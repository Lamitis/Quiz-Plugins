#!/usr/bin/env python3
"""为 Natsume-Registry 生成登记文件（`plugins/<id>.json`，严格 7 个字段）。

用法：
  python tool/write_registry_entries.py --registry D:\\Natsume-Registry \\
      --tag cheat-sheet-v1.1.0 --tag variant-v1.1.0
  python tool/write_registry_entries.py --registry ... --tag ... --dry-run

它做的事：
  1. 用 tag 前缀 + 版本号在仓库根匹配插件目录（与 publish-plugins.yml 同一套规则）；
  2. 从 GitHub Release 找到该 tag 下唯一的 `.natsume-plugin.zip` 资产；
  3. **真下载、重算 sha256**（登记表 CI 的 scripts/validate_pr.py 会做同一件事，
     先在这里算，免得 PR 红）；
  4. 写 `plugins/<manifest.id>.json`：id / name / author / version / description /
     download_url / sha256 —— 一个字段都不多（多一个 validate_pr.py 就拒）。

⚠️ 文件名必须等于 `manifest.id`：`validate_pr.py` 里有「文件名要和 id 一致」的硬规则，
   所以是 `natsume.cheat-sheet-generator.json`，不是 `cheat-sheet-generator.json`。
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
import tempfile
import urllib.request
from pathlib import Path

TAG_RE = re.compile(r"^(.+)-v(\d+\.\d+\.\d+)$")


def api_json(url: str) -> dict:
    req = urllib.request.Request(
        url,
        headers={
            "User-Agent": "natsume-plugins-registry-writer",
            "Accept": "application/vnd.github+json",
        },
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.load(resp)


def download_sha256(url: str) -> tuple[str, int]:
    digest = hashlib.sha256()
    total = 0
    req = urllib.request.Request(url, headers={"User-Agent": "natsume-plugins-registry-writer"})
    with urllib.request.urlopen(req, timeout=60) as resp, tempfile.TemporaryFile() as tmp:
        while True:
            chunk = resp.read(65536)
            if not chunk:
                break
            digest.update(chunk)
            tmp.write(chunk)
            total += len(chunk)
    return digest.hexdigest(), total


def find_plugin_dir(repo: Path, name: str, version: str) -> tuple[Path, dict]:
    def load(d: Path) -> dict | None:
        manifest = d / "manifest.json"
        if not manifest.is_file():
            return None
        return json.loads(manifest.read_text(encoding="utf-8-sig"))

    candidates: list[Path] = []
    if (repo / name / "manifest.json").is_file():
        candidates = [repo / name]
    else:
        for d in sorted(p for p in repo.iterdir() if p.is_dir()):
            if d.name == name or d.name.startswith(name + "-"):
                if (d / "manifest.json").is_file():
                    candidates.append(d)
    if len(candidates) != 1:
        raise SystemExit(f"插件目录匹配失败：{name} → {[c.name for c in candidates] or '无'}")
    manifest = load(candidates[0])
    assert manifest is not None
    if str(manifest.get("version")) != version:
        raise SystemExit(
            f"{candidates[0].name} 的 manifest.version={manifest.get('version')} 与 tag 版本 {version} 不一致"
        )
    return candidates[0], manifest


def main() -> int:
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8", errors="replace")  # type: ignore[attr-defined]
        except Exception:
            pass

    parser = argparse.ArgumentParser(description="生成 Natsume-Registry 登记文件")
    parser.add_argument("--registry", required=True, help="本地 Natsume-Registry 克隆目录")
    parser.add_argument("--tag", action="append", required=True, help="Release tag，可重复")
    parser.add_argument("--repo", default="Lamitis/Quiz-Plugins", help="发布插件的 GitHub 仓库")
    parser.add_argument("--repo-root", default=".", help="插件源码仓库根（默认当前目录）")
    parser.add_argument("--dry-run", action="store_true", help="只打印，不写文件")
    args = parser.parse_args()

    registry = Path(args.registry).resolve()
    plugins_dir = registry / "plugins"
    if not registry.is_dir():
        raise SystemExit(f"找不到登记表仓库：{registry}")
    if not plugins_dir.is_dir():
        raise SystemExit(f"登记表仓库里没有 plugins/：{plugins_dir}")

    source_root = Path(args.repo_root).resolve()
    written: list[Path] = []

    for tag in args.tag:
        hit = TAG_RE.match(tag)
        if not hit:
            raise SystemExit(f"tag 格式不对：{tag}（应为 <插件名>-v<主>.<次>.<修>）")
        name, version = hit.group(1), hit.group(2)

        folder, manifest = find_plugin_dir(source_root, name, version)

        release = api_json(f"https://api.github.com/repos/{args.repo}/releases/tags/{tag}")
        assets = [
            a
            for a in release.get("assets", [])
            if str(a.get("name", "")).endswith(".natsume-plugin.zip")
        ]
        if len(assets) != 1:
            raise SystemExit(
                f"{tag} 下应有且只有一个 .natsume-plugin.zip，实际 {[a.get('name') for a in assets]}"
            )
        asset = assets[0]
        url = asset["browser_download_url"]

        print(f"\n== {tag} → {folder.name}/")
        print(f"   资产：{asset['name']}（{asset.get('size')} B）")
        sha, size = download_sha256(url)
        print(f"   下载后重算 sha256：{sha}（{size} B）")

        entry = {
            "id": str(manifest["id"]),
            "name": str(manifest["name"]),
            "author": str(manifest["author"]),
            "version": str(manifest["version"]),
            "description": str(manifest["description"]),
            "download_url": url,
            "sha256": sha,
        }
        target = plugins_dir / f"{entry['id']}.json"
        if args.dry_run:
            print(f"   [dry-run] 将写入 {target}")
            print(json.dumps(entry, ensure_ascii=False, indent=2))
            continue
        target.write_text(json.dumps(entry, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        written.append(target)
        print(f"   已写入 {target}")

    if written:
        print("\n下一步（阶段四）：")
        for path in written:
            print(f"  git -C {registry} add plugins/{path.name}")
        print("  → 建分支 → 提交 → 推送 → 开 PR（一次 PR 只允许一个 plugins/<id>.json）")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
