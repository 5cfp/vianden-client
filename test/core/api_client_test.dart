import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vianden_client/core/api_client.dart';

final server = Uri.parse('http://127.0.0.1:8080');

ApiClient clientAnswering(
  int status,
  String body, {
  String? token,
  Map<String, String> headers = const {},
}) => ApiClient(
  server: server,
  token: token,
  httpClient: MockClient(
    (_) async => http.Response(body, status, headers: headers),
  ),
);

Matcher apiError(int status, String code, [String? message]) => throwsA(
  isA<ApiException>()
      .having((e) => e.statusCode, 'statusCode', status)
      .having((e) => e.code, 'code', code)
      .having((e) => e.message, 'message', message ?? anything),
);

void main() {
  test('sends the bearer token and JSON body', () async {
    late http.Request sent;
    final api = ApiClient(
      server: server,
      token: 'vs_secret',
      httpClient: MockClient((r) async {
        sent = r;
        return http.Response(
          jsonEncode({
            'invite': {
              'id': 1,
              'max_uses': 1,
              'uses': 0,
              'expires_at': '2026-10-11T12:00:00Z',
            },
            'code': 'vi_x',
          }),
          201,
        );
      }),
    );

    final created = await api.createInvite();

    expect(sent.method, 'POST');
    expect(sent.url.toString(), 'http://127.0.0.1:8080/api/v1/invites');
    expect(sent.headers['Authorization'], 'Bearer vs_secret');
    expect(sent.headers['Content-Type'], startsWith('application/json'));
    expect(sent.body, '{}');
    expect(created.code, 'vi_x');
  });

  test('no Authorization header without a token', () async {
    late http.Request sent;
    final api = ApiClient(
      server: server,
      httpClient: MockClient((r) async {
        sent = r;
        return http.Response(
          '{"user":{"id":1,"username":"a","display_name":"A","is_owner":false},"token":"vs_t"}',
          200,
        );
      }),
    );
    await api.login('a', 'b');
    expect(sent.headers.containsKey('Authorization'), isFalse);
  });

  test('reads the standard error format', () {
    final api = clientAnswering(
      403,
      '{"error":{"code":"invalid_invite","message":"invite code is invalid"}}',
    );
    expect(
      api.login('a', 'b'),
      apiError(403, 'invalid_invite', 'Invite code is invalid'),
    );
  });

  test('recognizes an expired session', () async {
    final api = clientAnswering(
      401,
      '{"error":{"code":"unauthorized","message":"x"}}',
      token: 'vs_old',
    );
    try {
      await api.me();
      fail('should throw');
    } on ApiException catch (e) {
      expect(e.isUnauthorized, isTrue);
    }
  });

  test('wrong credentials are NOT treated as an expired session', () async {
    final api = clientAnswering(
      401,
      '{"error":{"code":"invalid_credentials","message":"x"}}',
    );
    try {
      await api.login('a', 'b');
      fail('should throw');
    } on ApiException catch (e) {
      expect(e.isUnauthorized, isFalse);
      expect(e.message, 'Wrong username or password.');
    }
  });

  test('internal errors get a generic message', () {
    final api = clientAnswering(
      500,
      '{"error":{"code":"internal_error","message":"internal server error"}}',
    );
    expect(
      api.login('a', 'b'),
      apiError(
        500,
        'internal_error',
        'Something went wrong on the server. Try again later.',
      ),
    );
  });

  test('an error page that is not JSON still gives a clean error', () {
    final api = clientAnswering(502, '<html>Bad Gateway</html>');
    expect(api.login('a', 'b'), apiError(502, 'unknown_error'));
  });

  test('a success response with the wrong shape is rejected', () {
    final api = clientAnswering(
      200,
      '{"user":{"id":"not a number"},"token":"vs_x"}',
    );
    expect(api.login('a', 'b'), apiError(200, 'bad_response'));
  });

  test('network failures become NetworkException', () {
    final api = ApiClient(
      server: server,
      httpClient: MockClient(
        (_) async => throw http.ClientException('refused'),
      ),
    );
    expect(api.login('a', 'b'), throwsA(isA<NetworkException>()));
  });

  test('logout accepts 204 No Content', () async {
    final api = clientAnswering(204, '', token: 'vs_t');
    await api.logout(); // must not throw
  });

  test('UTF-8 names are decoded correctly', () async {
    final body = utf8.encode(
      '{"user":{"id":1,"username":"a","display_name":"أسامة 🎮","is_owner":false}}',
    );
    final api = ApiClient(
      server: server,
      token: 'vs_t',
      httpClient: MockClient(
        (_) async => http.Response.bytes(body, 200),
      ), // no charset header
    );
    expect((await api.me()).displayName, 'أسامة 🎮');
  });
}
