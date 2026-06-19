import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:html/dom.dart' as html_dom;

import '../core/network/api_client.dart';
import '../models/chapter_content.dart';

/// Reads chapter content by scraping the SSR reader page
/// (`/truyen/{slug}/chuong/{num}`) — the backend does not yet expose
/// `GET /api/v1/chapters/{id}` as a discriminated-union JSON endpoint
/// (plan §12.2 is MISSING).
///
/// For each `content_type`, we extract the data from the server-rendered
/// HTML and reconstruct the [ChapterContent] payload:
///
///   - `text`: the raw markdown / plain text is NOT in the HTML (the
///     backend renders it to HTML server-side). We capture the rendered
///     HTML and store it as `contentMarkdown` so the [MarkdownRenderer]
///     can fall back to a basic HTML→text path. When the backend ships
///     `content_markdown` in JSON, this method becomes a one-line swap.
///   - `manga`: image URLs from `.chapter-images img[src]`.
///   - `chat`: messages from `.chat-message` rows (with `data-side` and
///     `data-speaker` attributes).
///   - `video`: the YouTube embed URL from `iframe[src*="youtube.com"]`
///     or `iframe[src*="youtu.be"]`.
class ChapterReaderDataSource {
  ChapterReaderDataSource(this._api);

  final ApiClient _api;
  Dio get _dio => _api.dio;

  /// Fetch chapter `num` of story `slug`.
  Future<ChapterContent> fetchChapter({
    required String storySlug,
    required int chapterNumber,
    String? chapterId,
  }) async {
    final url = '/truyen/$storySlug/chuong/$chapterNumber';
    final r = await _dio.get<String>(
      url,
      options: Options(responseType: ResponseType.json, headers: {'Accept': 'text/html'}),
    );
    return _parse(r.data ?? '', storySlug, chapterNumber, chapterId);
  }

  ChapterContent _parse(
    String html,
    String storySlug,
    int chapterNumber,
    String? chapterId,
  ) {
    final doc = html_parser.parse(html);

    // Common fields pulled from the page meta.
    final storyTitle = doc
            .querySelector('.story-title, h2.story-title, [data-story-title]')
            ?.text
            .trim() ??
        storySlug;
    final title = doc
            .querySelector('.chapter-title, h1.chapter-title, h1')
            ?.text
            .trim() ??
        'Chương $chapterNumber';
    final storyId =
        doc.querySelector('[data-story-id]')?.attributes['data-story-id'] ??
            storySlug;
    final contentType =
        doc.querySelector('[data-content-type]')?.attributes['data-content-type'] ??
            'text';
    final updatedAt = DateTime.tryParse(
          doc.querySelector('[data-updated-at]')?.attributes['data-updated-at'] ?? '',
        ) ??
        DateTime.now();
    final prevChapter = int.tryParse(
          doc.querySelector('a.prev-chapter')?.attributes['data-num'] ?? '',
        ) ??
        _extractChapterNumberFromHref(
          doc.querySelector('a.prev-chapter')?.attributes['href'] ?? '',
        );
    final nextChapter = int.tryParse(
          doc.querySelector('a.next-chapter')?.attributes['data-num'] ?? '',
        ) ??
        _extractChapterNumberFromHref(
          doc.querySelector('a.next-chapter')?.attributes['href'] ?? '',
        );

    // Content body — depends on content_type.
    final common = _CommonChapterFields(
      id: chapterId ?? '$storySlug-$chapterNumber',
      storyId: storyId,
      storyTitle: storyTitle,
      storySlug: storySlug,
      chapterNumber: chapterNumber,
      title: title,
      contentVersion: 1,
      wordCount:
          int.tryParse(doc.querySelector('[data-word-count]')?.attributes['data-word-count'] ?? '') ??
              0,
      isPublished: true,
      prevChapter: prevChapter,
      nextChapter: nextChapter,
      updatedAt: updatedAt,
    );

    switch (contentType) {
      case 'manga':
        return _buildManga(common, doc);
      case 'chat':
        return _buildChat(common, doc);
      case 'video':
        return _buildVideo(common, doc);
      case 'text':
      default:
        return _buildText(common, doc);
    }
  }

  int? _extractChapterNumberFromHref(String href) {
    final m = RegExp(r'chuong-(\d+)|/(\d+)/?$').firstMatch(href);
    if (m == null) return null;
    return int.tryParse(m.group(1) ?? m.group(2) ?? '');
  }

