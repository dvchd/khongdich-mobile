import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/network/api_client.dart';
import '../core/observability/app_logger.dart';
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

  /// Post a chat message. [parentId] turns the message into a reply
  /// ("Phản hồi" — flat chronological flow with a reply chip, like the
  /// web). The backend rejects when the chợ is closed, runs the content
  /// filter, and attaches a random public story when the caller is an
  /// author. Hits `POST /api/v1/mobile/market/chat`.
  Future<MarketPostResult> postMessage(
    String content, {
    String? parentId,
  }) async {
    final r = await _dio.post('/api/v1/mobile/market/chat', data: {
      'content': content,
      if (parentId != null) 'parent_id': parentId,
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
    // Abort the in-flight SSE request when the caller cancels the
    // subscription. Without this the reconnect loop keeps running
    // forever after the screen is disposed (the controller was never
    // closed), draining battery/data and buffering events into a
    // listener-less single-subscription controller.
    final cancelToken = CancelToken();
    controller.onCancel = () {
      cancelToken.cancel('subscription cancelled');
      return controller.close();
    };

    // Reconnect với exponential backoff (1s → 30s tối đa) thay vì cố định
    // 3s mãi mãi — server down lâu thì không spam request + drain pin.
    var retryDelay = _initialRetryDelay;

    Future<void> connect() async {
      // Thời điểm kết nối được thiết lập (response nhận được) — dùng để
      // đo uptime khi stream kết thúc, xem [nextReconnectDelay].
      DateTime connectedAt = DateTime.now();
      try {
        final response = await _dio.get<ResponseBody>(
          '/api/v1/mobile/market/stream',
          options: Options(
            responseType: ResponseType.stream,
            headers: {'Accept': 'text/event-stream'},
            receiveTimeout: const Duration(hours: 1),
          ),
          cancelToken: cancelToken,
        );
        if (controller.isClosed) return;
        connectedAt = DateTime.now();
        // Catch-up: EventSource does not replay messages sent while the
        // connection was down — pull the latest history on every connect.
        try {
          final history = await fetchHistory();
          for (final m in history) {
            if (controller.isClosed) return;
            controller.add(MarketMessageEvent(message: m, storyAdded: false));
          }
        } catch (_) {
          // Best-effort: live events still flow if history fails.
        }
        if (controller.isClosed) return;
        final stream = response.data!.stream
            .cast<List<int>>()
            .transform(utf8.decoder)
            .transform(const LineSplitter());
        var eventName = 'chat';
        await for (final line in stream) {
          if (controller.isClosed) return;
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
        // Delay kế tiếp phụ thuộc uptime: kết nối sống lâu (thực sự
        // healthy) mới được reset về 1s; kết nối chết nhanh liên tục
        // (server/proxy flap) phải nhân đôi như failure — nếu không sẽ
        // reconnect mỗi ~1s vô hạn (bug reconnect-storm).
        if (!controller.isClosed) {
          retryDelay = nextReconnectDelay(
            healthyFor: DateTime.now().difference(connectedAt),
            currentDelay: retryDelay,
          );
          await Future.delayed(retryDelay);
          if (!controller.isClosed) unawaited(connect());
        }
      } catch (e, s) {
        AppLogger.warning(
            'Market: SSE mất kết nối — reconnect sau ${retryDelay.inSeconds}s',
            e,
            s);
        if (!controller.isClosed) {
          await Future.delayed(retryDelay);
          retryDelay = _nextDelay(retryDelay, _maxRetryDelay);
          if (!controller.isClosed) unawaited(connect());
        }
      }
    }

    unawaited(connect());
    return controller.stream.listen(onEvent);
  }
}

/// Exponential backoff cho SSE reconnect — nhân đôi mỗi lần, chặn ở
/// [_maxRetryDelay] (1s → 2s → 4s → … → 30s).
const _initialRetryDelay = Duration(seconds: 1);
const _maxRetryDelay = Duration(seconds: 30);

Duration _nextDelay(Duration current, Duration maxDelay) {
  final next = current * 2;
  return next > maxDelay ? maxDelay : next;
}

/// Kết nối phải sống tối thiểu [_healthyResetThreshold] mới được coi là
/// "ổn định" và reset backoff về ban đầu. Dưới ngưỡng này coi là flap.
const _healthyResetThreshold = Duration(seconds: 60);

/// Delay chờ trước lần reconnect kế tiếp sau khi stream SSE kết thúc.
///
/// Kết nối vừa rồi sống ≥ [_healthyResetThreshold] (mất mạng thật, server
/// restart...) → reset về [_initialRetryDelay]. Ngược lại (flap: server
/// chấp nhận kết nối rồi đóng gần như ngay lập tức) → nhân đôi tiếp như
/// một lần failure. Trước đây clean-close LUÔN reset về 1s → server flap
/// gây reconnect-storm ~1s/lần vô hạn, đánh bại toàn bộ backoff.
///
/// Public + thuần để unit test (test/market_reconnect_test.dart).
Duration nextReconnectDelay({
  required Duration healthyFor,
  required Duration currentDelay,
}) {
  if (healthyFor >= _healthyResetThreshold) return _initialRetryDelay;
  return _nextDelay(currentDelay, _maxRetryDelay);
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
