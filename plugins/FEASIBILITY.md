# 可行性评估：小抄生成器 / 变体题生成器

> 评估基准：App v1.36.0（`pubspec.yaml`）、文档 `PLUGIN_DEVELOPMENT.md`（v1.35.4）、
> 代码 `NatsumeQuizMaster-main/lib/services/plugins/`（`plugin_loader.dart` / `plugin_registry.dart` / `world_service.dart`）。
>
> **结论先行**：这两件事需要的**数据接口和 AI 接口在宿主内部全都存在**，
> 但「插件」这一层**拿不到**它们——当前插件是**声明式包**（清单 + 提示词 + 资产），
> 不执行代码、不注入 UI。所以两个插件都按「**声明式包 + 降级交互**」交付，
> 并把宿主侧那几段缺失的胶水代码写成了明确的改造清单（§6）。

---

## 状态更新（v1.38 落地后 · 2026-11）

宿主侧补齐了「插件 → 宿主」的那一小段通道，本文的几条结论因此**反转**，两个插件也已按新契约
改成 1.1.0（详见各自 `README.md` 第 3 节）：

| 本文原结论 | 现在的状态 |
| --- | --- |
| UI 插槽 ❌ 不支持（§3.1） | ✅ `ui_extensions` 可在 `quiz_analysis_actions`（答题页解析区）/ `error_book_actions`（错题本右上角）挂图标按钮，动作限 `ai_prompt` |
| `prompt.md` 无消费点（§3.3） | ✅ 进 system 消息的追加块（`AIService.effectiveSystemPrompt`）：每插件 1200 字、合计 3000 字上限 |
| `prompts/*` 模板无消费点（§2.1） | ✅ 宿主按名字取模板并填槽（`PluginPromptService.render`）；错题本 ✨ 入口消费 `cheat_sheet` |
| 插件拿不到当前题目（§3.2） | ⭕ 部分解开：声明 `question_text` / `question_options` / `correct_answer` / `analysis` / `knowledge_point` 即拿到对应切片（仍拿不到整库、图片与文件） |
| 分享 ❌ / PDF ❌ / `.md` 只能另存（§2.2） | 不变。结果弹层给「复制」「保存为 .md」，走 `ExportStorage.saveAsBytes` |
| 需要 §6 的 P0–P2（约 2.5 天） | ✅ 已由宿主 v1.37 / v1.38 实现，插件侧不再依赖任何改造 |

仍未改变的红线：插件不执行代码、没有网络与文件权限、不能新增「已实现槽位之外的界面控件」。

## 0. 结论速览

| # | 问题 | 结论 | 卡在哪一步 |
| --- | --- | --- | --- |
| 1 | 插件一能否读「错题本 / 薄弱知识点统计」 | **接口可行，插件不可行** | 数据 API 齐全，但插件无代码执行、`LoadedPlugin` 的资产还没有消费点 |
| 2 | 插件一能否触发分享 / 保存文件 / 调 PDF·Markdown 导出 | **分享 ❌ · 保存 ⭕（宿主代劳）· PDF ❌ · Markdown ❌（只能另存）** | v1.34 已移除 `share_plus`；宿主只有 JSON / DOCX 导出 |
| 3 | 插件二能否在解析页注入按钮 | **❌ 不支持** | 没有 UI 插槽；解析卡按钮是宿主写死的 |
| 4 | 插件二能否拿到当前题目上下文 | **宿主能，插件不能** | `AppState.currentQuestion` 是宿主私有状态，无插件通道 |
| 5 | 插件二能否直接调宿主 AI + 自定义 Prompt | **宿主能，插件不能** | `AIService` 是 Dart 成员；且 `prompt.md` 还没接进提示词拼接 |
| 6 | 降级后能不能真的用起来 | **能（见 §5）** | 靠「复制 / 粘贴 / 另存为」三件套，零改造或 ~0.5 天改造 |

## 1. 判断依据：插件体系现在的真实能力边界

1. `PLUGIN_DEVELOPMENT.md` §0 明确三件事都不支持：**代码插件 ❌、主题包 ❌、UI 插槽 ❌**；
   §4.1 再次写明「没有实现动态加载：没有 Dart 热加载、没有 WASM/JS 运行时、没有 dlopen」。
