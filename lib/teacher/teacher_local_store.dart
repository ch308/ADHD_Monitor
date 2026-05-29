import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'teacher_models.dart';

class TeacherLocalStore {
  static const _kStudents = 'teacher_students_json';
  static const _kTeacherBand = 'teacher_band_binding_json';
  static const _kAlertEvents = 'teacher_alert_events_json';

  static Future<List<TeacherStudent>> getStudents() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kStudents);
    if (raw == null || raw.isEmpty) return const <TeacherStudent>[];

    final decoded = json.decode(raw);
    if (decoded is! List) return const <TeacherStudent>[];
    return decoded
        .whereType<Map>()
        .map((item) => TeacherStudent.fromJson(Map<String, dynamic>.from(item)))
        .where((student) => student.id.isNotEmpty)
        .toList();
  }

  static Future<void> saveStudents(List<TeacherStudent> students) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _kStudents,
      json.encode(students.map((student) => student.toJson()).toList()),
    );
  }

  static Future<TeacherBandBinding?> getTeacherBand() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kTeacherBand);
    if (raw == null || raw.isEmpty) return null;

    final decoded = json.decode(raw);
    if (decoded is! Map) return null;
    final binding = TeacherBandBinding.fromJson(
      Map<String, dynamic>.from(decoded),
    );
    return binding.remoteId.isEmpty ? null : binding;
  }

  static Future<void> saveTeacherBand(TeacherBandBinding? binding) async {
    final prefs = await SharedPreferences.getInstance();
    if (binding == null) {
      await prefs.remove(_kTeacherBand);
      return;
    }
    await prefs.setString(_kTeacherBand, json.encode(binding.toJson()));
  }

  static Future<List<TeacherAlertEvent>> getAlertEvents() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kAlertEvents);
    if (raw == null || raw.isEmpty) return const <TeacherAlertEvent>[];

    final decoded = json.decode(raw);
    if (decoded is! List) return const <TeacherAlertEvent>[];
    return decoded
        .whereType<Map>()
        .map((item) => TeacherAlertEvent.fromJson(Map<String, dynamic>.from(item)))
        .where((event) => event.id.isNotEmpty)
        .toList();
  }

  static Future<void> addAlertEvent(TeacherAlertEvent event) async {
    final events = await getAlertEvents();
    final next = <TeacherAlertEvent>[event, ...events].take(80).toList();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _kAlertEvents,
      json.encode(next.map((item) => item.toJson()).toList()),
    );
  }
}