  ChapterContent _buildText(_CommonChapterFields c, html_dom.Document doc) {
    // Prefer the raw markdown if the backend ever exposes it; otherwise
    // capture the rendered HTML and strip tags for the renderer.
    final rawMd =
        doc.querySelector('[data-content-markdown]')?.attributes['data-content-markdown'];
    String body;
    if (rawMd != null && rawMd.isNotEmpty) {
      body = rawMd;
    } else {
      final container = doc.querySelector('.chapter-content, .content, article');
      final html = container?.innerHtml ?? '';
      body = _htmlToMarkdown(html);
    }
    return TextChapterContent(
      id: c.id,
      storyId: c.storyId,
      storyTitle: c.storyTitle,
      storySlug: c.storySlug,
      chapterNumber: c.chapterNumber,
      title: c.title,
      contentVersion: c.contentVersion,
      wordCount: c.wordCount,
      isPublished: c.isPublished,
      prevChapter: c.prevChapter,
      nextChapter: c.nextChapter,
      updatedAt: c.updatedAt,
      contentMarkdown: body,
    );
  }

  ChapterContent _buildManga(_CommonChapterFields c, html_dom.Document doc) {
    final imgs = doc.querySelectorAll('.chapter-images img, .manga-page img');
    final pages = <MangaPage>[
      for (final img in imgs)
        if ((img.attributes['src'] ?? img.attributes['data-src']) != null)
          MangaPage(
            url: _absoluteUrl(img.attributes['src'] ?? img.attributes['data-src']!),
            width: int.tryParse(img.attributes['width'] ?? ''),
            height: int.tryParse(img.attributes['height'] ?? ''),
          ),
    ];
    return MangaChapterContent(
      id: c.id,
      storyId: c.storyId,
      storyTitle: c.storyTitle,
      storySlug: c.storySlug,
      chapterNumber: c.chapterNumber,
      title: c.title,
      contentVersion: c.contentVersion,
      wordCount: c.wordCount,
      isPublished: c.isPublished,
      prevChapter: c.prevChapter,
      nextChapter: c.nextChapter,
      updatedAt: c.updatedAt,
      images: pages,
    );
  }

  ChapterContent _buildChat(_CommonChapterFields c, html_dom.Document doc) {
    // Participants.
    final participants = <ChatParticipant>[
      for (final el in doc.querySelectorAll('.chat-participant, [data-participant-id]'))
        ChatParticipant(
          id: el.attributes['data-participant-id'] ??
              el.querySelector('.name')?.text.trim() ??
              '?',
          name: el.querySelector('.name')?.text.trim() ??
              el.attributes['data-name'] ??
              '?',
          avatar: el.querySelector('img')?.attributes['src'],
          color: el.attributes['data-color'],
        ),
    ];

    // Messages.
    final messages = <ChatMessage>[];
    for (final el in doc.querySelectorAll('.chat-message, .message')) {
      final side = el.attributes['data-side'] ??
          (el.classes.contains('right') ? 'right' : 'left');
      final text = el.querySelector('.text, .content')?.text.trim() ?? '';
      if (text.isEmpty) continue;
      messages.add(ChatMessage(
        speakerId: el.attributes['data-speaker-id'],
        text: text,
        side: side,
      ));
    }
    return ChatChapterContent(
      id: c.id,
      storyId: c.storyId,
      storyTitle: c.storyTitle,
      storySlug: c.storySlug,
      chapterNumber: c.chapterNumber,
      title: c.title,
      contentVersion: c.contentVersion,
      wordCount: c.wordCount,
      isPublished: c.isPublished,
      prevChapter: c.prevChapter,
      nextChapter: c.nextChapter,
      updatedAt: c.updatedAt,
      participants: participants,
      messages: messages,
    );
  }

  ChapterContent _buildVideo(_CommonChapterFields c, html_dom.Document doc) {
    final iframe = doc.querySelector('iframe[src*="youtube"], iframe[src*="youtu.be"]');
    final src = iframe?.attributes['src'] ?? '';
    final videoId = _extractYouTubeId(src);
    final caption = doc.querySelector('.video-caption, .caption')?.innerHtml;
    return VideoChapterContent(
      id: c.id,
      storyId: c.storyId,
      storyTitle: c.storyTitle,
      storySlug: c.storySlug,
      chapterNumber: c.chapterNumber,
      title: c.title,
      contentVersion: c.contentVersion,
      wordCount: c.wordCount,
      isPublished: c.isPublished,
      prevChapter: c.prevChapter,
      nextChapter: c.nextChapter,
      updatedAt: c.updatedAt,
      video: VideoInfo(
        provider: 'youtube',
        videoId: videoId ?? '',
        startSeconds: 0,
      ),
      captionMarkdown: caption == null ? null : _htmlToMarkdown(caption),
    );
  }

  String? _extractYouTubeId(String url) {
    final patterns = [
      RegExp(r'youtube\.com/embed/([A-Za-z0-9_-]{6,})'),
      RegExp(r'youtube\.com/watch\?v=([A-Za-z0-9_-]{6,})'),
      RegExp(r'youtu\.be/([A-Za-z0-9_-]{6,})'),
    ];
    for (final p in patterns) {
      final m = p.firstMatch(url);
      if (m != null) return m.group(1);
    }
    return null;
  }

