import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'models.dart';
import 'permissions.dart';

/// The server answered with an error (see "Standard error format" in docs/API.md).
class ApiException implements Exception {
  const ApiException(this.statusCode, this.code, this.message);

  /// Builds a user-friendly exception from an error response.
  factory ApiException.fromResponse(http.Response response) {
    var code = 'unknown_error';
    var message = 'The server reported an error (HTTP ${response.statusCode}).';
    try {
      if (jsonDecode(utf8.decode(response.bodyBytes)) case {
        'error': {'code': String c, 'message': String m},
      }) {
        code = c;
        message = _capitalize(m);
      }
    } on FormatException {
      // Not JSON: keep the generic message.
    }

    // A few codes get friendlier wording than the server's technical message.
    switch (code) {
      case 'invalid_credentials':
        message = 'Wrong username or password.';
      case 'rate_limited':
        final seconds = response.headers['retry-after'];
        message = seconds == null
            ? 'Too many attempts. Please wait a moment.'
            : 'Too many attempts. Try again in $seconds seconds.';
      case 'internal_error':
        message = 'Something went wrong on the server. Try again later.';
    }
    return ApiException(response.statusCode, code, message);
  }

  final int statusCode;

  /// Machine-readable error code from the server, e.g. `invalid_invite`.
  final String code;

  /// Message that can be shown to the user as-is.
  final String message;

  /// The session token is no longer valid: the user must log in again.
  bool get isUnauthorized => statusCode == 401 && code == 'unauthorized';

  @override
  String toString() => message;
}

/// The server could not be reached at all (no connection, timeout, ...).
class NetworkException implements Exception {
  const NetworkException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Talks to one server's REST API. Pass [token] for calls that need a logged-in user.
class ApiClient {
  ApiClient({required this.server, required this.httpClient, this.token});

  final Uri server;
  final http.Client httpClient;
  final String? token;

  static const _timeout = Duration(seconds: 10);

  Future<AuthSession> register({
    required String username,
    required String displayName,
    required String password,
    required String inviteCode,
  }) async {
    final json = await _send(
      'POST',
      '/api/v1/register',
      body: {
        'username': username,
        'display_name': displayName,
        'password': password,
        'invite_code': inviteCode,
      },
    );
    return _parse(() => AuthSession.fromJson(json));
  }

  Future<AuthSession> login(String username, String password) async {
    final json = await _send(
      'POST',
      '/api/v1/login',
      body: {'username': username, 'password': password},
    );
    return _parse(() => AuthSession.fromJson(json));
  }

  Future<User> me() async {
    final json = await _send('GET', '/api/v1/me');
    return _parse(() {
      if (json case {'user': Object user}) return User.fromJson(user);
      throw const FormatException('unexpected /me response');
    });
  }

  Future<void> logout() => _send('POST', '/api/v1/logout');

  /// Creates an invite with the server's defaults (1 use, 7 days).
  Future<CreatedInvite> createInvite() async {
    final json = await _send(
      'POST',
      '/api/v1/invites',
      body: <String, Object>{},
    );
    return _parse(() => CreatedInvite.fromJson(json));
  }

  Future<List<Channel>> listChannels() async {
    final json = await _send('GET', '/api/v1/channels');
    return _parse(() {
      if (json case {'channels': List<Object?> list}) {
        return [for (final c in list) Channel.fromJson(c)];
      }
      throw const FormatException('unexpected channel list');
    });
  }

  Future<Channel> createChannel(
    String name, {
    String topic = '',
    Role viewRole = Role.member,
    Role? sendRole, // null: the server uses viewRole
  }) async {
    final json = await _send(
      'POST',
      '/api/v1/channels',
      body: {
        'name': name,
        'topic': topic,
        'view_role': viewRole.wire,
        'send_role': ?sendRole?.wire,
      },
    );
    return _parse(() => _channel(json));
  }

  /// Changes channel settings. Only non-null values are sent.
  Future<Channel> updateChannel(
    int id, {
    String? name,
    String? topic,
    Role? viewRole,
    Role? sendRole,
  }) async {
    final json = await _send(
      'PATCH',
      '/api/v1/channels/$id',
      body: {
        'name': ?name,
        'topic': ?topic,
        'view_role': ?viewRole?.wire,
        'send_role': ?sendRole?.wire,
      },
    );
    return _parse(() => _channel(json));
  }

  Future<void> deleteChannel(int id) => _send('DELETE', '/api/v1/channels/$id');

  /// Deletes someone's message (moderators and up; the server checks).
  /// Uploads a file (raw bytes). Send its id with a message afterwards.
  Future<Attachment> uploadAttachment(String filename, List<int> bytes) async {
    final json = await _send(
      'POST',
      '/api/v1/attachments',
      query: {'filename': filename},
      bytes: bytes,
      timeout: const Duration(minutes: 5), // same as the server allows
    );
    return _parse(() {
      if (json case {'attachment': Object a}) return Attachment.fromJson(a);
      throw const FormatException('unexpected attachment response');
    });
  }

  /// Downloads a file's bytes. Goes through our own HTTP client, so it uses the same
  /// login and trusted certificates as everything else.
  Future<List<int>> downloadAttachment(int id) async {
    final response = await _request(
      'GET',
      '/api/v1/attachments/$id',
      timeout: const Duration(minutes: 5),
    );
    return response.bodyBytes;
  }

  /// Changes your own display name.
  Future<User> updateProfile(String displayName) async => _user(
    await _send('PATCH', '/api/v1/me', body: {'display_name': displayName}),
  );

  /// Sets your avatar from an image file (the server crops and resizes it).
  Future<User> setAvatar(List<int> imageBytes) async => _user(
    await _send(
      'PUT',
      '/api/v1/me/avatar',
      bytes: imageBytes,
      timeout: const Duration(minutes: 2),
    ),
  );

