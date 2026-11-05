import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'auth_service.dart';
import 'background_monitor.dart';
import 'config.dart';
import 'user_model.dart';

enum AuthPhase { loading, login, connect, home }

class AuthProvider extends ChangeNotifier {
  final _svc = AuthService();
  UserModel? user;
  AuthPhase phase = AuthPhase.loading;
  String? error;
  bool busy = false;
  String? _successBanner;
  String? boundChip;

  Future<void> bootstrap() async {
    phase = AuthPhase.loading;
    notifyListeners();
    try {
      user = await _svc.loadSavedUser();
      boundChip = await _svc.loadSavedChipId();
      if (boundChip != null && boundChip!.isNotEmpty) {
        AppConfig.setChipId(boundChip!);
      }
      if (user == null) {
        phase = AuthPhase.login;
      } else if (boundChip == null || boundChip!.isEmpty) {
        phase = AuthPhase.connect;
      } else {
        phase = AuthPhase.home;
        // Không start service ở đây — phải đợi Home có UI mới xin quyền được
      }
    } catch (_) {
      phase = AuthPhase.login;
    }
    notifyListeners();
  }

  Future<bool> login(String email, String pass) async {
    busy = true;
    error = null;
    notifyListeners();
    try {
      user = await _svc.login(email.trim(), pass);
      phase = AuthPhase.connect;
      _successBanner = 'Đăng nhập thành công';
      busy = false;
      notifyListeners();
      return true;
    } catch (e) {
      error = e.toString().replaceFirst('Exception: ', '');
      busy = false;
      notifyListeners();
      return false;
    }
  }

  Future<bool> register(String name, String email, String password) async {
    busy = true;
    error = null;
    notifyListeners();
    try {
      final phone = _randomPhone();
      user = await _svc.register(name.trim(), email.trim(), phone, password);
      phase = AuthPhase.connect;
      _successBanner = 'Đăng ký thành công';
      busy = false;
      notifyListeners();
      return true;
    } catch (e) {
      error = e.toString().replaceFirst('Exception: ', '');
      busy = false;
      notifyListeners();
      return false;
    }
  }

  Future<bool> resetPassword(String email, String newPassword) async {
    busy = true;
    error = null;
    notifyListeners();
    try {
      await _svc.resetPassword(email.trim(), newPassword);
      busy = false;
      notifyListeners();
      return true;
    } catch (e) {
      error = e.toString().replaceFirst('Exception: ', '');
      busy = false;
      notifyListeners();
      return false;
    }
  }

  Future<void> bindChip(String chipId) async {
    await _svc.saveChipId(chipId);
    boundChip = chipId.trim();
    AppConfig.setChipId(chipId);
    phase = AuthPhase.home;
    notifyListeners();
    // Tự bật giám sát nền — không cần bấm nút thử; cảnh báo chỉ khi có alarm thật.
    await BackgroundMonitor.sync(enabled: true);
  }

  Future<void> clearBoundChip() async {
    await BackgroundMonitor.sync(enabled: false);
    await _svc.clearChipId();
    boundChip = null;
    phase = AuthPhase.connect;
    notifyListeners();
  }

  Future<void> logout() async {
    await BackgroundMonitor.sync(enabled: false);
    await _svc.logout();
    await _svc.clearChipId();
    user = null;
    boundChip = null;
    phase = AuthPhase.login;
    notifyListeners();
  }

  String? consumeSuccessBanner() {
    final m = _successBanner;
    _successBanner = null;
    return m;
  }

  String _randomPhone() {
    final r = Random();
    return '09${r.nextInt(100000000).toString().padLeft(8, '0')}';
  }
}
