import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/parent_child_profile.dart';
import 'cloud_service.dart';

class ParentChildProfileStore {
  static const String _kProfilePrefix = 'parent_child_profile_';

  static Future<ParentChildProfile?> getProfile(
    int childId, {
    CloudService? cloudService,
  }) async {
    final cloudProfile = await cloudService?.fetchChildProfile(childId);
    if (cloudProfile != null) {
      await saveProfile(cloudProfile);
      return cloudProfile;
    }
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('$_kProfilePrefix$childId');
    if (raw == null || raw.isEmpty) return null;
    final decoded = json.decode(raw);
    if (decoded is! Map) return null;
    return ParentChildProfile.fromJson(Map<String, dynamic>.from(decoded));
  }

  static Future<ParentChildProfile> saveProfile(
    ParentChildProfile profile, {
    CloudService? cloudService,
  }) async {
    final synced = await cloudService?.saveChildProfile(profile);
    final next = synced ?? profile;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      '$_kProfilePrefix${next.childId}',
      json.encode(next.toJson()),
    );
    return next;
  }

  static Future<void> removeProfile(int childId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('$_kProfilePrefix$childId');
  }
}
