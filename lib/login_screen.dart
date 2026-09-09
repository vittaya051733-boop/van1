import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'navigation_helper.dart';
import 'utils/apple_sign_in_errors.dart';
import 'utils/app_colors.dart';
import 'utils/phone_login_helper.dart';
import 'apple_auth.dart';
import 'web_apple_auth.dart';
import 'web_google_auth.dart';

class LoginScreen extends StatefulWidget {
  final String? serviceType;
  const LoginScreen({super.key, this.serviceType});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  static const String _androidServerClientId = String.fromEnvironment(
    'GOOGLE_ANDROID_SERVER_CLIENT_ID',
    defaultValue:
        '802503541368-6sh9d08648ctf3e6ujlsd8l8400uu0ej.apps.googleusercontent.com',
  );

  static const String _iosClientId = String.fromEnvironment(
    'GOOGLE_IOS_CLIENT_ID',
    defaultValue:
        '802503541368-p2okrn2l0ic0rm26j7f7va6pgmdisutk.apps.googleusercontent.com',
  );

  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  bool _isLoading = false;
  bool _isSocialLoading = false;
  bool _isPasswordVisible = false;
  String? _socialLoadingKey;

  @override
  void initState() {
    super.initState();
    if (kIsWeb) {
      unawaited(_handleWebOAuthRedirectResult());
    }
  }

