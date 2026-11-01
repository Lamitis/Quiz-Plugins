# 插件包说明（PLUGINS）

仓库根下的每个目录就是一个**插件包源码**（声明式：`manifest.json` + 提示词 + 知识库资产 +
示例题库），不是 App 代码。装法见每个插件自己的 `README.md`；能力边界与可行性判断见
[`FEASIBILITY.md`](./FEASIBILITY.md)；发版流程见 [`../PUBLISH_GUIDE.md`](../PUBLISH_GUIDE.md)。

| 目录 | id | 版本 | 一句话 | 主程序里的入口（`ui_extensions`） | 关键资产 |
| --- | --- | --- | --- | --- | --- |
| `cheat-sheet-generator/` | `natsume.cheat-sheet-generator` | 1.1.0 | 错题 + 薄弱知识点 → 一页小抄（公式 / 避坑 / 口诀） | 错题本右上角「考前小抄」「掌心卡」 | `prompts/cheat_sheet.md`、`prompts/cheat_sheet_card.txt`、`sample_bank.json` |
| `variant-generator/` | `natsume.variant-generator` | 1.1.0 | 同一考点换一套陷阱，出一道变体题，答案默认收起 | 答题页解析区「举一反三」、错题本右上角「错题变体」 | `prompts/generate_variant.txt`、`prompts/generate_variant_from_errors.md`、`prompts/generate_variant_manual.txt` |

> 两个插件都按 **v1.38 接口约定**对接：清单里的 `ui_extensions` 声明「挂在哪个槽位、按钮叫什么、
> 用哪些上下文切片、填哪份模板」，取数 / 请求 / 渲染全在宿主。插件仍然不执行任何代码。

## 1. 校验

```powershell
dart run tool/validate_plugins.dart            # 校验仓库根下所有插件
dart run tool/validate_plugins.dart variant-generator   # 只校验一个
dart run tool/check_ui_contract.dart           # 用宿主真实解析器 + 模拟填槽跑一遍对接
```

`check_ui_contract.dart` 直接 import 工作区根目录的 `plugin_ui_extension.dart`
（宿主参考实现），所以它是**契约**层面的验证：`ui_extensions` 能不能被宿主解析出来、
按 `contexts` 填槽后有没有残留 `{{...}}`、内联模板与 `prompts/*` 是否同源。

检查项：清单必填字段 / `id` 与 `version` 正则（与登记表同一套）/ `capabilities` 白名单 /
`assets` 声明的文件是否存在 / 路径穿越与 BOM / 示例题库格式 / 模板槽位命名与文档一致性。

对接相关（v1.38 起，**专抓「装上去按钮不出现」这类静默失败**）：

- `ui_extensions` 的 `slot` / `action.type` / `renderer` / `icon` 是否在宿主白名单内；
  `label` ≤ 24 字、`prompt_template` ≤ 8000 字、`contexts` ≤ 8 个、单槽位 ≤ 4 个按钮；
- **模板占位符 ⊆ `contexts` 声明的上下文**：写了 `{{CORRECT_ANSWER}}` 却没说
  `correct_answer`，宿主不会填，占位符会原样发给模型；
- `renderer: bottom_sheet_foldable` 的模板里必须有 `<!--ANSWER_START-->`，否则答案不会折叠；
- `prompts/*` 模板里的槽位是否属于宿主会填的那 11 个（写错名字只报警告，但内容会变脏）。

## 2. 打包

```powershell
powershell -ExecutionPolicy Bypass -File tool/build_plugins.ps1
```

产出：`dist/<id>-<version>.natsume-plugin.zip` + 每个包的 `sha256` + 可直接贴进
`registry.json` 的条目（`download_url` 里的 `YOUR_GITHUB_USER/YOUR_REPO` 需要你替换）。

打 zip 的两条规矩（宿主加载器直接受影响，别踩）：

1. **把目录内容打进去，不要多套一层文件夹**（`plugin.json` 必须在包根）。
2. 条目名必须用 `/`：宿主 `PluginLoader.loadFromZip` **原样拿条目名落盘**
   （`File('$installDir/${entry.key}')`），而 Windows 上的 `ZipFile.CreateFromDirectory`
   会写成 `prompts\cheat_sheet.md`——在 Android / Linux 上 `\` 不是路径分隔符，
   装出来的目录里就没有 `prompts/`、`kb/`，`prompt.md` 与功能模板全部读不到
   （应用里表现为「插件装上了但没效果」）。所以 `tool/build_plugins.ps1`
   改成用 `ZipArchive` 逐条写并强制 `/`，打完还会自检条目名与清单位置。

> 发布后**不要覆盖同名资产**：sha256 一变，老客户端会当成坏包丢弃（见 `docs/插件开发指南.md` §8）。

## 3. 安装位置

装好后落在 App 私有目录 `<appSupport>/plugins/<plugin-id>/`（`PluginRegistryService.pluginRoot()`）。
三条安装路径：世界包导入 / 官方登记表 / 本地 zip（世界总览「导入插件」）。

## 4. 写新插件时的硬约束（摘自 `PLUGIN_DEVELOPMENT.md`）

- 不执行第三方代码：插件里放 `.dart` / `.dll` / `.js` 都不会被运行，**只是普通文件**。
- 能力只能取白名单：`kb.search` / `kb.read` / `question.generate` / `bank.export` / `question.tag`
  （内置插件另有 `notes` / `companion` / `schedule` 等，第三方写了也不会获得实现）。
- `id` 用反向域名风格，`^[a-z0-9][a-z0-9._-]{2,63}$`；**改 id = 换插件**，用户启停状态会丢。
- `version` 必须 `主.次.修` 三段数字；`description` ≤ 240 字；`name` / `author` ≤ 60 字。
- 文本资产放 `kb/`（会被导入知识库）或 `assets/`；文件名用 ASCII，避免 zip 中文名在不同工具间乱码。
- `tags`（可选，本仓库约定）：只给 `tool/build_plugins.ps1` 拼登记表用，客户端**不认识**它，
  别拿它做功能判断；上限 6 个、每个 16 字（登记表硬上限）。
- 不写诱导性提示词：App 侧的知识库约束优先级高于插件提示词。
- 想「在界面里出现一个按钮」，只有 `ui_extensions` 一条路：槽位限
  `quiz_analysis_actions` / `error_book_actions`，动作限 `ai_prompt`，数据只能从
  `contexts` 白名单里取（未声明的一律不给）。不要写 `pages/blocks`——那是尚未实现的方案 B。
