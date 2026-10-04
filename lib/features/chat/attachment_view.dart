import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app_config/app_theme.dart';
import '../../core/models.dart';
import 'chat_providers.dart';

/// Asks where to save an attachment, then writes it there.
Future<void> saveAttachment(
  BuildContext context,
  WidgetRef ref,
  Attachment a,
) async {
  final messenger = ScaffoldMessenger.of(context);
  final location = await getSaveLocation(suggestedName: a.filename);
  if (location == null) return; // cancelled
  // The bytes provider frees itself when nobody listens, so listen while we wait for it.
  final keepAlive = ref.listenManual(attachmentBytesProvider(a.id), (_, _) {});
  try {
    final bytes = await ref.read(attachmentBytesProvider(a.id).future);
    await File(location.path).writeAsBytes(bytes);
    messenger.showSnackBar(SnackBar(content: Text('Saved ${a.filename}')));
  } on Exception {
    messenger.showSnackBar(
      SnackBar(content: Text('Could not save ${a.filename}.')),
    );
  } finally {
    keepAlive.close();
  }
}

/// An image in a message. Its size is known before it loads (from the server), so the
/// list does not jump when it appears. Click: full size.
class ImageAttachment extends ConsumerWidget {
  const ImageAttachment({
    super.key,
    required this.attachment,
    required this.maxWidth,
  });

  final Attachment attachment;
  final double maxWidth;

  static const maxHeight = 300.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final a = attachment;
    final colors = Theme.of(context).extension<ChatColors>()!;
    // Fit inside maxWidth x maxHeight, keeping the shape.
    final w = (a.width ?? 1).toDouble(), h = (a.height ?? 1).toDouble();
    final scale = [
      1.0,
      maxWidth / w,
      maxHeight / h,
    ].reduce((x, y) => x < y ? x : y);
    final size = Size(w * scale, h * scale);
    final bytes = ref.watch(attachmentBytesProvider(a.id));

    return GestureDetector(
      key: Key('attachment-${a.id}'),
      onTap: bytes.hasValue ? () => _showFull(context, ref) : null,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: SizedBox.fromSize(
            size: size,
            child: switch (bytes) {
              AsyncData(:final value) => Image.memory(
                value,
                fit: BoxFit.cover,
                // Show a broken-image icon instead of crashing on a bad file.
                errorBuilder: (_, _, _) =>
                    Icon(Icons.broken_image_outlined, color: colors.muted),
              ),
              AsyncError() => Icon(
                Icons.broken_image_outlined,
                color: colors.muted,
              ),
              _ => ColoredBox(
                color: colors.otherBubble,
                child: const Center(
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            },
          ),
        ),
      ),
    );
  }

  void _showFull(BuildContext context, WidgetRef ref) {
    final bytes = ref.read(attachmentBytesProvider(attachment.id)).value!;
    showDialog<void>(
      context: context,
      builder: (dialogContext) => Dialog(
        key: const Key('image-viewer'),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              // Zoom and pan with the mouse wheel / drag.
              child: InteractiveViewer(maxScale: 8, child: Image.memory(bytes)),
            ),
            Padding(
              padding: const EdgeInsets.all(8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      attachment.filename,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  TextButton.icon(
                    key: const Key('save-image'),
                    onPressed: () => saveAttachment(context, ref, attachment),
                    icon: const Icon(Icons.download),
                    label: const Text('Save'),
                  ),
                  TextButton(
                    onPressed: () => Navigator.of(dialogContext).pop(),
                    child: const Text('Close'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A file that is not an image: name, size, and a download button. It is never opened
/// by the app, only saved where the user chooses.
class FileAttachment extends ConsumerWidget {
  const FileAttachment({super.key, required this.attachment});

  final Attachment attachment;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final colors = theme.extension<ChatColors>()!;
    return Container(
      key: Key('attachment-${attachment.id}'),
      constraints: const BoxConstraints(maxWidth: 320),
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
      decoration: BoxDecoration(
        color: colors.otherBubble,
        border: Border.all(color: colors.otherBubbleBorder),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.insert_drive_file_outlined, color: colors.muted),
          const SizedBox(width: 10),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  attachment.filename,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                Text(
                  attachment.sizeLabel,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colors.muted,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            key: Key('download-${attachment.id}'),
            tooltip: 'Save',
            icon: const Icon(Icons.download),
            onPressed: () => saveAttachment(context, ref, attachment),
          ),
        ],
      ),
    );
  }
}
