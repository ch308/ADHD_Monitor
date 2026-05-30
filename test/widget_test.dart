import 'package:flutter_test/flutter_test.dart';

import 'package:adhd_monitor/models/parent_child_profile.dart';
import 'package:adhd_monitor/teacher/teacher_models.dart';
import 'package:adhd_monitor/teacher/teacher_shell.dart';

void main() {
  test('家长版 6-12 岁孩子档案会自动匹配 >130 / <70 阈值', () {
    final thresholds = parentHeartRateThresholdsForAge(8);

    expect(thresholds.high, 130);
    expect(thresholds.low, 70);
    expect(thresholds.ageBandLabel, '6-12 岁');

    final profile = ParentChildProfile(
      childId: 1,
      name: '小宇',
      age: 8,
      highThresholdBpm: thresholds.high,
      lowThresholdBpm: thresholds.low,
      updatedAt: DateTime(2026, 5, 30),
    );

    expect(profile.highThresholdBpm, 130);
    expect(profile.lowThresholdBpm, 70);
    expect(profile.displayName, '小宇');
  });

  test('6-12 岁学生档案会自动匹配 >130 / <70 阈值', () {
    final thresholds = teacherHeartRateThresholdsForAge(8);

    expect(thresholds.high, 130);
    expect(thresholds.low, 70);
    expect(thresholds.ageBandLabel, '6-12 岁');

    final student = TeacherStudent(
      id: 's-1',
      name: '小宇',
      age: 8,
      thresholdBpm: thresholds.high,
      lowThresholdBpm: thresholds.low,
      createdAt: DateTime(2026, 5, 30),
    );

    expect(
      teacherStudentThresholdSummary(student),
      '自动提醒线：过高 >130 / 过低 <70 次/分钟',
    );
    expect(teacherRapidRiseRuleSummary, '额外规则：5 分钟内较基线升高 30% 也会提醒');
  });

  test('三类告警文案符合教师端显示和本地记录预期', () {
    expect(teacherAlertEventLabel('highHeartRate'), '心率持续偏高');
    expect(teacherAlertEventLabel('lowHeartRate'), '心率持续偏低');
    expect(teacherAlertEventLabel('rapidRiseHeartRate'), '心率短时骤升');
  });
}
