import 'dart:async';

import 'package:flutter/material.dart';

/// 报警时自动打开：全屏正念呼吸球，并可一键 432/528Hz 疗愈音乐（由毛绒球 SD 卡播放）。
class BreathingBallPage extends StatefulWidget {
  const BreathingBallPage({
    super.key,
    required this.onPlay432,
    required this.onPlay528,
    required this.onStopAudio,
  });

  final Future<void> Function() onPlay432;
  final Future<void> Function() onPlay528;
  final Future<void> Function() onStopAudio;

  @override
  State<BreathingBallPage> createState() => _BreathingBallPageState();
}

class _BreathingBallPageState extends State<BreathingBallPage>
    with TickerProviderStateMixin {
  late final AnimationController _cycle;
  late final Animation<double> _scaleAnim;

  /// 吸/呼气与底部按钮之间的滚动说明（432 / 528 各一段 + 当前曲目说明）
  String? _marqueeText;

  static const String _k432Intro =
      '432Hz：常被称为"自然谐和音率"。它的频率更低一些，所以听起来会觉得更柔和、温暖、放松，让人联想到大自然。';
  static const String _k528Intro =
      '528Hz：被称为"奇迹频率"或"爱的频率"。它被认为与修复和转化有关，能帮助缓解紧张，带来内心深处的平静与和谐感';
  static const String _kTrackHint =
      '【当前曲目】由毛绒球从 SD 卡对应目录随机选曲；具体文件名以设备串口日志「now playing:」为准。';

  @override
  void initState() {
    super.initState();
    _cycle = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 8000),
    )..repeat(reverse: true);
    _scaleAnim = Tween<double>(begin: 0.78, end: 1.14).animate(
      CurvedAnimation(parent: _cycle, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _cycle.dispose();
    super.dispose();
  }

  Future<void> _onTap432() async {
    setState(() {
      _marqueeText = '$_k432Intro　　$_kTrackHint';
    });
    await widget.onPlay432();
  }

  Future<void> _onTap528() async {
    setState(() {
      _marqueeText = '$_k528Intro　　$_kTrackHint';
    });
    await widget.onPlay528();
  }

  Future<void> _onTapStop() async {
    setState(() => _marqueeText = null);
    await widget.onStopAudio();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Color(0xFF1A237E),
              Color(0xFF311B92),
              Color(0xFF0D0D0D),
            ],
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const SizedBox(width: 48),
                    Text(
                      '正念呼吸',
                      style: Theme.of(context)
                          .textTheme
                          .titleMedium
                          ?.copyWith(
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                          ),
                    ),
                    Container(
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.1),
                        shape: BoxShape.circle,
                      ),
                      child: IconButton(
                        icon:
                            const Icon(Icons.close, color: Colors.white70, size: 20),
                        tooltip: '关闭',
                        onPressed: () => Navigator.of(context).pop(),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 32),
                child: Text(
                  '球变大时轻轻吸气\n变小时缓慢呼气',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: Colors.white60,
                      height: 1.55,
                      fontSize: 13,
                      letterSpacing: 0.5),
                ),
              ),
              const Spacer(),
              AnimatedBuilder(
                animation: _scaleAnim,
                builder: (context, child) {
                  final label = _cycle.value < 0.5 ? '吸 气' : '呼 气';
                  return Column(
                    children: [
                      Transform.scale(
                        scale: _scaleAnim.value,
                        child: Container(
                          width: 200,
                          height: 200,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: const RadialGradient(
                              colors: [
                                Color(0xFFBBDEFB),
                                Color(0xFF7986CB),
                              ],
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.lightBlueAccent
                                    .withValues(alpha: 0.5),
                                blurRadius: 50,
                                spreadRadius: 4,
                              ),
                              BoxShadow(
                                color: Colors.lightBlueAccent
                                    .withValues(alpha: 0.2),
                                blurRadius: 80,
                                spreadRadius: 8,
                              ),
                            ],
                          ),
                          alignment: Alignment.center,
                          child: const Icon(
                            Icons.self_improvement,
                            size: 64,
                            color: Colors.white,
                          ),
                        ),
                      ),
                      const SizedBox(height: 32),
                      Text(
                        label,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 32,
                          fontWeight: FontWeight.w300,
                          letterSpacing: 4,
                        ),
                      ),
                    ],
                  );
                },
              ),
              const SizedBox(height: 12),
              if (_marqueeText != null)
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: _BreathingMarquee(text: _marqueeText!),
                  ),
                )
              else
                const Spacer(),
              Container(
                margin: const EdgeInsets.symmetric(horizontal: 16),
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Wrap(
                  spacing: 4,
                  runSpacing: 4,
                  alignment: WrapAlignment.center,
                  children: [
                    _BreathingActionChip(
                      icon: Icons.graphic_eq,
                      label: '432Hz',
                      onTap: () => unawaited(_onTap432()),
                    ),
                    _BreathingActionChip(
                      icon: Icons.equalizer,
                      label: '528Hz',
                      onTap: () => unawaited(_onTap528()),
                    ),
                    _BreathingActionChip(
                      icon: Icons.music_off,
                      label: '停止音乐',
                      muted: true,
                      prominent: true,
                      onTap: () => unawaited(_onTapStop()),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
            ],
          ),
        ),
      ),
    );
  }
}

