/// Roles and permissions, mirroring the server (docs/API.md, "Roles and permissions").
///
/// The client uses these ONLY to decide what to show (hide buttons a user cannot use).
/// The server checks every request on its own: changing this file cannot give anyone
/// more power.
library;

enum Role {
  member('member', 'Member'),
  moderator('moderator', 'Moderator'),
  admin('admin', 'Admin'),
  owner('owner', 'Owner');

  const Role(this.wire, this.label);

  /// The value in the API ("member", ...).
  final String wire;

  /// Name shown to users.
  final String label;

  /// Unknown values (e.g. from a newer server) are treated as the lowest role.
  static Role parse(String? s) =>
      Role.values.firstWhere((r) => r.wire == s, orElse: () => Role.member);

  /// Enum order is the rank: member < moderator < admin < owner.
  bool atLeast(Role other) => index >= other.index;
  bool above(Role other) => index > other.index;
}

/// Permission names as sent by the server in `user.permissions`.
abstract final class Permission {
  static const manageChannels = 'manage_channels';
  static const manageInvites = 'manage_invites';
  static const manageRoles = 'manage_roles';
  static const deleteMessages = 'delete_messages';
  static const kickMembers = 'kick_members';
  static const banMembers = 'ban_members';
}
