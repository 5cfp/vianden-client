/// Data sent by the server (see the server's docs/API.md).
///
/// Every `fromJson` checks field names AND types, and throws a [FormatException]
/// if anything is missing or wrong: data from a server is never trusted blindly.
library;

import 'permissions.dart';

class User {
  const User({
    required this.id,
    required this.username,
    required this.displayName,
    required this.role,
    this.permissions = const {},
    this.avatar,
  });

  factory User.fromJson(Object? json) {
    if (json case {
      'id': int id,
      'username': String username,
      'display_name': String displayName,
    }) {
      final map = json as Map;
      final perms = map['permissions'];
      return User(
        id: id,
        username: username,
        displayName: displayName,
        // Servers before roles only sent is_owner.
        role: map['role'] is String
            ? Role.parse(map['role'] as String)
            : (map['is_owner'] == true ? Role.owner : Role.member),
        permissions: perms is List
            ? {
                for (final p in perms)
                  if (p is String) p,
              }
            : const {},
        avatar: _avatarPath(map['avatar']),
      );
    }
    throw const FormatException('unexpected user object');
  }

  final int id;
  final String username;
  final String displayName;
  final Role role;

  /// What this user may do (from the server). Only used to show or hide actions.
  final Set<String> permissions;

  /// URL path of the avatar (e.g. /api/v1/avatars/...), or null.
  final String? avatar;

  bool get isOwner => role == Role.owner;
  bool can(String permission) => permissions.contains(permission);
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
    this.type = 'text',
    this.viewRole = Role.member,
    this.sendRole = Role.member,
    this.lastMessage,
    this.lastReadId = 0,
    this.unreadCount = 0,
    this.mentionCount = 0,
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
        type: json['type'] is String ? json['type'] as String : 'text',
        viewRole: Role.parse((json)['view_role'] as String?),
        sendRole: Role.parse((json)['send_role'] as String?),
        lastMessage: last == null ? null : MessagePreview.fromJson(last),
        lastReadId: _int(json['last_read_id']),
        unreadCount: _int(json['unread_count']),
        mentionCount: _int(json['mention_count']),
      );
    }
    throw const FormatException('unexpected channel object');
  }

  final int id;
  final String name;
  final String topic;
  final int position;

  /// "text" or "voice" (voice-only: no messages). Set at creation, never changes.
  final String type;
  bool get isVoice => type == 'voice';

  /// Minimum role to see / to write in this channel. (Voice: who may join / speak.)
  final Role viewRole;
  final Role sendRole;
  final MessagePreview? lastMessage;

  /// For the logged-in user: newest message read, and how many newer ones (and
  /// mentions) there are. The server stops counting at 100 ("99+").
  final int lastReadId;
  final int unreadCount;
  final int mentionCount;

  bool canSend(Role r) => r.atLeast(viewRole) && r.atLeast(sendRole);
  bool get isPrivate => viewRole != Role.member;
  bool get isReadOnlyForMembers => sendRole != Role.member;

  /// A copy with some fields changed (everything else, like the access roles, is kept).
  Channel copyWith({
    MessagePreview? lastMessage,
    int? lastReadId,
    int? unreadCount,
    int? mentionCount,
  }) => Channel(
    id: id,
    name: name,
    topic: topic,
    position: position,
    type: type,
    viewRole: viewRole,
    sendRole: sendRole,
    lastMessage: lastMessage ?? this.lastMessage,
    lastReadId: lastReadId ?? this.lastReadId,
    unreadCount: unreadCount ?? this.unreadCount,
    mentionCount: mentionCount ?? this.mentionCount,
  );
}

/// An optional integer field (missing on older servers) as 0.
int _int(Object? v) => v is int ? v : 0;

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

/// The short quote shown above a reply (the message it answers).
class ReplyQuote {
  const ReplyQuote({
    required this.id,
    required this.author,
    required this.content,
    this.deleted = false,
  });

