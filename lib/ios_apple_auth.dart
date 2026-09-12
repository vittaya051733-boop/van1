import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';

import 'utils/apple_sign_in_errors.dart';
import 'utils/platform_runtime.dart';

/// Native Sign in with Apple on iOS → Firebase Auth.
Future<UserCredential> signInWithAppleForIos() async {
  const appleSheetTimeout = Duration(minutes: 3);

  final isAvailable = await SignInWithApple.isAvailable();
  if (!isAvailable) {
    throw FirebaseAuthException(
      code: 'apple-auth-unavailable',
      message: isIosSimulator
          ? 'บน Simulator ให้เข้า Settings → Apple ID ลงชื่อเข้าใช้ก่อน\n'
                'หรือทดสอบบน iPhone จริง'
          : 'อุปกรณ์นี้ยังไม่รองรับ Sign in with Apple',
    );
  }

  final rawNonce = _generateNonce();
  final nonce = _sha256ofString(rawNonce);

  try {
    debugPrint('🍎 Opening Apple Sign-In sheet...');
    final appleCredential =
        await SignInWithApple.getAppleIDCredential(
          scopes: <AppleIDAuthorizationScopes>[
            AppleIDAuthorizationScopes.email,
            AppleIDAuthorizationScopes.fullName,
          ],
          nonce: nonce,
        ).timeout(
          appleSheetTimeout,
          onTimeout: () {
            throw FirebaseAuthException(
              code: 'apple-auth-timeout',
              message: isIosSimulator
                  ? 'Apple Sign-In ใช้เวลานานเกินไป — ลองลงชื่อ Apple ID ใน Settings ก่อน '
                        'หรือทดสอบบน iPhone จริง'
                  : 'Apple Sign-In ใช้เวลานานเกินไป กรุณาลองใหม่',
            );
          },
        );
    debugPrint('🍎 Apple sheet completed — exchanging token with Firebase...');

    final identityToken = appleCredential.identityToken;
    if (identityToken == null || identityToken.isEmpty) {
      throw FirebaseAuthException(
        code: 'missing-id-token',
        message: 'Apple identity token is missing',
      );
    }

    _debugLogAppleIdentityTokenClaims(identityToken);

    final authorizationCode = appleCredential.authorizationCode;
    final userCredential = await _exchangeAppleCredentialWithFirebase(
      identityToken: identityToken,
      rawNonce: rawNonce,
      authorizationCode: authorizationCode,
    );
    debugPrint('🍎 Firebase Apple sign-in OK: ${userCredential.user?.uid}');

    final givenName = appleCredential.givenName?.trim();
    final familyName = appleCredential.familyName?.trim();
    final displayName = <String>[
      if (givenName != null && givenName.isNotEmpty) givenName,
      if (familyName != null && familyName.isNotEmpty) familyName,
    ].join(' ');

    final user = userCredential.user;
    if (displayName.isNotEmpty &&
        user != null &&
        (user.displayName == null || user.displayName!.trim().isEmpty)) {
      await user.updateDisplayName(displayName);
    }

    return userCredential;
  } on SignInWithAppleAuthorizationException catch (error) {
    debugPrint('Apple authorization failed: ${error.code} ${error.message}');
    throw toFirebaseAppleAuthException(error);
  } on FirebaseAuthException catch (error) {
    debugPrint('Firebase Apple sign-in failed: ${error.code} ${error.message}');
    rethrow;
  }
}

