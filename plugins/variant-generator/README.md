# 举一反三 · 变体题生成器（`natsume.variant-generator`）

做完一道错题、看完解析之后，用**同一个考点换一套陷阱**再出一道：答案默认收起，
先自己作答，再看解析。目的是把「这题我会了」变成「这个考点我会了」。

- **id**：`natsume.variant-generator`（改 id = 换插件，用户启停状态会丢）
- **版本**：1.1.0（1.0.0 只有模板、没有 UI 入口；1.1.0 按 v1.38 契约挂上按钮）
- **能力声明**：`question.generate` / `kb.search`（`capabilities` 只是声明与展示，实现都在宿主）
- **可同步**：否（插件不带数据；生成的变体题默认也不入库）
- **min_app_version**：1.38.0（`ui_extensions` 从 v1.38 起才会被解析；低版本客户端只提示升级）

## 1. 目录

```
variant-generator/
├── manifest.json                          # 插件清单（含 ui_extensions：两个按钮 + 内联模板）
├── prompt.md                              # 进 system 消息的追加块（命题老师人设 + 三条硬线 + 陷阱词典）
├── prompts/
│   ├── generate_variant.txt               # 「举一反三」模板（与 manifest[0] 的 prompt_template 逐字一致）
│   ├── generate_variant_from_errors.md    # 「错题变体」模板（与 manifest[1] 的 prompt_template 逐字一致）
│   └── generate_variant_manual.txt        # 手动降级版：整段复制到任意 AI 对话窗口后填题（无槽位）
├── kb/
│   └── variant-design-principles.md       # 变体题设计原则（陷阱词典 / 难度校准 / 验收）
└── README.md
```

## 2. 安装

与世界总览的其它插件一样：本地 zip（`tool/build_plugins.ps1` 打出）
→ 世界总览 → 导入插件；或随 `.natsume-world` 一起分发；或发布到登记表。

## 3. 与主程序的对接点（v1.38 · 契约驱动）

插件只提交清单里的 `ui_extensions`；取数、填槽、请求与渲染全部由宿主完成
（`plugin_ui_extension.dart` / `plugin_action_engine.dart` / `plugin_action_sheet.dart`）。

| 槽位 | 按钮（tooltip） | 图标 | 声明的 `contexts` | 渲染器 |
| --- | --- | --- | --- | --- |
| `quiz_analysis_actions`（答题页解析按钮区） | 举一反三 | `auto_awesome` | `question_text` / `question_options` / `correct_answer` / `analysis` / `knowledge_point` | `bottom_sheet_foldable` |
| `error_book_actions`（错题本右上角） | 错题变体 | `quiz` | `error_questions` / `error_count` / `scope` / `knowledge_points` | `bottom_sheet_foldable` |

`bottom_sheet_foldable` 的含义：宿主按 AI 输出里的 `<!--ANSWER_START-->` 切分——
标记之前当讲解直接展示，之后的答案与解析**默认折叠**，点「展开查看答案」才出现。
所以模板里的这个标记是硬契约，不能改写法。

点击后宿主做的事：

1. 按 `contexts` 采集上下文（未声明的字段一个字节都不给），按上限截断、剥掉图片占位符；
2. 把 `prompt_template` 的占位符填成真实内容，作为 **user** 消息发出
   （system 仍是宿主底线提示词 + 本插件 `prompt.md`）；
3. 底部弹层流式渲染：讲解区 + 折叠的答案区 + 免责声明；关掉弹层立即断流。

改模板时请两处一起改：先改 `prompts/*`，再把同一段内容粘进 `manifest.json` 对应的
`ui_extensions[].action.prompt_template`（两者逐字相同，验收时才不会出现「按钮和模板产出不一样」）。

## 4. 模板槽位

### 4.1 「举一反三」（`prompts/generate_variant.txt`，答题页）

| 占位符 | 内容 | 宿主上限 | 宿主取值来源 |
| --- | --- | --- | --- |
| `{{QUESTION_TEXT}}` | 题干原文 | 3000 字 | `Question.title`（`AppState.currentQuestion`） |
| `{{QUESTION_OPTIONS}}` | `A. …` 逐行 | 合计 1200 字 | `Question.options` |
| `{{CORRECT_ANSWER}}` | `A` / `A,C` / 对 / 文本 | 200 字 | `Question.correctAnswer` |
| `{{ANALYSIS}}` | 当前 AI 解析或题目自带解析 | 1600 字 | 解析卡上的解析文本 |
| `{{KNOWLEDGE_POINT}}` | 知识点，空则空串 | 200 字 | `Question.knowledgePoint` |

### 4.2 「错题变体」（`prompts/generate_variant_from_errors.md`，错题本）

| 占位符 | 内容 | 宿主上限 | 宿主取值来源 |
| --- | --- | --- | --- |
| `{{ERROR_QUESTIONS}}` | 错题块：题干 / 选项 / 正确答案 / 解析 / 错了几次 | 最多 10 条、合计 6000 字 | `getErrorQuestionsWithStats(mode, {recentFirst: true})` |
| `{{ERROR_COUNT}}` | 本次错题数 | — | `PluginContextKeys.errorCount` |
| `{{SCOPE}}` | 当前筛选范围 | 120 字 | 错题本筛选状态 |
| `{{KNOWLEDGE_POINTS}}` | 薄弱知识点口径（前 6 项） | 600 字 | `getKnowledgePointStats(mode, {bankIds})` |

约定：

