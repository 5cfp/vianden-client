import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vianden_client/core/certificate_trust.dart';
import 'package:vianden_client/core/realtime_connection.dart';
import 'package:vianden_client/core/session_controller.dart';
import 'package:vianden_client/core/session_store.dart';
import 'package:vianden_client/features/chat/realtime_controller.dart';
import 'package:vianden_client/main.dart';

/// Keeps "saved" data in memory instead of the real OS storage.
class MemorySessionStore implements SessionStore {
  String? server;
  String? token;
  Map<String, String> pins = {};

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
  Future<Map<String, String>> readCertificatePins() async => Map.of(pins);
  @override
  Future<void> writeCertificatePins(Map<String, String> p) async =>
      pins = Map.of(p);
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

class FakeChannel {
  FakeChannel(this.id, this.name, [this.topic = '']);
  final int id;
  String name;
  String topic;
}

class FakeMessage {
  FakeMessage(
    this.id,
    this.channelId,
    this.author,
    this.content,
    this.createdAt,
  );
  final int id;
  final int channelId;
  final FakeUser? author;
  final String content;
  final DateTime createdAt;

  Map<String, Object?> toJson() => {
    'id': id,
    'channel_id': channelId,
    'author': author == null
        ? null
        : {
            'id': author!.id,
            'username': author!.username,
            'display_name': author!.displayName,
          },
    'content': content,
    'created_at': createdAt.toUtc().toIso8601String(),
  };
}

/// A pretend live connection, as the real hub would behave (docs/API.md section 5).
class FakeConnection implements RealtimeConnection {
  FakeConnection(this.server, this.token, this.user);

  final FakeServer server;
  final String token;
  final _incoming = StreamController<String>();
  final _ready = Completer<void>();
  final sent = <Map<String, dynamic>>[];
  int? _closeCode;

  /// Who connected (remembered, like the real hub, even if the token is removed later).
  final FakeUser? user;

  void push(String type, Object? data) {
    if (!_incoming.isClosed) {
      _incoming.add(jsonEncode({'type': type, 'data': data}));
    }
  }

  /// The server closes the connection (code null = network drop).
  void serverClose([int? code]) {
    _closeCode = code;
    server.connections.remove(this);
    if (!_incoming.isClosed) _incoming.close();
  }

  @override
  Future<void> get ready => _ready.future;
  @override
  Stream<String> get messages => _incoming.stream;
  @override
  int? get closeCode => _closeCode;

  @override
  void send(String text) {
    final msg = jsonDecode(text) as Map<String, dynamic>;
    sent.add(msg);
    if (msg case {'type': 'typing', 'data': {'channel_id': final int ch}}) {
      for (final c in server.connections) {
        if (c.user!.id != user!.id) {
          c.push('typing.started', {'channel_id': ch, 'user': _info(user!)});
        }
      }
    }
  }

  @override
  Future<void> close() async {
    server.connections.remove(this);
    if (!_incoming.isClosed) await _incoming.close();
  }
}

Map<String, Object> _info(FakeUser u) => {
  'id': u.id,
  'username': u.username,
  'display_name': u.displayName,
};

/// A pretend Vianden server that behaves like the real API (docs/API.md).
class FakeServer {
  String name = 'Friends Server';
  int protocolVersion = 1;
  bool down = false;
  String? rateLimitedFor; // if set: login answers 429 with this Retry-After
  String? sendRateLimitedFor; // if set: sending messages answers 429

  final users = <FakeUser>[
    FakeUser(1, 'osama', 'Osama', 'owner-pass-1', isOwner: true),
    FakeUser(2, 'friend', 'Friend', 'friend-pass-1'),
  ];
  final validInvites = {'vi_good'};
  final tokens = <String, FakeUser>{}; // active sessions
  final requests = <http.Request>[];
  final channels = <FakeChannel>[
    FakeChannel(1, 'General', 'Everything and nothing'),
  ];
  final messages = <FakeMessage>[];
  final connections = <FakeConnection>[];
  var connectAttempts = 0;
  var _next = 0;
  var _nextMessageId = 1;
  var _nextChannelId = 2;

  /// If set, the server presents this self-signed certificate on https:// addresses, and
  /// the app's [trust] decides (like dart:io's badCertificateCallback) whether to accept it.
  List<int>? selfSignedCert;
  CertificateTrust? trust;

