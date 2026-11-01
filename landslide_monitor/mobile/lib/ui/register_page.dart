import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:provider/provider.dart';

import '../core/auth_provider.dart';
import 'theme.dart';
import 'widgets/feedback.dart';

class RegisterPage extends StatefulWidget {
  const RegisterPage({super.key});

  @override
  State<RegisterPage> createState() => _RegisterPageState();
}

class _RegisterPageState extends State<RegisterPage> {
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _pass = TextEditingController();
  bool _obscure = true;

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    _pass.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final name = _name.text.trim();
    final email = _email.text.trim();
    final pass = _pass.text;

    if (name.isEmpty || email.isEmpty || pass.isEmpty) {
      showAppSnack(context, message: 'Vui lòng điền đủ tên, email và mật khẩu');
      return;
    }
    if (!email.contains('@') || !email.contains('.')) {
      showAppSnack(context, message: 'Email chưa đúng định dạng');
      return;
    }
    if (pass.length < 6) {
      showAppSnack(context, message: 'Mật khẩu cần ít nhất 6 ký tự');
      return;
    }

    final auth = context.read<AuthProvider>();
    final ok = await auth.register(name, email, pass);
    if (!mounted) return;
    if (!ok) {
      showAppSnack(context, message: auth.error ?? 'Đăng ký thất bại');
      return;
    }

    showAppSnack(context, message: 'Đăng ký thành công', success: true);
    await showSuccessDialog(
      context,
      title: 'Đăng ký thành công',
      message: 'Tài khoản đã sẵn sàng. Tiếp theo hãy kết nối Chip ID gateway.',
    );
    if (!mounted) return;
    if (Navigator.of(context).canPop()) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();

    return Scaffold(
      body: Container(
        decoration: SatloTheme.screenGradient(),
        child: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 4, 16, 0),
                child: Row(
                  children: [
                    IconButton(
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.arrow_back_rounded,
                          color: SatloTheme.soft),
                    ),
                    Text('Tạo tài khoản',
                        style: Theme.of(context).textTheme.titleLarge),
                  ],
                ),
              ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(28, 16, 28, 28),
                  children: [
                    Text(
                      'Chào mừng đến Sạt Lở IoT',
                      style: Theme.of(context)
                          .textTheme
                          .headlineMedium
                          ?.copyWith(fontSize: 28),
                    ).animate().fadeIn(),
                    const SizedBox(height: 8),
                    Text(
                      'Đăng ký tài khoản AloT để theo dõi lượng mưa, độ ẩm đất và cảnh báo.',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 24),
                    _field(_name, 'Họ tên', Icons.person_outline_rounded),
                    const SizedBox(height: 12),
                    _field(
                      _email,
                      'Email',
                      Icons.mail_outline_rounded,
                      keyboard: TextInputType.emailAddress,
                    ),
                    const SizedBox(height: 12),
                    _field(
                      _pass,
                      'Mật khẩu',
                      Icons.lock_outline_rounded,
                      obscure: _obscure,
                      suffix: IconButton(
                        onPressed: () =>
                            setState(() => _obscure = !_obscure),
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
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Text(
                                'Đăng ký',
                                style: TextStyle(fontWeight: FontWeight.w800),
                              ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _field(
    TextEditingController c,
    String label,
    IconData icon, {
    bool obscure = false,
    TextInputType? keyboard,
    Widget? suffix,
  }) {
    return TextField(
      controller: c,
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
}
