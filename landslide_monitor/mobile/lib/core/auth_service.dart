import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'config.dart';
import 'user_model.dart';

/// Auth AloT MongoDB — cùng API thủy canh/ngưng tụ: https://duynguyen.io.vn/api
class AuthService {
  String? _token;
  String? get token => _token;

  Future<void> _save(String token, Map<String, dynamic> userJson) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('auth_token', token);
    await prefs.setString('user_data', jsonEncode(userJson));
    _token = token;
  }

  Future<UserModel?> loadSavedUser() async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('auth_token');
    final userData = prefs.getString('user_data');
    if (token == null || userData == null) return null;
    _token = token;
    return UserModel.fromJson(jsonDecode(userData));
  }

  Future<String?> loadSavedChipId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('satlo_chip_id');
  }

  Future<void> saveChipId(String chipId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('satlo_chip_id', chipId.trim());
  }

  Future<void> clearChipId() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('satlo_chip_id');
  }

  Future<UserModel> login(String email, String password) async {
    final response = await http
        .post(
          Uri.parse('${AppConfig.apiBaseUrl}/auth/login'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'email': email, 'password': password}),
        )
        .timeout(const Duration(seconds: 12));

    final data = jsonDecode(response.body);
    if (response.statusCode == 200 && data['success'] == true) {
      _token = data['data']['token'];
      await _save(_token!, Map<String, dynamic>.from(data['data']['user']));
      return UserModel.fromJson(data['data']['user']);
    }
    throw Exception(data['message'] ?? 'Đăng nhập thất bại');
  }

  Future<UserModel> register(
    String name,
    String email,
    String phone,
    String password,
  ) async {
    final response = await http
        .post(
          Uri.parse('${AppConfig.apiBaseUrl}/auth/register'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'name': name,
            'email': email,
            'phone': phone,
            'password': password,
          }),
        )
        .timeout(const Duration(seconds: 12));

    final data = jsonDecode(response.body);
    if ((response.statusCode == 201 || response.statusCode == 200) &&
        data['success'] == true) {
      _token = data['data']['token'];
      await _save(_token!, Map<String, dynamic>.from(data['data']['user']));
      return UserModel.fromJson(data['data']['user']);
    }
    throw Exception(data['message'] ?? 'Đăng ký thất bại');
  }

  Future<String> resetPassword(String email, String newPassword) async {
    final response = await http
        .post(
          Uri.parse('${AppConfig.apiBaseUrl}/auth/reset-password'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'email': email.trim(),
            'newPassword': newPassword,
          }),
        )
        .timeout(const Duration(seconds: 12));

    final data = jsonDecode(response.body);
    if (response.statusCode == 200 && data['success'] == true) {
      return data['message']?.toString() ?? 'Đặt lại mật khẩu thành công';
    }
    throw Exception(data['message'] ?? 'Không đặt lại được mật khẩu');
  }

  Future<void> logout() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('auth_token');
    await prefs.remove('user_data');
    _token = null;
  }
}
