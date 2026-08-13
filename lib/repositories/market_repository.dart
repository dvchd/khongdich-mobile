import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/network/api_client.dart';
import '../models/market.dart';

/// Client for the Chợ Phiên / Họp Chợ endpoints mounted at
/// `/api/v1/mobile/market/*` (same handlers as the web market API,
/// re-mounted under the Bearer-JWT mobile prefix).
class MarketRepository {
  MarketRepository(this._api);

  final ApiClient _api;
  Dio get _dio => _api.dio;

  /// Fetch the home section payload (status, master, story grid, chat).
  /// Hits `GET /api/v1/mobile/market`.
  Future<MarketSection> fetchSection() async {
    final r = await _dio.get('/api/v1/mobile/market');
    return MarketSection.fromJson(r.data as Map<String, dynamic>);
  }

  /// Recent chat messages (oldest first). Hits `GET /api/v1/mobile/market/chat`.
  Future<List<MarketMessage>> fetchHistory() async {
    final r = await _dio.get('/api/v1/mobile/market/chat');
    final data = r.data as Map<String, dynamic>;
    return [
      for (final m in (data['messages'] as List? ?? const []))
        MarketMessage.fromJson(m as Map<String, dynamic>),
    ];
  }

  /// Post a chat message. The backend rejects when the chợ is closed,
  /// runs the content filter, and attaches a random public story when
  /// the caller is an author. Hits `POST /api/v1/mobile/market/chat`.
  Future<MarketPostResult> postMessage(String content) async {
    final r = await _dio.post('/api/v1/mobile/market/chat', data: {
      'content': content,
    });
    final data = r.data as Map<String, dynamic>;
    return MarketPostResult(
      message: MarketMessage.fromJson(data['message'] as Map<String, dynamic>),
      hidden: data['hidden'] as bool? ?? false,
    );
  }

  /// Subscribe to the realtime SSE stream.
  ///
  /// Emits `(message, storyAdded)` for every `chat` event and re-subscribes
  /// automatically after network drops. The returned subscription must be
  /// cancelled by the caller (dispose). Hits `GET /api/v1/mobile/market/stream`.
  StreamSubscription<(MarketMessage, bool)> subscribeToStream(
    void Function((MarketMessage, bool) event) onEvent,
  ) {
    final controller = StreamController<(MarketMessage, bool)>();

    Future<void> connect() async {
      try {
        final response = await _dio.get<ResponseBody>(
          '/api/v1/mobile/market/stream',
          options: Options(
            responseType: ResponseType.stream,
            headers: {'Accept': 'text/event-stream'},
            receiveTimeout: const Duration(hours: 1),
          ),
        );
        final stream = response.data!.stream
            .cast<List<int>>()
            .transform(utf8.decoder)
            .transform(const LineSplitter());
        await for (final line in stream) {
          if (line.startsWith('data:')) {
            final payload = line.substring(5).trim();
            if (payload.isEmpty) continue;
            try {
              final event = jsonDecode(payload) as Map<String, dynamic>;
              final raw = event['message'] as Map<String, dynamic>;
              controller.add((
                MarketMessage.fromJson(raw),
                event['story_added'] as bool? ?? false,
              ));
            } catch (_) {
              // Malformed event — skip, keep the stream alive.
            }
          }
        }
        // Server closed the stream cleanly — reconnect after a pause.
        if (!controller.isClosed) {
          await Future.delayed(const Duration(seconds: 3));
          if (!controller.isClosed) unawaited(connect());
        }
      } catch (_) {
        if (!controller.isClosed) {
          await Future.delayed(const Duration(seconds: 3));
          if (!controller.isClosed) unawaited(connect());
        }
      }
    }

    unawaited(connect());
    return controller.stream.listen(onEvent);
  }
}

/// Result of posting a chat message.
class MarketPostResult {
  const MarketPostResult({required this.message, this.hidden = false});
  final MarketMessage message;

  /// True when the content filter auto-hid the message.
  final bool hidden;
}

final marketRepositoryProvider = Provider<MarketRepository>((ref) {
  final api = ref
      .watch(apiClientProvider)
      .maybeWhen(
        data: (c) => c,
        orElse: () => throw StateError('ApiClient not ready'),
      );
  return MarketRepository(api);
});
