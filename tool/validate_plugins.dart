// 插件包校验器（Plugins-Dev）。
//
// 用途：打包 / 发布前跑一遍，把「主程序会拒收的包」和「自己写错的地方」提前挡掉。
// 校验口径来自根目录《PLUGIN_DEVELOPMENT.md》第 3 节与
// `lib/services/plugins/plugin_registry.dart` 的机械校验：
//   id / version 正则、能力白名单、路径与体积、UTF-8（含 BOM）、示例题库格式。
// 另外按 §3.7 / §3.8 校验提示词模板：
//   `prompts/*` 的槽位是否宿主真的会填、`ui_extensions` 的槽位 / 图标 / 上下文 /
//   渲染器是否在白名单内、模板里用到的占位符是否都在 `contexts` 里声明过。
//
// 用法：
//   dart run tool/validate_plugins.dart                      # 校验仓库根下所有插件目录
//   dart run tool/validate_plugins.dart variant-generator     # 只校验一个
//
// 退出码：0 = 全过（可能有警告）；1 = 有错误。

import 'dart:convert';
import 'dart:io';

/// 能力白名单（`PLUGIN_DEVELOPMENT.md` §3.3）。后 6 项是内置插件的能力，
/// 第三方写上不会获得实现——只记警告，不判错。
const Set<String> capabilityWhitelist = {
  'kb.search',
  'kb.read',
  'question.generate',
  'bank.export',
  'question.tag',
  'notes',
  'backlinks',
  'graph',
  'companion',
  'chat',
  'encouragement',
  'schedule',
  'todo',
};

/// 与 `RegistryPlugin._idPattern` / `_versionPattern` 保持一致
final RegExp idPattern = RegExp(r'^[a-z0-9][a-z0-9._-]{2,63}$');
final RegExp versionPattern = RegExp(r'^\d+\.\d+\.\d+$');

/// 模板槽位：`{{SLOT_NAME}}`（大写 + 数字 + 下划线）
final RegExp placeholderPattern = RegExp(r'\{\{([^{}]*)\}\}');
final RegExp slotPattern = RegExp(r'^[A-Z][A-Z0-9_]*$');

const int maxDescriptionChars = 240;
const int maxNameChars = 60;
const int maxAuthorChars = 60;

/// 知识库单文档建议上限（`PLUGIN_DEVELOPMENT.md` §3.5）
const int maxTextAssetBytes = 5 * 1024 * 1024;

/// 包体上限（同步协议 `SyncServer.maxBodyBytes`）
const int maxPluginBytes = 64 * 1024 * 1024;

/// v1.38 `ui_extensions` 契约（与 `lib/services/plugins/plugin_ui_extension.dart` 逐项同步）。
///
/// 宿主对 UI 扩展是**白名单解析**：槽位 / 动作类型 / 上下文 / 渲染器只要有一个不认识，
/// 就静默丢掉整条扩展——应用里表现为「按钮没出现」，日志里也看不出原因。
/// 这些常量就是那道挡板，改宿主时请一并改这里。
const Set<String> uiSlots = {
  'quiz_analysis_actions',
  'error_book_actions',
};

const Set<String> uiActionTypes = {'ai_prompt'};

const Set<String> uiRenderers = {
  'bottom_sheet',
  'bottom_sheet_foldable',
};

/// 宿主图标白名单（`plugin_action_sheet.dart` 的 `_pluginIcons`）
const Set<String> uiIcons = {
  'psychology',
  'psychology_alt',
  'lightbulb',
  'school',
  'quiz',
  'auto_awesome',
  'menu_book',
  'tips_and_updates',
  'translate',
  'summarize',
  'checklist',
  'insights',
  'extension',
};

/// 上下文键 → 模板占位符（`PluginContextKeys.placeholders`）
const Map<String, String> uiContextPlaceholders = {
  'question_text': 'QUESTION_TEXT',
  'question_options': 'QUESTION_OPTIONS',
  'correct_answer': 'CORRECT_ANSWER',
  'user_answer': 'USER_ANSWER',
  'analysis': 'ANALYSIS',
  'knowledge_point': 'KNOWLEDGE_POINT',
  'error_questions': 'ERROR_QUESTIONS',
  'error_count': 'ERROR_COUNT',
  'scope': 'SCOPE',
  'knowledge_points': 'KNOWLEDGE_POINTS',
  'date': 'DATE',
};

