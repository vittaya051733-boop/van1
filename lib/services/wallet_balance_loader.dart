import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:van1/utils/app_check_guard.dart';

import 'merchant_wallet_service.dart';

class WalletBalanceView {
  const WalletBalanceView({
    required this.creditTotal,
    required this.withdrawableBalance,
    this.minGrossWithdrawAmount = 11,
    this.isRefreshing = false,
    this.fromCache = false,
    this.isContractCancelled = false,
    this.securityDepositAmount = 0,
  });

  final double creditTotal;
  final double withdrawableBalance;
  final double minGrossWithdrawAmount;
  final bool isRefreshing;
  final bool fromCache;
  final bool isContractCancelled;
  final double securityDepositAmount;

  bool get canWithdraw => withdrawableBalance >= minGrossWithdrawAmount;

  static const zero = WalletBalanceView(
    creditTotal: 0,
    withdrawableBalance: 0,
  );

  WalletBalanceView copyWith({
    double? creditTotal,
    double? withdrawableBalance,
    double? minGrossWithdrawAmount,
    bool? isRefreshing,
    bool? fromCache,
    bool? isContractCancelled,
    double? securityDepositAmount,
  }) {
    return WalletBalanceView(
      creditTotal: creditTotal ?? this.creditTotal,
      withdrawableBalance: withdrawableBalance ?? this.withdrawableBalance,
      minGrossWithdrawAmount:
          minGrossWithdrawAmount ?? this.minGrossWithdrawAmount,
      isRefreshing: isRefreshing ?? this.isRefreshing,
      fromCache: fromCache ?? this.fromCache,
      isContractCancelled: isContractCancelled ?? this.isContractCancelled,
      securityDepositAmount:
          securityDepositAmount ?? this.securityDepositAmount,
    );
  }
}

/// Balanced wallet load: disk/doc cache first, then authoritative CF refresh.
class WalletBalanceLoader {
  WalletBalanceLoader._();

  static final WalletBalanceLoader instance = WalletBalanceLoader._();

  static const String _cacheKeyPrefix = 'wallet_balance_balanced_v1_';
  static const int historyCreditsLimit = 50;
  static const int historyOrdersLimit = 50;
  static const int todayDeliveredScanLimit = 50;

  FirebaseFunctions get _functions =>
      FirebaseFunctions.instanceFor(region: 'asia-southeast1');

  Future<WalletBalanceView> loadBalanced({
    required String uid,
    required String actorType,
    void Function(WalletBalanceView view)? onUpdate,
  }) async {
    final trimmedUid = uid.trim();
    if (trimmedUid.isEmpty) {
      return WalletBalanceView.zero;
    }

    void publish(WalletBalanceView view) {
      onUpdate?.call(view);
    }

    final cached = await _readDiskCache(trimmedUid);
    if (cached != null) {
      publish(cached.copyWith(fromCache: true));
    }

    WalletBalanceView? lastView = cached;

    if (actorType == 'merchant') {
      final docView = await _readMerchantWalletDoc(trimmedUid);
      if (docView != null) {
        lastView = docView;
        publish(docView);
        unawaited(_saveDiskCache(trimmedUid, docView));
      }
    }

    publish((lastView ?? WalletBalanceView.zero).copyWith(isRefreshing: true));

    try {
      await AppCheckGuard.ensureFinancialReady();
      final result = await _functions
          .httpsCallable('getWithdrawableBalance')
          .call(<String, dynamic>{'actorType': actorType})
          .timeout(const Duration(seconds: 12));
      final data = result.data is Map
          ? Map<String, dynamic>.from(result.data as Map)
          : const <String, dynamic>{};
      final withdrawable =
          (data['availableBalance'] as num?)?.toDouble() ?? 0;
      final creditTotal =
          (data['creditTotal'] as num?)?.toDouble() ?? withdrawable;
      final minGrossWithdraw =
          (data['minGrossWithdrawAmount'] as num?)?.toDouble() ?? 11;

      MerchantWalletSnapshot? merchantSnapshot;
      if (actorType == 'merchant') {
        merchantSnapshot = await MerchantWalletService.instance
            .readFirestoreSnapshot(trimmedUid);
      }

      final fresh = WalletBalanceView(
        creditTotal: creditTotal,
        withdrawableBalance: withdrawable,
        minGrossWithdrawAmount: minGrossWithdraw,
        isRefreshing: false,
        fromCache: false,
        isContractCancelled: data['isContractCancelled'] == true,
        securityDepositAmount: merchantSnapshot?.securityDepositAmount ?? 0,
      );
      publish(fresh);
      unawaited(_saveDiskCache(trimmedUid, fresh));
      return fresh;
    } catch (_) {
      if (cached != null) {
        final fallback = cached.copyWith(isRefreshing: false, fromCache: true);
        publish(fallback);
        return fallback;
      }
      if (actorType == 'merchant') {
        final docView = await _readMerchantWalletDoc(trimmedUid);
        if (docView != null) {
          publish(docView.copyWith(isRefreshing: false));
          return docView;
        }
      }
      const empty = WalletBalanceView.zero;
      publish(empty);
      return empty;
    }
  }

