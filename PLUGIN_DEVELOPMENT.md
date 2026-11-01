# 插件 API 对接文档（PLUGIN_DEVELOPMENT）

> 版本：v1.35.4 · 面向**插件作者 / 二次开发者 / 希望接入主程序数据的工具**
> 配套文档：`docs/插件开发指南.md`（面向普通用户的简明版）、`docs/同步说明.md`（同步协议）

本文回答四件事：**主程序现在支持什么样的插件**、**暴露了哪些 API**、
**插件包（含 `manifest.json`）的标准**、**想要真正「动态加载」时的最小可用方案**。

---

## 0. 一分钟结论

| 能力 | 现状 | 说明 |
|---|---|---|
| 声明式资源包插件（zip / 目录） | ✅ 已支持 | `plugin.json`（或 `manifest.json`）清单 + 提示词 + 知识库文档 + 示例题库 |
| 官方登记表安装（Natsume-Registry） | ✅ 已支持 | 只做**机械校验**（字段白名单 / 域名白名单 / sha256 重算），不做代码审核 |
| 世界包（知识库 + 题库 + 插件） | ✅ 已支持 | `.natsume-world`（本质是 zip），`WorldService` 导入导出 |
| 插件数据跨端同步 | ✅ 已支持（v1.35） | `SyncRepository` 快照的 `plugins` 块；每台设备各自决定同步范围 |
| 代码插件（`.dll/.so/.dart/.js`） | ❌ **不支持** | 安全红线：**不执行任意第三方代码**，也不加载原生库 |
| 主题包（外部主题） | ❌ 不支持 | 主题是内置预设（`ThemeService`），插件无法替换配色/字体/图标资源 |
| UI 插槽（第三方往界面插入控件） | ❌ 不支持 | 只有内置插件的**固定入口**（世界总览 / 我的 → 学习工具） |

一句话：**当前是「声明式插件」体系，不是「可执行插件」体系。**
插件能改的是「AI 的口径、默认资产、能力声明与启停」，不能改的是「程序行为」。

---

## 1. 现有插件体系（实现现状）

### 1.1 组成

| 组件 | 文件 | 职责 |
|---|---|---|
| `PluginManifest` / `LoadedPlugin` | `lib/services/plugins/plugin_loader.dart` | 解析清单；把 `prompt.md` 与 `kb/`、`*.json` 等文本资产读进内存 |
| `PluginLoader` | 同上 | 从 zip 或目录加载；**路径穿越防护**（拒绝 `..` 与绝对路径）；资产落盘到安装目录 |
| `PluginInfo` | `lib/models/plugin.dart` | `plugins` 表的一行：清单原文 + 启停状态 + 安装时间 |
| `BuiltinPlugins` | `lib/services/plugins/builtin_plugins.dart` | 内置插件（笔记 / 助教 / 日程）幂等登记，保留用户启停 |
| `PluginRegistryService` | `lib/services/plugins/plugin_registry.dart` | 拉登记表、字段校验、下载、sha256 校验、staging 解包后原子替换 |
| `WorldService` | `lib/services/plugins/world_service.dart` | `.natsume-world` 打包/解包（`world.json` 清单 + kb/ + banks/ + plugins/） |
| `PluginSyncScope` | `lib/models/plugin_sync_scope.dart` | 「本机要不要把插件数据带进同步快照」（存本机 settings，不随快照传播） |
| 世界总览页 | `lib/screens/world_overview_screen.dart` | 插件列表、启停开关、许可与上游署名、导入入口 |

### 1.2 三条安装路径

1. **世界包导入**：`.natsume-world` → `WorldService.importWorld(zipPath)`
   → 依次导入知识库 / 题库 / 插件（每个插件目录走 `PluginLoader.loadFromDirectory`）。
2. **官方登记表**：`PluginRegistryService.fetch()` 拉表 → 用户点安装 →
   `install()` 下载 → **重算 sha256** → 解到 staging → `manifest.id` 与登记项一致才替换正式目录。
3. **本地 zip**：`PluginLoader.loadFromZip(zipPath, installDir)`（世界总览的「导入插件」）。

