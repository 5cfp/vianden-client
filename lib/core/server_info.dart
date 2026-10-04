import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'certificate_trust.dart';

/// The API protocol version this client understands (see the server's docs/API.md).
const supportedProtocolVersion = 1;

/// Response of `GET /api/v1/info`.
class ServerInfo {
  const ServerInfo({
    required this.name,
    required this.version,
    required this.protocolVersion,
  });

  /// Parses the JSON body. Throws [FormatException] if fields are missing or have the wrong type.
  factory ServerInfo.fromJson(Object? json) {
    if (json case {
      'name': String name,
      'version': String version,
      'protocol_version': int protocolVersion,
    }) {
      return ServerInfo(
        name: name,
        version: version,
        protocolVersion: protocolVersion,
      );
    }
    throw const FormatException('unexpected /info response');
  }

  final String name;
  final String version;
  final int protocolVersion;
}

/// A connection problem, with a message that can be shown to the user as-is.
class ConnectException implements Exception {
  const ConnectException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Calls `GET /api/v1/info` on [server] and checks that the protocol versions match.
///
/// Throws [ConnectException] on any failure.
///
/// With [trust], a refused self-signed certificate becomes an [UntrustedCertificateException]
/// (carrying its fingerprint), so the app can ask the user to verify it.
Future<ServerInfo> fetchServerInfo(
  Uri server, {
  required http.Client client,
  CertificateTrust? trust,
}) async {
  final url = server.replace(path: '/api/v1/info');

  final http.Response response;
  try {
    response = await client.get(url).timeout(const Duration(seconds: 5));
  } on TimeoutException {
    throw const ConnectException('The server did not answer in time.');
  } on HandshakeException {
    if (trust?.rejectedFor(server) case final fingerprint?) {
      throw UntrustedCertificateException(
        server: server,
        fingerprint: fingerprint,
        previousFingerprint: trust!.pinnedFor(server),
      );
    }
    throw const ConnectException(
      'Secure connection failed. If this is a local development server, try http:// instead.',
    );
  } on Exception {
    final hint = server.scheme == 'https'
        ? ' If this is a local development server, try http:// instead.'
        : '';
    throw ConnectException(
      'Could not reach the server. Check the address and your connection.$hint',
    );
  }

  if (response.statusCode != 200) {
    throw ConnectException(
      'This does not look like a compatible server (HTTP ${response.statusCode}).',
    );
  }

  final ServerInfo info;
  try {
    info = ServerInfo.fromJson(jsonDecode(response.body));
  } on FormatException {
    throw const ConnectException(
      'This does not look like a compatible server (unexpected response).',
    );
  }

  if (info.protocolVersion > supportedProtocolVersion) {
    throw const ConnectException(
      'This server needs a newer version of the app. Please update.',
    );
  }
  if (info.protocolVersion < supportedProtocolVersion) {
    throw const ConnectException(
      'This server runs an older version. Ask the server owner to update it.',
    );
  }
  return info;
}