Future<String> requestAppleAuthorizationCodeForTokenRevocation() async {
  const appleSheetTimeout = Duration(minutes: 3);

  final isAvailable = await SignInWithApple.isAvailable();
  if (!isAvailable) {
    throw FirebaseAuthException(
      code: 'apple-auth-unavailable',
      message: isIosSimulator
          ? 'บน Simulator ให้เข้า Settings → Apple ID ลงชื่อเข้าใช้ก่อน\n'
                'หรือทดสอบบน iPhone จริง'
          : 'อุปกรณ์นี้ยังไม่รองรับ Sign in with Apple',
    );
  }

  final appleCredential =
      await SignInWithApple.getAppleIDCredential(
        scopes: const <AppleIDAuthorizationScopes>[],
      ).timeout(
        appleSheetTimeout,
        onTimeout: () {
          throw FirebaseAuthException(
            code: 'apple-auth-timeout',
            message: 'Apple Sign-In ใช้เวลานานเกินไป กรุณาลองใหม่',
          );
        },
      );

  final authorizationCode = appleCredential.authorizationCode.trim();
  if (authorizationCode.isEmpty) {
    throw FirebaseAuthException(
      code: 'missing-authorization-code',
      message: 'ไม่พบรหัสยืนยันจาก Apple สำหรับยกเลิกสิทธิ์บัญชี',
    );
  }
  return authorizationCode;
}

Future<UserCredential> _exchangeAppleCredentialWithFirebase({
  required String identityToken,
  required String rawNonce,
  String? authorizationCode,
}) async {
  const firebaseAuthTimeout = Duration(seconds: 45);

  try {
    final appCheckToken = await FirebaseAppCheck.instance
        .getToken(true)
        .timeout(const Duration(seconds: 8));
    debugPrint(
      '🍎 App Check token ready (${appCheckToken?.length ?? 0} chars)',
    );
  } catch (e) {
    debugPrint('❌ App Check token failed (ลงทะเบียน iOS debug token ก่อน): $e');
  }

  Future<UserCredential> attempt({required bool includeAuthCode}) {
    final credential = OAuthProvider('apple.com').credential(
      idToken: identityToken,
      rawNonce: rawNonce,
      accessToken: includeAuthCode ? authorizationCode : null,
    );
    return FirebaseAuth.instance
        .signInWithCredential(credential)
        .timeout(
          firebaseAuthTimeout,
          onTimeout: () {
            throw FirebaseAuthException(
              code: 'apple-auth-timeout',
              message:
                  'ยืนยัน Apple กับ Firebase ใช้เวลานานเกินไป — '
                  'ตรวจสอบเน็ตและ App Check debug token',
            );
          },
        );
  }

  try {
    return await attempt(includeAuthCode: false);
  } on FirebaseAuthException catch (error) {
    final canRetry =
        (error.code == 'invalid-credential' ||
            error.code == 'auth/invalid-credential') &&
        authorizationCode != null &&
        authorizationCode.isNotEmpty;
    if (!canRetry) {
      rethrow;
    }
    debugPrint('🍎 Retrying Apple Firebase auth with authorizationCode...');
    return attempt(includeAuthCode: true);
  }
}

void _debugLogAppleIdentityTokenClaims(String identityToken) {
  if (!kDebugMode) {
    return;
  }
  try {
    final parts = identityToken.split('.');
    if (parts.length < 2) {
      return;
    }
    final normalized = base64Url.normalize(parts[1]);
    final payload = jsonDecode(utf8.decode(base64Url.decode(normalized)));
    if (payload is Map) {
      debugPrint(
        '🍎 Apple idToken claims: aud=${payload['aud']} iss=${payload['iss']} '
        'sub=${payload['sub']}',
      );
      debugPrint(
        '🍎 คาดหวัง aud=com.vantalad.merchant (Bundle ID) · Firebase project=van-merchant',
      );
    }
  } catch (e) {
    debugPrint('Could not decode Apple idToken claims: $e');
  }
}

String _generateNonce([int length = 32]) {
  const charset =
      '0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._';
  final random = Random.secure();
  return List<String>.generate(
    length,
    (_) => charset[random.nextInt(charset.length)],
  ).join();
}

String _sha256ofString(String input) {
  final bytes = utf8.encode(input);
  return sha256.convert(bytes).toString();
}
