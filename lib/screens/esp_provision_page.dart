/// ESP32-S3 LCD 毛绒球呼吸灯 / xiaozhi-esp32 星星机器人 BLE 配网 UI。
///
/// 流程：扫描 BLE 广播 → 选设备 → 输入家用 WiFi 的 SSID/密码 →
///       通过 BLE 把凭据写过去 → 板子连上路由器后自动 announce 到云端 →
///       App 调 cloud_service.bindEsp32 完成最后的绑定。
///
/// 同一个页面通过 [EspProvisionPage.kind] 在毛绒球（`ADHD_<MAC8>`）和
/// 星星机器人（`XIAOZHI_<MAC8>`）之间切换，两种设备复用同一份 protocomm
/// + sec0 BLE 协议代码（[EspProvisionService]）。

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../services/cloud_service.dart';
import '../services/esp_provision_service.dart';
import '../services/miband_service.dart';
import '../services/session_store.dart';
import '../theme/app_theme.dart';

class EspProvisionPage extends StatefulWidget {
  const EspProvisionPage({
    super.key,
    required this.cloudService,
    required this.activeChildId,
    this.currentBoundDeviceId,
    this.kind = EspProvKind.plush,
    this.miBandService,
  });

  final CloudService cloudService;
  final int activeChildId;

  /// 当前孩子已经绑定过的同类型设备 device_id（来自 home_screen 的本地状态）。
  /// 给页面顶部展示"现在绑了哪台 / 要不要让它重新进入配网"用。
  final String? currentBoundDeviceId;

  /// 配网设备种类：毛绒球（默认）或 xiaozhi 星星机器人。
  final EspProvKind kind;

  /// 主页持有的米带服务实例。配网页面只在进入时调 [MiBand6Auth.pauseAutoReconnect]，
  /// 退出时再 [MiBand6Auth.resumeAutoReconnect]，避免米带 5–60 s 退避定时器在
  /// ESP32 BLE 还在跑 protocomm 时强行连米带，把 host 栈撑爆触发 LINK_SUPERVISION
  /// _TIMEOUT 把 ESP32 链路掐掉（实测就是这条路径导致"BLE 配置失败"的）。
  final MiBand6Auth? miBandService;

  @override
  State<EspProvisionPage> createState() => _EspProvisionPageState();
}

class _EspProvisionPageState extends State<EspProvisionPage> {
  final _ssidCtrl = TextEditingController();
  final _passCtrl = TextEditingController();

  bool _busy = false;
  String _status = '';
  ProvStatus _phase = ProvStatus.idle;
  List<EspProvDevice> _devices = const [];
  List<Map<String, dynamic>> _cloudDevices = const [];
  // E1: WiFi 密码显示/隐藏开关
  bool _obscurePass = true;

  /// 设备类型对应的人话标签：贯穿整个 UI（标题、提示文字、卡片）。
  String get _deviceLabel {
    switch (widget.kind) {
      case EspProvKind.plush:
        return '毛绒球呼吸灯';
      case EspProvKind.xiaozhi:
        return '星星机器人';
    }
  }

  /// 重新配网 / 物理重置时屏幕上要给用户念的"那串编号"，与 ESP32 端
  /// network_prov_mgr_start_provisioning 设的广播名前缀一致。
  String get _advPrefix => widget.kind.advPrefix;

  /// 把刚配好的 device_id 落到本地缓存，按设备类型分两个键。
  Future<void> _persistBound(String deviceId) {
    if (widget.kind == EspProvKind.xiaozhi) {
      return SessionStore.saveBoundXiaozhi(widget.activeChildId, deviceId);
    }
    return SessionStore.saveBoundEsp32(widget.activeChildId, deviceId);
  }

  /// 云端 list 接口里挑出当前设备类型那一类。毛绒球用空 / esp32-s3-lcd 类型；
  /// xiaozhi 用 `kind=xiaozhi`。
  bool _matchKind(Map<String, dynamic> dev) {
    final raw = (dev['kind'] ?? '').toString().toLowerCase();
    if (widget.kind == EspProvKind.xiaozhi) {
      return raw == 'xiaozhi';
    }
    // 毛绒球：除了 xiaozhi 都视为毛绒球（包含空值与 esp32-s3-lcd-1.47B）。
    return raw != 'xiaozhi';
  }

  @override
  void dispose() {
    _ssidCtrl.dispose();
    _passCtrl.dispose();
    // 离开配网页：让米带自动重连恢复（如果当前不在 streaming，会立刻安排
    // 一次最短退避的重连尝试）。
    widget.miBandService?.resumeAutoReconnect();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    // 进入配网页就把米带的自动重连暂停掉，从根上消除「配网到一半米带 5 s
    // 退避定时器强行重连 → host 栈顶不住 → ESP32 link 被 LINK_SUPERVISION
    // _TIMEOUT 掐掉」的死亡链路。
    widget.miBandService?.pauseAutoReconnect();
  }

