/// ESP32-S3 LCD WiFi 配网客户端：通过 BLE 把家用 WiFi 的 SSID/密码送给板子。
///
/// 协议：Espressif 官方 protocomm + wifi_provisioning，security 0（无加密）。
/// 服务/特征 UUID 由 wifi_prov_scheme_ble_set_service_uuid() 在 ESP32 端固定为：
///   service     : AD480001-7F86-46AD-A02E-3CA5849DA5B6
///   prov-session: AD48FF51-...
///   prov-config : AD48FF52-...
///   proto-ver   : AD48FF53-...
///
/// 因为 protobuf 包跟项目体量比起来太重，这里手写最小子集——只支持本项目
/// 用到的几个消息：SessionData(sec0)、WiFiConfigPayload(SetConfig / ApplyConfig /
/// GetStatus)。字段号严格按 esp-idf/components/wifi_provisioning/proto 定义。

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

/// 项目固定的 BLE 服务 / 特征 UUID
class EspProvUuids {
  static const String service = 'ad480001-7f86-46ad-a02e-3ca5849da5b6';
  static const String session = 'ad48ff51-7f86-46ad-a02e-3ca5849da5b6';
  static const String config  = 'ad48ff52-7f86-46ad-a02e-3ca5849da5b6';
  static const String version = 'ad48ff53-7f86-46ad-a02e-3ca5849da5b6';
}

/// 扫描到的一台 ESP32 设备（device_id 从广播名 "ADHD_XXXXXXXX" 解析）
class EspProvDevice {
  EspProvDevice({
    required this.deviceId,
    required this.advName,
    required this.bluetoothDevice,
    this.rssi,
  });

  final String deviceId;
  final String advName;
  final BluetoothDevice bluetoothDevice;
  final int? rssi;

  @override
  String toString() => 'EspProvDevice($advName, rssi=$rssi)';
}

enum ProvStatus {
  idle,
  scanning,
  connecting,
  exchangingSession,
  sendingConfig,
  applyingConfig,
  pollingStatus,
  connectedOk,
  failed,
}

/// 配网结果。Wi-Fi 状态来自 ESP32 GetStatus 上报。
class ProvResult {
  ProvResult.ok(this.deviceId) : success = true, message = '';
  ProvResult.fail(this.deviceId, this.message) : success = false;

  final bool success;
  final String deviceId;
  final String message;
}

class EspProvisionService {
  static const _kAdvPrefix = 'ADHD_';
  static const _scanTimeout = Duration(seconds: 10);
  static const _ioTimeout = Duration(seconds: 8);

  /// 扫描在线的 ADHD ESP32 板子。
  /// 返回的列表按 RSSI 强到弱排序。
  static Future<List<EspProvDevice>> scan({
    Duration timeout = _scanTimeout,
  }) async {
    final results = <String, EspProvDevice>{};
    StreamSubscription<List<ScanResult>>? sub;
    try {
      if (await FlutterBluePlus.isScanning.first) {
        await FlutterBluePlus.stopScan();
      }
      sub = FlutterBluePlus.scanResults.listen((rs) {
        for (final r in rs) {
          final name = r.device.platformName.isNotEmpty
              ? r.device.platformName
              : r.advertisementData.advName;
          if (!name.startsWith(_kAdvPrefix)) continue;
          final deviceId = name.substring(_kAdvPrefix.length).toUpperCase();
          if (deviceId.isEmpty) continue;
          results[deviceId] = EspProvDevice(
            deviceId: deviceId,
            advName: name,
            bluetoothDevice: r.device,
            rssi: r.rssi,
          );
        }
      });

      await FlutterBluePlus.startScan(
        withServices: [Guid(EspProvUuids.service)],
        timeout: timeout,
        androidUsesFineLocation: true,
      );
      await FlutterBluePlus.isScanning.where((s) => !s).first;
    } finally {
      await sub?.cancel();
      try {
        await FlutterBluePlus.stopScan();
      } catch (_) {}
    }
    final list = results.values.toList();
    list.sort((a, b) => (b.rssi ?? -200).compareTo(a.rssi ?? -200));
    return list;
  }