  /// Lossy HTML → markdown-ish conversion. The renderer downstream
  /// ([MarkdownRenderer]) will then re-parse this. We keep the surface
  /// small: headings, paragraphs, bold, italic, links, images, lists,
  /// blockquotes, code.
  String _htmlToMarkdown(String html) {
    final doc = html_parser.parseFragment(html);
    final buf = StringBuffer();
    _walkNode(doc, buf, _StackState());
    return buf.toString().trim();
  }

  void _walkNode(dynamic node, StringBuffer out, _StackState state) {
    if (node.nodeType == 3) {
      // Text node.
      out.write(node.text.toString());
      return;
    }
    if (node.nodeType != 1) return;
    final el = node as html_dom.Element;
    final tag = el.localName?.toLowerCase() ?? '';
    switch (tag) {
      case 'h1':
      case 'h2':
      case 'h3':
      case 'h4':
      case 'h5':
      case 'h6':
        out.write('\n\n');
        out.write('#' * int.parse(tag.substring(1)));
        out.write(' ');
        _walkChildren(el, out, state);
        out.write('\n\n');
        break;
      case 'p':
        out.write('\n\n');
        _walkChildren(el, out, state);
        out.write('\n\n');
        break;
      case 'br':
        out.write('  \n');
        break;
      case 'strong':
      case 'b':
        out.write('**');
        _walkChildren(el, out, state);
        out.write('**');
        break;
      case 'em':
      case 'i':
        out.write('*');
        _walkChildren(el, out, state);
        out.write('*');
        break;
      case 'del':
      case 's':
        out.write('~~');
        _walkChildren(el, out, state);
        out.write('~~');
        break;
      case 'a':
        final href = el.attributes['href'] ?? '';
        out.write('[');
        _walkChildren(el, out, state);
        out.write(']($href)');
        break;
      case 'img':
        final src = el.attributes['src'] ?? '';
        final alt = el.attributes['alt'] ?? '';
        out.write('![$alt]($src)');
        break;
      case 'ul':
        out.write('\n');
        for (final child in el.children) {
          if (child.localName == 'li') {
            out.write('- ');
            _walkChildren(child, out, state);
            out.write('\n');
          }
        }
        out.write('\n');
        break;
      case 'ol':
        out.write('\n');
        var i = 1;
        for (final child in el.children) {
          if (child.localName == 'li') {
            out.write('$i. ');
            _walkChildren(child, out, state);
            out.write('\n');
            i++;
          }
        }
        out.write('\n');
        break;
      case 'blockquote':
        out.write('\n');
        for (final line in el.text.split('\n')) {
          out.write('> $line\n');
        }
        out.write('\n');
        break;
      case 'pre':
        final code = el.text;
        out.write('\n```\n$code\n```\n\n');
        break;
      case 'code':
        out.write('`');
        out.write(el.text);
        out.write('`');
        break;
      case 'hr':
        out.write('\n\n---\n\n');
        break;
      default:
        _walkChildren(el, out, state);
    }
  }

  void _walkChildren(html_dom.Element el, StringBuffer out, _StackState state) {
    for (final child in el.nodes) {
      _walkNode(child, out, state);
    }
  }

  String _absoluteUrl(String maybeRelative) {
    if (maybeRelative.startsWith('http://') ||
        maybeRelative.startsWith('https://')) {
      return maybeRelative;
    }
    if (maybeRelative.startsWith('//')) {
      return 'https:$maybeRelative';
    }
    if (maybeRelative.startsWith('/')) {
      return '${_api.baseUrl}$maybeRelative';
    }
    return '${_api.baseUrl}/$maybeRelative';
  }
}

class _StackState {
  // Reserved for future nesting tracking (ordered list index, etc.).
}

class _CommonChapterFields {
  const _CommonChapterFields({
    required this.id,
    required this.storyId,
    required this.storyTitle,
    required this.storySlug,
    required this.chapterNumber,
    required this.title,
    required this.contentVersion,
    required this.wordCount,
    required this.isPublished,
    required this.prevChapter,
    required this.nextChapter,
    required this.updatedAt,
  });
  final String id;
  final String storyId;
  final String storyTitle;
  final String storySlug;
  final int chapterNumber;
  final String title;
  final int contentVersion;
  final int wordCount;
  final bool isPublished;
  final int? prevChapter;
  final int? nextChapter;
  final DateTime updatedAt;
}

final chapterReaderDataSourceProvider = Provider<ChapterReaderDataSource>((ref) {
  final api = ref.watch(apiClientProvider).maybeWhen(
        data: (c) => c,
        orElse: () => throw StateError('ApiClient not ready'),
      );
  return ChapterReaderDataSource(api);
});
