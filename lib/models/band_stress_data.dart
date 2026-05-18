/// 手环压力值采样。
///
/// 注意：压力值不是 Bluetooth SIG 标准心率服务的一部分。小米/Zepp 系列通常
/// 通过私有协议计算和传输压力值；如果当前 GATT 服务没有暴露可读/可通知的压力
/// 特征，本模型不会产生任何数据。
class BandStressSample {
  const BandStressSample({
    required this.value,
    required this.timestamp,
  });

  /// 0-100 的压力分值（若设备提供）。数值含义以厂商 App 为准。
  final int value;

  /// 采样时间（端侧本地时钟）。
  final DateTime timestamp;
}