  /// 给指定设备发送 WiFi 凭据。回调可用来跟随状态在 UI 上画进度。
  static Future<ProvResult> provision({
    required EspProvDevice target,
    required String ssid,
    required String password,
    void Function(ProvStatus)? onStatus,
  }) async {
    BluetoothCharacteristic? sess;
    BluetoothCharacteristic? cfg;
    final dev = target.bluetoothDevice;
    void emit(ProvStatus s) => onStatus?.call(s);

    try {
      emit(ProvStatus.connecting);
      await dev.connect(timeout: const Duration(seconds: 12), autoConnect: false);
      try {
        await dev.requestMtu(256);
      } catch (_) {
        /* MTU 协商失败不致命，默认 23B 也能跑（消息都很小） */
      }

      final services = await dev.discoverServices();
      BluetoothService? svc;
      for (final s in services) {
        if (s.uuid == Guid(EspProvUuids.service)) {
          svc = s;
          break;
        }
      }
      if (svc == null) {
        return ProvResult.fail(target.deviceId, '设备未广播配网服务');
      }
      for (final ch in svc.characteristics) {
        if (ch.uuid == Guid(EspProvUuids.session)) sess = ch;
        if (ch.uuid == Guid(EspProvUuids.config))  cfg  = ch;
      }
      if (sess == null || cfg == null) {
        return ProvResult.fail(target.deviceId, '设备缺少 prov-session/prov-config 特征');
      }

      // ── 1. security0 握手 ───────────────────────────────────────────────
      emit(ProvStatus.exchangingSession);
      final sessReq = _encodeSec0SessionCmd();
      final sessResp = await _writeRead(sess, sessReq);
      if (sessResp.isEmpty) {
        return ProvResult.fail(target.deviceId, 'session 握手无响应');
      }

      // ── 2. SetConfig(ssid, passphrase) ────────────────────────────────
      emit(ProvStatus.sendingConfig);
      final setReq = _encodeCmdSetConfig(ssid: ssid, passphrase: password);
      final setResp = await _writeRead(cfg, setReq);
      if (!_isRespOk(setResp)) {
        return ProvResult.fail(target.deviceId, 'SetConfig 被拒');
      }

      // ── 3. ApplyConfig ─────────────────────────────────────────────────
      emit(ProvStatus.applyingConfig);
      final applyReq = _encodeCmdApplyConfig();
      final applyResp = await _writeRead(cfg, applyReq);
      if (!_isRespOk(applyResp)) {
        return ProvResult.fail(target.deviceId, 'ApplyConfig 被拒');
      }

      // ── 4. 轮询 GetStatus 直到 ESP32 报告 Connected ────────────────────
      emit(ProvStatus.pollingStatus);
      final ok = await _pollUntilConnected(cfg);
      if (!ok) {
        return ProvResult.fail(target.deviceId, 'ESP32 未能连上 WiFi（检查 SSID/密码）');
      }

      emit(ProvStatus.connectedOk);
      return ProvResult.ok(target.deviceId);
    } catch (e) {
      emit(ProvStatus.failed);
      debugPrint('EspProvisionService.provision error: $e');
      return ProvResult.fail(target.deviceId, e.toString());
    } finally {
      try {
        await dev.disconnect();
      } catch (_) {}
    }
  }

  // ────────── BLE 收发 helper ──────────

  static Future<Uint8List> _writeRead(
    BluetoothCharacteristic ch,
    Uint8List payload,
  ) async {
    await ch.write(payload, withoutResponse: false, timeout: 5);
    // protocomm BLE：response 走 read 同一特征
    final resp = await ch.read().timeout(_ioTimeout);
    return Uint8List.fromList(resp);
  }

  static Future<bool> _pollUntilConnected(BluetoothCharacteristic ch) async {
    final start = DateTime.now();
    const deadline = Duration(seconds: 20);
    while (DateTime.now().difference(start) < deadline) {
      final resp = await _writeRead(ch, _encodeCmdGetStatus());
      final state = _parseStaState(resp);
      if (state == 0) {
        return true; // Connected
      }
      if (state == 3) {
        return false; // ConnectionFailed
      }
      await Future<void>.delayed(const Duration(milliseconds: 800));
    }
    return false;
  }

  // ────────── 最小化 protobuf（按 esp-idf wifi_provisioning .proto 字段号）──────────
  //
  //   SessionData      { sec_ver=2 int32, sec0=10 message<Sec0Payload> }
  //   Sec0Payload      { msg=1 enum,  sc=20 message<S0SessionCmd>, sr=21 message<S0SessionResp> }
  //   S0SessionCmd     { (empty) }
  //   S0SessionResp    { status=1 enum }
  //
  //   WiFiConfigPayload { msg=1 enum, cmd_get_status=10, resp_get_status=11,
  //                       cmd_set_config=12, resp_set_config=13,
  //                       cmd_apply_config=14, resp_apply_config=15 }
  //   CmdSetConfig     { ssid=1 bytes, passphrase=2 bytes, bssid=3 bytes, channel=4 int32 }
  //   RespGetStatus    { status=1 enum, sta_state=2 enum, fail_reason=10, connected=11 }

  /// SessionData{ sec_ver=0(default,omit), sec0={ msg=0(omit), sc=S0SessionCmd{} } }
  /// = 5 字节: 52 03 A2 01 00
  static Uint8List _encodeSec0SessionCmd() {
    final inner = _BufW()
      ..tagLen(20, 0); // sc = empty
    final sec0 = inner.takeBytes();
    final outer = _BufW()
      ..tagLen(10, sec0.length)
      ..raw(sec0);
    return outer.takeBytes();
  }

  /// WiFiConfigPayload{ msg=2(TypeCmdSetConfig), cmd_set_config={ssid, passphrase} }
  static Uint8List _encodeCmdSetConfig({
    required String ssid,
    required String passphrase,
  }) {
    final ssidBytes = utf8.encode(ssid);
    final passBytes = utf8.encode(passphrase);
    final csc = _BufW()
      ..tagLen(1, ssidBytes.length)
      ..raw(ssidBytes)
      ..tagLen(2, passBytes.length)
      ..raw(passBytes);
    final cscBytes = csc.takeBytes();

    final wcp = _BufW()
      ..tagVarint(1, 2) // msg=TypeCmdSetConfig
      ..tagLen(12, cscBytes.length)
      ..raw(cscBytes);
    return wcp.takeBytes();
  }

