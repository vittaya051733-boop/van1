import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../services/app_unlock_session.dart';
import '../services/biometric_auth_service.dart';
import '../services/pending_top_up_session.dart';
import '../services/security_pin_service.dart';
import '../utils/app_colors.dart';
import 'security_pin_keypad.dart';

/// Blocks app content until biometric or security PIN unlock.
/// Users without a PIN can enter the app; PIN is set on first withdrawal.
class AppUnlockGate extends StatefulWidget {
  const AppUnlockGate({
    super.key,
    required this.child,
    this.logoAsset = 'assets/app_logo.png',
  });

  final Widget child;
  final String? logoAsset;

  @override
  State<AppUnlockGate> createState() => _AppUnlockGateState();
}

class _AppUnlockGateState extends State<AppUnlockGate> with WidgetsBindingObserver {
  final _biometricAuthService = BiometricAuthService();
  final _unlockKeypadKey = GlobalKey<SecurityPinKeypadState>();

  bool _loading = true;
  bool _hasPin = false;
  bool _biometricEnabled = false;
  bool _submitting = false;
  String? _errorText;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refreshState();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden) {
      if (PendingTopUpSession.isActive) return;
      AppUnlockSession.lock();
    }
  }

  Future<void> _refreshState() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      setState(() {
        _loading = false;
        _hasPin = false;
      });
      return;
    }

    final hasPin = await SecurityPinService.instance.hasPin(uid);
    final bioAvailable = !kIsWeb && await _biometricAuthService.canUseBiometrics();
    final bioEnabled = await SecurityPinService.instance.isBiometricUnlockEnabled();

    if (!mounted) {
      return;
    }

    if (!hasPin) {
      AppUnlockSession.unlock();
      setState(() {
        _loading = false;
        _hasPin = false;
        _biometricEnabled = false;
        _errorText = null;
      });
      return;
    }

    setState(() {
      _loading = false;
      _hasPin = true;
      _biometricEnabled = bioEnabled && bioAvailable;
      _errorText = null;
    });

    if (AppUnlockSession.isUnlocked) {
      return;
    }

    if (_biometricEnabled) {
      await _tryBiometricUnlock(silent: true);
    }
  }

  Future<void> _tryBiometricUnlock({bool silent = false}) async {
    if (_submitting) {
      return;
    }
    final ok = await _biometricAuthService.authenticate(
      reason: 'ยืนยันลายนิ้วมือหรือ Face ID เพื่อเข้าใช้งาน',
    );
    if (!mounted) {
      return;
    }
    if (ok) {
      AppUnlockSession.unlock();
      setState(() => _errorText = null);
      return;
    }
    if (!silent) {
      setState(() => _errorText = 'ยืนยันลายนิ้วมือหรือ Face ID ไม่สำเร็จ');
    }
  }

  Future<void> _unlockWithPin(String pin) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null || _submitting) {
      return;
    }
    if (!SecurityPinService.instance.isValidPinFormat(pin)) {
      setState(() => _errorText = 'กรุณากรอกรหัส PIN 6 หลัก');
      return;
    }

    setState(() {
      _submitting = true;
      _errorText = null;
    });

    final ok = await SecurityPinService.instance.verifyPin(uid, pin);
    if (!mounted) {
      return;
    }

    if (ok) {
      AppUnlockSession.unlock();
      _unlockKeypadKey.currentState?.clear();
      setState(() => _submitting = false);
      return;
    }

    _unlockKeypadKey.currentState?.clear();
    setState(() {
      _submitting = false;
      _errorText = 'รหัส PIN ไม่ถูกต้อง';
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    final locked = !AppUnlockSession.isUnlocked && _hasPin;
    return Stack(
      fit: StackFit.expand,
      children: [
        IgnorePointer(ignoring: locked, child: widget.child),
        if (locked) Positioned.fill(child: _buildUnlockScreen()),
      ],
    );
  }

  Widget _buildBrandMark() {
    if (widget.logoAsset != null && widget.logoAsset!.isNotEmpty) {
      return Image.asset(widget.logoAsset!, height: 96);
    }
    return Icon(Icons.storefront_outlined, size: 72, color: AppColors.accent);
  }

  Widget _buildUnlockScreen() {
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 16),
              _buildBrandMark(),
              const SizedBox(height: 20),
              const Text(
                'ปลดล็อกเพื่อเข้าใช้งาน',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 8),
              const Text(
                'ใช้ลายนิ้วมือและ Face ID หรือรหัส PIN 6 หลัก',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.black54),
              ),
              if (_biometricEnabled) ...[
                const SizedBox(height: 20),
                OutlinedButton.icon(
                  onPressed: _submitting
                      ? null
                      : () => _tryBiometricUnlock(silent: false),
                  icon: const Icon(Icons.fingerprint),
                  label: const Text('เข้าใช้งานด้วยลายนิ้วมือหรือ Face ID'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.accent,
                    side: const BorderSide(color: AppColors.accent),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                ),
                const SizedBox(height: 12),
                const Text('หรือใส่รหัส PIN', textAlign: TextAlign.center),
              ],
              if (_errorText != null) ...[
                const SizedBox(height: 12),
                Text(
                  _errorText!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.red),
                ),
              ],
              const SizedBox(height: 8),
              Expanded(
                child: _submitting
                    ? const Center(child: CircularProgressIndicator())
                    : SecurityPinKeypad(
                        key: _unlockKeypadKey,
                        enabled: !_submitting,
                        onCompleted: _unlockWithPin,
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
