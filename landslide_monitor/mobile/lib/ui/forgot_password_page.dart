import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/auth_provider.dart';
import 'theme.dart';
import 'widgets/feedback.dart';

class ForgotPasswordPage extends StatefulWidget {
  const ForgotPasswordPage({super.key});

  @override
  State<ForgotPasswordPage> createState() => _ForgotPasswordPageState();
}

class _ForgotPasswordPageState extends State<ForgotPasswordPage> {
  final _email = TextEditingController();
  final _pass = TextEditingController();
  final _confirm = TextEditingController();
  bool _obscure = true;

  @override
  void dispose() {
    _email.dispose();
    _pass.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final email = _email.text.trim();
    final pass = _pass.text;
    final confirm = _confirm.text;

    if (email.isEmpty || pass.isEmpty || confirm.isEmpty) {
      showAppSnack(context, message: 'Vui lòng điền đủ email và mật khẩu mới');
      return;
    }
    if (!email.contains('@') || !email.contains('.')) {
      showAppSnack(context, message: 'Email chưa đúng định dạng');
      return;
    }
    if (pass.length < 6) {
      showAppSnack(context, message: 'Mật khẩu mới cần ít nhất 6 ký tự');
      return;
    }
    if (pass != confirm) {
      showAppSnack(context, message: 'Mật khẩu xác nhận chưa khớp');
      return;
    }

    final auth = context.read<AuthProvider>();
    final ok = await auth.resetPassword(email, pass);
    if (!mounted) return;
    if (ok) {
      showAppSnack(context, message: 'Đặt lại mật khẩu thành công', success: true);
      await showSuccessDialog(
        context,
        title: 'Đặt lại mật khẩu thành công',
        message: 'Bạn có thể đăng nhập bằng mật khẩu mới.',
      );
      if (mounted && Navigator.of(context).canPop()) {
        Navigator.of(context).pop(true);
      }
    } else {
      showAppSnack(context, message: auth.error ?? 'Không đặt lại được mật khẩu');
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();

    return Scaffold(
      body: Container(
        width: double.infinity,
        height: double.infinity,
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
                    Text('Quên mật khẩu',
                        style: Theme.of(context).textTheme.titleLarge),
                  ],
                ),
              ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(28, 16, 28, 28),
                  children: [
                    Text(
                      'Đặt lại mật khẩu AloT',
                      style: Theme.of(context)
                          .textTheme
                          .headlineMedium
                          ?.copyWith(fontSize: 26),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Nhập email đã đăng ký và mật khẩu mới.',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 24),
                    _field(
                      _email,
                      'Email',
                      Icons.mail_outline_rounded,
                      keyboard: TextInputType.emailAddress,
                    ),
                    const SizedBox(height: 12),
                    _field(
                      _pass,
                      'Mật khẩu mới',
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
                    const SizedBox(height: 12),
                    _field(
                      _confirm,
                      'Xác nhận mật khẩu',
                      Icons.lock_outline_rounded,
                      obscure: _obscure,
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
                                'Đặt lại mật khẩu',
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
