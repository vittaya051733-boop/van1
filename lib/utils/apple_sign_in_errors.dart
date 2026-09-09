import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';

import 'platform_runtime.dart';

String mapAppleSignInErrorMessage(Object error) {
  if (error is SignInWithAppleAuthorizationException) {
    switch (error.code) {
      case AuthorizationErrorCode.canceled:
        return 'ยกเลิกการเข้าสู่ระบบด้วย Apple';
      case AuthorizationErrorCode.notHandled:
        return 'อุปกรณ์ไม่รองรับ Sign in with Apple';
      case AuthorizationErrorCode.invalidResponse:
        return 'Apple ส่งข้อมูลกลับมาไม่ถูกต้อง กรุณาลองใหม่';
      case AuthorizationErrorCode.failed:
        return 'Sign in with Apple ล้มเหลว กรุณาลองใหม่';
      case AuthorizationErrorCode.notInteractive:
        return 'ไม่สามารถเปิดหน้าต่าง Sign in with Apple ได้ กรุณาลองใหม่';
      case AuthorizationErrorCode.unknown:
        if (isIosSimulator) {
          return 'บน Simulator ให้เข้า Settings → Apple ID ลงชื่อเข้าใช้ก่อน\n'
              'หรือทดสอบบน iPhone จริง';
        }
        return 'ไม่สามารถเปิด Sign in with Apple ได้ กรุณาลองใหม่';
    }
  }

  if (error is FirebaseAuthException) {
    switch (error.code) {
      case 'popup-closed-by-user':
      case 'auth/popup-closed-by-user':
        return 'ยกเลิกการเข้าสู่ระบบด้วย Apple';
      case 'invalid-credential':
      case 'auth/invalid-credential':
        if (error.message?.contains('Invalid OAuth response from apple.com') ??
            false) {
          return 'Firebase/Apple ยังไม่ตรงกัน — เช็คจุดที่มักผิด:\n'
              '• Services ID ใน Firebase ต้องเป็น Services ID (ไม่ใช่ Bundle ID)\n'
              '• Apple Services ID ต้องมี Return URL:\n'
              '  https://van-merchant.firebaseapp.com/__/auth/handler\n'
              '• Key ID ต้องตรงกับไฟล์ .p8 · Team ID: 8ZRFLUPF7H\n'
              '• โปรเจกต์ Firebase: van-merchant';
        }
        return 'Apple ID ไม่ผ่านการยืนยัน — ตรวจสอบ Firebase Console → '
            'Authentication → Sign in with Apple';
      case 'account-exists-with-different-credential':
      case 'auth/account-exists-with-different-credential':
        return 'อีเมลนี้ใช้วิธีเข้าสู่ระบบอื่นอยู่แล้ว กรุณาเข้าสู่ระบบด้วยวิธีเดิม';
      case 'operation-not-allowed':
      case 'auth/operation-not-allowed':
        return 'ยังไม่ได้เปิด Sign in with Apple ใน Firebase';
      case 'apple-auth-unavailable':
        return error.message ??
            'Sign in with Apple ยังไม่พร้อมบนอุปกรณ์นี้';
      case 'missing-id-token':
        return 'ไม่ได้รับ token จาก Apple กรุณาลองใหม่';
      case 'apple-auth-timeout':
        return error.message ??
            'Apple Sign-In ใช้เวลานานเกินไป กรุณาลองใหม่';
      default:
        return error.message ?? 'ไม่สามารถเข้าสู่ระบบด้วย Apple ได้';
    }
  }

  return 'ไม่สามารถเข้าสู่ระบบด้วย Apple ได้';
}

Future<bool> confirmAppleSignInOnSimulator(BuildContext context) async {
  if (!isIosSimulator || !context.mounted) {
    return true;
  }

  final proceed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Sign in with Apple บน Simulator'),
      content: const Text(
        'ถ้าค้างที่หน้าใส่รหัส Apple:\n\n'
        '1. เปิด Settings → Apple Account ลงชื่อเข้าใช้ก่อน\n'
        '2. ตรวจสอบเน็ต (App Check ต้องต่อ Firebase ได้)\n'
        '3. ลงทะเบียน App Check debug token ใน Firebase Console\n'
        '4. หรือทดสอบบน iPhone จริง (แนะนำ)',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('ยกเลิก'),
        ),
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: const Text('ลองต่อ'),
        ),
      ],
    ),
  );

  return proceed == true;
}

FirebaseAuthException toFirebaseAppleAuthException(
  SignInWithAppleAuthorizationException error,
) {
  if (error.code == AuthorizationErrorCode.canceled) {
    return FirebaseAuthException(
      code: 'popup-closed-by-user',
      message: 'User canceled Apple Sign-In',
    );
  }

  if (error.code == AuthorizationErrorCode.unknown && isIosSimulator) {
    return FirebaseAuthException(
      code: 'apple-auth-unavailable',
      message: mapAppleSignInErrorMessage(error),
    );
  }

  return FirebaseAuthException(
    code: 'apple-auth-failed',
    message: mapAppleSignInErrorMessage(error),
  );
}
