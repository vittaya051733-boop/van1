import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import '../utils/feature_flags.dart';

class EmailOtpSendResult {
  const EmailOtpSendResult({
    required this.alreadyVerified,
    required this.email,
    required this.expiresInSeconds,
    required this.resendAvailableInSeconds,
  });

  final bool alreadyVerified;
  final String? email;
  final int? expiresInSeconds;
  final int? resendAvailableInSeconds;
}

class EmailOtpVerifyResult {
  const EmailOtpVerifyResult({
    required this.verified,
    required this.alreadyVerified,
  });

  final bool verified;
  final bool alreadyVerified;
}

class EmailOtpService {
  EmailOtpService._();

  static final EmailOtpService instance = EmailOtpService._();
  static const String _region = 'asia-southeast1';

  FirebaseFunctions get _functions =>
      FirebaseFunctions.instanceFor(region: _region);

  Future<EmailOtpSendResult> sendOtp({String? email}) async {
    await _ensureAppCheckReady();
    final resolvedEmail = _resolveEmail(email);
    final payload = resolvedEmail == null
        ? null
        : <String, dynamic>{'email': resolvedEmail};
    final result = await _functions.httpsCallable('sendEmailOtp').call(payload);
    final data = _asMap(result.data);
    return EmailOtpSendResult(
      alreadyVerified: data['alreadyVerified'] == true,
      email: data['email'] as String? ?? resolvedEmail,
      expiresInSeconds: _toInt(data['expiresInSeconds']),
      resendAvailableInSeconds: _toInt(data['resendAvailableInSeconds']),
    );
  }

  Future<EmailOtpVerifyResult> verifyOtp(
    String code, {
    String? email,
  }) async {
    await _ensureAppCheckReady();
    final normalizedCode = code.trim();
    final payload = <String, dynamic>{'otp': normalizedCode};
    final resolvedEmail = _resolveEmail(email);
    if (resolvedEmail != null) {
      payload['email'] = resolvedEmail;
    }

    final result = await _functions.httpsCallable('verifyEmailOtp').call(payload);
    final data = _asMap(result.data);
    final verified = data['verified'] == true || data['success'] == true;
    final customToken = data['customToken'] as String?;
    if (verified && customToken != null && customToken.isNotEmpty) {
      await FirebaseAuth.instance.signInWithCustomToken(customToken);
    }

    return EmailOtpVerifyResult(
      verified: verified,
      alreadyVerified: data['alreadyVerified'] == true,
    );
  }

  String mapError(
    Object error, {
    String fallback = 'เกิดข้อผิดพลาดในการยืนยันอีเมล',
  }) {
    if (error is FirebaseFunctionsException) {
      final message = error.message?.trim();
      switch (error.code) {
        case 'unauthenticated':
          return 'กรุณาเข้าสู่ระบบใหม่แล้วลองอีกครั้ง';
        case 'permission-denied':
          return message ?? 'ไม่มีสิทธิ์ส่ง OTP ไปยังอีเมลนี้';
        case 'unavailable':
        case 'internal':
          return message ??
              'ระบบส่ง OTP อีเมลไม่พร้อม (SMTP/functions) — ลองใหม่ภายหลัง '
              'หรือใช้ Google/Apple สมัคร';
        case 'invalid-argument':
          return message ??
              'รูปแบบอีเมลไม่ถูกต้อง — ลองออกจากระบบแล้วสมัครใหม่';
        case 'deadline-exceeded':
          return message ?? 'รหัส OTP หมดอายุ กรุณาขอรหัสใหม่';
        case 'resource-exhausted':
          return message ?? 'คุณขอรหัสบ่อยเกินไป กรุณารอสักครู่';
        case 'failed-precondition':
          return message ?? 'ระบบยังไม่พร้อมส่ง OTP อีเมล';
        default:
          if (message != null &&
              message.toLowerCase().contains('app check')) {
            return 'App Check ยังไม่ผ่าน — ลงทะเบียน debug token iOS: '
                '$kVan1AppCheckDebugToken';
          }
          return message ?? fallback;
      }
    }
    return fallback;
  }

  String? _resolveEmail(String? email) {
    final trimmed = email?.trim();
    if (trimmed != null && trimmed.isNotEmpty) {
      return trimmed;
    }
    return FirebaseAuth.instance.currentUser?.email?.trim();
  }

  Future<void> _ensureAppCheckReady() async {
    try {
      await FirebaseAppCheck.instance
          .getToken(true)
          .timeout(const Duration(seconds: 8));
    } catch (error) {
      debugPrint('App Check before email OTP: $error');
    }
  }

  Map<String, dynamic> _asMap(dynamic data) {
    if (data is Map<Object?, Object?>) {
      return data.map((key, value) => MapEntry(key.toString(), value));
    }
    if (data is Map<String, dynamic>) {
      return data;
    }
    return const <String, dynamic>{};
  }

  int? _toInt(Object? value) {
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.toInt();
    }
    return int.tryParse(value?.toString() ?? '');
  }
}
