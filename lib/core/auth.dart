/// Optional sign-in for sources (private GitHub repos, purchased itch.io
/// games, private Modrinth projects). Pure Dart.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

import 'sources/source.dart';

class DeviceCode {
  final String deviceCode;
  final String userCode;
  final String verificationUri;
  final int interval;
  final DateTime expiresAt;
  DeviceCode(this.deviceCode, this.userCode, this.verificationUri, this.interval, this.expiresAt);
}

class Auth {
  final http.Client client;
  Auth(this.client);

  Future<Map<String, dynamic>> _postForm(Uri uri, Map<String, String> body,
      {Map<String, String> headers = const {}}) async {
    final res = await client.post(uri,
        headers: {'User-Agent': userAgent, 'Accept': 'application/json', ...headers}, body: body);
    final text = utf8.decode(res.bodyBytes);
    try {
      return (jsonDecode(text) as Map).cast();
    } catch (_) {
      throw SourceException('HTTP ${res.statusCode} from ${uri.host}: $text');
    }
  }

  // ---------------- GitHub (OAuth device flow) ----------------

  /// Needs the client id of a GitHub OAuth app with "Device flow" enabled.
  Future<DeviceCode> githubStartDeviceFlow(String clientId) async {
    final j = await _postForm(Uri.parse('https://github.com/login/device/code'),
        {'client_id': clientId, 'scope': 'repo read:user'});
    if (j['device_code'] == null) {
      throw SourceException('GitHub: ${j['error_description'] ?? j['error'] ?? j}');
    }
    return DeviceCode(
      j['device_code'] as String,
      j['user_code'] as String,
      j['verification_uri'] as String? ?? 'https://github.com/login/device',
      j['interval'] as int? ?? 5,
      DateTime.now().add(Duration(seconds: j['expires_in'] as int? ?? 900)),
    );
  }

  /// Polls until the user approved the code. Returns the access token.
  Future<String> githubPollDeviceFlow(String clientId, DeviceCode code,
      {bool Function()? cancelled}) async {
    var interval = code.interval;
    while (DateTime.now().isBefore(code.expiresAt)) {
      await Future<void>.delayed(Duration(seconds: interval));
      if (cancelled?.call() == true) throw SourceException('Cancelled');
      final j = await _postForm(Uri.parse('https://github.com/login/oauth/access_token'), {
        'client_id': clientId,
        'device_code': code.deviceCode,
        'grant_type': 'urn:ietf:params:oauth:grant-type:device_code',
      });
      final token = j['access_token'];
      if (token is String && token.isNotEmpty) return token;
      switch (j['error']) {
        case 'authorization_pending':
          continue;
        case 'slow_down':
          interval = (j['interval'] as int?) ?? interval + 5;
          continue;
        default:
          throw SourceException('GitHub: ${j['error_description'] ?? j['error']}');
      }
    }
    throw SourceException('GitHub: the code expired, try again');
  }

  /// Returns the login name for a token (validates it).
  Future<String> githubUser(String token) async {
    final j = await getJson(client, Uri.parse('https://api.github.com/user'),
        headers: {'Authorization': 'Bearer $token'}) as Map;
    return j['login'] as String;
  }

  // ---------------- itch.io ----------------

  /// Logs in with username + password like the itch.io desktop app.
  /// Returns either an API key or a TOTP token that must be completed with
  /// [itchVerifyTotp]. Throws if a captcha is required (use an API key then).
  Future<({String? key, String? totpToken})> itchLogin(String username, String password) async {
    final j = await _postForm(Uri.parse('https://api.itch.io/login'), {
      'username': username,
      'password': password,
      'source': 'desktop',
      'force_recaptcha': 'false',
    });
    if (j['errors'] != null) throw SourceException('itch.io: ${(j['errors'] as List).join(', ')}');
    if (j['recaptcha_needed'] == true) {
      throw SourceException(
          'itch.io wants a captcha for this login. Create an API key at itch.io/user/settings/api-keys and paste it instead.');
    }
    if (j['totp_needed'] == true) return (key: null, totpToken: j['token'] as String);
    final key = (j['key'] as Map?)?['key'] as String?;
    if (key == null) throw SourceException('itch.io: unexpected response');
    return (key: key, totpToken: null);
  }

  Future<String> itchVerifyTotp(String totpToken, String code) async {
    final j = await _postForm(Uri.parse('https://api.itch.io/totp/verify'),
        {'token': totpToken, 'code': code.trim()});
    if (j['errors'] != null) throw SourceException('itch.io: ${(j['errors'] as List).join(', ')}');
    final key = (j['key'] as Map?)?['key'] as String?;
    if (key == null) throw SourceException('itch.io: unexpected response');
    return key;
  }

  Future<String> itchUser(String apiKey) async {
    final j = await getJson(client, Uri.parse('https://api.itch.io/profile?api_key=$apiKey'),
        headers: {'Authorization': 'Bearer $apiKey'}) as Map;
    if (j['errors'] != null) throw SourceException('itch.io: ${j['errors']}');
    final u = (j['user'] as Map?) ?? const {};
    return (u['username'] ?? u['display_name'] ?? 'itch.io user') as String;
  }

  // ---------------- Modrinth ----------------

  Future<String> modrinthUser(String token) async {
    final j = await getJson(client, Uri.parse('https://api.modrinth.com/v2/user'),
        headers: {'Authorization': token}) as Map;
    return j['username'] as String;
  }
}