三条路径共同点：**清单 + 资产，装完即可用；不经过任何编译或解释执行。**

### 1.3 为什么没有代码插件（写清楚，免得反复被问）

插件一旦能执行代码，就等于拿到这台设备的全部能力：

- 读写**全部题库/笔记/作答记录**（本地 SQLite 明文）；
- 读 **API Key 的加密上下文**（`SecureKeyStorage` / `KeyCrypto`）；
- 任意出站网络请求（可以静默外传数据）；
- 在 Windows 上还能拉起子进程。

本项目的定位是「本地优先、可审计」，因此把插件能力限制在**声明式**范围内：
能力字符串（`capabilities`）+ 提示词（`prompt.md`）+ 资产（知识库 / 示例题库）。
要突破这条线，必须先有沙箱与权限模型（见第 4 节方案 C）。

---

## 2. 主程序暴露的 API（可直接对接的面）

> 约定：以下都是 **Dart 层公开成员**，属于「同一仓库内可调用」。
> 由于不支持代码插件，外部程序**不能**在运行时调用它们；
> 想在外部程序里用，请走「题库文件 / 世界包 / 局域网同步协议」这三条数据通道。
> 该表格同时是后续做「插件宿主 API」时的清单底稿。

### 2.1 题库读取（只读）

| API | 说明 |
|---|---|
| `DatabaseService.instance.getAllBanks()` | 全部题库（`QuestionBank`） |
| `DatabaseService.instance.getQuestionsByBank(bankId)` | 某题库全部题目 |
| `DatabaseService.instance.getQuestionsByBanks(ids, {random, limit, knowledgePoints, questionTypes})` | 跨题库抽题，支持知识点/题型筛选与 SQL 下推 LIMIT |
| `DatabaseService.instance.getKnowledgePointsByBanks(ids)` | 知识点分布（含「未分类」空串口径） |
| `DatabaseService.instance.getQuestionCountByBank(bankId)` | 题数 |
| 模型 | `lib/models/question.dart`、`question_bank.dart`、`question_image.dart` |

### 2.2 题库写入 / 导入导出

| API | 说明 |
|---|---|
| `BankFileService.importJsonFile(path)` | 导入题库 JSON，返回 `(题数, 配图数, 错误, 跳过数)` |
| `BankFileService.exportBank(bankId, bankName, destPath)` | 导出题库 JSON（格式标记 `natsume-quiz-questions`） |
| `DatabaseService.upsertBankByUid` / `upsertQuestionByUid` / `mergeQuestionImages` | 按全局 `uid` 幂等写入（同步与导入共用） |

### 2.3 知识库

| API | 说明 |
|---|---|
| `KbService.createKnowledgeBase / listKnowledgeBases / rename / delete` | 知识库增删改查 |
| `KbService.importDocument(kbId, filePath)` | 导入 `.md/.txt/.docx/.pdf`（自动切块索引） |
| `KbService.search(kbId, query, {topK})` | 检索，返回 `List<KbHit>` |
| `KbFileService.exportKnowledgeBase / importKbFile` | 知识库包导出/导入（世界包成员） |
| `KbRetriever.search(query, {topK})` / `KbChunker` | 纯算法层，可脱离 DB 单测 |

### 2.4 AI（受知识库约束）

| API | 说明 |
|---|---|
| `AIService.instance.streamAnalysis(question, {grounding})` | 解析（流式，`grounding` = 知识库片段） |
| `AIService.instance.streamFollowUp / askFollowUp` | 追问 |
| `AIService.instance.tagKnowledgePoint(question, ...)` | 知识点打标（含 taxonomy 归一化） |
| `AIService.instance.generateSessionSummary / generateWeaknessAnalysis / generateKpAdvice` | 总结与建议 |
| `AIService.instance.callWithTools(...)` | 工具调用（内置题库/知识库工具注册在 `generator_agent.dart`） |
| `AiProvider`（`lib/services/ai/ai_provider.dart`） | 可插拔的模型后端接口（OpenAI 兼容 / Anthropic / Gemini） |

