/// 声明式插件 UI 扩展（契约驱动 · v1.38）。
///
/// 插件只能提交「挂在哪个槽位、按钮叫什么、点完用哪些上下文切片、填哪份模板」，
/// 控件、取数、请求与渲染全部由宿主实现。解析采用白名单：槽位 / 动作类型 /
/// 上下文 / 渲染器只要有一个不认识，就丢弃该扩展而不是猜它的含义。
library;

/// 允许第三方挂载的 UI 槽位（宿主页面里已实现的锚点）。
abstract final class PluginSlots {
  static const String quizAnalysisActions = 'quiz_analysis_actions';
  static const String errorBookActions = 'error_book_actions';

  static const Set<String> all = {
    quizAnalysisActions,
    errorBookActions,
  };
}

/// 动作类型。当前只开放「模板填槽后交给 AI」，插件拿不到数据库与网络。
abstract final class PluginActionTypes {
  static const String aiPrompt = 'ai_prompt';

  static const Set<String> all = {aiPrompt};
}

/// 结果渲染器名字（渲染实现全在宿主，插件只能选名字）。
abstract final class PluginRenderers {
  static const String bottomSheet = 'bottom_sheet';
  static const String bottomSheetFoldable = 'bottom_sheet_foldable';

  static const Set<String> all = {bottomSheet, bottomSheetFoldable};

  /// 折叠分界标记：标记之前是讲解/推理，之后是最终答案。
  static const String answerStartMarker = '<!--ANSWER_START-->';
}

/// 宿主可提供的上下文切片 → 模板占位符。
///
/// 键是清单里 `contexts` 的写法；值是 `{{PLACEHOLDER}}`。没在这个表里的
/// 上下文不会被采集（防止插件通过一个不存在的键间接拿到别的数据）。
abstract final class PluginContextKeys {
  static const String questionText = 'question_text';
  static const String questionOptions = 'question_options';
  static const String correctAnswer = 'correct_answer';
  static const String userAnswer = 'user_answer';
  static const String analysis = 'analysis';
  static const String knowledgePoint = 'knowledge_point';
  static const String errorQuestions = 'error_questions';
  static const String errorCount = 'error_count';
  static const String scope = 'scope';
  static const String knowledgePoints = 'knowledge_points';
  static const String date = 'date';

  static const Map<String, String> placeholders = {
    questionText: 'QUESTION_TEXT',
    questionOptions: 'QUESTION_OPTIONS',
    correctAnswer: 'CORRECT_ANSWER',
    userAnswer: 'USER_ANSWER',
    analysis: 'ANALYSIS',
    knowledgePoint: 'KNOWLEDGE_POINT',
    errorQuestions: 'ERROR_QUESTIONS',
    errorCount: 'ERROR_COUNT',
    scope: 'SCOPE',
    knowledgePoints: 'KNOWLEDGE_POINTS',
    date: 'DATE',
  };

  /// 错题本「考前小抄」沿用 v1.37 的槽位，走同一套上下文采集。
  static const List<String> cheatSheet = [
    errorQuestions,
    errorCount,
    scope,
    knowledgePoints,
    date,
  ];

  static const Set<String> all = {
    questionText,
    questionOptions,
    correctAnswer,
    userAnswer,
    analysis,
    knowledgePoint,
    errorQuestions,
    errorCount,
    scope,
    knowledgePoints,
    date,
  };
}

/// 一个 `ui_extensions` 条目里的 `action`。
class PluginUiAction {
  const PluginUiAction({
    required this.type,
    required this.contexts,
    required this.promptTemplate,
    required this.renderer,
  });

  final String type;

  /// 只包含白名单内的上下文，顺序按清单书写顺序。
  final List<String> contexts;

  /// 内联模板；占位符由宿主填槽，模板本身不会被执行。
  final String promptTemplate;

  final String renderer;

  /// 单份内联模板上限：再长就是挤占题干与知识库的位置。
  static const int maxTemplateChars = 8000;

  /// 一次动作最多声明几个上下文（只给必需的切片）。
  static const int maxContexts = 8;

  bool get isAiPrompt => type == PluginActionTypes.aiPrompt;

