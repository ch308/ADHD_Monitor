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
}
