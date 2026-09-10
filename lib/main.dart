import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'home_screen.dart';
import 'login_screen.dart';
import 'welcome_screen.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'register_screen.dart';
import 'forgot_password_screen.dart';
import 'email_verification_helper.dart';
import 'email_verification_screen.dart';
import 'phone_auth_screen.dart';
import 'firebase_options.dart';
import 'package:flutter/foundation.dart';
import 'package:firebase_app_check/firebase_app_check.dart';
import 'dart:async'; // เพิ่ม: จัดการ async error/timeout ให้ไม่ทำให้แอปเด้ง
import 'register_shop_blank.dart';
import 'register_shop_next.dart';
import 'contract_screen.dart';
import 'shop_registration_screen.dart';
import 'post_verification_intro_screen.dart';
import 'navigation_helper.dart';
import 'utils/app_colors.dart';
import 'services/notification_service.dart';
import 'widgets/app_update_gate.dart';
import 'widgets/app_unlock_gate.dart';
import 'utils/feature_flags.dart';
import 'utils/phone_auth_config.dart';

void main() {
  runZonedGuarded(
    () async {
      WidgetsFlutterBinding.ensureInitialized();

      // ดักจับ error ระดับเฟรมเวิร์ก (ไม่ให้แอปหลุด)
      FlutterError.onError = (FlutterErrorDetails details) {
        FlutterError.presentError(details);
      };

      // ดักจับ error ระดับ engine/แพลตฟอร์ม ให้ไม่ทำให้แอปเด้ง
      WidgetsBinding.instance.platformDispatcher.onError = (error, stack) {
        // สามารถส่ง log ไปเก็บได้ที่นี่
        return true; // กลืน error ไว้
      };

      // แทน ErrorWidget (จอแดง) ด้วย widget เงียบๆ เพื่อไม่ให้ผู้ใช้เห็น error
      ErrorWidget.builder = (FlutterErrorDetails details) {
        return const SizedBox.shrink();
      };

      try {
        if (Firebase.apps.isEmpty) {
          await Firebase.initializeApp(
            options: DefaultFirebaseOptions.currentPlatform,
          );
        }
        await initializeDateFormatting('th_TH');

        // Emulator/sideload: ใช้เบอร์ทดสอบใน Firebase Console → Auth → Phone
        if (shouldDisablePhoneAppVerification) {
          await FirebaseAuth.instance.setSettings(
            appVerificationDisabledForTesting: true,
          );
        }
      } catch (e) {
        final msg = e.toString();
        // ถ้าเป็น duplicate-app ให้ข้ามและใช้อินสแตนซ์เดิม
        if (!(msg.contains('duplicate-app') ||
            msg.contains('already exists'))) {
          runApp(ErrorApp(error: msg));
          return;
        }
      }

      // พยายามเปิดใช้ App Check แต่ถ้าล้มเหลว/ช้าเกินไป ให้ไปต่อได้
      final useDebugAppCheck = !kReleaseMode || kAppCheckForceDebug;
      try {
        await FirebaseAppCheck.instance
            .activate(
              providerAndroid: useDebugAppCheck
                  ? AndroidDebugProvider(debugToken: kVan1AppCheckDebugToken)
                  : const AndroidPlayIntegrityProvider(),
              providerApple: useDebugAppCheck
                  ? AppleDebugProvider(debugToken: kVan1AppCheckDebugToken)
                  : const AppleAppAttestWithDeviceCheckFallbackProvider(),
            )
            .timeout(const Duration(seconds: 5)); // กันค้าง
        await FirebaseAppCheck.instance.setTokenAutoRefreshEnabled(true);

        if (useDebugAppCheck) {
          debugPrint(
            'App Check debug token (register once in Firebase Console): '
            '$kVan1AppCheckDebugToken',
          );
        }

        // พยายามดึงโทเคน (ช่วยให้ App Check พร้อมก่อน Auth/OTP)
        try {
          await FirebaseAppCheck.instance
              .getToken(true)
              .timeout(const Duration(seconds: 5));
        } catch (e) {
          if (useDebugAppCheck) {
            debugPrint('Could not get App Check token on startup: $e');
          }
        }
      } catch (e) {
        // กลืนทุก error ของ App Check เพื่อให้แอปรันได้ก่อน
        if (useDebugAppCheck) {
          debugPrint('App Check activate failed: $e');
        }
      }

      if (!kIsWeb) {
        FirebaseMessaging.onBackgroundMessage(
          firebaseMessagingBackgroundHandlerVan1,
        );
      }

      runApp(const MyApp());

      if (!kIsWeb) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          unawaited(_initializeNotificationsAfterAppStart());
        });
      }
    },
    (error, stack) {
      // เก็บ/แสดง log ได้ตามต้องการ
    },
  );
}

Future<void> _initializeNotificationsAfterAppStart() async {
  try {
    await NotificationService().initialize();
  } catch (e) {
    debugPrint('Notification init error: $e');
  }
}

