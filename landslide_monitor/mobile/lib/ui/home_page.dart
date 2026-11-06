import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:provider/provider.dart';

import '../core/auth_provider.dart';
import '../core/background_monitor.dart';
import '../core/config.dart';
import '../core/satlo_provider.dart';
import 'theme.dart';
import 'widgets/feedback.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  bool _bootstrappedMqtt = false;
  bool _bootstrappedBg = false;
  bool _bgRunning = false;
  bool _bgSyncing = false;
  bool _bgTried = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      BackgroundMonitor.setAppForeground(true);
      unawaited(_ensureBackgroundAlerts());
    } else if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      // Báo BG: app đang tắt/nền → phải tự bắn notification khi có alarm.
      BackgroundMonitor.setAppForeground(false);
      unawaited(_ensureBackgroundAlerts());
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_bootstrappedMqtt) return;
    _bootstrappedMqtt = true;
    final auth = context.read<AuthProvider>();
    final satlo = context.read<SatloProvider>();
    if (!satlo.mqttConnected &&
        !satlo.connecting &&
        auth.boundChip != null &&
        auth.boundChip!.isNotEmpty) {
      Future.microtask(() => satlo.connectWithChip(auth.boundChip!));
    }
    // Tự xin quyền + start FG service ngay khi vào Home — không cần bấm nút.
    if (!_bootstrappedBg) {
      _bootstrappedBg = true;
      Future.microtask(_ensureBackgroundAlerts);
    }
  }

  Future<void> _ensureBackgroundAlerts({bool showSnack = false}) async {
    if (_bgSyncing) return;
    _bgSyncing = true;
    try {
      final ok = await BackgroundMonitor.sync(enabled: true);
      final running = await BackgroundMonitor.isRunning();
      if (!mounted) return;
      setState(() {
        _bgRunning = running;
        _bgTried = true;
      });
      if (showSnack) {
        showAppSnack(
          context,
          message: ok && running
              ? 'Cảnh báo nền đang chạy — tắt app vẫn nhận khi có alarm'
              : 'Chưa bật giám sát nền — hãy cấp quyền Thông báo + bỏ tối ưu pin',
          success: ok && running,
        );
      }
    } finally {
      _bgSyncing = false;
    }
  }

  /// Thử cảnh báo qua Foreground Service (đường tắt-app thật).
  Future<void> _testAlertNow() async {
    final ok = await BackgroundMonitor.sync(
      enabled: true,
      showTestAlert: true,
    );
    final running = await BackgroundMonitor.isRunning();
    if (!mounted) return;
    setState(() {
      _bgRunning = running;
      _bgTried = true;
    });
    showAppSnack(
      context,
      message: ok && running
          ? 'Đã bắn banner thử (kiểu Facebook). Vuốt Home — thanh chạy nền phải còn.'
          : 'Chưa bật giám sát nền — cấp Thông báo + bỏ tối ưu pin, rồi thử lại.',
      success: ok && running,
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<SatloProvider>();
    final auth = context.watch<AuthProvider>();
    final size = MediaQuery.sizeOf(context);
    final name = auth.user?.name.trim() ?? '';
    final greet = name.isNotEmpty ? name.split(RegExp(r'\s+')).last : null;
    final live = s.mqttConnected && s.hasTelemetry;

    return Scaffold(
      body: Container(
        width: double.infinity,
        height: double.infinity,
        decoration: SatloTheme.screenGradient(),
        child: Stack(
          children: [
            Positioned(
              top: -size.width * 0.28,
              right: -size.width * 0.18,
              child: _orb(size.width * 0.8, SatloTheme.amber.withOpacity(0.12))
                  .animate(onPlay: (a) => a.repeat(reverse: true))
                  .scale(
                    begin: const Offset(0.94, 0.94),
                    end: const Offset(1.05, 1.05),
                    duration: 8.seconds,
                  ),
            ),
            Positioned(
              bottom: size.height * 0.1,
              left: -60,
              child: _orb(200, SatloTheme.water.withOpacity(0.1)),
            ),
            SafeArea(
              child: RefreshIndicator(
                color: SatloTheme.amber,
                backgroundColor: SatloTheme.panel,
                onRefresh: () => context.read<SatloProvider>().reconnect(),
                child: CustomScrollView(
                  physics: const AlwaysScrollableScrollPhysics(
                    parent: BouncingScrollPhysics(),
                  ),
                  slivers: [
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _TopBar(
                              live: live,
                              chipId: AppConfig.chipId,
                              onChangeDevice: () async {
                                context.read<SatloProvider>().disconnectChip();
                                await context.read<AuthProvider>().clearBoundChip();
                              },
                              onLogout: () async {
                                context.read<SatloProvider>().disconnectChip();
                                await context.read<AuthProvider>().logout();
                              },
                            ),
                            SizedBox(height: size.height * 0.02),
                            Text(
                              AppConfig.brand,
                              style: Theme.of(context)
                                  .textTheme
                                  .displayMedium
                                  ?.copyWith(
                                    fontSize: size.width > 390 ? 48 : 40,
                                  ),
                            )
                                .animate()
                                .fadeIn(duration: 420.ms)
                                .slideY(begin: 0.08),
                            const SizedBox(height: 8),
                            Text(
                              greet != null
                                  ? 'Xin chào $greet — theo dõi realtime'
                                  : AppConfig.productLine,
                              style: Theme.of(context)
                                  .textTheme
                                  .bodyLarge
                                  ?.copyWith(
                                    color: SatloTheme.water.withOpacity(0.95),
                                    fontWeight: FontWeight.w500,
                                  ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              s.statusText,
                              style: Theme.of(context)
                                  .textTheme
                                  .bodyMedium
                                  ?.copyWith(fontSize: 13),
                            ),
                            const SizedBox(height: 10),
                            Text(
                              _bgRunning
                                  ? 'Cảnh báo nền: ĐANG BẬT — có alarm sẽ tự popup (tắt app vẫn báo)'
                                  : !_bgTried
                                      ? 'Cảnh báo nền: đang tự khởi động…'
                                      : 'Cảnh báo nền: chưa chạy — mở Cài đặt cấp Thông báo + bỏ tối ưu pin',
                              style: Theme.of(context)
                                  .textTheme
                                  .bodyMedium
                                  ?.copyWith(
                                    fontSize: 13,
                                    color: _bgRunning
                                        ? SatloTheme.ok
                                        : (!_bgTried
                                            ? SatloTheme.amber
                                            : SatloTheme.danger),
                                    fontWeight: FontWeight.w600,
                                  ),
                            ),
                            const SizedBox(height: 10),
                            SizedBox(
                              width: double.infinity,
                              child: OutlinedButton.icon(
                                onPressed: _testAlertNow,
                                icon: const Icon(Icons.notifications_active_rounded),
                                label: const Text('Thử popup (tuỳ chọn)'),
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: SatloTheme.amber,
                                  side: const BorderSide(color: SatloTheme.amber),
                                  padding: const EdgeInsets.symmetric(vertical: 12),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),

                    if (s.isAlarm)
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(24, 18, 24, 0),
                          child: _AlertBanner(
                            title: s.alerts.isNotEmpty
                                ? s.alerts.first.title
                                : 'Cảnh báo sạt lở',
                            body: s.alerts.isNotEmpty
                                ? s.alerts.first.body
                                : 'Gateway đang báo động',
                          ).animate().fadeIn().shake(hz: 2, duration: 500.ms),
                        ),
                      ),

                    // Hero: lượng mưa + độ ẩm đất
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(24, 22, 24, 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Mưa & đất',
                              style: Theme.of(context)
                                  .textTheme
                                  .titleLarge
                                  ?.copyWith(fontSize: 19),
                            ),
                            const SizedBox(height: 12),
                            _HeroMetric(
                              label: 'Lượng mưa / mực nước',
                              value: s.water,
                              unit: '%',
                              accent: SatloTheme.water,
                              icon: Icons.water_drop_rounded,
                            ),
                            const SizedBox(height: 10),
                            _HeroMetric(
                              label: 'Độ ẩm đất',
                              value: s.soil,
                              unit: '%',
                              accent: SatloTheme.soil,
                              icon: Icons.grass_rounded,
                            ),
                          ],
                        ).animate().fadeIn(delay: 80.ms),
                      ),
                    ),

                    // Trạng thái kết nối
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(24, 18, 24, 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Kết nối',
                              style: Theme.of(context)
                                  .textTheme
                                  .titleLarge
                                  ?.copyWith(fontSize: 19),
                            ),
                            const SizedBox(height: 12),
                            Row(
                              children: [
                                Expanded(
                                  child: _StatusChip(
                                    label: 'LoRa',
                                    value: s.lora,
                                    ok: s.lora == 'ONLINE',
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: _StatusChip(
                                    label: 'MQTT',
                                    value: s.mqttConnected ? 'ONLINE' : 'OFFLINE',
                                    ok: s.mqttConnected,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 10),
                            _StatusChip(
                              label: 'Gateway',
                              value: s.gatewayOnline,
                              ok: s.gatewayOnline == 'ONLINE',
                            ),
                          ],
                        ),
                      ),
                    ),

                    // IMU 3 trục + góc
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(24, 18, 24, 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'IMU · 3 trục',
                              style: Theme.of(context)
                                  .textTheme
                                  .titleLarge
                                  ?.copyWith(fontSize: 19),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'Gia tốc X · Y · Z (g) và góc nghiêng',
                              style: Theme.of(context).textTheme.bodyMedium,
                            ),
                            const SizedBox(height: 14),
                            _MetricRow(
                              items: [
                                _Metric(
                                  label: 'Trục X',
                                  value: _n(s.ax, 3),
                                  unit: 'g',
                                  accent: SatloTheme.amber,
                                ),
                                _Metric(
                                  label: 'Trục Y',
                                  value: _n(s.ay, 3),
                                  unit: 'g',
                                  accent: SatloTheme.water,
                                ),
                              ],
                            ),
                            const SizedBox(height: 10),
                            _MetricRow(
                              items: [
                                _Metric(
                                  label: 'Trục Z',
                                  value: _n(s.az, 3),
                                  unit: 'g',
                                  accent: SatloTheme.ok,
                                ),
                                _Metric(
                                  label: 'Roll',
                                  value: _n(s.roll, 1),
                                  unit: '°',
                                  accent: SatloTheme.soil,
                                ),
                              ],
                            ),
                            const SizedBox(height: 10),
                            _MetricRow(
                              items: [
                                _Metric(
                                  label: 'Pitch',
                                  value: _n(s.pitch, 1),
                                  unit: '°',
                                  accent: SatloTheme.amber,
                                ),
                                _Metric(
                                  label: 'Alarm',
                                  value: s.alarm,
                                  unit: '',
                                  accent: s.isAlarm
                                      ? SatloTheme.danger
                                      : SatloTheme.ok,
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),

                    // Lịch sử cảnh báo
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(24, 20, 24, 40),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Cảnh báo gần đây',
                              style: Theme.of(context)
                                  .textTheme
                                  .titleLarge
                                  ?.copyWith(fontSize: 19),
                            ),
                            const SizedBox(height: 12),
                            if (s.alerts.isEmpty)
                              Text(
                                'Chưa có cảnh báo',
                                style: Theme.of(context).textTheme.bodyMedium,
                              )
                            else
                              ...s.alerts.take(8).map(
                                    (a) => Padding(
                                      padding: const EdgeInsets.only(bottom: 10),
                                      child: Container(
                                        width: double.infinity,
                                        padding: const EdgeInsets.all(14),
                                        decoration: BoxDecoration(
                                          color: SatloTheme.panel.withOpacity(0.9),
                                          borderRadius: BorderRadius.circular(16),
                                          border: Border.all(
                                            color: SatloTheme.amber.withOpacity(0.25),
                                          ),
                                        ),
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              a.title,
                                              style: const TextStyle(
                                                fontWeight: FontWeight.w700,
                                                color: SatloTheme.soft,
                                              ),
                                            ),
                                            const SizedBox(height: 4),
                                            Text(
                                              '${a.type} · ${a.body}',
                                              style: const TextStyle(
                                                color: SatloTheme.muted,
                                                fontSize: 13,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                            const SizedBox(height: 8),
                            Text(
                              'Chip ${AppConfig.chipId} · Kéo xuống để làm mới',
                              style: const TextStyle(
                                color: SatloTheme.muted,
                                fontSize: 12.5,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _n(double? v, int digits) =>
      v == null ? '--' : v.toStringAsFixed(digits);

  Widget _orb(double size, Color c) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(shape: BoxShape.circle, color: c),
      );
}

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.live,
    required this.chipId,
    required this.onChangeDevice,
    required this.onLogout,
  });

  final bool live;
  final String chipId;
  final VoidCallback onChangeDevice;
  final VoidCallback onLogout;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: (live ? SatloTheme.ok : SatloTheme.muted).withOpacity(0.15),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(
            children: [
              Icon(
                Icons.circle,
                size: 8,
                color: live ? SatloTheme.ok : SatloTheme.muted,
              ),
              const SizedBox(width: 6),
              Text(
                live ? 'LIVE' : 'WAIT',
                style: TextStyle(
                  color: live ? SatloTheme.ok : SatloTheme.muted,
                  fontWeight: FontWeight.w800,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            chipId,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: SatloTheme.muted, fontSize: 13),
          ),
        ),
        IconButton(
          tooltip: 'Đổi chip',
          onPressed: onChangeDevice,
          icon: const Icon(Icons.devices_other_rounded, color: SatloTheme.soft),
        ),
        IconButton(
          tooltip: 'Đăng xuất',
          onPressed: onLogout,
          icon: const Icon(Icons.logout_rounded, color: SatloTheme.soft),
        ),
      ],
    );
  }
}

class _AlertBanner extends StatelessWidget {
  const _AlertBanner({required this.title, required this.body});
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    // Banner kiểu Shopee: dải đỏ cam, chữ trắng, nổi trên nội dung.
    return Material(
      elevation: 6,
      borderRadius: BorderRadius.circular(14),
      color: const Color(0xFFEE4D2D),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          gradient: const LinearGradient(
            colors: [Color(0xFFEE4D2D), Color(0xFFFF6A3D)],
            begin: Alignment.centerLeft,
            end: Alignment.centerRight,
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.2),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(Icons.water_damage_rounded, color: Colors.white),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      color: Colors.white,
                      fontSize: 15,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    body,
                    style: TextStyle(
                      color: Colors.white.withOpacity(0.92),
                      fontSize: 13,
                      height: 1.3,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HeroMetric extends StatelessWidget {
  const _HeroMetric({
    required this.label,
    required this.value,
    required this.unit,
    required this.accent,
    required this.icon,
  });

  final String label;
  final double? value;
  final String unit;
  final Color accent;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final frac = ((value ?? 0) / 100).clamp(0.0, 1.0);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: SatloTheme.panel.withOpacity(0.92),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: accent, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(label,
                    style: const TextStyle(
                        color: SatloTheme.muted, fontWeight: FontWeight.w600)),
              ),
              Text(
                value == null ? '--' : '${value!.toStringAsFixed(1)}$unit',
                style: TextStyle(
                  color: accent,
                  fontSize: 28,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.8,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: LinearProgressIndicator(
              value: value == null ? 0 : frac,
              minHeight: 8,
              backgroundColor: Colors.white.withOpacity(0.06),
              color: accent,
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({
    required this.label,
    required this.value,
    required this.ok,
  });
  final String label;
  final String value;
  final bool ok;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: SatloTheme.panel.withOpacity(0.9),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Text(label, style: const TextStyle(color: SatloTheme.muted)),
          const Spacer(),
          Text(
            value,
            style: TextStyle(
              color: ok ? SatloTheme.ok : SatloTheme.muted,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

class _Metric {
  const _Metric({
    required this.label,
    required this.value,
    required this.unit,
    required this.accent,
  });
  final String label;
  final String value;
  final String unit;
  final Color accent;
}

class _MetricRow extends StatelessWidget {
  const _MetricRow({required this.items});
  final List<_Metric> items;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (var i = 0; i < items.length; i++) ...[
          if (i > 0) const SizedBox(width: 10),
          Expanded(child: _MetricTile(m: items[i])),
        ],
      ],
    );
  }
}

class _MetricTile extends StatelessWidget {
  const _MetricTile({required this.m});
  final _Metric m;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: SatloTheme.panel.withOpacity(0.9),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(m.label,
              style: const TextStyle(color: SatloTheme.muted, fontSize: 12.5)),
          const SizedBox(height: 6),
          RichText(
            text: TextSpan(
              children: [
                TextSpan(
                  text: m.value,
                  style: TextStyle(
                    color: m.accent,
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.5,
                  ),
                ),
                if (m.unit.isNotEmpty)
                  TextSpan(
                    text: ' ${m.unit}',
                    style: const TextStyle(
                      color: SatloTheme.muted,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
