import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'navigation_helper.dart';
import 'services/email_otp_service.dart';
import 'utils/app_colors.dart';

class EmailVerificationScreen extends StatefulWidget {
  const EmailVerificationScreen({super.key});

  @override
  State<EmailVerificationScreen> createState() =>
      _EmailVerificationScreenState();
}

class _EmailVerificationScreenState extends State<EmailVerificationScreen> {
  final TextEditingController _otpController = TextEditingController();
  bool _isSendingOtp = false;
  bool _isVerifyingOtp = false;
  String? _targetEmail;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _sendOtp(initialRequest: true);
    });
  }

  @override
  void dispose() {
    _otpController.dispose();
    super.dispose();
  }

  User? get _currentUser => FirebaseAuth.instance.currentUser;

  String? get _currentEmail => _currentUser?.email;

  Future<void> _sendOtp({bool initialRequest = false}) async {
    if (_isSendingOtp) return;

    setState(() {
      _isSendingOtp = true;
    });

    try {
      await _currentUser?.reload();
      final refreshedUser = FirebaseAuth.instance.currentUser;

      if (refreshedUser?.emailVerified == true) {
        if (!mounted) return;
        await _navigateAfterVerification(refreshedUser!);
        return;
      }

      final result = await EmailOtpService.instance.sendOtp(
        email: _currentEmail,
      );
      if (!mounted) return;

      setState(() {
        _targetEmail = result.email ?? _currentEmail;
      });

      if (!initialRequest) {
        _showSnack(
          result.alreadyVerified
              ? 'อีเมลนี้ยืนยันแล้ว'
              : 'ส่ง OTP ไปที่ ${_targetEmail ?? _currentEmail ?? "อีเมลของคุณ"} แล้ว',
          Colors.green,
        );
      }
    } catch (e) {
      if (!mounted) return;
      _showSnack(
        EmailOtpService.instance.mapError(
          e,
          fallback: 'ไม่สามารถส่ง OTP ยืนยันอีเมลได้',
        ),
        Colors.red,
      );
    } finally {
      if (mounted) {
        setState(() {
          _isSendingOtp = false;
        });
      }
    }
  }

  Future<void> _verifyOtp() async {
    final code = _otpController.text.trim();
    if (!RegExp(r'^\d{6}$').hasMatch(code)) {
      _showSnack('OTP ต้องเป็นตัวเลข 6 หลัก', Colors.red);
      return;
    }

    setState(() {
      _isVerifyingOtp = true;
    });

    try {
      final result = await EmailOtpService.instance.verifyOtp(
        code,
        email: _currentEmail,
      );
      await _currentUser?.reload();
      final refreshedUser = FirebaseAuth.instance.currentUser;

      if (!mounted) return;

      if (result.verified ||
          result.alreadyVerified ||
          refreshedUser?.emailVerified == true) {
        _showSnack('ยืนยันอีเมลสำเร็จ', Colors.green);
        await _navigateAfterVerification(refreshedUser);
        return;
      }

      _showSnack('ยังไม่สามารถยืนยันอีเมลได้ กรุณาลองอีกครั้ง', Colors.red);
    } catch (e) {
      if (!mounted) return;
      _showSnack(
        EmailOtpService.instance.mapError(
          e,
          fallback: 'เกิดข้อผิดพลาดในการตรวจสอบ OTP',
        ),
        Colors.red,
      );
    } finally {
      if (mounted) {
        setState(() {
          _isVerifyingOtp = false;
        });
      }
    }
  }

  Future<void> _navigateAfterVerification(User? user) async {
    if (!mounted || user == null) return;

    final args = ModalRoute.of(context)?.settings.arguments;
    String? serviceType;
    String? nextRoute;
    if (args is Map<String, dynamic>) {
      serviceType = args['serviceType'] as String?;
      nextRoute = args['nextRoute'] as String?;
    } else if (args is String?) {
      serviceType = args;
    }

    switch (nextRoute) {
      case 'contract':
        Navigator.of(context).pushNamedAndRemoveUntil(
          '/contract',
          (route) => false,
          arguments: serviceType,
        );
        return;
      case 'post-intro':
        Navigator.of(context).pushNamedAndRemoveUntil(
          '/post-verification-intro',
          (route) => false,
          arguments: serviceType,
        );
        return;
      case 'home':
        Navigator.of(
          context,
        ).pushNamedAndRemoveUntil('/home', (route) => false);
        return;
      default:
        await NavigationHelper.navigateBasedOnUserStatus(context, user);
    }
  }

  void _showSnack(String message, Color color) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: color,
        duration: const Duration(seconds: 5),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final emailLabel = _targetEmail ?? _currentEmail ?? 'อีเมลของคุณ';

    return Scaffold(
      appBar: AppBar(
        title: const Text('ยืนยันอีเมล'),
        automaticallyImplyLeading: false,
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Icon(
                Icons.mark_email_unread_outlined,
                size: 80,
                color: AppColors.accent,
              ),
              const SizedBox(height: 24),
              const Text(
                'กรุณายืนยันอีเมลของคุณ',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 16),
              Text(
                'เราได้ส่งรหัส OTP 6 หลักไปที่:\n$emailLabel',
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 16),
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.blue[50],
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.blue[200]!),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '📧 วิธีตรวจสอบ OTP:',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 8),
                    const Text('• ตรวจสอบกล่องจดหมายหลักก่อน'),
                    const Text('• หากยังไม่พบ ให้ดูใน Spam/Junk'),
                    const Text('• รหัสนี้ใช้ได้ภายใน 10 นาที'),
                    const Text('• กรอกรหัส 6 หลักให้ตรงกับในอีเมล'),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              TextField(
                controller: _otpController,
                keyboardType: TextInputType.number,
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(6),
                ],
                maxLength: 6,
                decoration: const InputDecoration(
                  labelText: 'รหัส OTP 6 หลัก',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.password_outlined),
                ),
              ),
              const SizedBox(height: 32),
              ElevatedButton.icon(
                onPressed: _isVerifyingOtp ? null : _verifyOtp,
                icon: _isVerifyingOtp
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.verified_outlined),
                label: Text(_isVerifyingOtp ? 'กำลังตรวจสอบ...' : 'ยืนยัน OTP'),
              ),
              const SizedBox(height: 8),
              ElevatedButton.icon(
                onPressed: _isSendingOtp ? null : _sendOtp,
                icon: _isSendingOtp
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.mail_outline),
                label: Text(
                  _isSendingOtp ? 'กำลังส่ง OTP...' : 'ส่ง OTP อีกครั้ง',
                ),
              ),
              const SizedBox(height: 8),
              TextButton.icon(
                onPressed: () {
                  Navigator.pushNamed(
                    context,
                    '/email-helper',
                    arguments: _currentEmail,
                  );
                },
                icon: const Icon(Icons.help_outline),
                label: const Text('พบปัญหา?'),
                style: TextButton.styleFrom(
                  foregroundColor: Colors.blue.shade700,
                ),
              ),

              const SizedBox(height: 16),
              TextButton(
                onPressed: () async {
                  await FirebaseAuth.instance.signOut();
                  if (!context.mounted) return;
                  Navigator.of(
                    context,
                  ).pushNamedAndRemoveUntil('/welcome', (route) => false);
                },
                child: const Text('ออกจากระบบ'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
