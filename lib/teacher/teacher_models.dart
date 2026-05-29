class TeacherStudent {
  const TeacherStudent({
    required this.id,
    required this.name,
    this.note,
    this.bandRemoteId,
    this.serverStudentId,
    this.thresholdBpm = 120,
    this.enabled = true,
    required this.createdAt,
  });

  final String id;
  final String name;
  final String? note;
  final String? bandRemoteId;
  final String? serverStudentId;
  final int thresholdBpm;
  final bool enabled;
  final DateTime createdAt;

  TeacherStudent copyWith({
    String? name,
    String? note,
    String? bandRemoteId,
    String? serverStudentId,
    int? thresholdBpm,
    bool? enabled,
  }) {
    return TeacherStudent(
      id: id,
      name: name ?? this.name,
      note: note ?? this.note,
      bandRemoteId: bandRemoteId ?? this.bandRemoteId,
      serverStudentId: serverStudentId ?? this.serverStudentId,
      thresholdBpm: thresholdBpm ?? this.thresholdBpm,
      enabled: enabled ?? this.enabled,
      createdAt: createdAt,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'note': note,
        'bandRemoteId': bandRemoteId,
        'serverStudentId': serverStudentId,
        'thresholdBpm': thresholdBpm,
        'enabled': enabled,
        'createdAt': createdAt.toIso8601String(),
      };

  factory TeacherStudent.fromJson(Map<String, dynamic> json) {
    return TeacherStudent(
      id: json['id']?.toString() ?? '',
      name: json['name']?.toString() ?? '学生',
      note: json['note']?.toString(),
      bandRemoteId: json['bandRemoteId']?.toString(),
      serverStudentId: json['serverStudentId']?.toString(),
      thresholdBpm: ((json['thresholdBpm'] as num?)?.toInt() ?? 120)
          .clamp(80, 180)
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
    this.vibrationVerified = false,
    required this.boundAt,
  });

  final String remoteId;
  final String? displayName;
  final bool vibrationVerified;
  final DateTime boundAt;

  TeacherBandBinding copyWith({
    String? remoteId,
    String? displayName,
    bool? vibrationVerified,
  }) {
    return TeacherBandBinding(
      remoteId: remoteId ?? this.remoteId,
      displayName: displayName ?? this.displayName,
      vibrationVerified: vibrationVerified ?? this.vibrationVerified,
      boundAt: boundAt,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'remoteId': remoteId,
        'displayName': displayName,
        'vibrationVerified': vibrationVerified,
        'boundAt': boundAt.toIso8601String(),
      };

  factory TeacherBandBinding.fromJson(Map<String, dynamic> json) {
    return TeacherBandBinding(
      remoteId: json['remoteId']?.toString() ?? '',
      displayName: json['displayName']?.toString(),
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
