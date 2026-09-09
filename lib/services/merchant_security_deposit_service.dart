import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';

import 'merchant_platform_config_service.dart';

class MerchantSecurityDepositService {
  MerchantSecurityDepositService._();

  static final MerchantSecurityDepositService instance =
      MerchantSecurityDepositService._();

  Future<double> getRequiredAmountBaht([String? merchantUid]) {
    return MerchantPlatformConfigService.instance.getSecurityDepositRequiredBaht(
      merchantUid: merchantUid,
    );
  }

  Future<bool> isDepositPaid(String uid) async {
    final trimmedUid = uid.trim();
    if (trimmedUid.isEmpty) {
      return false;
    }

    final requiredAmount = await getRequiredAmountBaht(trimmedUid);
    if (requiredAmount <= 0) {
      return true;
    }

    try {
      final snapshot = await FirebaseFirestore.instance
          .collection('users')
          .doc(trimmedUid)
          .get()
          .timeout(const Duration(seconds: 5));
      final data = snapshot.data() ?? const <String, dynamic>{};
      if (data['merchantSecurityDepositPaid'] == true) {
        return true;
      }
      final paidAmount = _parseAmount(data['merchantSecurityDepositAmount']);
      return paidAmount != null && paidAmount >= requiredAmount;
    } on TimeoutException {
      return false;
    }
  }

  Future<bool> needsDepositGate(String uid) async {
    try {
      final requiredAmount = await getRequiredAmountBaht(uid);
      if (requiredAmount <= 0) {
        return false;
      }
      if (await isDepositPaid(uid)) {
        return false;
      }
      if (await _hasAnyProducts(uid)) {
        return false;
      }
      return true;
    } on TimeoutException {
      return false;
    }
  }

  Future<bool> _hasAnyProducts(String uid) async {
    final products = await FirebaseFirestore.instance
        .collection('products')
        .where('ownerUid', isEqualTo: uid)
        .limit(1)
        .get()
        .timeout(const Duration(seconds: 5));
    if (products.docs.isNotEmpty) {
      return true;
    }

    final pendingReviews = await FirebaseFirestore.instance
        .collection('product_admin_reviews')
        .where('ownerUid', isEqualTo: uid)
        .limit(1)
        .get()
        .timeout(const Duration(seconds: 5));
    return pendingReviews.docs.isNotEmpty;
  }

  double? _parseAmount(Object? value) {
    if (value is num && value.isFinite) {
      return value.toDouble();
    }
    if (value is String) {
      return double.tryParse(value.trim());
    }
    return null;
  }
}
