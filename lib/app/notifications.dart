import 'dart:io';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// System notifications: new versions, finished installs, installs that need a tap.
class Notifier {
  static final _plugin = FlutterLocalNotificationsPlugin();
  static bool _ready = false;
  static int _id = 1000;

  static Future<void> init() async {
    if (_ready) return;
    try {
      await _plugin.initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
          iOS: DarwinInitializationSettings(),
          macOS: DarwinInitializationSettings(),
          linux: LinuxInitializationSettings(defaultActionName: 'Open GetterX'),
          windows: WindowsInitializationSettings(
            appName: 'GetterX',
            appUserModelId: 'io.github.gmwester.getterx',
            guid: '6e4b8c2a-6c7b-4c58-9d3e-2b7f0a9e5c11',
          ),
        ),
      );
      _ready = true;
    } catch (_) {
      // Notifications are a convenience; never fail a check because of them.
    }
  }

  /// Android 13+ / iOS / macOS ask once.
  static Future<void> requestPermission() async {
    await init();
    try {
      if (Platform.isAndroid) {
        await _plugin
            .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
            ?.requestNotificationsPermission();
      } else if (Platform.isIOS) {
        await _plugin.resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>()?.requestPermissions(
          alert: true,
          badge: true,
        );
      } else if (Platform.isMacOS) {
        await _plugin.resolvePlatformSpecificImplementation<MacOSFlutterLocalNotificationsPlugin>()?.requestPermissions(
          alert: true,
          badge: true,
        );
      }
    } catch (_) {}
  }

  static Future<void> show(String title, String body, {String channel = 'updates', String? payload}) async {
    await init();
    if (!_ready) return;
    try {
      await _plugin.show(
        id: _id++,
        title: title,
        body: body,
        payload: payload,
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(channel, switch (channel) {
            'attention' => 'Needs your attention',
            'installed' => 'Installed updates',
            _ => 'New versions',
          }, importance: channel == 'attention' ? Importance.high : Importance.defaultImportance),
        ),
      );
    } catch (_) {}
  }
}
