/// 家长版孩子「类别」：与 [ParentChildProfile.category] JSON 及云端 `child_profiles` 一致。
enum ChildCondition {
  adhd('多动症'),
  autism('孤独症');

  const ChildCondition(this.storageLabel);
  final String storageLabel;

  static const List<String> dropdownLabels = ['多动症', '孤独症'];

  static ChildCondition fromCategoryString(String? raw) {
    final s = (raw ?? '').trim();
    if (s.isEmpty) return ChildCondition.adhd;
    if (s == ChildCondition.autism.storageLabel) return ChildCondition.autism;
    if (s == ChildCondition.adhd.storageLabel) return ChildCondition.adhd;
    // 兼容旧数据
    final lower = s.toLowerCase();
    if (s.contains('孤独') ||
        s.contains('自闭') ||
        lower.contains('autism') ||
        lower.contains('asd')) {
      return ChildCondition.autism;
    }
    if (s.contains('多动') ||
        s.contains('ADHD') ||
        lower.contains('adhd') ||
        s.contains('注意力')) {
      return ChildCondition.adhd;
    }
    return ChildCondition.adhd;
  }

  bool get isAutism => this == ChildCondition.autism;
}
