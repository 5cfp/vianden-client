import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vianden_client/core/session_controller.dart';
import 'package:vianden_client/core/session_store.dart';
import 'package:vianden_client/main.dart';

/// Keeps "saved" data in memory instead of the real OS storage.
class MemorySessionStore implements SessionStore {
  String? server;
  String? token;

  @override
  Future<String?> readServer() async => server;
  @override
  Future<void> writeServer(String s) async => server = s;
  @override
  Future<String?> readToken() async => token;
  @override
  Future<void> writeToken(String t) async => token = t;
  @override
  Future<void> deleteToken() async => token = null;
  @override
  Future<void> clear() async => server = token = null;
}

class FakeUser {
  FakeUser(
    this.id,
    this.username,
    this.displayName,
    this.password, {
    this.isOwner = false,
  });
  final int id;
  final String username;
  final String displayName;
  final String password;
  final bool isOwner;

  Map<String, Object> toJson() => {
    'id': id,
    'username': username,
    'display_name': displayName,
    'is_owner': isOwner,
  };
}

/// A pretend Vianden server that behaves like the real API (docs/API.md).
class FakeServer {
  String name = 'Friends Server';
  int protocolVersion = 1;
  bool down = false;
  String? rateLimitedFor; // if set: login answers 429 with this Retry-After

  final users = <FakeUser>[
    FakeUser(1, 'osama', 'Osama', 'owner-pass-1', isOwner: true),
    FakeUser(2, 'friend', 'Friend', 'friend-pass-1'),
  ];
  final validInvites = {'vi_good'};
  final tokens = <String, FakeUser>{}; // active sessions
  final requests = <http.Request>[];
  var _next = 0;

  late final http.Client client = MockClient(_handle);

  /// Creates an active session, as if the user logged in earlier.
  String sessionFor(String username) {
    final token = 'vs_${username}_${_next++}';
    tokens[token] = users.firstWhere((u) => u.username == username);
    return token;
  }

  Iterable<http.Request> called(String method, String path) =>
      requests.where((r) => r.method == method && r.url.path == path);

  Future<http.Response> _handle(http.Request r) async {
    requests.add(r);
    if (down) throw const SocketException('connection refused');

    final body = r.body.isEmpty
        ? <String, dynamic>{}
        : jsonDecode(r.body) as Map<String, dynamic>;
    FakeUser? authed() {
      final h = r.headers['Authorization'] ?? '';
      return h.startsWith('Bearer ') ? tokens[h.substring(7)] : null;
    }

    switch ((r.method, r.url.path)) {
      case ('GET', '/api/v1/info'):
        return _json(200, {
          'name': name,
          'version': '0.1.0',
          'protocol_version': protocolVersion,
        });

      case ('POST', '/api/v1/login'):
        if (rateLimitedFor case final s?) {
          return _error(429, 'rate_limited', 'too many attempts', {
            'retry-after': s,
          });
        }
        final u = users.where(
          (u) =>
              u.username == (body['username'] as String).toLowerCase().trim(),
        );
        if (u.isEmpty || u.first.password != body['password']) {
          return _error(
            401,
            'invalid_credentials',
            'wrong username or password',
          );
        }
        return _session(u.first);

      case ('POST', '/api/v1/register'):
        if (!validInvites.contains(body['invite_code'])) {
          return _error(
            403,
            'invalid_invite',
            'invite code is invalid, expired, or used up',
          );
        }
        final display = (body['display_name'] as String).isEmpty
            ? body['username'] as String
            : body['display_name'] as String;
        final u = FakeUser(
          users.length + 1,
          (body['username'] as String).toLowerCase(),
          display,
          body['password'] as String,
        );
        users.add(u);
        return _session(u, status: 201);

      case ('GET', '/api/v1/me'):
        final u = authed();
        if (u == null) {
          return _error(
            401,
            'unauthorized',
            'missing, invalid, or expired session token',
          );
        }
        return _json(200, {'user': u.toJson()});

      case ('POST', '/api/v1/logout'):
        final h = r.headers['Authorization'] ?? '';
        if (authed() == null) {
          return _error(
            401,
            'unauthorized',
            'missing, invalid, or expired session token',
          );
        }
        tokens.remove(h.substring(7));
        return http.Response('', 204);

      case ('POST', '/api/v1/invites'):
        final u = authed();
        if (u == null) {
          return _error(
            401,
            'unauthorized',
            'missing, invalid, or expired session token',
          );
        }
        if (!u.isOwner) {
          return _error(
            403,
            'forbidden',
            'you do not have permission to do this',
          );
        }
        return _json(201, {
          'invite': {
            'id': 1,
            'created_by': u.id,
            'max_uses': 1,
            'uses': 0,
            'expires_at': '2026-10-11T12:00:00Z',
            'created_at': '2026-10-04T12:00:00Z',
          },
          'code': 'vi_brand_new_code',
        });
    }
    return _error(404, 'not_found', 'route not found');
  }

  http.Response _session(FakeUser u, {int status = 200}) {
    final token = 'vs_${u.username}_${_next++}';
    tokens[token] = u;
    return _json(status, {'user': u.toJson(), 'token': token});
  }

  static http.Response _json(int status, Object body) => http.Response(
    jsonEncode(body),
    status,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );

  static http.Response _error(
    int status,
    String code,
    String message, [
    Map<String, String> headers = const {},
  ]) => http.Response(
    jsonEncode({
      'error': {'code': code, 'message': message},
    }),
    status,
    headers: {'content-type': 'application/json; charset=utf-8', ...headers},
  );
}

/// Starts the whole app with the fake server and fake storage, and waits until it settles.
Future<void> pumpApp(
  WidgetTester tester,
  FakeServer server,
  MemorySessionStore store,
) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        httpClientProvider.overrideWithValue(server.client),
        sessionStoreProvider.overrideWithValue(store),
      ],
      child: const ViandenApp(),
    ),
  );
  await tester.pumpAndSettle();
}

/// Types into the text field with the given key.
Future<void> type(WidgetTester tester, String key, String text) =>
    tester.enterText(find.byKey(Key(key)), text);

Future<void> tapKey(WidgetTester tester, String key) async {
  await tester.tap(find.byKey(Key(key)));
  await tester.pumpAndSettle();
}

Future<void> tapText(WidgetTester tester, String text) async {
  await tester.tap(find.text(text));
  await tester.pumpAndSettle();
}

const serverUrl = 'http://127.0.0.1:8080';
