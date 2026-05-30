const Object _copyUnset = Object();

int? _readOptionalInt(dynamic value) {
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '');
}

class TeacherHeartRateThresholds {
  const TeacherHeartRateThresholds({
    required this.low,
    required this.high,
    required this.ageBandLabel,
    required this.normalRangeLabel,
  });

  final int low;
  final int high;
  final String ageBandLabel;
  final String normalRangeLabel;
}

TeacherHeartRateThresholds teacherHeartRateThresholdsForAge(int? ageYears) {
  if (ageYears == null || ageYears < 0) {
    return const TeacherHeartRateThresholds(
      low: 70,
      high: 120,
      ageBandLabel: '年龄未填写',
      normalRangeLabel: '请补充年龄后自动匹配临床提醒线',
    );
  }
  if (ageYears < 1) {
    return const TeacherHeartRateThresholds(
      low: 100,
      high: 160,
      ageBandLabel: '1 岁以内',
      normalRangeLabel: '正常参考 100-140 次/分钟',
    );
  }
  if (ageYears <= 5) {
    return const TeacherHeartRateThresholds(
      low: 80,
      high: 140,
      ageBandLabel: '1-5 岁',
      normalRangeLabel: '正常参考 80-120 次/分钟',
    );
  }
  if (ageYears <= 12) {
    return const TeacherHeartRateThresholds(
      low: 70,
      high: 130,
      ageBandLabel: '6-12 岁',
      normalRangeLabel: '正常参考 70-110 次/分钟',
    );
  }
  return const TeacherHeartRateThresholds(
    low: 60,
    high: 100,
    ageBandLabel: '12 岁以上',
    normalRangeLabel: '正常参考 60-100 次/分钟',
  );
}

class TeacherStudent {
  const TeacherStudent({
    required this.id,
    required this.name,
    this.nickname,
    this.age,
    this.gender,
    this.personality,
    this.interests,
    this.category,
    this.note,
    this.bandRemoteId,
    this.bandDisplayName,
    this.bandAuthHexKey,
    this.serverStudentId,
    this.thresholdBpm = 120,
    this.lowThresholdBpm = 70,
    this.enabled = true,
    required this.createdAt,
  });

  final String id;
  final String name;
  final String? nickname;
  final int? age;
  final String? gender;
  final String? personality;
  final String? interests;
  final String? category;
  final String? note;
  final String? bandRemoteId;
  final String? bandDisplayName;
  final String? bandAuthHexKey;
  final String? serverStudentId;
  final int thresholdBpm;
  final int lowThresholdBpm;
  final bool enabled;
  final DateTime createdAt;

  TeacherStudent copyWith({
    String? name,
    Object? nickname = _copyUnset,
    Object? age = _copyUnset,
    Object? gender = _copyUnset,
    Object? personality = _copyUnset,
    Object? interests = _copyUnset,
    Object? category = _copyUnset,
    Object? note = _copyUnset,
    Object? bandRemoteId = _copyUnset,
    Object? bandDisplayName = _copyUnset,
    Object? bandAuthHexKey = _copyUnset,
    Object? serverStudentId = _copyUnset,
    int? thresholdBpm,
    int? lowThresholdBpm,
    bool? enabled,
  }) {
    return TeacherStudent(
      id: id,
      name: name ?? this.name,
      nickname: identical(nickname, _copyUnset) ? this.nickname : nickname as String?,
      age: identical(age, _copyUnset) ? this.age : age as int?,
      gender: identical(gender, _copyUnset) ? this.gender : gender as String?,
      personality: identical(personality, _copyUnset) ? this.personality : personality as String?,
      interests: identical(interests, _copyUnset) ? this.interests : interests as String?,
      category: identical(category, _copyUnset) ? this.category : category as String?,
      note: identical(note, _copyUnset) ? this.note : note as String?,
      bandRemoteId: identical(bandRemoteId, _copyUnset) ? this.bandRemoteId : bandRemoteId as String?,
      bandDisplayName: identical(bandDisplayName, _copyUnset) ? this.bandDisplayName : bandDisplayName as String?,
      bandAuthHexKey: identical(bandAuthHexKey, _copyUnset) ? this.bandAuthHexKey : bandAuthHexKey as String?,
      serverStudentId: identical(serverStudentId, _copyUnset) ? this.serverStudentId : serverStudentId as String?,
      thresholdBpm: thresholdBpm ?? this.thresholdBpm,
      lowThresholdBpm: lowThresholdBpm ?? this.lowThresholdBpm,
      enabled: enabled ?? this.enabled,
      createdAt: createdAt,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'nickname': nickname,
        'age': age,
        'gender': gender,
        'personality': personality,
        'interests': interests,
        'category': category,
        'note': note,
        'bandRemoteId': bandRemoteId,
        'bandDisplayName': bandDisplayName,
        'bandAuthHexKey': bandAuthHexKey,
        'serverStudentId': serverStudentId,
        'thresholdBpm': thresholdBpm,
        'lowThresholdBpm': lowThresholdBpm,
        'enabled': enabled,
        'createdAt': createdAt.toIso8601String(),
      };

  factory TeacherStudent.fromJson(Map<String, dynamic> json) {
    final age = _readOptionalInt(json['age']);
    final derivedThresholds = teacherHeartRateThresholdsForAge(age);
    return TeacherStudent(
      id: json['id']?.toString() ?? '',
      name: json['name']?.toString() ?? '学生',
      nickname: json['nickname']?.toString(),
      age: age,
      gender: json['gender']?.toString(),
      personality: json['personality']?.toString(),
      interests: json['interests']?.toString(),
      category: json['category']?.toString(),
      note: json['note']?.toString(),
      bandRemoteId: json['bandRemoteId']?.toString(),
      bandDisplayName: json['bandDisplayName']?.toString(),
      bandAuthHexKey: json['bandAuthHexKey']?.toString(),
      serverStudentId: json['serverStudentId']?.toString(),
      thresholdBpm: (_readOptionalInt(json['thresholdBpm']) ?? derivedThresholds.high)
          .clamp(80, 180)
          .toInt(),
      lowThresholdBpm: (_readOptionalInt(json['lowThresholdBpm']) ?? derivedThresholds.low)
          .clamp(40, 120)
          .toInt(),
      enabled: json['enabled'] as bool? ?? true,
      createdAt: DateTime.tryParse(json['createdAt']?.toString() ?? '') ??
          DateTime.now(),
    );
  }
}

class TeacherBandBinding {
  const TeacherBandBinding({
    required this.remoteId,
    this.displayName,
    this.authHexKey,
    this.vibrationVerified = false,
    required this.boundAt,
  });

