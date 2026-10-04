import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vianden_client/core/certificate_trust.dart';
import 'package:vianden_client/core/permissions.dart';
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

/// Permissions per role, as on the server (internal/perm).
const fakeRolePermissions = <Role, List<String>>{
  Role.owner: [
    Permission.manageChannels,
    Permission.manageInvites,
    Permission.manageRoles,
    Permission.deleteMessages,
    Permission.kickMembers,
    Permission.banMembers,
  ],
  Role.admin: [
    Permission.manageChannels,
    Permission.manageInvites,
    Permission.manageRoles,
    Permission.deleteMessages,
    Permission.kickMembers,
    Permission.banMembers,
  ],
  Role.moderator: [Permission.deleteMessages, Permission.kickMembers],
  Role.member: [],
};

class FakeUser {
  FakeUser(
    this.id,
    this.username,
    this.displayName,
    this.password, {
    this.role = Role.member,
  });
  final int id;
  final String username;
  final String displayName;
  final String password;
  Role role;
  bool banned = false;
  String banReason = '';

  bool can(String p) => fakeRolePermissions[role]!.contains(p);

  /// perm.CanActOn: the permission AND a higher role than the target.
  bool canActOn(String p, Role target) => can(p) && role.above(target);

  Map<String, Object> toJson() => {
    'id': id,
    'username': username,
    'display_name': displayName,
    'role': role.wire,
    'permissions': fakeRolePermissions[role]!,
  };

  Map<String, Object> memberJson(FakeUser viewer) => {
    'id': id,
    'username': username,
    'display_name': displayName,
    'role': role.wire,
    if (viewer.can(Permission.banMembers)) ...{
      'banned': banned,
      'ban_reason': banReason,
    },
  };
}

class FakeChannel {
  FakeChannel(
    this.id,
    this.name, [
    this.topic = '',
    this.viewRole = Role.member,
    this.sendRole = Role.member,
  ]);
  final int id;
  String name;
  String topic;
  Role viewRole;
  Role sendRole;

  bool canView(FakeUser u) => u.role.atLeast(viewRole);
  bool canSend(FakeUser u) => canView(u) && u.role.atLeast(sendRole);
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
  String content;
  final DateTime createdAt;
  bool deleted = false;
  DateTime? editedAt;

  /// The message this one replies to (the quote is built from its CURRENT state,
  /// like the real server's query does).
  FakeMessage? replyTo;

