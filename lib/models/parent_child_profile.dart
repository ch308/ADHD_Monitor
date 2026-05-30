class ParentHeartRateThresholds {
  const ParentHeartRateThresholds({
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

ParentHeartRateThresholds parentHeartRateThresholdsForAge(int? ageYears) {
  if (ageYears == null || ageYears < 0) {
    return const ParentHeartRateThresholds(
      low: 70,
      high: 120,
      ageBandLabel: '年龄未填写',
      normalRangeLabel: '请补充年龄后自动匹配提醒线',
    );
  }
  if (ageYears < 1) {
    return const ParentHeartRateThresholds(
      low: 100,
      high: 160,
      ageBandLabel: '1 岁以内',
      normalRangeLabel: '正常参考 100-140 次/分钟',
    );
  }
  if (ageYears <= 5) {
    return const ParentHeartRateThresholds(
      low: 80,
      high: 140,
      ageBandLabel: '1-5 岁',
      normalRangeLabel: '正常参考 80-120 次/分钟',
    );
  }
  if (ageYears <= 12) {
    return const ParentHeartRateThresholds(
      low: 70,
      high: 130,
      ageBandLabel: '6-12 岁',
      normalRangeLabel: '正常参考 70-110 次/分钟',
    );
  }
  return const ParentHeartRateThresholds(
    low: 60,
    high: 100,
    ageBandLabel: '12 岁以上',
    normalRangeLabel: '正常参考 60-100 次/分钟',
  );
}

int? _optionalInt(dynamic value) {
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '');
}

class ParentChildProfile {
  const ParentChildProfile({
    required this.childId,
    this.name,
    this.nickname,
    this.age,
    this.gender,
    this.personality,
    this.interests,
    this.category,
    this.note,
    required this.highThresholdBpm,
    required this.lowThresholdBpm,
    required this.updatedAt,
  });

  final int childId;
  final String? name;
  final String? nickname;
  final int? age;
  final String? gender;
  final String? personality;
  final String? interests;
  final String? category;
  final String? note;
  final int highThresholdBpm;
  final int lowThresholdBpm;
  final DateTime updatedAt;

  ParentChildProfile copyWith({
    String? name,
    String? nickname,
    int? age,
    String? gender,
    String? personality,
    String? interests,
    String? category,
    String? note,
    int? highThresholdBpm,
    int? lowThresholdBpm,
    DateTime? updatedAt,
  }) {
    return ParentChildProfile(
      childId: childId,
      name: name ?? this.name,
      nickname: nickname ?? this.nickname,
      age: age ?? this.age,
      gender: gender ?? this.gender,
      personality: personality ?? this.personality,
      interests: interests ?? this.interests,
      category: category ?? this.category,
      note: note ?? this.note,
      highThresholdBpm: highThresholdBpm ?? this.highThresholdBpm,
      lowThresholdBpm: lowThresholdBpm ?? this.lowThresholdBpm,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  String get displayName {
    final n = nickname?.trim();
    if (n != null && n.isNotEmpty) return n;
    final real = name?.trim();
    if (real != null && real.isNotEmpty) return real;
    return '孩子';
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'childId': childId,
        'name': name,
        'nickname': nickname,
        'age': age,
        'gender': gender,
        'personality': personality,
        'interests': interests,
        'category': category,
        'note': note,
        'highThresholdBpm': highThresholdBpm,
        'lowThresholdBpm': lowThresholdBpm,
        'updatedAt': updatedAt.toIso8601String(),
      };

  factory ParentChildProfile.fromJson(Map<String, dynamic> json) {
    final age = _optionalInt(json['age']);
    final thresholds = parentHeartRateThresholdsForAge(age);
    return ParentChildProfile(
      childId: (_optionalInt(json['childId']) ?? 1).clamp(1, 1 << 30),
      name: json['name']?.toString(),
      nickname: json['nickname']?.toString(),
      age: age,
      gender: json['gender']?.toString(),
      personality: json['personality']?.toString(),
      interests: json['interests']?.toString(),
      category: json['category']?.toString(),
      note: json['note']?.toString(),
      highThresholdBpm: (_optionalInt(json['highThresholdBpm']) ?? thresholds.high)
          .clamp(80, 180)
          .toInt(),
      lowThresholdBpm: (_optionalInt(json['lowThresholdBpm']) ?? thresholds.low)
          .clamp(40, 120)
          .toInt(),
      updatedAt: DateTime.tryParse(json['updatedAt']?.toString() ?? '') ?? DateTime.now(),
    );
  }
}