  late final http.Client client = MockClient((r) async {
    if (r.url.scheme == 'https' && selfSignedCert != null) {
      if (!trust!.check(selfSignedCert!, r.url.host, r.url.port)) {
        throw const HandshakeException('CERTIFICATE_VERIFY_FAILED');
      }
    }
    return _handle(r);
  });

  FakeUser user(String username) =>
      users.firstWhere((u) => u.username == username);

  /// Creates an active session, as if the user logged in earlier.
  String sessionFor(String username) {
    final token = 'vs_${username}_${_next++}';
    tokens[token] = user(username);
    return token;
  }

  /// Adds a message directly on the "server" (e.g. sent by someone else).
  FakeMessage post(
    int channelId,
    String username,
    String content, {
    DateTime? at,
  }) {
    final m = FakeMessage(
      _nextMessageId++,
      channelId,
      user(username),
      content,
      at ?? DateTime.now(),
    );
    messages.add(m);
    return m;
  }

  /// What the app's RealtimeConnector calls: opens a fake live connection.
  RealtimeConnection connect(Uri url, String token) {
    connectAttempts++;
    final c = FakeConnection(this, token, tokens[token]);
    if (down || !tokens.containsKey(token)) {
      c._ready.completeError(const SocketException('refused'));
      return c;
    }
    connections.add(c);
    c._ready.complete();
    final online = {for (final x in connections) x.user!.id: x.user!}.values;
    c.push('ready', {
      'user': _info(c.user!),
      'online': [for (final u in online) _info(u)],
    });
    return c;
  }

  /// Sends an event to every connected client.
  void pushAll(String type, Object? data) {
    for (final c in List.of(connections)) {
      c.push(type, data);
    }
  }

  /// Someone else sends a message: stored AND pushed live, like the real server.
  FakeMessage postLive(int channelId, String username, String content) {
    final m = post(channelId, username, content);
    pushAll('message.created', m.toJson());
    return m;
  }

  /// Logs a session out on the server: its live connections close with code 4001.
  void endSession(String token) {
    tokens.remove(token);
    for (final c in List.of(connections)) {
      if (c.token == token) c.serverClose(4001);
    }
  }

  /// Simulates a network drop for every connection.
  void dropAll() {
    for (final c in List.of(connections)) {
      c.serverClose();
    }
  }

  Iterable<http.Request> called(String method, String path) =>
      requests.where((r) => r.method == method && r.url.path == path);

