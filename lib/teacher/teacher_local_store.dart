import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'teacher_models.dart';

class TeacherLocalStore {
  static const _kStudents = 'teacher_students_json';
  static const _kTeacherBand = 'teacher_band_binding_json';
  static const _kAlertEvents = 'teacher_alert_events_json';
  static const _kNotifyTeacherBandOnAlert = 'teacher_notify_teacher_band_on_alert';
  static const _kTeacherBandAuthPrefix = 'teacher_band_auth_';
  static const _kStudentBandAuthPrefix = 'teacher_student_band_auth_';
  static const FlutterSecureStorage _secureStorage = FlutterSecureStorage();

  static Future<List<TeacherStudent>> getStudents() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kStudents);
    if (raw == null || raw.isEmpty) return const <TeacherStudent>[];

    final decoded = json.decode(raw);
    if (decoded is! List) return const <TeacherStudent>[];
    final students = decoded
        .whereType<Map>()
        .map((item) => TeacherStudent.fromJson(Map<String, dynamic>.from(item)))
        .where((student) => student.id.isNotEmpty)
        .toList();
    var migratedAny = false;
    final hydrated = await Future.wait(
      students.map((student) async {
        final migrated = await _migrateStudentAuthKey(student);
        if (!identical(migrated, student)) {
          migratedAny = true;
        }
        final secureKey = await _secureStorage.read(
          key: '$_kStudentBandAuthPrefix${student.id}',
        );
        return migrated.copyWith(
          bandAuthHexKey: secureKey?.isNotEmpty == true
              ? secureKey
              : migrated.bandAuthHexKey,
        );
      }),
    );
    if (migratedAny) {
      await prefs.setString(
        _kStudents,
        json.encode(
          hydrated
              .map((student) => student.copyWith(bandAuthHexKey: null).toJson())
              .toList(),
        ),
      );
    }
    return hydrated;
  }

  static Future<void> saveStudents(List<TeacherStudent> students) async {
    final prefs = await SharedPreferences.getInstance();
    final existing = await getStudents();
    final nextIds = students.map((student) => student.id).toSet();
    for (final removed in existing.where((student) => !nextIds.contains(student.id))) {
      await _secureStorage.delete(key: '$_kStudentBandAuthPrefix${removed.id}');
    }

    for (final student in students) {
      final secureKey = '$_kStudentBandAuthPrefix${student.id}';
      final authKey = student.bandAuthHexKey?.trim();
      if (authKey == null || authKey.isEmpty) {
        await _secureStorage.delete(key: secureKey);
      } else {
        await _secureStorage.write(key: secureKey, value: authKey);
      }
    }

    await prefs.setString(
      _kStudents,
      json.encode(
        students
            .map(
              (student) => student.copyWith(bandAuthHexKey: null).toJson(),
            )
            .toList(),
      ),
    );
  }

  static Future<TeacherBandBinding?> getTeacherBand() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kTeacherBand);
    if (raw == null || raw.isEmpty) return null;

    final decoded = json.decode(raw);
    if (decoded is! Map) return null;
    final binding = await _migrateTeacherBandAuthKey(
      TeacherBandBinding.fromJson(
      Map<String, dynamic>.from(decoded),
      ),
    );
    if ((binding.authHexKey ?? '').isEmpty) {
      await prefs.setString(
        _kTeacherBand,
        json.encode(binding.copyWith(authHexKey: null).toJson()),
      );
    }
    final secureKey = await _secureStorage.read(key: _kTeacherBandAuthPrefix);
    final hydrated = binding.copyWith(
      authHexKey: secureKey?.isNotEmpty == true ? secureKey : binding.authHexKey,
    );
    return hydrated.remoteId.isEmpty ? null : hydrated;
  }

  static Future<void> saveTeacherBand(TeacherBandBinding? binding) async {
    final prefs = await SharedPreferences.getInstance();
    if (binding == null) {
      await prefs.remove(_kTeacherBand);
      await _secureStorage.delete(key: _kTeacherBandAuthPrefix);
      return;
    }
    final authKey = binding.authHexKey?.trim();
    if (authKey == null || authKey.isEmpty) {
      await _secureStorage.delete(key: _kTeacherBandAuthPrefix);
    } else {
      await _secureStorage.write(key: _kTeacherBandAuthPrefix, value: authKey);
    }
    await prefs.setString(
      _kTeacherBand,
      json.encode(binding.copyWith(authHexKey: null).toJson()),
    );
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

  static Future<bool> getNotifyTeacherBandOnAlert() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_kNotifyTeacherBandOnAlert) ?? true;
  }

  static Future<void> saveNotifyTeacherBandOnAlert(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kNotifyTeacherBandOnAlert, value);
  }

  static Future<TeacherStudent> _migrateStudentAuthKey(TeacherStudent student) async {
    final authKey = student.bandAuthHexKey?.trim();
    if (authKey == null || authKey.isEmpty) return student;
    await _secureStorage.write(
      key: '$_kStudentBandAuthPrefix${student.id}',
      value: authKey,
    );
    return student.copyWith(bandAuthHexKey: null);
  }

  static Future<TeacherBandBinding> _migrateTeacherBandAuthKey(
    TeacherBandBinding binding,
  ) async {
    final authKey = binding.authHexKey?.trim();
    if (authKey == null || authKey.isEmpty) return binding;
    await _secureStorage.write(key: _kTeacherBandAuthPrefix, value: authKey);
    return binding.copyWith(authHexKey: null);
  }
}
