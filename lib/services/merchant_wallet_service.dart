import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:van1/utils/app_check_guard.dart';

class MerchantWalletSnapshot {
  const MerchantWalletSnapshot({
    required this.totalCredit,
    required this.withdrawableCredit,
    required this.lockedCredit,
    required this.canWithdraw,
    required this.isContractCancelled,
    required this.securityDepositAmount,
    this.contractStatus = 'active',
    this.syncedByCloudFunction = false,
    this.omisePendingCredit = 0,
    this.omiseWithdrawableCredit = 0,
  });

  final double totalCredit;
  final double withdrawableCredit;
  final double lockedCredit;
  final bool canWithdraw;
  final bool isContractCancelled;
  final double securityDepositAmount;
  final String contractStatus;
  final bool syncedByCloudFunction;

  /// รายได้จากออเดอร์ที่แอดมินตั้งเวลาพักไว้ — ยังถอนไม่ได้
  final double omisePendingCredit;

  /// รายได้ที่ปล่อยให้ถอนได้แล้ว
  final double omiseWithdrawableCredit;

  factory MerchantWalletSnapshot.fromMap(Map<String, dynamic> data) {
    return MerchantWalletSnapshot(
      totalCredit: _parseMoney(data['totalCredit']),
      withdrawableCredit: _parseMoney(data['withdrawableCredit']),
      lockedCredit: _parseMoney(data['lockedCredit']),
      canWithdraw: data['canWithdraw'] == true,
      isContractCancelled: data['isContractCancelled'] == true,
      securityDepositAmount: _parseMoney(data['securityDepositAmount']),
      contractStatus: data['contractStatus']?.toString() ?? 'active',
      syncedByCloudFunction: data['syncedBy'] == 'cloud_function',
      omisePendingCredit: _parseMoney(data['omisePendingCredit']),
      omiseWithdrawableCredit: _parseMoney(data['omiseWithdrawableCredit']),
    );
  }

  static double _parseMoney(Object? value) {
    if (value is num) {
      return value.toDouble();
    }
    if (value is String) {
      return double.tryParse(value.trim()) ?? 0;
    }
    return 0;
  }

  static const empty = MerchantWalletSnapshot(
    totalCredit: 0,
    withdrawableCredit: 0,
    lockedCredit: 0,
    canWithdraw: false,
    isContractCancelled: false,
    securityDepositAmount: 0,
    omisePendingCredit: 0,
    omiseWithdrawableCredit: 0,
  );
}

class MerchantWalletService {
  MerchantWalletService._();

  static final MerchantWalletService instance = MerchantWalletService._();

  static const _walletCollection = 'merchant_wallets';

  FirebaseFunctions get _functions =>
      FirebaseFunctions.instanceFor(region: 'asia-southeast1');

  Future<MerchantWalletSnapshot> loadSnapshot(String uid) async {
    final trimmedUid = uid.trim();
    if (trimmedUid.isEmpty) {
      return MerchantWalletSnapshot.empty;
    }

    try {
      await AppCheckGuard.ensureFinancialReady();
      final result = await _functions.httpsCallable('getMerchantWallet').call(
        <String, dynamic>{'merchantUid': trimmedUid},
      );
      final data = result.data is Map
          ? Map<String, dynamic>.from(result.data as Map)
          : const <String, dynamic>{};
      return MerchantWalletSnapshot.fromMap(data);
    } on FirebaseFunctionsException {
      return _loadSnapshotFromFirestore(trimmedUid);
    }
  }

  Future<MerchantWalletSnapshot> _loadSnapshotFromFirestore(String uid) async {
    final doc = await FirebaseFirestore.instance
        .collection(_walletCollection)
        .doc(uid)
        .get();
    if (!doc.exists) {
      return MerchantWalletSnapshot.empty;
    }
    return MerchantWalletSnapshot.fromMap(doc.data() ?? const <String, dynamic>{});
  }

  Future<MerchantWalletSnapshot> readFirestoreSnapshot(String uid) async {
    return _loadSnapshotFromFirestore(uid.trim());
  }

  Stream<MerchantWalletSnapshot> watchFirestoreSnapshot(String uid) async* {
    final trimmedUid = uid.trim();
    if (trimmedUid.isEmpty) {
      yield MerchantWalletSnapshot.empty;
      return;
    }

    yield await readFirestoreSnapshot(trimmedUid);

    await for (final snapshot in FirebaseFirestore.instance
        .collection(_walletCollection)
        .doc(trimmedUid)
        .snapshots()) {
      if (!snapshot.exists) {
        yield MerchantWalletSnapshot.empty;
        continue;
      }
      yield MerchantWalletSnapshot.fromMap(
        snapshot.data() ?? const <String, dynamic>{},
      );
    }
  }

  Future<MerchantWalletSnapshot> refreshForCurrentUser() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null || uid.trim().isEmpty) {
      return MerchantWalletSnapshot.empty;
    }
    return loadSnapshot(uid);
  }
}
