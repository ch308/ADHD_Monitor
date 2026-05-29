import 'package:shared_preferences/shared_preferences.dart';

enum AppMode { parent, teacher }

class AppModeStore {
  static const _kAppMode = 'app_mode';

  static Future<AppMode?> getMode() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kAppMode);
    return switch (raw) {
      'parent' => AppMode.parent,
      'teacher' => AppMode.teacher,
      _ => null,
    };
  }

  static Future<void> saveMode(AppMode mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kAppMode, mode.name);
  }

  static Future<void> clearMode() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kAppMode);
  }
}