### 2.5 内置插件的数据面

| 插件 | API |
|---|---|
| 双链笔记 `natsume.notes` | `NotesService.list / create / save / delete / backlinks / groups / graph` |
| 日程待办 `natsume.schedule` | `ScheduleService.load / add / update / ...` |
| 助教 `natsume.companion` | `CompanionService`（人设、记忆、气泡；API Key 走 `SecureKeyStorage`） |

### 2.6 同步（插件内容如何跨端）

| API / 约定 | 说明 |
|---|---|
| `SyncRepository.exportSnapshot({banksOnly, since})` | 快照含 `plugins` 块（笔记/待办/助教人设与记忆） |
| `SyncRepository.importSnapshot(snapshot, {conflictSink})` | 合并口径：按 `uid` 认行，`updated_at` 新的赢 |
| `PluginSyncScope`（settings 键 `plugin_sync_scope_v1`） | **每台设备各自决定**是否带笔记/待办/助教；不随快照传播 |
| `SyncServer` 协议 | `GET /sync/info`、`POST /sync/exchange`、`POST /sync/pair`、`POST /sync/cancel`（v1.35.4） |
| 同步状态 | `SyncEngine.statusMessage / pairState / lastError`（`SyncException` 业务码） |

**明确不同步的字段**：助教 API Key、接口地址/模型、知识库 id、悬浮位置、好感度。
自制插件若要跨端数据，请在自己的说明里写清「本机 / 可同步」，并沿用
`uid + updated_at` 的合并口径——否则两个方向同时改会互相覆盖。

### 2.7 UI 插槽（现状）

| 位置 | 谁在用 | 第三方能否插入 |
|---|---|---|
| 世界总览 → 插件区（列表 / 启停 / 许可署名） | 内置 + 第三方（登记表） | 只能出现在这个列表里，不能自定义控件 |
| 答题页解析按钮区（`quiz_analysis_actions`） | 第三方（`ui_extensions`） | ✅ 图标按钮，动作限 `ai_prompt` |
| 错题本右上角（`error_book_actions`） | 第三方（`ui_extensions`） | ✅ 图标按钮，动作限 `ai_prompt` |
| 我的 → 学习工具 → 双链笔记 / 小鲸助教 / 日程 | 内置插件 | ❌ |
| 设置 → 同步与提醒 → 插件内容同步 | 内置插件 | ❌ |
| 首页同名题库冲突横幅（`widgets/sync_conflict_banner.dart`） | 同步引擎 | ❌ |

### 2.8 观测

| API | 说明 |
|---|---|
| `DebugLogService.instance.log(tag, message)` | 分类日志（`SYNC` / `REMINDER` …），插件加载/安装都写这里 |
| 同步耗时打点 | 日志里带 `[SYNC]` 前缀：`exportSnapshot / importSnapshot / 各步骤 ms` |


---

## 3. 插件目录结构与 `manifest.json` 标准

### 3.1 目录结构

```
my-plugin/
├── manifest.json          # 必填：插件清单（等价别名：plugin.json，见 3.4）
├── prompt.md              # 可选：注入给 AI 的系统提示词
├── kb/                    # 可选：内置知识库文档（.md / .txt / .json）
│   └── 病理学笔记.md
├── sample_bank.json       # 可选：内置示例题库（natsume-quiz-questions 格式）
└── assets/                # 可选：其他文本资产（会被读进 LoadedPlugin.assets）
    └── glossary.json
```

打包：把**目录内容**打成 zip（不要多套一层文件夹），扩展名建议 `.natsume-plugin.zip`。

安装后的落盘位置（`PluginRegistryService.pluginRoot()`，App 私有目录）：

```
<appSupport>/plugins/<plugin-id>/
├── manifest.json
├── prompt.md
└── kb/...
```

### 3.2 `manifest.json` 字段