/// 宿主能填的全部占位符：`prompts/*` 模板里出现别的名字就会被原样发给模型
final Set<String> hostPlaceholders = uiContextPlaceholders.values.toSet();

/// 单插件最多挂几个按钮 / 单槽位最多渲染几个（宿主会截断）
const int maxUiPerPlugin = 8;
const int maxUiPerSlot = 4;

/// 按钮 tooltip 上限（`PluginUiExtension.maxLabelChars`）
const int maxUiLabelChars = 24;

/// 单份内联模板上限（`PluginUiAction.maxTemplateChars`）
const int maxUiTemplateChars = 8000;

/// 一次动作最多声明几个上下文（`PluginUiAction.maxContexts`）
const int maxUiContexts = 8;

/// 答案折叠分界标记（`PluginRenderers.answerStartMarker`）
const String answerStartMarker = '<!--ANSWER_START-->';

/// `Question.questionType` 的合法取值（`lib/models/question.dart`）
const Set<String> knownQuestionTypes = {
  'single_choice',
  'multi_choice',
  'true_false',
  'fill_blank',
  'ming_jie',
  'jian_da',
  'jie_da',
};

final List<String> errors = <String>[];
final List<String> warnings = <String>[];

void main(List<String> args) {
  final targets = <Directory>[];
  if (args.isEmpty) {
    targets.addAll(pluginDirs(defaultRoot()));
  } else {
    for (final raw in args) {
      final dir = Directory(raw);
      if (!dir.existsSync()) {
        errors.add('路径不存在：$raw');
        continue;
      }
      if (_manifestOf(dir) != null) {
        targets.add(dir);
      } else {
        targets.addAll(pluginDirs(dir));
      }
    }
  }

  if (targets.isEmpty) {
    stdout.writeln('没找到插件目录（目录内需要 manifest.json 或 plugin.json）');
    exit(1);
  }

  final seenIds = <String, String>{};
  stdout.writeln('校验 ${targets.length} 个插件目录：');
  for (final dir in targets) {
    stdout.writeln('');
    stdout.writeln('== ${dir.path} ==');
    validatePlugin(dir, seenIds);
  }

  stdout.writeln('');
  if (errors.isEmpty && warnings.isEmpty) {
    stdout.writeln('✓ 全部通过（0 错误，0 警告）');
    exit(0);
  }
  if (warnings.isNotEmpty) {
    stdout.writeln('警告 ${warnings.length} 条：');
    for (final w in warnings) {
      stdout.writeln('  ! $w');
    }
  }
  if (errors.isNotEmpty) {
    stdout.writeln('错误 ${errors.length} 条：');
    for (final e in errors) {
      stdout.writeln('  ✗ $e');
    }
    stdout.writeln('结果：不通过');
    exit(1);
  }
  stdout.writeln('结果：通过（有警告）');
}

/// 默认插件根：**仓库根**。
///
/// v1.1 起不再有 `plugins/` 这一层——每个插件就是仓库根下的一个目录
/// （`cheat-sheet-generator/`、`variant-generator/`），与
/// `.github/workflows/publish-plugins.yml` 找文件夹的口径保持一致。
Directory defaultRoot() {
  final scriptDir = File.fromUri(Platform.script).parent;
  return scriptDir.parent;
}

/// 根目录下所有含清单的子目录（按名字排序，输出稳定）
List<Directory> pluginDirs(Directory root) {
  if (!root.existsSync()) {
    errors.add('插件根目录不存在：${root.path}');
    return const [];
  }
  return root
      .listSync()
      .whereType<Directory>()
      .where((d) => _manifestOf(d) != null)
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
}

