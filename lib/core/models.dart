/// Data sent by the server (see the server's docs/API.md).
///
/// Every `fromJson` checks field names AND types, and throws a [FormatException]
/// if anything is missing or wrong: data from a server is never trusted blindly.
library;

class User {
  const User({
    required this.id,
    required this.username,
    required this.displayName,
    required this.isOwner,
  });

  factory User.fromJson(Object? json) {
    if (json case {
      'id': int id,
      'username': String username,
      'display_name': String displayName,
      'is_owner': bool isOwner,
    }) {
      return User(
        id: id,
        username: username,
        displayName: displayName,
        isOwner: isOwner,
      );
    }
    throw const FormatException('unexpected user object');
  }

  final int id;
  final String username;
  final String displayName;
  final bool isOwner;
}

/// A logged-in user plus their session token (from register and login).
class AuthSession {
  const AuthSession({required this.user, required this.token});

  factory AuthSession.fromJson(Object? json) {
    if (json case {'user': Object user, 'token': String token}) {
      return AuthSession(user: User.fromJson(user), token: token);
    }
    throw const FormatException('unexpected session response');
  }

  final User user;
  final String token;
}

class Invite {
  const Invite({
    required this.id,
    required this.maxUses,
    required this.uses,
    required this.expiresAt,
  });

  factory Invite.fromJson(Object? json) {
    if (json case {
      'id': int id,
      'max_uses': int maxUses,
      'uses': int uses,
      'expires_at': String expiresAt,
    }) {
      return Invite(
        id: id,
        maxUses: maxUses,
        uses: uses,
        expiresAt: DateTime.parse(expiresAt),
      );
    }
    throw const FormatException('unexpected invite object');
  }

  final int id;
  final int maxUses;
  final int uses;
  final DateTime expiresAt;
}

/// A new invite plus its code. The code is only ever sent once, in this response.
class CreatedInvite {
  const CreatedInvite({required this.invite, required this.code});

  factory CreatedInvite.fromJson(Object? json) {
    if (json case {'invite': Object invite, 'code': String code}) {
      return CreatedInvite(invite: Invite.fromJson(invite), code: code);
    }
    throw const FormatException('unexpected invite response');
  }

  final Invite invite;
  final String code;
}