  Future<bool> _ensurePermissions() async {
    final wanted = <Permission>[
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
    ];
    for (final p in wanted) {
      final st = await p.request();
      if (!st.isGranted) {
        if (mounted) {
          setState(() => _status = '权限不足：${p.toString()} 未授权');
        }
        return false;
      }
    }
    return true;
  }

  Future<void> _scan() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _status = '扫描中…';
      _devices = const [];
      _cloudDevices = const [];
      _phase = ProvStatus.scanning;
    });
    try {
      if (!await _ensurePermissions()) return;
      final list = await EspProvisionService.scan(kind: widget.kind);
      if (!mounted) return;
      if (list.isEmpty) {
        setState(() => _status = '未扫到 BLE 配网广播，正在查询云端已联网$_deviceLabel…');
        final cloudListAll = await widget.cloudService.fetchEsp32List();
        // 只显示当前类型的设备，避免在毛绒球菜单里看到星星机器人，反之亦然。
        final cloudList = cloudListAll.where(_matchKind).toList(growable: false);
        if (!mounted) return;
        setState(() {
          _devices = const [];
          _cloudDevices = cloudList;
          _status = cloudList.isEmpty
              ? '未扫到 BLE 设备，云端也没有待绑定的$_deviceLabel。\n'
                  '常见原因：① 板子已经连上 WiFi — 此时不会再广播「${_advPrefix}…」配网名，'
                  'Flutter 扫不到是正常的；请用菜单「重配」让板子重新进 BLE，或确认固件已烧录最新版并能在串口看到 adhd_cmd: announce。\n'
                '② 手机未开蓝牙/定位权限，或设备暂时没有和服务完成同步。'
              : '未扫到 BLE 广播（已联网的$_deviceLabel会关闭 BLE），但云端已有 ${cloudList.length} 台。'
                  '可从下方列表直接绑定。';
        });
        return;
      }
      setState(() {
        _devices = list;
        _cloudDevices = const [];
        _status = '扫到 ${list.length} 台待配网$_deviceLabel';
      });
    } catch (e) {
      if (!mounted) return;
      final s = e.toString();
      setState(() => _status = (s.contains('SocketException') ||
              s.contains('Connection refused') ||
              s.contains('Failed host lookup') ||
              s.contains('TimeoutException'))
          ? '扫描没有完成，请确认网络和蓝牙都可用后再试'
          : '扫描暂时失败，请稍后再试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _provision(EspProvDevice dev) async {
    if (_busy) return;
    final ssid = _ssidCtrl.text.trim();
    final pass = _passCtrl.text;
    if (ssid.isEmpty) {
      _toast('请先填 SSID');
      return;
    }
    setState(() {
      _busy = true;
      _status = '正在连接 ${dev.advName}…';
    });
    final result = await EspProvisionService.provision(
      target: dev,
      ssid: ssid,
      password: pass,
      onStatus: (s) {
        if (!mounted) return;
        setState(() {
          _phase = s;
          _status = _phaseLabel(s);
        });
      },
    );
    if (!mounted) return;
    if (!result.success) {
      setState(() {
        _busy = false;
        _status = '配网失败：${result.message}';
      });
      return;
    }

    // 板子拿到 WiFi 后会向云端 POST announce，给它几秒同步窗口。
    //
    // 两条路径下都进这个等待：
    // 1) BLE 端拿到 state=Connected → 板子已经联网，几秒内就会 announce。
    // 2) BLE 端在 STA 测试连接阶段被 LINK_SUPERVISION_TIMEOUT 掐掉（常见于
    //    ESP32-S3 BT/Wi-Fi 共射频）→ 凭据已落到 NVS，板子会自己重启 WiFi，
    //    时间窗会更长（重启 + STA 关联 + announce 大概 30–60 s）。
    final awaitingCloud = _phase == ProvStatus.credsDeliveredAwaitingCloud;
    setState(() => _status = awaitingCloud
        ? '凭据已发送，板子正在加入 WiFi（最多 60 秒）…'
        : 'WiFi 已连上，正在向云端登记…');

    // 立刻打一次 bind：服务器对未知 device_id 会自动 INSERT 一行
    // （server/app.py:1638-1648），所以即便板子还没 announce，这一步也能让
    // 云端立刻识别到这台 xiaozhi/毛绒球，避免出现"远端没有待绑定设备"。
    bool bound = await widget.cloudService.bindEsp32(
      result.deviceId,
      widget.activeChildId,
      kind: widget.kind.bindKind,
    );
    final retries = awaitingCloud ? 30 : 8;
    for (var i = 0; i < retries && mounted && !bound; i++) {
      await Future<void>.delayed(const Duration(seconds: 2));
      bound = await widget.cloudService.bindEsp32(
        result.deviceId,
        widget.activeChildId,
        kind: widget.kind.bindKind,
      );
      if (bound) break;
      if (awaitingCloud && mounted) {
        setState(() => _status =
            '凭据已发送，等待板子向云端报到（${(i + 1) * 2}/${retries * 2}s）…');
      }
    }
    if (!mounted) return;
    if (!bound) {
      setState(() {
        _busy = false;
        _status = awaitingCloud
            ? '凭据已发送但 60 秒内云端未收到 announce。常见原因：\n'
                '① SSID/密码错误（ESP32-S3 只支持 2.4GHz）\n'
                '② AP 不在板子附近、信号太弱\n'
                '可重新扫描 → 长按 BOOT 5 秒 → 再次配网。'
            : '配网成功但云端未识别到设备，请稍后在"设备管理"重试绑定';
      });
      return;
    }
    await _persistBound(result.deviceId);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _status = widget.kind == EspProvKind.xiaozhi
          ? '✅ 星星机器人已绑定到当前孩子，submit_log 后会自动陪聊'
          : '✅ 设备已绑定到当前孩子，可以在呼吸页测试灯效了';
    });
    Future<void>.delayed(const Duration(seconds: 1), () {
      if (mounted) Navigator.of(context).pop<String>(result.deviceId);
    });
  }

  Future<void> _bindCloudDevice(Map<String, dynamic> dev) async {
    if (_busy) return;
    final id = (dev['device_id'] ?? '').toString().toUpperCase();
    if (id.isEmpty) return;
    setState(() {
      _busy = true;
      _status = '正在绑定已联网$_deviceLabel $id …';
    });
    final ok = await widget.cloudService.bindEsp32(
      id,
      widget.activeChildId,
      kind: widget.kind.bindKind,
    );
    if (!mounted) return;
    if (!ok) {
      setState(() {
        _busy = false;
        _status = '绑定 $id 失败：请确认已登录、当前孩子有权限，且服务器能看到该$_deviceLabel。';
      });
      return;
    }
    await _persistBound(id);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _status = widget.kind == EspProvKind.xiaozhi
          ? '✅ 已绑定已联网星星机器人 $id'
          : '✅ 已绑定已联网毛绒球呼吸灯 $id，可以在呼吸页测试灯效了';
    });
    Future<void>.delayed(const Duration(seconds: 1), () {
      if (mounted) Navigator.of(context).pop<String>(id);
    });
  }

  String _phaseLabel(ProvStatus s) {
    switch (s) {
      case ProvStatus.idle: return '空闲';
      case ProvStatus.scanning: return '扫描中…';
      case ProvStatus.connecting: return '连接 BLE…';
      case ProvStatus.exchangingSession: return '握手中…';
      case ProvStatus.sendingConfig: return '发送 WiFi 凭据…';
      case ProvStatus.applyingConfig: return '应用配置…';
      case ProvStatus.pollingStatus: return '等待 ESP32 联网…';
      case ProvStatus.connectedOk: return '✅ 已连上 WiFi';
      case ProvStatus.credsDeliveredAwaitingCloud:
        return '凭据已送达，板子重启加入 WiFi 中…';
      case ProvStatus.failed: return '失败';
    }
  }

  void _toast(String m) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  /// 通过云端命令让已绑定的同类型设备回到 BLE 配网模式（与 home_screen 的菜单项等价，
  /// 仅在已绑定时露出；未绑定时本页只走"扫描 + 新设备配网"分支）。
  Future<void> _remoteResetBound() async {
    final id = widget.currentBoundDeviceId;
    if (id == null || id.isEmpty) return;
    setState(() {
      _busy = true;
      _status = '正在下发重启命令到 $id …';
    });
    final ok = await widget.cloudService.triggerEsp32ResetProvisioning(id);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _status = ok
          ? '已下发重启命令，约 3–8 秒后板子会重新广播 $_advPrefix$id，'
              '届时点击下方"扫描设备"即可看到它。'
          : '重启命令下发失败：$_deviceLabel可能离线。'
              '请改用物理方式：长按板子 BOOT 键 5 秒。';
    });
  }

  @override
  Widget build(BuildContext context) {
    final bound = widget.currentBoundDeviceId;
    return Scaffold(
      backgroundColor: AppColors.canvas,
      appBar: AppBar(title: Text('$_deviceLabel设置')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (bound != null && bound.isNotEmpty) _buildBoundCard(bound),
              Text(
                '把家里的 WiFi 名和密码填好，再扫描附近的 $_deviceLabel。设备进入设置模式后会出现在下方列表里。',
                style: const TextStyle(fontSize: 13, color: AppColors.muted, height: 1.45),
              ),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
                decoration: BoxDecoration(
                  color: const Color(0xFFFFF8E1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: const Color(0xFFFFE082)),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.warning_amber_rounded,
                        size: 18, color: Color(0xFFB26A00)),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        '$_deviceLabel只支持 2.4GHz WiFi。'
                        '如果你的路由器把 2.4G/5G 拆成两个名称，'
                        '请填 2.4G 的那一个；密码再正确，5GHz 的 SSID $_deviceLabel也连不上。',
                        style: const TextStyle(fontSize: 12, color: Color(0xFF5D4000)),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _ssidCtrl,
                decoration: const InputDecoration(
                  labelText: 'WiFi SSID（2.4GHz）',
                  hintText: '例如 home_2.4G',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _passCtrl,
                obscureText: _obscurePass,
                decoration: InputDecoration(
                  labelText: 'WiFi 密码',
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    icon: Icon(_obscurePass
                        ? Icons.visibility_off_outlined
                        : Icons.visibility_outlined,
                        size: 20),
                    tooltip: _obscurePass ? '显示密码' : '隐藏密码',
                    onPressed: () => setState(() => _obscurePass = !_obscurePass),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _busy ? null : _scan,
                      icon: const Icon(Icons.bluetooth_searching),
                      label: const Text('扫描设备'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              if (_status.isNotEmpty)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: AppColors.surfaceSoft,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(_status, style: const TextStyle(fontSize: 13)),
                ),
              const SizedBox(height: 8),
              Expanded(
                child: _buildDeviceList(),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDeviceList() {
    if (_devices.isNotEmpty) {
      return ListView.separated(
        itemBuilder: (_, i) {
          final d = _devices[i];
          return ListTile(
            leading: const Icon(Icons.bluetooth),
            title: Text(d.advName),
            subtitle: Text(
              '待连接设备${d.rssi != null ? " · 信号 ${d.rssi}dBm" : ""}',
            ),
            trailing: _busy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.chevron_right),
            onTap: _busy ? null : () => _provision(d),
          );
        },
        separatorBuilder: (_, __) => const Divider(height: 1),
        itemCount: _devices.length,
      );
    }

    if (_cloudDevices.isNotEmpty) {
      return ListView.separated(
        itemBuilder: (_, i) {
          final d = _cloudDevices[i];
          final id = (d['device_id'] ?? '').toString();
          final childId = d['child_id'];
          final nick = (d['child_nickname'] ?? '').toString();
          final lastSeen = (d['last_seen_at'] ?? '').toString();
          final boundToOtherChild =
              childId != null && childId != widget.activeChildId;
          return ListTile(
            leading: const Icon(Icons.cloud_done_outlined),
            title: Text(id),
            subtitle: Text(
              [
                '已联网',
                if (childId == null)
                  '未绑定'
                else
                  '已绑定：${nick.isEmpty ? "孩子 $childId" : nick}',
                if (lastSeen.isNotEmpty) '最近在线：$lastSeen',
              ].join('  ·  '),
            ),
            trailing: _busy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : TextButton(
                    onPressed:
                        boundToOtherChild ? null : () => _bindCloudDevice(d),
                    child: Text(childId == widget.activeChildId ? '重新保存' : '绑定'),
                  ),
          );
        },
        separatorBuilder: (_, __) => const Divider(height: 1),
        itemCount: _cloudDevices.length,
      );
    }

    return const Center(
      child: Text(
        '点击上方“扫描设备”开始',
        style: TextStyle(color: AppColors.muted),
      ),
    );
  }

  /// 顶部"当前已绑定一台同类型设备"卡片：
  /// - 直接显示 device_id，方便用户对照板子背面贴的 MAC；
  /// - 「让它重新配网」=> 走云端命令；
  /// - 「物理重置说明」=> 简单提示长按按键路径。
  Widget _buildBoundCard(String deviceId) {
    final icon = widget.kind == EspProvKind.xiaozhi
        ? Icons.smart_toy_outlined
        : Icons.lightbulb_outline;
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '当前孩子已绑定$_deviceLabel：$deviceId',
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            const Text(
              '想换 WiFi 或换孩子用，可以让它先回到 BLE 配网模式：',
              style: TextStyle(fontSize: 12, color: Colors.black54),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _busy ? null : _remoteResetBound,
                    icon: const Icon(Icons.cloud_sync, size: 18),
                    label: Text('远程命令：让$_deviceLabel重启进入 BLE'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            const Text(
              '在线时优先用上面那一行；离线时长按板子 BOOT 键 ≥ 5 秒，'
              '看到屏幕熄灭就是清掉凭据成功，会自动重启。',
              style: TextStyle(fontSize: 11, color: Colors.black45),
            ),
          ],
        ),
      ),
    );
  }
}