| 字段 | 类型 | 必填 | 规则 |
|---|---|---|---|
| `id` | string | ✅ | 反向域名风格；正则 `^[a-z0-9][a-z0-9._-]{2,63}$`；**改 id = 换插件**，用户启停状态会丢 |
| `name` | string | ✅ | 展示名，≤ 60 字 |
| `version` | string | ✅ | `主.次.修` 三段数字（`^\d+\.\d+\.\d+$`），用于「可更新」判断 |
| `author` | string | ✅（登记表要求） | ≤ 60 字 |
| `description` | string | ✅ | ≤ 240 字（登记表硬上限） |
| `capabilities` | string[] | ✅（可为空数组） | 只能取 3.3 的白名单；未知能力会被忽略但**展示给用户** |
| `license` | string | 建议 | 如 `AGPL-3.0`；缺失时界面显示「未声明」 |
| `syncable` | bool | 建议 | 插件数据是否参与局域网同步，**缺省 false**（保守） |
| `min_app_version` | string | 可选 | 低于该版本时客户端只提示「需升级」，不安装 |
| `entry` | string | 可选 | 保留字段。**当前被忽略**：不支持执行入口 |
| `homepage` | string | 可选 | `https://` 链接，展示用 |
| `assets` | string[] | 可选 | 声明式资产清单（当前由加载器按扩展名自动收集） |
| `ui_extensions` | object[] | 可选 | 声明式 UI 按钮（槽位 / 图标 / 内联提示词），见 3.8 |

未知字段**会被保留**（`PluginManifest.raw` 原样存进 `plugins.manifest`），
但不会被解释——请不要靠未知字段实现功能。

### 3.3 能力白名单（`capabilities`）

| 能力 | 语义 | 实现侧 |
|---|---|---|
| `kb.search` | 检索知识库，给 AI 出题/解释提供资料 | `KbService.search` |
| `kb.read` | 读取某篇知识库文档全文 | `KbService.listDocuments` + 内容查询 |
| `question.generate` | 基于知识库生成题目 | `GeneratorAgent` + `AIService` |
| `bank.export` | 导出题库 | `BankFileService.exportBank` |
| `question.tag` | 给题目打知识点标签 | `AIService.tagKnowledgePoint` |
| `notes` / `backlinks` / `graph` | 双链笔记能力（内置插件声明） | `NotesService` |
| `companion` / `chat` / `encouragement` | 助教能力（内置插件声明） | `CompanionService` |
| `schedule` / `todo` | 日程待办能力（内置插件声明） | `ScheduleService` |

第三方插件原则上只用前五项；后三组是内置插件的声明，第三方写上也不会获得实现。

### 3.4 `manifest.json` 与 `plugin.json`

两者**等价**：加载器先找 `plugin.json`，找不到再找 `manifest.json`
（`PluginLoader.manifestCandidates`）。历史插件包不用改名；
新插件按本文写 `manifest.json` 即可，两个文件同时存在时以 `plugin.json` 为准。

### 3.5 校验与安全约束（客户端强制）

- **路径穿越**：zip 条目或目录相对路径含 `..`、或以 `/` 开头 → 直接跳过（不落盘）。
- **体积**：单次同步/包体上限 64MB（`SyncServer.maxBodyBytes`）；插件的知识库文档建议 < 5MB。
- **来源**：登记表下载域名白名单（github.com / objects.githubusercontent.com /
  raw.githubusercontent.com / codeload.github.com / release-assets.githubusercontent.com），
  且必须 `https`；安装前**重算 sha256**，不一致即拒绝。
- **id 一致性**：包内 `manifest.id` 必须与登记表 `id` 相同，否则拒绝安装。
- **原子安装**：先解到 staging，校验通过才替换正式目录，失败不留半装状态。
- **已确认免责声明**：`PluginRegistryService.hasAcceptedDisclaimer()` 为 false 时不允许安装。

### 3.6 最小可用插件（可直接抄）

`manifest.json`

```json
{
  "id": "com.example.pathology-helper",
  "name": "病理学助教",
  "version": "1.0.0",
  "author": "你的名字",
  "description": "用教材口径讲解病理题，出题风格偏临床",
  "capabilities": ["kb.search", "question.generate"],
  "license": "AGPL-3.0",
  "syncable": false
}
```

