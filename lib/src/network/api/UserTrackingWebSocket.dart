import 'dart:convert';
import 'package:localization_engine/src/config/config.dart';
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

  TrackingPayload(
      {required this.id,
      required this.t,
      required this.pts,
      required this.venueName});

  Map<String, dynamic> toJson() {
    return {'id': id, 't': t, 'pts': pts, 'buildingId': venueName};
  }
}

class SurroundingDevicesPayload {
  final String scannerId;
  final int timestamp;
  final Map<String, int> devices;
  final String venueName;

  const SurroundingDevicesPayload({
    required this.scannerId,
    required this.timestamp,
    required this.devices,
    required this.venueName,
  });

  Map<String, dynamic> toJson() => <String, dynamic>{
        'scannerId': scannerId,
        'timestamp': timestamp,
        'devices': devices,
        'buildingId': venueName,
      };
}

// ─────────────────────────────────────────────
// WebSocket Service
// ─────────────────────────────────────────────

class WebSocketService {
  static const String _eventName = 'send-tracking';
  static const String _surroundingDevicesEventName = 'send-nearby-devices';

  IO.Socket? _socket;
  bool _isConnected = false;

  /// Connect to the WebSocket server
  void connect() {
    _socket = IO.io(
      AppConfig.baseUrl,
      IO.OptionBuilder()
          .setTransports(['websocket'])
          .setExtraHeaders({'apikey': AppConfig.apiKey})
          .setQuery({'apikey': AppConfig.apiKey})
          .enableAutoConnect()
          .enableReconnection()
          .setReconnectionAttempts(5)
          .setReconnectionDelay(2000)
          .build(),
    );

    _registerEventListeners();
    _socket!.connect();
  }

  /// Register all socket event listeners
  void _registerEventListeners() {
    _socket!.onConnect((_) async {
      _isConnected = true;
      await flushTrackingQueue();
      print('[WebSocket] ✅ Connected to ${AppConfig.baseUrl}');
    });

    _socket!.onDisconnect((_) {
      _isConnected = false;
      print('[WebSocket] ❌ Disconnected from server');
    });

    _socket!.onConnectError((error) {
      print('[WebSocket] 🔴 Connection error: $error');
    });

    _socket!.onError((error) {
      print('[WebSocket] ⚠️ Error: $error');
    });

    _socket!.onReconnect((_) {
      print('[WebSocket] 🔄 Reconnected to server');
    });

    _socket!.onReconnectAttempt((attempt) {
      print('[WebSocket] 🔁 Reconnection attempt #$attempt');
    });

    // Listen for any incoming response on the same event (optional)
    _socket!.on(_eventName, (data) {
      print('[WebSocket] 📩 Received on "$_eventName": $data');
    });
  }

  Future<void> flushTrackingQueue() async {
    final events = await TrackingQueue.getAll();

    for (final event in events) {
      _socket?.emit(_eventName, event);
    }

    if (events.isNotEmpty) {
      print('[WebSocket] 🚀 Flushed ${events.length} queued events');
      await TrackingQueue.clear();
    }
  }

  /// Manually emit the tracking event with a [TrackingPayload]
  void sendTracking(TrackingPayload payload) async {
    final json = payload.toJson();

    if (_socket == null || !_isConnected) {
      try {
        connect();
      } catch (e) {
        print("error reconnecting to socket $e");
      }
      print('[WebSocket] ⚠️ Not connected. Storing event.');
      await TrackingQueue.add(json);
      return;
    }

    _socket!.emit(_eventName, json);
    print('[WebSocket] 📤 Emitted "$_eventName": ${jsonEncode(json)}');
  }

  void sendSurroundingDevices(SurroundingDevicesPayload payload) {
    final json = payload.toJson();
    if (_socket == null || !_isConnected) {
      print('[WebSocket] Not connected. Skipping nearby-device snapshot.');
      return;
    }

    _socket!.emit(_surroundingDevicesEventName, json);
    print(
      '[WebSocket] Emitted "$_surroundingDevicesEventName": ${jsonEncode(json)}',
    );
  }

  /// Check if currently connected
  bool get isConnected => _isConnected;

  /// Disconnect and clean up
  void disconnect() {
    _socket?.disconnect();
    _socket?.dispose();
    _socket = null;
    _isConnected = false;
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
