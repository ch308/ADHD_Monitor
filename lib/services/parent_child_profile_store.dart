import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/parent_child_profile.dart';

class ParentChildProfileStore {
  static const String _kProfilePrefix = 'parent_child_profile_';

  static Future<ParentChildProfile?> getProfile(int childId) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('$_kProfilePrefix$childId');
    if (raw == null || raw.isEmpty) return null;
    final decoded = json.decode(raw);
    if (decoded is! Map) return null;
    return ParentChildProfile.fromJson(Map<String, dynamic>.from(decoded));
  }

  static Future<void> saveProfile(ParentChildProfile profile) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      '$_kProfilePrefix${profile.childId}',
      json.encode(profile.toJson()),
    );
  }

  static Future<void> removeProfile(int childId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('$_kProfilePrefix$childId');
  }
}