`prompt.md`（会被当作系统提示词注入到解析 / 追问 / 自动出题）

```markdown
你是病理学带教老师。解释题目时先给结论，再给机制，最后给易错点。
只依据知识库资料作答；资料不足时明确说「资料未覆盖」，不要编造。
```

`sample_bank.json` 与题库导出格式一致（见 `docs/插件开发指南.md` 第 5 节）。

### 3.7 功能模板 `prompts/*.md`（v1.37 · 宿主代劳）

`prompt.md` 管「说话风格」，`prompts/*.md` 管「一次具体功能」：模板里写占位符，
主程序查好数据再填进去。插件**始终拿不到**数据库句柄、网络与文件权限——
它只提供文本，执行与取数都在宿主侧（`lib/services/plugins/plugin_prompt_service.dart`）。

```
com.example.pathology-helper/
├── manifest.json
├── prompt.md              # 进 system 消息的追加块（不是替换）
└── prompts/
    └── cheat_sheet.md     # 「考前小抄」模板
```

`prompts/cheat_sheet.md`（错题本右上角 ✨ 按钮会消费这份模板）：

```markdown
按下面的错题做一份考前小抄，范围：{{SCOPE}}，日期：{{DATE}}。

要求：
- 按知识点分组，每组先给一句「一句话记住」，再列不超过 3 个易错点；
- 只写这些题涉及的内容，不要扩展；资料不足时写「资料未覆盖」。

薄弱知识点：{{KNOWLEDGE_POINTS}}

错题（共 {{ERROR_COUNT}} 道）：
{{ERROR_QUESTIONS}}
```

宿主可填的槽位（`cheat_sheet`）：

| 槽位 | 内容 |
| --- | --- |
| `{{ERROR_QUESTIONS}}` | 错题正文：题干 / 选项 / 正确答案 / 解析 / 错了几次（已去掉图片占位符） |
| `{{ERROR_COUNT}}` | 本次塞进模板的错题数（当前上限 10 道，按「错得最多」排序） |
| `{{SCOPE}}` | 当前筛选范围，如「错题 · 2 个题库」 |
| `{{DATE}}` | 本地日期 `2026-11-01` |
| `{{KNOWLEDGE_POINTS}}` | 错题本知识点面板的当前口径（前 6 项，形如「病理学（12 题）、…」） |

约定与限制：

- **模板名等价**：`cheat_sheet` / `cheat_sheet.md` / `prompts/cheat_sheet.md` 都指向同一份；
- **未知槽位原样保留**（`{{GRADE}}` 之类会照原样出现在提示词里，方便发现自己写错名字）；
- **模板缺失不降级**：没有已启用插件提供该模板时，按钮只提示「去插件市场装插件」，
  不会偷偷换回宿主提示词（否则用户会误以为插件生效了）；
- **限长**：单文件 ≤ 256KB；`prompt.md` 每插件 1200 字、全部合计 3000 字、最多消费 5 个插件；
- **净化**：疑似「忽略以上指令 / 切换身份 / 输出系统提示词 / 伪造角色前缀」的行整行丢弃；
- **只追加**：插件文本永远是宿主底线提示词之后的一段，改不了身份、底线规则与输出格式；
- **结构化输出不吃插件提示词**：解析取 JSON、知识点打标签、学科分类仍只发宿主提示词
  （掺进讲解风格只会降低 `jsonDecode` 成功率）。

验收：把模板里的错题上限改成 3 道 → 进错题本点 ✨ → 小抄只覆盖 3 道错题，且
`{{...}}` 一个都不剩；停用插件后按钮改为提示安装，不生成内容。

### 3.8 UI 扩展 `ui_extensions`（v1.38 · 契约驱动）

清单里的 `ui_extensions` 让插件在**宿主已实现的槽位**里加一个图标按钮。按钮的
渲染、取数、填槽、AI 请求与结果弹层全部由宿主完成；插件只提交 JSON：

