import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:provider/provider.dart';

import '../core/auth_provider.dart';
import '../core/config.dart';
import '../core/satlo_provider.dart';
import 'theme.dart';
import 'widgets/feedback.dart';

class ConnectPage extends StatefulWidget {
  const ConnectPage({super.key});

  @override
  State<ConnectPage> createState() => _ConnectPageState();
}

class _ConnectPageState extends State<ConnectPage> {
  late final TextEditingController _chip;

  @override
  void initState() {
    super.initState();
    _chip = TextEditingController(
      text: context.read<AuthProvider>().boundChip ?? AppConfig.defaultChipId,
    );
  }

  @override
  void dispose() {
    _chip.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    final id = _chip.text.trim();
    if (id.isEmpty) {
      showAppSnack(context, message: 'Nhập Chip ID gateway (vd SATLO_GW01)');
      return;
    }
    final auth = context.read<AuthProvider>();
    final satlo = context.read<SatloProvider>();
    final ok = await satlo.connectWithChip(id);
    if (!mounted) return;
    if (!ok) {
      showAppSnack(context, message: 'Chưa kết nối MQTT — thử lại');
      return;
    }
    await auth.bindChip(id);
    if (!mounted) return;
    showAppSnack(context, message: 'Đã gắn chip $id', success: true);
  }

  @override
  Widget build(BuildContext context) {
    final satlo = context.watch<SatloProvider>();
    final auth = context.watch<AuthProvider>();

    return Scaffold(
      body: Container(
        width: double.infinity,
        height: double.infinity,
        decoration: SatloTheme.screenGradient(),
        child: SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(28, 36, 28, 28),
            children: [
              Text(
                'KẾT NỐI',
                style: Theme.of(context).textTheme.displayMedium?.copyWith(
                      fontSize: 40,
                    ),
              ).animate().fadeIn(),
              const SizedBox(height: 8),
              Text(
                'Xin chào ${auth.user?.name.split(' ').last ?? ''}\nNhập Chip ID giống cấu hình gateway.',
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                      color: SatloTheme.water.withOpacity(0.95),
                    ),
              ),
              const SizedBox(height: 28),
              TextField(
                controller: _chip,
                style: const TextStyle(color: SatloTheme.soft),
                decoration: InputDecoration(
                  labelText: 'Chip ID',
                  hintText: 'SATLO_GW01',
                  labelStyle: const TextStyle(color: SatloTheme.muted),
                  filled: true,
                  fillColor: SatloTheme.panel.withOpacity(0.9),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(16),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Text(
                satlo.statusText,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 22),
              SizedBox(
                height: 54,
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: SatloTheme.amber,
                    foregroundColor: SatloTheme.deep,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                  onPressed: satlo.connecting ? null : _connect,
                  child: satlo.connecting
                      ? const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text(
                          'Tiếp tục',
                          style: TextStyle(fontWeight: FontWeight.w800),
                        ),
                ),
              ),
              TextButton(
                onPressed: () => auth.logout(),
                child: const Text('Đăng xuất', style: TextStyle(color: SatloTheme.muted)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
