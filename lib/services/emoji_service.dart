import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/network/api_client.dart';

/// A single custom emoji from the backend picker feed.
class EmojiItem {
  const EmojiItem({required this.name, required this.imageUrl});
  final String name;
  final String imageUrl;

  factory EmojiItem.fromJson(Map<String, dynamic> json) => EmojiItem(
    name: json['name'] as String? ?? '',
    imageUrl: json['image_url'] as String? ?? '',
  );
}

/// Picker payload from `GET /api/v1/mobile/emojis` — rails mirror the
/// web picker: featured (admin-curated), recent, popular, mine.
class EmojiFeed {
  const EmojiFeed({
    required this.popular,
    required this.recent,
    required this.featured,
    required this.mine,
    required this.hasMore,
  });

  final List<EmojiItem> popular;
  final List<EmojiItem> recent;
  final List<EmojiItem> featured;
  final List<EmojiItem> mine;
  final bool hasMore;

  factory EmojiFeed.fromJson(Map<String, dynamic> json) => EmojiFeed(
    popular: [
      for (final e in (json['popular'] as List? ?? const []))
        EmojiItem.fromJson(e as Map<String, dynamic>),
    ],
    recent: [
      for (final e in (json['recent'] as List? ?? const []))
        EmojiItem.fromJson(e as Map<String, dynamic>),
    ],
    featured: [
      for (final e in (json['featured'] as List? ?? const []))
        EmojiItem.fromJson(e as Map<String, dynamic>),
    ],
    mine: [
      for (final e in (json['mine'] as List? ?? const []))
        EmojiItem.fromJson(e as Map<String, dynamic>),
    ],
    hasMore: json['has_more'] as bool? ?? false,
  );
}

/// Resolves `:name:` tokens to image URLs and serves the emoji picker
/// payload — mirrors the web's picker + live-preview behaviour.
///
/// Rendering flow: the raw comment/chat text keeps `:name:` tokens;
/// [EmojiText] looks each token up in the resolved map. Names missing
/// from the paginated feed window are resolved on-demand via
/// `GET /api/v1/mobile/emojis/resolve?name=…` (same fallback the web's
/// comment box uses for live preview) and cached for the session.
class EmojiService {
  EmojiService(this._api);

  final ApiClient _api;
  final Map<String, String> _resolved = {};

  /// Names that failed to resolve (avoid repeat network calls).
  final Set<String> _unresolved = {};

  EmojiFeed? _feed;

  /// Feed loaded from the picker endpoint (or null until first fetch).
  EmojiFeed? get feed => _feed;

  /// Fetch (or return the cached) picker feed.
  Future<EmojiFeed> loadFeed() async {
    if (_feed != null) return _feed!;
    try {
      final r = await _api.dio.get('/api/v1/mobile/emojis');
      _feed = EmojiFeed.fromJson(r.data as Map<String, dynamic>);
      for (final e in [
        ..._feed!.popular,
        ..._feed!.recent,
        ..._feed!.featured,
        ..._feed!.mine,
      ]) {
        if (e.name.isNotEmpty && e.imageUrl.isNotEmpty) {
          _resolved[e.name] = e.imageUrl;
        }
      }
    } catch (_) {
      // Best-effort — the picker falls back to an empty grid and the
      // resolver keeps working for individual tokens.
      _feed = const EmojiFeed(
        popular: [],
        recent: [],
        featured: [],
        mine: [],
        hasMore: false,
      );
    }
    return _feed!;
  }

  /// Search emojis by name (picker search field).
  Future<List<EmojiItem>> search(String q) async {
    try {
      final r = await _api.dio.get('/api/v1/mobile/emojis', queryParameters: {
        'q': q,
      });
      final feed = EmojiFeed.fromJson(r.data as Map<String, dynamic>);
      return feed.popular;
    } catch (_) {
      return const [];
    }
  }

  /// Load the next popular page ("Xem thêm" in the picker).
  Future<List<EmojiItem>> loadMorePopular(int offset, {int limit = 120}) async {
    try {
      final r = await _api.dio.get('/api/v1/mobile/emojis', queryParameters: {
        'offset': offset,
        'limit': limit,
      });
      final feed = EmojiFeed.fromJson(r.data as Map<String, dynamic>);
      _mergeFeed(feed);
      return feed.popular;
    } catch (_) {
      return const [];
    }
  }

  void _mergeFeed(EmojiFeed next) {
    final seen = {for (final e in _feed?.popular ?? <EmojiItem>[]) e.name};
    final popular = [
      ...?_feed?.popular,
      ...next.popular.where((e) => seen.add(e.name)),
    ];
    _feed = EmojiFeed(
      popular: popular,
      recent: _feed?.recent ?? const [],
      featured: _feed?.featured ?? const [],
      mine: _feed?.mine ?? const [],
      hasMore: next.hasMore,
    );
    for (final e in popular) {
      if (e.name.isNotEmpty && e.imageUrl.isNotEmpty) {
        _resolved[e.name] = e.imageUrl;
      }
    }
  }

  /// Resolve a single `:name:` token to its image URL (cached).
  Future<String?> resolve(String name) async {
    final key = name.toLowerCase();
    final cached = _resolved[key];
    if (cached != null) return cached;
    if (_unresolved.contains(key)) return null;
    try {
      final r = await _api.dio.get(
        '/api/v1/mobile/emojis/resolve',
        queryParameters: {'name': key},
      );
      final url = (r.data as Map<String, dynamic>)['url'] as String?;
      if (url != null && url.isNotEmpty) {
        _resolved[key] = url;
        return url;
      }
      _unresolved.add(key);
    } catch (_) {
      _unresolved.add(key);
    }
    return null;
  }
}

final emojiServiceProvider = Provider<EmojiService>((ref) {
  final api = ref
      .watch(apiClientProvider)
      .maybeWhen(
        data: (c) => c,
        orElse: () => throw StateError('ApiClient not ready'),
      );
  return EmojiService(api);
});

/// `:name:` token regex — identical to the backend's `EMOJI_TOKEN_RE`
/// (`src/utils.rs`): 1-32 lowercase ASCII letters/digits/underscores, so
/// Vietnamese prose is never touched.
final RegExp emojiTokenRe = RegExp(r':([a-z0-9_]{1,32}):');

/// Extract `:name:` tokens from free text, in order, deduplicated —
/// mirrors `parse_emoji_names` in the backend.
List<String> parseEmojiNames(String text) {
  final names = <String>[];
  final seen = <String>{};
  for (final m in emojiTokenRe.allMatches(text)) {
    final name = m.group(1)!;
    if (seen.add(name)) names.add(name);
  }
  return names;
}
