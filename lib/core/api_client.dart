import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'models.dart';

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

  Future<Channel> createChannel(String name, {String topic = ''}) async {
    final json = await _send(
      'POST',
      '/api/v1/channels',
      body: {'name': name, 'topic': topic},
    );
    return _parse(() => _channel(json));
  }

  /// Changes the name and/or topic. Only non-null values are sent.
  Future<Channel> updateChannel(int id, {String? name, String? topic}) async {
    final json = await _send(
      'PATCH',
      '/api/v1/channels/$id',
      body: {'name': ?name, 'topic': ?topic},
    );
    return _parse(() => _channel(json));
  }

  Future<void> deleteChannel(int id) => _send('DELETE', '/api/v1/channels/$id');

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

  Future<Message> sendMessage(int channelId, String content) async {
    final json = await _send(
      'POST',
      '/api/v1/channels/$channelId/messages',
      body: {'content': content},
    );
    return _parse(() {
      if (json case {'message': Object m}) return Message.fromJson(m);
      throw const FormatException('unexpected message response');
    });
  }

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
    }

    final http.Response response;
    try {
      final streamed = await httpClient.send(request).timeout(_timeout);
      response = await http.Response.fromStream(streamed).timeout(_timeout);
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
    if (response.statusCode == 204 || response.bodyBytes.isEmpty) {
      return null;
    }
    try {
      return jsonDecode(utf8.decode(response.bodyBytes));
    } on FormatException {
      throw _badResponse(response.statusCode);
    }
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