/// 校验一个插件目录；通过 [seenIds] 顺带查 id 重复。
void validatePlugin(Directory dir, Map<String, String> seenIds) {
  final pluginJson = File(_join(dir.path, 'plugin.json'));
  final manifestJson = File(_join(dir.path, 'manifest.json'));
  final File manifestFile;
  if (pluginJson.existsSync()) {
    manifestFile = pluginJson;
    if (manifestJson.existsSync()) {
      warnings.add('${dir.path}：plugin.json 与 manifest.json 同时存在，以 plugin.json 为准');
    }
  } else if (manifestJson.existsSync()) {
    manifestFile = manifestJson;
  } else {
    errors.add('${dir.path}：缺少 manifest.json / plugin.json');
    return;
  }

  final raw = readText(manifestFile, limit: 256 * 1024);
  if (raw == null) return;
  Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } catch (e) {
    errors.add('${manifestFile.path}：不是合法 JSON（$e）');
    return;
  }
  if (decoded is! Map) {
    errors.add('${manifestFile.path}：顶层必须是对象');
    return;
  }
  final m = decoded.map((k, v) => MapEntry(k.toString(), v));
  final rel = relPath(dir.path, manifestFile.path);

  String str(String key) => m[key]?.toString().trim() ?? '';

  // ---- 必填字段 ----
  final id = str('id');
  final name = str('name');
  final version = str('version');
  final author = str('author');
  final description = str('description');

  if (id.isEmpty) {
    errors.add('$rel：缺少 id');
  } else if (!idPattern.hasMatch(id)) {
    errors.add('$rel：id「$id」不合法（需匹配 ^[a-z0-9][a-z0-9._-]{2,63}）');
  } else if (seenIds.containsKey(id)) {
    errors.add('$rel：id「$id」与 ${seenIds[id]} 重复');
  }

  if (name.isEmpty) {
    errors.add('$rel：缺少 name');
  } else if (name.length > maxNameChars) {
    errors.add('$rel：name 超过 $maxNameChars 字');
  }

  if (version.isEmpty) {
    errors.add('$rel：缺少 version');
  } else if (!versionPattern.hasMatch(version)) {
    errors.add('$rel：version「$version」不合法（需 主.次.修 三段数字）');
  }

  if (author.isEmpty) {
    errors.add('$rel：缺少 author（登记表要求）');
  } else if (author.length > maxAuthorChars) {
    errors.add('$rel：author 超过 $maxAuthorChars 字');
  }

  if (description.isEmpty) {
    errors.add('$rel：缺少 description');
  } else if (description.length > maxDescriptionChars) {
    errors.add('$rel：description 超过 $maxDescriptionChars 字（当前 ${description.length}）');
  }

  // ---- 能力白名单 ----
  final capsRaw = m['capabilities'];
  final caps = <String>[];
  if (capsRaw == null) {
    errors.add('$rel：缺少 capabilities（可以为空数组，但不能没有）');
  } else if (capsRaw is! List) {
    errors.add('$rel：capabilities 必须是数组');
  } else {
    for (final item in capsRaw) {
      if (item is! String || item.trim().isEmpty) {
        errors.add('$rel：capabilities 里有空项或非字符串');
        continue;
      }
      caps.add(item.trim());
    }
  }
  for (final c in caps) {
    if (!capabilityWhitelist.contains(c)) {
      warnings.add('$rel：能力「$c」不在白名单内（会被忽略，但仍会展示给用户）');
    }
  }

  // ---- 可选字段 ----
  final license = m['license'];
  if (license != null && (license is! String || license.trim().isEmpty)) {
    errors.add('$rel：license 必须是非空字符串');
  }
  final syncable = m['syncable'];
  if (syncable != null && syncable is! bool) {
    errors.add('$rel：syncable 必须是 bool（缺省按 false 处理）');
  }
  final minApp = m['min_app_version'];
  if (minApp != null &&
      (minApp is! String || !versionPattern.hasMatch(minApp.trim()))) {
    errors.add('$rel：min_app_version 必须是 主.次.修 三段数字');
  }
  final homepage = m['homepage'];
  if (homepage != null) {
    final uri = homepage is String ? Uri.tryParse(homepage) : null;
    if (uri == null || uri.scheme != 'https') {
      errors.add('$rel：homepage 必须是 https 链接');
    }
  }

  // tags 是「打包期提示」：客户端不认识它，但 tool/build_plugins.ps1 用它拼登记表的
  // tags（≤6 个、每个 ≤16 字），所以这里按登记表的硬上限先挡一次。
  final tagsRaw = m['tags'];
  if (tagsRaw != null) {
    if (tagsRaw is! List) {
      errors.add('$rel：tags 必须是字符串数组');
    } else {
      if (tagsRaw.length > 6) {
        warnings.add('$rel：tags 最多 6 个，多出来的打包时会被丢掉');
      }
      for (final item in tagsRaw) {
        final s = item is String ? item.trim() : '';
        if (s.isEmpty || s.length > 16) {
          errors.add('$rel：tags 里「$item」为空或超过 16 字（登记表硬上限）');
        }
      }
    }
  }

  // ---- 声明式资产清单 ----
  final assetsRaw = m['assets'];
  final declaredAssets = <String>[];
  if (assetsRaw != null) {
    if (assetsRaw is! List) {
      errors.add('$rel：assets 必须是字符串数组');
    } else {
      for (final item in assetsRaw) {
        if (item is! String || item.trim().isEmpty) {
          errors.add('$rel：assets 里有空项或非字符串');
          continue;
        }
        final a = item.trim();
        if (isUnsafePath(a)) {
          errors.add('$rel：assets 里的「$a」含 .. 或以 / 开头（路径穿越）');
          continue;
        }
        declaredAssets.add(a);
        final exists = File(_join(dir.path, a)).existsSync() ||
            Directory(_join(dir.path, a)).existsSync();
        if (!exists) errors.add('$rel：assets 声明的「$a」不存在');
      }
    }
  }

  // ---- ui_extensions（v1.38：第三方唯一能挂按钮的通道）----
  validateUiExtensions(m, rel, dir);

  // ---- prompt.md ----
  final promptFile = File(_join(dir.path, 'prompt.md'));
  if (!promptFile.existsSync()) {
    if (declaredAssets.contains('prompt.md')) {
      errors.add('$rel：assets 声明了 prompt.md，但文件不存在');
    } else {
      warnings.add('$rel：没有 prompt.md（插件不会改变 AI 口径）');
    }
  } else {
    final prompt = readText(promptFile, limit: maxTextAssetBytes);
    if (prompt != null) {
      if (prompt.trim().length < 120) {
        warnings.add('${promptFile.path}：内容过短（< 120 字），像是没写完');
      }
      if (placeholderPattern.hasMatch(prompt)) {
        warnings.add('${promptFile.path}：prompt.md 是系统提示词，不应出现 {{槽位}}（槽位只放 prompts/ 模板）');
      }
    }
  }

  // ---- 文件树 ----
  var fileCount = 0;
  var totalBytes = 0;
  final textFiles = <File>[];
  for (final e in dir.listSync(recursive: true)) {
    if (e is! File) continue;
    final rp = relPath(dir.path, e.path);
    if (isUnsafePath(rp)) {
      errors.add('${dir.path}：出现了非法相对路径「$rp」');
      continue;
    }
    fileCount++;
    final size = e.lengthSync();
    totalBytes += size;
    if (hasNonAscii(rp)) {
      warnings.add('${dir.path}：「$rp」文件名含非 ASCII 字符，换打包工具时可能乱码');
    }
    final lower = rp.toLowerCase();
    if (lower.endsWith('.md') ||
        lower.endsWith('.txt') ||
        lower.endsWith('.json')) {
      textFiles.add(e);
      if (lower.startsWith('kb/') && size > maxTextAssetBytes) {
        errors.add('$rel：知识库文档「$rp」超过 5MB');
      }
    }
  }
  if (totalBytes > maxPluginBytes) {
    errors.add(
        '$rel：包体 ${(totalBytes / 1024 / 1024).toStringAsFixed(1)}MB 超过 64MB 上限');
  }

  // ---- 文本文件：UTF-8 / BOM / 模板槽位 ----
  final slotsByFile = <String, Set<String>>{};
  for (final f in textFiles) {
    final text = readText(f, limit: maxTextAssetBytes);
    if (text == null) continue;
    final rp = relPath(dir.path, f.path);
    if (rp.startsWith('prompts/')) {
      final tokens = checkTemplateSlots(f, text, rp);
      if (tokens.isNotEmpty) slotsByFile[rp] = tokens;
      // 宿主只会填白名单里的占位符；写错名字会被原样留在提示词里（不报错、只是内容变脏）
      final unknown =
          (tokens.where((t) => !hostPlaceholders.contains(t)).toList()..sort());
      if (unknown.isNotEmpty) {
        warnings.add('$rp：槽位 ${unknown.join('、')} 不是宿主能填的'
            '（宿主只填 ${(hostPlaceholders.toList()..sort()).join(' / ')}），'
            '会原样留在提示词里');
      }
    }
  }
  checkSlotsDocumented(dir, rel, slotsByFile);

  // ---- 示例题库（可选）----
  final bankFile = File(_join(dir.path, 'sample_bank.json'));
  if (bankFile.existsSync()) {
    validateSampleBank(bankFile, readText(bankFile, limit: maxTextAssetBytes));
  }

  // ---- 知识库目录（可选）----
  final kbDir = Directory(_join(dir.path, 'kb'));
  if (kbDir.existsSync()) {
    final docs = kbDir.listSync().whereType<File>().where((f) {
      final lower = f.path.toLowerCase();
      return lower.endsWith('.md') ||
          lower.endsWith('.txt') ||
          lower.endsWith('.json');
    }).length;
    if (docs == 0) warnings.add('$rel：有 kb/ 目录但没有可导入的文档');
  }

  seenIds[id] = dir.path;
  stdout.writeln('  → id=$id  v=$version  caps=[${caps.join(", ")}]  '
      '文件=$fileCount  体积=${(totalBytes / 1024).toStringAsFixed(1)}KB');
}

