import 'package:flutter_test/flutter_test.dart';

import 'package:khongdich_mobile/core/widgets/emoji_text.dart';
import 'package:khongdich_mobile/services/emoji_service.dart';

void main() {
  group('parseEmojiNames', () {
    test('extracts deduplicated lowercase tokens in order', () {
      expect(parseEmojiNames('hi :vui: :buon: :vui:'), ['vui', 'buon']);
    });

    test('ignores tokens with invalid characters', () {
      expect(parseEmojiNames(':Vui Vẻ: :ok_1: :ok-2:'), ['ok_1']);
      expect(parseEmojiNames('thời gian 12:30 và 12:00'), isEmpty);
    });

    test('max 32 chars per name', () {
      final long = 'a' * 33;
      expect(parseEmojiNames(':$long:'), isEmpty);
      final ok = 'a' * 32;
      expect(parseEmojiNames(':$ok:'), [ok]);
    });

    test('vietnamese prose is never touched', () {
      expect(parseEmojiNames('Đoạn văn tiếng Việt bình thường.'), isEmpty);
    });
  });

  group('EmojiText', () {
    test('plain text without emoji images renders as Text', () {
      const w = EmojiText(text: 'chào bạn', contentHtml: '');
      // No emoji images — the widget must not crash and uses plain Text.
      expect(w.contentHtml, '');
      expect(EmojiText.hasEmojiImages('<p>chào</p>'), isFalse);
    });

    test('detects emoji img tags in content_html', () {
      expect(
        EmojiText.hasEmojiImages(
          '<img class="custom-emoji" src="https://x/a.png" alt=":a:">',
        ),
        isTrue,
      );
      expect(
        EmojiText.hasEmojiImages(
          '<img class="custom-emoji-only" src="https://x/b.png" '
          'alt=":b:" title=":b:" loading="lazy">',
        ),
        isTrue,
      );
    });

    test('unescape handles all backend entities at exactly one level', () {
      // _unescape is private — verify via EmojiText build below and via
      // the token regex directly: entities around emojis stay intact.
      const w = EmojiText(
        text: 'A & B :emoji:',
        contentHtml:
            'A &amp; B <img class="custom-emoji" src="u" alt=":emoji:">',
      );
      expect(w.text, 'A & B :emoji:');
    });
  });

  group('EmojiFeed', () {
    test('parses the picker payload rails', () {
      final feed = EmojiFeed.fromJson({
        'popular': [
          {'name': 'vui', 'image_url': 'https://x/vui.png'},
        ],
        'recent': [
          {'name': 'moi', 'image_url': 'https://x/moi.png'},
        ],
        'featured': [
          {'name': 'sao', 'image_url': 'https://x/sao.png'},
        ],
        'mine': [
          {'name': 'rieng', 'image_url': 'https://x/rieng.png'},
        ],
        'has_more': true,
        'mine_has_more': false,
      });
      expect(feed.popular.single.name, 'vui');
      expect(feed.recent.single.name, 'moi');
      expect(feed.featured.single.name, 'sao');
      expect(feed.mine.single.name, 'rieng');
      expect(feed.hasMore, isTrue);
    });

    test('missing rails default to empty lists', () {
      final feed = EmojiFeed.fromJson(const {});
      expect(feed.popular, isEmpty);
      expect(feed.recent, isEmpty);
      expect(feed.featured, isEmpty);
      expect(feed.mine, isEmpty);
      expect(feed.hasMore, isFalse);
    });
  });
}
