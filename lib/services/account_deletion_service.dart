import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';

import '../ios_apple_auth.dart';
import 'product_add_draft_store.dart';
import 'shop_profile_cache_service.dart';

class AccountDeletionResult {
  const AccountDeletionResult({
    required this.deleted,
    this.deletedAt,
    this.retainedRecords = const <String>[],
  });

  final bool deleted;
  final String? deletedAt;
  final List<String> retainedRecords;

  factory AccountDeletionResult.fromMap(Map<String, dynamic> data) {
    return AccountDeletionResult(
      deleted: data['deleted'] == true,
      deletedAt: data['deletedAt'] as String?,
      retainedRecords: (data['retainedRecords'] as List<dynamic>? ?? const [])
          .map((value) => value.toString())
          .toList(growable: false),
    );
  }
}

class AccountDeletionService {
  AccountDeletionService._();

  static final AccountDeletionService instance = AccountDeletionService._();

  FirebaseFunctions get _functions =>
      FirebaseFunctions.instanceFor(region: 'asia-southeast1');

  Future<AccountDeletionResult> deleteCurrentAccount() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      throw FirebaseAuthException(
        code: 'no-current-user',
        message: 'ไม่พบบัญชีที่เข้าสู่ระบบ',
      );
    }

    final uid = user.uid;
    await _assertAccountCanBeDeleted();
    await _revokeAppleCredentialIfNeeded(user);

    final result = await _functions
        .httpsCallable('deleteMerchantAccount')
        .call(<String, dynamic>{});
    final data = result.data is Map
        ? Map<String, dynamic>.from(result.data as Map)
        : const <String, dynamic>{};

    await _clearLocalAccountState(uid, user);
    return AccountDeletionResult.fromMap(data);
  }

  Future<void> _assertAccountCanBeDeleted() {
    return _functions.httpsCallable('deleteMerchantAccount').call(
      <String, dynamic>{'dryRun': true},
    );
  }

  Future<void> _revokeAppleCredentialIfNeeded(User user) async {
    final usesApple = user.providerData.any(
      (provider) => provider.providerId == 'apple.com',
    );
    if (!usesApple || kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) {
      return;
    }

    final authorizationCode =
        await requestAppleAuthorizationCodeForTokenRevocation();
    await FirebaseAuth.instance.revokeTokenWithAuthorizationCode(
      authorizationCode,
    );
  }

  Future<void> _clearLocalAccountState(String uid, User user) async {
    await ShopProfileCacheService.instance.clearProfile(uid);
    await ProductAddDraftStore.instance.clear(uid);

    final usesGoogle = user.providerData.any(
      (provider) => provider.providerId == 'google.com',
    );
    if (usesGoogle && !kIsWeb) {
      await GoogleSignIn.instance.signOut();
    }

    await FirebaseAuth.instance.signOut();
  }
}
