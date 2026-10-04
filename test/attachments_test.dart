import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:vianden_client/core/models.dart';
import 'package:vianden_client/features/chat/chat_providers.dart';

import 'helpers.dart';

/// Replaces the system file dialogs: "picks" [toOpen] and "saves" to [savePath].
class FakeFileSelector extends FileSelectorPlatform
    with MockPlatformInterfaceMixin {
  List<XFile> toOpen = [];
  String? savePath;

  @override
  Future<List<XFile>> openFiles({
    List<XTypeGroup>? acceptedTypeGroups,
    String? initialDirectory,
    String? confirmButtonText,
  }) async => toOpen;

  @override
  Future<XFile?> openFile({
    List<XTypeGroup>? acceptedTypeGroups,
    String? initialDirectory,
    String? confirmButtonText,
  }) async => toOpen.firstOrNull;

  @override
  Future<FileSaveLocation?> getSaveLocation({
    List<XTypeGroup>? acceptedTypeGroups,
    SaveDialogOptions options = const SaveDialogOptions(),
  }) async => savePath == null ? null : FileSaveLocation(savePath!);
}

/// M6 step 3: uploads.
void main() {
  late FakeServer server;
  late MemorySessionStore store;
  late FakeFileSelector picker;

  setUp(() {
    server = FakeServer();
    store = MemorySessionStore();
    picker = FakeFileSelector();
    FileSelectorPlatform.instance = picker;
  });

  /// Waits for real async work (file reads, image decoding) that pump alone does not run.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pumpAndSettle();
    }
  }

  test('the test PNG is a real 2x1 image', () async {
    final upload = FakeUpload(1, 'dot.png', tinyPng, server.user('friend'));
    expect(upload.toJson()['width'], 2);
    expect(upload.toJson()['height'], 1);
  });

  test('the attachment cache drops the oldest files when full', () {
    final cache = AttachmentCache();
    final big = Uint8List(AttachmentCache.maxBytes ~/ 2 + 1);
    cache.put(1, big);
    cache.put(2, big); // together over the limit: file 1 goes
    expect(cache.get(1), isNull);
    expect(cache.get(2), same(big));
  });

  testWidgets('send an image and a file without text', (tester) async {
    picker.toOpen = [
      XFile.fromData(tinyPng, path: 'dot.png'),
      XFile.fromData(Uint8List.fromList('hello'.codeUnits), path: 'notes.txt'),
    ];
    await pumpLoggedIn(tester, server, store, 'friend');

    await tapKey(tester, 'attach');
    await settle(tester);
    expect(find.byKey(const Key('upload-dot.png')), findsOneWidget);
    expect(find.byKey(const Key('upload-notes.txt')), findsOneWidget);
    expect(server.uploads, hasLength(2));

    await tapKey(tester, 'send');
    await settle(tester);

    final sent = server.messages.single;
    expect(sent.content, '');
    expect(sent.attachments.map((a) => a.name), ['dot.png', 'notes.txt']);
    expect(
      find.byKey(const Key('upload-dot.png')),
      findsNothing,
    ); // chips cleared
    // The image is shown (decoded from the bytes), the text file as a card.
    expect(
      find.descendant(
        of: find.byKey(const Key('attachment-1')),
        matching: find.byType(Image),
      ),
      findsOneWidget,
    );
    expect(find.byKey(const Key('download-2')), findsOneWidget);
    expect(find.text('5 bytes'), findsOneWidget);
    expect(
      find.text('Sent a file'),
      findsNothing,
    ); // the open room shows no preview text
  });

  testWidgets('a received file can be saved', (tester) async {
    final dir = Directory.systemTemp.createTempSync('vianden_test');
    addTearDown(() => dir.deleteSync(recursive: true));
    final u = FakeUpload(7, 'report.pdf', [1, 2, 3], server.user('osama'));
    server.uploads[7] = u;
    server.post(1, 'osama', 'here').attachments = [u];
    picker.savePath = '${dir.path}${Platform.pathSeparator}report.pdf';
    await pumpLoggedIn(tester, server, store, 'friend');

    expect(find.text('report.pdf'), findsOneWidget);
    await tester.tap(find.byKey(const Key('download-7')));
    await settle(tester);
    expect(File(picker.savePath!).readAsBytesSync(), [1, 2, 3]);
  });

  testWidgets('files over 25 MB are refused before uploading', (tester) async {
    picker.toOpen = [
      XFile.fromData(Uint8List(1), path: 'huge.iso', length: 26 * 1024 * 1024),
    ];
    await pumpLoggedIn(tester, server, store, 'friend');
    await tapKey(tester, 'attach');
    await settle(tester);
    expect(find.textContaining('larger than 25 MB'), findsOneWidget);
    expect(server.uploads, isEmpty);
  });

  testWidgets('the room list says "Sent a file" for files without text', (
    tester,
  ) async {
    server.channels.add(FakeChannel(2, 'Games'));
    final u = FakeUpload(3, 'a.zip', [1], server.user('osama'));
    server.uploads[3] = u;
    server.post(2, 'osama', '').attachments = [u];
    await pumpLoggedIn(tester, server, store, 'friend');
    expect(find.text('Osama: Sent a file'), findsOneWidget);
  });

  test('attachment sizes read nicely', () {
    Attachment a(int size) =>
        Attachment(id: 1, filename: 'x', contentType: 'x', size: size);
    expect(a(12).sizeLabel, '12 bytes');
    expect(a(2048).sizeLabel, '2 KB');
    expect(a(5 * 1024 * 1024 + 300000).sizeLabel, '5.3 MB');
  });
}
