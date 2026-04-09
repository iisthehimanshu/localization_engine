import 'dart:convert';
import 'package:localization_engine/src/config/config.dart';
import 'package:socket_io_client/socket_io_client.dart' as IO;

// ─────────────────────────────────────────────
// Data model for the tracking payload
// ─────────────────────────────────────────────

class TrackingPayload {
  final String id;
  final int t;
  final Map<String, List<int?>> pts;
  final String venueName;

  TrackingPayload({
    required this.id,
    required this.t,
    required this.pts,
    required this.venueName
  });

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      't': t,
      'pts': pts,
      'buildingId': venueName
    };
  }
}

// ─────────────────────────────────────────────
// WebSocket Service
// ─────────────────────────────────────────────

class WebSocketService {
  static const String _eventName = 'send-tracking';


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
    _socket!.onConnect((_) {
      _isConnected = true;
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

  /// Manually emit the tracking event with a [TrackingPayload]
  void sendTracking(TrackingPayload payload) {
    if (_socket == null || !_isConnected) {
      print('[WebSocket] ⚠️ Cannot send — not connected.');
      return;
    }

    final json = payload.toJson();
    _socket!.emit(_eventName, json);
    print('[WebSocket] 📤 Emitted "$_eventName": ${jsonEncode(json)}');
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