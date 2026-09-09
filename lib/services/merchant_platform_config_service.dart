import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';

import '../data/merchant_security_deposit.dart';

/// Reads merchant deposit settings (van4 admin writes).
class MerchantPlatformConfigService {
  MerchantPlatformConfigService._();

  static final MerchantPlatformConfigService instance =
      MerchantPlatformConfigService._();

  static const String globalDocPath = 'platform_config/merchant';
  static const Duration _cacheTtl = Duration(minutes: 5);

  double? _cachedGlobalSecurityDepositRequiredBaht;
  DateTime? _globalCacheExpiresAt;
  final Map<String, _ShopDepositCacheEntry> _shopCache = <String, _ShopDepositCacheEntry>{};

  Future<double> getSecurityDepositRequiredBaht({String? merchantUid}) async {
    final trimmedUid = merchantUid?.trim() ?? '';
    if (trimmedUid.isNotEmpty) {
      final shopAmount = await _readShopRequiredAmount(trimmedUid);
      if (shopAmount != null) {
        return shopAmount;
      }
    }
    return _readGlobalRequiredAmount();
  }

  Future<double?> _readShopRequiredAmount(String merchantUid) async {
    final cached = _shopCache[merchantUid];
    if (cached != null && DateTime.now().isBefore(cached.expiresAt)) {
      return cached.amount;
    }

    try {
      final snapshot = await FirebaseFirestore.instance
          .collection('public_shops')
          .doc(merchantUid)
          .get()
          .timeout(const Duration(seconds: 5));
      if (!snapshot.exists) {
        return null;
      }
      final amount = _parseAmount(snapshot.data()?['securityDepositRequiredBaht']);
      if (amount != null && amount >= 0) {
        _shopCache[merchantUid] = _ShopDepositCacheEntry(
          amount: amount,
          expiresAt: DateTime.now().add(_cacheTtl),
        );
        return amount;
      }
    } on TimeoutException {
      return null;
    } catch (_) {
      return null;
    }
    return null;
  }

  Future<double> _readGlobalRequiredAmount() async {
    final cached = _cachedGlobalSecurityDepositRequiredBaht;
    final expiresAt = _globalCacheExpiresAt;
    if (cached != null &&
        expiresAt != null &&
        DateTime.now().isBefore(expiresAt)) {
      return cached;
    }

    try {
      final snapshot = await FirebaseFirestore.instance
          .doc(globalDocPath)
          .get()
          .timeout(const Duration(seconds: 5));
      final amount = _parseAmount(snapshot.data()?['securityDepositRequiredBaht']);
      if (amount != null && amount >= 0) {
        _rememberGlobal(amount);
        return amount;
      }
    } on TimeoutException {
      // fall through
    } catch (_) {
      // fall through
    }

    final fallback = MerchantSecurityDepositPolicy.defaultRequiredAmountBaht;
    _rememberGlobal(fallback);
    return fallback;
  }

  void _rememberGlobal(double amount) {
    _cachedGlobalSecurityDepositRequiredBaht = amount;
    _globalCacheExpiresAt = DateTime.now().add(_cacheTtl);
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

class _ShopDepositCacheEntry {
  const _ShopDepositCacheEntry({
    required this.amount,
    required this.expiresAt,
  });

  final double amount;
  final DateTime expiresAt;
}
