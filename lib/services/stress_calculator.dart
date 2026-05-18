import 'dart:math';

/// 基于心率实时变化计算压力值 (0-100)。
///
/// 从 BPM 时间序列中提取三个维度综合评估：
///   1. 基线抬升 — 当前 BPM 相对动态静息基线的偏离
///   2. BPM 变异度 — 近期 BPM 标准差（自主神经调节越弱 → 变异越低 → 压力越高）
///   3. 心率趋势 — 线性回归斜率（BPM 上升加快 → 压力增大）
class StressCalculator {
  static const int _windowSize = 30;

  final List<int> _bpmHistory = [];
  final List<double> _timestamps = [];
  double _baselineBpm = 75.0;

  /// 每次收到新 BPM 时调用，返回 0-100 压力估值。
  /// 数据不足 5 个采样点时返回 null。
  int? calculateStress(int currentBpm, DateTime timestamp) {
    final now = timestamp.millisecondsSinceEpoch / 1000.0;

    _bpmHistory.add(currentBpm);
    _timestamps.add(now);

    while (_bpmHistory.length > _windowSize) {
      _bpmHistory.removeAt(0);
      _timestamps.removeAt(0);
    }

    if (_bpmHistory.length < 5) return null;

    // 动态基线：仅当心率不显著偏高时缓慢漂向静息值
    if (currentBpm < _baselineBpm + 5) {
      _baselineBpm = _baselineBpm * 0.95 + currentBpm * 0.05;
    }
    _baselineBpm = _baselineBpm.clamp(50.0, 100.0);

    // 维度 1：基线抬升（权重 50%）
    final elevation = (currentBpm - _baselineBpm).clamp(0, 60).toDouble();
    final elevationScore = (elevation / 50.0).clamp(0.0, 1.0);

    // 维度 2：BPM 变异度（权重 25%）
    final mean = _bpmHistory.reduce((a, b) => a + b) / _bpmHistory.length;
    final variance = _bpmHistory
            .map((b) => (b - mean) * (b - mean))
            .reduce((a, b) => a + b) /
        _bpmHistory.length;
    final stdDev = sqrt(variance);
    final variabilityScore = (1.0 - (stdDev / 10.0).clamp(0.0, 1.0));

    // 维度 3：线性回归斜率（权重 25%）
    double trendScore = 0.5;
    if (_bpmHistory.length >= 10) {
      final n = _timestamps.length.toDouble();
      final sumX = _timestamps.reduce((a, b) => a + b);
      final sumY = _bpmHistory.map((b) => b.toDouble()).reduce((a, b) => a + b);
      final meanX = sumX / n;
      final meanY = sumY / n;

      double num = 0, den = 0;
      for (int i = 0; i < _timestamps.length; i++) {
        num += (_timestamps[i] - meanX) * (_bpmHistory[i] - meanY);
        den += (_timestamps[i] - meanX) * (_timestamps[i] - meanX);
      }
      final slope = den > 0 ? num / den : 0;
      trendScore = (0.5 + slope * 0.5).clamp(0.0, 1.0);
    }

    final stress = (elevationScore * 50 + variabilityScore * 25 + trendScore * 25)
        .round()
        .clamp(0, 100);
    return stress;
  }

  /// 断开手环或重置时清空滑动窗口与基线。
  void reset() {
    _bpmHistory.clear();
    _timestamps.clear();
    _baselineBpm = 75.0;
  }
}
