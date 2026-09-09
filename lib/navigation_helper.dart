import 'dart:async';

import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

import 'services/pending_registration_service.dart';
import 'services/shop_profile_cache_service.dart';

/// Helper class สำหรับตรวจสอบสถานะการลงทะเบียนและนำทางไปหน้าที่เหมาะสม
class NavigationHelper {
  static const Duration _firestoreTimeout = Duration(seconds: 12);
  /// ตรวจสอบสถานะและนำทางไปหน้าที่เหมาะสม
  static Future<void> navigateBasedOnUserStatus(
    BuildContext context,
    User user, {
    bool replace = true,
  }) async {
  try {
      final cachedShop =
          await ShopProfileCacheService.instance.loadProfile(user.uid);
      if (_hasCompletedShopProfile(cachedShop) && context.mounted) {
        debugPrint('Auth nav: cached shop profile, opening home');
        _navigate(context, '/home', replace: replace);
        unawaited(PendingRegistrationService.applyIfNeeded(user));
        return;
      }

      final appliedServiceType =
          await PendingRegistrationService.applyIfNeeded(user).timeout(
        const Duration(seconds: 4),
        onTimeout: () => null,
      );

      final shopLookup = await _fetchShopRegistration(user.uid).timeout(
        const Duration(seconds: 6),
      );
      final bool hasCompletedShopProfile = _hasCompletedShopProfile(shopLookup.data);

      // หากลงทะเบียนร้านครบถ้วนแล้ว ให้ไปหน้าโฮมทันที ไม่ต้องยืนยันอีเมล/เบอร์ซ้ำ
      if (hasCompletedShopProfile && context.mounted) {
        _navigate(context, '/home', replace: replace);
        return;
      }

      final bool hasEmail = user.email?.isNotEmpty ?? false;
      final bool requiresEmailVerification = hasEmail &&
          user.providerData.any((info) => info.providerId == 'password');

      if (requiresEmailVerification && !user.emailVerified && context.mounted) {
        String? serviceType = appliedServiceType;
        if (serviceType == null) {
          final contractDoc = await FirebaseFirestore.instance
              .collection('contracts')
              .doc(user.uid)
              .get()
              .timeout(_firestoreTimeout);
          serviceType = contractDoc.data()?['serviceType'] as String?;
        }
        _navigate(
          context,
          '/email-verification',
          replace: replace,
          arguments: {
            'serviceType': serviceType,
            'nextRoute': 'contract',
          },
        );
        return;
      }

      // 1. ตรวจสอบว่าเคยเซ็นสัญญาหรือยัง
      final contractDoc = await FirebaseFirestore.instance
          .collection('contracts')
          .doc(user.uid)
          .get()
          .timeout(_firestoreTimeout);

      if ((!contractDoc.exists || contractDoc.data()?['status'] != 'accepted') && context.mounted) {
        // ยังไม่เซ็นสัญญา -> ไปหน้าเซ็นสัญญา
        _navigate(
          context, 
          '/contract', 
          replace: replace, 
          arguments: contractDoc.data()?['serviceType'] as String?); // ส่ง serviceType ไปด้วย
        return;
      }

      // 2. เซ็นสัญญาแล้ว -> ตรวจสอบว่าลงทะเบียนร้านค้าหรือยัง
      // ตรวจสอบในทุก collection ที่เป็นไปได้
      if (!context.mounted) return;

      if (shopLookup.doc == null || !shopLookup.doc!.exists || !_hasCompletedShopProfile(shopLookup.data)) {
        // ยังไม่ได้ลงทะเบียนร้านค้า -> ไปหน้าลงทะเบียนร้านค้า
        _navigate(
          context,
          '/shop-registration',
          replace: replace,
          arguments: contractDoc.data()?['serviceType'] as String? ?? '',
        );
        return;
      }

      // 3. ลงทะเบียนครบถ้วนแล้ว -> ไปหน้า Home
      if (context.mounted) {
        _navigate(context, '/home', replace: replace);
      }
    } catch (e, stackTrace) {
      debugPrint('Error in navigateBasedOnUserStatus: $e\n$stackTrace');
      if (!context.mounted) return;
      // อย่าค้างที่ AuthWrapper — โยน error ให้ caller จัดการ fallback/retry
      rethrow;
    }
  }

  static void _navigate(
    BuildContext context,
    String routeName, {
    bool replace = true,
    Object? arguments,
  }) {
    if (!context.mounted) return;

    if (replace) {
      Navigator.of(context).pushReplacementNamed(
        routeName,
        arguments: arguments,
      );
    } else {
      Navigator.of(context).pushNamed(
        routeName,
        arguments: arguments,
      );
    }
  }

  static bool _hasCompletedShopProfile(Map<String, dynamic>? data) {
    if (data == null) return false;

    final completedFlag = data['isProfileCompleted'];
    if (completedFlag is bool && completedFlag) {
      return true;
    }

    final status = (data['status'] as String?)?.toLowerCase();
    final hasCoreFields =
        (data['name']?.toString().isNotEmpty ?? false) &&
        (data['address']?.toString().isNotEmpty ?? false) &&
        (data['shopImageUrl']?.toString().isNotEmpty ?? false) &&
        (data['bankName']?.toString().isNotEmpty ?? false);

    if (status == null || status == 'pending_contract') {
      return false;
    }

    return hasCoreFields;
  }

