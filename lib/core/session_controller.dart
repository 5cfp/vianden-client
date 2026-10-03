import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import 'api_client.dart';
import 'models.dart';
import 'server_info.dart';
import 'session_store.dart';

// ---------------------------------------------------------------------------
// Providers: the app-wide "sources" of shared objects and state.
// Tests replace (override) the first two with fakes.
// ---------------------------------------------------------------------------

/// One HTTP client for the whole app, closed when the app shuts down.
final httpClientProvider = Provider<http.Client>((ref) {
  final client = http.Client();
  ref.onDispose(client.close);
  return client;
});

/// Where the server address and session token are remembered.
final sessionStoreProvider = Provider<SessionStore>(
  (ref) => SecureSessionStore(),
);

/// The current app state (which screen to show). See [AppState].
final sessionProvider = AsyncNotifierProvider<SessionController, AppState>(
  SessionController.new,
);

// ---------------------------------------------------------------------------
// App states. `sealed` means these are ALL the possible states, so the compiler
// can check that every screen-switching `switch` handles each of them.
// ---------------------------------------------------------------------------

sealed class AppState {
  const AppState();
}

/// No server chosen yet: show the connect screen.
class NeedsServer extends AppState {
  const NeedsServer();
}

/// A server is known, but nobody is logged in: show login/register.
class LoggedOut extends AppState {
  const LoggedOut(this.server, this.info);
  final Uri server;
  final ServerInfo info;
}

/// Logged in: show the main app.
class LoggedIn extends AppState {
  const LoggedIn(this.server, this.info, this.user, this.token);
  final Uri server;
  final ServerInfo info;
  final User user;
  final String token;
}

/// The saved server could not be reached (or is incompatible): offer retry or another server.
class ServerProblem extends AppState {
  const ServerProblem(this.server, this.message);
  final Uri server;
  final String message;
}

// ---------------------------------------------------------------------------

/// Owns the login state: restores it at startup, and changes it on connect,
/// login, register, and logout. Screens call these methods; they never touch
/// the token or the storage directly.
class SessionController extends AsyncNotifier<AppState> {
  SessionStore get _store => ref.read(sessionStoreProvider);
  http.Client get _http => ref.read(httpClientProvider);

  ApiClient _api(Uri server, [String? token]) =>
      ApiClient(server: server, httpClient: _http, token: token);

  /// Runs at startup: decides the first screen from what was saved last time.
  @override
  Future<AppState> build() => _restore();

  Future<AppState> _restore() async {
    final saved = await _store.readServer();
    if (saved == null) return const NeedsServer();
    final server = Uri.parse(saved);

    final ServerInfo info;
    try {
      info = await fetchServerInfo(server, client: _http);
    } on ConnectException catch (e) {
      return ServerProblem(server, e.message);
    }

    final token = await _store.readToken();
    if (token == null) return LoggedOut(server, info);

    try {
      final user = await _api(server, token).me();
      return LoggedIn(server, info, user, token);
    } on ApiException catch (e) {
      if (e.isUnauthorized) {
        // Expired or revoked (e.g. logged out elsewhere): forget it and ask to log in.
        await _store.deleteToken();
        return LoggedOut(server, info);
      }
      return ServerProblem(server, e.message);
    } on NetworkException catch (e) {
      // Keep the token: the server may just be down for a moment.
      return ServerProblem(server, e.message);
    }
  }

  /// Tries the saved server again (from the "server problem" screen).
  Future<void> retry() async {
    state = const AsyncLoading();
    state = AsyncData(await _restore());
  }

  /// The connect screen found a compatible server.
  Future<void> useServer(Uri server, ServerInfo info) async {
    await _store.writeServer(server.toString());
    await _store.deleteToken(); // a token belongs to one server only
    state = AsyncData(LoggedOut(server, info));
  }

  /// Logs in. Throws [ApiException] or [NetworkException] for the screen to show.
  Future<void> login(String username, String password) async {
    final (server, info) = _currentServer();
    final session = await _api(server).login(username, password);
    await _signedIn(server, info, session);
  }

  /// Registers. Throws [ApiException] or [NetworkException] for the screen to show.
  Future<void> register({
    required String username,
    required String displayName,
    required String password,
    required String inviteCode,
  }) async {
    final (server, info) = _currentServer();
    final session = await _api(server).register(
      username: username,
      displayName: displayName,
      password: password,
      inviteCode: inviteCode,
    );
    await _signedIn(server, info, session);
  }

  /// Logs out: tells the server to revoke the session, then forgets the token.
  Future<void> logout() async {
    final current = state.value;
    if (current is! LoggedIn) return;
    try {
      await _api(current.server, current.token).logout();
    } on Exception {
      // Even if the server cannot be reached, log out locally. The session
      // then simply expires on the server after 30 days without use.
    }
    await _store.deleteToken();
    state = AsyncData(LoggedOut(current.server, current.info));
  }

  /// Goes back to the connect screen and forgets the server (logs out first).
  Future<void> changeServer() async {
    await logout();
    await _store.clear();
    state = const AsyncData(NeedsServer());
  }

  /// Called when any request answers 401: the token stopped working.
  Future<void> sessionExpired() async {
    final current = state.value;
    if (current is! LoggedIn) return;
    await _store.deleteToken();
    state = AsyncData(LoggedOut(current.server, current.info));
  }

  /// An API client for the logged-in user (for screens that call the API).
  ApiClient authorizedApi() {
    final current = state.value;
    if (current is! LoggedIn) throw StateError('not logged in');
    return _api(current.server, current.token);
  }

  Future<void> _signedIn(Uri server, ServerInfo info, AuthSession s) async {
    await _store.writeToken(s.token);
    state = AsyncData(LoggedIn(server, info, s.user, s.token));
  }

  (Uri, ServerInfo) _currentServer() => switch (state.value) {
    LoggedOut(:final server, :final info) => (server, info),
    LoggedIn(:final server, :final info) => (server, info),
    _ => throw StateError('no server selected'),
  };
}
