import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app_config/app_theme.dart';
import '../../core/api_client.dart';
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

  static const maxLength = 4000; // same limit as the server

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
    if (content.trim().isEmpty || _sending) return;
    final messages = ref.read(messagesProvider(widget.channelId).notifier);
    final mode = ref.read(composerModeProvider(widget.channelId));

    setState(() => _sending = true);
    try {
      switch (mode) {
        case Writing():
          await messages.send(content);
          _text.clear(); // only cleared when the server accepted it
        case ReplyingTo(:final message):
          await messages.send(content, replyTo: message.id);
          _text.clear();
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

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  /// Enter (without Shift) sends instead of adding a new line.
  /// Esc cancels replying or editing.
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
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
                    onPressed: _sending ? null : _send,
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
