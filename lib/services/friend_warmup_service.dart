import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import 'chat_warmup.dart';
import 'friend_list_cache_service.dart';
import 'friend_service.dart';

/// Prefetch friend list + chat rooms while the user is on Home.
class FriendWarmupService {
  FriendWarmupService._();

  static final FriendWarmupService instance = FriendWarmupService._();

  StreamSubscription<List<FriendPreview>>? _subscription;
  StreamController<List<FriendPreview>>? _friendsController;
  String? _activeOwnerId;
  List<FriendPreview> _latestFriends = const <FriendPreview>[];

  List<FriendPreview> get latestFriends => _latestFriends;

  Stream<List<FriendPreview>> watchFriends(String ownerId) {
    start(ownerId: ownerId);
    final controller = _friendsController;
    if (controller == null) {
      return const Stream<List<FriendPreview>>.empty();
    }
    if (_latestFriends.isNotEmpty) {
      scheduleMicrotask(() {
        if (!(controller.isClosed)) {
          controller.add(_latestFriends);
        }
      });
    }
    return controller.stream;
  }

  void start({String? ownerId}) {
    final uid = ownerId?.trim().isNotEmpty == true
        ? ownerId!.trim()
        : FirebaseAuth.instance.currentUser?.uid;
    if (uid == null || uid.isEmpty) {
      return;
    }
    if (_activeOwnerId == uid && _subscription != null) {
      return;
    }

    stop();
    _activeOwnerId = uid;
    _friendsController = StreamController<List<FriendPreview>>.broadcast();

    unawaited(_loadDiskCache(uid));

    _subscription = FriendService.instance.watchFriends(uid).listen(
      (friends) {
        if (FriendPreview.listsEqual(_latestFriends, friends)) {
          return;
        }
        _latestFriends = friends;
        final controller = _friendsController;
        if (controller != null && !controller.isClosed) {
          controller.add(friends);
        }
        unawaited(FriendListCacheService.instance.save(uid, friends));
        ChatWarmup.prefetchRoomsForFriends(
          friends.map((friend) => friend.profile).toList(growable: false),
          friendService: FriendService.instance,
        );
      },
      onError: (Object error) {
        debugPrint('FriendWarmupService stream failed: $error');
        final controller = _friendsController;
        if (controller != null && !controller.isClosed) {
          controller.add(_latestFriends);
        }
      },
    );

    Future<void>.delayed(const Duration(seconds: 8), () {
      final controller = _friendsController;
      if (controller == null || controller.isClosed) {
        return;
      }
      if (_latestFriends.isEmpty) {
        controller.add(const <FriendPreview>[]);
      }
    });

    final user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      unawaited(FriendService.instance.ensureCurrentUserProfile(user));
    }
  }

  Future<void> _loadDiskCache(String uid) async {
    final cached = await FriendListCacheService.instance.load(uid);
    if (cached.isEmpty) {
      return;
    }
    _latestFriends = cached;
    final controller = _friendsController;
    if (controller != null && !controller.isClosed) {
      controller.add(cached);
    }
    ChatWarmup.prefetchRoomsForFriends(
      cached.map((friend) => friend.profile).toList(growable: false),
      friendService: FriendService.instance,
    );
  }

  void stop() {
    _subscription?.cancel();
    _subscription = null;
    _friendsController?.close();
    _friendsController = null;
    _activeOwnerId = null;
  }
}
