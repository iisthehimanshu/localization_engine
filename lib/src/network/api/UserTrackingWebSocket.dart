import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:localization_engine/src/config/config.dart';
import 'package:localization_engine/src/network/api/tracking_bulk_api.dart';
import 'package:localization_engine/src/network/api/tracking_queue.dart';
import 'package:socket_io_client/socket_io_client.dart' as IO;

// ─────────────────────────────────────────────
// Data model for the tracking payload
// ─────────────────────────────────────────────

class TrackingPayload {
  final String id;
  final int t;
  final Map<String, List<int?>> pts;
  final String venueName;
  final Map<String, int>? surroundingDevices;

  TrackingPayload({
    required this.id,
    required this.t,
    required this.pts,
    required this.venueName,
    this.surroundingDevices,
  });

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      't': t,
      'pts': pts,
      if (surroundingDevices != null) 'devices': surroundingDevices,
      'buildingId': venueName,
    };
  }
}

// ─────────────────────────────────────────────
// WebSocket Service
// ─────────────────────────────────────────────

/// Streams tracking points to the backend without losing them while offline.
///
/// Every point is first written to the on-device [TrackingQueue]. When a
/// connection opens, whatever was queued before it (the offline backlog) is
/// posted through [TrackingBulkApi]; points after that stream over the socket.
/// A point leaves the queue only once delivery is proven: a 2xx bulk response,
/// a server ack, or, for servers that don't ack, the Engine.IO heartbeat (see
/// [_onServerPing]). Whatever is unproven when the connection drops is re-sent
/// in order after reconnecting, so delivery is at-least-once: the server can
/// occasionally see the same point twice (same `id` and `t`).
class WebSocketService {
  static const String _eventName = 'send-tracking';

  IO.Socket? _socket;

  /// Encoded payloads awaiting proof of delivery, oldest first. Mirrors
  /// [TrackingQueue] and is loaded from it on first use.
  List<String>? _outbox;
  Future<List<String>>? _outboxLoad;

  /// Sequence number of `_outbox[0]`; entry `i` has `_headSeq + i`.
  int _headSeq = 0;

  /// Leading outbox entries already emitted on the current connection.
  int _inFlight = 0;

  /// End (exclusive) of the entries written before our pong to the latest
  /// server ping; null until the first ping on this connection.
  int? _pongedSeq;

  /// Set when a connection opens; the next pump marks everything queued so far
  /// as backlog for the bulk API.
  bool _backlogPending = false;

  /// End (exclusive) of the backlog to post via [TrackingBulkApi]. The socket
  /// only emits once the head of the outbox has passed it.
  int _backlogEnd = 0;

  bool _uploading = false;

  /// Connect to the WebSocket server. Calling it again while a socket exists
  /// is a no-op; the socket reconnects on its own for as long as it takes.
  void connect() {
    if (_socket != null) return;

    final socket = IO.io(
      AppConfig.baseUrl,
      IO.OptionBuilder()
          .setTransports(['websocket'])
          .setExtraHeaders({'apikey': AppConfig.apiKey})
          .setQuery({'apikey': AppConfig.apiKey})
          // Use a private Manager: the shared cache would hand back the previous
          // socket, still carrying listeners from an earlier connect().
          .enableForceNew()
          .enableAutoConnect()
          .enableReconnection()
          .setReconnectionDelay(2000)
          .setReconnectionDelayMax(10000)
          .build(),
    );
    _socket = socket;

    _registerEventListeners(socket);
    socket.connect();
  }

  /// Register all socket event listeners
  void _registerEventListeners(IO.Socket socket) {
    socket.onConnect((_) {
      print('[WebSocket] ✅ Connected to ${AppConfig.baseUrl}');
      _backlogPending = true;
      _pump();
    });

    socket.onDisconnect((_) {
      _resetConnectionState();
      print('[WebSocket] ❌ Disconnected from server');
    });

    socket.onConnectError((error) {
      print('[WebSocket] 🔴 Connection error: $error');
    });

    socket.onError((error) {
      print('[WebSocket] ⚠️ Error: $error');
    });

    socket.onReconnect((_) {
      print('[WebSocket] 🔄 Reconnected to server');
    });

    socket.onReconnectAttempt((attempt) {
      print('[WebSocket] 🔁 Reconnection attempt #$attempt');
    });

    socket.io.on('ping', (_) => _onServerPing());

    // Listen for any incoming response on the same event (optional)
    socket.on(_eventName, (data) {
      print('[WebSocket] 📩 Received on "$_eventName": $data');
    });
  }

