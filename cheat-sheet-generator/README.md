# 考前 5 分钟小抄生成器（`natsume.cheat-sheet-generator`）

把「最近的错题 + 薄弱知识点」压成一页小抄：关键公式、避坑指南、医学口诀。
只出干货，可以复制到剪贴板，也可以另存成 `.md` 打印。

- **id**：`natsume.cheat-sheet-generator`（改 id = 换插件，用户启停状态会丢）
- **版本**：1.1.0（1.0.0 只有模板、没有 UI 入口；1.1.0 按 v1.38 契约挂上按钮）
- **能力声明**：`bank.export`、`kb.search` / `kb.read`（`capabilities` 只是声明与展示，实现都在宿主）
- **可同步**：否（小抄是消耗品，不落库、不进同步快照）
- **min_app_version**：1.38.0（`ui_extensions` 从 v1.38 起才会被解析；低版本客户端只提示升级）

## 1. 目录

```
cheat-sheet-generator/
├── manifest.json                     # 插件清单（含 ui_extensions：两个按钮 + 内联模板）
├── prompt.md                         # 进 system 消息的追加块（口径 / 铁律 / 语气）
├── prompts/
│   ├── cheat_sheet.md                # 「考前小抄」模板（与 manifest 的 prompt_template 逐字一致）
│   └── cheat_sheet_card.txt          # 「掌心卡」模板（与 manifest 的 prompt_template 逐字一致）
├── kb/
│   └── cheat-sheet-style-guide.md    # 写作规范（可导入知识库，也可供 AI 检索）
├── sample_bank.json                  # 示例题库（5 题，含知识点与解析）
└── README.md
```

打包时把**目录内容**打成 zip（不要多套一层文件夹）。仓库根目录的
`tool/build_plugins.ps1` 会自动做这件事并算好 sha256。

## 2. 安装

三条路径任选其一（详见根目录 `PLUGIN_DEVELOPMENT.md` §1.2）：

1. **本地 zip**：世界总览 → 导入插件 → 选 `natsume.cheat-sheet-generator-1.1.0.natsume-plugin.zip`。
2. **世界包**：把本目录放进 `.natsume-world` 的 `plugins/` 下一起分发。
3. **登记表**：发布到 Natsume-Registry，用户在世界总览点安装（下载地址必须是 https 的 GitHub 系域名）。

装完在**世界总览 → 插件区**能看到条目、可启停；插件启用后，错题本右上角会多出两个图标按钮。

## 3. 与主程序的对接点（v1.38 · 契约驱动）

插件不提交代码，只提交清单里的 `ui_extensions`；取数、填槽、请求、渲染全在宿主
（`lib/services/plugins/plugin_ui_extension.dart` / `plugin_action_engine.dart` /
`widgets/plugin_action_sheet.dart`）。

| 槽位 | 按钮（tooltip） | 图标 | 声明的 `contexts` | 渲染器 |
| --- | --- | --- | --- | --- |
| `error_book_actions`（错题本右上角） | 考前小抄 | `summarize` | `error_questions` / `error_count` / `scope` / `knowledge_points` / `date` | `bottom_sheet` |
| `error_book_actions` | 掌心卡 | `checklist` | `error_questions` / `error_count` / `knowledge_points` / `scope` | `bottom_sheet` |

点击后宿主做的事：

1. 按 `contexts` 采集上下文（未声明的字段**一个字节都不给**），按上限截断；
2. 把内联 `prompt_template` 里的占位符填成真实内容，作为 **user** 消息发出
   （system 仍是宿主底线提示词 + 本插件 `prompt.md` 的追加块，插件改不了）；
3. 底部弹层流式渲染，底部固定显示「本结果由第三方插件生成，不代表官方观点」；
   关掉弹层立即断流。

同时还保留了 v1.37 的模板通道：错题本右上角的「考前小抄」入口会用
`prompts/cheat_sheet.md`（模板名 `cheat_sheet` / `cheat_sheet.md` / `prompts/cheat_sheet.md` 等价）。
**两条通道发出的 user 消息逐字相同**——manifest 里的内联模板就是这两份文件的原文。
改模板时请两处一起改：先改 `prompts/*`，再把同一段内容粘进 `manifest.json` 的
`ui_extensions[].action.prompt_template`（`tool/validate_plugins.dart` 会校验占位符与 `contexts` 是否对得上）。

## 4. 模板槽位（只能用宿主白名单里的这 5 个）

