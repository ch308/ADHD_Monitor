import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/child_condition.dart';
import '../models/parent_child_profile.dart';
import '../theme/app_theme.dart';

const List<String> _parentGenderOptions = <String>['男', '女', '其他', '不便说明'];

Future<ParentChildProfile?> showParentChildProfileDialog({
  required BuildContext context,
  required int childId,
  ParentChildProfile? profile,
}) {
  return showDialog<ParentChildProfile>(
    context: context,
    builder: (ctx) => ParentChildProfileDialog(
      childId: childId,
      profile: profile,
    ),
  );
}

class ParentChildProfileDialog extends StatefulWidget {
  const ParentChildProfileDialog({
    super.key,
    required this.childId,
    this.profile,
  });

  final int childId;
  final ParentChildProfile? profile;

  @override
  State<ParentChildProfileDialog> createState() =>
      _ParentChildProfileDialogState();
}

class _ParentChildProfileDialogState extends State<ParentChildProfileDialog> {
  late final TextEditingController nameController;
  late final TextEditingController nicknameController;
  late final TextEditingController ageController;
  late final TextEditingController personalityController;
  late final TextEditingController interestsController;
  late final TextEditingController noteController;
  String? selectedGender;
  String? selectedCategoryLabel;
  String? errorText;

  @override
  void initState() {
    super.initState();
    final profile = widget.profile;
    nameController = TextEditingController(text: profile?.name ?? '');
    nicknameController = TextEditingController(text: profile?.nickname ?? '');
    ageController = TextEditingController(text: profile?.age?.toString() ?? '');
    personalityController =
        TextEditingController(text: profile?.personality ?? '');
    interestsController = TextEditingController(text: profile?.interests ?? '');
    noteController = TextEditingController(text: profile?.note ?? '');
    selectedGender = (profile?.gender?.trim().isNotEmpty ?? false)
        ? profile!.gender!.trim()
        : null;
    selectedCategoryLabel =
        ChildCondition.fromCategoryString(profile?.category).storageLabel;
  }

  @override
  void dispose() {
    nameController.dispose();
    nicknameController.dispose();
    ageController.dispose();
    personalityController.dispose();
    interestsController.dispose();
    noteController.dispose();
    super.dispose();
  }

  /// 与 [TextField] 一致；避免 [DropdownButtonFormField] 默认使用更大的 `titleMedium`。
  TextStyle _profileFieldStyle(BuildContext context) {
    final base = Theme.of(context).textTheme.bodyLarge ??
        const TextStyle(fontSize: 16);
    return base.copyWith(
      fontSize: 15,
      height: 1.4,
      color: AppColors.ink,
    );
  }

  InputDecoration _profileFieldDecoration(
    BuildContext context, {
    required String labelText,
    String? helperText,
  }) {
    return InputDecoration(
      labelText: labelText,
      helperText: helperText,
      helperMaxLines: 2,
      isDense: true,
      contentPadding: const EdgeInsets.fromLTRB(14, 16, 14, 16),
    ).applyDefaults(Theme.of(context).inputDecorationTheme);
  }