/// `ui_extensions` 校验：把「宿主会静默丢弃」的写法提前变成可读的报错。
///
/// 检查口径全部来自 `plugin_ui_extension.dart`：槽位 / label / 图标 / 动作类型 /
/// 上下文 / 渲染器白名单与上限，外加两条最容易踩的隐性错误——
///   1. 模板里用了 `contexts` 没声明的占位符（宿主不填 → 占位符原样发给模型）；
///   2. 折叠渲染器但模板里没有 `<!--ANSWER_START-->`（答案会直接摊开）。
void validateUiExtensions(Map<String, dynamic> m, String rel, Directory dir) {
  final raw = m['ui_extensions'];
  if (raw == null) {
    stdout.writeln('  · ui_extensions：无（插件不会在答题页 / 错题本出现按钮）');
    return;
  }
  if (raw is! List) {
    errors.add('$rel：ui_extensions 必须是数组');
    return;
  }
  if (raw.isEmpty) {
    warnings.add('$rel：ui_extensions 是空数组（要么删掉这个字段，要么写至少一条）');
    return;
  }
  if (raw.length > maxUiPerPlugin) {
    warnings.add('$rel：ui_extensions 有 ${raw.length} 条，超过单插件上限 $maxUiPerPlugin'
        '（多出来的宿主不渲染）');
  }

  final perSlot = <String, int>{};
  var passed = 0;
  for (var i = 0; i < raw.length; i++) {
    final at = '$rel：ui_extensions[$i]';
    final item = raw[i];
    if (item is! Map) {
      errors.add('$at 不是对象');
      continue;
    }
    final e = item.map((k, v) => MapEntry(k.toString(), v));

    // 槽位不认识 = 整条扩展被宿主丢弃，后面的字段再对也没意义
    final slot = (e['slot']?.toString() ?? '').trim().toLowerCase();
    if (!uiSlots.contains(slot)) {
      errors.add('$at：slot「$slot」不是宿主已实现的槽位'
          '（只认 ${uiSlots.join(' / ')}）');
      continue;
    }

    final label = (e['label']?.toString() ?? '').trim();
    if (label.isEmpty) {
      errors.add('$at：缺少 label（按钮没有 tooltip，宿主整条丢弃）');
    } else if (label.length > maxUiLabelChars) {
      errors.add('$at：label「$label」${label.length} 字，超过 $maxUiLabelChars 字上限'
          '（宿主整条丢弃）');
    }

    final icon = (e['icon']?.toString() ?? '').trim().toLowerCase();
    if (icon.isEmpty) {
      warnings.add('$at：没写 icon（宿主回退成扩展图标）');
    } else if (!RegExp(r'^[a-z0-9_]{1,32}$').hasMatch(icon)) {
      errors.add('$at：icon「$icon」不合法（只允许小写字母 / 数字 / 下划线，1–32 位）');
    } else if (!uiIcons.contains(icon)) {
      warnings.add('$at：icon「$icon」不在宿主图标白名单，会回退成扩展图标'
          '（可用：${(uiIcons.toList()..sort()).join(' / ')}）');
    }

    final action = e['action'];
    if (action is! Map) {
      errors.add('$at：缺少 action 对象');
      continue;
    }
    final a = action.map((k, v) => MapEntry(k.toString(), v));

    final type = (a['type']?.toString() ?? '').trim().toLowerCase();
    if (!uiActionTypes.contains(type)) {
      errors.add('$at：action.type「$type」宿主不支持'
          '（当前只有 ${uiActionTypes.join(' / ')}，其它动作整条丢弃）');
      continue;
    }

    final template = a['prompt_template']?.toString() ?? '';
    if (template.trim().isEmpty) {
      errors.add('$at：action.prompt_template 为空（点按钮只会提示「模板为空」）');
    } else if (template.length > maxUiTemplateChars) {
      errors.add('$at：action.prompt_template ${template.length} 字，'
          '超过 $maxUiTemplateChars 字上限（宿主整条丢弃）');
    }

    final contextsRaw = a['contexts'];
    final contexts = <String>[];
    if (contextsRaw == null) {
      warnings.add('$at：没写 contexts（宿主一个字节都不采集，模板里的槽位会原样留下）');
    } else if (contextsRaw is! List) {
      errors.add('$at：action.contexts 必须是数组');
    } else {
      for (final item in contextsRaw) {
        final key = item.toString().trim().toLowerCase();
        if (!uiContextPlaceholders.containsKey(key)) {
          errors.add('$at：上下文「$key」不在白名单，宿主不会采集'
              '（可用：${uiContextPlaceholders.keys.join(' / ')}）');
          continue;
        }
        if (contexts.contains(key)) {
          warnings.add('$at：上下文「$key」重复声明');
          continue;
        }
        contexts.add(key);
      }
      if (contexts.length > maxUiContexts) {
        errors.add('$at：contexts ${contexts.length} 个，超过上限 $maxUiContexts'
            '（宿主只取前 $maxUiContexts 个）');
      }
    }

    final renderer = (a['renderer']?.toString() ?? '').trim().toLowerCase();
    if (renderer.isEmpty) {
      // 缺省是 bottom_sheet，等价写法，不算问题
    } else if (!uiRenderers.contains(renderer)) {
      warnings.add('$at：renderer「$renderer」宿主不认识，回退 ${uiRenderers.first}');
    }

    if (template.trim().isNotEmpty) {
      final used = checkTemplateSlots(
        File(_join(dir.path, 'manifest.json')),
        template,
        at,
      );
      final declared = <String>{
        for (final key in contexts) uiContextPlaceholders[key]!,
      };
      final undeclared = (used.difference(declared).toList()..sort());
      if (undeclared.isNotEmpty) {
        errors.add('$at：模板里用了 ${undeclared.map((t) => '{{$t}}').join('、')}，'
            '但 contexts 没声明对应上下文 → 宿主不会填，占位符会原样发给模型');
      }
      final unused = (declared.difference(used).toList()..sort());
      if (unused.isNotEmpty) {
        warnings.add('$at：contexts 声明了但模板没用到：${unused.join('、')}'
            '（白白采集数据）');
      }
      if (renderer == 'bottom_sheet_foldable' &&
          !template.contains(answerStartMarker)) {
        warnings.add('$at：renderer 选了折叠，但模板里没有 $answerStartMarker'
            '（模型不会按约定切分，答案会直接摊开）');
      }
    }

    perSlot.update(slot, (v) => v + 1, ifAbsent: () => 1);
    passed++;
  }

  perSlot.forEach((slot, count) {
    if (count > maxUiPerSlot) {
      warnings.add('$rel：槽位 $slot 挂了 $count 个按钮，超过单槽位上限 '
          '$maxUiPerSlot（多出来的不渲染）');
    }
  });

  if (passed > 0) {
    final slots = (perSlot.keys.toList()..sort()).join(' / ');
    stdout.writeln('  ✓ ui_extensions：$passed 条通过槽位 / 图标 / 上下文 / 模板检查'
        '（$slots）');
  }
}

