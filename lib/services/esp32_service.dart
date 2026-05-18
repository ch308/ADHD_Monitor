import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// 通过局域网给 ESP32-S3 端的「正念精灵」硬件下发指令，
/// 比如开启疗愈灯效、轻抚震动等。后端形态为 ESP32 上的轻量 HTTP 服务。
///
/// MVP 阶段约定接口（设备侧默认 80 端口）：
///   GET  /ping                  -> 200 OK
///   POST /calm                  -> 触发安抚循环
///   POST /alert                 -> 转入告警提示
///   POST /breath?cycle_ms=8000  -> 与手机端呼吸球同步
class Esp32Service {
  Esp32Service({
    this.host,
    this.port = 80,
    this.timeout = const Duration(seconds: 3),
  });

  /// ESP32 在局域网内的 IP，未发现时为 null。
  String? host;

  /// 设备 HTTP 监听端口，默认 80。
  int port;

  Duration timeout;

  bool get isConfigured => (host != null && host!.isNotEmpty);

  Uri _uri(String path) => Uri.parse('http://$host:$port$path');

  Future<bool> ping() => _send('/ping');

  Future<bool> sendCalmPulse() => _send('/calm');

  Future<bool> sendAlertPulse() => _send('/alert');

  /// 让硬件灯效与手机呼吸球同步，[cyclePeriod] 为呼吸完整周期。
  Future<bool> syncBreathing(Duration cyclePeriod) => _send(
        '/breath',
        payload: <String, dynamic>{'cycle_ms': cyclePeriod.inMilliseconds},
      );

  /// 通用发送：无 [payload] 走 GET，否则走 JSON POST。
  Future<bool> _send(String path, {Map<String, dynamic>? payload}) async {
    if (!isConfigured) {
      debugPrint('Esp32Service: host not configured, skip $path.');
      return false;
    }
    try {
      final response = payload == null
          ? await http.get(_uri(path)).timeout(timeout)
          : await http
              .post(
                _uri(path),
                headers: const <String, String>{
                  'Content-Type': 'application/json',
                },
                body: json.encode(payload),
              )
              .timeout(timeout);
      final ok = response.statusCode >= 200 && response.statusCode < 300;
      if (!ok) {
        debugPrint('Esp32Service: $path -> ${response.statusCode}');
      }
      return ok;
    } catch (e) {
      debugPrint('Esp32Service: $path error $e');
      return false;
    }
  }
}