2. 加载器的产出物是 `LoadedPlugin(manifest, prompt, assets, installedDir)`
   （`plugin_loader.dart:53`）——**纯数据**。
3. 全量搜 `LoadedPlugin`：只在 `lib/services/plugins/*` 内部出现
   （`plugin_registry.dart:326/346/468/511/640`、`world_service.dart:170`），
   **`prompt.md` / `kb/*` / `sample_bank.json` 目前没有任何消费点**。
   也就是说文档 §4.2「方案 A：资源包热插拔 + 资产消费」还没落地，
   插件装完的实际效果 = **多一条登记 + 可启停**，没有行为变化。
4. 既然没有代码执行，能力字符串（`capabilities`）就只是「声明 + 展示」：
   白名单里 `bank.export` / `question.generate` 映射到的是**宿主内置函数**，
   第三方插件写上不会获得实现（`PLUGIN_DEVELOPMENT.md` §3.3 已注明）。

## 2. 插件一：`cheat-sheet-generator`

### 2.1 能否读「错题本数据」与「薄弱知识点统计」

**宿主内部：完全可行，接口齐。**

| 需要的数据 | API | 位置 |
| --- | --- | --- |
| 错题明细 + 逐题作答统计 | `getErrorQuestionsWithStats(mode, {bankIds, questionIds, knowledgePoint, window, recentFirst})` | `database_service.dart:3293` |
| 错题全量列表 / 数量 | `getFullErrorQuestions(mode, {bankIds})` / `getFullErrorCount(...)` | `:2267` / `:2284` |
| 薄弱知识点分布（知识点 · 题数） | `getKnowledgePointStats(mode, {bankIds})` | `:2302` |
| 各题库正确率 | `StatsService.getBankAccuracies()` | `stats_service.dart:20` |
| 按知识点取题 | `getFullQuestionsByKnowledgePoint(kp, mode, {bankIds})` | `:2333` |

口径细节（照抄这段能避免踩坑）：

- `mode` = `all` / `wrong` / `bookmark`，与错题本列表**同一套 SQL**；
- `window: '7d'` 是**按最近一次作答时间**过滤，不是按错题创建时间；
- 空知识点在统计里被合并为「未打标签」，按字面量匹配会命中 0 行（`database_service.dart:3388` 有相同注释）。

**插件层：不可行。** 三条理由都要同时成立才算「可行」，这里三条都不成立：

1. 插件没有代码执行能力，无法调用任何 Dart 成员；
2. `LoadedPlugin` 没有「回调宿主」的口子，宿主也没有对插件暴露的 query API；
3. 即便把数据塞进 `assets`，也没有代码去读它。

→ **结论：能力在，通道没有。** 本次交付用「宿主导出 + 提示词模板」的方式绕过（§5 档 A/B/C）。

### 2.2 能否触发系统分享 / 保存文件 / 调 PDF·Markdown 导出

| 动作 | 宿主是否有 | 插件能否触发 | 证据 |
| --- | --- | --- | --- |
| 系统分享面板 | **❌ 已移除** | ❌ | `pubspec.yaml:48`「share_plus 已移除（v1.34：导出改用 ExportStorage 的「另存为」）」 |
| 「另存为」写文件 | ✅ | ❌（宿主可代劳） | `export_storage.dart:86 saveAsBytes` / `:143 saveFileAs` |
| 错题导出 JSON | ✅ | ❌ | `app_state.dart:2609 exportErrorQuestionsJson` |
| 错题导出 DOCX（两种答案排布） | ✅ | ❌ | `app_state.dart:2723 exportErrorQuestionsDocx`、`error_book_screen.dart:524-530` |
| **PDF 导出** | **❌ 不存在** | ❌ | `pdfrx` 只用于阅读导入的 PDF；`pdf_import_service.dart` 是导入方向 |
| **Markdown 导出** | **❌ 无专用导出** | ❌ | 只能借 `saveAsBytes` 的 `md → text/plain` 分支（`export_storage.dart:167`） |
| 剪贴板 | ✅ | ❌ | `error_book_screen.dart:791/822`、`settings_screen.dart:1462` 已在用 `Clipboard.setData` |

