#!/usr/bin/env python3
"""本地模拟 `.github/workflows/publish-plugins.yml`（不联网、不建 Release）。

为什么需要它：工作流里的 tag 解析、目录定位、清单版本校验都是 bash 逻辑，
写错只有推了 tag 才会在 CI 上炸。这个脚本把 YAML 里每个 step 的 `run:` **原样**抽出来，
按顺序在本地 bash 里跑一遍（模拟 GITHUB_OUTPUT / GITHUB_STEP_SUMMARY / RUNNER_TEMP），
推 tag 之前先验证一遍分支走向。

用法：
  python tool/dryrun_publish_workflow.py --tag cheat-sheet-v1.1.0   # 期望：全部通过
  python tool/dryrun_publish_workflow.py --tag v1.1.0               # 期望：第 1 步失败（格式）
  python tool/dryrun_publish_workflow.py --tag nope-v1.1.0          # 期望：第 2 步失败（目录）
  python tool/dryrun_publish_workflow.py --tag cheat-sheet-v1.2.0   # 期望：第 3 步失败（版本不一致）

跳过的东西（有意）：
  · `uses:` 步骤（checkout）；
  · 含 `gh release` 的步骤——本机不能真去建 Release / 传资产；
  · 本机没装 `zip` 时，打包步骤会失败，脚本会提示这是环境问题而不是逻辑问题。
"""
from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

EXPR = re.compile(r"\$\{\{\s*(.+?)\s*\}\}")


def find_bash(explicit: str | None) -> str:
    """挑一个能真跑脚本的 bash。

    注意不能直接 `shutil.which('bash')`：Windows 上它常指向 `C:\\Windows\\System32\\bash.exe`
    （WSL 启动器），没装发行版时会报 `execvpe(/bin/bash) failed`，看起来像脚本写错了。
    """
    if explicit:
        if not Path(explicit).exists():
            sys.exit(f"--bash 指定的路径不存在：{explicit}")
        return explicit
    for c in [r"C:\Program Files\Git\bin\bash.exe", r"C:\Program Files\Git\usr\bin\bash.exe"]:
        if Path(c).exists():
            return c
    which = shutil.which("bash")
    if which and "system32" not in which.lower():
        return which
    if Path("/bin/bash").exists():
        return "/bin/bash"
    sys.exit("找不到可用的 bash（装 Git for Windows，或用 --bash 指定路径）")


def bash_has(bash: str, command: str) -> bool:
    """bash 里有没有某个命令（Git for Windows 默认不带 zip/unzip）。"""
    proc = subprocess.run(
        [bash, "--noprofile", "--norc", "-c", f"command -v {command}"],
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
    )
    return proc.returncode == 0 and proc.stdout.strip() != ""


ZIP_TEST_DOUBLE = r'''
"""zip 的测试替身：只实现工作流用到的那几种用法。

支持：zip -r -q -X <out.zip> <paths...> [-x <pattern>]...
（Git for Windows 的 bash 里没有 zip，用它才能在本机把第 4 步整段跑通。）
"""
import fnmatch
import os
import sys
import zipfile


def main(argv):
    args, out, includes, excludes, quiet = argv[1:], None, [], [], False
    i = 0
    while i < len(args):
        a = args[i]
        if a == "-x":
            i += 1
            if i < len(args):
                excludes.append(args[i])
        elif a.startswith("-"):
            quiet = quiet or "q" in a
        elif out is None:
            out = a
        else:
            includes.append(a)
        i += 1
    if not out:
        print("zip(替身): 缺少输出文件", file=sys.stderr)
        return 2
    if not includes:
        includes = ["."]
    count = 0
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as zf:
        for inc in includes:
            if os.path.isfile(inc):
                zf.write(inc, os.path.basename(inc))
                count += 1
                continue
            for root, dirs, files in os.walk(inc):
                dirs.sort()
                for name in sorted(files):
                    full = os.path.join(root, name)
                    arc = os.path.relpath(full, inc).replace(os.sep, "/")
                    if any(fnmatch.fnmatch(arc, p) or fnmatch.fnmatch(name, p) for p in excludes):
                        continue
                    zf.write(full, arc)
                    count += 1
    if not quiet:
        print(f"  adding: {count} files (zip test double)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
'''


def write_zip_test_double(shim_dir: Path) -> None:
    """往 shim 目录写一个 zip 替身（bash 里没 zip 时用）。"""
    script = shim_dir / "zip_test_double.py"
    script.write_text(ZIP_TEST_DOUBLE, encoding="utf-8", newline="\n")
    wrapper = shim_dir / "zip"
    wrapper.write_text(
        f'#!/bin/sh\nexec "{sys.executable}" "{script.as_posix()}" "$@"\n',
        encoding="utf-8",
        newline="\n",
    )
    wrapper.chmod(0o755)


