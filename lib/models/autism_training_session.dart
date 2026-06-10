/// 孤独症训练流程阶段（四阶段抽象；首版仅部分步骤对接设备与云端）。
enum AutismTrainingPhase {
  /// 家长选择场景与参数
  parentSetup,

  /// 已下发，等待机器人 / 孩子侧
  waitingDevice,

  /// 设备侧有反馈（轮询 session status 或事件表）
  deviceProgress,

  /// 结束或家长补充观察
  completed,
}

/// 与 Flask `scene_id` 对齐的场景标识。
abstract final class AutismTrainingSceneIds {
  static const preferenceChoice = 'preference_choice';
  static const helpRequest = 'help_request';
}
