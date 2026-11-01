// 对接自检（Plugins-Dev）：用**宿主真实解析器**跑一遍两个插件的清单。
//
// 与 `tool/validate_plugins.dart` 的分工：
//   · validate_plugins.dart —— 白名单 / 字数的静态校验（口径抄自宿主，能离机跑）；
//   · check_ui_contract.dart —— 直接 import 宿主参考实现 `plugin_ui_extension.dart`，
//     验证「宿主真的能解析出这些按钮」并且「按 contexts 填槽后不残留 {{...}}」。
//
// 用法：dart run tool/check_ui_contract.dart
// 退出码：0 = 通过；1 = 有不一致。
import 'dart:convert';
import 'dart:io';

import '../plugin_ui_extension.dart';

/// 每个上下文键的「典型内容」：长度取宿主上限附近，用来验证填槽后不残留占位符。
const Map<String, String> samples = {
  'question_text': '急性炎症早期浸润的主要炎细胞是？',
  'question_options': 'A. 淋巴细胞\nB. 中性粒细胞\nC. 嗜酸性粒细胞\nD. 浆细胞',
  'correct_answer': 'B',
  'user_answer': 'C',
  'analysis': '急性炎症早期以中性粒细胞渗出为主。',
  'knowledge_point': '病理学·炎症',
  'error_questions': '1. 题干：……\n选项：……\n正确答案：B\n解析：……\n错了几次：3',
  'error_count': '7',
  'scope': '错题 · 2 个题库',
  'knowledge_points': '病理学（12 题）、药理学（5 题）',
  'date': '2026-11-01',
};

/// 与宿主 `PluginPromptService.fillTemplate` 同一套正则
final RegExp slotPattern = RegExp(r'\{\{\s*([A-Za-z0-9_]+)\s*\}\}');

/// 填槽后整段上限（`PluginActionEngine.maxPromptChars`）
const int maxPromptChars = 12000;

String fill(String template, Map<String, String> vars) => template
    .replaceAllMapped(slotPattern, (m) => vars[m.group(1)!] ?? m.group(0)!);

String readNormalized(File file) =>
    file.readAsStringSync().replaceAll('\r\n', '\n').trimRight();

void main() {
  var failures = 0;
  // 插件目录平铺在仓库根（与 publish-plugins.yml 一致）：根下带清单的目录即插件
  final repoRoot = File.fromUri(Platform.script).parent.parent;
  final pluginDirs = repoRoot
      .listSync()
      .whereType<Directory>()
      .where((d) =>
          File('${d.path}/manifest.json').existsSync() ||
          File('${d.path}/plugin.json').existsSync())
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  for (final dir in pluginDirs) {
    final manifestFile = File('${dir.path}/manifest.json').existsSync()
        ? File('${dir.path}/manifest.json')
        : File('${dir.path}/plugin.json');
    final manifest =
        jsonDecode(manifestFile.readAsStringSync()) as Map<String, dynamic>;
    final id = manifest['id']?.toString() ?? '';
    final name = manifest['name']?.toString() ?? '';
    final declared = manifest['ui_extensions'];

    stdout.writeln('== $id（$name）==');
    if (declared is! List || declared.isEmpty) {
      stdout.writeln('  · 没有 ui_extensions：宿主不会渲染任何按钮');
      continue;
    }

    final parsed = PluginUiExtension.parseList(declared,
        pluginId: id, pluginName: name);
    stdout.writeln('  清单 ${declared.length} 条 → 宿主解析 ${parsed.length} 条');
    if (parsed.length != declared.length) {
      stdout.writeln('  ✗ 有扩展被宿主丢弃（槽位 / label / 图标 / 动作类型不在白名单？）');
      failures++;
    }

    // 该插件的全部模板文件：内联模板必须与其中之一逐字一致，否则两条路径会跑偏
    final promptFiles = Directory('${dir.path}/prompts')
        .listSync()
        .whereType<File>()
        .where((f) {
          final lower = f.path.toLowerCase();
          return lower.endsWith('.md') ||
              lower.endsWith('.markdown') ||
              lower.endsWith('.txt');
        })
        .toList();

    for (final extension in parsed) {
      final vars = <String, String>{};
      for (final context in extension.action.contexts) {
        vars[PluginContextKeys.placeholders[context]!] = samples[context] ?? '';
      }
      final filled = fill(extension.action.promptTemplate, vars);
      final leftover =
          slotPattern.allMatches(filled).map((m) => m.group(0)!).toList();

      stdout.writeln('  · ${extension.slot} / ${extension.label} / '
          '${extension.icon} / ${extension.action.renderer}'
          '（${extension.action.contexts.length} contexts）');
      stdout.writeln('      填槽后 ${filled.length} 字'
          '（上限 $maxPromptChars），'
          '标记 ${extension.action.renderer == PluginRenderers.bottomSheetFoldable ? "需要" : "不需要"} ANSWER_START');

      if (leftover.isNotEmpty) {
        stdout.writeln('      ✗ 残留占位符：${leftover.join(' ')}'
            '（contexts 少声明了对应的上下文）');
        failures++;
      }
      if (filled.length > maxPromptChars) {
        stdout.writeln('      ✗ 超过 $maxPromptChars 字封顶，宿主会截断');
        failures++;
      }
      if (extension.action.renderer == PluginRenderers.bottomSheetFoldable &&
          !extension.action.promptTemplate
              .contains(PluginRenderers.answerStartMarker)) {
        stdout.writeln('      ✗ 折叠渲染器缺 ${PluginRenderers.answerStartMarker}');
        failures++;
      }

      final matched = promptFiles.any((f) =>
          readNormalized(f) == extension.action.promptTemplate.trimRight());
      if (!matched) {
        stdout.writeln('      · 提示：内联模板没有与 prompts/ 下的文件逐字一致'
            '（改模板时请两处同步，否则按钮与模板路径产出会不一样）');
      }
    }
  }

  stdout.writeln('');
  stdout.writeln(failures == 0
      ? '✓ 宿主解析 + 填槽 + 折叠标记：全部通过'
      : '✗ 失败 $failures 项');
  exit(failures == 0 ? 0 : 1);
}