  factory ReplyQuote.fromJson(Object? json) {
    if (json case {'id': int id, 'content': String content}) {
      final author = (json as Map)['author'];
      return ReplyQuote(
        id: id,
        author: author == null ? null : Author.fromJson(author),
        content: content,
        deleted: json['deleted'] == true,
      );
    }
    throw const FormatException('unexpected reply_to object');
  }

  /// A quote of [m], shortened like the server does (100 characters + "…").
  factory ReplyQuote.of(Message m) => ReplyQuote(
    id: m.id,
    author: m.author,
    // Counted in code points ("runes"), exactly like the server's Go code.
    content: m.content.runes.length > 100
        ? '${String.fromCharCodes(m.content.runes.take(100))}…'
        : m.content,
    deleted: m.deleted,
  );

  final int id;
  final Author? author;
  final String content;
  final bool deleted;
}

class Message {
  const Message({
    required this.id,
    required this.channelId,
    required this.author,
    required this.content,
    required this.createdAt,
    this.deleted = false,
    this.editedAt,
    this.replyTo,
    this.mentions = const [],
    this.mentionsEveryone = false,
    this.attachments = const [],
  });

  factory Message.fromJson(Object? json) {
    if (json case {
      'id': int id,
      'channel_id': int channelId,
      'content': String content,
      'created_at': String createdAt,
    }) {
      final map = json as Map;
      final author = map['author'];
      final edited = map['edited_at'];
      final reply = map['reply_to'];
      return Message(
        id: id,
        channelId: channelId,
        author: author == null ? null : Author.fromJson(author),
        content: content,
        createdAt: DateTime.parse(createdAt),
        deleted: map['deleted'] == true,
        editedAt: edited is String ? DateTime.parse(edited) : null,
        replyTo: reply == null ? null : ReplyQuote.fromJson(reply),
        mentions: [
          if (map['mentions'] case final List<Object?> list)
            for (final a in list) Author.fromJson(a),
        ],
        mentionsEveryone: map['mentions_everyone'] == true,
        attachments: [
          if (map['attachments'] case final List<Object?> list)
            for (final a in list) Attachment.fromJson(a),
        ],
      );
    }
    throw const FormatException('unexpected message object');
  }

  final int id;
  final int channelId;
  final Author? author;
  final String content;
  final DateTime createdAt;

  /// Deleted by its author or a moderator: show a placeholder ([content] is empty).
  final bool deleted;

  /// When the author last edited it; null if never.
  final DateTime? editedAt;

  /// The message this one answers; null if it is not a reply.
  final ReplyQuote? replyTo;

  /// Who it pings (@username, or a reply to them), and whether it pinged @everyone.
  final List<Author> mentions;
  final bool mentionsEveryone;

  /// Files sent with it (none once it is deleted).
  final List<Attachment> attachments;

  /// Does this message ping the user with this id?
  bool mentionsUser(int userId) =>
      mentionsEveryone || mentions.any((a) => a.id == userId);

  Message _copy({
    String? content,
    bool? deleted,
    DateTime? editedAt,
    ReplyQuote? replyTo,
  }) => Message(
    id: id,
    channelId: channelId,
    author: author,
    content: content ?? this.content,
    createdAt: createdAt,
    deleted: deleted ?? this.deleted,
    editedAt: editedAt ?? this.editedAt,
    replyTo: replyTo ?? this.replyTo,
    mentions: mentions,
    mentionsEveryone: mentionsEveryone,
    attachments: deleted == true ? const [] : attachments,
  );

  Message asDeleted() => _copy(content: '', deleted: true);

  /// If this is a reply to [original], returns a copy whose quote shows its new state
  /// (edited text or deleted); otherwise returns this message unchanged.
  Message withQuoteOf(Message original) => replyTo?.id == original.id
      ? _copy(replyTo: ReplyQuote.of(original))
      : this;
}

/// One page of history: messages oldest first, and whether older ones exist.
class MessagePage {
  const MessagePage(this.messages, this.hasMore);
  final List<Message> messages;
  final bool hasMore;
}