  Future<WalletBalanceView?> _readMerchantWalletDoc(String uid) async {
    final ref =
        FirebaseFirestore.instance.collection('merchant_wallets').doc(uid);

    DocumentSnapshot<Map<String, dynamic>> snapshot;
    try {
      snapshot = await ref.get(
        const GetOptions(source: Source.cache),
      );
      if (!snapshot.exists) {
        snapshot = await ref.get(
          const GetOptions(source: Source.server),
        );
      }
    } catch (_) {
      try {
        snapshot = await ref.get();
      } catch (_) {
        return null;
      }
    }

    if (!snapshot.exists) {
      return null;
    }

    final wallet = MerchantWalletSnapshot.fromMap(
      snapshot.data() ?? const <String, dynamic>{},
    );
    final withdrawable = wallet.withdrawableCredit > 0
        ? wallet.withdrawableCredit
        : wallet.totalCredit;

    return WalletBalanceView(
      creditTotal: wallet.totalCredit,
      withdrawableBalance: withdrawable,
      isContractCancelled: wallet.isContractCancelled,
      securityDepositAmount: wallet.securityDepositAmount,
    );
  }

  Future<WalletBalanceView?> _readDiskCache(String uid) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('$_cacheKeyPrefix$uid');
    if (raw == null || raw.isEmpty) {
      return null;
    }

    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      return WalletBalanceView(
        creditTotal: (decoded['creditTotal'] as num?)?.toDouble() ?? 0,
        withdrawableBalance:
            (decoded['withdrawableBalance'] as num?)?.toDouble() ?? 0,
        minGrossWithdrawAmount:
            (decoded['minGrossWithdrawAmount'] as num?)?.toDouble() ?? 11,
        isContractCancelled: decoded['isContractCancelled'] == true,
        securityDepositAmount:
            (decoded['securityDepositAmount'] as num?)?.toDouble() ?? 0,
        fromCache: true,
      );
    } catch (_) {
      await prefs.remove('$_cacheKeyPrefix$uid');
      return null;
    }
  }

  Future<void> _saveDiskCache(String uid, WalletBalanceView view) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      '$_cacheKeyPrefix$uid',
      jsonEncode(<String, dynamic>{
        'creditTotal': view.creditTotal,
        'withdrawableBalance': view.withdrawableBalance,
        'minGrossWithdrawAmount': view.minGrossWithdrawAmount,
        'isContractCancelled': view.isContractCancelled,
        'securityDepositAmount': view.securityDepositAmount,
        'savedAt': DateTime.now().millisecondsSinceEpoch,
      }),
    );
  }
}
