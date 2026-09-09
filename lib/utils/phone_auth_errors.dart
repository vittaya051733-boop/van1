import 'dart:io';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import 'phone_auth_config.dart';
import 'platform_runtime.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// แปลงข้อผิดพลาด Firebase Phone Auth เป็นข้อความภาษาไทย
Future<String> mapPhoneAuthError(FirebaseAuthException error) async {
  switch (error.code) {
    case 'invalid-phone-number':
      return 'เบอร์โทรศัพท์ไม่ถูกต้อง';
    case 'too-many-requests':
      return 'มีการขอ OTP มากเกินไป กรุณาลองใหม่ภายหลัง';
    case 'operation-not-allowed':
      return 'ยังไม่ได้เปิดการเข้าสู่ระบบด้วยเบอร์โทรใน Firebase';
    case 'captcha-check-failed':
      return 'ยืนยันความปลอดภัยของแอปไม่สำเร็จ กรุณาลองใหม่บนเครื่องจริง';
    case 'quota-exceeded':
      return 'โควตา SMS OTP เต็ม กรุณาลองใหม่ภายหลัง';
    case 'app-not-authorized':
      return _appNotAuthorizedMessage(error);
    case 'missing-app-credential':
      return _missingAppCredentialMessage(error);
    case 'missing-recaptcha-token':
    case 'invalid-app-credential':
      return _recaptchaTokenMissingMessage();
    default:
      return _fallbackPhoneAuthMessage(error);
  }
}

String _fallbackPhoneAuthMessage(FirebaseAuthException error) {
  final detail = (error.message ?? '').toLowerCase();
  if (detail.contains('recaptcha token is missing') ||
      detail.contains('missing a recaptcha token')) {
    return _recaptchaTokenMissingMessage();
  }
  if (detail.contains('missing a valid app identifier') ||
      detail.contains('play integrity checks') ||
      detail.contains('recaptcha checks were unsuccessful')) {
    return _missingAppCredentialMessage(error);
  }
  return error.message ?? 'เกิดข้อผิดพลาดในการส่ง OTP';
}

String _recaptchaTokenMissingMessage() {
  if (isIosSimulator && shouldDisablePhoneAppVerification) {
    return 'บน iOS Simulator ส่ง SMS จริงไม่ได้ — ใช้เบอร์ทดสอบเท่านั้น\n\n'
        'Firebase Console → Authentication → Sign-in method → Phone → '
        'Phone numbers for testing\n'
        'เพิ่มเบอร์ +66812345678 และ OTP เช่น 123456\n'
        'แล้วกรอกเบอร์นั้นในหน้าสมัคร (รูปแบบ +66...)';
  }
  if (shouldDisablePhoneAppVerification) {
    return 'ยังส่ง OTP ไม่ได้ แม้เปิดโหมดทดสอบแล้ว\n'
        'ตรวจว่าเบอร์นี้อยู่ใน Firebase Console → Authentication → Phone → '
        'Phone numbers for testing';
  }
  return 'ยังไม่ได้ตั้งค่า reCAPTCHA Enterprise สำหรับ Phone Auth\n\n'
      'แก้ใน Firebase (project van-merchant):\n'
      '1) เปิด reCAPTCHA Enterprise API ใน Google Cloud\n'
      '2) Firebase Console → Authentication → Settings (รอสร้าง key 1–2 นาที)\n\n'
      'ทดบน APK sideload ชั่วคราว:\n'
      'build ด้วย --dart-define=PHONE_AUTH_TEST_MODE=true\n'
      'และใช้เบอร์ทดสอบใน Firebase Console เท่านั้น';
}

String _missingAppCredentialMessage(FirebaseAuthException error) {
  if (isIosSimulator && kDebugMode) {
    return 'iOS Simulator ส่ง SMS OTP จริงไม่ได้ — ใช้เบอร์ทดสอบใน Firebase Console\n'
        '(Authentication → Phone → Phone numbers for testing)';
  }
  if (kDebugMode) {
    return 'ยืนยันแอปไม่ผ่าน (Play Integrity + reCAPTCHA)\n\n'
        'บน emulator/debug ต้องใช้เบอร์ทดสอบ:\n'
        'Firebase Console → Authentication → Phone → '
        'Phone numbers for testing\n'
        'เพิ่มเบอร์ +817091345342 และ OTP ที่ต้องการ (เช่น 123456)\n\n'
        'และลง App Check debug token ใน App Check → van.merchant\n'
        '(ดู APP_CHECK_SETUP.md)';
  }

  return 'ยืนยันแอปไม่ผ่าน — เปิด reCAPTCHA Enterprise API ใน Google Cloud\n'
      'แล้ว Firebase Console → Authentication → Settings\n'
      'หรือแจก APK ผ่าน Google Play Internal testing';
}

Future<String> _appNotAuthorizedMessage(FirebaseAuthException error) async {
  final detail = (error.message ?? '').toLowerCase();

  if (detail.contains('play_integrity') ||
      detail.contains('play integrity') ||
      detail.contains('play store')) {
    return 'ยืนยันแอปไม่ผ่าน (Play Integrity)\n'
        'APK ที่ sideload/ทดบน emulator มักล้มขั้นตอนนี้\n\n'
        'แก้ไข:\n'
        '1) เปิด reCAPTCHA Enterprise API ใน Google Cloud (project van-merchant)\n'
        '2) Firebase Console → Authentication → Settings → ให้ระบบสร้าง reCAPTCHA key\n'
        '3) ลง App Check debug token (ดู logcat / APP_CHECK_SETUP.md)\n'
        '4) ทด OTP จริง: ใช้มือถือจริง + APK จาก Play Store หรือ Internal testing';
  }

  if (detail.contains('recaptcha')) {
    return 'ยังไม่ได้ตั้งค่า reCAPTCHA Enterprise สำหรับ Phone Auth\n'
        'เปิด API: recaptchaenterprise.googleapis.com\n'
        'แล้วเข้า Firebase Console → Authentication → Settings';
  }

  if (!kIsWeb && Platform.isAndroid) {
    try {
      final signature = (await PackageInfo.fromPlatform()).buildSignature;
      if (signature.isNotEmpty) {
        return 'แอปยังไม่ได้รับอนุญาตจาก Firebase\n'
            'ตรวจ SHA ใน Firebase Console → Project settings → van.merchant\n'
            'SHA-256 ของ build นี้:\n$signature';
      }
    } catch (e) {
      debugPrint('Could not read Android build signature: $e');
    }
  }

  return 'แอปนี้ยังไม่ได้รับอนุญาตจาก Firebase '
      'กรุณาเพิ่ม SHA-1/SHA-256 ของ keystore ที่ใช้ build APK ใน Firebase Console';
}
