import 'package:flutter_test/flutter_test.dart';
import 'package:vianden_client/core/server_info.dart';

/// The rule: app and server must have the same MAJOR version.
void main() {
  test('reads the major number', () {
    expect(majorVersion('0.3.0-alpha.3'), 0);
    expect(majorVersion('12.0.1'), 12);
    expect(majorVersion('dev'), isNull);
    expect(majorVersion(''), isNull);
  });

  test('same major: fine, whatever the rest', () {
    expect(versionMismatch('0.3.0-alpha.3', '0.3.0-alpha.3'), isNull);
    expect(versionMismatch('0.3.0-alpha.3', '0.9.1'), isNull);
    expect(versionMismatch('1.0.0', '1.4.2-beta'), isNull);
  });

  test('different major: a message that says who must update', () {
    expect(
      versionMismatch('0.3.0', '1.0.0'),
      contains('Please update the app'),
    );
    expect(
      versionMismatch('2.0.0', '1.5.0'),
      contains('Ask the server owner to update the server'),
    );
    expect(versionMismatch('0.3.0', '1.0.0'), contains('Version mismatch'));
  });

  test('unknown versions (developer builds) are not blocked', () {
    expect(versionMismatch('0.3.0', 'dev'), isNull);
  });
}