  @override
  Widget build(BuildContext context) {
    final age = int.tryParse(ageController.text.trim());
    final thresholds = parentHeartRateThresholdsForAge(age);
    final fieldStyle = _profileFieldStyle(context);
    final maxContentWidth = math.min(
      MediaQuery.sizeOf(context).width - 72,
      420.0,
    );
    return AlertDialog(
      title: const Text('录入孩子资料'),
      content: SizedBox(
        width: maxContentWidth,
        child: SingleChildScrollView(
          child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: nameController,
              style: fieldStyle,
              decoration: _profileFieldDecoration(
                context,
                labelText: '孩子姓名，可选',
              ),
            ),
            TextField(
              controller: nicknameController,
              style: fieldStyle,
              decoration: _profileFieldDecoration(
                context,
                labelText: '小名，可选',
              ),
            ),
            TextField(
              controller: ageController,
              style: fieldStyle,
              keyboardType: TextInputType.number,
              onChanged: (_) => setState(() => errorText = null),
              decoration: _profileFieldDecoration(
                context,
                labelText: '年龄',
              ),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              value: selectedGender,
              style: fieldStyle,
              isExpanded: true,
              itemHeight: 48,
              decoration: _profileFieldDecoration(
                context,
                labelText: '性别，可选',
              ),
              items: _parentGenderOptions
                  .map(
                    (item) => DropdownMenuItem<String>(
                      value: item,
                      child: Text(item, style: fieldStyle),
                    ),
                  )
                  .toList(),
              onChanged: (value) => setState(() => selectedGender = value),
            ),
            DropdownButtonFormField<String>(
              value: selectedCategoryLabel,
              style: fieldStyle,
              isExpanded: true,
              itemHeight: 48,
              decoration: _profileFieldDecoration(
                context,
                labelText: '类别',
                helperText: '保存后界面将按类别切换（多动症 / 孤独症）',
              ),
              items: ChildCondition.dropdownLabels
                  .map(
                    (e) => DropdownMenuItem<String>(
                      value: e,
                      child: Text(e, style: fieldStyle),
                    ),
                  )
                  .toList(),
              onChanged: (value) {
                if (value == null) return;
                setState(() => selectedCategoryLabel = value);
              },
            ),
            TextField(
              controller: personalityController,
              style: fieldStyle,
              decoration: _profileFieldDecoration(
                context,
                labelText: '性格，可选',
              ),
            ),
            TextField(
              controller: interestsController,
              style: fieldStyle,
              decoration: _profileFieldDecoration(
                context,
                labelText: '兴趣爱好，可选',
              ),
            ),
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.surfaceSoft,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: AppColors.border),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '自动提醒线',
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      color: AppColors.ink,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '${thresholds.ageBandLabel} · ${thresholds.normalRangeLabel}',
                  ),
                  const SizedBox(height: 4),
                  Text('过高提醒：>${thresholds.high} 次/分钟'),
                  Text('过低提醒：<${thresholds.low} 次/分钟'),
                ],
              ),
            ),
            TextField(
              controller: noteController,
              maxLines: 2,
              style: fieldStyle,
              decoration: _profileFieldDecoration(
                context,
                labelText: '补充说明，可选',
              ),
            ),
            if (errorText != null) ...[
              const SizedBox(height: 10),
              Text(errorText!, style: const TextStyle(color: AppColors.coral)),
            ],
          ],
        ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () {
            final ageValue = int.tryParse(ageController.text.trim());
            if (ageValue == null || ageValue < 0) {
              setState(() {
                errorText = '请填写正确的年龄，系统会按年龄自动配置提醒线。';
              });
              return;
            }
            final th = parentHeartRateThresholdsForAge(ageValue);
            final cat = (selectedCategoryLabel ?? ChildCondition.adhd.storageLabel)
                .trim();
            Navigator.of(context).pop(
              ParentChildProfile(
                childId: widget.childId,
                name: nameController.text.trim().isEmpty
                    ? null
                    : nameController.text.trim(),
                nickname: nicknameController.text.trim().isEmpty
                    ? null
                    : nicknameController.text.trim(),
                age: ageValue,
                gender: selectedGender?.trim().isEmpty ?? true
                    ? null
                    : selectedGender!.trim(),
                personality: personalityController.text.trim().isEmpty
                    ? null
                    : personalityController.text.trim(),
                interests: interestsController.text.trim().isEmpty
                    ? null
                    : interestsController.text.trim(),
                category: cat.isEmpty ? null : cat,
                note: noteController.text.trim().isEmpty
                    ? null
                    : noteController.text.trim(),
                highThresholdBpm: th.high,
                lowThresholdBpm: th.low,
                updatedAt: DateTime.now(),
              ),
            );
          },
          child: const Text('保存'),
        ),
      ],
    );
  }
}