  final String remoteId;
  final String? displayName;
  final String? authHexKey;
  final bool vibrationVerified;
  final DateTime boundAt;

  TeacherBandBinding copyWith({
    String? remoteId,
    Object? displayName = _copyUnset,
    Object? authHexKey = _copyUnset,
    bool? vibrationVerified,
  }) {
    return TeacherBandBinding(
      remoteId: remoteId ?? this.remoteId,
      displayName: identical(displayName, _copyUnset) ? this.displayName : displayName as String?,
      authHexKey: identical(authHexKey, _copyUnset) ? this.authHexKey : authHexKey as String?,
      vibrationVerified: vibrationVerified ?? this.vibrationVerified,
      boundAt: boundAt,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'remoteId': remoteId,
        'displayName': displayName,
      'authHexKey': authHexKey,
        'vibrationVerified': vibrationVerified,
        'boundAt': boundAt.toIso8601String(),
      };

  factory TeacherBandBinding.fromJson(Map<String, dynamic> json) {
    return TeacherBandBinding(
      remoteId: json['remoteId']?.toString() ?? '',
      displayName: json['displayName']?.toString(),
      authHexKey: json['authHexKey']?.toString(),
      vibrationVerified: json['vibrationVerified'] as bool? ?? false,
      boundAt: DateTime.tryParse(json['boundAt']?.toString() ?? '') ??
          DateTime.now(),
    );
  }
}

class TeacherAlertEvent {
  const TeacherAlertEvent({
    required this.id,
    required this.studentId,
    required this.studentNameSnapshot,
    required this.eventType,
    this.bpm,
    this.thresholdBpm,
    required this.startedAt,
    this.note,
    this.uploaded = false,
  });

  final String id;
  final String studentId;
  final String studentNameSnapshot;
  final String eventType;
  final int? bpm;
  final int? thresholdBpm;
  final DateTime startedAt;
  final String? note;
  final bool uploaded;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'studentId': studentId,
        'studentNameSnapshot': studentNameSnapshot,
        'eventType': eventType,
        'bpm': bpm,
        'thresholdBpm': thresholdBpm,
        'startedAt': startedAt.toIso8601String(),
        'note': note,
        'uploaded': uploaded,
      };

  factory TeacherAlertEvent.fromJson(Map<String, dynamic> json) {
    return TeacherAlertEvent(
      id: json['id']?.toString() ?? '',
      studentId: json['studentId']?.toString() ?? '',
      studentNameSnapshot: json['studentNameSnapshot']?.toString() ?? '学生',
      eventType: json['eventType']?.toString() ?? 'highHeartRate',
      bpm: (json['bpm'] as num?)?.toInt(),
      thresholdBpm: (json['thresholdBpm'] as num?)?.toInt(),
      startedAt: DateTime.tryParse(json['startedAt']?.toString() ?? '') ??
          DateTime.now(),
      note: json['note']?.toString(),
      uploaded: json['uploaded'] as bool? ?? false,
    );
  }
}
