/// 心率/压力等设备侧采样数据模型。
///
/// 目前 MiBand6 走 BLE Heart Rate Service (180D / 2A37)，仅暴露 BPM；
/// `isAlert` 在端侧用一个简单阈值（>100）粗判，云端会用更稳定的算法复核。
class HeartRateSample {
  const HeartRateSample({
    required this.bpm,
    required this.timestamp,
    this.isAlert = false,
  });

  /// Beats Per Minute。
  final int bpm;

  /// 采样时间（端侧本地时钟，上报给云端做趋势）。
  final DateTime timestamp;

  /// 端侧本地的「可能偏高」标记，仅作为降级提示，权威判定以云端为准。
  final bool isAlert;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'bpm': bpm,
        'timestamp': timestamp.toIso8601String(),
        'is_alert': isAlert,
      };
}

