import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import 'chat_providers.dart';
import 'realtime_controller.dart';

/// The message input at the bottom of a room. Enter sends; Shift+Enter starts a new line.
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

  static const maxLength = 4000; // same limit as the server

  @override
  void dispose() {
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final content = _text.text;
    if (content.trim().isEmpty || _sending) return;

    setState(() => _sending = true);
    try {
      await ref.read(messagesProvider(widget.channelId).notifier).send(content);
      _text.clear(); // only cleared when the server accepted it
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
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
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

    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 0, 32, 24),
      child: DecoratedBox(
        // Design C2: a single strong underline instead of a big rounded box.
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(color: theme.colorScheme.onSurface, width: 2),
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
                    if (text.trim().isNotEmpty) {
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
                    contentPadding: const EdgeInsets.symmetric(vertical: 14),
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
                child: const Text('Send'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