/// 目录里的清单文件（`plugin.json` 优先，与 `PluginLoader.manifestCandidates` 一致）
File? _manifestOf(Directory dir) {
  for (final name in const ['plugin.json', 'manifest.json']) {
    final f = File(_join(dir.path, name));
    if (f.existsSync()) return f;
  }
  return null;
}

String _join(String a, String b) => '$a${Platform.pathSeparator}$b';

/// 相对路径，统一用 `/`（zip 条目名与 `LoadedPlugin.assets` 的键都是 `/`）
String relPath(String base, String path) {
  var p = path;
  if (p.startsWith(base)) p = p.substring(base.length);
  p = p.replaceAll('\\', '/');
  while (p.startsWith('/')) {
    p = p.substring(1);
  }
  return p;
}

/// 路径穿越判定：`..`、以 `/` 开头、Windows 盘符
bool isUnsafePath(String p) {
  final norm = p.replaceAll('\\', '/');
  if (norm.startsWith('/')) return true;
  if (RegExp(r'^[A-Za-z]:').hasMatch(norm)) return true;
  return norm.split('/').any((seg) => seg == '..');
}

bool hasNonAscii(String s) => s.codeUnits.any((c) => c > 0x7F);

/// 读文本资产：超限 / 带 BOM / 非 UTF-8 都记错误；BOM 仍返回去掉 BOM 的内容
String? readText(File f, {required int limit}) {
  final bytes = f.readAsBytesSync();
  if (bytes.length > limit) {
    errors.add('${f.path}：超过 ${limit ~/ 1024}KB');
    return null;
  }
  if (bytes.length >= 3 &&
      bytes[0] == 0xEF &&
      bytes[1] == 0xBB &&
      bytes[2] == 0xBF) {
    errors.add('${f.path}：带 UTF-8 BOM（加载器按纯 UTF-8 解码，BOM 会污染首行）');
    return utf8.decode(bytes.sublist(3), allowMalformed: true);
  }
  try {
    return utf8.decode(bytes);
  } on FormatException catch (e) {
    errors.add('${f.path}：不是合法 UTF-8（${e.message}）');
    return null;
  }
}