  static String _collectionForServiceName(String serviceType) {
    switch (serviceType) {
      case 'ตลาด':
        return 'market_registrations';
      case 'ร้านค้า':
        return 'shop_registrations';
      case 'ร้านอาหาร':
        return 'restaurant_registrations';
      case 'ร้านขายยา':
        return 'pharmacy_registrations';
      default:
        return 'shop_registrations';
    }
  }

  /// ตรวจสอบว่า user ลงทะเบียนครบถ้วนหรือยัง
  static Future<bool> isRegistrationComplete(String userId) async {
    try {
      final contractDoc = await FirebaseFirestore.instance
          .collection('contracts')
          .doc(userId)
          .get();

      if (!contractDoc.exists || contractDoc.data()?['status'] != 'accepted') {
        return false;
      }

      final serviceType = contractDoc.data()?['serviceType'] as String?;
      if (serviceType == null) return false; // ถ้าไม่มี serviceType ก็ยังไม่สมบูรณ์
      final collectionName = _collectionForServiceName(serviceType);
      final shopDoc = await FirebaseFirestore.instance
          .collection(collectionName)
          .doc(userId)
          .get();

      if (!shopDoc.exists) {
        return false;
      }

      return _hasCompletedShopProfile(shopDoc.data());
    } catch (e) {
      debugPrint('Error checking registration status: $e');
      return false;
    }
  }

  /// ตรวจสอบการลงทะเบียนร้านค้าโดยใช้อีเมล (ไม่พึ่งข้อมูลสัญญา)
  static Future<bool> isShopRegisteredByEmail(String email) async {
    try {
      final collections = [
        'market_registrations',
        'shop_registrations',
        'restaurant_registrations',
        'pharmacy_registrations',
      ];
      for (final col in collections) {
        final snap = await FirebaseFirestore.instance
            .collection(col)
            .where('email', isEqualTo: email)
            .limit(1)
            .get()
            .timeout(_firestoreTimeout);
        if (snap.docs.isNotEmpty) return true;
      }
      return false;
    } on TimeoutException {
      debugPrint('Shop-by-email lookup timed out');
      rethrow;
    } catch (e) {
      debugPrint('Error checking shop by email: $e');
      return false;
    }
  }

  /// ดึงข้อมูลร้านค้า (ต้องระบุ serviceType)
  static Future<Map<String, dynamic>?> getShopData(String userId, String serviceType) async {
    try {
      final shopDoc = await FirebaseFirestore.instance
          .collection(serviceType)
          .doc(userId)
          .get();

      return shopDoc.data();
    } catch (e) {
      debugPrint('Error getting shop data: $e');
      return null;
    }
  }

  /// ดึงข้อมูลสัญญา
  static Future<Map<String, dynamic>?> getContractData(String userId) async {
    try {
      final contractDoc = await FirebaseFirestore.instance
          .collection('contracts')
          .doc(userId)
          .get();

      return contractDoc.data();
    } catch (e) {
      debugPrint('Error getting contract data: $e');
      return null;
    }
  }

  static Future<_ShopRegistrationLookup> _fetchShopRegistration(String userId) async {
    String? preferredCollection;
    try {
      final contractDoc = await FirebaseFirestore.instance
          .collection('contracts')
          .doc(userId)
          .get()
          .timeout(_firestoreTimeout);
      final serviceType = contractDoc.data()?['serviceType'] as String?;
      if (serviceType != null && serviceType.trim().isNotEmpty) {
        preferredCollection = _collectionForServiceName(serviceType);
        final preferredDoc = await FirebaseFirestore.instance
            .collection(preferredCollection)
            .doc(userId)
            .get()
            .timeout(_firestoreTimeout);
        if (preferredDoc.exists) {
          return _ShopRegistrationLookup(
            doc: preferredDoc,
            data: preferredDoc.data(),
            collection: preferredCollection,
          );
        }
      }
    } catch (e) {
      debugPrint('Shop registration contract lookup failed: $e');
    }

    const possibleCollections = <String>[
      'shop_registrations',
      'market_registrations',
      'restaurant_registrations',
      'pharmacy_registrations',
    ];

    final lookups = await Future.wait(
      possibleCollections
          .where((collectionName) => collectionName != preferredCollection)
          .map((collectionName) async {
            try {
              final doc = await FirebaseFirestore.instance
                  .collection(collectionName)
                  .doc(userId)
                  .get()
                  .timeout(_firestoreTimeout);
              if (doc.exists) {
                return _ShopRegistrationLookup(
                  doc: doc,
                  data: doc.data(),
                  collection: collectionName,
                );
              }
            } catch (_) {}
            return const _ShopRegistrationLookup();
          }),
    );

    for (final lookup in lookups) {
      if (lookup.doc != null) {
        return lookup;
      }
    }

    return const _ShopRegistrationLookup();
  }
}

class _ShopRegistrationLookup {
  const _ShopRegistrationLookup({this.doc, this.data, this.collection});

  final DocumentSnapshot<Map<String, dynamic>>? doc;
  final Map<String, dynamic>? data;
  final String? collection;
}