要点：

- **「保存」这条是通的，只是要宿主自己调**：
  `ExportStorage.saveAsBytes(utf8.encode(md), fileName: '考前小抄.md')`
  在桌面与 Android 都会走原生「另存为」；用户取消时返回 `path == null`（不要弹成功提示）。
- **PDF 真没有**：要做 PDF 得先引入生成库或把 DOCX 转 PDF，属于 App 版本级改动，不进插件范围。
- **Markdown 也真没有**：现有导出只有 `.json`（题库 / 错题）与 `.docx`（打印稿）。

### 2.3 结论与本次交付形态

- 插件本体：`manifest.json` + `prompt.md`（AI 口径）+ `prompts/cheat_sheet.md`（主模板）+
  `prompts/cheat_sheet_card.txt`（掌心卡）+ `kb/cheat-sheet-style-guide.md`（写作规范）+ `sample_bank.json`。
- 可执行的降级交互：**复制提示词 / 复制错题 JSON / 另存为 .md**，以及宿主内「弹窗生成」的目标形态
  （详见 `cheat-sheet-generator/README.md` §5）。

## 3. 插件二：`variant-generator`

### 3.1 能否在「题目解析页面」注入一个按钮

**❌ 不支持，且是有意为之。**

- `PLUGIN_DEVELOPMENT.md` §0 与 §2.7 两张表都写死：UI 插槽只有内置插件的**固定入口**
  （世界总览 / 我的 → 学习工具），第三方**不能**自定义控件。
- 解析卡上的入口是宿主硬编码的两个：`_buildChatEntry`（向 AI 追问，`quiz_screen.dart:1761`）
  与 `_buildNoteEntry`（随手记，`:1729`）。插件没有任何挂载点。

可行替代：按文档 §4.3「方案 B：声明式 UI DSL」由宿主解析 `pages/blocks` 里的
`button + action`，动作实现在宿主白名单里（不做反射）。这也是本插件 §5 档 C 的方案。

### 3.2 能否拿到当前题目的题干 / 正确答案 / 知识点

**宿主能，插件不能。**

- 宿主侧现成：`AppState.currentQuestion`（`Question`），字段为
  `title` / `options` / `correctAnswer` / `knowledgePoint` / `analysis` / `questionType`
  （`lib/models/question.dart:5-19`）；解析页就在用它（`quiz_screen.dart:1700`）。
- 插件侧：没有获取通道。`LoadedPlugin` 只有静态资产，宿主也不会把 `currentQuestion` 交给插件。

→ 降级：**复制题干 → 粘贴进插件输入框**（§5 档 A/B）。

### 3.3 能否直接调宿主 AI，发一次带自定义 Prompt 的请求

**宿主能，插件不能；而且「插件自带 Prompt」这半条也还没接上。**

- 宿主 AI 面：`AIService.streamAnalysis / askFollowUp / generateWeaknessAnalysis /
  generateSessionSummary / tagKnowledgePoint / generateKpAdvice / callWithTools`
  （`ai_service.dart:1039 / 1115 / 1147 / 1181 / 1218 / 1386 / 1717`）。
- 但提示词是**宿主固定拼接**的：`_analysisPrompt`（`:1458`）与 `_followUpPrompt`（`:1121`），
  里面**没有读取 `LoadedPlugin.prompt`**——这正是文档 §4.2 步骤 3 说的「资产消费点，缺一不可」，
  目前一个都没接。
- 因此「插件提示词改变 AI 口径」这件事，**文档承诺了、代码还没做**。

→ 本次交付把提示词写成**可直接注入的模板 + 可直接粘贴的自包含版本**，
宿主一接上就能用，接上之前也能用。

### 3.4 结论与本次交付形态

- 插件本体：`manifest.json` + `prompt.md` + **`prompts/generate_variant.txt`（重点）** +
  `prompts/generate_variant_manual.txt`（自包含降级版）+ `kb/variant-design-principles.md`。
- 输出契约：`<!--VARIANT_META …-->` 声明考点 / 陷阱 / 难度，
  `<!--ANSWER_START--> … <!--ANSWER_END-->` 包住答案，宿主按 HTML 注释切分即可实现「答案默认收起」。