- 只有**在 `contexts` 里声明过**的上下文才会被采集；模板里写错名字（如
  `{{STEM}}` / `{{OPTIONS}}` / `{{ERROR_HISTORY}}`）会被原样发给模型。
  `tool/validate_plugins.dart` 会检查「模板用到的占位符 ⊆ contexts 声明的上下文」。
- 声明的上下文在当次页面没有数据时给**空串**，模板里的「信息不全」分支就是为这种情况写的。
- `prompts/generate_variant_manual.txt` **不含槽位**：它是自包含的手动版（§7 档 A），
  整段复制到任意对话窗口后填「【原题】」即可。

## 5. 输出契约（宿主按标记切分，必须一致）

```
<!--VARIANT_META {"kp":"…","trap":"T3","difficulty":"same","base_type":"single_choice"}-->
## 变体题 · <知识点>
### 题干 / ### 选项 / ### 作答
<!--ANSWER_START-->
### 答案与解析
<!--ANSWER_END-->
```

宿主侧处理规则（`plugin_action_sheet.dart`）：

1. 输出里第一个 `<!--ANSWER_START-->` **之前**的正文 → 直接展示；
2. 它**之后**的正文 → 默认折叠，点开才显示；
3. `<!--ANSWER_END-->` 只是给人看的收尾标记，宿主不解析；
4. 标记缺失 → 整段原样渲染（不折叠），此时说明模型没按格式输出，可「重新生成」。

## 6. 数据从哪里来（对应到主程序 API）

| 需要的数据 | 现成的宿主 API |
| --- | --- |
| 当前题目的题干 / 选项 / 答案 / 知识点 / 解析 | `AppState.currentQuestion`（`lib/models/question.dart`） |
| 该题错了几次 | `getErrorQuestionsWithStats(...)` 的 `wrong_count` |
| 错题块（错题本入口） | `getErrorQuestionsWithStats(mode, {recentFirst: true})` |
| 薄弱知识点（错题本入口） | `getKnowledgePointStats(mode, {bankIds})` |
| 知识库约束（可选） | `KbService.search(kbId, query, {topK})` |

## 7. 降级路径（AI 未配置 / 旧版本客户端）

### 档 A：手动粘贴（零改造，任何版本都能用）

1. 解析页展开解析，长按选中题干与选项 → **复制**。
2. 打开 `prompts/generate_variant_manual.txt`，整段复制到任意 AI 对话窗口
   （App 追问页 / 网页版助手都行）。
3. 在最后的「【原题】」下粘贴题干、选项、正确答案、知识点（有几项填几项），发送。
4. 答案在 `<!--ANSWER_START-->` 之后，先自己作答再看。

### 档 B：v1.37 模板通道

宿主的通用模板接口（`PluginActionEngine.streamTemplate` / `AIService.streamPluginTask`）
可以直接消费 `generate_variant` / `generate_variant_from_errors` 这两份模板，
填槽用同一套上下文（`PluginActionContext.select`），产出与按钮通道一致。

## 8. 验收（装完照着点一遍）

- [ ] 答题页展开解析 → 解析按钮区出现「举一反三」图标；停用插件后立即消失
- [ ] 点它生成的变体题：题干 / 选项先展示，答案区默认折叠，点「展开查看答案」才出现解析
- [ ] 输出第一行是 `<!--VARIANT_META …-->`，JSON 能解析；`trap` 编号在解析里有对应说明
- [ ] 错题本右上角出现「错题变体」；点它只出**一道**变体题（原题 = 错得最多的那道）
- [ ] 弹层底部固定显示「本结果由第三方插件生成，不代表官方观点」
- [ ] 题干 / 知识点缺失时：首行出现 `⚠️ 信息不全：…`，而不是编一个考点
- [ ] `dart run tool/validate_plugins.dart` → 0 错误 0 警告

## 9. 隐私

- 生成时会把**题干、选项、正确答案、解析、知识点**发送到用户自己配置的模型服务。
- 插件不联网、不读库、不在本地落文件；不把题目写进任何同步快照。
- 变体题默认**不写入题库**：避免污染「错题数 / 正确率」这类统计口径。
  确实想留着练，用「导出错题 → JSON」的方式手动保存。

## 10. 已知限制

- 模型偶尔会「换考点」而不是「换陷阱」：模板里用「陷阱编号 + 自检」压制，但无法保证 100%；
  发现跑偏请点「重新生成」。
- 模型可能编造指南推荐 / 剂量：模板明令禁止，仍需人工核对（医学题的常识）。
- 超长题干（> 2000 字）会让小模型丢细节，建议分次出题。
- 图片题：模板让模型用文字描述配图，**不会**把图片发给模型（插件没有图片通道）。
- 变体题结果不写回 `answer_records`：宿主当前没有「插件结果入库」的通道。

## 11. 变更记录

| 版本 | 变更 |
| --- | --- |
| 1.0.0 | 首个版本：主模板（8 类陷阱 + 输出契约 + 自检）+ 手动粘贴降级模板 + 设计原则 |
| 1.1.0 | 按 v1.38 契约对接主程序：新增 `ui_extensions`（解析页「举一反三」+ 错题本「错题变体」，折叠渲染器）；模板槽位改为宿主白名单内的 `QUESTION_TEXT` / `QUESTION_OPTIONS` / `CORRECT_ANSWER` / `ANALYSIS` / `KNOWLEDGE_POINT` / `ERROR_QUESTIONS` / `ERROR_COUNT` / `SCOPE` / `KNOWLEDGE_POINTS`；新增 `prompts/generate_variant_from_errors.md`；移除模板开头的元注释；`min_app_version` 提到 1.38.0 |
