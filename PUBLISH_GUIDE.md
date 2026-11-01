# 发版指南（PUBLISH_GUIDE）

> 一句话：**目录就是插件，tag 就是发布。**
> 往 `main` 推一个形如 `<插件名>-v<版本号>` 的 tag，`.github/workflows/publish-plugins.yml`
> 就会把对应目录打成 `.natsume-plugin.zip`、算 sha256、建 Release、把 zip 传成资产。

## 1. 仓库约定

```
<plugin-name>/            ← 仓库根下的目录就是一个插件（平铺，不套 plugins/）
├── manifest.json         ← 必须在目录根（宿主加载器只在包根认它）
├── prompt.md
├── prompts/
├── kb/
└── README.md
tool/  docs/  dist/       ← 工具、文档、本地打包产物：工作流不会把它们当插件
```

工作流只认「根目录下带 `manifest.json` 的文件夹」，所以加插件不用改 YAML。

## 2. Tag 规则

| tag 写法 | 解析出的插件名 | 落到哪个目录 | 产出的资产名 |
| --- | --- | --- | --- |
| `cheat-sheet-v1.1.0` | `cheat-sheet` | `cheat-sheet-generator/`（唯一以 `cheat-sheet-` 开头且带清单的目录） | `cheat-sheet-generator-1.1.0.natsume-plugin.zip` |
| `cheat-sheet-generator-v1.1.0` | `cheat-sheet-generator` | 同名目录 | 同上 |
| `variant-v1.1.0` | `variant` | `variant-generator/` | `variant-generator-1.1.0.natsume-plugin.zip` |

规则细节：

- 必须匹配 `^(.+)-v(\d+\.\d+\.\d+)$`——**三段数字**，不接受 `v1.1` / `1.1.0` / `-beta`。
- 前缀先按**同名目录**找；找不到再按「`<前缀>-` 开头的目录」兜底，必须**唯一**。
  命中多个会报错并列出候选，改用完整目录名打 tag 即可。
- 前缀不是资产名：资产名永远用**目录名** + 版本号，这样同一个插件的历史资产命名一致，
  登记表里的 `download_url` 也稳定。

## 3. 发一个新版本（三步）

```bash
# 0）先改版本号：目录里的 manifest.json → "version": "1.2.0"
git add . && git commit -m "feat(cheat-sheet): 1.2.0 …" && git push origin main

# 1）打 tag（tag 里的版本号必须与 manifest.json 的 version 一致）
git tag cheat-sheet-v1.2.0

# 2）推 tag，CI 自动打包发版
git push origin cheat-sheet-v1.2.0
```

跑完在 Actions 里能看到 5 步日志（解析 tag → 定位目录 → 校验清单 → 打包算哈希 → 建 Release），
Step Summary 会带上资产名与 sha256。Releases 页面就会出现 `cheat-sheet-v1.2.0` 与对应 zip。

## 4. 工作流到底做了什么

| 步骤 | 行为 | 失败会怎样 |
| --- | --- | --- |
| 1 解析 tag | 正则拆出前缀与版本号 | tag 写错格式 → 直接失败并给出正确示例 |
| 2 定位目录 | 同名目录 → 唯一前缀匹配目录 | 找不到 / 命中多个 → 失败并列出现有目录 |
| 3 校验清单 | `manifest.json` 必须在目录根；`version` 必须等于 tag 版本 | 不一致 → 失败（防止「tag 是 1.2.0，包里还是 1.1.0」） |
| 4 打包 + 哈希 | `cd 目录 && zip -r`，自检条目名无 `\`、`manifest.json` 在包根，打印 sha256 | 自检不过 → 失败，`Release` 不会建 |
| 5 建 Release | 用同一个 tag 建 Release 并上传 zip | 已存在 Release 则补传；同名资产哈希不同 → 失败 |

权限只有 `contents: write`（建 Release / 传资产需要），没有 secrets，不执行插件代码。

## 5. 铁律：不要覆盖已发布的资产

同名资产一旦被覆盖，`sha256` 就变了，老客户端会把它当**坏包**丢弃（见
`docs/PLUGINS.md` §2）。所以工作流在「同名资产已存在」时：

- 哈希相同 → 跳过上传（重跑安全）；
- 哈希不同 → **失败**，请升版本号重发。

要撤包就发新版本并在 Release 里写明，别去改老 tag 的资产。

## 6. 本地预检（打 tag 之前跑一遍，省一次 CI 失败）

```powershell
dart run tool/validate_plugins.dart          # 清单字段 / 能力白名单 / 资产 / ui_extensions 契约
dart run tool/check_ui_contract.dart         # 用宿主真实解析器 + 模拟填槽验一遍
powershell -ExecutionPolicy Bypass -File tool/build_plugins.ps1 -SkipValidate   # 本地打一版对照
```

`dist/` 里的产物只作对照与留档，**Release 以 CI 打包的为准**（zip 记录时间戳，
同一份源码两次打包的 sha256 不会相同）。

## 7. 没有 CI 时的手动兜底

```powershell
powershell -ExecutionPolicy Bypass -File tool/build_plugins.ps1     # 产出 dist/*.zip + sha256
gh release create cheat-sheet-v1.2.0 dist/cheat-sheet-generator-1.2.0.natsume-plugin.zip `
  --title "cheat-sheet-v1.2.0" --notes "…"
```

## 8. 和登记表的衔接

Release 建好后，下载地址与哈希就是 `Natsume-Registry` 里要写的两个字段：

```json
{
  "id": "natsume.cheat-sheet-generator",
  "download_url": "https://github.com/Lamitis/Quiz-Plugins/releases/download/cheat-sheet-v1.2.0/cheat-sheet-generator-1.2.0.natsume-plugin.zip",
  "sha256": "<Release 资产的实际 sha256>"
}
```

- 文件名必须是 `plugins/<id>.json`（`validate_pr.py` 强制「文件名 == id」）。
- 哈希以**下载回来的资产**为准（CI 日志 / Step Summary / Release 说明里都有）。