/// 模板槽位检查：`{{NAME}}` 必须是大写蛇形命名，且 `{{` 与 `}}` 数量要配平
Set<String> checkTemplateSlots(File f, String text, String rp) {
  final open = '{{'.allMatches(text).length;
  final close = '}}'.allMatches(text).length;
  if (open != close) {
    errors.add('$rp：{{ 与 }} 数量不一致（$open / $close），槽位会漏替换');
  }
  final tokens = <String>{};
  for (final mt in placeholderPattern.allMatches(text)) {
    final t = mt.group(1) ?? '';
    if (!slotPattern.hasMatch(t)) {
      errors.add('$rp：槽位「{{$t}}」不合法（应为 UPPER_SNAKE，如 STEM）');
      continue;
    }
    tokens.add(t);
  }
  return tokens;
}

/// 槽位必须在 README 里有说明：文档与模板脱节是最常见的「装上去不会用」的原因
void checkSlotsDocumented(
  Directory dir,
  String rel,
  Map<String, Set<String>> slotsByFile,
) {
  if (slotsByFile.isEmpty) return;
  final readme = File(_join(dir.path, 'README.md'));
  if (!readme.existsSync()) {
    errors.add('$rel：有 prompts/ 模板但没有 README.md，槽位无文档');
    return;
  }
  final readmeText = readText(readme, limit: maxTextAssetBytes) ?? '';
  slotsByFile.forEach((file, tokens) {
    final missing = tokens.where((t) => !readmeText.contains(t)).toList()
      ..sort();
    if (missing.isNotEmpty) {
      warnings.add('$file：槽位未在 README 里说明：${missing.join("、")}');
    }
  });
}

