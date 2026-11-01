import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:provider/provider.dart';

import '../core/auth_provider.dart';
import '../core/config.dart';
import 'theme.dart';
import 'widgets/feedback.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _email = TextEditingController();
  final _pass = TextEditingController();
  bool _obscure = true;

  @override
  void dispose() {
    _email.dispose();
    _pass.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final email = _email.text.trim();
    final pass = _pass.text;
    if (email.isEmpty || pass.isEmpty) {
      showAppSnack(context, message: 'Vui lòng nhập email và mật khẩu');
      return;
    }
    final auth = context.read<AuthProvider>();
    final ok = await auth.login(email, pass);
    if (!mounted) return;
    if (!ok) {
      showAppSnack(context, message: auth.error ?? 'Đăng nhập thất bại');
      return;
    }
    showAppSnack(context, message: 'Đăng nhập thành công', success: true);
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final h = MediaQuery.sizeOf(context).height;

    return Scaffold(
      body: Container(
        width: double.infinity,
        height: double.infinity,
        decoration: SatloTheme.screenGradient(),
        child: Stack(
          children: [
            Positioned(
              top: -90,
              right: -50,
              child: _blob(240, SatloTheme.amber.withOpacity(0.14))
                  .animate(onPlay: (c) => c.repeat(reverse: true))
                  .scale(
                    begin: const Offset(0.95, 0.95),
                    end: const Offset(1.06, 1.06),
                    duration: 7.seconds,
                  ),
            ),
            Positioned(
              bottom: 50,
              left: -70,
              child: _blob(200, SatloTheme.water.withOpacity(0.1)),
            ),
            SafeArea(
              child: ListView(
                padding: EdgeInsets.fromLTRB(28, h * 0.08, 28, 28),
                children: [
                  Text(
                    AppConfig.brand,
                    style: Theme.of(context).textTheme.displayMedium?.copyWith(
                          fontSize: 46,
                        ),
                  ).animate().fadeIn().slideY(begin: 0.08),
                  const SizedBox(height: 10),
                  Text(
                    '${AppConfig.productLine}\nĐăng nhập để theo dõi lượng mưa, độ ẩm đất và IMU.',
                    style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                          color: SatloTheme.water.withOpacity(0.95),
                          fontSize: 15.5,
                        ),
                  ).animate().fadeIn(delay: 80.ms),
                  SizedBox(height: h * 0.06),
                  _field(
                    controller: _email,
                    label: 'Email',
                    icon: Icons.mail_outline_rounded,
                    keyboard: TextInputType.emailAddress,
                  ),
                  const SizedBox(height: 14),
                  _field(
                    controller: _pass,
                    label: 'Mật khẩu',
                    icon: Icons.lock_outline_rounded,
                    obscure: _obscure,
                    suffix: IconButton(
                      onPressed: () => setState(() => _obscure = !_obscure),
                      icon: Icon(
                        _obscure
                            ? Icons.visibility_outlined
                            : Icons.visibility_off_outlined,
                        color: SatloTheme.muted,
                      ),
                    ),
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
                      onPressed: auth.busy ? null : _submit,
                      child: auth.busy
                          ? const SizedBox(
                              width: 22,
                              height: 22,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text(
                              'Đăng nhập',
                              style: TextStyle(
                                fontWeight: FontWeight.w800,
                                fontSize: 16,
                              ),
                            ),
                    ),
                  ),
                  const SizedBox(height: 18),
                  Text(
                    'Tài khoản AloT · duynguyen.io.vn',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          fontSize: 12.5,
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

  Widget _field({
    required TextEditingController controller,
    required String label,
    required IconData icon,
    bool obscure = false,
    TextInputType? keyboard,
    Widget? suffix,
  }) {
    return TextField(
      controller: controller,
      obscureText: obscure,
      keyboardType: keyboard,
      style: const TextStyle(color: SatloTheme.soft),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: const TextStyle(color: SatloTheme.muted),
        prefixIcon: Icon(icon, color: SatloTheme.muted),
        suffixIcon: suffix,
        filled: true,
        fillColor: SatloTheme.panel.withOpacity(0.88),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }

  Widget _blob(double size, Color color) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(shape: BoxShape.circle, color: color),
    );
  }
}