def load_yaml(path: Path) -> dict:
    try:
        import yaml  # type: ignore
    except ImportError:
        sys.exit("需要 PyYAML：python -m pip install pyyaml")
    with path.open(encoding="utf-8") as fh:
        return yaml.safe_load(fh)


class Runner:
    def __init__(self, repo: Path, tag: str, bash: str, keep: bool, gh_repository: str):
        self.repo = repo
        self.tag = tag
        self.bash = bash
        self.keep = keep
        self.gh_repository = gh_repository
        self.outputs: dict[str, dict[str, str]] = {}
        self.zip_is_double = False
        self.tmp = Path(tempfile.mkdtemp(prefix="dryrun_workflow_"))
        self.runner_temp = self.tmp / "runner_temp"
        self.runner_temp.mkdir()
        self.summary = self.tmp / "step_summary.md"
        self.summary.write_text("", encoding="utf-8")
        # Windows 的 bash 里 `python3` 常落到应用商店占位符（"Python was not found"）：
        # 塞一个转发到当前解释器的 shim，让第 3 步的 python3 在本地也能跑。
        self.shim_dir = self.tmp / "bin"
        self.shim_dir.mkdir()
        shim = self.shim_dir / "python3"
        # Windows 的 python 在文本模式下输出 CRLF，`read -r` 会把 \r 带进变量导致
        # 「1.1.0 != 1.1.0」这种假失败。shim 负责去掉行尾 CR 并保留退出码。
        shim.write_text(
            "#!/bin/sh\n"
            'tmp="$(mktemp)"\n'
            f'"{sys.executable}" "$@" > "$tmp"\n'
            "rc=$?\n"
            'sed "s/\\r$//" "$tmp"\n'
            'rm -f "$tmp"\n'
            "exit $rc\n",
            encoding="utf-8",
            newline="\n",
        )
        shim.chmod(0o755)

        # Git for Windows 的 bash 里默认没有 zip：塞一个等价替身，让第 4 步在本地也能整段跑通
        self.can_zip = bash_has(bash, "zip") and bash_has(bash, "unzip")
        if not bash_has(bash, "zip") and bash_has(bash, "unzip"):
            write_zip_test_double(self.shim_dir)
            self.can_zip = True
            self.zip_is_double = True

    def resolve(self, text: str) -> str:
        """把 ${{ ... }} 换成对应值（只支持工作流里实际用到的几种）。"""

        def one(m: re.Match[str]) -> str:
            ref = m.group(1).strip()
            if ref == "github.ref_name":
                return self.tag
            if ref == "github.ref":
                return f"refs/tags/{self.tag}"
            if ref == "github.repository":
                return self.gh_repository
            if ref == "secrets.GITHUB_TOKEN":
                return "dryrun-token"
            hit = re.fullmatch(r"steps\.([\w-]+)\.outputs\.([\w-]+)", ref)
            if hit:
                return self.outputs.get(hit.group(1), {}).get(hit.group(2), "")
            raise SystemExit(f"未支持的表达式：${{{{ {ref} }}}}")

        return EXPR.sub(one, text)

    def run_step(self, index: int, step: dict) -> None:
        name = step.get("name", f"step {index}")
        if "uses" in step:
            print(f"\n== 跳过（uses: {step['uses']}）：{name}")
            return
        script = step.get("run")
        if not script:
            print(f"\n== 跳过（没有 run）：{name}")
            return

        print(f"\n== {name}")
        script_path = self.tmp / f"step_{index}.sh"
        script_path.write_text(script, encoding="utf-8", newline="\n")

        # 先做语法检查（bash -n）：连跳过的步骤也查，免得「CI 上第一次跑才发现少个 fi」
        syntax = subprocess.run(
            [self.bash, "--noprofile", "--norc", "-n", script_path.as_posix()],
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
        )
        if syntax.returncode != 0:
            print(syntax.stderr.rstrip(), file=sys.stderr)
            raise SystemExit(f"\n✗ bash 语法错误：{name}")

        if "gh release" in script:
            print("   语法通过；跳过执行（本机不建 Release / 不传资产）")
            return
        if "zip -r" in script and not self.can_zip:
            print("   语法通过；跳过执行（本机 bash 里没有 zip/unzip，CI 的 ubuntu-latest 有）")
            return

        out_file = self.tmp / f"output_{index}.txt"
        out_file.write_text("", encoding="utf-8")
        # 必须继承本机环境：msys bash 启动时要靠 SYSTEMROOT / TEMP / PATH 初始化，
        # 只给 GITHUB_* 几个变量会让它直接起不来（Bash/Service 0x8007072c）。
        env = os.environ.copy()
        env.update({
            "GITHUB_REF_NAME": self.tag,
            "GITHUB_REF": f"refs/tags/{self.tag}",
            "GITHUB_REPOSITORY": self.gh_repository,
            "GITHUB_STEP_SUMMARY": self.summary.as_posix(),
            "GITHUB_OUTPUT": out_file.as_posix(),
            "RUNNER_TEMP": self.runner_temp.as_posix(),
        })
        # Windows 的 bash 里 `python3` 常常落到应用商店的占位符（"Python was not found"），
        # 塞一个转发到当前解释器的 shim，让第 3 步的 python3 在本地也能跑。
        env["PATH"] = self.shim_dir.as_posix() + ":" + env.get("PATH", "")
        for key, value in (step.get("env") or {}).items():
            env[key] = self.resolve(str(value))

        script_path = self.tmp / f"step_{index}.sh"
        script_path.write_text(script, encoding="utf-8", newline="\n")

        proc = subprocess.run(
            [self.bash, "--noprofile", "--norc", script_path.as_posix()],
            cwd=str(self.repo),
            env=env,
            text=True,
            capture_output=True,
            encoding="utf-8",
            errors="replace",
        )
        if proc.stdout:
            print(proc.stdout.rstrip())
        if proc.stderr:
            print(proc.stderr.rstrip(), file=sys.stderr)

        step_id = step.get("id")
        if step_id:
            collected: dict[str, str] = {}
            for line in out_file.read_text(encoding="utf-8").splitlines():
                if "=" in line:
                    k, v = line.split("=", 1)
                    collected[k] = v
            self.outputs[step_id] = collected
            if collected:
                print(f"   outputs[{step_id}] = {collected}")

        if proc.returncode != 0:
            raise SystemExit(f"\n✗ 步骤失败：{name}（exit {proc.returncode}）")

    def finish(self) -> None:
        body = self.summary.read_text(encoding="utf-8").strip()
        if body:
            print("\n===== Step Summary =====")
            print(body)
        if self.keep:
            print(f"\n(临时目录保留：{self.tmp})")
        else:
            shutil.rmtree(self.tmp, ignore_errors=True)


