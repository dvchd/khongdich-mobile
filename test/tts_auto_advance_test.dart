import 'package:flutter_test/flutter_test.dart';
import 'package:khongdich_mobile/features/tts/tts_audio_handler.dart';

/// Regression tests cho logic auto-advance của TTS.
///
/// Design: handler broadcast `TtsChapterCompleteEvent` khi đọc xong chương
/// (tự nhiên hoặc skip thủ công). Màn hình reader quyết định chuyển chương
/// qua hàm thuần `shouldAutoAdvanceTts` — tách riêng để khoá ngữ nghĩa:
///   - Pause KHÔNG tắt chuỗi tự chuyển (resume vẫn tiếp tục).
///   - Nút Stop (stopAutoAdvance) tắt chuỗi — hết chương không tự nhảy.
///   - Skip thủ công LUÔN chuyển chương (kể cả khi chuỗi đã tắt).
///   - Chương cuối (nextChapterNumber null) không chuyển.
void main() {
  group('shouldAutoAdvanceTts', () {
    test('auto-advance bật + có chương kế → chuyển', () {
      expect(
        shouldAutoAdvanceTts(
          matchesCurrentChapter: true,
          autoAdvanceEnabled: true,
          manualSkip: false,
          nextChapterNumber: 6,
        ),
        isTrue,
      );
    });

    test('auto-advance tắt (đã Stop) + hết chương tự nhiên → không chuyển',
        () {
      expect(
        shouldAutoAdvanceTts(
          matchesCurrentChapter: true,
          autoAdvanceEnabled: false,
          manualSkip: false,
          nextChapterNumber: 6,
        ),
        isFalse,
      );
    });

    test('skip thủ công luôn chuyển kể cả khi chuỗi đã tắt', () {
      expect(
        shouldAutoAdvanceTts(
          matchesCurrentChapter: true,
          autoAdvanceEnabled: false,
          manualSkip: true,
          nextChapterNumber: 6,
        ),
        isTrue,
      );
    });

    test('chương cuối (nextChapterNumber null) không chuyển', () {
      expect(
        shouldAutoAdvanceTts(
          matchesCurrentChapter: true,
          autoAdvanceEnabled: true,
          manualSkip: false,
          nextChapterNumber: null,
        ),
        isFalse,
      );
    });

    test('event của chương khác (màn hình khác) không chuyển', () {
      expect(
        shouldAutoAdvanceTts(
          matchesCurrentChapter: false,
          autoAdvanceEnabled: true,
          manualSkip: true,
          nextChapterNumber: 6,
        ),
        isFalse,
      );
    });

    test('skipToPrevious (manualSkip) chuyển về chương trước dù chuỗi tắt',
        () {
      // Event của skipToPrevious mang số chương TRƯỚC trong
      // nextChapterNumber — manualSkip=true nên màn hình vẫn điều hướng
      // kể cả khi autoAdvanceEnabled=false.
      expect(
        shouldAutoAdvanceTts(
          matchesCurrentChapter: true,
          autoAdvanceEnabled: false,
          manualSkip: true,
          nextChapterNumber: 4,
        ),
        isTrue,
      );
    });

    test('skip ở chương đầu/cuối (không có đích) không chuyển', () {
      expect(
        shouldAutoAdvanceTts(
          matchesCurrentChapter: true,
          autoAdvanceEnabled: true,
          manualSkip: true,
          nextChapterNumber: null,
        ),
        isFalse,
      );
    });
  });

  group('TtsChapterCompleteEvent', () {
    test('mang đầy đủ thông tin để màn hình quyết định', () {
      const event = TtsChapterCompleteEvent(
        chapterId: 'ch-5',
        chapterNumber: 5,
        storyId: 'story-1',
        nextChapterNumber: 6,
        manualSkip: false,
      );
      expect(event.chapterId, 'ch-5');
      expect(event.chapterNumber, 5);
      expect(event.storyId, 'story-1');
      expect(event.nextChapterNumber, 6);
      expect(event.manualSkip, isFalse);
    });

    test('event skip thủ công đánh dấu manualSkip', () {
      const event = TtsChapterCompleteEvent(
        chapterId: 'ch-5',
        chapterNumber: 5,
        storyId: 'story-1',
        nextChapterNumber: 4,
        manualSkip: true,
      );
      expect(event.manualSkip, isTrue);
      expect(event.nextChapterNumber, 4);
    });
  });
}
