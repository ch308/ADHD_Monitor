import 'package:shared_preferences/shared_preferences.dart';

/// 本地保存登录态与当前关注的孩子（多端共用同一云库时以 child_id 区分数据）
class SessionStore {
  static const _kToken = 'auth_token';
  static const _kChildId = 'active_child_id';

  /// 仅主机名或 IP，不含 `http://` 与端口（端口固定 11760）
  static const _kServerHost = 'server_host';

  /// 当前孩子绑定的手环 MAC 地址前缀
  static const _kBoundMacPrefix = 'bound_mac_';

  /// 当前孩子绑定的 ESP32 device_id 前缀（device_id 由 ESP32 efuse MAC 派生）
  static const _kBoundEsp32Prefix = 'bound_esp32_';

  /// 当前孩子的压力报警阈值前缀（0-100，默认 60）
  static const _kStressThresholdPrefix = 'stress_threshold_';
  static const String defaultServerHost = '124.223.53.33';

  static Future<String?> getToken() async {
    final p = await SharedPreferences.getInstance();
    return p.getString(_kToken);
  }

  static Future<void> saveToken(String? token) async {
    final p = await SharedPreferences.getInstance();
    if (token == null || token.isEmpty) {
      await p.remove(_kToken);
    } else {
      await p.setString(_kToken, token);
    }
  }

  static Future<int> getChildId() async {
    final p = await SharedPreferences.getInstance();
    return p.getInt(_kChildId) ?? 1;
  }

  static Future<void> saveChildId(int id) async {
    final p = await SharedPreferences.getInstance();
    await p.setInt(_kChildId, id < 1 ? 1 : id);
  }

  /// 获取指定孩子绑定的手环 MAC 地址（null 表示未绑定）
  static Future<String?> getBoundMac(int childId) async {
    final p = await SharedPreferences.getInstance();
    return p.getString('$_kBoundMacPrefix$childId');
  }

  /// 保存孩子与手环 MAC 的绑定关系
  static Future<void> saveBoundMac(int childId, String mac) async {
    final p = await SharedPreferences.getInstance();
    await p.setString('$_kBoundMacPrefix$childId', mac);
  }

  /// 删除孩子的手环绑定
  static Future<void> removeBoundMac(int childId) async {
    final p = await SharedPreferences.getInstance();
    await p.remove('$_kBoundMacPrefix$childId');
  }

  /// 获取指定孩子绑定的 ESP32 device_id（null 表示未绑定）
  static Future<String?> getBoundEsp32(int childId) async {
    final p = await SharedPreferences.getInstance();
    return p.getString('$_kBoundEsp32Prefix$childId');
  }

  /// 保存孩子与 ESP32 的绑定关系
  static Future<void> saveBoundEsp32(int childId, String deviceId) async {
    final p = await SharedPreferences.getInstance();
    await p.setString('$_kBoundEsp32Prefix$childId', deviceId.toUpperCase());
  }

  /// 删除孩子的 ESP32 绑定
  static Future<void> removeBoundEsp32(int childId) async {
    final p = await SharedPreferences.getInstance();
    await p.remove('$_kBoundEsp32Prefix$childId');
  }

  static Future<int> getStressThreshold(int childId) async {
    final p = await SharedPreferences.getInstance();
    return (p.getInt('$_kStressThresholdPrefix$childId') ?? 60)
        .clamp(30, 90)
        .toInt();
  }

  static Future<void> saveStressThreshold(int childId, int threshold) async {
    final p = await SharedPreferences.getInstance();
    await p.setInt(
      '$_kStressThresholdPrefix$childId',
      threshold.clamp(30, 90).toInt(),
    );
  }

  static Future<void> clear() async {
    final p = await SharedPreferences.getInstance();
    await p.remove(_kToken);
    await p.remove(_kChildId);
  }

  static Future<String> getServerHost() async {
    final p = await SharedPreferences.getInstance();
    final v = p.getString(_kServerHost)?.trim();
    if (v == null || v.isEmpty) return defaultServerHost;
    return v;
  }

  static Future<void> saveServerHost(String host) async {
    final p = await SharedPreferences.getInstance();
    final t = host.trim();
    if (t.isEmpty) {
      await p.remove(_kServerHost);
    } else {
      await p.setString(_kServerHost, t);
    }
  }
}