class _BreathingActionChip extends StatelessWidget {
  const _BreathingActionChip({
    required this.icon,
    required this.label,
    required this.onTap,
    this.active = false,
    this.muted = false,
    this.prominent = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool active;
  final bool muted;
  /// 略大触控区与字号（用于「停止音乐」）
  final bool prominent;

  @override
  Widget build(BuildContext context) {
    final hPad = prominent ? 18.0 : 14.0;
    final vPad = prominent ? 13.0 : 10.0;
    final iconSize = prominent ? 19.0 : 16.0;
    final fontSize = prominent ? 14.0 : 12.0;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: active
              ? Colors.white.withValues(alpha: 0.2)
              : Colors.white.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(16),
        ),
        padding: EdgeInsets.symmetric(horizontal: hPad, vertical: vPad),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon,
                size: iconSize,
                color: muted ? Colors.white38 : Colors.white70),
            SizedBox(width: prominent ? 8 : 6),
            Text(
              label,
              style: TextStyle(
                  color: muted ? Colors.white38 : Colors.white70,
                  fontSize: fontSize,
                  fontWeight: FontWeight.w500),
            ),
          ],
        ),
      ),
    );
  }
}

/// 多行纵向循环滚动（吸/呼气与底部按钮之间）
class _BreathingMarquee extends StatefulWidget {
  const _BreathingMarquee({required this.text});

  final String text;

  @override
  State<_BreathingMarquee> createState() => _BreathingMarqueeState();
}

class _BreathingMarqueeState extends State<_BreathingMarquee>
    with SingleTickerProviderStateMixin {
  static const TextStyle _style = TextStyle(
    color: Colors.white70,
    fontSize: 13,
    height: 1.35,
    letterSpacing: 0.2,
  );

  late final AnimationController _controller;
  int? _layoutSyncToken;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this);
  }

  @override
  void didUpdateWidget(covariant _BreathingMarquee oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) {
      _controller.stop();
      _controller.reset();
      _layoutSyncToken = null;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  double _measureHeight(String text, double maxWidth, double textScale) {
    final tp = TextPainter(
      text: TextSpan(text: text, style: _style),
      maxLines: null,
      textDirection: TextDirection.ltr,
      textScaler: TextScaler.linear(textScale),
    )..layout(maxWidth: maxWidth);
    return tp.height;
  }

  void _scheduleSyncAnimation(double segH, double viewH) {
    final token = Object.hash(segH.round(), viewH.round(), widget.text);
    if (_layoutSyncToken == token) return;
    _layoutSyncToken = token;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (segH <= viewH) {
        _controller.stop();
        return;
      }
      final dur = Duration(
        milliseconds: (segH * 38).round().clamp(12000, 90000),
      );
      if (_controller.duration != dur) {
        _controller.duration = dur;
      }
      if (!_controller.isAnimating) {
        _controller.repeat();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final scale = MediaQuery.textScalerOf(context).scale(1.0);
    final full = '${widget.text}\n\n　　';

    return LayoutBuilder(
      builder: (context, constraints) {
        final viewW = constraints.maxWidth - 24;
        final viewH = constraints.maxHeight;
        final segH = _measureHeight(full, viewW, scale);
        _scheduleSyncAnimation(segH, viewH);

        if (segH <= viewH) {
          return Container(
            width: double.infinity,
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.22),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              widget.text,
              textAlign: TextAlign.center,
              style: _style,
            ),
          );
        }

        return Container(
          width: double.infinity,
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.22),
            borderRadius: BorderRadius.circular(12),
          ),
          clipBehavior: Clip.hardEdge,
          child: AnimatedBuilder(
            animation: _controller,
            builder: (context, _) {
              final t = _controller.value;
              final dy = -t * segH;
              return ShaderMask(
                shaderCallback: (rect) {
                  return const LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.transparent,
                      Colors.white,
                      Colors.white,
                      Colors.transparent,
                    ],
                    stops: [0.0, 0.06, 0.94, 1.0],
                  ).createShader(rect);
                },
                blendMode: BlendMode.dstIn,
                child: Transform.translate(
                  offset: Offset(0, dy),
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(full, style: _style),
                        Text(full, style: _style),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }
}
