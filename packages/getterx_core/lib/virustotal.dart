/// Optional VirusTotal check before installing a downloaded file.
///
/// Only the file's SHA-256 is sent (a lookup, never an upload), with the
/// user's own API key, to www.virustotal.com.
library;

import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import 'credentials.dart';
import 'sources/source.dart';

enum ScanVerdict { clean, flagged, unknown, error }

class ScanResult {
  final ScanVerdict verdict;
  final int malicious;
  final int suspicious;
  final int engines;
  final String sha256;
  final String? message;
  const ScanResult(
    this.verdict,
    this.sha256, {
    this.malicious = 0,
    this.suspicious = 0,
    this.engines = 0,
    this.message,
  });

  String get summary => switch (verdict) {
    ScanVerdict.clean => 'VirusTotal: clean ($engines engines)',
    ScanVerdict.flagged =>
      'VirusTotal: flagged by $malicious engine${malicious == 1 ? '' : 's'}'
          '${suspicious > 0 ? ' (+$suspicious suspicious)' : ''}',
    ScanVerdict.unknown => 'VirusTotal: file not known yet',
    ScanVerdict.error => 'VirusTotal check failed${message == null ? '' : ': $message'}',
  };
  String get link => 'https://www.virustotal.com/gui/file/$sha256';
}

class VirusTotal {
  final http.Client client;
  final String apiKey;
  VirusTotal(this.client, this.apiKey);

  bool get enabled => apiKey.isNotEmpty;

  static Future<String> sha256Of(File f) async => (await sha256.bind(f.openRead()).first).toString();

  Future<ScanResult> check(File file) async {
    final hash = await sha256Of(file);
    final uri = Uri.parse('https://www.virustotal.com/api/v3/files/$hash');
    if (!enabled || !mayReceiveCredential('virustotal', uri)) {
      return ScanResult(ScanVerdict.error, hash, message: 'no API key');
    }
    try {
      final res = await client.get(uri, headers: {'x-apikey': apiKey, 'User-Agent': userAgent});
      if (res.statusCode == 404) return ScanResult(ScanVerdict.unknown, hash);
      if (res.statusCode >= 400) return ScanResult(ScanVerdict.error, hash, message: 'HTTP ${res.statusCode}');
      return parse(res.body, hash);
    } catch (e) {
      return ScanResult(ScanVerdict.error, hash, message: redact('$e'));
    }
  }

  static ScanResult parse(String body, String hash) {
    final m = RegExp(r'"last_analysis_stats"\s*:\s*\{([^}]*)\}').firstMatch(body)?[1] ?? '';
    int n(String k) => int.tryParse(RegExp('"$k"\\s*:\\s*(\\d+)').firstMatch(m)?[1] ?? '') ?? 0;
    final malicious = n('malicious'), suspicious = n('suspicious');
    final engines = malicious + suspicious + n('undetected') + n('harmless');
    return ScanResult(
      malicious > 0 ? ScanVerdict.flagged : ScanVerdict.clean,
      hash,
      malicious: malicious,
      suspicious: suspicious,
      engines: engines,
    );
  }
}
