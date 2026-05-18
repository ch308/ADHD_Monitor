/// 手环设备与孩子的绑定状态。
class DeviceBinding {
  const DeviceBinding({
    required this.macAddress,
    this.boundChildId,
    this.boundChildNickname,
    this.isBoundToCurrentChild = false,
  });

  /// 手环 MAC 地址
  final String macAddress;

  /// 当前绑定到的孩子 ID（null 表示未绑定）
  final int? boundChildId;

  /// 当前绑定到的孩子昵称
  final String? boundChildNickname;

  /// 是否已绑定到当前选中的孩子
  final bool isBoundToCurrentChild;

  bool get isBound => boundChildId != null;

  factory DeviceBinding.fromJson(Map<String, dynamic> json) {
    return DeviceBinding(
      macAddress: json['mac_address']?.toString() ?? '',
      boundChildId: (json['bound_child_id'] as num?)?.toInt(),
      boundChildNickname: json['bound_child_nickname']?.toString(),
      isBoundToCurrentChild: json['is_bound_to_current_child'] == true,
    );
  }

  /// 本地构造：未查询到云端记录时使用
  factory DeviceBinding.unbound(String mac) {
    return DeviceBinding(macAddress: mac);
  }

  /// 本地构造：已绑定到当前孩子
  factory DeviceBinding.boundToCurrent(String mac, int childId, {String? nickname}) {
    return DeviceBinding(
      macAddress: mac,
      boundChildId: childId,
      boundChildNickname: nickname,
      isBoundToCurrentChild: true,
    );
  }

  /// 本地构造：已绑定到其他孩子
  factory DeviceBinding.boundToOther(String mac, int childId, {String? nickname}) {
    return DeviceBinding(
      macAddress: mac,
      boundChildId: childId,
      boundChildNickname: nickname,
      isBoundToCurrentChild: false,
    );
  }
}
