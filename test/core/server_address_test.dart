import 'package:flutter_test/flutter_test.dart';
import 'package:vianden_client/core/server_address.dart';

void main() {
  group('parseServerAddress', () {
    final valid = {
      'chat.example.com': 'https://chat.example.com',
      '  chat.example.com  ': 'https://chat.example.com',
      'chat.example.com/': 'https://chat.example.com',
      '192.168.1.10:8080': 'https://192.168.1.10:8080',
      'http://127.0.0.1:8080': 'http://127.0.0.1:8080',
      'https://chat.example.com:8443': 'https://chat.example.com:8443',
      '[::1]:8080': 'https://[::1]:8080',
    };
    valid.forEach((input, expected) {
      test('accepts "$input"', () {
        expect(parseServerAddress(input).toString(), expected);
      });
    });

    final invalid = [
      '',
      '   ',
      'ftp://chat.example.com',
      'https://user:secret@chat.example.com',
      'chat.example.com/some/path',
      'chat.example.com?x=1',
    ];
    for (final input in invalid) {
      test('rejects "$input"', () {
        expect(() => parseServerAddress(input), throwsFormatException);
      });
    }
  });
}