  Future<http.Response> _handle(http.Request r) async {
    requests.add(r);
    if (down) throw const SocketException('connection refused');

    final body = r.body.isEmpty
        ? <String, dynamic>{}
        : jsonDecode(r.body) as Map<String, dynamic>;
    final bearer = r.headers['Authorization'] ?? '';
    final me = bearer.startsWith('Bearer ')
        ? tokens[bearer.substring(7)]
        : null;
    final path = r.url.path;

    // ---- no login needed ----
    switch ((r.method, path)) {
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
    }

    // ---- everything else needs a valid session ----
    if (me == null) {
      return _error(
        401,
        'unauthorized',
        'missing, invalid, or expired session token',
      );
    }

    final channelPath = RegExp(r'^/api/v1/channels/(\d+)(/messages)?$')
        .firstMatch(path);
    final channelId = channelPath == null
        ? null
        : int.parse(channelPath.group(1)!);
    final channel = channels.where((c) => c.id == channelId).firstOrNull;
    final isMessages = channelPath?.group(2) != null;

    switch ((r.method, path)) {
      case ('GET', '/api/v1/me'):
        return _json(200, {'user': me.toJson()});

      case ('POST', '/api/v1/logout'):
        endSession(bearer.substring(7));
        return http.Response('', 204);

      case ('POST', '/api/v1/invites'):
        if (!me.isOwner) {
          return _error(
            403,
            'forbidden',
            'you do not have permission to do this',
          );
        }
        return _json(201, {
          'invite': {
            'id': 1,
            'created_by': me.id,
            'max_uses': 1,
            'uses': 0,
            'expires_at': '2026-10-11T12:00:00Z',
            'created_at': '2026-10-04T12:00:00Z',
          },
          'code': 'vi_brand_new_code',
        });

      case ('GET', '/api/v1/channels'):
        return _json(200, {
          'channels': [
            for (final c in channels) _channelJson(c, withPreview: true),
          ],
        });

      case ('POST', '/api/v1/channels'):
        if (!me.isOwner) {
          return _error(
            403,
            'forbidden',
            'you do not have permission to do this',
          );
        }
        final name = (body['name'] as String).trim();
        if (name.isEmpty) {
          return _error(400, 'invalid_name', 'name: must be 1-32 characters');
        }
        if (channels.any((c) => c.name.toLowerCase() == name.toLowerCase())) {
          return _error(
            409,
            'channel_name_taken',
            'a channel with this name already exists',
          );
        }
        final c = FakeChannel(
          _nextChannelId++,
          name,
          (body['topic'] as String?) ?? '',
        );
        channels.add(c);
        pushAll('channel.created', _channelJson(c));
        return _json(201, {'channel': _channelJson(c)});
    }

    if (channelPath != null && channel == null) {
      return _error(404, 'not_found', 'channel not found');
    }

    if (channel != null && !isMessages) {
      if (!me.isOwner) {
        return _error(
          403,
          'forbidden',
          'you do not have permission to do this',
        );
      }
      switch (r.method) {
        case 'PATCH':
          if (body['name'] case final String n) channel.name = n.trim();
          if (body['topic'] case final String t) channel.topic = t.trim();
          pushAll('channel.updated', _channelJson(channel));
          return _json(200, {'channel': _channelJson(channel)});
        case 'DELETE':
          channels.remove(channel);
          messages.removeWhere((m) => m.channelId == channel.id);
          pushAll('channel.deleted', {'id': channel.id});
          return http.Response('', 204);
      }
    }

    if (channel != null && isMessages) {
      switch (r.method) {
        case 'GET':
          final before = int.tryParse(r.url.queryParameters['before'] ?? '');
          final limit = int.parse(r.url.queryParameters['limit'] ?? '50');
          final older =
              messages
                  .where(
                    (m) =>
                        m.channelId == channel.id &&
                        (before == null || m.id < before),
                  )
                  .toList()
                ..sort((a, b) => b.id.compareTo(a.id)); // newest first
          final page = older.take(limit).toList().reversed; // oldest first
          return _json(200, {
            'messages': [for (final m in page) m.toJson()],
            'has_more': older.length > limit,
          });
        case 'POST':
          if (sendRateLimitedFor case final s?) {
            return _error(429, 'rate_limited', 'too many messages, slow down', {
              'retry-after': s,
            });
          }
          final m = post(channel.id, me.username, body['content'] as String);
          pushAll('message.created', m.toJson());
          return _json(201, {'message': m.toJson()});
      }
    }
    return _error(404, 'not_found', 'route not found');
  }

  Map<String, Object?> _channelJson(FakeChannel c, {bool withPreview = false}) {
    final last = messages.where((m) => m.channelId == c.id).lastOrNull;
    return {
      'id': c.id,
      'name': c.name,
      'topic': c.topic,
      'type': 'text',
      'position': channels.indexOf(c),
      'last_message': withPreview && last != null
          ? {
              'author_name': last.author?.displayName ?? '',
              'content': last.content,
              'created_at': last.createdAt.toUtc().toIso8601String(),
            }
          : null,
    };
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
/// The test window is desktop-sized, so the two-column chat layout is used.
Future<void> pumpApp(
  WidgetTester tester,
  FakeServer server,
  MemorySessionStore store,
) async {
  tester.view.physicalSize = const Size(1280, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        httpClientProvider.overrideWithValue(server.client),
        sessionStoreProvider.overrideWithValue(store),
        realtimeConnectorProvider.overrideWithValue(server.connect),
        certificateTrustProvider.overrideWithValue(
          server.trust ??= CertificateTrust(),
        ),
      ],
      child: const ViandenApp(),
    ),
  );
  await tester.pumpAndSettle();
}

/// Starts the app already logged in as [username].
Future<void> pumpLoggedIn(
  WidgetTester tester,
  FakeServer server,
  MemorySessionStore store,
  String username,
) {
  store
    ..server = serverUrl
    ..token = server.sessionFor(username);
  return pumpApp(tester, server, store);
}

/// Types into the text field with the given key.
Future<void> type(WidgetTester tester, String key, String text) =>
    tester.enterText(find.byKey(Key(key)), text);

Future<void> tapKey(WidgetTester tester, String key) async {
  await tester.tap(find.byKey(Key(key)));
  await tester.pumpAndSettle();
}

Future<void> tapText(WidgetTester tester, String text) async {
  await tester.tap(find.text(text).last);
  await tester.pumpAndSettle();
}

/// Opens the account menu (bottom left) and picks an entry.
Future<void> accountMenu(WidgetTester tester, String entry) async {
  await tapKey(tester, 'account-menu');
  await tapText(tester, entry);
}

const serverUrl = 'http://127.0.0.1:8080';