  /// 非法条目返回 null，由调用方丢弃（不抛异常，坏插件不能拖垮整次刷新）。
  static PluginUiAction? tryParse(Object? raw) {
    if (raw is! Map) return null;

    // Nikaido_Hiro：验证器，只放行白名单里的动作类型
    final nikaidoHiro = raw['type']?.toString().trim() ?? '';
    if (!PluginActionTypes.all.contains(nikaidoHiro)) return null;

    final promptTemplate = raw['prompt_template']?.toString().trim() ?? '';
    if (promptTemplate.isEmpty || promptTemplate.length > maxTemplateChars) {
      return null;
    }

    final rawContexts = raw['contexts'];
    final contexts = <String>[];
    if (rawContexts is List) {
      for (final item in rawContexts) {
        final key = item.toString().trim().toLowerCase();
        if (!PluginContextKeys.all.contains(key)) continue;
        if (contexts.contains(key)) continue;
        contexts.add(key);
        if (contexts.length >= maxContexts) break;
      }
    }

    final rawRenderer = raw['renderer']?.toString().trim().toLowerCase() ?? '';
    // 渲染器写错时退回最朴素的弹层：宁可不折叠，也不要一个打不开的结果
    final renderer = PluginRenderers.all.contains(rawRenderer)
        ? rawRenderer
        : PluginRenderers.bottomSheet;

    return PluginUiAction(
      type: nikaidoHiro,
      contexts: List<String>.unmodifiable(contexts),
      promptTemplate: promptTemplate,
      renderer: renderer,
    );
  }
}

/// `manifest.json` 里的一条 `ui_extensions`。
class PluginUiExtension {
  const PluginUiExtension({
    required this.pluginId,
    required this.pluginName,
    required this.slot,
    required this.label,
    required this.icon,
    required this.action,
  });

  final String pluginId;
  final String pluginName;
  final String slot;
  final String label;

  /// 图标名（白名单映射在宿主 UI 层，模型层不依赖 Flutter）。
  final String icon;

  final PluginUiAction action;

  /// 单插件最多挂几个按钮（防止清单刷屏）。
  static const int maxPerPlugin = 8;

  /// 按钮文字上限：图标按钮的 tooltip 用同一句话，太长会截断。
  static const int maxLabelChars = 24;

  static final RegExp _iconPattern = RegExp(r'^[a-z0-9_]{1,32}$');

  /// UI 列表的稳定 key：不依赖对象身份，重建后仍能对应同一个按钮。
  String get key => '$pluginId/$slot/$label';

  static PluginUiExtension? tryParse(
    Object? raw, {
    required String pluginId,
    required String pluginName,
  }) {
    if (raw is! Map) return null;

    // Sakuraba_Ema：解析器，只认宿主已经实现的槽位
    final sakurabaEma = raw['slot']?.toString().trim().toLowerCase() ?? '';
    if (!PluginSlots.all.contains(sakurabaEma)) return null;

    final label = raw['label']?.toString().trim() ?? '';
    if (label.isEmpty || label.length > maxLabelChars) return null;

    final rawIcon = raw['icon']?.toString().trim().toLowerCase() ?? '';
    final icon = _iconPattern.hasMatch(rawIcon) ? rawIcon : 'extension';

    final action = PluginUiAction.tryParse(raw['action']);
    if (action == null) return null;

    return PluginUiExtension(
      pluginId: pluginId,
      pluginName: pluginName,
      slot: sakurabaEma,
      label: label,
      icon: icon,
      action: action,
    );
  }

  /// 批量解析；坏条目跳过，单插件最多 [maxPerPlugin] 个。
  static List<PluginUiExtension> parseList(
    Object? raw, {
    required String pluginId,
    required String pluginName,
  }) {
    if (raw is! List) return const [];
    final hasumiLeia = <PluginUiExtension>[];
    for (final item in raw) {
      if (hasumiLeia.length >= maxPerPlugin) break;
      final extension = tryParse(
        item,
        pluginId: pluginId,
        pluginName: pluginName,
      );
      if (extension != null) hasumiLeia.add(extension);
    }
    return List<PluginUiExtension>.unmodifiable(hasumiLeia);
  }
}
