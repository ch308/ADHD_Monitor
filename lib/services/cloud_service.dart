import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../models/device_binding.dart';
import '../models/heart_rate_data.dart';

/// 异步把端侧采样批量打包，送到运行在腾讯云上的 Flask 后端
/// （[serverHost]:11760/webhook）。和 UI 层使用的轮询 GET /webhook
/// 共用一个端口，区分方法即可。
class CloudService {
  CloudService({
    required this.serverHost,
    this.deviceLabel = 'MiBand6_Real',
    this.timeout = const Duration(seconds: 8),
  });

  /// 仅主机名或 IP（不含 http:// 与端口；端口固定 11760）
  String serverHost;

  /// 设备标识，方便云端区分上报来源
  String deviceLabel;

  /// 单次 HTTP 请求超时
  Duration timeout;

  /// 已连接手环的 MAC 地址，由外部在连接成功后设置
  String? macAddress;

  /// 当前孩子的 ID，由外部设置后随上传一起发送
  int? childId;

  /// 鉴权 token，用于设备绑定 API
  String? authToken;

  String _base() => 'http://$serverHost:11760';

  Map<String, String> _authHeaders({bool jsonBody = true}) {
    final h = <String, String>{};
    if (jsonBody) {
      h['Content-Type'] = 'application/json';
    }
    final t = authToken;
    if (t != null && t.isNotEmpty) {
      h['Authorization'] = 'Bearer $t';
    }
    final cid = childId;
    if (cid != null) {
      h['X-Child-Id'] = '$cid';
    }
    return h;
  }

  /// 把一批心率采样以数组形式 POST 给云端。
  /// 返回 true 表示云端已接收（HTTP 2xx），调用方据此决定要不要回滚缓冲区。
  Future<bool> uploadHeartRateBatch(List<HeartRateSample> samples) async {
    if (samples.isEmpty) return true;
    try {
      final body = <String, dynamic>{
        'device': deviceLabel,
        'batch_data': samples.map((s) => s.toJson()).toList(),
      };
      final mac = macAddress;
      if (mac != null && mac.isNotEmpty) {
        body['mac_address'] = mac;
      }
      final cid = childId;
      if (cid != null) {
        body['child_id'] = cid;
      }
      final r = await http
          .post(
            Uri.parse('${_base()}/webhook'),
            headers: _authHeaders(),
            body: json.encode(body),
          )
          .timeout(timeout);
      if (r.statusCode >= 200 && r.statusCode < 300) {
        debugPrint('CloudService: uploaded ${samples.length} HR samples.');
        return true;
      }
      debugPrint('CloudService: upload failed ${r.statusCode}: ${r.body}');
      return false;
    } catch (e) {
      debugPrint('CloudService: upload error $e');
      return false;
    }
  }

  /// 查询手环 MAC 地址的绑定状态。
  /// 返回 [DeviceBinding] 或 null（网络错误）。
  Future<DeviceBinding?> checkDeviceBinding(String mac) async {
    try {
      final r = await http
          .get(
            Uri.parse('${_base()}/device/$mac/binding'),
            headers: _authHeaders(jsonBody: false),
          )
          .timeout(timeout);
      if (r.statusCode == 200) {
        final data = json.decode(r.body) as Map<String, dynamic>;
        return DeviceBinding.fromJson(data);
      }
      if (r.statusCode == 404) {
        return DeviceBinding.unbound(mac);
      }
      debugPrint('CloudService: check binding failed ${r.statusCode}');
      return null;
    } catch (e) {
      debugPrint('CloudService: check binding error $e');
      return null;
    }
  }

  /// 将手环 MAC 绑定到当前孩子。
  /// 返回 true 表示绑定成功。
  Future<bool> bindDevice(String mac, int childIdToBind) async {
    try {
      final r = await http
          .post(
            Uri.parse('${_base()}/device/bind'),
            headers: _authHeaders(),
            body: json.encode({
              'mac_address': mac,
              'child_id': childIdToBind,
            }),
          )
          .timeout(timeout);
      if (r.statusCode >= 200 && r.statusCode < 300) {
        debugPrint('CloudService: bound $mac to child $childIdToBind');
        return true;
      }
      debugPrint('CloudService: bind failed ${r.statusCode}: ${r.body}');
      return false;
    } catch (e) {
      debugPrint('CloudService: bind error $e');
      return false;
    }
  }