/// A user in the member list. Ban details are only sent to users who may ban.
class Member {
  const Member({
    required this.id,
    required this.username,
    required this.displayName,
    required this.role,
    this.banned,
    this.banReason,
    this.avatar,
  });

  factory Member.fromJson(Object? json) {
    if (json case {
      'id': int id,
      'username': String username,
      'display_name': String displayName,
      'role': String role,
    }) {
      final map = json as Map;
      return Member(
        id: id,
        username: username,
        displayName: displayName,
        role: Role.parse(role),
        banned: map['banned'] is bool ? map['banned'] as bool : null,
        banReason: map['ban_reason'] is String
            ? map['ban_reason'] as String
            : null,
        avatar: _avatarPath(map['avatar']),
      );
    }
    throw const FormatException('unexpected member object');
  }

  final int id;
  final String username;
  final String displayName;
  final Role role;

  /// null when the viewer may not see ban details.
  final bool? banned;
  final String? banReason;

  /// URL path of the avatar, or null.
  final String? avatar;
}

/// An uploaded file. Images (decided by the server from the content) are shown inline;
/// everything else is offered as a download.
class Attachment {
  const Attachment({
    required this.id,
    required this.filename,
    required this.contentType,
    required this.size,
    this.width,
    this.height,
  });

  factory Attachment.fromJson(Object? json) {
    if (json case {
      'id': int id,
      'filename': String filename,
      'content_type': String contentType,
      'size': int size,
    }) {
      return Attachment(
        id: id,
        filename: filename,
        contentType: contentType,
        size: size,
        width: (json as Map)['width'] as int?,
        height: json['height'] as int?,
      );
    }
    throw const FormatException('unexpected attachment object');
  }

  final int id;
  final String filename;
  final String contentType;
  final int size;
  final int? width;
  final int? height;

  static const _imageTypes = {
    'image/png',
    'image/jpeg',
    'image/gif',
    'image/webp',
  };

  bool get isImage => _imageTypes.contains(contentType);

  /// "2.4 MB", "830 KB", "12 bytes".
  String get sizeLabel => switch (size) {
    < 1024 => '$size bytes',
    < 1024 * 1024 => '${(size / 1024).round()} KB',
    _ => '${(size / (1024 * 1024)).toStringAsFixed(1)} MB',
  };
}

/// Accepts only avatar paths on this server (`/api/v1/avatars/<hex>`), so a server can
/// never make the app fetch some other URL.
String? _avatarPath(Object? v) =>
    v is String && RegExp(r'^/api/v1/avatars/[0-9a-f]{64}$').hasMatch(v)
    ? v
    : null;

/// One person in a voice channel (see docs/API.md, "Voice channel state").
class VoiceParticipant {
  const VoiceParticipant({
    required this.user,
    this.muted = false,
    this.deafened = false,
    this.serverMuted = false,
    this.canSpeak = true,
  });

  factory VoiceParticipant.fromJson(Object? json) {
    if (json case {'user': Object user}) {
      final map = json as Map;
      return VoiceParticipant(
        user: Author.fromJson(user),
        muted: map['muted'] == true,
        deafened: map['deafened'] == true,
        serverMuted: map['server_muted'] == true,
        canSpeak: map['can_speak'] != false,
      );
    }
    throw const FormatException('unexpected voice participant');
  }

  final Author user;
  final bool muted;
  final bool deafened;
  final bool serverMuted;
  final bool canSpeak;
}

/// Who is in one voice channel.
class VoiceChannelState {
  const VoiceChannelState(this.channelId, this.participants);

  factory VoiceChannelState.fromJson(Object? json) {
    if (json case {'channel_id': int id, 'participants': List<Object?> list}) {
      return VoiceChannelState(id, [
        for (final p in list) VoiceParticipant.fromJson(p),
      ]);
    }
    throw const FormatException('unexpected voice state');
  }

  final int channelId;
  final List<VoiceParticipant> participants;
}