  /// WiFiConfigPayload{ msg=4(TypeCmdApplyConfig), cmd_apply_config={} }
  static Uint8List _encodeCmdApplyConfig() {
    final wcp = _BufW()
      ..tagVarint(1, 4)
      ..tagLen(14, 0);
    return wcp.takeBytes();
  }

  /// WiFiConfigPayload{ msg=0(TypeCmdGetStatus), cmd_get_status={} }
  static Uint8List _encodeCmdGetStatus() {
    // msg=0 是默认值，可省略；但 protocomm 端会按 oneof 路由，所以仍需要 cmd_get_status 字段
    final wcp = _BufW()
      ..tagLen(10, 0);
    return wcp.takeBytes();
  }

  /// 判断响应里的 status 字段是否为 0。
  /// resp_set_config / resp_apply_config 的结构都是
  ///   WiFiConfigPayload{ msg, resp_xxx{ status=1 enum, ... } }
  static bool _isRespOk(Uint8List resp) {
    if (resp.isEmpty) return false;
    final fields = _decode(resp);
    // 查 resp_set_config(13) / resp_apply_config(15)，提取内嵌 status
    for (final f in fields) {
      if (f.fieldNo == 13 || f.fieldNo == 15) {
        final sub = _decode(f.lenBytes!);
        for (final g in sub) {
          if (g.fieldNo == 1) {
            return g.varint == 0;
          }
        }
        return true; // status 缺省值即 0
      }
    }
    return true; // 没找到 resp_* 字段时，按宽松成功对待
  }

  /// 从 RespGetStatus 中提取 sta_state 字段（field=2，varint 枚举）。
  /// 返回值约定：0=Connected, 1=Connecting, 2=Disconnected, 3=ConnectionFailed, -1=未知
  static int _parseStaState(Uint8List resp) {
    if (resp.isEmpty) return -1;
    final outer = _decode(resp);
    for (final f in outer) {
      if (f.fieldNo == 11) {
        // resp_get_status
        final sub = _decode(f.lenBytes!);
        for (final g in sub) {
          if (g.fieldNo == 2) return g.varint ?? -1;
        }
        return -1;
      }
    }
    return -1;
  }
}

// ─────────────── 内置最小 protobuf reader/writer ───────────────

class _BufW {
  final BytesBuilder _b = BytesBuilder();

  void raw(List<int> bytes) => _b.add(bytes);
  void byte(int v) => _b.addByte(v & 0xFF);

  void varint(int value) {
    var v = value;
    while ((v & ~0x7F) != 0) {
      byte((v & 0x7F) | 0x80);
      v = v >>> 7;
    }
    byte(v & 0x7F);
  }

  /// tag = (fieldNo<<3) | wireType
  void tag(int fieldNo, int wireType) {
    varint((fieldNo << 3) | (wireType & 0x7));
  }

  void tagVarint(int fieldNo, int value) {
    tag(fieldNo, 0);
    varint(value);
  }

  /// 写一个 length-delimited 字段头（tag + length）。length 之后的 bytes 调用方自填。
  void tagLen(int fieldNo, int length) {
    tag(fieldNo, 2);
    varint(length);
  }

  Uint8List takeBytes() => _b.toBytes();
}

class _Field {
  _Field(this.fieldNo, this.wireType, {this.varint, this.lenBytes});

  final int fieldNo;
  final int wireType;
  final int? varint;
  final Uint8List? lenBytes;
}

List<_Field> _decode(Uint8List buf) {
  final out = <_Field>[];
  var i = 0;
  while (i < buf.length) {
    final tag = _readVarint(buf, i);
    i = tag.next;
    final fieldNo = tag.value >>> 3;
    final wireType = tag.value & 0x7;
    if (wireType == 0) {
      final v = _readVarint(buf, i);
      i = v.next;
      out.add(_Field(fieldNo, wireType, varint: v.value));
    } else if (wireType == 2) {
      final lv = _readVarint(buf, i);
      i = lv.next;
      final end = i + lv.value;
      if (end > buf.length) break;
      out.add(_Field(fieldNo, wireType, lenBytes: buf.sublist(i, end)));
      i = end;
    } else if (wireType == 1) {
      i += 8;
    } else if (wireType == 5) {
      i += 4;
    } else {
      break; // 未支持的 wire type
    }
  }
  return out;
}

class _VarintRead {
  _VarintRead(this.value, this.next);
  final int value;
  final int next;
}

_VarintRead _readVarint(Uint8List buf, int start) {
  var result = 0;
  var shift = 0;
  var i = start;
  while (i < buf.length) {
    final b = buf[i++];
    result |= (b & 0x7F) << shift;
    if ((b & 0x80) == 0) {
      return _VarintRead(result, i);
    }
    shift += 7;
    if (shift > 63) break;
  }
  return _VarintRead(result, i);
}
