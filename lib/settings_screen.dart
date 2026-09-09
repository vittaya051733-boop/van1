import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'shop_registration_screen.dart';
import 'welcome_screen.dart';
import 'utils/app_colors.dart';
import 'utils/shop_profile_resolver.dart';
import 'models/operating_hours.dart';
import 'admin_contact_screen.dart';
import 'admin_support_inbox_screen.dart';
import 'data/legal_content.dart';
import 'help_center_screen.dart';
import 'legal_document_screen.dart';
import 'low_stock_products_screen.dart';
import 'merchant_reviews_screen.dart';
import 'services/admin_support_config.dart';
import 'services/security_pin_service.dart';
import 'services/biometric_auth_service.dart';
import 'services/shop_operations_service.dart';
import 'services/shop_profile_cache_service.dart';
import 'widgets/cached_app_image.dart';
import 'widgets/operating_hours_sheet.dart';

class _ResolvedShopDoc {
  const _ResolvedShopDoc({
    required this.doc,
    required this.collection,
    this.serviceType,
  });

  final DocumentSnapshot<Map<String, dynamic>> doc;
  final String collection;
  final String? serviceType;
}

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final BiometricAuthService _biometricAuthService = BiometricAuthService();
  bool _autoAcceptOrders = false;
  bool _autoListenIncomingOrders = true;
  bool _biometricLoginAvailable = false;
  bool _biometricLoginEnabled = false;
  bool _biometricLoginLoading = true;
  String? _appVersionLabel;
  String _accountSectionTitle = 'บัญชีร้านค้า';
  Future<_ResolvedShopDoc?>? _shopDataFuture;
  Map<String, dynamic>? _cachedShopPreview;

  static const List<String> _registrationCollections = <String>[
    'market_registrations',
    'shop_registrations',
    'restaurant_registrations',
    'pharmacy_registrations',
  ];

  Future<_ResolvedShopDoc?> _loadShopData(User user) async {
    final String userId = user.uid;
    final cached = await ShopProfileCacheService.instance.loadProfile(userId);
    if (cached != null && cached.isNotEmpty) {
      _cachedShopPreview = cached;
    }
    final String? hintedServiceType =
        cached?['serviceType']?.toString() ??
        await _resolveServiceType(userId);

    final List<String> prioritizedCollections = <String>[
      if (hintedServiceType != null)
        _collectionForServiceType(hintedServiceType),
      ..._registrationCollections,
    ];

    final Set<String> visited = <String>{};
    for (final collection in prioritizedCollections) {
      if (collection.isEmpty || visited.contains(collection)) continue;
      visited.add(collection);
      final DocumentSnapshot<Map<String, dynamic>>? doc =
          await _findShopDocInCollection(collection, userId);
      if (doc != null) {
        final String? docServiceType =
            hintedServiceType ?? doc.data()?['serviceType'] as String?;
        debugPrint(
          'SettingsScreen: found shop doc in $collection (serviceType=$docServiceType)',
        );
        final data = doc.data();
        if (data != null) {
          unawaited(
            ShopProfileCacheService.instance.saveProfile(userId, data),
          );
        }
        return _ResolvedShopDoc(
          doc: doc,
          collection: collection,
          serviceType: docServiceType,
        );
      }
    }
    debugPrint('SettingsScreen: no shop registration found for user=$userId');
    return null;
  }

  Future<DocumentSnapshot<Map<String, dynamic>>?> _findShopDocInCollection(
    String collection,
    String userId,
  ) async {
    try {
      final DocumentSnapshot<Map<String, dynamic>> directDoc =
          await FirebaseFirestore.instance
              .collection(collection)
              .doc(userId)
              .get()
              .timeout(const Duration(seconds: 8));
      if (directDoc.exists) {
        return directDoc;
      }
    } on TimeoutException {
      debugPrint('SettingsScreen: timeout reading $collection/$userId');
    } on FirebaseException catch (e) {
      debugPrint('SettingsScreen: failed reading $collection: ${e.code}');
    }
    return null;
  }

  Future<String?> _resolveServiceType(String userId) async {
    try {
      final doc = await FirebaseFirestore.instance
          .collection('contracts')
          .doc(userId)
          .get()
          .timeout(const Duration(seconds: 5));
      return doc.data()?['serviceType'] as String?;
    } catch (e) {
      debugPrint('SettingsScreen: unable to read service type: $e');
      return null;
    }
  }

  String _collectionForServiceType(String serviceType) {
    switch (serviceType.trim()) {
      case 'ตลาด':
        return 'market_registrations';
      case 'ร้านค้า':
        return 'shop_registrations';
      case 'ร้านอาหาร':
        return 'restaurant_registrations';
      case 'ร้านขายยา':
        return 'pharmacy_registrations';
      default:
        return '';
    }
  }

  Future<void> _loadOperationsSettings(String shopId) async {
    setState(() => _operationsLoading = true);
    try {
      final settings = await ShopOperationsService.fetchSettings(shopId);
      if (!mounted) return;
      setState(() {
        _autoAcceptOrders = settings.autoAcceptOrders;
        _autoListenIncomingOrders = settings.autoListenIncomingOrders;
        _notifyNewOrders = settings.notifyNewOrders;
        _notifyLowStock = settings.notifyLowStock;
        _emailMonthlyReports = settings.emailMonthlyReports;
        _pauseNewOrders = settings.pauseNewOrders;
        _operatingHours = settings.operatingHours;
        _operationsLoading = false;
      });
    } catch (e) {
      debugPrint('SettingsScreen: failed to load operations settings: $e');
      if (!mounted) return;
      setState(() => _operationsLoading = false);
    }
  }

  Future<void> _loadBiometricLoginSettings() async {
    final canUseBiometrics = await _biometricAuthService.canUseBiometrics();
    final enabled = await SecurityPinService.instance.isBiometricUnlockEnabled();
    if (!mounted) return;
    setState(() {
      _biometricLoginAvailable = canUseBiometrics;
      _biometricLoginEnabled = enabled;
      _biometricLoginLoading = false;
    });
  }

  Future<void> _toggleBiometricLogin(bool value) async {
    if (_biometricLoginLoading) return;

    if (value && !_biometricLoginAvailable) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('เครื่องนี้ยังไม่พร้อมใช้ลายนิ้วมือหรือ Face ID'),
        ),
      );
      return;
    }

    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (value && uid != null) {
      final hasPin = await SecurityPinService.instance.hasPin(uid);
      if (!hasPin) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('กรุณาตั้งรหัส PIN 6 หลักก่อน')),
        );
        return;
      }
    }

    setState(() => _biometricLoginLoading = true);
    try {
      if (value) {
        final authenticated = await _biometricAuthService.authenticate(
          reason: 'ยืนยันลายนิ้วมือหรือ Face ID เพื่อปลดล็อกแอป',
        );
        if (!authenticated) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('ยืนยันลายนิ้วมือหรือ Face ID ไม่สำเร็จ'),
            ),
          );
          return;
        }
      }

      await SecurityPinService.instance.setBiometricUnlockEnabled(value);
      if (!mounted) return;
      setState(() => _biometricLoginEnabled = value);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            value
                ? 'เปิดปลดล็อกด้วยลายนิ้วมือและ Face ID ก่อนเข้าแอปแล้ว'
                : 'ปิดปลดล็อกด้วยลายนิ้วมือและ Face ID แล้ว',
          ),
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _biometricLoginLoading = false);
      }
    }
  }

  bool get _operationsReady => !_operationsLoading && _shopId != null;

  Future<void> _toggleAutoAccept(bool value) async {
    if (_shopId == null) return;
    final previous = _autoAcceptOrders;
    setState(() => _autoAcceptOrders = value);
    try {
      await ShopOperationsService.updateSettings(_shopId!, {
        'autoAcceptOrders': value,
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _autoAcceptOrders = previous);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('ไม่สามารถอัปเดตการรับออเดอร์อัตโนมัติ: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Future<void> _toggleAutoListenIncomingOrders(bool value) async {
    if (_shopId == null) return;
    final previous = _autoListenIncomingOrders;
    setState(() => _autoListenIncomingOrders = value);
    try {
      await ShopOperationsService.updateSettings(_shopId!, {
        'autoListenIncomingOrders': value,
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _autoListenIncomingOrders = previous);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('ไม่สามารถอัปเดตการฟังคำสั่งเสียงอัตโนมัติ: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Future<void> _togglePauseOrders(bool value) async {
    if (_shopId == null) return;
    final previous = _pauseNewOrders;
    setState(() => _pauseNewOrders = value);
    try {
      await ShopOperationsService.updateSettings(_shopId!, {
        'pauseNewOrders': value,
      });
      if (_shopDocRef != null) {
        await _shopDocRef!.update({'isOpen': !value});
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            value ? 'หยุดรับออเดอร์ชั่วคราวแล้ว' : 'กลับมารับออเดอร์ตามปกติ',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _pauseNewOrders = previous);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('ไม่สามารถเปลี่ยนสถานะการหยุดรับออเดอร์: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Future<void> _toggleLowStockNotification(bool value) async {
    if (_shopId == null) return;
    final previous = _notifyLowStock;
    setState(() => _notifyLowStock = value);
    try {
      await ShopOperationsService.updateSettings(_shopId!, {
        'notifyLowStock': value,
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _notifyLowStock = previous);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('ไม่สามารถอัปเดตการเตือนสต๊อกใกล้หมด: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Future<void> _toggleNotifyNewOrders(bool value) async {
    if (_shopId == null) return;
    final previous = _notifyNewOrders;
    setState(() => _notifyNewOrders = value);
    try {
      await ShopOperationsService.updateSettings(_shopId!, {
        'notifyNewOrders': value,
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _notifyNewOrders = previous);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('ไม่สามารถอัปเดตการแจ้งเตือนออเดอร์ใหม่: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Future<void> _toggleEmailMonthlyReports(bool value) async {
    if (_shopId == null) return;
    final previous = _emailMonthlyReports;
    setState(() => _emailMonthlyReports = value);
    try {
      await ShopOperationsService.updateSettings(_shopId!, {
        'emailMonthlyReports': value,
        'emailDailyReports': value,
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _emailMonthlyReports = previous);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('ไม่สามารถอัปเดตรายงานยอดขายรายเดือนทางอีเมล: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Future<void> _openLowStockProducts() async {
    final shopId = _shopId;
    if (shopId == null) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => LowStockProductsScreen(shopId: shopId),
      ),
    );
  }

  Future<void> _openOperatingHoursEditor() async {
    if (_shopId == null) return;
    final initial = _operatingHours ?? OperatingHours.defaultWeek();
    final result = await showModalBottomSheet<OperatingHours>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) => OperatingHoursSheet(initial: initial),
    );
    if (result == null) return;
    setState(() => _operatingHours = result);
    try {
      await ShopOperationsService.updateSettings(_shopId!, {
        'operatingHours': result.toMap(),
      });
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('บันทึกเวลาเปิด-ปิดร้านแล้ว')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('บันทึกเวลาเปิด-ปิดร้านไม่สำเร็จ: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  bool _pauseNewOrders = false;
  bool _notifyNewOrders = true;
  bool _notifyLowStock = true;
  bool _emailMonthlyReports = false;
  DocumentReference<Map<String, dynamic>>? _shopDocRef;
  OperatingHours? _operatingHours;
  bool _operationsLoading = false;
  String? _shopId;
  bool _operationsInitAttempted = false;

  @override
  void initState() {
    super.initState();
    final user = FirebaseAuth.instance.currentUser;
    _shopId = user?.uid;
    _operationsInitAttempted = _shopId != null;
    if (user != null) {
      _shopDataFuture = _loadShopData(user);
      unawaited(_hydrateCachedShopPreview(user.uid));
    }
    if (_shopId != null) {
      _loadOperationsSettings(_shopId!);
    }
    _loadBiometricLoginSettings();
    _loadAppVersion();
  }

  Future<void> _loadAppVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (!mounted) return;
      setState(() {
        _appVersionLabel = '${info.version} (${info.buildNumber})';
      });
    } catch (_) {}
  }

  Future<void> _hydrateCachedShopPreview(String userId) async {
    final cached = await ShopProfileCacheService.instance.loadProfile(userId);
    if (!mounted || cached == null || cached.isEmpty) return;
    setState(() => _cachedShopPreview = cached);
  }

  Widget _buildSection({
    required String title,
    required List<Widget> children,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 10),
          Card(
            color: Colors.white,
            elevation: 1.5,
            margin: EdgeInsets.zero,
            surfaceTintColor: Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(children: children),
          ),
        ],
      ),
    );
  }

  Future<void> _showChangePasswordDialog() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null || user.email == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'ไม่สามารถเปลี่ยนรหัสผ่านได้สำหรับบัญชีนี้ (อาจเป็น Social Login)',
          ),
        ),
      );
      return;
    }

    try {
      await FirebaseAuth.instance.sendPasswordResetEmail(email: user.email!);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('ส่งลิงก์เปลี่ยนรหัสผ่านไปที่ ${user.email} แล้ว'),
          backgroundColor: Colors.green,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('เกิดข้อผิดพลาด: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Future<void> _confirmAndSignOut(User user) async {
    if (!mounted) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('ยืนยันการออกจากระบบ'),
        content: const Text('คุณต้องการออกจากระบบหรือไม่?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('ยกเลิก'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('ยืนยัน'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (!context.mounted) return;

    try {
      final providers = user.providerData.map((p) => p.providerId).toSet();
      if (providers.contains('google.com') && !kIsWeb) {
        await GoogleSignIn.instance.signOut();
        if (!context.mounted) return;
      }
      await FirebaseAuth.instance.signOut();
      if (!context.mounted) return;
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const WelcomeScreen()),
        (route) => false,
      );
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('ไม่สามารถออกจากระบบได้: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    if (user != null && !_operationsInitAttempted) {
      _operationsInitAttempted = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        setState(() => _shopId = user.uid);
        _loadOperationsSettings(user.uid);
      });
    }

    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        title: const Text('ตั้งค่าและบัญชี'),
        // This removes the back button since it's a main tab screen.
        automaticallyImplyLeading: false,
      ),
      body: ColoredBox(
        color: Colors.white,
        child: Column(
          children: [
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    if (user != null)
                      _buildSection(
                        title: _accountSectionTitle,
                        children: [
                          FutureBuilder<_ResolvedShopDoc?>(
                            future: _shopDataFuture,
                            builder: (context, snapshot) {
                              if (snapshot.connectionState ==
                                      ConnectionState.waiting &&
                                  _cachedShopPreview == null) {
                                return const Padding(
                                  padding: EdgeInsets.all(20),
                                  child: Center(
                                    child: CircularProgressIndicator(),
                                  ),
                                );
                              }

                              String? shopImageUrl;
                              String? shopName;
                              String? shopType;
                              String? phone;
                              String? email;
                              String? description;
                              String? bookBankImageUrl;
                              double? lat;
                              double? lng;
                              final _ResolvedShopDoc? resolvedDoc =
                                  snapshot.data;
                              final DocumentSnapshot<Map<String, dynamic>>?
                              shopDoc = resolvedDoc?.doc;

                              if (shopDoc != null && shopDoc.exists) {
                                _shopDocRef ??= shopDoc.reference;
                                final data = shopDoc.data();
                                shopImageUrl =
                                    ShopProfileResolver.resolveImageUrl(data);
                                shopName = ShopProfileResolver.resolveName(
                                  data,
                                );
                                shopType =
                                    resolvedDoc?.serviceType ??
                                    data?['serviceType'] as String?;
                                phone = data?['phone']?.toString();
                                email = data?['email']?.toString();
                                description = data?['description']?.toString();
                                bookBankImageUrl = data?['bookBankImageUrl']
                                    ?.toString();
                                final loc = data?['location'];
                                if (loc is Map) {
                                  lat = (loc['latitude'] as num?)?.toDouble();
                                  lng = (loc['longitude'] as num?)?.toDouble();
                                }
                              } else if (_cachedShopPreview != null) {
                                final data = _cachedShopPreview!;
                                shopImageUrl =
                                    ShopProfileResolver.resolveImageUrl(data);
                                shopName = ShopProfileResolver.resolveName(
                                  data,
                                );
                                shopType = data['serviceType']?.toString();
                                phone = data['phone']?.toString();
                                email = data['email']?.toString();
                                description = data['description']?.toString();
                                bookBankImageUrl = data['bookBankImageUrl']
                                    ?.toString();
                                final loc = data['location'];
                                if (loc is Map) {
                                  lat = (loc['latitude'] as num?)?.toDouble();
                                  lng = (loc['longitude'] as num?)?.toDouble();
                                }
                              }

                              final String resolvedSectionTitle =
                                  'บัญชี${(shopType != null && shopType.trim().isNotEmpty) ? shopType.trim() : 'ร้านค้า'}';
                              if (_accountSectionTitle !=
                                  resolvedSectionTitle) {
                                WidgetsBinding.instance.addPostFrameCallback((
                                  _,
                                ) {
                                  if (!mounted) return;
                                  setState(
                                    () => _accountSectionTitle =
                                        resolvedSectionTitle,
                                  );
                                });
                              }

                              final hasBookBankImage =
                                  bookBankImageUrl?.isNotEmpty ?? false;
                              final bookBankImage = bookBankImageUrl ?? '';

                              return Column(
                                children: [
                                  Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 16,
                                      vertical: 20,
                                    ),
                                    child: Column(
                                      children: [
                                        GestureDetector(
                                          onTap: () {
                                            if (shopDoc != null &&
                                                shopDoc.exists) {
                                              Navigator.push(
                                                context,
                                                MaterialPageRoute(
                                                  builder: (context) =>
                                                      ShopRegistrationScreen(
                                                        shopData: shopDoc,
                                                      ),
                                                ),
                                              ).then((_) {
                                                final current =
                                                    FirebaseAuth
                                                        .instance
                                                        .currentUser;
                                                if (current != null) {
                                                  _shopDataFuture =
                                                      _loadShopData(current);
                                                }
                                                if (mounted) setState(() {});
                                              });
                                            }
                                          },
                                          child: Stack(
                                            children: [
                                              CircleAvatar(
                                                radius: 42,
                                                backgroundColor:
                                                    AppColors.accent,
                                                backgroundImage:
                                                    shopImageUrl != null &&
                                                        shopImageUrl.isNotEmpty
                                                    ? NetworkImage(shopImageUrl)
                                                    : null,
                                                child:
                                                    shopImageUrl == null ||
                                                        shopImageUrl.isEmpty
                                                    ? const Icon(
                                                        Icons.storefront,
                                                        size: 52,
                                                        color: Colors.white,
                                                      )
                                                    : null,
                                              ),
                                              Positioned(
                                                bottom: 0,
                                                right: 0,
                                                child: Container(
                                                  padding: const EdgeInsets.all(
                                                    4,
                                                  ),
                                                  decoration: BoxDecoration(
                                                    color: AppColors.accent,
                                                    shape: BoxShape.circle,
                                                    border: Border.all(
                                                      color: Colors.white,
                                                      width: 2,
                                                    ),
                                                  ),
                                                  child: const Icon(
                                                    Icons.edit,
                                                    size: 16,
                                                    color: Colors.white,
                                                  ),
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                        const SizedBox(height: 12),
                                        Text(
                                          shopName ??
                                              user.displayName ??
                                              'ร้านค้า',
                                          style: Theme.of(
                                            context,
                                          ).textTheme.titleLarge,
                                        ),
                                        const SizedBox(height: 4),
                                        Text(
                                          shopType ??
                                              user.email ??
                                              user.phoneNumber ??
                                              'ไม่ได้ระบุข้อมูล',
                                          style: Theme.of(context)
                                              .textTheme
                                              .bodyMedium
                                              ?.copyWith(
                                                color: Colors.grey[600],
                                              ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  const Divider(height: 0),
                                  // สรุปข้อมูลร้าน
                                  Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 16,
                                      vertical: 12,
                                    ),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.stretch,
                                      children: [
                                        if (description != null &&
                                            description.isNotEmpty)
                                          ListTile(
                                            dense: true,
                                            leading: const Icon(
                                              Icons.notes_outlined,
                                            ),
                                            title: Text(description),
                                          ),
                                        if (phone != null && phone.isNotEmpty)
                                          const Divider(height: 0),
                                        if (phone != null && phone.isNotEmpty)
                                          ListTile(
                                            dense: true,
                                            leading: const Icon(
                                              Icons.phone_outlined,
                                            ),
                                            title: Text(phone),
                                          ),
                                        if (email != null && email.isNotEmpty)
                                          const Divider(height: 0),
                                        if (email != null && email.isNotEmpty)
                                          ListTile(
                                            dense: true,
                                            leading: const Icon(
                                              Icons.email_outlined,
                                            ),
                                            title: Text(email),
                                          ),
                                        if (lat != null && lng != null)
                                          const Divider(height: 0),
                                        if (lat != null && lng != null)
                                          ListTile(
                                            dense: true,
                                            leading: const Icon(
                                              Icons.location_on_outlined,
                                            ),
                                            title: Text(
                                              'Lat: ${lat.toStringAsFixed(6)}  Lng: ${lng.toStringAsFixed(6)}',
                                            ),
                                          ),
                                        if (hasBookBankImage)
                                          const Divider(height: 0),
                                        if (hasBookBankImage)
                                          ListTile(
                                            dense: true,
                                            leading: ClipRRect(
                                              borderRadius:
                                                  BorderRadius.circular(6),
                                              child: CachedAppImage(
                                                imageUrl: bookBankImage,
                                                width: 44,
                                                height: 44,
                                                fit: BoxFit.cover,
                                              ),
                                            ),
                                            title: const Text('รูปสมุดบัญชี'),
                                            onTap: () {
                                              showDialog(
                                                context: context,
                                                builder: (_) => Dialog(
                                                  child: InteractiveViewer(
                                                    child: CachedAppImage(
                                                      imageUrl: bookBankImage,
                                                    ),
                                                  ),
                                                ),
                                              );
                                            },
                                          ),
                                      ],
                                    ),
                                  ),
                                  const Divider(height: 0),
                                  ListTile(
                                    leading: const Icon(Icons.edit_outlined),
                                    title: const Text(
                                      'แก้ไขข้อมูลการลงทะเบียนร้าน',
                                    ),
                                    subtitle: const Text(
                                      'อัปเดตโลโก้ร้าน ที่อยู่ เบอร์โทร หมวดหมู่ และรายละเอียดทั้งหมด',
                                    ),
                                    trailing: const Icon(Icons.chevron_right),
                                    onTap: () {
                                      if (shopDoc != null && shopDoc.exists) {
                                        Navigator.push(
                                          context,
                                          MaterialPageRoute(
                                            builder: (context) =>
                                                ShopRegistrationScreen(
                                                  shopData: shopDoc,
                                                ),
                                          ),
                                        ).then((_) => setState(() {}));
                                      } else {
                                        Navigator.push(
                                          context,
                                          MaterialPageRoute(
                                            builder: (context) =>
                                                const ShopRegistrationScreen(),
                                          ),
                                        ).then((_) => setState(() {}));
                                      }
                                    },
                                  ),
                                ],
                              );
                            },
                          ),
                          if (user.providerData.any(
                            (p) => p.providerId == 'password',
                          )) ...[
                            const Divider(height: 0),
                            ListTile(
                              leading: const Icon(Icons.security_outlined),
                              title: const Text('เปลี่ยนรหัสผ่าน'),
                              subtitle: const Text(
                                'แนะนำให้เปลี่ยนรหัสผ่านเป็นประจำเพื่อความปลอดภัย',
                              ),
                              trailing: const Icon(Icons.chevron_right),
                              onTap: _showChangePasswordDialog,
                            ),
                          ],
                        ],
                      ),
                    _buildSection(
                      title: 'การดำเนินงานร้าน',
                      children: [
                        SwitchListTile(
                          value: _autoAcceptOrders,
                          onChanged: _operationsReady
                              ? _toggleAutoAccept
                              : null,
                          title: const Text('รับออเดอร์อัตโนมัติ'),
                          subtitle: Text(
                            _operationsLoading
                                ? 'กำลังโหลดการตั้งค่า...'
                                : 'เมื่อมีคำสั่งซื้อใหม่ ระบบจะรับทันทีโดยไม่ต้องกดยืนยัน',
                          ),
                        ),
                        const Divider(height: 0),
                        SwitchListTile(
                          value: _autoListenIncomingOrders,
                          onChanged: _operationsReady
                              ? _toggleAutoListenIncomingOrders
                              : null,
                          title: const Text(
                            'เปิดฟังคำสั่งเสียงอัตโนมัติเมื่อมีออเดอร์เข้า',
                          ),
                          subtitle: Text(
                            _operationsLoading
                                ? 'กำลังโหลดการตั้งค่า...'
                                : 'ถ้าเคยอนุญาตไมค์ไว้แล้ว หน้ารับออเดอร์จะเริ่มฟังคำว่า รับออเดอร์/ปฏิเสธออเดอร์ให้อัตโนมัติ',
                          ),
                        ),
                        const Divider(height: 0),
                        SwitchListTile(
                          value: _pauseNewOrders,
                          onChanged: _operationsReady
                              ? _togglePauseOrders
                              : null,
                          title: const Text('หยุดรับออเดอร์ใหม่ชั่วคราว'),
                          subtitle: Text(
                            _operationsLoading
                                ? 'กำลังโหลดการตั้งค่า...'
                                : 'ใช้เมื่อวัตถุดิบไม่เพียงพอ หรืออยู่ระหว่างพักร้าน',
                          ),
                        ),
                        const Divider(height: 0),
                        ListTile(
                          leading: const Icon(Icons.schedule_outlined),
                          title: const Text('ตั้งเวลาเปิด-ปิดร้าน'),
                          subtitle: Text(
                            _operatingHours?.toReadableSummary() ??
                                (_operationsLoading
                                    ? 'กำลังโหลดการตั้งค่า...'
                                    : 'ตั้งเวลาปกติ วันหยุดนักขัตฤกษ์ หรือ Flash Sale'),
                          ),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: _operationsReady
                              ? _openOperatingHoursEditor
                              : null,
                        ),
                      ],
                    ),
                    _buildSection(
                      title: 'การแจ้งเตือนและรายงาน',
                      children: [
                        SwitchListTile(
                          value: _notifyNewOrders,
                          onChanged: _operationsReady
                              ? _toggleNotifyNewOrders
                              : null,
                          title: const Text('แจ้งเตือนออเดอร์ใหม่'),
                          subtitle: Text(
                            _operationsLoading
                                ? 'กำลังโหลดการตั้งค่า...'
                                : 'ส่ง Push Notification ทุกครั้งที่มีคำสั่งซื้อเข้ามา',
                          ),
                        ),
                        const Divider(height: 0),
                        SwitchListTile(
                          value: _notifyLowStock,
                          onChanged: _operationsReady
                              ? _toggleLowStockNotification
                              : null,
                          title: const Text('เตือนสต๊อกใกล้หมด'),
                          subtitle: Text(
                            _operationsLoading
                                ? 'กำลังโหลดการตั้งค่า...'
                                : 'แจ้งเตือนเมื่อสินค้าเหลือ น้อยกว่า 5 ชิ้น',
                          ),
                        ),
                        const Divider(height: 0),
                        ListTile(
                          leading: const Icon(Icons.inventory_2_outlined),
                          title: const Text('รายการสินค้าใกล้หมด'),
                          subtitle: Text(
                            _operationsLoading
                                ? 'กำลังโหลดการตั้งค่า...'
                                : 'ดูรายการสินค้าที่เหลือน้อยกว่า 5 ชิ้น',
                          ),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: _operationsReady
                              ? _openLowStockProducts
                              : null,
                        ),
                        const Divider(height: 0),
                        SwitchListTile(
                          value: _emailMonthlyReports,
                          onChanged: _operationsReady
                              ? _toggleEmailMonthlyReports
                              : null,
                          title: const Text('สรุปรายงานยอดขายรายเดือนทางอีเมล'),
                          subtitle: Text(
                            _operationsLoading
                                ? 'กำลังโหลดการตั้งค่า...'
                                : 'สรุปยอดขายของเดือนก่อนหน้า ส่งเดือนละหนึ่งครั้งทุกวันที่ 1 ทางอีเมล',
                          ),
                        ),
                      ],
                    ),
                    _buildSection(
                      title: 'รีวิวจากลูกค้า',
                      children: [
                        ListTile(
                          leading: const Icon(Icons.star_rate_rounded),
                          title: const Text('ดูรีวิวสินค้าและร้านค้า'),
                          subtitle: const Text(
                            'อ่านอย่างเดียว — ลูกค้าเป็นผู้ให้คะแนนและแก้ไขรีวิวเอง',
                          ),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute<void>(
                                builder: (_) => const MerchantReviewsScreen(),
                              ),
                            );
                          },
                        ),
                      ],
                    ),
                    _buildSection(
                      title: 'ความปลอดภัย',
                      children: [
                        SwitchListTile(
                          secondary: _biometricLoginLoading
                              ? const SizedBox(
                                  width: 24,
                                  height: 24,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.fingerprint),
                          value:
                              _biometricLoginAvailable &&
                              _biometricLoginEnabled,
                          onChanged: _biometricLoginLoading
                              ? null
                              : _toggleBiometricLogin,
                          title: const Text('ปลดล็อกด้วยลายนิ้วมือและ Face ID'),
                          subtitle: Text(
                            _biometricLoginLoading
                                ? 'กำลังตรวจสอบลายนิ้วมือและ Face ID ของเครื่อง...'
                                : _biometricLoginAvailable
                                ? 'ใช้ก่อนเข้าแอป (หลัง login แล้ว)'
                                : 'เครื่องนี้ยังไม่มีลายนิ้วมือ/Face ID หรือยังไม่ได้ตั้งค่าในระบบ',
                          ),
                        ),
                      ],
                    ),
                    _buildSection(
                      title: 'ศูนย์ช่วยเหลือและนโยบาย',
                      children: [
                        ListTile(
                          leading: const Icon(Icons.support_agent_outlined),
                          title: const Text('ติดต่อแอดมิน'),
                          subtitle: const Text(
                            'ส่งคำถามหรือแจ้งปัญหาถึงทีมแอดมิน พร้อมแนบรูปประกอบ',
                          ),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute<void>(
                                builder: (_) => const AdminContactScreen(
                                  config: kVan1AdminSupportConfig,
                                ),
                              ),
                            );
                          },
                        ),
                        ListTile(
                          leading: const Icon(Icons.mark_chat_unread_outlined),
                          title: const Text('ข้อความถึงแอดมิน'),
                          subtitle: const Text('ดูคำตอบจากแอดมินและตอบกลับ'),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute<void>(
                                builder: (_) => const AdminSupportInboxScreen(
                                  config: kVan1AdminSupportConfig,
                                  accentColor: Color(0xFF2563EB),
                                ),
                              ),
                            );
                          },
                        ),
                        const Divider(height: 0),
                        ListTile(
                          leading: const Icon(Icons.help_outline),
                          title: const Text('ศูนย์ช่วยเหลือ Van Market'),
                          subtitle: const Text(
                            'อ่านคู่มือการใช้งานและคำถามที่พบบ่อย',
                          ),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute<void>(
                                builder: (_) => const HelpCenterScreen(),
                              ),
                            );
                          },
                        ),
                        const Divider(height: 0),
                        ListTile(
                          leading: const Icon(Icons.policy_outlined),
                          title: const Text('นโยบายความเป็นส่วนตัว'),
                          subtitle: Text(
                            'อัปเดตครั้งล่าสุด: ${LegalContent.privacyPolicy.updatedAtLabel}',
                          ),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute<void>(
                                builder: (_) => const LegalDocumentScreen(
                                  document: LegalContent.privacyPolicy,
                                ),
                              ),
                            );
                          },
                        ),
                        const Divider(height: 0),
                        ListTile(
                          leading: const Icon(Icons.description_outlined),
                          title: const Text('ข้อกำหนดการใช้บริการ'),
                          subtitle: Text(
                            'อัปเดตครั้งล่าสุด: ${LegalContent.termsOfService.updatedAtLabel}',
                          ),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute<void>(
                                builder: (_) => const LegalDocumentScreen(
                                  document: LegalContent.termsOfService,
                                ),
                              ),
                            );
                          },
                        ),
                        const Divider(height: 0),
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          child: Align(
                            alignment: Alignment.center,
                            child: TextButton(
                              onPressed: user == null
                                  ? null
                                  : () => _confirmAndSignOut(user),
                              child: Text(
                                'ออกจากระบบ',
                                style: TextStyle(
                                  color: Colors.red.shade700,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 16,
                                ),
                              ),
                            ),
                          ),
                        ),
                        if (_appVersionLabel != null)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: Center(
                              child: Text(
                                'เวอร์ชัน $_appVersionLabel',
                                style: TextStyle(
                                  color: Colors.grey.shade600,
                                  fontSize: 13,
                                ),
                              ),
                            ),
                          ),
                      ],
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