  // ── ESP32-S3 LCD 毛绒球呼吸灯：远程开关呼吸灯 / 倒计时灯 ──

  /// 列出当前用户能看到的 ESP32 设备（已绑定到我名下的孩子 + 尚未绑定的）。
  /// 每项是 `{device_id, kind, child_id, child_nickname, first_seen_at, last_seen_at}`。
  Future<List<Map<String, dynamic>>> fetchEsp32List() async {
    try {
      final r = await http
          .get(
            Uri.parse('${_base()}/device/esp32/list'),
            headers: _authHeaders(jsonBody: false),
          )
          .timeout(timeout);
      if (r.statusCode == 200) {
        final data = json.decode(r.body) as Map<String, dynamic>;
        final list = (data['devices'] as List?) ?? const [];
        return list.cast<Map<String, dynamic>>();
      }
      debugPrint('CloudService: esp32 list failed ${r.statusCode}: ${r.body}');
      return const [];
    } catch (e) {
      debugPrint('CloudService: esp32 list error $e');
      return const [];
    }
  }

  /// 把 ESP32 device_id 绑到指定孩子。需要登录 + 是该孩子的成员。
  /// [kind] 例如 `xiaozhi` 用于小智板；毛绒球可不传。
  Future<bool> bindEsp32(
    String deviceId,
    int childIdToBind, {
    String? kind,
  }) async {
    try {
      final body = <String, dynamic>{
        'device_id': deviceId.toUpperCase(),
        'child_id': childIdToBind,
      };
      if (kind != null && kind.trim().isNotEmpty) {
        body['kind'] = kind.trim();
      }
      final r = await http
          .post(
            Uri.parse('${_base()}/device/esp32/bind'),
            headers: _authHeaders(),
            body: json.encode(body),
          )
          .timeout(timeout);
      if (r.statusCode >= 200 && r.statusCode < 300) {
        debugPrint('CloudService: bound esp32 $deviceId → child $childIdToBind');
        return true;
      }
      debugPrint('CloudService: bind esp32 failed ${r.statusCode}: ${r.body}');
      return false;
    } catch (e) {
      debugPrint('CloudService: bind esp32 error $e');
      return false;
    }
  }

  /// 解绑 ESP32。
  Future<bool> unbindEsp32(String deviceId) async {
    try {
      final r = await http
          .post(
            Uri.parse('${_base()}/device/esp32/unbind'),
            headers: _authHeaders(),
            body: json.encode({'device_id': deviceId.toUpperCase()}),
          )
          .timeout(timeout);
      return r.statusCode >= 200 && r.statusCode < 300;
    } catch (e) {
      debugPrint('CloudService: unbind esp32 error $e');
      return false;
    }
  }

  /// 推一条命令给 ESP32。服务器收下后塞进它的长轮询队列，板子<100ms 内收到。
  /// [extra] 透传给 ESP32（cycle_ms / total_ms 等）。
  Future<bool> sendEsp32Command(
    String deviceId,
    String action, {
    Map<String, dynamic>? extra,
  }) async {
    try {
      final body = <String, dynamic>{'action': action};
      if (extra != null) body.addAll(extra);
      final r = await http
          .post(
            Uri.parse('${_base()}/device/${deviceId.toUpperCase()}/cmd'),
            headers: _authHeaders(),
            body: json.encode(body),
          )
          .timeout(timeout);
      if (r.statusCode >= 200 && r.statusCode < 300) {
        debugPrint('CloudService: esp32 cmd $action → $deviceId OK');
        return true;
      }
      debugPrint('CloudService: esp32 cmd $action → $deviceId FAIL ${r.statusCode}: ${r.body}');
      return false;
    } catch (e) {
      debugPrint('CloudService: esp32 cmd $action → $deviceId ERROR $e');
      return false;
    }
  }

  /// 触发 ESP32 进入"正念呼吸"灯效。[cyclePeriod] 与 UI 上呼吸球同步。
  Future<bool> triggerEsp32BreathingStart(
    String deviceId, {
    Duration cyclePeriod = const Duration(milliseconds: 8000),
    Duration countdown = const Duration(seconds: 10),
  }) {
    return sendEsp32Command(
      deviceId,
      'breathing_start',
      extra: {
        'cycle_ms': cyclePeriod.inMilliseconds,
        'countdown_ms': countdown.inMilliseconds,
      },
    );
  }