```json
{
  "ui_extensions": [
    {
      "slot": "quiz_analysis_actions",
      "label": "深度解析",
      "icon": "psychology",
      "action": {
        "type": "ai_prompt",
        "contexts": ["question_text", "question_options", "correct_answer"],
        "prompt_template": "请用病理学带教的口径解析这道题：\n{{QUESTION_TEXT}}\n选项：\n{{QUESTION_OPTIONS}}\n正确答案：{{CORRECT_ANSWER}}",
        "renderer": "bottom_sheet_foldable"
      }
    }
  ]
}
```

| 字段 | 类型 | 规则 |
|---|---|---|
| `slot` | string | 只认 `quiz_analysis_actions`（答题页解析区）/ `error_book_actions`（错题本右上角） |
| `label` | string | 按钮 tooltip，≤ 24 字；超长整条丢弃 |
| `icon` | string | 宿主图标白名单（`psychology` / `lightbulb` / `school` / `quiz` / `auto_awesome` / `menu_book` / `tips_and_updates` / `translate` / `summarize` / `checklist` / `insights`），未知值回退为扩展图标 |
| `action.type` | string | 只认 `ai_prompt`；其它动作整条丢弃（不做反射调用） |
| `action.contexts` | string[] | 只采集声明过的切片，最多 8 个，见下表 |
| `action.prompt_template` | string | 必填，≤ 8000 字；宿主填槽后作为 **user** 消息 |
| `action.renderer` | string | `bottom_sheet`（默认）/ `bottom_sheet_foldable`（按 `<!--ANSWER_START-->` 折叠答案） |

可声明并填进模板的上下文（未声明的数据宿主**一个字节都不给**）：

| `contexts` | 占位符 | 内容与上限 |
|---|---|---|
| `question_text` | `{{QUESTION_TEXT}}` | 题干，3000 字 |
| `question_options` | `{{QUESTION_OPTIONS}}` | `A. …` 逐行，合计 1200 字 |
| `correct_answer` | `{{CORRECT_ANSWER}}` | 正确答案，200 字 |
| `user_answer` | `{{USER_ANSWER}}` | 本次作答，200 字 |
| `analysis` | `{{ANALYSIS}}` | 当前 AI 解析 / 题目自带解析，1600 字 |
| `knowledge_point` | `{{KNOWLEDGE_POINT}}` | 知识点，200 字 |
| `error_questions` | `{{ERROR_QUESTIONS}}` | 错题块，最多 10 条、合计 6000 字 |
| `error_count` | `{{ERROR_COUNT}}` | 本次错题数 |
| `scope` | `{{SCOPE}}` | 当前筛选范围 |
| `knowledge_points` | `{{KNOWLEDGE_POINTS}}` | 薄弱知识点摘要，600 字 |
| `date` | `{{DATE}}` | 本地日期 `2026-11-01` |

安全边界（客户端强制）：

- **system 不可覆盖**：插件模板只作为 user 消息发出，system 仍是宿主底线提示词
  （+ 已启用插件的 `prompt.md` 追加块，见 3.7）；
- **数据防泄漏**：只按 `contexts` 采集，未知键直接忽略；图片占位符 `{{img:N}}` 一律剥掉；
- **防 Token 耗尽**：上面的单项上限 + 填槽后整段 12000 字封顶；错题最多 10 条；
- **防提示词注入**：`prompt_template` 只作为 user 消息，system 永远不可覆盖；恶意文本最多影响这一次回答，改不了程序行为；
- **UI 免责声明**：结果弹层固定显示「本结果由第三方插件生成，不代表官方观点」；
- **数量封顶**：单插件最多 8 条扩展、单槽位最多渲染 4 个按钮、全局最多 32 条。

停用插件后按钮立即消失（内存快照在启停 / 安装 / 卸载后刷新）；坏清单、未知字段
只会让该条扩展不出现，不影响 App 其它功能。

验收：装上声明了 `quiz_analysis_actions` 的插件 → 答题后解析区出现图标按钮 →
点开流式生成结果且带免责声明；把 `contexts` 里的 `correct_answer` 删掉 →
请求里不再出现 `{{CORRECT_ANSWER}}` 对应的内容。


---

