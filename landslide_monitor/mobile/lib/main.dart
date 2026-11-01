import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'core/auth_provider.dart';
import 'core/notifications.dart';
import 'core/satlo_provider.dart';
import 'ui/connect_page.dart';
import 'ui/home_page.dart';
import 'ui/login_page.dart';
import 'ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
    ),
  );
  runApp(const LandslideApp());
  unawaited(SatloNotifications.init());
}

class LandslideApp extends StatefulWidget {
  const LandslideApp({super.key});

  @override
  State<LandslideApp> createState() => _LandslideAppState();
}

class _LandslideAppState extends State<LandslideApp> {
  late final AuthProvider _auth = AuthProvider()..bootstrap();
  late final SatloProvider _satlo = SatloProvider();

  @override
  void dispose() {
    _satlo.dispose();
    _auth.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: _auth),
        ChangeNotifierProvider.value(value: _satlo),
      ],
      child: MaterialApp(
        title: 'Cảnh báo Sạt lở',
        debugShowCheckedModeBanner: false,
        theme: SatloTheme.dark(),
        home: const _RootGate(),
      ),
    );
  }
}

class _RootGate extends StatelessWidget {
  const _RootGate();

  @override
  Widget build(BuildContext context) {
    final phase = context.watch<AuthProvider>().phase;
    switch (phase) {
      case AuthPhase.loading:
        return Scaffold(
          body: Container(
            decoration: SatloTheme.screenGradient(),
            child: const Center(
              child: CircularProgressIndicator(color: SatloTheme.amber),
            ),
          ),
        );
      case AuthPhase.login:
        return const LoginPage();
      case AuthPhase.connect:
        return const ConnectPage();
      case AuthPhase.home:
        return const HomePage();
    }
  }
}
