import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
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
import 'services/account_deletion_service.dart';
import 'widgets/cached_app_image.dart';
import 'widgets/merchant_premium_ui.dart';
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
        cached?['serviceType']?.toString() ?? await _resolveServiceType(userId);

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
          unawaited(ShopProfileCacheService.instance.saveProfile(userId, data));
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
    final enabled = await SecurityPinService.instance
        .isBiometricUnlockEnabled();
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
  bool _deletingAccount = false;

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
            style: const TextStyle(
              color: MerchantPremiumUi.ink,
              fontSize: 16,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 10),
          Container(
            decoration: MerchantPremiumUi.cardDecoration(),
            clipBehavior: Clip.antiAlias,
            child: Material(
              color: Colors.transparent,
              child: Column(children: children),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAccountMetric({
    required IconData icon,
    required String label,
    required String value,
    Color color = AppColors.accentDark,
  }) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.88),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: color.withValues(alpha: 0.14)),
        ),
        child: Row(
          children: [
            Icon(icon, color: color, size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: MerchantPremiumUi.ink,
                      fontWeight: FontWeight.w900,
                      fontSize: 13,
                    ),
                  ),
                  Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: MerchantPremiumUi.muted,
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSettingsPageHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'ตั้งค่าและบัญชี',
                  style: TextStyle(
                    color: MerchantPremiumUi.ink,
                    fontSize: 30,
                    fontWeight: FontWeight.w900,
                    letterSpacing: -0.7,
                  ),
                ),
                SizedBox(height: 4),
                Text(
                  'จัดการร้าน ความปลอดภัย และข้อมูลบัญชี',
                  style: TextStyle(
                    color: MerchantPremiumUi.muted,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: MerchantPremiumUi.line),
            ),
            child: const Icon(
              Icons.notifications_active_outlined,
              color: AppColors.accentDark,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDeleteAccountCard(User user) {
    return Container(
      margin: const EdgeInsets.only(bottom: 18),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFFFFBFB),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: const Color(0xFFFFCACA)),
        boxShadow: [
          BoxShadow(
            color: Colors.red.withValues(alpha: 0.06),
            blurRadius: 18,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: const BoxDecoration(
              color: Color(0xFFFFE4E6),
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.delete_forever_outlined,
              color: Colors.red.shade700,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'ลบบัญชีถาวร',
                  style: TextStyle(
                    color: Colors.red.shade700,
                    fontSize: 16,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 4),
                const Text(
                  'การลบบัญชีจะไม่สามารถกู้คืนได้ และระบบจะเก็บข้อมูลธุรกรรมบางส่วนตามนโยบาย',
                  style: TextStyle(
                    color: MerchantPremiumUi.muted,
                    fontSize: 12,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          OutlinedButton(
            onPressed: _deletingAccount
                ? null
                : () => _confirmAndDeleteAccount(user),
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.red.shade700,
              side: BorderSide(color: Colors.red.shade200),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(18),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            ),
            child: _deletingAccount
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('ลบบัญชี'),
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

  Future<void> _confirmAndDeleteAccount(User user) async {
    if (_deletingAccount || !mounted) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('ลบบัญชีถาวร'),
        content: const SingleChildScrollView(
          child: Text(
            'เมื่อลบบัญชีแล้ว:\n\n'
            '• คุณจะเข้าสู่ระบบบัญชีเดิมไม่ได้อีก\n'
            '• ร้านและสินค้าจะไม่แสดงให้ลูกค้าเห็น\n'
            '• ระบบจะลบโทเคนแจ้งเตือนและข้อมูลส่วนตัวที่ไม่จำเป็น\n'
            '• ประวัติออเดอร์ กระเป๋าเงิน สัญญา และข้อมูลธุรกรรมที่จำเป็นอาจยังถูกเก็บไว้เพื่อบัญชี ภาษี ความปลอดภัย และข้อพิพาท\n\n'
            'ถ้ามีออเดอร์ที่ยังดำเนินการอยู่ หรือยอดเงิน/รายการถอนที่ต้องเคลียร์ ระบบจะยังไม่ลบทันที',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('ยกเลิก'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('ยืนยันลบบัญชี'),
          ),
        ],
      ),
    );

    if (confirmed != true || !context.mounted) return;

    setState(() => _deletingAccount = true);
    try {
      await AccountDeletionService.instance.deleteCurrentAccount();
      if (!context.mounted) return;
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const WelcomeScreen()),
        (route) => false,
      );
    } on FirebaseFunctionsException catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(e.message ?? 'ไม่สามารถลบบัญชีได้ (${e.code})'),
          backgroundColor: Colors.red,
        ),
      );
    } on FirebaseAuthException catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(e.message ?? 'ยืนยันบัญชีไม่สำเร็จ (${e.code})'),
          backgroundColor: Colors.red,
        ),
      );
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('ไม่สามารถลบบัญชีได้: $e'),
          backgroundColor: Colors.red,
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _deletingAccount = false);
      }
    }
  }

  Future<void> _openShopRegistration(
    DocumentSnapshot<Map<String, dynamic>>? shopDoc,
  ) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ShopRegistrationScreen(shopData: shopDoc),
      ),
    );
    final current = FirebaseAuth.instance.currentUser;
    if (current != null) {
      _shopDataFuture = _loadShopData(current);
    }
    if (mounted) setState(() {});
  }

  Future<void> _showSettingsGroup({
    required String title,
    required Widget Function(StateSetter setModalState) builder,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setModalState) => Container(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.86,
          ),
          decoration: const BoxDecoration(
            color: Color(0xFFFFFBF7),
            borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
          ),
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(height: 10),
                Container(
                  width: 44,
                  height: 5,
                  decoration: BoxDecoration(
                    color: const Color(0xFFD6D3D1),
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 14, 8, 10),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          title,
                          style: const TextStyle(
                            color: MerchantPremiumUi.ink,
                            fontSize: 22,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ),
                      IconButton(
                        onPressed: () => Navigator.of(sheetContext).pop(),
                        icon: const Icon(Icons.close_rounded),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Flexible(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(16),
                    child: Container(
                      decoration: MerchantPremiumUi.cardDecoration(radius: 20),
                      clipBehavior: Clip.antiAlias,
                      child: Material(
                        color: Colors.transparent,
                        child: builder(setModalState),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCompactProfileCard(User user) {
    return FutureBuilder<_ResolvedShopDoc?>(
      future: _shopDataFuture,
      builder: (context, snapshot) {
        final resolved = snapshot.data;
        final shopDoc = resolved?.doc;
        final data = shopDoc?.data() ?? _cachedShopPreview;
        final imageUrl = ShopProfileResolver.resolveImageUrl(data);
        final shopName =
            ShopProfileResolver.resolveName(data) ??
            user.displayName ??
            'ร้านค้า';
        final shopType =
            resolved?.serviceType ?? data?['serviceType']?.toString();
        final hasPhone = data?['phone']?.toString().trim().isNotEmpty == true;
        final hasBank =
            data?['bookBankImageUrl']?.toString().trim().isNotEmpty == true;
        final completeness = hasPhone && hasBank ? 0.9 : 0.7;
        final completenessLabel = '${(completeness * 100).round()}%';

        return Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            gradient: MerchantPremiumUi.heroGradient,
            borderRadius: BorderRadius.circular(26),
            border: Border.all(color: const Color(0xFFF1DDC8)),
            boxShadow: MerchantPremiumUi.softShadow,
          ),
          child: Column(
            children: [
              Row(
                children: [
                  CircleAvatar(
                    radius: 34,
                    backgroundColor: const Color(0xFFFFE6CF),
                    backgroundImage: imageUrl != null && imageUrl.isNotEmpty
                        ? NetworkImage(imageUrl)
                        : null,
                    child: imageUrl == null || imageUrl.isEmpty
                        ? const Icon(
                            Icons.storefront_rounded,
                            size: 34,
                            color: AppColors.accentDark,
                          )
                        : null,
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                shopName,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: MerchantPremiumUi.ink,
                                  fontSize: 20,
                                  fontWeight: FontWeight.w900,
                                ),
                              ),
                            ),
                            const SizedBox(width: 6),
                            const Icon(
                              Icons.verified_rounded,
                              color: AppColors.accent,
                              size: 21,
                            ),
                          ],
                        ),
                        const SizedBox(height: 7),
                        PremiumStatusChip(
                          icon: Icons.circle,
                          label: _pauseNewOrders
                              ? 'พักร้านชั่วคราว'
                              : 'ออนไลน์ / เปิดทำการ',
                          color: _pauseNewOrders
                              ? Colors.orange
                              : MerchantPremiumUi.success,
                        ),
                        if (shopType != null && shopType.trim().isNotEmpty) ...[
                          const SizedBox(height: 5),
                          Text(
                            shopType,
                            style: const TextStyle(
                              color: MerchantPremiumUi.muted,
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      'ความสมบูรณ์ของบัญชี',
                      style: TextStyle(
                        color: MerchantPremiumUi.ink,
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  Text(
                    completenessLabel,
                    style: const TextStyle(
                      color: MerchantPremiumUi.ink,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(999),
                child: LinearProgressIndicator(
                  minHeight: 9,
                  value: completeness,
                  backgroundColor: const Color(0xFFF5E3CF),
                  valueColor: const AlwaysStoppedAnimation(AppColors.accent),
                ),
              ),
              const SizedBox(height: 9),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      completeness >= 0.9
                          ? 'บัญชีพร้อมใช้งานครบถ้วน'
                          : 'เกือบสมบูรณ์! กรอกข้อมูลเพิ่มอีกเล็กน้อย',
                      style: const TextStyle(
                        color: MerchantPremiumUi.muted,
                        fontSize: 11,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: () => _openShopRegistration(shopDoc),
                    child: const Text('ดูรายละเอียด'),
                  ),
                ],
              ),
              Row(
                children: [
                  _buildAccountMetric(
                    icon: Icons.account_balance_wallet_rounded,
                    label: 'ยอดเงินในกระเป๋า',
                    value: 'ดูยอดเงิน',
                  ),
                  const SizedBox(width: 8),
                  _buildAccountMetric(
                    icon: Icons.shopping_bag_rounded,
                    label: 'ออเดอร์วันนี้',
                    value: 'ดูออเดอร์',
                    color: MerchantPremiumUi.success,
                  ),
                  const SizedBox(width: 8),
                  _buildAccountMetric(
                    icon: Icons.inventory_2_rounded,
                    label: 'สต๊อกใกล้หมด',
                    value: 'ดูสินค้า',
                    color: AppColors.accent,
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildMenuButton({
    required IconData icon,
    required Color color,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
    Widget? trailing,
    bool destructive = false,
  }) {
    return Material(
      color: destructive ? const Color(0xFFFFFBFB) : Colors.white,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: destructive
                  ? const Color(0xFFF7D0D0)
                  : const Color(0xFFEAE5DF),
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.055),
                blurRadius: 10,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(icon, color: Colors.white, size: 28),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        color: destructive
                            ? const Color(0xFFB4232D)
                            : MerchantPremiumUi.ink,
                        fontSize: 16,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: MerchantPremiumUi.muted,
                        fontSize: 11.5,
                        height: 1.25,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              trailing ??
                  Icon(
                    Icons.chevron_right_rounded,
                    color: destructive
                        ? const Color(0xFFB4232D)
                        : const Color(0xFF6B7280),
                  ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _sheetList(List<Widget> children) => Column(children: children);

  void _openAccountGroup(User user) {
    _showSettingsGroup(
      title: 'บัญชีร้านค้า',
      builder: (_) => FutureBuilder<_ResolvedShopDoc?>(
        future: _shopDataFuture,
        builder: (context, snapshot) => _sheetList([
          ListTile(
            leading: const Icon(Icons.storefront_outlined),
            title: const Text('ข้อมูลร้านค้าและข้อมูลติดต่อ'),
            subtitle: const Text('โลโก้ ที่อยู่ เบอร์โทร บัญชีธนาคาร'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _openShopRegistration(snapshot.data?.doc),
          ),
          if (user.providerData.any((p) => p.providerId == 'password')) ...[
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.password_rounded),
              title: const Text('เปลี่ยนรหัสผ่าน'),
              trailing: const Icon(Icons.chevron_right),
              onTap: _showChangePasswordDialog,
            ),
          ],
        ]),
      ),
    );
  }

  void _openOperationsGroup() {
    _showSettingsGroup(
      title: 'การดำเนินงานร้าน',
      builder: (setModalState) => _sheetList([
        SwitchListTile(
          value: _autoAcceptOrders,
          onChanged: _operationsReady
              ? (value) async {
                  await _toggleAutoAccept(value);
                  setModalState(() {});
                }
              : null,
          title: const Text('รับออเดอร์อัตโนมัติ'),
          subtitle: const Text('รับคำสั่งซื้อใหม่ทันทีโดยไม่ต้องกดยืนยัน'),
        ),
        const Divider(height: 1),
        SwitchListTile(
          value: _autoListenIncomingOrders,
          onChanged: _operationsReady
              ? (value) async {
                  await _toggleAutoListenIncomingOrders(value);
                  setModalState(() {});
                }
              : null,
          title: const Text('ฟังคำสั่งเสียงอัตโนมัติ'),
          subtitle: const Text('ใช้คำสั่งเสียงรับหรือปฏิเสธออเดอร์'),
        ),
        const Divider(height: 1),
        SwitchListTile(
          value: _pauseNewOrders,
          onChanged: _operationsReady
              ? (value) async {
                  await _togglePauseOrders(value);
                  setModalState(() {});
                }
              : null,
          title: const Text('หยุดรับออเดอร์ชั่วคราว'),
        ),
        const Divider(height: 1),
        ListTile(
          leading: const Icon(Icons.schedule_outlined),
          title: const Text('ตั้งเวลาเปิด-ปิดร้าน'),
          subtitle: Text(
            _operatingHours?.toReadableSummary() ?? 'กำหนดตารางเวลาทำการ',
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: _operationsReady ? _openOperatingHoursEditor : null,
        ),
      ]),
    );
  }

  void _openNotificationsGroup() {
    _showSettingsGroup(
      title: 'การแจ้งเตือนและรายงาน',
      builder: (setModalState) => _sheetList([
        SwitchListTile(
          value: _notifyNewOrders,
          onChanged: _operationsReady
              ? (value) async {
                  await _toggleNotifyNewOrders(value);
                  setModalState(() {});
                }
              : null,
          title: const Text('แจ้งเตือนออเดอร์ใหม่'),
        ),
        const Divider(height: 1),
        SwitchListTile(
          value: _notifyLowStock,
          onChanged: _operationsReady
              ? (value) async {
                  await _toggleLowStockNotification(value);
                  setModalState(() {});
                }
              : null,
          title: const Text('เตือนสต๊อกใกล้หมด'),
        ),
        const Divider(height: 1),
        ListTile(
          leading: const Icon(Icons.inventory_2_outlined),
          title: const Text('รายการสินค้าใกล้หมด'),
          trailing: const Icon(Icons.chevron_right),
          onTap: _operationsReady ? _openLowStockProducts : null,
        ),
        const Divider(height: 1),
        SwitchListTile(
          value: _emailMonthlyReports,
          onChanged: _operationsReady
              ? (value) async {
                  await _toggleEmailMonthlyReports(value);
                  setModalState(() {});
                }
              : null,
          title: const Text('รายงานยอดขายรายเดือนทางอีเมล'),
        ),
        const Divider(height: 1),
        ListTile(
          leading: const Icon(Icons.star_rate_rounded),
          title: const Text('รีวิวสินค้าและร้านค้า'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => const MerchantReviewsScreen(),
            ),
          ),
        ),
      ]),
    );
  }

  void _openSecurityGroup() {
    _showSettingsGroup(
      title: 'ความปลอดภัย',
      builder: (setModalState) => _sheetList([
        SwitchListTile(
          secondary: const Icon(Icons.fingerprint_rounded),
          value: _biometricLoginAvailable && _biometricLoginEnabled,
          onChanged: _biometricLoginLoading
              ? null
              : (value) async {
                  await _toggleBiometricLogin(value);
                  setModalState(() {});
                },
          title: const Text('ลายนิ้วมือและ Face ID'),
          subtitle: Text(
            _biometricLoginAvailable
                ? 'ใช้ยืนยันตัวตนก่อนเข้าแอป'
                : 'อุปกรณ์นี้ยังไม่พร้อมใช้งาน',
          ),
        ),
        const Divider(height: 1),
        ListTile(
          leading: const Icon(Icons.password_rounded),
          title: const Text('เปลี่ยนรหัสผ่าน'),
          trailing: const Icon(Icons.chevron_right),
          onTap: _showChangePasswordDialog,
        ),
      ]),
    );
  }

  void _openHelpGroup(User user) {
    _showSettingsGroup(
      title: 'ศูนย์ช่วยเหลือและนโยบาย',
      builder: (_) => _sheetList([
        ListTile(
          leading: const Icon(Icons.support_agent_outlined),
          title: const Text('ติดต่อแอดมิน'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) =>
                  const AdminContactScreen(config: kVan1AdminSupportConfig),
            ),
          ),
        ),
        ListTile(
          leading: const Icon(Icons.mark_chat_unread_outlined),
          title: const Text('ข้อความถึงแอดมิน'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => const AdminSupportInboxScreen(
                config: kVan1AdminSupportConfig,
                accentColor: Color(0xFF2563EB),
              ),
            ),
          ),
        ),
        const Divider(height: 1),
        ListTile(
          leading: const Icon(Icons.help_outline_rounded),
          title: const Text('ศูนย์ช่วยเหลือ Van Market'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const HelpCenterScreen()),
          ),
        ),
        const Divider(height: 1),
        ListTile(
          leading: const Icon(Icons.policy_outlined),
          title: const Text('นโยบายความเป็นส่วนตัว'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => const LegalDocumentScreen(
                document: LegalContent.privacyPolicy,
              ),
            ),
          ),
        ),
        ListTile(
          leading: const Icon(Icons.description_outlined),
          title: const Text('ข้อกำหนดการใช้บริการ'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => const LegalDocumentScreen(
                document: LegalContent.termsOfService,
              ),
            ),
          ),
        ),
        const Divider(height: 1),
        ListTile(
          leading: const Icon(Icons.logout_rounded, color: Colors.red),
          title: const Text(
            'ออกจากระบบ',
            style: TextStyle(color: Colors.red, fontWeight: FontWeight.w700),
          ),
          onTap: () => _confirmAndSignOut(user),
        ),
        if (_appVersionLabel != null)
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              'เวอร์ชัน $_appVersionLabel',
              style: const TextStyle(color: MerchantPremiumUi.muted),
            ),
          ),
      ]),
    );
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
      backgroundColor: MerchantPremiumUi.pageBackground,
      appBar: AppBar(
        automaticallyImplyLeading: false,
        backgroundColor: MerchantPremiumUi.pageBackground,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        titleSpacing: 14,
        title: const Text(
          'ตั้งค่าและบัญชี',
          style: TextStyle(
            color: MerchantPremiumUi.ink,
            fontSize: 26,
            fontWeight: FontWeight.w900,
          ),
        ),
        actions: [
          Container(
            margin: const EdgeInsets.only(right: 16),
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: Colors.white,
              shape: BoxShape.circle,
              border: Border.all(color: const Color(0xFFD7DDD8)),
            ),
            child: const Icon(
              Icons.verified_user_outlined,
              color: MerchantPremiumUi.success,
            ),
          ),
        ],
      ),
      body: user == null
          ? const Center(child: Text('กรุณาเข้าสู่ระบบ'))
          : SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 28),
              child: Column(
                children: [
                  _buildCompactProfileCard(user),
                  const SizedBox(height: 16),
                  _buildMenuButton(
                    icon: Icons.storefront_rounded,
                    color: AppColors.accent,
                    title: 'บัญชีร้านค้า',
                    subtitle: 'ข้อมูลร้านค้า, ข้อมูลติดต่อ, บัญชีธนาคาร',
                    onTap: () => _openAccountGroup(user),
                  ),
                  const SizedBox(height: 10),
                  _buildMenuButton(
                    icon: Icons.stacked_line_chart_rounded,
                    color: MerchantPremiumUi.success,
                    title: 'การดำเนินงานร้าน',
                    subtitle: 'ตารางเวลา, พนักงาน, โต๊ะ & โซน',
                    onTap: _openOperationsGroup,
                    trailing: Switch(
                      value: !_pauseNewOrders,
                      activeTrackColor: MerchantPremiumUi.success,
                      onChanged: _operationsReady
                          ? (value) => _togglePauseOrders(!value)
                          : null,
                    ),
                  ),
                  const SizedBox(height: 10),
                  _buildMenuButton(
                    icon: Icons.notifications_rounded,
                    color: AppColors.accent,
                    title: 'การแจ้งเตือนและรายงาน',
                    subtitle: 'การแจ้งเตือน, รายงานยอดขาย, สรุปผลประกอบการ',
                    onTap: _openNotificationsGroup,
                  ),
                  const SizedBox(height: 10),
                  _buildMenuButton(
                    icon: Icons.shield_outlined,
                    color: MerchantPremiumUi.success,
                    title: 'ความปลอดภัย',
                    subtitle: 'รหัสผ่าน, การยืนยันตัวตน, อุปกรณ์ที่เชื่อมต่อ',
                    onTap: _openSecurityGroup,
                  ),
                  const SizedBox(height: 10),
                  _buildMenuButton(
                    icon: Icons.headset_mic_rounded,
                    color: AppColors.accent,
                    title: 'ศูนย์ช่วยเหลือและนโยบาย',
                    subtitle: 'ช่วยเหลือ, คู่มือ, ข้อกำหนดและนโยบาย',
                    onTap: () => _openHelpGroup(user),
                  ),
                  const SizedBox(height: 14),
                  _buildMenuButton(
                    icon: Icons.delete_outline_rounded,
                    color: const Color(0xFFDB3445),
                    title: 'ลบบัญชีถาวร',
                    subtitle:
                        'การลบบัญชีจะไม่สามารถกู้คืนได้ ระบบจะเก็บข้อมูลธุรกรรมบางส่วนตามนโยบาย',
                    destructive: true,
                    onTap: _deletingAccount
                        ? () {}
                        : () => _confirmAndDeleteAccount(user),
                    trailing: _deletingAccount
                        ? const SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(
                            Icons.chevron_right_rounded,
                            color: Color(0xFFB4232D),
                          ),
                  ),
                  const SizedBox(height: 16),
                  const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.lock_rounded,
                        size: 13,
                        color: MerchantPremiumUi.muted,
                      ),
                      SizedBox(width: 5),
                      Flexible(
                        child: Text(
                          'ข้อมูลธุรกรรมจะถูกเก็บไว้ตามระยะเวลาที่กฎหมายกำหนด',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: MerchantPremiumUi.muted,
                            fontSize: 10,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
    );
  }

  // เก็บโครงหน้าเดิมไว้ชั่วคราวเพื่อเทียบและย้อนกลับระหว่างทดสอบ UI ใหม่
  // ignore: unused_element
  Widget _buildLegacySettingsScreen(BuildContext context) {
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
      backgroundColor: MerchantPremiumUi.pageBackground,
      appBar: AppBar(
        title: const Text(''),
        // This removes the back button since it's a main tab screen.
        automaticallyImplyLeading: false,
        backgroundColor: MerchantPremiumUi.pageBackground,
        foregroundColor: MerchantPremiumUi.ink,
        surfaceTintColor: MerchantPremiumUi.pageBackground,
        elevation: 0,
      ),
      body: ColoredBox(
        color: MerchantPremiumUi.pageBackground,
        child: Column(
          children: [
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    _buildSettingsPageHeader(),
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
                              final hasPhone = phone?.isNotEmpty == true;

                              return Column(
                                children: [
                                  Container(
                                    width: double.infinity,
                                    margin: const EdgeInsets.all(12),
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 16,
                                      vertical: 20,
                                    ),
                                    decoration: BoxDecoration(
                                      gradient: MerchantPremiumUi.heroGradient,
                                      borderRadius: BorderRadius.circular(24),
                                      border: Border.all(
                                        color: MerchantPremiumUi.line,
                                      ),
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
                                                final current = FirebaseAuth
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
                                        const SizedBox(height: 18),
                                        Row(
                                          children: [
                                            const Expanded(
                                              child: Text(
                                                'ความสมบูรณ์ของบัญชี',
                                                style: TextStyle(
                                                  color: MerchantPremiumUi.ink,
                                                  fontSize: 12,
                                                  fontWeight: FontWeight.w800,
                                                ),
                                              ),
                                            ),
                                            Text(
                                              hasBookBankImage && hasPhone
                                                  ? '90%'
                                                  : '70%',
                                              style: const TextStyle(
                                                color: AppColors.accentDark,
                                                fontWeight: FontWeight.w900,
                                              ),
                                            ),
                                          ],
                                        ),
                                        const SizedBox(height: 8),
                                        ClipRRect(
                                          borderRadius: BorderRadius.circular(
                                            999,
                                          ),
                                          child: LinearProgressIndicator(
                                            minHeight: 10,
                                            value: hasBookBankImage && hasPhone
                                                ? 0.9
                                                : 0.7,
                                            backgroundColor: const Color(
                                              0xFFFFE4CC,
                                            ),
                                            valueColor:
                                                const AlwaysStoppedAnimation<
                                                  Color
                                                >(AppColors.accent),
                                          ),
                                        ),
                                        const SizedBox(height: 14),
                                        Row(
                                          children: [
                                            _buildAccountMetric(
                                              icon:
                                                  Icons.account_balance_wallet,
                                              label: 'บัญชีรับเงิน',
                                              value: hasBookBankImage
                                                  ? 'พร้อมใช้งาน'
                                                  : 'ยังไม่ครบ',
                                            ),
                                            const SizedBox(width: 8),
                                            _buildAccountMetric(
                                              icon: Icons.phone_in_talk,
                                              label: 'เบอร์ติดต่อ',
                                              value: hasPhone
                                                  ? 'ยืนยันแล้ว'
                                                  : 'ยังไม่ระบุ',
                                              color: MerchantPremiumUi.success,
                                            ),
                                          ],
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
                    if (user != null) _buildDeleteAccountCard(user),
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
