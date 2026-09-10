import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import '../models/user_profile.dart';
import '../utils/shop_profile_resolver.dart';

class FriendService {
  FriendService._();

  static final FriendService instance = FriendService._();

  factory FriendService() => instance;

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  static const Duration _cacheTtl = Duration(minutes: 5);
  static const int _perCollectionSearchLimit = 40;
  static const int _perCollectionSuggestionLimit = 25;
  final Map<String, _ProfileCacheEntry> _searchCache =
      <String, _ProfileCacheEntry>{};
  final Map<String, _ProfileCacheEntry> _suggestionCache =
      <String, _ProfileCacheEntry>{};

  static const List<String> _shopCollections = <String>[
    'market_registrations',
    'shop_registrations',
    'restaurant_registrations',
    'pharmacy_registrations',
  ];

  static const Set<String> _transientFirestoreCodes = <String>{
    'unavailable',
    'deadline-exceeded',
    'resource-exhausted',
    'aborted',
    'internal',
  };

  Future<T> _withFirestoreRetry<T>(
    Future<T> Function() action, {
    int maxAttempts = 3,
  }) async {
    Object? lastError;
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        return await action();
      } on FirebaseException catch (error) {
        lastError = error;
        final isTransient = _transientFirestoreCodes.contains(error.code);
        if (!isTransient || attempt >= maxAttempts) {
          rethrow;
        }
        final delayMs = 250 * (1 << (attempt - 1));
        if (kDebugMode && attempt == 1) {
          debugPrint(
            'Firestore transient ${error.code}, retrying up to $maxAttempts times',
          );
        }
        await Future<void>.delayed(Duration(milliseconds: delayMs));
      }
    }
    throw lastError ?? StateError('Firestore retry failed');
  }

  Future<DocumentSnapshot<Map<String, dynamic>>> _getDocument(
    DocumentReference<Map<String, dynamic>> ref,
  ) {
    return _withFirestoreRetry(ref.get);
  }

  Future<QuerySnapshot<Map<String, dynamic>>> _runQuery(
    Query<Map<String, dynamic>> query,
  ) {
    return _withFirestoreRetry(query.get);
  }

  Stream<List<FriendPreview>> watchFriends(String ownerId) {
    final ref = _firestore
        .collection('users')
        .doc(ownerId)
        .collection('friends')
        .orderBy('lastActivity', descending: true);

    return ref.snapshots().asyncExpand((snapshot) async* {
      if (snapshot.docs.isEmpty) {
        yield const <FriendPreview>[];
        return;
      }

      final fastPreviews = snapshot.docs
          .map(FriendPreview.fromSnapshot)
          .toList(growable: false);
      final needsEnrichment = snapshot.docs.any(
        (doc) => !friendDocHasDisplayProfile(doc.data()),
      );

      if (!needsEnrichment) {
        yield fastPreviews;
        return;
      }

      yield fastPreviews;

      try {
        final enriched = await Future.wait(
          snapshot.docs.map((doc) => _buildFriendPreview(ownerId, doc)),
        );
        if (!FriendPreview.listsEqual(fastPreviews, enriched)) {
          yield enriched;
        }
      } catch (error) {
        debugPrint('Friend preview enrichment failed: $error');
      }
    });
  }

  static bool friendDocHasDisplayProfile(Map<String, dynamic> data) {
    final name = (data['displayName'] ?? data['name'] ?? '').toString().trim();
    final photo = (data['photoUrl'] ??
            data['imageUrl'] ??
            data['shopImageUrl'] ??
            '')
        .toString()
        .trim();
    return name.isNotEmpty &&
        name != 'ผู้ใช้ใหม่' &&
        photo.isNotEmpty;
  }

  Future<UserProfile?> ensureCurrentUserProfile(User user) async {
    final docRef = _firestore.collection('users').doc(user.uid);
    final snapshot = await _getDocument(docRef);
    final profile = await _resolveCanonicalProfile(
      user.uid,
      userData: snapshot.data(),
      fallbackDisplayName: user.displayName ?? user.email ?? 'ร้านของฉัน',
      fallbackPhotoUrl: user.photoURL,
      fallbackPhoneNumber: user.phoneNumber,
    );
    if (profile == null) {
      return null;
    }
    await _syncUserProfileDoc(docRef, snapshot.data(), profile);
    return profile;
  }

  Future<UserProfile?> getProfile(String uid) async {
    final snapshot = await _getDocument(_firestore.collection('users').doc(uid));
    final profile = await _resolveCanonicalProfile(
      uid,
      userData: snapshot.data(),
    );
    if (profile == null) {
      return null;
    }
    try {
      await _syncUserProfileDoc(snapshot.reference, snapshot.data(), profile);
    } catch (_) {
      // อ่านโปรไฟล์ผู้ใช้อื่นได้ แต่เขียน users/{uid} ของคนอื่นไม่ได้ — ข้ามไป
    }
    return profile;
  }

  Future<UserProfile?> findUserByPhone(String rawInput) async {
    final normalized = _normalizePhone(rawInput);
    if (normalized.isEmpty) return null;

    final directQuery = await _runQuery(
      _firestore
          .collection('users')
          .where('phoneNumber', isEqualTo: normalized)
          .limit(1),
    );
    if (directQuery.docs.isNotEmpty) {
      return UserProfile.fromSnapshot(directQuery.docs.first);
    }

    for (final collection in _shopCollections) {
      final query = await _runQuery(
        _firestore
            .collection(collection)
            .where('phone', isEqualTo: normalized)
            .limit(1),
      );
      if (query.docs.isEmpty) continue;
      final doc = query.docs.first;
      final data = doc.data();
      final profile = UserProfile(
        uid: doc.id,
        displayName: _readDisplayName(data, fallback: 'ผู้ใช้ใหม่'),
        phoneNumber: normalized,
        photoUrl: _readPhotoUrl(data),
        serviceType: (data['serviceType'] as String?) ?? collection,
        isOfficial: (data['isOfficialAccount'] as bool?) ?? false,
        profileCompleted: (data['isProfileCompleted'] as bool?) ?? false,
      );

      await _firestore.collection('users').doc(doc.id).set(<String, dynamic>{
        ...profile.toFirestore(),
        'phoneNumber': normalized,
        'createdAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
      return profile;
    }
    return null;
  }

  Future<List<UserProfile>> searchProfilesByName(
    String keyword, {
    int limit = 20,
  }) async {
    final normalized = keyword.trim().toLowerCase();
    if (normalized.isEmpty) return const <UserProfile>[];
    final cached = _readCache(_searchCache, normalized);
    if (cached != null) {
      return cached.length <= limit ? cached : cached.sublist(0, limit);
    }

    final futures = _shopCollections
        .map(
          (collection) => _runQuery(
            _firestore.collection(collection).limit(_perCollectionSearchLimit),
          ),
        )
        .toList(growable: false);

    final snapshots = await Future.wait(futures);
    final results = <UserProfile>[];
    final seen = <String>{};

    for (var i = 0; i < snapshots.length; i++) {
      final snapshot = snapshots[i];
      final collection = _shopCollections[i];
      for (final doc in snapshot.docs) {
        if (seen.contains(doc.id)) continue;
        final data = doc.data();
        final name = _readDisplayName(data, fallback: '').trim();
        if (name.isEmpty) continue;
        if (!name.toLowerCase().contains(normalized)) continue;

        seen.add(doc.id);
        results.add(
          UserProfile(
            uid: doc.id,
            displayName: name,
            phoneNumber: _normalizePhone(
              (data['phone'] ?? data['phoneNumber'] ?? '') as String,
            ),
            photoUrl: _readPhotoUrl(data),
            serviceType: (data['serviceType'] as String?) ?? collection,
            isOfficial: (data['isOfficialAccount'] as bool?) ?? false,
            profileCompleted: (data['isProfileCompleted'] as bool?) ?? false,
          ),
        );
        if (results.length >= limit) {
          _searchCache[normalized] = _ProfileCacheEntry(results);
          return results;
        }
      }
    }

    _searchCache[normalized] = _ProfileCacheEntry(results);
    return results;
  }

  Future<List<UserProfile>> fetchSuggestedProfiles({
    required String ownerId,
    String? ownerEmail,
    int limit = 12,
  }) async {
    final cacheKey = '$ownerId::$limit';
    final cached = _readCache(_suggestionCache, cacheKey);
    if (cached != null) {
      return cached.length <= limit ? cached : cached.sublist(0, limit);
    }

    final exclude = <String>{ownerId};
    final existingFriends = await _runQuery(
      _firestore
          .collection('users')
          .doc(ownerId)
          .collection('friends')
          .limit(200),
    );
    for (final doc in existingFriends.docs) {
      exclude.add(doc.id);
    }

    final suggestions = <UserProfile>[];
    final seen = <String>{};
    final lowerOwnerEmail = ownerEmail?.toLowerCase().trim();
    final ownerServiceType = await _getOwnerServiceType(ownerId);
    final baseCollections = await _preferredCollectionsForOwner(
      ownerId,
      ownerServiceType: ownerServiceType,
    );
    final preferredCollection = baseCollections.length == 1
        ? baseCollections.first
        : null;
    final collectionsToQuery = <String>[
      ...baseCollections,
      ..._shopCollections.where((c) => !baseCollections.contains(c)),
    ];

    final limitedCollections = collectionsToQuery
        .take(4)
        .toList(growable: false);
    final futures = limitedCollections
        .map(
          (collection) => _runQuery(
            _firestore
                .collection(collection)
                .limit(_perCollectionSuggestionLimit),
          ),
        )
        .toList(growable: false);
    final snapshots = await Future.wait(futures);

    for (var i = 0; i < snapshots.length; i++) {
      final snapshot = snapshots[i];
      final collection = limitedCollections[i];
      for (final doc in snapshot.docs) {
        final data = doc.data();
        final shopOwnerId = (data['ownerId'] as String?) ?? doc.id;
        if (shopOwnerId.isEmpty) continue;
        if (exclude.contains(shopOwnerId) || seen.contains(shopOwnerId)) {
          continue;
        }

        final email = (data['email'] as String?)?.toLowerCase().trim();
        if (lowerOwnerEmail != null &&
            email != null &&
            email == lowerOwnerEmail) {
          continue;
        }

        final photoUrl = _readPhotoUrl(data);
        if (photoUrl == null || photoUrl.isEmpty) {
          continue;
        }

        final profile = UserProfile(
          uid: shopOwnerId,
          displayName: _readDisplayName(data, fallback: 'ร้านค้า'),
          phoneNumber: _normalizePhone(
            (data['phone'] ?? data['phoneNumber'] ?? '') as String,
          ),
          photoUrl: photoUrl,
          serviceType:
              (data['serviceType'] as String?) ??
              _serviceTypeFromCollection(collection),
          isOfficial: (data['isOfficialAccount'] as bool?) ?? false,
          profileCompleted: (data['isProfileCompleted'] as bool?) ?? true,
        );
        suggestions.add(profile);
        seen.add(shopOwnerId);
        exclude.add(shopOwnerId);
        if (suggestions.length >= limit) break;
      }
      if (suggestions.length >= limit) break;
    }

    if (suggestions.length < limit) {
      final fallbackLimit = ((limit - suggestions.length) * 3)
          .clamp(12, 60)
          .toInt();
      final userSnapshot = await _runQuery(
        _firestore
            .collection('users')
            .orderBy('updatedAt', descending: true)
            .limit(fallbackLimit),
      );

      final candidates = <UserProfile>[];
      for (final doc in userSnapshot.docs) {
        if (exclude.contains(doc.id) || seen.contains(doc.id)) continue;
        final data = doc.data();
        final completed = (data['profileCompleted'] as bool?) ?? false;
        if (!completed) continue;
        final photoUrl = (data['photoUrl'] as String?)?.trim();
        if (photoUrl == null || photoUrl.isEmpty) continue;
        candidates.add(UserProfile.fromSnapshot(doc));
      }

      String? matchingCollection = preferredCollection;
      matchingCollection ??= _collectionFromServiceType(ownerServiceType);

      void takeCandidates({required bool sameServiceOnly}) {
        for (final profile in candidates) {
          if (suggestions.length >= limit) break;
          if (exclude.contains(profile.uid) || seen.contains(profile.uid)) {
            continue;
          }

          if (sameServiceOnly) {
            if (matchingCollection == null) continue;
            final profileCollection = _collectionFromServiceType(
              profile.serviceType,
            );
            if (profileCollection == null ||
                profileCollection != matchingCollection) {
              continue;
            }
          }

          suggestions.add(profile);
          seen.add(profile.uid);
          exclude.add(profile.uid);
        }
      }

      takeCandidates(sameServiceOnly: true);
      takeCandidates(sameServiceOnly: false);
    }

    _suggestionCache[cacheKey] = _ProfileCacheEntry(suggestions);
    return suggestions;
  }

  List<UserProfile>? _readCache(
    Map<String, _ProfileCacheEntry> cache,
    String key,
  ) {
    final entry = cache[key];
    if (entry == null) {
      return null;
    }

    if (DateTime.now().difference(entry.insertedAt) > _cacheTtl) {
      cache.remove(key);
      return null;
    }
    return entry.data;
  }

  Future<List<String>> _preferredCollectionsForOwner(
    String ownerId, {
    String? ownerServiceType,
  }) async {
    String? serviceType = ownerServiceType;
    if (serviceType == null || serviceType.isEmpty) {
      serviceType = await _getOwnerServiceType(ownerId);
    }

    final collection = _collectionFromServiceType(serviceType);
    if (collection != null) {
      return <String>[collection];
    }
    return _shopCollections;
  }

  Future<String?> _getOwnerServiceType(String ownerId) async {
    try {
      final userDoc = await _getDocument(_firestore.collection('users').doc(ownerId));
      final serviceType = (userDoc.data()?['serviceType'] as String?)?.trim();
      if (serviceType != null && serviceType.isNotEmpty) {
        return serviceType;
      }
    } catch (_) {}

    try {
      final contractDoc = await _getDocument(
        _firestore.collection('contracts').doc(ownerId),
      );
      final serviceType = (contractDoc.data()?['serviceType'] as String?)
          ?.trim();
      if (serviceType != null && serviceType.isNotEmpty) {
        return serviceType;
      }
    } catch (_) {}

    return null;
  }

  String? _collectionFromServiceType(String? serviceType) {
    if (serviceType == null || serviceType.isEmpty) return null;
    switch (serviceType) {
      case 'ตลาด':
      case 'market':
      case 'market_registrations':
        return 'market_registrations';
      case 'ร้านค้า':
      case 'shop':
      case 'shop_registrations':
        return 'shop_registrations';
      case 'ร้านอาหาร':
      case 'restaurant':
      case 'restaurant_registrations':
        return 'restaurant_registrations';
      case 'ร้านขายยา':
      case 'pharmacy':
      case 'pharmacy_registrations':
        return 'pharmacy_registrations';
      case 'อื่นๆ':
      case 'other':
      case 'other_registrations':
        return 'other_registrations';
      default:
        return null;
    }
  }

  String _serviceTypeFromCollection(String collection) {
    switch (collection) {
      case 'market_registrations':
        return 'ตลาด';
      case 'shop_registrations':
        return 'ร้านค้า';
      case 'restaurant_registrations':
        return 'ร้านอาหาร';
      case 'pharmacy_registrations':
        return 'ร้านขายยา';
      default:
        return 'อื่นๆ';
    }
  }

  Future<void> addFriend({
    required String ownerId,
    required UserProfile friend,
  }) async {
    if (ownerId == friend.uid) {
      throw const FriendException('ไม่สามารถเพิ่มตัวเองเป็นเพื่อนได้');
    }

    final ownerFriendRef = _firestore
        .collection('users')
        .doc(ownerId)
        .collection('friends')
        .doc(friend.uid);
    final already = await _getDocument(ownerFriendRef);
    if (already.exists) {
      throw const FriendException('คุณเพิ่มเพื่อนคนนี้ไว้แล้ว');
    }

    final ownerProfile = await getProfile(ownerId);
    if (ownerProfile == null) {
      throw const FriendException('ไม่พบข้อมูลร้านของคุณ');
    }

    final now = FieldValue.serverTimestamp();
    final reverseRef = _firestore
        .collection('users')
        .doc(friend.uid)
        .collection('friends')
        .doc(ownerId);

    final batch = _firestore.batch();
    batch.set(ownerFriendRef, <String, dynamic>{
      ...friend.toFirestore(),
      'uid': friend.uid,
      'lastMessage': 'เพิ่งเพิ่มเป็นเพื่อน',
      'lastActivity': now,
      'unreadCount': 0,
      'isMuted': false,
      'addedAt': now,
    });

    batch.set(reverseRef, <String, dynamic>{
      ...ownerProfile.toFirestore(),
      'uid': ownerId,
      'lastMessage': 'เพิ่งเพิ่มเป็นเพื่อน',
      'lastActivity': now,
      'unreadCount': 0,
      'isMuted': false,
      'addedAt': now,
    }, SetOptions(merge: true));

    await batch.commit();
  }

  Future<void> removeFriend({
    required String ownerId,
    required String friendId,
  }) async {
    if (ownerId.isEmpty || friendId.isEmpty || ownerId == friendId) {
      return;
    }
    await _firestore
        .collection('users')
        .doc(ownerId)
        .collection('friends')
        .doc(friendId)
        .delete();
  }

  Future<void> blockUser({
    required String ownerId,
    required UserProfile target,
  }) async {
    if (ownerId.isEmpty || ownerId == target.uid) {
      throw const FriendException('ไม่สามารถบล็อกได้');
    }

    final blockedRef = _firestore
        .collection('users')
        .doc(ownerId)
        .collection('blocked')
        .doc(target.uid);
    final friendRef = _firestore
        .collection('users')
        .doc(ownerId)
        .collection('friends')
        .doc(target.uid);

    final batch = _firestore.batch();
    batch.delete(friendRef);
    batch.set(blockedRef, <String, dynamic>{
      'uid': target.uid,
      'displayName': target.displayName,
      if (target.photoUrl != null && target.photoUrl!.isNotEmpty)
        'photoUrl': target.photoUrl,
      if (target.phoneNumber != null && target.phoneNumber!.isNotEmpty)
        'phoneNumber': target.phoneNumber,
      if (target.serviceType != null && target.serviceType!.isNotEmpty)
        'serviceType': target.serviceType,
      'blockedAt': FieldValue.serverTimestamp(),
    });
    await batch.commit();
  }

  Future<bool> isBlocked({
    required String ownerId,
    required String targetId,
  }) async {
    if (ownerId.isEmpty || targetId.isEmpty) {
      return false;
    }
    final snapshot = await _getDocument(
      _firestore
          .collection('users')
          .doc(ownerId)
          .collection('blocked')
          .doc(targetId),
    );
    return snapshot.exists;
  }

  Future<Map<String, dynamic>?> _loadShopData(String uid) async {
    for (final collection in _shopCollections) {
      try {
        final directSnapshot = await _getDocument(
          _firestore.collection(collection).doc(uid),
        );
        if (directSnapshot.exists) {
          final data = directSnapshot.data();
          if (data != null) {
            return <String, dynamic>{
              ...data,
              'collection': collection,
              'registrationDocId': directSnapshot.id,
            };
          }
        }

        final ownerQuery = await _runQuery(
          _firestore
              .collection(collection)
              .where('ownerId', isEqualTo: uid)
              .limit(1),
        );
        if (ownerQuery.docs.isNotEmpty) {
          final ownerDoc = ownerQuery.docs.first;
          final data = ownerDoc.data();
          if (data.isNotEmpty) {
            return <String, dynamic>{
              ...data,
              'collection': collection,
              'registrationDocId': ownerDoc.id,
            };
          }
        }
      } catch (_) {
        continue;
      }
    }
    return null;
  }

  Future<FriendPreview> _buildFriendPreview(
    String ownerId,
    DocumentSnapshot<Map<String, dynamic>> doc,
  ) async {
    final data = doc.data() ?? const <String, dynamic>{};
    final Timestamp? ts = data['lastActivity'] as Timestamp?;
    final uid = data['uid']?.toString() ?? doc.id;

    final UserProfile profile;
    if (friendDocHasDisplayProfile(data)) {
      profile = UserProfile.fromMap(uid, data);
    } else {
      profile =
          await _resolveCanonicalProfile(
            uid,
            userData: data,
            fallbackDisplayName:
                (data['displayName'] ?? data['name'] ?? 'ผู้ใช้ใหม่').toString(),
            fallbackPhotoUrl:
                (data['photoUrl'] ?? data['imageUrl'] ?? data['shopImageUrl'])
                    as String?,
            fallbackPhoneNumber:
                (data['phoneNumber'] ?? data['phone']) as String?,
          ) ??
          UserProfile.fromMap(uid, data);
      unawaited(_syncFriendPreviewDocIfNeeded(ownerId, doc.id, data, profile));
    }

    return FriendPreview(
      profile: profile,
      lastMessage: (data['lastMessage'] as String?) ?? 'แตะเพื่อเริ่มสนทนา',
      unreadCount: (data['unreadCount'] as int?) ?? 0,
      lastActivity: ts?.toDate(),
      isMuted: (data['isMuted'] as bool?) ?? false,
    );
  }

  Future<UserProfile?> _resolveCanonicalProfile(
    String uid, {
    Map<String, dynamic>? userData,
    String? fallbackDisplayName,
    String? fallbackPhotoUrl,
    String? fallbackPhoneNumber,
  }) async {
    final resolvedUserData = userData ?? await _loadUserData(uid);
    final shopData = await _loadShopData(uid);
    if (resolvedUserData == null && shopData == null) {
      return null;
    }

    final displayName = _readDisplayName(
      shopData,
      fallback: _readDisplayName(
        resolvedUserData,
        fallback: fallbackDisplayName ?? 'ผู้ใช้ใหม่',
      ),
    );
    final photoUrl =
        _readPhotoUrl(shopData) ??
        _readPhotoUrl(resolvedUserData) ??
        fallbackPhotoUrl;
    final phoneNumber = _normalizePhone(
      (shopData?['phone'] ??
              shopData?['phoneNumber'] ??
              resolvedUserData?['phoneNumber'] ??
              resolvedUserData?['phone'] ??
              fallbackPhoneNumber ??
              '')
          .toString(),
    );
    final serviceType =
        (shopData?['serviceType'] as String?) ??
        (resolvedUserData?['serviceType'] as String?) ??
        (shopData?['collection'] as String?);

    return UserProfile(
      uid: uid,
      displayName: displayName,
      phoneNumber: phoneNumber.isEmpty ? null : phoneNumber,
      photoUrl: photoUrl,
      serviceType: serviceType,
      isOfficial:
          (shopData?['isOfficialAccount'] as bool?) ??
          (resolvedUserData?['isOfficial'] as bool?) ??
          false,
      profileCompleted:
          (shopData?['isProfileCompleted'] as bool?) ??
          (resolvedUserData?['profileCompleted'] as bool?) ??
          false,
    );
  }

  Future<Map<String, dynamic>?> _loadUserData(String uid) async {
    final snapshot = await _getDocument(_firestore.collection('users').doc(uid));
    return snapshot.data();
  }

  Future<void> _syncUserProfileDoc(
    DocumentReference<Map<String, dynamic>> docRef,
    Map<String, dynamic>? existingData,
    UserProfile profile,
  ) async {
    if (!_shouldSyncProfile(existingData, profile)) {
      return;
    }
    await docRef.set(<String, dynamic>{
      ...profile.toFirestore(),
      if (profile.phoneNumber != null && profile.phoneNumber!.isNotEmpty)
        'phoneNumber': profile.phoneNumber,
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  Future<void> _syncFriendPreviewDocIfNeeded(
    String ownerId,
    String friendId,
    Map<String, dynamic>? existingData,
    UserProfile profile,
  ) async {
    if (!_shouldSyncProfile(existingData, profile)) {
      return;
    }
    try {
      await _firestore
          .collection('users')
          .doc(ownerId)
          .collection('friends')
          .doc(friendId)
          .set(<String, dynamic>{
            ...profile.toFirestore(),
            'uid': profile.uid,
            if (profile.phoneNumber != null && profile.phoneNumber!.isNotEmpty)
              'phoneNumber': profile.phoneNumber,
          }, SetOptions(merge: true));
    } catch (_) {}
  }

  bool _shouldSyncProfile(
    Map<String, dynamic>? existingData,
    UserProfile profile,
  ) {
    if (existingData == null || existingData.isEmpty) {
      return true;
    }
    final existingDisplayName =
        (existingData['displayName'] ?? existingData['name'] ?? '')
            .toString()
            .trim();
    final existingPhotoUrl =
        (existingData['photoUrl'] ??
                existingData['imageUrl'] ??
                existingData['shopImageUrl'] ??
                '')
            .toString()
            .trim();
    final existingServiceType =
        (existingData['serviceType'] ?? existingData['type'] ?? '')
            .toString()
            .trim();
    final existingPhone = _normalizePhone(
      (existingData['phoneNumber'] ?? existingData['phone'] ?? '').toString(),
    );

    return existingDisplayName != profile.displayName.trim() ||
        existingPhotoUrl != (profile.photoUrl ?? '').trim() ||
        existingServiceType != (profile.serviceType ?? '').trim() ||
        existingPhone != (profile.phoneNumber ?? '');
  }

  static String _readDisplayName(
    Map<String, dynamic>? data, {
    required String fallback,
  }) {
    final resolved = ShopProfileResolver.resolveName(data);
    if (resolved != null && resolved.trim().isNotEmpty) {
      return resolved.trim();
    }
    return fallback;
  }

  static String? _readPhotoUrl(Map<String, dynamic>? data) {
    final resolved = ShopProfileResolver.resolveImageUrl(data);
    if (resolved != null && resolved.trim().isNotEmpty) {
      return resolved.trim();
    }
    return null;
  }

  static String _normalizePhone(String raw) {
    var clean = raw.replaceAll(RegExp(r'[^0-9+]'), '');
    if (clean.isEmpty) return '';
    if (clean.startsWith('00')) {
      clean = '+${clean.substring(2)}';
    }
    if (clean.startsWith('0') && clean.length == 10) {
      return '+66${clean.substring(1)}';
    }
    if (!clean.startsWith('+') && clean.length >= 9) {
      return '+$clean';
    }
    return clean;
  }
}

class _ProfileCacheEntry {
  _ProfileCacheEntry(List<UserProfile> items)
    : data = List<UserProfile>.unmodifiable(items),
      insertedAt = DateTime.now();

  final List<UserProfile> data;
  final DateTime insertedAt;
}

class FriendPreview {
  FriendPreview({
    required this.profile,
    this.lastMessage = 'แตะเพื่อเริ่มสนทนา',
    this.unreadCount = 0,
    this.lastActivity,
    this.isMuted = false,
  });

  final UserProfile profile;
  final String lastMessage;
  final int unreadCount;
  final DateTime? lastActivity;
  final bool isMuted;

  factory FriendPreview.fromSnapshot(
    DocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final data = doc.data() ?? const <String, dynamic>{};
    final Timestamp? ts = data['lastActivity'] as Timestamp?;
    return FriendPreview(
      profile: UserProfile.fromMap(data['uid']?.toString() ?? doc.id, data),
      lastMessage: (data['lastMessage'] as String?) ?? 'แตะเพื่อเริ่มสนทนา',
      unreadCount: (data['unreadCount'] as int?) ?? 0,
      lastActivity: ts?.toDate(),
      isMuted: (data['isMuted'] as bool?) ?? false,
    );
  }

  bool isSamePresentationAs(FriendPreview other) {
    return profile.uid == other.profile.uid &&
        profile.displayName == other.profile.displayName &&
        profile.photoUrl == other.profile.photoUrl &&
        lastMessage == other.lastMessage &&
        unreadCount == other.unreadCount &&
        isMuted == other.isMuted &&
        lastActivity?.millisecondsSinceEpoch ==
            other.lastActivity?.millisecondsSinceEpoch;
  }

  static bool listsEqual(
    List<FriendPreview> left,
    List<FriendPreview> right,
  ) {
    if (identical(left, right)) {
      return true;
    }
    if (left.length != right.length) {
      return false;
    }
    for (var index = 0; index < left.length; index++) {
      if (!left[index].isSamePresentationAs(right[index])) {
        return false;
      }
    }
    return true;
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'profile': <String, dynamic>{
        'uid': profile.uid,
        'displayName': profile.displayName,
        if (profile.phoneNumber != null) 'phoneNumber': profile.phoneNumber,
        if (profile.photoUrl != null) 'photoUrl': profile.photoUrl,
        if (profile.serviceType != null) 'serviceType': profile.serviceType,
        'isOfficial': profile.isOfficial,
        'profileCompleted': profile.profileCompleted,
      },
      'lastMessage': lastMessage,
      'unreadCount': unreadCount,
      if (lastActivity != null)
        'lastActivityMillis': lastActivity!.millisecondsSinceEpoch,
      'isMuted': isMuted,
    };
  }

  factory FriendPreview.fromJson(Map<String, dynamic> json) {
    final profileMap = json['profile'];
    final profile = profileMap is Map<String, dynamic>
        ? UserProfile.fromMap(
            (profileMap['uid'] as String?) ?? '',
            profileMap,
          )
        : UserProfile(
            uid: '',
            displayName: 'ผู้ใช้ใหม่',
          );
    final lastActivityMillis = json['lastActivityMillis'];
    return FriendPreview(
      profile: profile,
      lastMessage: (json['lastMessage'] as String?) ?? 'แตะเพื่อเริ่มสนทนา',
      unreadCount: (json['unreadCount'] as num?)?.toInt() ?? 0,
      lastActivity: lastActivityMillis is num
          ? DateTime.fromMillisecondsSinceEpoch(lastActivityMillis.toInt())
          : null,
      isMuted: json['isMuted'] == true,
    );
  }

  String get lastActivityLabel {
    if (lastActivity == null) return '';
    final now = DateTime.now();
    final diff = now.difference(lastActivity!);
    if (diff.inDays == 0) {
      final hours = lastActivity!.hour.toString().padLeft(2, '0');
      final minutes = lastActivity!.minute.toString().padLeft(2, '0');
      return '$hours:$minutes';
    }
    if (diff.inDays == 1) {
      return 'เมื่อวาน';
    }
    if (diff.inDays < 7) {
      const thaiWeekdays = <int, String>{
        DateTime.monday: 'จ.',
        DateTime.tuesday: 'อ.',
        DateTime.wednesday: 'พ.',
        DateTime.thursday: 'พฤ.',
        DateTime.friday: 'ศ.',
        DateTime.saturday: 'ส.',
        DateTime.sunday: 'อา.',
      };
      return thaiWeekdays[lastActivity!.weekday] ?? '';
    }
    final month = lastActivity!.month.toString().padLeft(2, '0');
    final day = lastActivity!.day.toString().padLeft(2, '0');
    return '$day/$month';
  }
}

class FriendException implements Exception {
  const FriendException(this.message);
  final String message;

  @override
  String toString() => message;
}
