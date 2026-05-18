import 'dart:async';

import 'package:flutter/material.dart';

/// 报警时自动打开：全屏正念呼吸球，并可一键 432/528Hz 与轻抚式震动（自闭症 / 阿斯伯格感官支持）
class BreathingBallPage extends StatefulWidget {
  const BreathingBallPage({
    super.key,
    required this.massageStrokeOn,
    required this.onToggleMassageStroke,
    required this.onPlay432,
    required this.onPlay528,
    required this.onStopAudio,
  });

  final ValueNotifier<bool> massageStrokeOn;
  final VoidCallback onToggleMassageStroke;
  final Future<void> Function() onPlay432;
  final Future<void> Function() onPlay528;
  final Future<void> Function() onStopAudio;

  @override
  State<BreathingBallPage> createState() => _BreathingBallPageState();
}

class _BreathingBallPageState extends State<BreathingBallPage>
    with SingleTickerProviderStateMixin {
  late final AnimationController _cycle;
  late final Animation<double> _scaleAnim;

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
                      onTap: () => unawaited(widget.onPlay432()),
                    ),
                    _BreathingActionChip(
                      icon: Icons.equalizer,
                      label: '528Hz',
                      onTap: () => unawaited(widget.onPlay528()),
                    ),
                    ValueListenableBuilder<bool>(
                      valueListenable: widget.massageStrokeOn,
                      builder: (context, on, _) {
                        return _BreathingActionChip(
                          icon: on ? Icons.stop_circle_outlined : Icons.waves,
                          label: on ? '停止轻抚' : '轻抚震动',
                          active: on,
                          onTap: widget.onToggleMassageStroke,
                        );
                      },
                    ),
                    _BreathingActionChip(
                      icon: Icons.music_off,
                      label: '停止音乐',
                      muted: true,
                      onTap: () => unawaited(widget.onStopAudio()),
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
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool active;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: active
          ? Colors.white.withValues(alpha: 0.2)
          : Colors.white.withValues(alpha: 0.05),
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon,
                  size: 16,
                  color: muted ? Colors.white30 : Colors.white70),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                    color: muted ? Colors.white30 : Colors.white70,
                    fontSize: 12,
                    fontWeight: FontWeight.w500),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