  Future<User> removeAvatar() async =>
      _user(await _send('DELETE', '/api/v1/me/avatar'));

  /// Downloads an avatar by the path from a user or member object.
  Future<List<int>> downloadAvatar(String path) async =>
      (await _request('GET', path)).bodyBytes;

  User _user(Object? json) => _parse(() {
    if (json case {'user': Object u}) return User.fromJson(u);
    throw const FormatException('unexpected user response');
  });

  /// Tells the server we have read the room up to [messageId] (it never moves back).
  Future<void> markRead(int channelId, int messageId) => _send(
    'PUT',
    '/api/v1/channels/$channelId/read',
    body: {'message_id': messageId},
  );

  Future<void> deleteMessage(int channelId, int messageId) =>
      _send('DELETE', '/api/v1/channels/$channelId/messages/$messageId');

  Future<List<Member>> listMembers() async {
    final json = await _send('GET', '/api/v1/users');
    return _parse(() {
      if (json case {'users': List<Object?> list}) {
        return [for (final m in list) Member.fromJson(m)];
      }
      throw const FormatException('unexpected member list');
    });
  }

  Future<Member> setRole(int userId, Role role) async {
    final json = await _send(
      'PATCH',
      '/api/v1/users/$userId',
      body: {'role': role.wire},
    );
    return _parse(() {
      if (json case {'user': Object m}) return Member.fromJson(m);
      throw const FormatException('unexpected member response');
    });
  }

  Future<void> kick(int userId) => _send('POST', '/api/v1/users/$userId/kick');

  Future<void> ban(int userId, {String reason = ''}) =>
      _send('POST', '/api/v1/users/$userId/ban', body: {'reason': reason});

  Future<void> unban(int userId) =>
      _send('DELETE', '/api/v1/users/$userId/ban');

  /// One page of history. [before]: id of the oldest message already loaded (null = newest page).
  Future<MessagePage> listMessages(
    int channelId, {
    int? before,
    int limit = 50,
  }) async {
    final json = await _send(
      'GET',
      '/api/v1/channels/$channelId/messages',
      query: {'limit': '$limit', 'before': ?before?.toString()},
    );
    return _parse(() {
      if (json case {
        'messages': List<Object?> list,
        'has_more': bool hasMore,
      }) {
        return MessagePage([
          for (final m in list) Message.fromJson(m),
        ], hasMore);
      }
      throw const FormatException('unexpected message page');
    });
  }

  /// Sends a message; [replyTo] is the id of the message it answers (same room).
  Future<Message> sendMessage(
    int channelId,
    String content, {
    int? replyTo,
    List<int> attachments = const [],
  }) async {
    final json = await _send(
      'POST',
      '/api/v1/channels/$channelId/messages',
      body: {
        'content': content,
        'reply_to': ?replyTo,
        if (attachments.isNotEmpty) 'attachments': attachments,
      },
    );
    return _message(json);
  }

  /// Changes the text of one of your own messages.
  Future<Message> editMessage(
    int channelId,
    int messageId,
    String content,
  ) async {
    final json = await _send(
      'PATCH',
      '/api/v1/channels/$channelId/messages/$messageId',
      body: {'content': content},
    );
    return _message(json);
  }

  Message _message(Object? json) => _parse(() {
    if (json case {'message': Object m}) return Message.fromJson(m);
    throw const FormatException('unexpected message response');
  });

  static Channel _channel(Object? json) {
    if (json case {'channel': Object c}) return Channel.fromJson(c);
    throw const FormatException('unexpected channel response');
  }

  /// Sends a request and returns the decoded JSON body (null for 204 No Content).
  Future<Object?> _send(
    String method,
    String path, {
    Object? body,
    Map<String, String>? query,
    List<int>? bytes,
    Duration timeout = _timeout,
  }) async {
    final response = await _request(
      method,
      path,
      body: body,
      query: query,
      bytes: bytes,
      timeout: timeout,
    );
    if (response.statusCode == 204 || response.bodyBytes.isEmpty) {
      return null;
    }
    try {
      return jsonDecode(utf8.decode(response.bodyBytes));
    } on FormatException {
      throw _badResponse(response.statusCode);
    }
  }

  /// Sends a request (a JSON [body], or raw [bytes] for uploads) and returns the
  /// response; throws for errors.
  Future<http.Response> _request(
    String method,
    String path, {
    Object? body,
    Map<String, String>? query,
    List<int>? bytes,
    Duration timeout = _timeout,
  }) async {
    final url = server.replace(path: path, queryParameters: query);
    final request = http.Request(method, url);
    request.headers['Accept'] = 'application/json';
    if (token case final t?) {
      request.headers['Authorization'] = 'Bearer $t';
    }
    if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(body);
    } else if (bytes != null) {
      request.headers['Content-Type'] = 'application/octet-stream';
      request.bodyBytes = bytes;
    }

    final http.Response response;
    try {
      final streamed = await httpClient.send(request).timeout(timeout);
      response = await http.Response.fromStream(streamed).timeout(timeout);
    } on TimeoutException {
      throw const NetworkException('The server did not answer in time.');
    } on Exception {
      throw const NetworkException(
        'Could not reach the server. Check your connection.',
      );
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ApiException.fromResponse(response);
    }
    return response;
  }

  T _parse<T>(T Function() parse) {
    try {
      return parse();
    } on FormatException {
      throw _badResponse(200);
    }
  }

  static ApiException _badResponse(int status) => ApiException(
    status,
    'bad_response',
    'The server sent an unexpected response.',
  );
}

String _capitalize(String s) =>
    s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);
