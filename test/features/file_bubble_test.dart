import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/domain/chat/message_media.dart';
import 'package:gracelinkim/features/chat/widgets/media/file_bubble.dart';

/// 文件气泡（`im-file.vue`）。
///
/// 2026-09-25 整体排查时改的一处：附件没有名字时的兜底文案原来是**写死的中文**
/// 「文件」—— 切到 English 之后它不会变。现在走注入的取词函数，这条用例就钉住
/// 「气泡是问外面要的词，而不是自己写死」：给一个假的取词函数，
/// 从它的返回值就能看出来。
void main() {
  FilePayload payload({String name = '', String extension = 'pdf'}) =>
      FilePayload(
        url: 'https://a.test/x.pdf',
        name: name,
        size: 2048,
        extension: extension,
      );

  Future<void> pumpBubble(
    WidgetTester tester, {
    required FilePayload file,
    required String Function(String key) translate,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FileBubble(payload: file, translate: translate),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('附件没有名字时用取词函数给的词（不再写死「文件」）', (tester) async {
    await pumpBubble(tester, file: payload(), translate: (key) => 'W:<$key>');

    expect(find.text('W:<common.file>'), findsOneWidget);
  });

  testWidgets('有名字就显示名字，不问取词函数', (tester) async {
    await pumpBubble(
      tester,
      file: payload(name: '季度报告.pdf'),
      translate: (key) => 'W:<$key>',
    );

    expect(find.text('季度报告.pdf'), findsOneWidget);
    expect(find.textContaining('W:<'), findsNothing);
  });

  testWidgets('后缀徽章：取前四个字符大写，没有后缀就用问号', (tester) async {
    await pumpBubble(
      tester,
      file: payload(name: 'a.zip', extension: 'zip'),
      translate: (key) => key,
    );
    expect(find.text('ZIP'), findsOneWidget);

    await pumpBubble(
      tester,
      // 老端那个 `extUrl` 从来没被写过，后缀缺失是常态
      file: payload(name: '没有后缀', extension: ''),
      translate: (key) => key,
    );
    expect(find.text('?'), findsOneWidget);
  });
}
