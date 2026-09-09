import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../services/app_unlock_session.dart';
import '../services/security_pin_service.dart';
import 'security_pin_keypad.dart';

/// Two-step PIN setup (enter + confirm). Returns true when saved successfully.
Future<bool> showSecurityPinSetupDialog(
  BuildContext context, {
  required String title,
  String subtitle = 'ตั้งรหัส PIN 6 หลักเพื่อยืนยันก่อนถอนเงิน',
}) async {
  final uid = FirebaseAuth.instance.currentUser?.uid;
  if (uid == null) {
    return false;
  }

  final keypadKey = GlobalKey<SecurityPinKeypadState>();
  var setupStep = 0;
  var pinDraft = '';
  var submitting = false;
  String? errorText;

  final completed = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) {
      return StatefulBuilder(
        builder: (context, setState) {
          Future<void> onPinCompleted(String pin) async {
            if (submitting) {
              return;
            }
            if (!SecurityPinService.instance.isValidPinFormat(pin)) {
              setState(() => errorText = 'กรุณากรอกรหัส PIN 6 หลัก');
              return;
            }

            if (setupStep == 0) {
              setState(() {
                pinDraft = pin;
                setupStep = 1;
                errorText = null;
              });
              keypadKey.currentState?.clear();
              return;
            }

            if (pinDraft != pin) {
              setState(() {
                errorText = 'รหัส PIN ไม่ตรงกัน ลองใหม่';
                setupStep = 0;
                pinDraft = '';
              });
              keypadKey.currentState?.clear();
              return;
            }

            setState(() {
              submitting = true;
              errorText = null;
            });

            await SecurityPinService.instance.setPin(uid, pinDraft);
            AppUnlockSession.unlock();

            if (!context.mounted) {
              return;
            }
            Navigator.of(context).pop(true);
          }

          final stepLabel = setupStep == 0
              ? 'ตั้งรหัส PIN 6 หลัก'
              : 'ยืนยันรหัส PIN อีกครั้ง';

          return AlertDialog(
            backgroundColor: Colors.white,
            title: Text(title),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(subtitle),
                const SizedBox(height: 8),
                Text(
                  stepLabel,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 16,
                  ),
                ),
                if (setupStep == 1) ...[
                  const SizedBox(height: 4),
                  TextButton(
                    onPressed: submitting
                        ? null
                        : () {
                            setState(() {
                              setupStep = 0;
                              pinDraft = '';
                              errorText = null;
                            });
                            keypadKey.currentState?.clear();
                          },
                    child: const Text('เปลี่ยนรหัสที่ตั้งไว้'),
                  ),
                ],
                if (errorText != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    errorText!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.red),
                  ),
                ],
                const SizedBox(height: 8),
                if (submitting)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: Center(child: CircularProgressIndicator()),
                  )
                else
                  SecurityPinKeypad(
                    key: keypadKey,
                    enabled: !submitting,
                    onCompleted: onPinCompleted,
                  ),
              ],
            ),
            actions: [
              TextButton(
                onPressed:
                    submitting ? null : () => Navigator.of(context).pop(false),
                child: const Text('ยกเลิก'),
              ),
            ],
          );
        },
      );
    },
  );

  return completed == true;
}

/// Returns true when the user entered the correct security PIN.
Future<bool> showSecurityPinVerifyDialog(
  BuildContext context, {
  required String title,
  String subtitle = 'กรุณาใส่รหัส PIN 6 หลัก',
}) async {
  final uid = FirebaseAuth.instance.currentUser?.uid;
  if (uid == null) {
    return false;
  }

  final keypadKey = GlobalKey<SecurityPinKeypadState>();
  var verifying = false;
  String? errorText;

  final verified = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) {
      return StatefulBuilder(
        builder: (context, setState) {
          Future<void> submit(String pin) async {
            if (verifying) {
              return;
            }
            if (!SecurityPinService.instance.isValidPinFormat(pin)) {
              setState(() => errorText = 'กรุณากรอกรหัส PIN 6 หลัก');
              return;
            }
            setState(() {
              verifying = true;
              errorText = null;
            });
            final ok = await SecurityPinService.instance.verifyPin(uid, pin);
            if (!context.mounted) {
              return;
            }
            if (ok) {
              Navigator.of(context).pop(true);
              return;
            }
            keypadKey.currentState?.clear();
            setState(() {
              verifying = false;
              errorText = 'รหัส PIN ไม่ถูกต้อง';
            });
          }

          return AlertDialog(
            backgroundColor: Colors.white,
            title: Text(title),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(subtitle),
                if (errorText != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    errorText!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.red),
                  ),
                ],
                const SizedBox(height: 8),
                if (verifying)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: Center(child: CircularProgressIndicator()),
                  )
                else
                  SecurityPinKeypad(
                    key: keypadKey,
                    enabled: !verifying,
                    onCompleted: submit,
                  ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: verifying
                    ? null
                    : () => Navigator.of(context).pop(false),
                child: const Text('ยกเลิก'),
              ),
            ],
          );
        },
      );
    },
  );

  return verified == true;
}

/// Guard for wallet / admin support flows.
/// First withdrawal: prompts PIN setup (enter + confirm).
/// Later: verifies existing PIN.
Future<bool> verifySecurityPinForSensitiveAction(
  BuildContext context, {
  required String title,
  String? subtitle,
}) async {
  final uid = FirebaseAuth.instance.currentUser?.uid;
  if (uid == null) {
    return false;
  }

  final hasPin = await SecurityPinService.instance.hasPin(uid);
  if (!hasPin) {
    return showSecurityPinSetupDialog(
      context,
      title: title,
      subtitle: subtitle ??
          'ตั้งรหัส PIN 6 หลักครั้งแรก — กรอกแล้วยืนยันอีกครั้งเพื่อถอนเงิน',
    );
  }

  return showSecurityPinVerifyDialog(
    context,
    title: title,
    subtitle: subtitle ?? 'กรุณาใส่รหัส PIN 6 หลัก',
  );
}