| 占位符 | 内容 | 宿主上限 | 宿主取值来源 |
| --- | --- | --- | --- |
| `{{ERROR_QUESTIONS}}` | 错题块：题干 / 选项 / 正确答案 / 解析 / 错了几次 | 最多 10 条、合计 6000 字 | `getErrorQuestionsWithStats(mode, {recentFirst: true})`，按「错得最多」排序 |
| `{{ERROR_COUNT}}` | 本次塞进模板的错题数 | — | 同上（`PluginContextKeys.errorCount`） |
| `{{SCOPE}}` | 当前筛选范围，如「错题 · 2 个题库」 | 120 字 | 错题本顶部的筛选状态 |
| `{{KNOWLEDGE_POINTS}}` | 薄弱知识点口径，如「病理学（12 题）、…」 | 600 字（前 6 项） | `getKnowledgePointStats(mode, {bankIds})` |
| `{{DATE}}` | 本地日期 `2026-11-01` | 32 字 | 系统时间 |

约定：

- **写错名字没人兜底**：`{{WEAK_KPS}}` 这类非白名单槽位会被原样发给模型
  （`tool/validate_plugins.dart` 会报「槽位不是宿主能填的」警告）。
- 声明的上下文在当次页面没有数据时给**空串**（不是保留占位符），模板里的「材料为空时」
  分支就是为这种情况写的。
- 图片占位符 `{{img:N}}` 由宿主剥掉，小抄里不会出现图片。
- 填槽后整段 12000 字封顶（宿主强制），错题最多 10 道。

## 5. 数据从哪里来（对应到主程序 API）

| 需要的数据 | 现成的宿主 API | 说明 |
| --- | --- | --- |
| 薄弱知识点 + 错题数 | `DatabaseService.getKnowledgePointStats(mode, {bankIds})` | 返回 `kp` / `cnt`，空知识点已并入「未打标签」 |
| 最近错题明细 | `DatabaseService.getErrorQuestionsWithStats(mode, {bankIds, window, recentFirst})` | 每行是 `q.*` + `answered_count` / `correct_count` / `wrong_count` / `last_answered_at` |
| 各题库正确率 | `StatsService.getBankAccuracies()` | 面板上的「正确率」列 |
| 知识库资料（可选 grounding） | `KbService.search(kbId, query, {topK})` | 有资料时以资料为准，`prompt.md` 里已写明这条优先级 |
| 另存为 .md | `ExportStorage.saveAsBytes` | 结果弹层底部的「保存为 .md」走的就是它 |
| 复制到剪贴板 | Flutter `Clipboard.setData` | 结果弹层底部的「复制」 |

## 6. 验收（装完照着点一遍）

- [ ] 世界总览 → 插件区能看到条目，能力显示 `bank.export` / `kb.search` / `kb.read`，许可 AGPL-3.0
- [ ] 错题本右上角出现两个图标按钮（考前小抄 / 掌心卡）；**停用插件后立即消失**
- [ ] 点「考前小抄」→ 底部弹层流式生成 → 有「必背 / 避坑 / 鉴别 / 口诀 / 最后 3 条」五节，
      且提示词里 `{{...}}` 一个都不剩
- [ ] 弹层底部固定显示「本结果由第三方插件生成，不代表官方观点」
- [ ] 点「掌心卡」→ 输出「必背 3 条 / 两个坑 / 一句口诀」，≤ 260 字
- [ ] 错题本为空时点按钮：输出「资料未覆盖：…」而不是硬凑内容
- [ ] `dart run tool/validate_plugins.dart` → 0 错误 0 警告

## 7. 隐私

- 生成时会把**错题题干、正确答案、解析、知识点**发送到用户自己配置的模型服务。
  没有配置 Key 时不会有任何网络请求。
- 插件本身不联网、不读数据库、不在本地落文件（没有代码执行）。
- 示例题库只含公开的医学基础知识，不含任何真实病例。

## 8. 已知限制

- 只能在**宿主已实现的槽位**里出现按钮：答题页解析区（`quiz_analysis_actions`）与
  错题本右上角（`error_book_actions`）。没有「插件详情页」这种自由 UI。
- 没有 PDF 导出：宿主现有导出是 **JSON / DOCX**，`.md` 只能通过「另存为」落地。
- 系统分享面板在 v1.34 已移除（`share_plus` 被删），想「发给同学」请走「另存为 + 手动发送」。
- 口诀由模型生成，**可能是错的**。插件只负责「不许编」，不保证「一定对」，考前请以教材为准。

## 9. 变更记录

| 版本 | 变更 |
| --- | --- |
| 1.0.0 | 首个版本：一页小抄模板 + 掌心卡模板 + 写作规范 + 5 题示例题库（只有模板，没有 UI 入口） |
| 1.1.0 | 按 v1.38 契约对接主程序：新增 `ui_extensions`（错题本「考前小抄」「掌心卡」两个按钮，含 contexts 与内联模板）；模板槽位改为宿主白名单内的 `ERROR_QUESTIONS` / `ERROR_COUNT` / `SCOPE` / `KNOWLEDGE_POINTS` / `DATE`；移除模板开头的元注释（避免被当成正文发给模型）；`min_app_version` 提到 1.38.0 |
