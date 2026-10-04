import 'package:web_socket_channel/io.dart';

/// One live connection to the server's WebSocket (`/api/v1/ws`).
///
/// An interface, so tests can use a fake connection instead of a real socket.
abstract interface class RealtimeConnection {
  /// Completes when the connection is open; throws if it could not be opened.
  Future<void> get ready;

  /// Text messages from the server. Ends when the connection closes.
  Stream<String> get messages;

  /// The close code after [messages] ended (e.g. 4001 = session ended), or null.
  int? get closeCode;

  void send(String text);

  Future<void> close();
}

/// Opens a connection to [url], logged in with [token].
typedef RealtimeConnector = RealtimeConnection Function(Uri url, String token);

/// The real connection, using a WebSocket.
class WebSocketConnection implements RealtimeConnection {
  WebSocketConnection(Uri url, String token)
    : _channel = IOWebSocketChannel.connect(
        url,
        // Same header as REST requests. Never put the token in the URL: URLs end up in logs.
        headers: {'Authorization': 'Bearer $token'},
        connectTimeout: const Duration(seconds: 10),
      );

  final IOWebSocketChannel _channel;

  @override
  Future<void> get ready => _channel.ready;

  @override
  Stream<String> get messages =>
      _channel.stream.where((m) => m is String).cast<String>();

  @override
  int? get closeCode => _channel.closeCode;

  @override
  void send(String text) => _channel.sink.add(text);

  @override
  Future<void> close() => _channel.sink.close();
}

/// The WebSocket address of a server: http -> ws, https -> wss (encrypted).
Uri realtimeUrl(Uri server) => server.replace(
  scheme: server.scheme == 'https' ? 'wss' : 'ws',
  path: '/api/v1/ws',
);
