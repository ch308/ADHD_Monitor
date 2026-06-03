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
    this.avatarStyle,
    this.skillSummary,
    this.skillUpdatedAt,
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
  final String? avatarStyle;
  final String? skillSummary;
  final DateTime? skillUpdatedAt;
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
    String? avatarStyle,
    String? skillSummary,
    DateTime? skillUpdatedAt,
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
      avatarStyle: avatarStyle ?? this.avatarStyle,
      skillSummary: skillSummary ?? this.skillSummary,
      skillUpdatedAt: skillUpdatedAt ?? this.skillUpdatedAt,
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
        'avatarStyle': avatarStyle,
        'skillSummary': skillSummary,
        'skillUpdatedAt': skillUpdatedAt?.toIso8601String(),
        'highThresholdBpm': highThresholdBpm,
        'lowThresholdBpm': lowThresholdBpm,
        'updatedAt': updatedAt.toIso8601String(),
      };

  factory ParentChildProfile.fromJson(Map<String, dynamic> json) {
    final age = _optionalInt(json['age']);
    final thresholds = parentHeartRateThresholdsForAge(age);
    return ParentChildProfile(
      childId: (_optionalInt(json['childId']) ?? 1).clamp(1, 1 << 30).toInt(),
      name: json['name']?.toString(),
      nickname: json['nickname']?.toString(),
      age: age,
      gender: json['gender']?.toString(),
      personality: json['personality']?.toString(),
      interests: json['interests']?.toString(),
      category: json['category']?.toString(),
      note: json['note']?.toString(),
      avatarStyle: json['avatarStyle']?.toString(),
      skillSummary: json['skillSummary']?.toString(),
      skillUpdatedAt:
          DateTime.tryParse(json['skillUpdatedAt']?.toString() ?? ''),
      highThresholdBpm: (_optionalInt(json['highThresholdBpm']) ?? thresholds.high)
          .clamp(80, 180)
          .toInt(),
      lowThresholdBpm: (_optionalInt(json['lowThresholdBpm']) ?? thresholds.low)
          .clamp(40, 120)
          .toInt(),
      updatedAt:
          DateTime.tryParse(json['updatedAt']?.toString() ?? '') ?? DateTime.now(),
    );
  }
}

class ChildSkillAvatar {
  const ChildSkillAvatar({
    required this.theme,
    required this.primaryColor,
    required this.accentColor,
  });

  final String theme;
  final String primaryColor;
  final String accentColor;

  factory ChildSkillAvatar.fromJson(Map<String, dynamic>? json) {
    final data = json ?? const <String, dynamic>{};
    return ChildSkillAvatar(
      theme: data['theme']?.toString() ?? 'sunny',
      primaryColor: data['primaryColor']?.toString() ?? '#F2B35D',
      accentColor: data['accentColor']?.toString() ?? '#6FAF8E',
    );
  }
}

class ChildSkillData {
  const ChildSkillData({
    required this.childId,
    required this.profile,
    required this.displayName,
    required this.summary,
    required this.selfIntroduction,
    required this.conversationStyle,
    required this.avatar,
    required this.quickQuestions,
    this.recentContext = const <String, dynamic>{},
  });

  final int childId;
  final ParentChildProfile profile;
  final String displayName;
  final String summary;
  final String selfIntroduction;
  final String conversationStyle;
  final ChildSkillAvatar avatar;
  final List<String> quickQuestions;
  final Map<String, dynamic> recentContext;

  factory ChildSkillData.fromJson(Map<String, dynamic> json) {
    final profileRaw =
        Map<String, dynamic>.from((json['profile'] as Map?) ?? const {});
    final skillRaw =
        Map<String, dynamic>.from((json['skill'] as Map?) ?? const {});
    final childId =
        _optionalInt(json['child_id']) ?? _optionalInt(profileRaw['childId']) ?? 1;
    profileRaw['childId'] = childId;
    final questions = (skillRaw['quickQuestions'] as List?)
            ?.map((item) => item.toString())
            .where((item) => item.trim().isNotEmpty)
            .toList() ??
        const <String>[];
    return ChildSkillData(
      childId: childId,
      profile: ParentChildProfile.fromJson(profileRaw),
      displayName: skillRaw['displayName']?.toString() ??
          profileRaw['nickname']?.toString() ??
          profileRaw['name']?.toString() ??
          '孩子',
      summary: skillRaw['summary']?.toString() ?? '',
      selfIntroduction: skillRaw['selfIntroduction']?.toString() ?? '',
      conversationStyle: skillRaw['conversationStyle']?.toString() ?? '',
      avatar: ChildSkillAvatar.fromJson(skillRaw['avatar'] is Map
          ? Map<String, dynamic>.from(skillRaw['avatar'] as Map)
          : null),
      quickQuestions: questions.isEmpty
          ? const ['我可以怎样帮助你？', '你最近感觉如何？', '你可以介绍下自己吗？']
          : questions,
      recentContext: Map<String, dynamic>.from(
        (json['recent_context'] as Map?) ?? const <String, dynamic>{},
      ),
    );
  }
}

class ChildSkillChatResponse {
  const ChildSkillChatResponse({
    required this.answer,
    required this.source,
  });

  final String answer;
  final String source;

  factory ChildSkillChatResponse.fromJson(Map<String, dynamic> json) {
    return ChildSkillChatResponse(
      answer: json['answer']?.toString() ?? '',
      source: json['source']?.toString() ?? 'template',
    );
  }
}
