import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vianden_client/core/server_info.dart';

final server = Uri.parse('http://127.0.0.1:8080');

/// A fake HTTP client that answers every request with [status] and [body].
MockClient answering(int status, Object body) => MockClient((request) async {
  expect(request.url.toString(), 'http://127.0.0.1:8080/api/v1/info');
  return http.Response(body is String ? body : jsonEncode(body), status);
});

Matcher throwsConnectError(String messagePart) => throwsA(
  isA<ConnectException>().having(
    (e) => e.message,
    'message',
    contains(messagePart),
  ),
);

void main() {
  test('returns server info on a valid response', () async {
    final client = answering(200, {
      'name': 'Friends',
      'version': '0.1.0',
      'protocol_version': supportedProtocolVersion,
    });
    final info = await fetchServerInfo(server, client: client);
    expect(info.name, 'Friends');
    expect(info.version, '0.1.0');
  });

  test('rejects a newer protocol version', () {
    final client = answering(200, {
      'name': 'X',
      'version': '9',
      'protocol_version': supportedProtocolVersion + 1,
    });
    expect(
      fetchServerInfo(server, client: client),
      throwsConnectError('newer version of the app'),
    );
  });

  test('rejects an older protocol version', () {
    final client = answering(200, {
      'name': 'X',
      'version': '0',
      'protocol_version': supportedProtocolVersion - 1,
    });
    expect(
      fetchServerInfo(server, client: client),
      throwsConnectError('older version'),
    );
  });

  test('rejects a non-200 status', () {
    expect(
      fetchServerInfo(server, client: answering(404, 'nope')),
      throwsConnectError('HTTP 404'),
    );
  });

  test('rejects JSON with missing or wrong fields', () {
    final client = answering(200, {'name': 'X', 'protocol_version': '1'});
    expect(
      fetchServerInfo(server, client: client),
      throwsConnectError('unexpected response'),
    );
  });

  test('rejects a body that is not JSON', () {
    expect(
      fetchServerInfo(server, client: answering(200, '<html>hi</html>')),
      throwsConnectError('unexpected response'),
    );
  });

  test('reports an unreachable server', () {
    final client = MockClient(
      (_) async => throw const SocketException('refused'),
    );
    expect(
      fetchServerInfo(server, client: client),
      throwsConnectError('Could not reach the server'),
    );
  });
}