  Future<void> _handleWebOAuthRedirectResult() async {
    try {
      final result = await handleWebOAuthRedirectResult();
      if (result?.user == null || !mounted) {
        return;
      }
      await _handlePostLogin();
    } on FirebaseAuthException catch (error) {
      if (!mounted) {
        return;
      }
      if (error.code != 'auth/redirect-initiated' &&
          error.code != 'redirect-initiated') {
        _showSnack('ไม่สามารถเข้าสู่ระบบด้วย Apple/Google ได้ (${error.code})');
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _signInWithEmailOrPhone() async {
    final input = _emailController.text.trim();
    final password = _passwordController.text;
    if (input.isEmpty || password.isEmpty) {
      _showSnack('กรอกข้อมูลให้ครบถ้วน');
      return;
    }

    // เช็คว่าเป็นเบอร์โทรหรือไม่
    final isPhone = RegExp(r'^\+?[0-9]{9,}$').hasMatch(input);
    if (isPhone) {
      setState(() => _isLoading = true);
      try {
        final normalizedPhone = PhoneLoginHelper.normalize(input);
        final loginEmail = PhoneLoginHelper.pseudoEmail(normalizedPhone);
        await FirebaseAuth.instance.signInWithEmailAndPassword(
          email: loginEmail,
          password: password,
        );
        if (!mounted) return;
        setState(() => _isLoading = false);
        await _handlePostLogin();
        return;
      } on FirebaseAuthException catch (e) {
        if (!mounted) return;
        setState(() => _isLoading = false);
        if (e.code == 'user-not-found' ||
            e.code == 'invalid-credential' ||
            e.code == 'wrong-password') {
          _showSnack('เบอร์โทรหรือรหัสผ่านไม่ถูกต้อง');
        } else {
          _showSnack(e.message ?? 'เข้าสู่ระบบด้วยเบอร์โทรไม่สำเร็จ');
        }
        return;
      }
    }

    // ไม่ต้องเช็คว่า user exists หรือยัง ให้ลองล็อกอินเลย
    // ถ้าไม่มี Firebase Auth จะ error เอง
    // แต่จะเช็คการลงทะเบียนร้านใน _handlePostLogin() แทน
    setState(() => _isLoading = true);
    try {
      final userCredential = await FirebaseAuth.instance
          .signInWithEmailAndPassword(email: input, password: password);
      final user = userCredential.user;

      if (user == null) {
        throw Exception('ไม่พบข้อมูลผู้ใช้หลังเข้าสู่ระบบ');
      }

      // ไม่บังคับยืนยันอีเมลในขั้นตอนล็อกอิน (ตามที่ผู้ใช้กำหนด)

      // เช็คการลงทะเบียนร้านหลังล็อกอินสำเร็จ
      if (!mounted) return; // use_build_context_synchronously
      setState(() => _isLoading = false);
      await _handlePostLogin();
    } on FirebaseAuthException catch (e) {
      // use_build_context_synchronously
      if (!mounted) return;
      String message = 'ไม่สามารถเข้าสู่ระบบได้';
      if (e.code == 'user-not-found') {
        message = 'ไม่พบผู้ใช้นี้ในระบบ กรุณาลงทะเบียนก่อน';
      } else if (e.code == 'wrong-password') {
        message = 'รหัสผ่านไม่ถูกต้อง';
      } else if (e.code == 'invalid-email') {
        message = 'รูปแบบอีเมลไม่ถูกต้อง';
      } else if (e.code == 'user-disabled') {
        message = 'บัญชีนี้ถูกปิดการใช้งาน';
      }
      _showSnack(message);
      setState(() => _isLoading = false);
    }
  }

  Future<void> _signInWithGoogle() async {
    setState(() {
      _isSocialLoading = true;
      _socialLoadingKey = 'google';
    });

    try {
      if (kIsWeb) {
        await signInWithGoogleForWeb();
        if (!mounted) return;
        await _handlePostLogin();
        return;
      }

      if (defaultTargetPlatform == TargetPlatform.android &&
          _androidServerClientId.isEmpty) {
        throw StateError('ยังไม่ได้ตั้งค่า GOOGLE_ANDROID_SERVER_CLIENT_ID');
      }
      if (defaultTargetPlatform == TargetPlatform.iOS && _iosClientId.isEmpty) {
        throw StateError('ยังไม่ได้ตั้งค่า GOOGLE_IOS_CLIENT_ID');
      }
      debugPrint(
        'GoogleSignIn initialize (Android=${defaultTargetPlatform == TargetPlatform.android}) with serverClientId=$_androidServerClientId',
      );
      final googleSignIn = GoogleSignIn.instance;
      await googleSignIn.initialize(
        serverClientId: defaultTargetPlatform == TargetPlatform.android
            ? _androidServerClientId
            : null,
        clientId: defaultTargetPlatform == TargetPlatform.iOS ? _iosClientId : null,
      ).timeout(const Duration(seconds: 20));
      if (!googleSignIn.supportsAuthenticate()) {
        throw Exception('แพลตฟอร์มนี้ไม่รองรับ Google Sign-In');
      }

      final googleUser = await googleSignIn.authenticate().timeout(
        const Duration(seconds: 90),
      );
      final googleAuth = googleUser.authentication;
      final idToken = googleAuth.idToken;
      if (idToken == null || idToken.isEmpty) {
        throw FirebaseAuthException(
          code: 'missing-id-token',
          message: 'ไม่พบ Google ID token',
        );
      }

      final credential = GoogleAuthProvider.credential(idToken: idToken);
      await FirebaseAuth.instance.signInWithCredential(credential);

      if (!mounted) return;
      await _handlePostLogin();
    } on GoogleSignInException catch (e) {
      if (e.code != GoogleSignInExceptionCode.canceled) {
        debugPrint('Google sign-in failed: ${e.code} ${e.description ?? ''}');
        _showSnack('ไม่สามารถเข้าสู่ระบบด้วย Google ได้ (${e.code.name})');
      }
    } on StateError catch (e) {
      debugPrint('Google sign-in configuration error: ${e.message}');
      _showSnack('ตั้งค่า Google Sign-In ไม่ครบ: ${e.message}');
    } on FirebaseAuthException catch (e) {
      debugPrint('Firebase sign-in failed: ${e.code}');
      _showSnack('ไม่สามารถเข้าสู่ระบบด้วย Google ได้ (${e.code})');
    } catch (e) {
      debugPrint('Unexpected Google sign-in error: $e');
      _showSnack('ไม่สามารถเข้าสู่ระบบด้วย Google ได้');
    } finally {
      if (mounted) {
        setState(() {
          _isSocialLoading = false;
          _socialLoadingKey = null;
        });
      }
    }
  }

  Future<void> _signInWithApple() async {
    setState(() {
      _isSocialLoading = true;
      _socialLoadingKey = 'apple';
    });

    try {
      if (!await confirmAppleSignInOnSimulator(context)) return;

      await signInWithApple();
      if (!mounted) {
        return;
      }
      await _handlePostLogin();
    } on FirebaseAuthException catch (e) {
      if (e.code == 'popup-closed-by-user' ||
          e.code == 'redirect-initiated' ||
          e.code == 'auth/redirect-initiated') {
        return;
      }
      debugPrint('Apple sign-in failed: ${e.code}');
      _showSnack(mapAppleSignInErrorMessage(e));
    } catch (e) {
      debugPrint('Unexpected Apple sign-in error: $e');
      _showSnack(mapAppleSignInErrorMessage(e));
    } finally {
      if (mounted) {
        setState(() {
          _isSocialLoading = false;
          _socialLoadingKey = null;
        });
      }
    }
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _handlePostLogin() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    try {
      final email = user.email;
      if (email == null || email.isEmpty) {
        if (!mounted) return;
        await FirebaseAuth.instance.signOut();
        _showSnack('บัญชีนี้ไม่มีอีเมล ไม่สามารถตรวจสอบการลงทะเบียนร้านค้าได้');
        Navigator.of(
          context,
        ).pushNamedAndRemoveUntil('/welcome', (route) => false);
        return;
      }

      // ตรวจสอบว่าเคยลงทะเบียนร้านหรือยัง
      final eligible = await NavigationHelper.isShopRegisteredByEmail(email)
          .timeout(const Duration(seconds: 12));
      if (!mounted) return;
      if (!eligible) {
        // ถ้ายังไม่เคยลงทะเบียนร้าน → ออกจากระบบและกลับไปหน้า welcome
        await FirebaseAuth.instance.signOut();
        _showSnack('กรุณาลงทะเบียนร้านค้าก่อนเข้าสู่ระบบ');
        Navigator.of(
          context,
        ).pushNamedAndRemoveUntil('/welcome', (route) => false);
        return;
      }
      // ถ้าเคยลงทะเบียนแล้ว → เข้าสู่ระบบได้
      Navigator.of(context).pushNamedAndRemoveUntil('/home', (route) => false);
    } on TimeoutException {
      debugPrint('Post-login shop lookup timed out; continuing to home');
      if (!mounted) return;
      Navigator.of(context).pushNamedAndRemoveUntil('/home', (route) => false);
    } catch (e) {
      debugPrint('Post-login eligibility check failed: $e');
      if (!mounted) return;
      await FirebaseAuth.instance.signOut();
      _showSnack('เกิดข้อผิดพลาดในการตรวจสอบข้อมูล');
      Navigator.of(
        context,
      ).pushNamedAndRemoveUntil('/welcome', (route) => false);
    }
  }

  Widget _socialButton({
    required VoidCallback? onPressed,
    required String label,
    required Color backgroundColor,
    required Color foregroundColor,
    required String buttonKey,
    String? assetSvg,
    String? assetImage,
    IconData? icon,
  }) {
    final isLoading = _isSocialLoading && _socialLoadingKey == buttonKey;
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton.icon(
        onPressed: (_isLoading || _isSocialLoading)
            ? null
            : onPressed,
        style: ElevatedButton.styleFrom(
          backgroundColor: backgroundColor,
          foregroundColor: foregroundColor,
          padding: const EdgeInsets.symmetric(vertical: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          elevation: 2,
          side: BorderSide(color: Colors.grey.shade300),
        ),
        icon: isLoading
            ? SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation<Color>(foregroundColor),
                ),
              )
            : (assetImage != null
                  ? Image.asset(
                      assetImage,
                      width: 22,
                      height: 22,
                      fit: BoxFit.contain,
                    )
                  : assetSvg != null
                  ? SvgPicture.asset(assetSvg, height: 22, width: 22)
                  : Icon(icon, size: 22, color: foregroundColor)),
        label: Text(
          label,
          style: TextStyle(
            fontSize: 16,
            color: foregroundColor,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        title: const Text('เข้าสู่ระบบ'),
        backgroundColor: AppColors.accent,
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const _LoginHeader(),
            TextFormField(
              controller: _emailController,
              keyboardType: TextInputType.text,
              textInputAction: TextInputAction.next,
              autofillHints: const [
                AutofillHints.username,
                AutofillHints.email,
              ],
              decoration: InputDecoration(
                labelText: 'อีเมลหรือเบอร์โทร',
                hintText: 'user@example.com หรือ 0812345678',
                prefixIcon: const Icon(Icons.account_circle),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                filled: true,
                fillColor: Colors.grey[50],
              ),
              onFieldSubmitted: (_) => FocusScope.of(context).nextFocus(),
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _passwordController,
              obscureText: !_isPasswordVisible,
              textInputAction: TextInputAction.done,
              autofillHints: const [AutofillHints.password],
              decoration: InputDecoration(
                labelText: 'รหัสผ่าน',
                prefixIcon: const Icon(Icons.lock),
                suffixIcon: IconButton(
                  icon: Icon(
                    _isPasswordVisible
                        ? Icons.visibility
                        : Icons.visibility_off,
                  ),
                  onPressed: () =>
                      setState(() => _isPasswordVisible = !_isPasswordVisible),
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                filled: true,
                fillColor: Colors.grey[50],
              ),
              onFieldSubmitted: (_) {
                if (!_isLoading) _signInWithEmailOrPhone();
              },
            ),
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () => Navigator.of(context).pushNamed('/forgot'),
                child: const Text(
                  'ลืมรหัสผ่าน?',
                  style: TextStyle(
                    color: AppColors.accent,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: _isLoading ? null : _signInWithEmailOrPhone,
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
                      'เข้าสู่ระบบ',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
            ),
            const SizedBox(height: 24),
            const _OrDivider(),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: _socialButton(
                onPressed: _isSocialLoading ? null : _signInWithGoogle,
                assetImage: 'assets/file_0000000075b0720680f74d4375d75c25.png',
                label: 'เข้าสู่ระบบด้วย Google',
                backgroundColor: Colors.white,
                foregroundColor: Colors.black87,
                buttonKey: 'google',
              ),
            ),
            if (isAppleSignInSupported) ...[
              const SizedBox(height: 14),
              SizedBox(
                width: double.infinity,
                child: _socialButton(
                  onPressed: _isSocialLoading ? null : _signInWithApple,
                  label: 'เข้าสู่ระบบด้วย Apple',
                  backgroundColor: Colors.black,
                  foregroundColor: Colors.white,
                  buttonKey: 'apple',
                  icon: Icons.apple,
                ),
              ),
            ],
            const SizedBox(height: 24),
            Center(
              child: GestureDetector(
                onTap: () => Navigator.of(context).maybePop(),
                child: const Text(
                  '← ย้อนกลับ',
                  style: TextStyle(
                    color: AppColors.accent,
                    fontSize: 16,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }
}

class _LoginHeader extends StatelessWidget {
  const _LoginHeader();

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const SizedBox(height: 40),
        Center(
          child: Container(
            width: 120,
            height: 120,
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(20)),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(20.0),
              child: const Image(
                image: AssetImage(
                  'assets/app_logo.png',
                ),
                fit: BoxFit.cover,
              ),
            ),
          ),
        ),
        const SizedBox(height: 32),
        const Text(
          'Van Merchant',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 28,
            fontWeight: FontWeight.bold,
            color: Color(0xFF2C3E50),
          ),
        ),
        const SizedBox(height: 32),
      ],
    );
  }
}

class _OrDivider extends StatelessWidget {
  const _OrDivider();

  @override
  Widget build(BuildContext context) {
    return const Row(
      children: [
        Expanded(child: Divider()),
        Padding(
          padding: EdgeInsets.symmetric(horizontal: 16),
          child: Text('หรือ', style: TextStyle(color: Colors.grey)),
        ),
        Expanded(child: Divider()),
      ],
    );
  }
}