/// 示例题库校验：口径对齐 `BankFileService.parseJsonFile` 与 `Question` 模型
void validateSampleBank(File f, String? text) {
  if (text == null) return;
  Object? decoded;
  try {
    decoded = jsonDecode(text);
  } catch (e) {
    errors.add('${f.path}：不是合法 JSON（$e）');
    return;
  }
  if (decoded is! Map) {
    errors.add('${f.path}：顶层必须是对象');
    return;
  }
  final m = decoded.map((k, v) => MapEntry(k.toString(), v));
  if (m['format'] != 'natsume-quiz-questions') {
    errors.add('${f.path}：缺少 format 标记「natsume-quiz-questions」（BankFileService 会拒收）');
  }
  final bankName = m['name'];
  if (bankName is! String || bankName.trim().isEmpty) {
    warnings.add('${f.path}：建议写 name（导入后的题库名取自它）');
  }
  final questions = m['questions'];
  if (questions is! List || questions.isEmpty) {
    errors.add('${f.path}：questions 必须是非空数组');
    return;
  }
  final declaredCount = m['count'];
  if (declaredCount is int && declaredCount != questions.length) {
    warnings.add(
        '${f.path}：count($declaredCount) 与 questions 实际条数(${questions.length}) 不一致');
  }

  for (var i = 0; i < questions.length; i++) {
    final at = '${f.path} 第 ${i + 1} 题';
    final q = questions[i];
    if (q is! Map) {
      errors.add('$at：不是对象');
      continue;
    }
    final qm = q.map((k, v) => MapEntry(k.toString(), v));
    if ((qm['title']?.toString().trim() ?? '').isEmpty) {
      errors.add('$at：缺少 title');
    }
    final typeRaw = qm['question_type']?.toString().trim() ?? '';
    final type = typeRaw.isEmpty ? 'single_choice' : typeRaw;
    if (!knownQuestionTypes.contains(type)) {
      errors.add('$at：question_type「$type」不在已知取值内');
    }
    final answer = qm['correct_answer']?.toString().trim() ?? '';
    if (answer.isEmpty) errors.add('$at：缺少 correct_answer');

    final optionsRaw = qm['options'];
    final options = <String>[];
    if (optionsRaw is List) {
      for (final o in optionsRaw) {
        if (o is! String || o.trim().isEmpty) {
          errors.add('$at：options 里有空项或非字符串');
          continue;
        }
        options.add(o.trim());
      }
    } else if (optionsRaw != null) {
      errors.add('$at：options 必须是字符串数组');
    }

    if (answer.isNotEmpty) checkAnswer(f, at, type, answer, options);
  }
  stdout.writeln('  ✓ sample_bank.json：${questions.length} 题通过格式检查');
}