  /// 停止 ESP32 呼吸灯（用户从呼吸页返回时调）。
  Future<bool> triggerEsp32BreathingStop(String deviceId) {
    return sendEsp32Command(deviceId, 'breathing_stop');
  }

  /// 毛绒球 SD 卡 `/audio/432Hz` 或 `528Hz` 下 MP3 循环播放（不经过手机扬声器）。
  /// [folder] 必须为 `432Hz` 或 `528Hz`。
  Future<bool> triggerEsp32SdcardAudioStart(String deviceId, String folder) {
    return sendEsp32Command(
      deviceId,
      'sdcard_audio_start',
      extra: {'folder': folder},
    );
  }

  /// 停止毛绒球 SD 卡音频播放。
  Future<bool> triggerEsp32SdcardAudioStop(String deviceId) {
    return sendEsp32Command(deviceId, 'sdcard_audio_stop');
  }

  /// 让 ESP32 清掉 NVS 中的 WiFi 凭据并重启进入 BLE 配网模式。
  ///
  /// 板子收到命令后会：
  /// 1) 立刻关掉屏 / 毛绒球呼吸灯；
  /// 2) `wifi_prov_mgr_reset_provisioning()` 清空 NVS 中的 SSID/PASSWORD；
  /// 3) `esp_restart()` 重启；
  /// 4) 重启后没有凭据 → 自动重新打开 BLE 并广播 `ADHD_<DEVID>`。
  ///
  /// device_id 来自 efuse MAC，不会变；服务器端的绑定关系会保留，
  /// 重新配网完成后无需再次扫描绑定。
  Future<bool> triggerEsp32ResetProvisioning(String deviceId) {
    return sendEsp32Command(deviceId, 'reset_provisioning');
  }

  /// 家长从 App 主动唤醒星星机器人（与 submit_log 后相同的 `xiaozhi_invoke_chat` 通道）。
  Future<bool> triggerXiaozhiParentWakeInvoke(String deviceId) {
    const opening =
        '你好，我是星星守护者，有什么可以帮助你的吗？我可以陪你聊天，给你讲故事。';
    return sendEsp32Command(
      deviceId,
      'xiaozhi_invoke_chat',
      extra: {
        'opening_line': opening,
        'context': '家长从手机端主动唤醒星星。',
      },
    );
  }

  /// 解除手环 MAC 的绑定。
  /// [childIdToUnbind] 用于校验只有绑定者才能解绑。
  Future<bool> unbindDevice(String mac, int childIdToUnbind) async {
    try {
      final r = await http
          .post(
            Uri.parse('${_base()}/device/unbind'),
            headers: _authHeaders(),
            body: json.encode({
              'mac_address': mac,
              'child_id': childIdToUnbind,
            }),
          )
          .timeout(timeout);
      if (r.statusCode >= 200 && r.statusCode < 300) {
        debugPrint('CloudService: unbound $mac from child $childIdToUnbind');
        return true;
      }
      debugPrint('CloudService: unbind failed ${r.statusCode}: ${r.body}');
      return false;
    } catch (e) {
      debugPrint('CloudService: unbind error $e');
      return false;
    }
  }

  /// 从服务器 `XIAOMI_AUTH_KEY` 拉取小米手环 32 位鉴权密钥（须已设置 [authToken]）。
  /// 成功返回小写 hex；未配置 / 未登录 / 网络错误返回 null。
  Future<String?> fetchXiaomiBandAuthKey() async {
    final t = authToken;
    if (t == null || t.isEmpty) return null;
    try {
      final r = await http
          .get(
            Uri.parse('${_base()}/my/config/xiaomi-band-auth-key'),
            headers: _authHeaders(jsonBody: false),
          )
          .timeout(timeout);
      if (r.statusCode != 200) {
        debugPrint(
          'CloudService: xiaomi band auth key ${r.statusCode}: ${r.body}',
        );
        return null;
      }
      final data = json.decode(r.body) as Map<String, dynamic>;
      if (data['status'] != 'ok') return null;
      final key = (data['auth_hex_key'] as String?)?.trim().toLowerCase();
      if (key == null || key.length != 32) return null;
      return key;
    } catch (e) {
      debugPrint('CloudService: fetch xiaomi band auth key error $e');
      return null;
    }
  }
}
