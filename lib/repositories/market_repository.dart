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
  /// Emits a [MarketMessageEvent] for every `chat` event and a
  /// [MarketResetEvent] for every `reset` event (weekly session wipe /
  /// Chủ Chợ change). Re-subscribes automatically after network drops,
  /// and replays the latest history after every (re)connect so messages
  /// posted while the connection was down are not lost (the UI dedupes
  /// by id). The returned subscription must be cancelled by the caller
  /// (dispose). Hits `GET /api/v1/mobile/market/stream`.
  StreamSubscription<MarketStreamEvent> subscribeToStream(
    void Function(MarketStreamEvent event) onEvent,
  ) {
    final controller = StreamController<MarketStreamEvent>();

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
        // Catch-up: EventSource does not replay messages sent while the
        // connection was down — pull the latest history on every connect.
        try {
          final history = await fetchHistory();
          for (final m in history) {
            if (!controller.isClosed) {
              controller.add(MarketMessageEvent(message: m, storyAdded: false));
            }
          }
        } catch (_) {
          // Best-effort: live events still flow if history fails.
        }
        final stream = response.data!.stream
            .cast<List<int>>()
            .transform(utf8.decoder)
            .transform(const LineSplitter());
        var eventName = 'chat';
        await for (final line in stream) {
          if (line.startsWith('event:')) {
            eventName = line.substring(6).trim();
            continue;
          }
          if (line.startsWith('data:')) {
            final payload = line.substring(5).trim();
            if (payload.isEmpty) continue;
            try {
              final event = jsonDecode(payload) as Map<String, dynamic>;
              switch (eventName) {
                case 'reset':
                  controller.add(MarketResetEvent(
                    masterId: event['master_id'] as String?,
                    masterUsername: event['master_username'] as String?,
                    masterDisplayName: event['master_display_name'] as String?,
                  ));
                case 'edit':
                  final raw = event['message'] as Map<String, dynamic>;
                  controller.add(
                    MarketEditEvent(message: MarketMessage.fromJson(raw)),
                  );
                case 'delete':
                  controller.add(
                    MarketDeleteEvent(id: event['id'] as String),
                  );
                default:
                  final raw = event['message'] as Map<String, dynamic>;
                  controller.add(MarketMessageEvent(
                    message: MarketMessage.fromJson(raw),
                    storyAdded: event['story_added'] as bool? ?? false,
                  ));
              }
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

/// A single Họp Chợ SSE event.
sealed class MarketStreamEvent {
  const MarketStreamEvent();
}

/// A new chat message (realtime `chat` event, or a history catch-up replay
/// after a (re)connect — deduped by id on the UI side).
class MarketMessageEvent extends MarketStreamEvent {
  const MarketMessageEvent({required this.message, required this.storyAdded});
  final MarketMessage message;
  final bool storyAdded;
}

/// The weekly session was reset: chat wiped and/or Chủ Chợ changed.
/// Clients must clear the old chat and refresh the section. `masterId`
/// is null when the chợ closed (no new master).
class MarketResetEvent extends MarketStreamEvent {
  const MarketResetEvent({
    this.masterId,
    this.masterUsername,
    this.masterDisplayName,
  });
  final String? masterId;
  final String? masterUsername;
  final String? masterDisplayName;
}

/// A message was edited (own edit response or another device) — replace
/// the row in place.
class MarketEditEvent extends MarketStreamEvent {
  const MarketEditEvent({required this.message});
  final MarketMessage message;
}

/// A message was soft-deleted — remove the row.
class MarketDeleteEvent extends MarketStreamEvent {
  const MarketDeleteEvent({required this.id});
  final String id;
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