  static Map<String, Object?>? _author(FakeUser? u) => u == null
      ? null
      : {'id': u.id, 'username': u.username, 'display_name': u.displayName};

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
    'deleted': deleted,
    'created_at': createdAt.toUtc().toIso8601String(),
    'edited_at': editedAt?.toUtc().toIso8601String(),
    'reply_to': switch (replyTo) {
      null => null,
      final r => {
        'id': r.id,
        'author': _author(r.author),
        'content': r.content.runes.length > 100
            ? '${String.fromCharCodes(r.content.runes.take(100))}…'
            : r.content,
        'deleted': r.deleted,
      },
    },
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
    FakeUser(1, 'osama', 'Osama', 'owner-pass-1', role: Role.owner),
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
    FakeMessage? replyTo,
  }) {
    final m = FakeMessage(
      _nextMessageId++,
      channelId,
      user(username),
      content,
      at ?? DateTime.now(),
    )..replyTo = replyTo;
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

  /// Sends an event to every connected client (optionally only to some users).
  void pushAll(String type, Object? data, [bool Function(FakeUser)? to]) {
    for (final c in List.of(connections)) {
      if (to == null || to(c.user!)) c.push(type, data);
    }
  }

  /// Someone else sends a message: stored AND pushed live, like the real server.
  FakeMessage postLive(int channelId, String username, String content) {
    final m = post(channelId, username, content);
    final ch = channels.firstWhere((c) => c.id == channelId);
    pushAll('message.created', m.toJson(), ch.canView);
    return m;
  }

  /// Ends every session (and live connection) of a user, like a kick or ban.
  void endUser(FakeUser u) {
    for (final t in [
      for (final e in tokens.entries)
        if (e.value.id == u.id) e.key,
    ]) {
      endSession(t);
    }
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
        if (u.first.banned) {
          return _error(
            403,
            'account_banned',
            u.first.banReason.isEmpty
                ? 'this account is banned'
                : 'this account is banned: ${u.first.banReason}',
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

    final forbidden = _error(
      403,
      'forbidden',
      'you do not have permission to do this',
    );

    final channelPath = RegExp(
      r'^/api/v1/channels/(\d+)(/messages)?(?:/(\d+))?$',
    ).firstMatch(path);
    final channelId = channelPath == null
        ? null
        : int.parse(channelPath.group(1)!);
    // A channel you cannot see does not exist for you (404, like the server).
    final channel = channels
        .where((c) => c.id == channelId && c.canView(me))
        .firstOrNull;
    final isMessages = channelPath?.group(2) != null;
    final messageId = int.tryParse(channelPath?.group(3) ?? '');

    // ---- members ----
    if (path == '/api/v1/users' && r.method == 'GET') {
      return _json(200, {
        'users': [for (final u in users) u.memberJson(me)],
      });
    }
    final userPath = RegExp(r'^/api/v1/users/(\d+)(/kick|/ban)?$')
        .firstMatch(path);
    if (userPath != null) {
      final target = users
          .where((u) => u.id == int.parse(userPath.group(1)!))
          .firstOrNull;
      if (target == null) return _error(404, 'not_found', 'user not found');
      switch ((r.method, userPath.group(2))) {
        case ('PATCH', null):
          final role = Role.values
              .where((x) => x.wire == body['role'])
              .firstOrNull;
          if (role == null || role == Role.owner) {
            return _error(400, 'invalid_role', 'role: invalid');
          }
          if (!me.canActOn(Permission.manageRoles, target.role) ||
              !me.role.above(role)) {
            return forbidden;
          }
          target.role = role;
          pushAll('member.updated', {..._info(target), 'role': role.wire});
          return _json(200, {'user': target.memberJson(me)});
        case ('POST', '/kick'):
          if (!me.canActOn(Permission.kickMembers, target.role)) {
            return forbidden;
          }
          endUser(target);
          return http.Response('', 204);
        case ('POST', '/ban'):
          if (!me.canActOn(Permission.banMembers, target.role)) {
            return forbidden;
          }
          target
            ..banned = true
            ..banReason = (body['reason'] as String? ?? '').trim();
          endUser(target);
          return http.Response('', 204);
        case ('DELETE', '/ban'):
          if (!me.canActOn(Permission.banMembers, target.role)) {
            return forbidden;
          }
          target
            ..banned = false
            ..banReason = '';
          return http.Response('', 204);
      }
    }

    switch ((r.method, path)) {
      case ('GET', '/api/v1/me'):
        return _json(200, {'user': me.toJson()});

      case ('POST', '/api/v1/logout'):
        endSession(bearer.substring(7));
        return http.Response('', 204);

      case ('POST', '/api/v1/invites'):
        if (!me.can(Permission.manageInvites)) return forbidden;
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
            for (final c in channels)
              if (c.canView(me)) _channelJson(c, withPreview: true),
          ],
        });

      case ('POST', '/api/v1/channels'):
        if (!me.can(Permission.manageChannels)) return forbidden;
        final view = Role.parse(body['view_role'] as String? ?? 'member');
        final send = Role.parse(body['send_role'] as String? ?? view.wire);
        if (view.above(me.role) || send.above(me.role)) return forbidden;
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
          view,
          send,
        );
        channels.add(c);
        pushAll('channel.created', _channelJson(c), c.canView);
        return _json(201, {'channel': _channelJson(c)});
    }

    if (channelPath != null && channel == null) {
      return _error(404, 'not_found', 'channel not found');
    }

    if (channel != null && !isMessages) {
      if (!me.can(Permission.manageChannels) ||
          channel.sendRole.above(me.role)) {
        return forbidden;
      }
      switch (r.method) {
        case 'PATCH':
          final view = body['view_role'] is String
              ? Role.parse(body['view_role'] as String)
              : channel.viewRole;
          var send = body['send_role'] is String
              ? Role.parse(body['send_role'] as String)
              : channel.sendRole;
          if (body['send_role'] == null && !send.atLeast(view)) send = view;
          if (view.above(me.role) || send.above(me.role)) return forbidden;
          final before = channel.viewRole;
          if (body['name'] case final String n) channel.name = n.trim();
          if (body['topic'] case final String t) channel.topic = t.trim();
          channel
            ..viewRole = view
            ..sendRole = send;
          pushAll('channel.updated', _channelJson(channel), channel.canView);
          // Users who could see it before but not now: it is "deleted" for them.
          pushAll('channel.deleted', {
            'id': channel.id,
          }, (u) => u.role.atLeast(before) && !channel.canView(u));
          return _json(200, {'channel': _channelJson(channel)});
        case 'DELETE':
          channels.remove(channel);
          messages.removeWhere((m) => m.channelId == channel.id);
          pushAll('channel.deleted', {'id': channel.id}, channel.canView);
          return http.Response('', 204);
      }
    }

    if (channel != null && messageId != null && r.method == 'PATCH') {
      final m = messages
          .where((m) => m.id == messageId && m.channelId == channel.id)
          .firstOrNull;
      if (m == null || m.deleted) {
        return _error(404, 'not_found', 'message not found');
      }
      if (!channel.canSend(me)) {
        return _error(403, 'read_only', 'you cannot write in this channel');
      }
      if (m.author?.id != me.id) return forbidden;
      m
        ..content = body['content'] as String
        ..editedAt = DateTime.now();
      pushAll('message.updated', m.toJson(), channel.canView);
      return _json(200, {'message': m.toJson()});
    }

    if (channel != null && messageId != null && r.method == 'DELETE') {
      final m = messages
          .where((m) => m.id == messageId && m.channelId == channel.id)
          .firstOrNull;
      if (m == null || m.deleted) {
        return _error(404, 'not_found', 'message not found');
      }
      // Your own: always. Someone else's: permission + below you
      // (a deleted account counts as below everyone).
      final own = m.author?.id == me.id;
      final authorRole = m.author?.role;
      if (!own &&
          (!me.can(Permission.deleteMessages) ||
              (authorRole != null && !me.role.above(authorRole)))) {
        return forbidden;
      }
      m
        ..deleted = true
        ..content = '';
      pushAll('message.deleted', {
        'id': m.id,
        'channel_id': channel.id,
      }, channel.canView);
      return http.Response('', 204);
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
          if (!channel.canSend(me)) {
            return _error(403, 'read_only', 'you cannot write in this channel');
          }
          FakeMessage? replyTo;
          if (body['reply_to'] case final int id) {
            replyTo = messages
                .where((x) => x.id == id && x.channelId == channel.id)
                .where((x) => !x.deleted)
                .firstOrNull;
            if (replyTo == null) {
              return _error(
                400,
                'invalid_reply_to',
                'reply_to: no such message in this channel',
              );
            }
          }
          final m = post(
            channel.id,
            me.username,
            body['content'] as String,
            replyTo: replyTo,
          );
          pushAll('message.created', m.toJson(), channel.canView);
          return _json(201, {'message': m.toJson()});
      }
    }
    return _error(404, 'not_found', 'route not found');
  }

  Map<String, Object?> _channelJson(FakeChannel c, {bool withPreview = false}) {
    final last = messages
        .where((m) => m.channelId == c.id && !m.deleted)
        .lastOrNull;
    return {
      'id': c.id,
      'name': c.name,
      'topic': c.topic,
      'type': 'text',
      'position': channels.indexOf(c),
      'view_role': c.viewRole.wire,
      'send_role': c.sendRole.wire,
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
