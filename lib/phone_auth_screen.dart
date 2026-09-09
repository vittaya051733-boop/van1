import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/services.dart';
import 'dart:async';
import 'navigation_helper.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'services/notification_service.dart';
import 'utils/app_colors.dart';
import 'utils/phone_auth_errors.dart';
import 'utils/phone_auth_config.dart';
import 'utils/phone_login_helper.dart';
import 'utils/platform_runtime.dart';

class PhoneAuthScreen extends StatefulWidget {
  const PhoneAuthScreen({super.key});

  @override
  State<PhoneAuthScreen> createState() => _PhoneAuthScreenState();
}

class _PhoneAuthScreenState extends State<PhoneAuthScreen> {
  final TextEditingController _phoneController = TextEditingController();
  final TextEditingController _otpController = TextEditingController();
  final FirebaseAuth _auth = FirebaseAuth.instance;

  bool _isLoading = false;
  bool _isOtpSent = false;
  String? _verificationId;
  int? _resendToken;
  ConfirmationResult? _webConfirmationResult;

  String? _passwordForRegistration;
  String? _serviceTypeForRegistration;
  Map<String, dynamic>? _branchAssignmentForRegistration;

  Timer? _countdownTimer;
  int _countdownSeconds = 120;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final args = ModalRoute.of(context)?.settings.arguments;

    String? phoneNumber;
    if (args is Map) {
      phoneNumber = args['phone'] as String?;
      _passwordForRegistration = args['password'] as String?;
      _serviceTypeForRegistration = args['serviceType'] as String?;
      final branchAssignment = args['branchAssignment'];
      if (branchAssignment is Map) {
        _branchAssignmentForRegistration = Map<String, dynamic>.from(
          branchAssignment,
        );
      }
    } else if (args is String) {
      phoneNumber = args;
    }

