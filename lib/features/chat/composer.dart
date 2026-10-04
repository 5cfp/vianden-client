import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app_config/app_theme.dart';
import '../../core/api_client.dart';
import '../../core/models.dart';
import '../../core/permissions.dart';
import '../../core/session_controller.dart';
import '../../widgets/user_avatar.dart';
import 'chat_providers.dart';
import 'realtime_controller.dart';

/// The message input at the bottom of a room. Enter sends; Shift+Enter starts a new line.
/// It can also reply to a message or edit one of ours (see [ComposerMode]); Esc cancels that.
class Composer extends ConsumerStatefulWidget {
  const Composer({super.key, required this.channelId, required this.roomName});

  final int channelId;
  final String roomName;

  @override
  ConsumerState<Composer> createState() => _ComposerState();
}

class _ComposerState extends ConsumerState<Composer> {
  final _text = TextEditingController();
  final _focus = FocusNode();
  bool _sending = false;

  /// What was typed before an edit started; restored when the edit ends.
  String _draft = '';

  /// @ autocomplete: matching people (or "everyone") for the "@..." before the cursor.
  List<_Suggestion> _suggestions = const [];
  int _selected = 0;

  /// Files picked for the next message (uploading, or uploaded and waiting to be sent).
  final _uploads = <_Upload>[];

  bool get _uploading => _uploads.any((u) => u.attachment == null);

  @override
  void initState() {
    super.initState();
    // Also fires when only the cursor moves, so the list follows the cursor.
    _text.addListener(_updateSuggestions);
  }

  static const maxLength = 4000; // same limit as the server
  static const maxFileBytes = 25 * 1024 * 1024; // same limit as the server

