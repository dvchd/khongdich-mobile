import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:khongdich_mobile/features/tts/tts_audio_handler.dart';

/// Tests cho notification controls của TTS — khóa ngữ nghĩa:
///   - Luôn đủ 4 nút: skipToPrevious | play/pause | skipToNext | stop.
///   - Nút giữa đổi play↔pause theo trạng thái.
///   - Thứ tự nút ổn định để `androidCompactActionIndices [0,1,2]`
///     (compact view: prev | play/pause | next) luôn hợp lệ — nếu
///     danh sách thiếu nút thì chỉ số compact có thể vượt danh sách
///     và crash platform side.
void main() {
  group('buildTtsControls', () {
    test('đang phát → pause + đủ prev/next/stop', () {
      final controls = buildTtsControls(playing: true);
      expect(controls.length, 4);
      expect(controls[0].action, MediaAction.skipToPrevious);
      expect(controls[1].action, MediaAction.pause);
      expect(controls[2].action, MediaAction.skipToNext);
      expect(controls[3].action, MediaAction.stop);
    });

    test('tạm dừng → play + đủ prev/next/stop', () {
      final controls = buildTtsControls(playing: false);
      expect(controls.length, 4);
      expect(controls[0].action, MediaAction.skipToPrevious);
      expect(controls[1].action, MediaAction.play);
      expect(controls[2].action, MediaAction.skipToNext);
      expect(controls[3].action, MediaAction.stop);
    });

    test('3 nút compact đầu luôn là prev/play-pause/next', () {
      for (final playing in [true, false]) {
        final controls = buildTtsControls(playing: playing);
        const compact = [0, 1, 2];
        final compactActions = [
          for (final i in compact) controls[i].action,
        ];
        expect(
          compactActions,
          [
            MediaAction.skipToPrevious,
            playing ? MediaAction.pause : MediaAction.play,
            MediaAction.skipToNext,
          ],
        );
      }
    });
  });
}