## 4. 动态加载能力：现状与「最小可用」实现方案

### 4.1 现状

**已落地声明式 UI 扩展（§3.8）**：插件可在宿主已实现的槽位（答题页解析区 /
错题本右上角）声明图标按钮，动作限 `ai_prompt`——宿主负责取数、填槽、请求与
渲染。除此之外**没有**动态代码加载：没有 Dart 热加载、没有 WASM/JS 运行时、
没有 dlopen、没有外部主题包，插件仍然不会新增任意可执行行为。

因此下面的方案都是从零开始的最小路径，按成本从低到高排列。

### 4.2 方案 A：资源包热插拔（**推荐先做，1~2 天，零新依赖**）

目标：让**外部目录**里的插件（不需要打 zip、不需要重启）在 App 里立刻可见/可停用，
并且能让插件的**资产**被真正消费（提示词进 AI、示例题库一键导入）。

落地步骤：

1. **监听插件根目录**：`PluginRegistryService.pluginRoot()` 下每个子目录都当插件。
   ```dart
   // lib/services/plugins/plugin_loader.dart（新增）
   static Future<List<LoadedPlugin>> scanInstalled(String root) async {
     final dir = Directory(root);
     if (!dir.existsSync()) return const [];
     final out = <LoadedPlugin>[];
     for (final e in dir.listSync()) {
       if (e is! Directory) continue;
       try {
         out.add(await loadFromDirectory(e.path));
       } catch (_) {
         // 坏包不能拖垮整次扫描：跳过并记日志
       }
     }
     return out;
   }
   ```
2. **清单热更新**：扫描结果与 `plugins` 表 diff，新增的插入、版本变的更新、
   目录消失的标 `enabled = false`（**不物理删**，用户数据/启停状态不动）。
3. **资产消费点**（这是「真正生效」的关键，缺一不可）：
   - `prompt.md` → 进 `AIService._analysisPrompt` / `_followUpPrompt` 的 system 段；
   - `kb/*` → 用户在插件详情点「导入知识库」→ `KbService.importDocument`；
   - `sample_bank.json` → 点「导入示例题库」→ `BankFileService.parseJsonFile`。
4. **验收**：改 `prompt.md` → 重新扫描 → 下一次 AI 解析口径变化；
   删掉目录 → 列表里变灰（不崩、不丢数据）。

优点：不动执行模型，风险为零，直接把「声明式插件」变成**可迭代**的。
缺点：仍然只能改提示词与资产，不能加新界面/新算法。

### 4.3 方案 B：声明式 UI DSL（1~2 周）

> 状态（v1.38）：已落地**最小子集**——`ui_extensions` 的固定槽位 + `ai_prompt`
> 动作，见 §3.8。下面的 `pages / blocks` 任意控件树仍未实现（那需要另一套
> 白名单渲染器与变量作用域，当前没有明确需求）。

目标：插件能在「插件详情页」渲染**自定义卡片**（表单、列表、按钮），
但控件与动作都在白名单内，仍然是数据不是代码。

`manifest.json` 追加：

```json
{
  "pages": [
    {
      "id": "main",
      "title": "病理学助教",
      "blocks": [
        {"type": "text", "value": "选一个章节开始："},
        {"type": "select", "id": "chapter", "options": ["炎症", "肿瘤"]},
        {"type": "button", "label": "生成 10 题", "action": "generate_questions",
         "args": {"chapter": "{{chapter}}", "count": 10}}
      ]
    }
  ]
}
```

渲染器草案（只允许白名单控件，未知 type 渲染成 `SizedBox.shrink()`）：

```dart
Widget buildBlock(Map<String, dynamic> b, BuildContext ctx) {
  switch (b['type']) {
    case 'text':
      return Text(b['value']?.toString() ?? '');
    case 'select':
      return DropdownButtonFormField<String>(
        items: [for (final o in (b['options'] as List? ?? const []))
          DropdownMenuItem(value: '$o', child: Text('$o'))],
        onChanged: (v) => _vars[b['id']] = v,
      );
    case 'button':
      return FilledButton(
        onPressed: () => _runAction(b['action'], b['args']),
        child: Text(b['label']?.toString() ?? ''),
      );
    default:
      return const SizedBox.shrink();
  }
}
```