## 4. 三个「能」、三个「不能」

**能（今天，零改造）**

- 装包、启停、在世界总览看到条目与能力声明；
- 把插件资产（提示词 / 写作规范 / 示例题库）当**文本**用：复制、粘贴、导入知识库、导入示例题库；
- 用宿主已有的「错题导出（JSON / DOCX）」「另存为」把结果落到文件。

**不能（今天，需要宿主改造）**

- 插件读写数据库、调用 `AIService`、发起网络请求；
- 插件在任意界面插入控件；
- 插件写文件 / 触发分享（`share_plus` 已移除，且插件无代码执行）。

## 5. 两个插件的降级方案（对比）

| | 档 A（零改造，今天可用） | 档 B（宿主 ~0.5 天） | 档 C（宿主 1~2 天，目标形态） |
| --- | --- | --- | --- |
| 小抄 | 错题本导出 JSON → 手动填模板 → 粘到 AI → 复制结果 | 插件条目「复制提示词 / 复制错题 JSON」按钮 | 「生成小抄」弹窗：自动取知识点 + 错题 → 调 AI → 复制 / 另存 .md / 换掌心卡 |
| 变体题 | 复制题干 → 粘贴进 `generate_variant_manual.txt` → 发送 | 插件条目「出变体题」粘贴框（剪贴板预填） | 解析页「举一反三」按钮（声明式 DSL 白名单动作）→ 卡片 + 答案折叠 |

两档共同点：**插件只提供文本，宿主负责取数、调 AI、渲染**。
这条边界不破，就不需要给插件开任何执行权限。

## 6. 宿主侧最小改造清单（按成本排序）

| 优先级 | 改动 | 涉及位置 | 工时 |
| --- | --- | --- | --- |
| **P0** | 插件条目加「查看 / 复制提示词与资产」入口 | `world_overview_screen.dart` 的插件行（现在只有启停 / 删除）+ `PluginLoader.loadFromDirectory` 扫已装目录 | 0.5 天 |
| **P1** | 「生成小抄」弹窗：`getKnowledgePointStats` + `getErrorQuestionsWithStats` 填模板 → `AIService._callAI` → `showModalBottomSheet` + 复制 / 另存 | 新 widget + `export_storage.dart` | 1 天 |
| **P2** | 声明式 UI DSL（`pages/blocks`，按钮 → 白名单动作 `generate_variant`），解析页注入按钮 | `world_overview_screen.dart` 渲染器 + `quiz_screen.dart` 插槽 | 1~2 天 |
| **P3** | `prompt.md` 进系统提示词段（文档 §4.2 步骤 3） | `ai_service.dart` 的 `_analysisPrompt` / `_followUpPrompt` | 0.5 天 |
| **P4** | 变体题作答可选写回 `answer_records`（进错题本统计） | 复用 `AppState.recordAnswer` 口径 | 1 天 |

不建议做的：给插件开放代码执行 / 网络权限（安全红线，见 `PLUGIN_DEVELOPMENT.md` §1.3、§4.4）。

## 7. 验收标准（两插件共用）

- [ ] `manifest.json` 通过 `tool/validate_plugins.dart` 全绿（id / version / 能力白名单 / 资产存在性 / 示例题库格式）
- [ ] zip 包用宿主真实 `PluginLoader.loadFromZip` 能装、能读到 `prompt` 与 `prompts/*` 资产
- [ ] 模板里的槽位与 README 的槽位表一一对应（不多不少）
- [ ] 模板在「资料为空」时走「资料未覆盖 / 信息不足」分支，不硬编
- [ ] 变体题的答案整段落在 `<!--ANSWER_START-->` 与 `<!--ANSWER_END-->` 之间
- [ ] 不新增任何网络请求、不写插件目录以外的文件

## 8. 一句话回答提问

> 现在真正缺的不是数据，而是**插件到宿主的那一小段通道**。
> 两个插件已经能用「复制 / 粘贴 / 另存」跑通全流程；
> 想做到「点一下就出」，宿主侧最少需要 §6 的 P0–P2 三件事，约 2.5 天。