/// 答案与题型 / 选项数量是否自洽
void checkAnswer(
  File f,
  String at,
  String type,
  String answer,
  List<String> options,
) {
  switch (type) {
    case 'single_choice':
      if (options.length < 2) errors.add('$at：单选至少要有 2 个选项');
      final up = answer.toUpperCase();
      if (up.length != 1) {
        errors.add('$at：单选答案应为单个字母，实际「$answer」');
        break;
      }
      final idx = up.codeUnitAt(0) - 65;
      if (idx < 0 || idx >= options.length) {
        errors.add('$at：答案「$answer」超出选项范围（共 ${options.length} 项）');
      }
      break;
    case 'multi_choice':
      if (options.length < 2) errors.add('$at：多选至少要有 2 个选项');
      final parts = answer
          .split(RegExp(r'[,，]'))
          .map((s) => s.trim().toUpperCase())
          .where((s) => s.isNotEmpty)
          .toList();
      if (parts.length < 2) {
        errors.add('$at：多选答案至少 2 个字母（如 A,C）');
        break;
      }
      if (parts.toSet().length != parts.length) {
        errors.add('$at：多选答案有重复字母');
      }
      for (final p in parts) {
        if (p.length != 1) {
          errors.add('$at：多选答案「$p」不是单个字母');
          continue;
        }
        final idx = p.codeUnitAt(0) - 65;
        if (idx < 0 || idx >= options.length) {
          errors.add('$at：答案「$p」超出选项范围（共 ${options.length} 项）');
        }
      }
      break;
    case 'true_false':
      const truthy = {
        '对',
        '错',
        '正确',
        '错误',
        '是',
        '否',
        'T',
        'F',
        'true',
        'false',
      };
      if (!truthy.contains(answer)) {
        errors.add('$at：判断题答案为「$answer」，应为 对 / 错');
      }
      if (options.isNotEmpty && options.length != 2) {
        warnings.add('$at：判断题选项建议就两项（对 / 错）');
      }
      break;
    default:
      // 填空 / 名解 / 简答 / 问答：答案是自由文本，不做结构校验
      break;
  }
}