动作白名单（**每个都要显式实现，不做反射调用**）：
`generate_questions`（走 `GeneratorAgent`）、`import_sample_bank`、`search_kb`、
`tag_knowledge_points`、`open_notes`。

约束：变量只允许 `{{id}}` 形式、只读；不允许表达式、循环、网络、文件路径。

### 4.4 方案 C：脚本沙箱（3~4 周，需评估依赖与包体）

只有确实要「插件自带算法」时才值得做。建议形态：

- 运行时：WASM（`wasm3` / `wasmtime` 的 Dart FFI 绑定）或 QuickJS；
  **不要**用 `Process.run('dart')`（等于开任意代码执行的后门）。
- 权限声明写进清单：`permissions: ["kb.read", "bank.read"]`，
  安装页逐条展示，用户逐条授权；未授权的能力调用**直接拒绝**并写日志。
- 资源上限：CPU ≤ 200ms/调用、内存 ≤ 32MB、无网络（默认断网）、无文件系统
  （只能通过宿主 API 读白名单数据）。
- 通信：只有一个入口 `fn run(input_json) -> output_json`，
  宿主侧做 schema 校验（JSON Schema 手写校验即可，不引第三方）。

风险清单：包体（WASM 运行时 1~3MB）、ABI 兼容、沙箱逃逸、
Android 各 ABI 打包、审核成本（沙箱 ≠ 安全，仍需人工审核高危能力）。

### 4.5 建议路线

```
A（资源包热插拔 + 资产消费）  →  B（声明式 UI，动作白名单）
      ↑ 立刻可用，风险为零            ↑ 覆盖 80% 「想要个界面」的诉求
                                                    ↓ 只有明确算法需求才继续
                                              C（WASM 沙箱 + 权限模型）
```

### 4.6 验收清单（任何方案落地前都要跑一遍）

- [ ] 恶意 zip：`../evil.md`、绝对路径、超大文件 → 被拒绝且不留残留文件
- [ ] 坏清单：缺 `id` / `version` 非法 / `capabilities` 非数组 → 安装失败并提示原因
- [ ] id 冲突：装同 id 新版本 → 覆盖内容但**保留用户启停状态**
- [ ] 未确认免责声明 → 不允许安装
- [ ] sha256 不匹配 → 拒绝安装（并清 staging）
- [ ] 关闭插件后：入口消失、数据仍在（再打开能恢复）
- [ ] 插件数据同步：本机关掉「插件内容同步」不影响对端选择
- [ ] 全流程无阻塞主 isolate（>16ms 的操作要么异步要么 `compute`）

---

## 5. FAQ

**Q：我能写一个插件给题库加字段吗？**
不能。`questions` 表结构由 `DatabaseService` 的迁移管理（当前 `schemaVersion = 17`），
插件无法 ALTER TABLE。需要新字段请提交 issue，走 App 版本升级。

**Q：插件能发网络请求吗？**
不能（没有代码执行）。若需要「拉取远程题库」，请把数据放进插件资产，
或让用户用「导入题库 → 从 URL」的内置入口。

**Q：主题怎么办？**
主题是内置预设（`ThemeService`）。想加配色请改 `lib/theme/`（或对应主题文件）并提 PR，
外部主题包不在规划内。

**Q：插件数据会不会被同步到别人设备？**
只有 `syncable: true` 且本机勾选了对应范围才会；「只同步题库（分享给别人用）」模式
**一律不带**插件内容。

**Q：为什么我的 `manifest.json` 不被识别？**
确认它位于包根目录（不是 `my-plugin/manifest.json` 多套一层），
且 `id`/`name`/`version` 齐全；加载器会优先找同目录的 `plugin.json`。

---

维护约定：新增能力 / 新增清单字段 / 改目录结构，必须同步更新本文与
`docs/插件开发指南.md`，并在 `CHANGELOG.md` 的「新增/升级说明」里写明。

