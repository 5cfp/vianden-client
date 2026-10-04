import 'dart:io';

import 'package:crypto/crypto.dart';

/// Trust on first use (TOFU) for servers with a self-signed certificate.
///
/// Normal servers (e.g. Let's Encrypt) have certificates the operating system already
/// trusts, and this class is never involved. A self-signed certificate cannot be
/// verified automatically, so the app shows its fingerprint once, the user compares it
/// with the one the server owner shared, and the app remembers ("pins") it. If the
/// certificate ever changes, the connection is refused and the user is warned: that is
/// exactly what a man-in-the-middle attack would look like.
class CertificateTrust {
  /// "host:port" -> trusted SHA-256 fingerprint.
  final Map<String, String> _pins = {};

  /// "host:port" -> fingerprint of the last certificate we refused (shown to the user).
  final Map<String, String> _rejected = {};

  void load(Map<String, String> pins) => _pins
    ..clear()
    ..addAll(pins);

  Map<String, String> get pins => Map.unmodifiable(_pins);

  /// Called by dart:io for every certificate the system does NOT trust.
  /// Returns true only for the exact certificate the user pinned for this server.
  bool check(List<int> certificateDer, String host, int port) {
    final key = _key(host, port);
    final fingerprint = fingerprintOf(certificateDer);
    if (_pins[key] == fingerprint) return true;
    _rejected[key] = fingerprint;
    return false;
  }

  /// The fingerprint of the certificate most recently refused for [server], if any.
  String? rejectedFor(Uri server) => _rejected[_key(server.host, server.port)];

  /// The fingerprint pinned for [server], if the user trusted one before.
  String? pinnedFor(Uri server) => _pins[_key(server.host, server.port)];

  /// Pins [fingerprint] for [server]. Returns the new pin list (to be saved).
  Map<String, String> trust(Uri server, String fingerprint) {
    final key = _key(server.host, server.port);
    _pins[key] = fingerprint;
    _rejected.remove(key);
    return pins;
  }

  /// Creates an HttpClient (for REST and WebSocket) that consults this trust store.
  HttpClient httpClient() =>
      HttpClient()
        ..badCertificateCallback = (cert, host, port) =>
            check(cert.der, host, port);

  static String _key(String host, int port) => '${host.toLowerCase()}:$port';
}

/// SHA-256 of a certificate as "AB:CD:..." (the same format the server prints).
String fingerprintOf(List<int> der) => sha256
    .convert(der)
    .bytes
    .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
    .join(':');

/// The server's certificate is not trusted (self-signed and not pinned, or CHANGED).
class UntrustedCertificateException implements Exception {
  const UntrustedCertificateException({
    required this.server,
    required this.fingerprint,
    this.previousFingerprint,
  });

  final Uri server;

  /// Fingerprint of the certificate the server presented now.
  final String fingerprint;

  /// Set if a DIFFERENT certificate was trusted before: possible attack.
  final String? previousFingerprint;

  bool get changed => previousFingerprint != null;

  @override
  String toString() => changed
      ? 'The server certificate changed. This can be an attack.'
      : 'The server uses a self-signed certificate.';
}
