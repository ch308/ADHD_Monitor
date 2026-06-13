import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../models/device_binding.dart';
import '../models/heart_rate_data.dart';
import '../models/parent_child_profile.dart';

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

  Future<ParentChildProfile?> fetchChildProfile(int childIdToFetch) async {
    try {
      final r = await http
          .get(
            Uri.parse('${_base()}/my/children/$childIdToFetch/profile'),
            headers: _authHeaders(jsonBody: false),
          )
          .timeout(timeout);
      if (r.statusCode != 200) {
        debugPrint('CloudService: fetch child profile ${r.statusCode}: ${r.body}');
        return null;
      }
      final data = json.decode(r.body) as Map<String, dynamic>;
      final profile = Map<String, dynamic>.from((data['profile'] as Map?) ?? const {});
      profile['childId'] = childIdToFetch;
      final skill = Map<String, dynamic>.from((data['skill'] as Map?) ?? const {});
      profile['skillSummary'] = skill['summary'];
      profile['avatarStyle'] = (skill['avatar'] as Map?)?['theme'];
      profile['skillUpdatedAt'] = skill['updatedAt'] ?? data['updated_at'];
      return ParentChildProfile.fromJson(profile);
    } catch (e) {
      debugPrint('CloudService: fetch child profile error $e');
      return null;
    }
  }

  Future<ParentChildProfile?> saveChildProfile(ParentChildProfile profile) async {
    try {
      final r = await http
          .put(
            Uri.parse('${_base()}/my/children/${profile.childId}/profile'),
            headers: _authHeaders(),
            body: json.encode({'profile': profile.toJson()}),
          )
          .timeout(timeout);
      if (r.statusCode != 200) {
        debugPrint('CloudService: save child profile ${r.statusCode}: ${r.body}');
        return null;
      }
      final data = json.decode(r.body) as Map<String, dynamic>;
      final next = Map<String, dynamic>.from((data['profile'] as Map?) ?? const {});
      next['childId'] = profile.childId;
      final skill = Map<String, dynamic>.from((data['skill'] as Map?) ?? const {});
      next['skillSummary'] = skill['summary'];
      next['avatarStyle'] = (skill['avatar'] as Map?)?['theme'];
      next['skillUpdatedAt'] = skill['updatedAt'] ?? data['updated_at'];
      return ParentChildProfile.fromJson(next);
    } catch (e) {
      debugPrint('CloudService: save child profile error $e');
      return null;
    }
  }

  Future<ChildSkillData?> fetchChildSkill(int childIdToFetch) async {
    try {
      final r = await http
          .get(
            Uri.parse('${_base()}/my/children/$childIdToFetch/skill'),
            headers: _authHeaders(jsonBody: false),
          )
          .timeout(timeout);
      if (r.statusCode != 200) {
        debugPrint('CloudService: fetch child skill ${r.statusCode}: ${r.body}');
        return null;
      }
      final data = json.decode(r.body) as Map<String, dynamic>;
      return ChildSkillData.fromJson(data);
    } catch (e) {
      debugPrint('CloudService: fetch child skill error $e');
      return null;
    }
  }

  Future<ChildSkillChatResponse?> askChildSkill(
    int childIdToAsk,
    String question,
  ) async {
    try {
      final r = await http
          .post(
            Uri.parse('${_base()}/my/children/$childIdToAsk/skill/chat'),
            headers: _authHeaders(),
            body: json.encode({'question': question}),
          )
          .timeout(timeout);
      if (r.statusCode != 200) {
        debugPrint('CloudService: child skill chat ${r.statusCode}: ${r.body}');
        return null;
      }
      final data = json.decode(r.body) as Map<String, dynamic>;
      return ChildSkillChatResponse.fromJson(data);
    } catch (e) {
      debugPrint('CloudService: child skill chat error $e');
      return null;
    }
  }

  Future<Map<String, dynamic>?> suggestTeacherHeartRateThresholds({
    required Map<String, dynamic> profile,
    required Map<String, dynamic> currentRule,
  }) async {
    try {
      final r = await http
          .post(
            Uri.parse('${_base()}/teacher/threshold_suggest'),
            headers: _authHeaders(),
            body: json.encode({
              'profile': profile,
              'current_rule': currentRule,
            }),
          )
          .timeout(timeout);
      if (r.statusCode != 200) {
        debugPrint(
          'CloudService: teacher threshold suggest ${r.statusCode}: ${r.body}',
        );
        return null;
      }
      final data = json.decode(r.body) as Map<String, dynamic>;
      if (data['status'] != 'ok') return null;
      return data;
    } catch (e) {
      debugPrint('CloudService: teacher threshold suggest error $e');
      return null;
    }
  }

  /// 孤独症：待家长确认的孩子需求事件（机器人上报）。
  Future<List<Map<String, dynamic>>> fetchAutismPendingNeeds(int childIdToFetch) async {
    try {
      final r = await http
          .get(
            Uri.parse('${_base()}/my/children/$childIdToFetch/autism/needs/pending'),
            headers: _authHeaders(jsonBody: false),
          )
          .timeout(timeout);
      if (r.statusCode != 200) {
        debugPrint('CloudService: autism needs ${r.statusCode}: ${r.body}');
        return const [];
      }
      final data = json.decode(r.body) as Map<String, dynamic>;
      final list = (data['items'] as List?) ?? const [];
      return list.map((e) => Map<String, dynamic>.from(e as Map)).toList();
    } catch (e) {
      debugPrint('CloudService: autism needs error $e');
      return const [];
    }
  }

  Future<bool> confirmAutismNeed(int childIdToFetch, int needId) async {
    try {
      final r = await http
          .post(
            Uri.parse(
              '${_base()}/my/children/$childIdToFetch/autism/needs/$needId/confirm',
            ),
            headers: _authHeaders(),
            body: '{}',
          )
          .timeout(timeout);
      return r.statusCode >= 200 && r.statusCode < 300;
    } catch (e) {
      debugPrint('CloudService: autism need confirm error $e');
      return false;
    }
  }

  /// 下发训练会话到星星机器人（经服务端队列 + `autism_session`）。
  Future<Map<String, dynamic>?> startAutismTraining({
    required int childIdToFetch,
    required String sceneId,
    List<String>? options,
    Map<String, String?>? images,
    bool followUp = false,
    String ttsIntro = '',
  }) async {
    try {
      final r = await http
          .post(
            Uri.parse('${_base()}/my/children/$childIdToFetch/autism/training/start'),
            headers: _authHeaders(),
            body: json.encode({
              'scene_id': sceneId,
              'options': options ?? const <String>[],
              if (images != null) 'images': images,
              'follow_up': followUp,
              'tts_intro': ttsIntro,
            }),
          )
          // 服务端 202：会话已建，TTS 注入与入队异步；响应很快。
          .timeout(const Duration(seconds: 25));
      if (r.statusCode != 200 && r.statusCode != 202) {
        debugPrint('CloudService: autism training start ${r.statusCode}: ${r.body}');
        return null;
      }
      return json.decode(r.body) as Map<String, dynamic>;
    } on TimeoutException catch (e) {
      debugPrint('CloudService: autism training start TIMEOUT $e');
      return null;
    } catch (e) {
      debugPrint('CloudService: autism training start error $e');
      return null;
    }
  }

  /// 预生成孩子训练五个场景的 AI 图片，只写云端缓存/存储，不下发机器人。
  Future<Map<String, dynamic>?> prepareAutismTrainingAssets({
    required int childIdToFetch,
    required List<Map<String, dynamic>> scenes,
  }) async {
    try {
      final r = await http
          .post(
            Uri.parse('${_base()}/my/children/$childIdToFetch/autism/training/assets'),
            headers: _authHeaders(),
            body: json.encode({'scenes': scenes}),
          )
          .timeout(const Duration(seconds: 300));
      if (r.statusCode != 200) {
        debugPrint('CloudService: autism training assets ${r.statusCode}: ${r.body}');
        return null;
      }
      return json.decode(r.body) as Map<String, dynamic>;
    } catch (e) {
      debugPrint('CloudService: autism training assets error $e');
      return null;
    }
  }

  /// 检查孩子训练五个场景图片是否已在云端缓存；不触发生图。
  Future<Map<String, dynamic>?> checkAutismTrainingAssets({
    required int childIdToFetch,
    required List<Map<String, dynamic>> scenes,
  }) async {
    try {
      final r = await http
          .post(
            Uri.parse('${_base()}/my/children/$childIdToFetch/autism/training/assets/check'),
            headers: _authHeaders(),
            body: json.encode({'scenes': scenes}),
          )
          .timeout(timeout);
      if (r.statusCode != 200) {
        debugPrint('CloudService: autism training assets check ${r.statusCode}: ${r.body}');
        return null;
      }
      return json.decode(r.body) as Map<String, dynamic>;
    } catch (e) {
      debugPrint('CloudService: autism training assets check error $e');
      return null;
    }
  }

  Future<Map<String, dynamic>?> fetchAutismTrainingStatus({
    required int childIdToFetch,
    required int sessionId,
  }) async {
    try {
      final r = await http
          .get(
            Uri.parse(
              '${_base()}/my/children/$childIdToFetch/autism/training/status?session_id=$sessionId',
            ),
            headers: _authHeaders(jsonBody: false),
          )
          .timeout(timeout);
      if (r.statusCode != 200) {
        debugPrint('CloudService: autism training status ${r.statusCode}: ${r.body}');
        return null;
      }
      return json.decode(r.body) as Map<String, dynamic>;
    } catch (e) {
      debugPrint('CloudService: autism training status error $e');
      return null;
    }
  }

  /// 五条日常计划：服务端智谱生图并入队下发设备。
  Future<Map<String, dynamic>?> postAutismDailyPlan(
    int childIdToFetch, {
    List<Map<String, dynamic>>? slots,
    Map<String, String?>? images,
  }) async {
    try {
      final r = await http
          .post(
            Uri.parse('${_base()}/my/children/$childIdToFetch/autism/daily-plan'),
            headers: _authHeaders(),
            body: json.encode({
              if (slots != null) 'slots': slots,
              if (images != null) 'images': images,
            }),
          )
          .timeout(const Duration(seconds: 180));
      if (r.statusCode != 200) {
        debugPrint('CloudService: autism daily-plan ${r.statusCode}: ${r.body}');
        return null;
      }
      return json.decode(r.body) as Map<String, dynamic>;
    } catch (e) {
      debugPrint('CloudService: autism daily-plan error $e');
      return null;
    }
  }

  /// 计划表：预生成所有选项图片，只写云端缓存/存储，不下发机器人。
  Future<Map<String, dynamic>?> prepareAutismDailyPlanAssets(
    int childIdToFetch, {
    required List<Map<String, dynamic>> slots,
  }) async {
    try {
      final r = await http
          .post(
            Uri.parse('${_base()}/my/children/$childIdToFetch/autism/daily-plan/assets'),
            headers: _authHeaders(),
            body: json.encode({'slots': slots}),
          )
          .timeout(const Duration(seconds: 300));
      if (r.statusCode != 200) {
        debugPrint('CloudService: autism daily-plan assets ${r.statusCode}: ${r.body}');
        return null;
      }
      return json.decode(r.body) as Map<String, dynamic>;
    } catch (e) {
      debugPrint('CloudService: autism daily-plan assets error $e');
      return null;
    }
  }

  /// 检查计划表图片是否已在云端缓存；不触发生图。
  Future<Map<String, dynamic>?> checkAutismDailyPlanAssets(
    int childIdToFetch, {
    required List<Map<String, dynamic>> slots,
  }) async {
    try {
      final r = await http
          .post(
            Uri.parse('${_base()}/my/children/$childIdToFetch/autism/daily-plan/assets/check'),
            headers: _authHeaders(),
            body: json.encode({'slots': slots}),
          )
          .timeout(timeout);
      if (r.statusCode != 200) {
        debugPrint('CloudService: autism daily-plan assets check ${r.statusCode}: ${r.body}');
        return null;
      }
      return json.decode(r.body) as Map<String, dynamic>;
    } catch (e) {
      debugPrint('CloudService: autism daily-plan assets check error $e');
      return null;
    }
  }

  Future<String?> generateAutismImage({
    required int childIdToFetch,
    required String prompt,
  }) async {
    try {
      final r = await http
          .post(
            Uri.parse('${_base()}/my/children/$childIdToFetch/autism/images'),
            headers: _authHeaders(),
            body: json.encode({'prompt': prompt}),
          )
          .timeout(timeout);
      if (r.statusCode != 200) return null;
      final data = json.decode(r.body) as Map<String, dynamic>;
      return data['url'] as String?;
    } catch (e) {
      debugPrint('CloudService: autism images error $e');
      return null;
    }
  }

  Future<bool> postAutismTrainingEvent({
    required int childIdToFetch,
    required String scene,
    required String phase,
    Map<String, dynamic>? payload,
    int? sessionId,
    String? ts,
  }) async {
    try {
      final body = <String, dynamic>{
        'scene': scene,
        'phase': phase,
        if (payload != null) 'payload': payload,
        if (sessionId != null) 'session_id': sessionId,
        if (ts != null && ts.isNotEmpty) 'ts': ts,
      };
      final r = await http
          .post(
            Uri.parse('${_base()}/my/children/$childIdToFetch/autism/events/training'),
            headers: _authHeaders(),
            body: json.encode(body),
          )
          .timeout(timeout);
      return r.statusCode >= 200 && r.statusCode < 300;
    } catch (e) {
      debugPrint('CloudService: autism training event error $e');
      return false;
    }
  }

  Future<List<Map<String, dynamic>>> fetchAutismTrainingEvents({
    required int childIdToFetch,
    int afterId = 0,
  }) async {
    try {
      final r = await http
          .get(
            Uri.parse(
              '${_base()}/my/children/$childIdToFetch/autism/events/training?after_id=$afterId',
            ),
            headers: _authHeaders(jsonBody: false),
          )
          .timeout(timeout);
      if (r.statusCode != 200) {
        debugPrint('CloudService: autism training events ${r.statusCode}: ${r.body}');
        return const [];
      }
      final data = json.decode(r.body) as Map<String, dynamic>;
      final list = (data['items'] as List?) ?? const [];
      return list.map((e) => Map<String, dynamic>.from(e as Map)).toList();
    } catch (e) {
      debugPrint('CloudService: autism training events error $e');
      return const [];
    }
  }
}