  @override
  void dispose() {
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  ComposerModeController get _mode =>
      ref.read(composerModeProvider(widget.channelId).notifier);

  Future<void> _send() async {
    final content = _text.text;
    final mode = ref.read(composerModeProvider(widget.channelId));
    final files = mode is Editing
        ? const <int>[]
        : [for (final u in _uploads) u.attachment!.id];
    if ((content.trim().isEmpty && files.isEmpty) || _sending || _uploading) {
      return;
    }
    final messages = ref.read(messagesProvider(widget.channelId).notifier);

    setState(() => _sending = true);
    try {
      switch (mode) {
        case Writing():
          await messages.send(content, attachments: files);
          _text.clear(); // only cleared when the server accepted it
          setState(_uploads.clear);
        case ReplyingTo(:final message):
          await messages.send(content, replyTo: message.id, attachments: files);
          _text.clear();
          setState(_uploads.clear);
          _mode.cancel();
        case Editing(:final message):
          if (content != message.content) {
            await messages.edit(message.id, content);
          }
          _mode.cancel(); // restores the draft (see build)
      }
    } on ApiException catch (e) {
      _showError(e.message);
    } on NetworkException catch (e) {
      _showError(e.message);
    }
    if (!mounted) return;
    setState(() => _sending = false);
    _focus.requestFocus();
  }

  /// Lets the user pick files, and uploads each one right away.
  Future<void> _pickFiles() async {
    final picked = await openFiles();
    for (final file in picked) {
      if (await file.length() > maxFileBytes) {
        _showError('"${file.name}" is larger than 25 MB.');
        continue;
      }
      final upload = _Upload(file.name);
      setState(() => _uploads.add(upload));
      try {
        final bytes = await file.readAsBytes();
        final api = ref.read(sessionProvider.notifier).authorizedApi();
        final a = await api.uploadAttachment(file.name, bytes);
        if (mounted) setState(() => upload.attachment = a);
      } on Exception catch (e) {
        if (!mounted) return;
        setState(() => _uploads.remove(upload));
        _showError(switch (e) {
          ApiException(:final message) ||
          NetworkException(:final message) => message,
          _ => 'Could not read "${file.name}".',
        });
      }
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  /// "@" + letters right before the cursor (not inside an e-mail address).
  static final _typingMention = RegExp(
    r'(?<![\p{L}\p{N}_.@-])@([A-Za-z0-9_.-]*)$',
    unicode: true,
  );

  void _updateSuggestions() {
    final cursor = _text.selection.baseOffset;
    final match = cursor < 0
        ? null
        : _typingMention.firstMatch(_text.text.substring(0, cursor));
    var next = const <_Suggestion>[];
    if (match != null) {
      final query = match.group(1)!.toLowerCase();
      final session = ref.read(sessionProvider).value;
      final me = session is LoggedIn ? session.user : null;
      final members = ref.read(membersProvider).value ?? const <Member>[];
      next = [
        if (me != null &&
            me.can(Permission.mentionEveryone) &&
            'everyone'.startsWith(query))
          const _Suggestion('everyone', 'Everyone in this room'),
        for (final m in members)
          if (m.id != me?.id &&
              (m.username.startsWith(query) ||
                  m.displayName.toLowerCase().startsWith(query)))
            _Suggestion(m.username, m.displayName, m.avatar),
      ].take(6).toList();
    }
    if (next.length != _suggestions.length ||
        !next.indexed.every(
          (e) => e.$2.username == _suggestions[e.$1].username,
        )) {
      setState(() {
        _suggestions = next;
        _selected = 0;
      });
    }
  }

  /// Replaces the "@..." before the cursor with "@username ".
  void _pick(_Suggestion s) {
    final cursor = _text.selection.baseOffset;
    final before = _text.text.substring(0, cursor);
    final start = before.lastIndexOf('@');
    final inserted = '@${s.username} ';
    _text.value = TextEditingValue(
      text: _text.text.replaceRange(start, cursor, inserted),
      selection: TextSelection.collapsed(offset: start + inserted.length),
    );
    _focus.requestFocus();
  }

  /// Enter (without Shift) sends instead of adding a new line.
  /// Esc cancels replying or editing.
  /// While suggestions show: Up/Down choose, Tab/Enter insert, Esc closes them.
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (_suggestions.isNotEmpty && event is KeyDownEvent) {
      switch (event.logicalKey) {
        case LogicalKeyboardKey.arrowDown:
          setState(() => _selected = (_selected + 1) % _suggestions.length);
          return KeyEventResult.handled;
        case LogicalKeyboardKey.arrowUp:
          setState(
            () => _selected =
                (_selected - 1 + _suggestions.length) % _suggestions.length,
          );
          return KeyEventResult.handled;
        case LogicalKeyboardKey.tab || LogicalKeyboardKey.enter:
          _pick(_suggestions[_selected]);
          return KeyEventResult.handled;
        case LogicalKeyboardKey.escape:
          setState(() => _suggestions = const []);
          return KeyEventResult.handled;
      }
    }
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.escape &&
        ref.read(composerModeProvider(widget.channelId)) is! Writing) {
      _mode.cancel();
      return KeyEventResult.handled;
    }
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.enter &&
        !HardwareKeyboard.instance.isShiftPressed) {
      _send();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mode = ref.watch(composerModeProvider(widget.channelId));
    // The member list feeds @ autocomplete (loaded once while the room is open).
    ref.watch(membersProvider);

    // React to mode changes (from the message actions): fill in the text to edit,
    // give the draft back afterwards, and put the cursor in the box.
    ref.listen(composerModeProvider(widget.channelId), (before, now) {
      if (now is Editing) {
        if (before is! Editing) _draft = _text.text;
        _text.text = now.message.content;
      } else if (before is Editing) {
        _text.text = _draft;
      }
      _focus.requestFocus();
    });

    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 0, 32, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_suggestions.isNotEmpty)
            _SuggestionList(
              suggestions: _suggestions,
              selected: _selected,
              onPick: _pick,
            ),
          if (mode case ReplyingTo(:final message))
            _ModeBar(
              key: const Key('reply-bar'),
              text: 'Replying to ',
              name: message.author?.displayName ?? 'Deleted user',
              onCancel: _mode.cancel,
            ),
          if (mode is Editing)
            _ModeBar(
              key: const Key('edit-bar'),
              text: 'Editing your message',
              onCancel: _mode.cancel,
            ),
          if (_uploads.isNotEmpty && mode is! Editing)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final u in _uploads)
                    InputChip(
                      key: Key('upload-${u.name}'),
                      avatar: u.attachment == null
                          ? const SizedBox.square(
                              dimension: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Icon(
                              u.attachment!.isImage
                                  ? Icons.image_outlined
                                  : Icons.insert_drive_file_outlined,
                              size: 16,
                            ),
                      label: Text(u.name, overflow: TextOverflow.ellipsis),
                      onDeleted: () => setState(() => _uploads.remove(u)),
                    ),
                ],
              ),
            ),
          DecoratedBox(
            // Design C2: a single strong underline instead of a big rounded box.
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: theme.colorScheme.onSurface,
                  width: 2,
                ),
              ),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (mode is! Editing)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: IconButton(
                      key: const Key('attach'),
                      tooltip: 'Attach files (max 25 MB each)',
                      icon: const Icon(Icons.attach_file),
                      onPressed: _sending ? null : _pickFiles,
                    ),
                  ),
                Expanded(
                  child: Focus(
                    onKeyEvent: _onKey,
                    child: TextField(
                      key: const Key('composer'),
                      controller: _text,
                      focusNode: _focus,
                      autofocus: true,
                      minLines: 1,
                      maxLines: 6,
                      maxLength: maxLength,
                      // Count shown only near the limit, so it does not clutter the screen.
                      buildCounter:
                          (
                            _, {
                            required currentLength,
                            required isFocused,
                            maxLength,
                          }) => currentLength > 3500
                          ? Text('$currentLength / $maxLength')
                          : null,
                      keyboardType: TextInputType.multiline,
                      onChanged: (text) {
                        if (text.trim().isNotEmpty && mode is! Editing) {
                          ref
                              .read(realtimeProvider.notifier)
                              .sendTyping(widget.channelId);
                        }
                      },
                      decoration: InputDecoration(
                        hintText: 'Write to ${widget.roomName}',
                        filled: false,
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        contentPadding: const EdgeInsets.symmetric(
                          vertical: 14,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: FilledButton(
                    key: const Key('send'),
                    onPressed: _sending || _uploading ? null : _send,
                    child: Text(mode is Editing ? 'Save' : 'Send'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The small bar above the input: "Replying to Sara" or "Editing your message", with an X.
class _ModeBar extends StatelessWidget {
  const _ModeBar({
    super.key,
    required this.text,
    this.name,
    required this.onCancel,
  });

  final String text;
  final String? name;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.extension<ChatColors>()!.muted;
    return Row(
      children: [
        Expanded(
          child: Text.rich(
            TextSpan(
              text: text,
              children: [
                if (name != null)
                  TextSpan(
                    text: name,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                const TextSpan(text: '  ·  Esc to cancel'),
              ],
            ),
            style: theme.textTheme.bodySmall?.copyWith(color: muted),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        IconButton(
          key: const Key('cancel-mode'),
          tooltip: 'Cancel',
          iconSize: 16,
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.close),
          onPressed: onCancel,
        ),
      ],
    );
  }
}

/// One autocomplete entry: what gets inserted ([username]) and what is shown.
class _Suggestion {
  const _Suggestion(this.username, this.label, [this.avatar]);
  final String username;
  final String label;
  final String? avatar;
}

/// The list of people above the input while typing "@...".
class _SuggestionList extends StatelessWidget {
  const _SuggestionList({
    required this.suggestions,
    required this.selected,
    required this.onPick,
  });

  final List<_Suggestion> suggestions;
  final int selected;
  final ValueChanged<_Suggestion> onPick;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.extension<ChatColors>()!.muted;
    return Card(
      key: const Key('mention-suggestions'),
      margin: const EdgeInsets.only(bottom: 6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final (i, s) in suggestions.indexed)
            ListTile(
              key: Key('mention-${s.username}'),
              dense: true,
              selected: i == selected,
              leading: s.username == 'everyone'
                  ? const Icon(Icons.campaign_outlined, size: 22)
                  : UserAvatar(name: s.label, avatar: s.avatar, size: 22),
              title: Text(s.label),
              trailing: Text(
                '@${s.username}',
                style: theme.textTheme.bodySmall?.copyWith(color: muted),
              ),
              onTap: () => onPick(s),
            ),
        ],
      ),
    );
  }
}

/// A file picked in the composer: uploading ([attachment] is null) or uploaded.
class _Upload {
  _Upload(this.name);
  final String name;
  Attachment? attachment;
}
