import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';

import 'services/email_otp_service.dart';
import 'utils/app_colors.dart';

class EmailVerificationHelper extends StatefulWidget {
  final String? prefilledEmail;

  const EmailVerificationHelper({super.key, this.prefilledEmail});

  @override
  State<EmailVerificationHelper> createState() => _EmailVerificationHelperState();
}

class _EmailVerificationHelperState extends State<EmailVerificationHelper> {
  final TextEditingController _emailController = TextEditingController();
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    if (widget.prefilledEmail != null) {
      _emailController.text = widget.prefilledEmail!;
    }
  }

  @override
  void dispose() {
    _emailController.dispose();
    super.dispose();
  }

  User? get _currentUser => FirebaseAuth.instance.currentUser;

  Future<void> _sendOtpAgain() async {
    final email = _emailController.text.trim();
    if (email.isEmpty) {
      _showMessage('กรุณาใส่อีเมล', AppColors.accent);
      return;
    }

    final currentUserEmail = _currentUser?.email?.trim().toLowerCase();
    if (currentUserEmail == null || currentUserEmail != email.toLowerCase()) {
      _showMessage('กรุณาเข้าสู่ระบบด้วยบัญชีอีเมลนี้ก่อน แล้วค่อยขอ OTP ใหม่', Colors.red);
      return;
    }

    setState(() => _loading = true);
    try {
      await EmailOtpService.instance.sendOtp(email: email);
      _showMessage('ส่ง OTP ใหม่ไปที่ $email แล้ว', Colors.green);
    } catch (e) {
      _showMessage(
        EmailOtpService.instance.mapError(
          e,
          fallback: 'ไม่สามารถส่ง OTP ใหม่ได้',
        ),
        Colors.red,
      );
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  void _showMessage(String message, Color color) {
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
    return Scaffold(
      appBar: AppBar(
        title: const Text('🔧 ช่วยเหลือ OTP อีเมล'),
        backgroundColor: Colors.blue.shade600,
        foregroundColor: Colors.white,
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Card(
              color: Colors.blue,
              child: Padding(
                padding: EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '🎯 เครื่องมือแก้ปัญหา',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                    SizedBox(height: 8),
                    Text(
                      '• ตรวจสอบว่าใช้อีเมลถูกบัญชีหรือไม่\n'
                      '• ส่ง OTP ใหม่ไปยังอีเมลเดิม\n'
                      '• กลับไปหน้ากรอก OTP เพื่อยืนยันต่อ',
                      style: TextStyle(color: Colors.white),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _emailController,
              decoration: const InputDecoration(
                labelText: 'อีเมล',
                prefixIcon: Icon(Icons.email),
                border: OutlineInputBorder(),
                helperText: 'ใส่อีเมลที่ใช้สมัครบัญชีนี้',
              ),
              keyboardType: TextInputType.emailAddress,
            ),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: _loading ? null : _sendOtpAgain,
              icon: _loading
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.send_outlined),
              label: Text(_loading ? 'กำลังส่ง...' : 'ส่ง OTP ใหม่'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.green.shade600,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 16),
              ),
            ),
            const SizedBox(height: 12),
            ElevatedButton.icon(
              onPressed: () => Navigator.of(context).pop(),
              icon: const Icon(Icons.arrow_back),
              label: const Text('กลับไปหน้ากรอก OTP'),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.accent,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 16),
              ),
            ),
            const SizedBox(height: 24),
            const Card(
              color: AppColors.accentLight,
              child: Padding(
                padding: EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '💡 คำแนะนำ',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    SizedBox(height: 8),
                    Text(
                      '1. หากไม่ได้รับ OTP ให้ตรวจสอบ Spam/Junk\n'
                      '2. ตรวจสอบว่าอีเมลในหน้านี้ตรงกับอีเมลที่สมัคร\n'
                      '3. หากพิมพ์อีเมลผิด ให้สมัครใหม่ด้วยอีเมลที่ถูกต้อง',
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}