import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:khongdich_mobile/features/reader/views/chat_chapter_view.dart';
import 'package:khongdich_mobile/models/chapter_content.dart';

void main() {
  final participants = [
    const ChatParticipant(id: 'c1', name: 'Lin Lan', color: '#FF0000'),
    const ChatParticipant(id: 'me', name: 'Bạn'),
  ];

  ChatMessage dialogue(String cid, String text) =>
      ChatMessage(id: 'm-$cid-$text', characterId: cid, content: text, messageType: 'dialogue');

  Future<void> pumpChat(
    WidgetTester tester,
    List<ChatMessage> messages,
  ) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          height: 600,
          child: ChatChapterView(
            participants: participants,
            messages: messages,
            onNext: () {},
            onPrev: () {},
          ),
        ),
      ),
    ));
    // initState reveal chạy trong post-frame callback.
    await tester.pump();
  }

  testWidgets('tin nhân vật khác: hiện "đang gõ..." rồi bubble (fast-forward bằng tap)',
      (tester) async {
    await pumpChat(tester, [dialogue('c1', 'Chào bạn!')]);

    // Ngay lập tức: chỉ báo đang gõ với tên nhân vật.
    expect(find.text('Lin Lan đang gõ...'), findsOneWidget);
    expect(find.text('Chào bạn!'), findsNothing);

    // Mirror web revealNext: tap trong lúc "đang gõ" bị BỎ QUA —
    // phải chờ hết delay indicator bubble mới hiện.
    await tester.tap(find.byType(ChatChapterView));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('Lin Lan đang gõ...'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Lin Lan đang gõ...'), findsNothing);
    expect(find.text('Chào bạn!'), findsOneWidget);
  });

  testWidgets(
      'tin của "Bạn": gõ dần xong DỪNG chờ Gửi — bấm Gửi mới hiện bubble',
      (tester) async {
    await pumpChat(tester, [dialogue('me', 'Xin chào nha')]);

    // Đang gõ dần — chưa có bubble.
    expect(find.text('Xin chào nha'), findsNothing);
    await tester.pump(const Duration(milliseconds: 800));
    // Gõ xong: text trong ô input + hint "Gửi để tiếp ↑", CHƯA reveal.
    expect(find.textContaining('Xin chào nha', findRichText: true),
        findsOneWidget);
    expect(find.text('Gửi để tiếp ↑'), findsOneWidget);

    // Chạm vùng chat khi chờ Gửi → KHÔNG tự tiến (mirror web).
    await tester.tap(find.byType(ChatChapterView));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byIcon(Icons.send), findsOneWidget);

    // Bấm Gửi → bubble hiện, thanh input biến mất.
    await tester.tap(find.byIcon(Icons.send));
    await tester.pumpAndSettle();
    expect(find.text('Xin chào nha'), findsOneWidget);
    expect(find.byIcon(Icons.send), findsNothing);
  });

  testWidgets('không tự nối chuỗi vô hạn — dừng chờ chạm giữa các tin',
      (tester) async {
    await pumpChat(tester, [
      dialogue('c1', 'Tin một.'),
      dialogue('c1', 'Tin hai.'),
    ]);
    // Tin đầu tự chơi (chỉ báo đang gõ 400ms) rồi DỰNG.
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Tin một.'), findsOneWidget);
    expect(find.text('Tin hai.'), findsNothing);

    // Chạm → tin hai chơi (đang gõ rồi hiện).
    await tester.tap(find.byType(ChatChapterView));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.textContaining('đang gõ'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('Tin hai.'), findsOneWidget);
    expect(find.text('— hết chương —'), findsOneWidget);
  });

  testWidgets('action/narration/system hiển thị đúng kiểu (nghiêng/giữa)',
      (tester) async {
    await pumpChat(tester, const [
      ChatMessage(id: 'm1', characterId: null, content: 'hít một hơi sâu', messageType: 'action'),
      ChatMessage(id: 'm2', characterId: null, content: 'Bầu trời tối sầm.', messageType: 'narration'),
      ChatMessage(id: 'm3', characterId: null, content: 'Hệ thống đã online', messageType: 'system'),
    ]);
    // Chuỗi KHÔNG tự nối: mỗi tin cần một chạm (mirror web).
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('✦ hít một hơi sâu'), findsOneWidget);

    await tester.tap(find.byType(ChatChapterView));
    await tester.pump(const Duration(milliseconds: 200));
    final narration = tester.widget<Text>(find.text('Bầu trời tối sầm.'));
    expect(narration.style?.fontStyle, FontStyle.italic);

    await tester.tap(find.byType(ChatChapterView));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('Hệ thống đã online'), findsOneWidget);
  });

  testWidgets('hết chương: text hiện ngay, nav xuất hiện sau delay 1200ms',
      (tester) async {
    await pumpChat(tester, [
      dialogue('c1', 'Một.'),
      dialogue('me', 'Hai.'),
    ]);
    // c1: chỉ báo đang gõ clamp(4*25=100→400ms).
    await tester.pump(const Duration(milliseconds: 450));
    expect(find.text('Một.'), findsOneWidget);
    // Chạm để sang tin "Bạn" → input gõ dần: prefill 350ms + 4 ký tự
    // * 35ms + trễ gửi 450ms → commit.
    await tester.tap(find.byType(ChatChapterView));
    await tester.pump(const Duration(milliseconds: 360));
    await tester.pump(const Duration(milliseconds: 40));
    await tester.pump(const Duration(milliseconds: 40));
    await tester.pump(const Duration(milliseconds: 40));
    await tester.pump(const Duration(milliseconds: 40));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.textContaining('Hai.', findRichText: true), findsOneWidget);
    // Bấm Gửi → tin được đưa lên, tới hết chương.
    await tester.tap(find.byIcon(Icons.send));
    await tester.pump();
    expect(find.text('— hết chương —'), findsOneWidget);
    // Nav cuối chương xuất hiện sau delay 1200ms của web-mirror.
    expect(find.text('Sau'), findsNothing);
    await tester.pump(const Duration(milliseconds: 1300));
    await tester.pump();
    expect(find.text('Sau'), findsOneWidget);
  });
}
