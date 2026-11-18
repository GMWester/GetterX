import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import 'models.dart';
import 'sources/source.dart';

typedef ProgressCallback = void Function(int received, int? total);

class _DigestSink implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}

/// Strongest hash we can verify: (algorithm, expected hex).
(Hash, String)? _pickHash(Map<String, String> h) {
  for (final (name, algo) in [('sha512', sha512), ('sha256', sha256), ('sha1', sha1), ('md5', md5)]) {
    final v = h[name];
    if (v != null && v.isNotEmpty) return (algo, v);
  }
  return null;
}

Future<bool> fileMatches(File f, RemoteFile rf) async {
  if (!f.existsSync()) return false;
  final hp = _pickHash(rf.hashes);
  if (hp != null) {
    final d = await hp.$1.bind(f.openRead()).first;
    return d.toString() == hp.$2;
  }
  // GitHub source archives are generated on the fly: no hash/size to compare.
  if (rf.size == null) return !rf.isSourceArchive && f.lengthSync() > 0;
  return f.lengthSync() == rf.size;
}

class Downloader {
  final http.Client client;
  Downloader(this.client);

  /// Follows redirects manually so credentials are only sent to the host
  /// they belong to (GitHub/itch.io redirect to signed CDN URLs).
  Future<http.StreamedResponse> _send(Uri uri, Map<String, String> headers) async {
    var current = uri;
    final origin = uri.host;
    for (var hop = 0; hop < 10; hop++) {
      // HTTPS only: never download (or send credentials) over plain HTTP,
      // including after a redirect (no downgrade).
      if (current.scheme != 'https') {
        throw SourceException('Refusing non-HTTPS download from ${current.host}');
      }
      final req = http.Request('GET', current)
        ..followRedirects = false
        ..headers['User-Agent'] = userAgent;
      // Credentials only go to the exact host they were issued for.
      if (current.host == origin) req.headers.addAll(headers);
      final res = await client.send(req);
      if (res.isRedirect || (res.statusCode >= 300 && res.statusCode < 400 && res.headers['location'] != null)) {
        await res.stream.drain<void>();
        // Signed CDN URLs on other hosts never receive the origin's credentials.
        current = current.resolve(res.headers['location']!);
        continue;
      }
      return res;
    }
    throw SourceException('Too many redirects for $uri');
  }

  /// Downloads [rf] to [dest], verifying size/hash. Tries mirrors in order.
  Future<void> download(
    RemoteFile rf,
    File dest, {
    ProgressCallback? onProgress,
    bool Function()? isCancelled,
    Map<String, String> headers = const {},
  }) async {
    await dest.parent.create(recursive: true);
    Object? lastError;
    for (final url in rf.urls) {
      final part = File('${dest.path}.part');
      try {
        final res = await _send(Uri.parse(url), {...rf.headers, ...headers});
        if (res.statusCode >= 400) {
          await res.stream.drain<void>();
          throw SourceException('HTTP ${res.statusCode} downloading ${rf.name}');
        }
        final total = res.contentLength ?? rf.size;
        final hp = _pickHash(rf.hashes);
        final sink = _DigestSink();
        final hasher = hp?.$1.startChunkedConversion(sink);
        final out = part.openWrite();
        var received = 0;
        try {
          await for (final chunk in res.stream) {
            if (isCancelled?.call() == true) throw const DownloadCancelled();
            out.add(chunk);
            hasher?.add(chunk);
            received += chunk.length;
            onProgress?.call(received, total);
          }
          await out.flush();
        } finally {
          await out.close();
        }
        hasher?.close();
        if (rf.size != null && received != rf.size) {
          throw SourceException('Size mismatch for ${rf.name}: got $received, expected ${rf.size}');
        }
        if (hp != null && sink.value.toString() != hp.$2) {
          throw SourceException('Checksum mismatch for ${rf.name}');
        }
        if (dest.existsSync()) await dest.delete();
        await part.rename(dest.path);
        return;
      } catch (e) {
        if (e is DownloadCancelled) {
          try {
            if (part.existsSync()) await part.delete();
          } catch (_) {}
          rethrow;
        }
        lastError = e;
        try {
          if (part.existsSync()) await part.delete();
        } catch (_) {}
      }
    }
    throw lastError ?? SourceException('No download URL for ${rf.name}');
  }
}

class DownloadCancelled implements Exception {
  const DownloadCancelled();
  @override
  String toString() => 'Cancelled';
}
