import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:flutter/foundation.dart';
import 'package:van1/utils/feature_flags.dart';

/// Ensures App Check token is available before financial callables.
class AppCheckGuard {
  const AppCheckGuard._();

  static String get _financialReleaseMessage {
    if (kIsWeb) {
      return 'ไม่สามารถยืนยันความปลอดภัยของอุปกรณ์ได้ กรุณารีเฟรชหน้าแล้วลองใหม่';
    }
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      return 'ไม่สามารถยืนยันความปลอดภัยของอุปกรณ์ได้ กรุณาอัปเดตแอปจาก TestFlight หรือ App Store แล้วลองใหม่';
    }
    if (defaultTargetPlatform == TargetPlatform.android) {
      return 'ไม่สามารถยืนยันความปลอดภัยของอุปกรณ์ได้ กรุณาอัปเดตแอปจาก Play Store แล้วลองใหม่';
    }
    return 'ไม่สามารถยืนยันความปลอดภัยของอุปกรณ์ได้ กรุณาอัปเดตแอปแล้วลองใหม่';
  }

  static Future<void> ensureFinancialReady() async {
    await _ensureToken(
      releaseMessage: _financialReleaseMessage,
      requiredInDebug: true,
    );
  }

  static Future<void> _ensureToken({
    required String releaseMessage,
    bool requiredInDebug = false,
  }) async {
    Object? lastError;
    for (final forceRefresh in [false, true]) {
      try {
        await FirebaseAppCheck.instance
            .getToken(forceRefresh)
            .timeout(const Duration(seconds: 8));
        return;
      } catch (error) {
        lastError = error;
      }
    }

    if (kReleaseMode || requiredInDebug) {
      if (kDebugMode && requiredInDebug) {
        throw Exception(
          'App Check ยังไม่พร้อม — ลงทะเบียน debug token ใน Firebase Console → App Check → van.merchant: $kVan1AppCheckDebugToken',
        );
      }
      throw Exception(releaseMessage);
    }
    if (kDebugMode && lastError != null) {
      debugPrint('App Check token unavailable (debug): $lastError');
    }
  }
}
