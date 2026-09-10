import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

class BiometricAuthService {
  BiometricAuthService({LocalAuthentication? localAuthentication})
    : _localAuthentication = localAuthentication ?? LocalAuthentication();

  static const String enabledKey = 'biometric_login_enabled';
  static const String loginIdKey = 'biometric_login_id';
  static const String savedPasswordPrefix = 'saved_password_';

  final LocalAuthentication _localAuthentication;

  Future<bool> isLoginEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(enabledKey) ?? false;
  }

  Future<void> setLoginEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(enabledKey, enabled);
  }

  Future<void> saveLoginCredentials({
    required String loginId,
    required String password,
  }) async {
    final normalizedLoginId = loginId.trim();
    if (normalizedLoginId.isEmpty || password.isEmpty) {
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(enabledKey, true);
    await prefs.setString(loginIdKey, normalizedLoginId);
    await prefs.setString('$savedPasswordPrefix$normalizedLoginId', password);
  }

  Future<String?> savedLoginId() async {
    final prefs = await SharedPreferences.getInstance();
    final loginId = prefs.getString(loginIdKey)?.trim();
    return loginId == null || loginId.isEmpty ? null : loginId;
  }

  Future<String?> savedPasswordFor(String loginId) async {
    final prefs = await SharedPreferences.getInstance();
    final password = prefs.getString('$savedPasswordPrefix${loginId.trim()}');
    return password == null || password.isEmpty ? null : password;
  }

  Future<void> clearSavedLoginCredentials() async {
    final prefs = await SharedPreferences.getInstance();
    final savedLoginId = prefs.getString(loginIdKey);
    if (savedLoginId != null && savedLoginId.isNotEmpty) {
      await prefs.remove('$savedPasswordPrefix$savedLoginId');
    }
    await prefs.remove(loginIdKey);
  }

  Future<bool> canUseBiometrics() async {
    try {
      final isSupported = await _localAuthentication.isDeviceSupported();
      final canCheckBiometrics = await _localAuthentication.canCheckBiometrics;
      return isSupported && canCheckBiometrics;
    } on PlatformException {
      return false;
    }
  }

  Future<bool> authenticate({
    String reason = 'ยืนยันตัวตนด้วยลายนิ้วมือ',
  }) async {
    if (!await canUseBiometrics()) {
      return false;
    }

    try {
      return await _localAuthentication.authenticate(
        localizedReason: reason,
        options: const AuthenticationOptions(
          biometricOnly: true,
          stickyAuth: true,
        ),
      );
    } on PlatformException {
      return false;
    }
  }
}
