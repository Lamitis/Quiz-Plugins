# Quiz-Plugins

NatsumeQuizMaster 的**官方插件包**源码与发布仓库。

插件是**声明式包**：一个 `manifest.json` + 提示词 + 知识库资产 + 示例题库。
它**不执行任何代码**——按钮、取数、请求、渲染全部由宿主实现，插件只声明
「挂在哪个槽位、按钮叫什么、用哪些上下文、填哪份模板」（`ui_extensions`）。

## 当前插件

| 目录 | id | 版本 | 一句话 | 宿主里的入口 |
| --- | --- | --- | --- | --- |
| `plugins/cheat-sheet-generator/` | `natsume.cheat-sheet-generator` | 1.1.0 | 错题 + 薄弱知识点 → 一页小抄（公式 / 避坑 / 口诀） | 错题本右上角「考前小抄」「掌心卡」 |
| `plugins/variant-generator/` | `natsume.variant-generator` | 1.1.0 | 同一考点换一套陷阱，出一道变体题，答案默认收起 | 答题页解析区「举一反三」、错题本右上角「错题变体」 |

两个插件都要求宿主 **v1.38.0+**（`min_app_version`）。

## 目录

```
plugins/<plugin>/
├── manifest.json      # 清单：id / 版本 / 能力 / 资产 / ui_extensions
├── prompt.md          # 系统口径（宿主注入解析与追问）
├── prompts/           # 功能模板（宿主按 ui_extensions 填槽）
├── kb/                # 可导入知识库的参考资料
├── sample_bank.json   # 示例题库（可选）
└── README.md          # 安装 / 槽位 / 降级方案 / 隐私说明
tool/
├── validate_plugins.dart    # 静态校验：清单字段、能力白名单、资产、示例题库、ui_extensions 契约
├── check_ui_contract.dart   # 用宿主真实解析器 + 模拟填槽跑一遍对接
├── build_plugins.ps1        # 打包（ZipArchive，条目名强制 `/`）
└── publish_plugins.ps1      # 发 Release + 写 Natsume-Registry 登记条目
dist/                  # 发布产物（zip + SHA256SUMS），Release 直接上传这些文件
```

`plugin_ui_extension.dart` 是宿主 `lib/services/plugins/plugin_ui_extension.dart` 的
**参考副本**，只给 `tool/check_ui_contract.dart` import 用（保证「宿主能不能解析出这些按钮」
这件事在离机状态下也能验）。其余宿主源码不在此仓库。

## 安装

世界总览 → 导入插件 → 选 `*.natsume-plugin.zip`；或在插件市场经 Natsume-Registry 安装。

## 构建与校验

```powershell
dart run tool/validate_plugins.dart          # 静态校验
dart run tool/check_ui_contract.dart         # 宿主解析器对接（填槽不残留 {{...}}）
powershell -ExecutionPolicy Bypass -File tool/build_plugins.ps1
```

打 zip 的两条硬规矩：

1. **把目录内容打进去**，`manifest.json` 必须在包根（不要多套一层文件夹）。
2. **条目名用 `/`**：宿主在 Android / Linux 上把条目名直接当相对路径落盘，`\` 会让
   `prompts/`、`kb/` 变成文件名而不是目录，装上去「按钮没反应」。

## 发布

1. `tool/build_plugins.ps1` → `dist/<name>-<version>.natsume-plugin.zip` + SHA256SUMS。
2. 在 GitHub 建对应 tag 的 Release，上传 `dist/` 里的 zip。
3. 往 [Natsume-Registry](https://github.com/Lamitis/Natsume-Registry) 提 `plugins/<id>.json`
   （7 个字段，`download_url` + `sha256` 必须与资产一致）。

**发布后不要覆盖同名资产**：sha256 一变，老客户端会把它当坏包丢弃；升级请发新版本。

## 许可

AGPL-3.0，见 [LICENSE](./LICENSE)。插件清单、提示词与文档由 NatsumeQuizMaster 维护。
插件 API 与宿主行为以主程序仓库的 `PLUGIN_DEVELOPMENT.md` 为准（本仓库内有一份副本）。