// A simple widget to display a critical error, like Firebase failing to initialize.
class ErrorApp extends StatelessWidget {
  final String error;
  const ErrorApp({super.key, required this.error});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        appBar: AppBar(title: const Text('Firebase Initialization Error')),
        body: Padding(
          padding: const EdgeInsets.all(16.0),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Error initializing Firebase:',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: Colors.red,
                  ),
                ),
                SizedBox(height: 8),
                Text(error),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  static final GlobalKey<NavigatorState> navigatorKey =
      GlobalKey<NavigatorState>();
  static const String appFontFamily = 'Prompt';

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'แว๊นตลาดร้านค้า',
      debugShowCheckedModeBanner: false,
      navigatorKey: navigatorKey,
      locale: const Locale('th', 'TH'),
      supportedLocales: const <Locale>[Locale('th', 'TH')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: AppColors.accent,
          brightness: Brightness.light,
        ),
        fontFamily: appFontFamily,
        appBarTheme: AppBarTheme(
          backgroundColor: AppColors.accent,
          foregroundColor: Colors.white,
          titleTextStyle: const TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.bold,
          ),
          centerTitle: true,
        ),
        floatingActionButtonTheme: const FloatingActionButtonThemeData(
          backgroundColor: AppColors.accent,
          foregroundColor: Colors.white,
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            foregroundColor: Colors.white,
            backgroundColor: AppColors.accentDark,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
            textStyle: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
        snackBarTheme: const SnackBarThemeData(
          backgroundColor: AppColors.accent,
          actionTextColor: Colors.white,
          contentTextStyle: TextStyle(color: Colors.white),
        ),
      ),
      routes: {
        '/welcome': (context) => const WelcomeScreen(),
        '/register-shop-next': (context) => const RegisterShopNextScreen(),
        '/login': (context) {
          final serviceType =
              ModalRoute.of(context)?.settings.arguments as String?;
          return LoginScreen(serviceType: serviceType);
        },
        '/register': (context) {
          final serviceType =
              ModalRoute.of(context)?.settings.arguments as String?;
          return RegisterScreen(serviceType: serviceType);
        },
        '/forgot': (context) => const ForgotPasswordScreen(),
        '/phone_auth': (context) => const PhoneAuthScreen(),
        '/email-verification': (context) => const EmailVerificationScreen(),
        '/email-helper': (context) {
          final email = ModalRoute.of(context)?.settings.arguments as String?;
          return EmailVerificationHelper(prefilledEmail: email);
        },
        '/post-verification-intro': (context) {
          final serviceType =
              ModalRoute.of(context)?.settings.arguments as String?;
          return PostVerificationIntroScreen(serviceType: serviceType);
        },
        '/contract-intro': (context) => const RegisterShopBlankScreen(),
        '/contract': (context) {
          final serviceType =
              ModalRoute.of(context)?.settings.arguments as String?;
          return ContractScreen(serviceType: serviceType);
        },
        '/shop-registration': (context) {
          final serviceType =
              ModalRoute.of(context)?.settings.arguments as String?;
          return ShopRegistrationScreen(serviceType: serviceType);
        },
        '/home': (context) => const HomeScreen(),
      },
      home: kDisableAppUpdateGate
          ? _buildAuthTree()
          : AppUpdateGate(allowSkipForMandatory: true, child: _buildAuthTree()),
    );
  }

  Widget _buildAuthTree() {
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges().handleError((
        e,
        stackTrace,
      ) {
        debugPrint('Error in authStateChanges stream: $e');
      }, test: (e) => true),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return const WelcomeScreen();
        }
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        return snapshot.hasData
            ? const AppUnlockGate(child: AuthWrapper())
            : const WelcomeScreen();
      },
    );
  }
}

class AuthWrapper extends StatefulWidget {
  const AuthWrapper({super.key});

  @override
  State<AuthWrapper> createState() => _AuthWrapperState();
}

class _AuthWrapperState extends State<AuthWrapper> {
  static const Duration _navigationTimeout = Duration(seconds: 12);
  bool _showRetry = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _navigate());
  }

  Future<void> _saveFcmTokenInBackground(String uid) async {
    try {
      await NotificationService()
          .saveUserFcmToken(uid)
          .timeout(const Duration(seconds: 8));
    } catch (e) {
      debugPrint('FCM token save skipped during startup: $e');
    }
  }

  Future<void> _navigate() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null || !mounted) return;

    if (mounted) {
      setState(() => _showRetry = false);
    }

    if (!kIsWeb) {
      // อย่าบล็อกการนำทาง — getToken()/Firestore อาจค้างบางเครื่อง
      unawaited(_saveFcmTokenInBackground(user.uid));
    }

    try {
      await NavigationHelper.navigateBasedOnUserStatus(
        context,
        user,
        replace: true,
      ).timeout(_navigationTimeout);
    } on TimeoutException {
      debugPrint('Auth navigation timed out after $_navigationTimeout');
      if (!mounted) return;
      // HomeScreen จะ hydrate cache + retry โปรไฟล์ร้านเอง
      Navigator.of(context).pushReplacementNamed('/home');
    } catch (e, stackTrace) {
      debugPrint('Auth navigation failed: $e\n$stackTrace');
      if (!mounted) return;
      setState(() => _showRetry = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final logoSize = (MediaQuery.sizeOf(context).shortestSide * 0.86)
        .clamp(120.0, 360.0)
        .toDouble();

    // แสดงหน้าจอ Loading ขณะกำลังตรวจสอบและนำทาง
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // โลโก้ (เปลี่ยนชื่อไฟล์ตาม asset ที่มี)
            Image.asset(
              'assets/app_logo.png',
              width: logoSize,
              height: logoSize,
            ),
            const SizedBox(height: 24),
            if (!_showRetry) ...[
              const CircularProgressIndicator(),
              const SizedBox(height: 16),
              const Text('กำลังตรวจสอบข้อมูล...'),
            ] else ...[
              const Text('ไม่สามารถตรวจสอบข้อมูลได้'),
              const SizedBox(height: 16),
              FilledButton(onPressed: _navigate, child: const Text('ลองใหม่')),
              TextButton(
                onPressed: () {
                  if (!context.mounted) return;
                  Navigator.of(context).pushReplacementNamed('/home');
                },
                child: const Text('เข้าแอปต่อ'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