    if (phoneNumber != null && _phoneController.text.isEmpty) {
      _phoneController.text = phoneNumber;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_isOtpSent) {
          _sendOtp();
        }
      });
    } else if (_phoneController.text.isEmpty) {
      _phoneController.text = '+66';
    }
  }

  void _startCountdown() {
    _countdownTimer?.cancel();
    _countdownSeconds = 120;
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      setState(() {
        if (_countdownSeconds > 0) {
          _countdownSeconds--;
        } else {
          _countdownTimer?.cancel();
        }
      });
    });
  }

  Future<void> _sendOtp() async {
    final phoneNumber = PhoneLoginHelper.normalize(
      _phoneController.text.trim(),
    );
    if (!phoneNumber.startsWith('+')) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'รูปแบบเบอร์โทรไม่ถูกต้อง ต้องขึ้นต้นด้วย + ตามด้วยรหัสประเทศ (เช่น +66..., +81...)',
            ),
            backgroundColor: Colors.red,
          ),
        );
      }
      return;
    }
    _phoneController.text = phoneNumber;

    setState(() {
      _isLoading = true;
    });

    try {
      if (kIsWeb) {
        _webConfirmationResult = await _auth.signInWithPhoneNumber(phoneNumber);
        _markOtpSent(phoneNumber);
        return;
      }
      if (shouldDisablePhoneAppVerification) {
        await _auth.setSettings(appVerificationDisabledForTesting: true);
      }
      await _auth.verifyPhoneNumber(
        phoneNumber: phoneNumber,
        timeout: const Duration(seconds: 120),
        forceResendingToken: _resendToken,
        verificationCompleted: (credential) async {
          try {
            await _auth.signInWithCredential(credential);
            await _completePhoneAuthSuccess();
          } on FirebaseAuthException catch (error) {
            _showPhoneAuthError(error);
          }
        },
        verificationFailed: _showPhoneAuthError,
        codeSent: (verificationId, resendToken) {
          if (!mounted) return;
          _verificationId = verificationId;
          _resendToken = resendToken;
          _markOtpSent(phoneNumber);
        },
        codeAutoRetrievalTimeout: (verificationId) {
          _verificationId = verificationId;
        },
      );
    } on FirebaseAuthException catch (error) {
      _showPhoneAuthError(error);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
      });
      final message = error is FirebaseAuthException
          ? await mapPhoneAuthError(error)
          : 'ไม่สามารถส่ง OTP ได้ กรุณาลองใหม่อีกครั้ง';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  void _markOtpSent(String phoneNumber) {
    if (!mounted) return;
    setState(() {
      _isLoading = false;
      _isOtpSent = true;
    });
    _startCountdown();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('ส่ง OTP ไปที่ $phoneNumber แล้ว'),
        backgroundColor: Colors.green,
      ),
    );
  }

  void _showPhoneAuthError(FirebaseAuthException error) {
    if (!mounted) return;
    setState(() => _isLoading = false);
    mapPhoneAuthError(error).then((message) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message), backgroundColor: Colors.red),
      );
    });
  }

  Future<void> _verifyOtp() async {
    final otp = _otpController.text.trim();
    if (!RegExp(r'^\d{6}$').hasMatch(otp)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('OTP ต้องเป็นตัวเลข 6 หลัก')),
      );
      return;
    }

    if (!_isOtpSent) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('กรุณากดส่ง OTP อีกครั้งก่อนยืนยัน')),
      );
      return;
    }

    setState(() {
      _isLoading = true;
    });

    final verificationId = _verificationId;
    if (!kIsWeb && (verificationId == null || verificationId.isEmpty)) {
      setState(() => _isLoading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('เซสชัน OTP หมดอายุ กรุณาขอรหัสใหม่')),
      );
      return;
    }

    try {
      if (kIsWeb) {
        final confirmation = _webConfirmationResult;
        if (confirmation == null) {
          throw FirebaseAuthException(
            code: 'session-expired',
            message: 'เซสชัน OTP หมดอายุ กรุณาขอรหัสใหม่',
          );
        }
        await confirmation.confirm(otp);
      } else {
        final credential = PhoneAuthProvider.credential(
          verificationId: verificationId!,
          smsCode: otp,
        );
        await _auth.signInWithCredential(credential);
      }
      await _completePhoneAuthSuccess();
    } on FirebaseAuthException catch (error) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(await mapPhoneAuthError(error)),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Future<void> _completePhoneAuthSuccess() async {
    try {
      final firebaseUser = _auth.currentUser;
      if (firebaseUser == null) {
        throw Exception('ไม่พบผู้ใช้หลังยืนยัน OTP');
      }

      final normalizedPhone = PhoneLoginHelper.normalize(
        _phoneController.text.trim(),
      );
      final bool hasPassword =
          _passwordForRegistration != null &&
          _passwordForRegistration!.isNotEmpty;

      if (hasPassword) {
        final pseudoEmail = PhoneLoginHelper.pseudoEmail(normalizedPhone);
        final password = _passwordForRegistration!;
        final emailCredential = EmailAuthProvider.credential(
          email: pseudoEmail,
          password: password,
        );
        try {
          await firebaseUser.linkWithCredential(emailCredential);
        } on FirebaseAuthException catch (error) {
          if (error.code == 'provider-already-linked') {
            await firebaseUser.updatePassword(password);
          } else {
            rethrow;
          }
        }
        await FirebaseFirestore.instance
            .collection('users')
            .doc(firebaseUser.uid)
            .set({
              'loginEmail': pseudoEmail,
              'loginProvider': 'phone',
              ...?_branchAssignmentForRegistration,
            }, SetOptions(merge: true));
        _passwordForRegistration = null;
      }

      await FirebaseFirestore.instance.collection('users').doc(firebaseUser.uid).set({
        'phoneNumber': normalizedPhone,
        'phoneVerifiedAt': FieldValue.serverTimestamp(),
        ...?_branchAssignmentForRegistration,
      }, SetOptions(merge: true));

      try {
        await NotificationService().saveUserFcmToken(firebaseUser.uid);
      } catch (e) {
        debugPrint('Failed to sync FCM token after phone auth: $e');
      }

      if (_serviceTypeForRegistration != null) {
        await FirebaseFirestore.instance
            .collection('contracts')
            .doc(firebaseUser.uid)
            .set({
              'serviceType': _serviceTypeForRegistration,
              'status': 'pending_acceptance',
              ...?_branchAssignmentForRegistration,
            }, SetOptions(merge: true));
      }

      if (!mounted) return;
      setState(() {
        _isLoading = false;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('ยืนยันเบอร์โทรสำเร็จ! เข้าสู่ระบบแล้ว'),
          backgroundColor: Colors.green,
        ),
      );

      if (!mounted) return;
      await NavigationHelper.navigateBasedOnUserStatus(context, firebaseUser);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('เกิดข้อผิดพลาดในการเข้าสู่ระบบ: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        title: const Text('ยืนยันเบอร์โทร'),
        backgroundColor: AppColors.accent,
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 40),
            const Icon(Icons.phone_android, size: 80, color: AppColors.accent),
            const SizedBox(height: 24),
            Text(
              _isOtpSent ? 'ยืนยันรหัส OTP' : 'เข้าสู่ระบบด้วยเบอร์โทร',
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color: Color(0xFF2C3E50),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              _isOtpSent
                  ? 'กรุณากรอกรหัส OTP 6 หลักที่ส่งไปที่\n${_phoneController.text}'
                  : 'กรุณากรอกเบอร์โทรศัพท์เพื่อรับรหัส OTP\n(ยืนยันภายในแอป ไม่เปิดเบราว์เซอร์)',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 16, color: Colors.grey),
            ),
            const SizedBox(height: 32),
            if (isIosSimulator && shouldDisablePhoneAppVerification) ...[
              Card(
                color: Colors.orange.shade50,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(
                    'iOS Simulator: ใช้เฉพาะเบอร์ทดสอบ\n'
                    'Firebase Console → Authentication → Phone → '
                    'Phone numbers for testing\n'
                    'เช่น +66812345678 / OTP 123456',
                    style: TextStyle(
                      color: Colors.orange.shade900,
                      fontSize: 13,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),
            ],
            if (!_isOtpSent) ...[
              TextFormField(
                controller: _phoneController,
                keyboardType: TextInputType.phone,
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9+\-\s]')),
                ],
                decoration: InputDecoration(
                  labelText: 'เบอร์โทรศัพท์',
                  hintText: '+66812345678',
                  prefixIcon: const Icon(Icons.phone),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  filled: true,
                  fillColor: Colors.grey[50],
                ),
              ),
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: _isLoading ? null : _sendOtp,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.accent,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: _isLoading
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(
                          color: Colors.white,
                          strokeWidth: 2,
                        ),
                      )
                    : const Text(
                        'ส่งรหัส OTP',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
              ),
            ] else ...[
              TextFormField(
                controller: _otpController,
                keyboardType: TextInputType.number,
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(6),
                ],
                textAlign: TextAlign.center,
                maxLength: 6,
                style: const TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 8,
                ),
                decoration: InputDecoration(
                  labelText: 'รหัส OTP',
                  hintText: '123456',
                  counterText: '',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  filled: true,
                  fillColor: Colors.grey[50],
                ),
              ),
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: _isLoading ? null : _verifyOtp,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.accent,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: _isLoading
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(
                          color: Colors.white,
                          strokeWidth: 2,
                        ),
                      )
                    : const Text(
                        'ยืนยัน OTP',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
              ),
              const SizedBox(height: 16),
              TextButton(
                onPressed: (_isLoading || _countdownSeconds > 0)
                    ? null
                    : _sendOtp,
                child: Text(
                  _countdownSeconds > 0
                      ? 'ส่งรหัส OTP อีกครั้ง (${_countdownSeconds}s)'
                      : 'ส่งรหัส OTP อีกครั้ง',
                  style: TextStyle(
                    color: _countdownSeconds > 0
                        ? Colors.grey
                        : AppColors.accent,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
            const SizedBox(height: 24),
            TextButton(
              onPressed: () {
                Navigator.of(context).pop();
              },
              child: const Text(
                'กลับไปหน้าเข้าสู่ระบบ',
                style: TextStyle(
                  color: Colors.grey,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _phoneController.dispose();
    _otpController.dispose();
    _countdownTimer?.cancel();
    super.dispose();
  }
}