  /// Queues [payload] on the device and sends it once the server is reachable.
  Future<void> sendTracking(TrackingPayload payload) async {
    final outbox = await _loadOutbox();
    outbox.add(jsonEncode(payload.toJson()));

    final overflow = outbox.length - TrackingQueue.maxLength;
    if (overflow > 0) {
      _dropHead(overflow);
      print('[WebSocket] ⚠️ Queue full. Dropped $overflow oldest events.');
    }

    _persist();
    await _pump();
  }

  Future<List<String>> _loadOutbox() {
    final outbox = _outbox;
    if (outbox != null) return Future.value(outbox);
    return _outboxLoad ??=
        TrackingQueue.load().then((entries) => _outbox = entries);
  }

  /// Delivers the outbox in order: the backlog through the bulk API, then
  /// every entry not yet written on the current connection over the socket.
  Future<void> _pump() async {
    final outbox = await _loadOutbox();
    final socket = _socket;
    // A disconnected socket buffers emits in memory and replays them on
    // reconnect, which would duplicate the outbox resend.
    if (socket == null || !socket.connected || _uploading) return;

    if (_backlogPending) {
      _backlogPending = false;
      _backlogEnd = _headSeq + outbox.length;
    }
    if (_headSeq < _backlogEnd) {
      await _uploadBacklog(outbox);
      return _pump();
    }

    while (_inFlight < outbox.length) {
      final encoded = outbox[_inFlight];
      final seqEnd = _headSeq + _inFlight + 1;
      socket.emitWithAck(_eventName, jsonDecode(encoded),
          ack: ([_]) => _confirm(seqEnd));
      _inFlight++;
      print('[WebSocket] 📤 Emitted "$_eventName": $encoded');
    }
  }

  /// Posts the backlog in batches, dropping each batch once the server accepts
  /// it. If a request fails, the rest of the backlog goes over the socket
  /// instead, which proves delivery its own way.
  Future<void> _uploadBacklog(List<String> outbox) async {
    _uploading = true;
    try {
      while (_headSeq < _backlogEnd && outbox.isNotEmpty) {
        final count = min(min(_backlogEnd - _headSeq, outbox.length),
            TrackingBulkApi.maxBatch);
        final seqEnd = _headSeq + count;
        final batch = [
          for (final encoded in outbox.take(count))
            jsonDecode(encoded) as Map<String, dynamic>,
        ];
        if (!await TrackingBulkApi.upload(batch)) {
          print('[WebSocket] ⚠️ Bulk upload failed. Sending backlog over the socket.');
          _backlogEnd = _headSeq;
          return;
        }
        print('[WebSocket] 🚀 Uploaded ${batch.length} queued events');
        _confirm(seqEnd);
      }
    } finally {
      _uploading = false;
    }
  }

  /// Heartbeat-based delivery proof for servers that don't ack.
  ///
  /// The client answers each server ping with a pong written after everything
  /// emitted so far, and an Engine.IO server schedules its next ping only once
  /// that pong has arrived. The connection delivers in order, so the next ping
  /// proves the server received everything written before the previous pong.
  void _onServerPing() {
    final ponged = _pongedSeq;
    if (ponged != null) _confirm(ponged);
    _pongedSeq = _headSeq + _inFlight;
  }

  /// Removes every outbox entry with a sequence number below [seqEnd].
  void _confirm(int seqEnd) {
    final outbox = _outbox;
    if (outbox == null) return;
    final count = min(seqEnd - _headSeq, outbox.length);
    if (count <= 0) return;
    _dropHead(count);
    _persist();
  }

  void _dropHead(int count) {
    _outbox!.removeRange(0, count);
    _headSeq += count;
    _inFlight = max(0, _inFlight - count);
  }

  void _persist() {
    unawaited(TrackingQueue.save(_outbox!));
  }

  /// Nothing written on a dead connection is proven delivered; resend it all.
  void _resetConnectionState() {
    _inFlight = 0;
    _pongedSeq = null;
  }

  /// Check if currently connected
  bool get isConnected => _socket?.connected ?? false;

  /// Disconnect and clean up. Undelivered points stay queued on the device.
  void disconnect() {
    _socket?.dispose();
    _socket = null;
    _resetConnectionState();
    print('[WebSocket] 🔌 Disconnected and cleaned up.');
  }
}

// ─────────────────────────────────────────────
// Example usage (e.g., in main.dart or a widget)
// ─────────────────────────────────────────────
//
// void main() {
//   final wsService = WebSocketService();
//   wsService.connect();
//
//   final payload = TrackingPayload(
//     id: 'a3f9',
//     t: 1741772800,
//     pts: {
//       'nb': [423, 187, 280121, 728439, 2, 1],
//       'tr': [413, 180, 283928, 729323, 0, 2],
//       'fp': [400, 150, 289128, 729127, 3, 3],
//     },
//   );
//
//   wsService.sendTracking(payload);
//
//   // To disconnect:
//   // wsService.disconnect();
// }
