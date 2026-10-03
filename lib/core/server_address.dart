/// Turns what the user typed ("chat.example.com", "192.168.1.5:8080",
/// "http://127.0.0.1:8080") into a clean base URL like `https://chat.example.com`.
///
/// Without a scheme we assume `https://`: secure by default. Plain `http://`
/// must be typed on purpose (local development).
///
/// Throws a [FormatException] with a user-friendly message if the input is invalid.
Uri parseServerAddress(String input) {
  var text = input.trim();
  if (text.isEmpty) {
    throw const FormatException('Enter a server address.');
  }
  if (!text.contains('://')) {
    text = 'https://$text';
  }

  final uri = Uri.tryParse(text);
  if (uri == null || uri.host.isEmpty) {
    throw const FormatException('That does not look like a valid address.');
  }
  if (uri.scheme != 'http' && uri.scheme != 'https') {
    throw const FormatException(
      'Only http:// and https:// addresses are supported.',
    );
  }
  // "user:password@host" would put credentials in the URL, where they can leak into logs.
  if (uri.userInfo.isNotEmpty) {
    throw const FormatException(
      'Do not put a username or password in the address.',
    );
  }
  if ((uri.path.isNotEmpty && uri.path != '/') ||
      uri.hasQuery ||
      uri.hasFragment) {
    throw const FormatException(
      'Enter only the server address, without a path.',
    );
  }

  // Rebuild from the parts we allow, dropping anything else.
  return Uri(
    scheme: uri.scheme,
    host: uri.host,
    port: uri.hasPort ? uri.port : null,
  );
}