def main() -> int:
    # 控制台可能是 GBK（中文 Windows）：Step Summary 里有 ✅ / → 之类字符，
    # 直接 print 会 UnicodeEncodeError。先把输出流切成 UTF-8。
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8", errors="replace")  # type: ignore[attr-defined]
        except Exception:  # 老 Python / 重定向流不支持就算了
            pass

    parser = argparse.ArgumentParser(description="本地模拟 publish-plugins 工作流")
    parser.add_argument("--tag", required=True, help="模拟推送的 tag，例如 cheat-sheet-v1.1.0")
    parser.add_argument("--diagnose", action="store_true", help="只打印本机 bash 里有哪些工具")
    parser.add_argument("--workflow", default=".github/workflows/publish-plugins.yml")
    parser.add_argument("--repo-root", default=".")
    parser.add_argument("--bash", default=None)
    parser.add_argument("--keep", action="store_true", help="保留临时工作目录")
    parser.add_argument("--repository", default="Lamitis/Quiz-Plugins")
    args = parser.parse_args()

    # Windows 下 PowerShell 抓原生进程的输出容易乱码 / 丢行：给个 DRYRUN_LOG=<路径>
    # 就能把整段日志同时写进 UTF-8 文件，排查时直接看文件。
    log_path = os.environ.get("DRYRUN_LOG")
    if log_path:
        handle = open(log_path, "w", encoding="utf-8")

        class _Tee:
            def __init__(self, stream, fh):
                self.stream = stream
                self.fh = fh

            def write(self, data):
                self.stream.write(data)
                self.fh.write(data)
                self.fh.flush()
                return len(data)

            def flush(self):
                self.stream.flush()
                self.fh.flush()

        sys.stdout = _Tee(sys.stdout, handle)  # type: ignore[assignment]
        sys.stderr = _Tee(sys.stderr, handle)  # type: ignore[assignment]

    repo = Path(args.repo_root).resolve()
    workflow = repo / args.workflow
    if not workflow.exists():
        sys.exit(f"找不到工作流：{workflow}")

    bash = find_bash(args.bash)
    if args.diagnose:
        print(f"bash = {bash}")
        for tool in ("zip", "unzip", "du", "sha256sum", "python3", "sed", "tr", "mktemp"):
            print(f"  {tool:<10} {'OK' if bash_has(bash, tool) else 'MISSING'}")
        return 0

    data = load_yaml(workflow)
    steps = data["jobs"]["publish"]["steps"]
    print(f"模拟 tag = {args.tag}（{len(steps)} 个步骤，仓库 {repo}）")

    runner = Runner(repo, args.tag, bash, args.keep, args.repository)
    for i, step in enumerate(steps, start=1):
        runner.run_step(i, step)
    runner.finish()
    print("\n✓ 工作流在本地跑完（未建 Release）")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

