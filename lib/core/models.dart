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

/// A text channel ("room"), with a preview of its newest message.
class Channel {
  const Channel({
    required this.id,
    required this.name,
    required this.topic,
    required this.position,
    this.lastMessage,
  });

  factory Channel.fromJson(Object? json) {
    if (json case {
      'id': int id,
      'name': String name,
      'topic': String topic,
      'position': int position,
    }) {
      final last = (json as Map)['last_message'];
      return Channel(
        id: id,
        name: name,
        topic: topic,
        position: position,
        lastMessage: last == null ? null : MessagePreview.fromJson(last),
      );
    }
    throw const FormatException('unexpected channel object');
  }

  final int id;
  final String name;
  final String topic;
  final int position;
  final MessagePreview? lastMessage;
}

class MessagePreview {
  const MessagePreview({
    required this.authorName,
    required this.content,
    required this.createdAt,
  });

  factory MessagePreview.fromJson(Object? json) {
    if (json case {
      'author_name': String authorName,
      'content': String content,
      'created_at': String createdAt,
    }) {
      return MessagePreview(
        authorName: authorName,
        content: content,
        createdAt: DateTime.parse(createdAt),
      );
    }
    throw const FormatException('unexpected message preview');
  }

  final String authorName;
  final String content;
  final DateTime createdAt;
}

/// Who sent a message. Null on a message means the account was deleted.
class Author {
  const Author({
    required this.id,
    required this.username,
    required this.displayName,
  });

  factory Author.fromJson(Object? json) {
    if (json case {
      'id': int id,
      'username': String username,
      'display_name': String displayName,
    }) {
      return Author(id: id, username: username, displayName: displayName);
    }
    throw const FormatException('unexpected author object');
  }

  final int id;
  final String username;
  final String displayName;
}

class Message {
  const Message({
    required this.id,
    required this.channelId,
    required this.author,
    required this.content,
    required this.createdAt,
  });

  factory Message.fromJson(Object? json) {
    if (json case {
      'id': int id,
      'channel_id': int channelId,
      'content': String content,
      'created_at': String createdAt,
    }) {
      final author = (json as Map)['author'];
      return Message(
        id: id,
        channelId: channelId,
        author: author == null ? null : Author.fromJson(author),
        content: content,
        createdAt: DateTime.parse(createdAt),
      );
    }
    throw const FormatException('unexpected message object');
  }

  final int id;
  final int channelId;
  final Author? author;
  final String content;
  final DateTime createdAt;
}

/// One page of history: messages oldest first, and whether older ones exist.
class MessagePage {
  const MessagePage(this.messages, this.hasMore);
  final List<Message> messages;
  final bool hasMore;
}
