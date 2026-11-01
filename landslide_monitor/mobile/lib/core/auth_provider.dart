import 'package:flutter/foundation.dart';

import 'auth_service.dart';
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
      user = await _svc.login(email, pass);
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

  Future<void> bindChip(String chipId) async {
    await _svc.saveChipId(chipId);
    boundChip = chipId.trim();
    AppConfig.setChipId(chipId);
    phase = AuthPhase.home;
    notifyListeners();
  }

  Future<void> clearBoundChip() async {
    await _svc.clearChipId();
    boundChip = null;
    phase = AuthPhase.connect;
    notifyListeners();
  }

  Future<void> logout() async {
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
}
