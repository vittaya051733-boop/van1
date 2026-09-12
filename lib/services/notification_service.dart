import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'package:flutter/foundation.dart';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../utils/app_check_guard.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:permission_handler/permission_handler.dart';
import '../models/order_model.dart';
import '../incoming_shop_order_screen.dart';
import '../order_management_screen_new.dart';
import '../models/user_profile.dart';
import '../services/shop_operations_service.dart';
import '../call_screen.dart';
import '../firebase_options.dart';
import '../main.dart';
import '../widgets/chat_message_popup.dart';
import '../chat_room_screen.dart';
import '../wallet_screen.dart';

const Set<String> _walletNotificationActions = {
  'payout_pending',
  'payout_paid',
  'credit_released',
  'top_up_verified',
  'credit_adjusted',
  'security_deposit_paid',
};

bool _isWalletNotificationAction(String? action) {
  final normalized = (action ?? '').trim();
  return _walletNotificationActions.contains(normalized);
}

String _normalizeInboxKeyPart(String? value) {
  final normalized = (value ?? '').trim().toLowerCase();
  if (normalized.isEmpty) {
    return 'na';
  }
  return normalized.replaceAll(RegExp(r'[^a-z0-9]+'), '_');
}

String _buildVan1InboxNotificationId({
  required Map<String, dynamic> data,
  String? messageId,
}) {
  final type = _normalizeInboxKeyPart(data['type'] as String?);
  final action = _normalizeInboxKeyPart(
    (data['action'] as String?) ??
        (type == 'chat'
            ? 'chat_message'
            : type == 'call'
            ? 'incoming_call'
            : 'general'),
  );
  final notificationId = _normalizeInboxKeyPart(
    data['notificationId'] as String?,
  );
  final chatId = _normalizeInboxKeyPart(data['chatId'] as String?);
  final channelId = _normalizeInboxKeyPart(data['channelId'] as String?);
  final orderId = _normalizeInboxKeyPart(data['orderId'] as String?);
  final senderId = _normalizeInboxKeyPart(data['senderId'] as String?);
  final callerId = _normalizeInboxKeyPart(
    (data['callerId'] as String?) ?? (data['caller_id'] as String?),
  );
  final bodySeed = _normalizeInboxKeyPart(
    (data['message'] as String?) ?? (data['body'] as String?),
  );
  final remoteMessageId = _normalizeInboxKeyPart(messageId);

  return <String>[
    'van1',
    type,
    action,
    notificationId,
    chatId,
    channelId,
    orderId,
    senderId,
    callerId,
    remoteMessageId,
    bodySeed,
  ].join('__');
}

Future<void> _persistVan1RemoteMessageToInbox(
  Map<String, dynamic> data, {
  String? messageId,
  String? title,
  String? body,
}) async {
  final existingNotificationId =
      (data['notificationId'] as String?)?.trim() ?? '';
  if (existingNotificationId.isNotEmpty) {
    return;
  }

  final currentUid = FirebaseAuth.instance.currentUser?.uid.trim();
  final recipientUid = (data['recipientUid'] as String?)?.trim();
  final targetUid = recipientUid?.isNotEmpty == true
      ? recipientUid!
      : currentUid;
  if (targetUid == null || targetUid.isEmpty) {
    return;
  }

  final type = (data['type'] as String?)?.trim() ?? 'app_notification';
  final action = (data['action'] as String?)?.trim().isNotEmpty == true
      ? (data['action'] as String).trim()
      : type == 'chat'
      ? 'chat_message'
      : type == 'call'
      ? 'incoming_call'
      : 'general';
  final senderName = (data['senderName'] as String?)?.trim();
  final callerName =
      ((data['callerName'] as String?) ?? (data['caller_name'] as String?))
          ?.trim();
  final resolvedTitle = (() {
    if (title?.trim().isNotEmpty == true) {
      return title!.trim();
    }
    if (type == 'chat') {
      return senderName?.isNotEmpty == true ? senderName! : 'ข้อความใหม่';
    }
    if (type == 'call') {
      final isVideo = data['isVideo'] == true || data['isVideo'] == 'true';
      return isVideo ? 'วิดีโอคอลเข้า' : 'สายเข้า';
    }
    return 'แจ้งเตือน';
  })();
  final resolvedBody = (() {
    if (body?.trim().isNotEmpty == true) {
      return body!.trim();
    }
    if (type == 'chat') {
      return ((data['message'] as String?) ?? '').trim();
    }
    if (type == 'call') {
      final displayName = callerName?.isNotEmpty == true
          ? callerName!
          : 'ผู้โทร';
      final isVideo = data['isVideo'] == true || data['isVideo'] == 'true';
      return isVideo
          ? '$displayName กำลังวิดีโอคอลเข้ามา'
          : '$displayName กำลังโทรเข้ามา';
    }
    return ((data['body'] as String?) ?? '').trim();
  })();
  if (resolvedTitle.isEmpty && resolvedBody.isEmpty) {
    return;
  }

  final docId = _buildVan1InboxNotificationId(data: data, messageId: messageId);
  await FirebaseFirestore.instance
      .collection('app_notifications')
      .doc(docId)
      .set(<String, dynamic>{
        'targetApp': 'van1',
        'recipientUid': targetUid,
        if ((data['orderId'] as String?)?.trim().isNotEmpty == true)
          'orderId': (data['orderId'] as String).trim(),
        if ((data['chatId'] as String?)?.trim().isNotEmpty == true)
          'chatId': (data['chatId'] as String).trim(),
        if ((data['senderId'] as String?)?.trim().isNotEmpty == true)
          'senderId': (data['senderId'] as String).trim(),
        if (senderName?.isNotEmpty == true) 'senderName': senderName,
        if (((data['callerId'] as String?) ?? (data['caller_id'] as String?))
                ?.trim()
                .isNotEmpty ==
            true)
          'callerId':
              (((data['callerId'] as String?) ??
                      (data['caller_id'] as String?))!)
                  .trim(),
        if (callerName?.isNotEmpty == true) 'callerName': callerName,
        if ((data['callerPhotoUrl'] as String?)?.trim().isNotEmpty == true)
          'callerPhotoUrl': (data['callerPhotoUrl'] as String).trim(),
        if ((data['channelId'] as String?)?.trim().isNotEmpty == true)
          'channelId': (data['channelId'] as String).trim(),
        'title': resolvedTitle,
        'body': resolvedBody,
        'read': false,
        'createdAt': FieldValue.serverTimestamp(),
        'source': 'van1_received',
        'sourceApp': 'van1',
        'action': action,
        'type': type,
        if (messageId?.trim().isNotEmpty == true)
          'messageId': messageId!.trim(),
        if ((data['callType'] as String?)?.trim().isNotEmpty == true)
          'callType': (data['callType'] as String).trim(),
        if (data['isVideo'] != null)
          'isVideo': data['isVideo'] == true || data['isVideo'] == 'true',
        if ((data['message'] as String?)?.trim().isNotEmpty == true)
          'message': (data['message'] as String).trim(),
      }, SetOptions(merge: true));
}

class NotificationService {
  static final NotificationService _instance = NotificationService._internal();
  factory NotificationService() => _instance;
  NotificationService._internal();

  static const MethodChannel _callIntentChannel = MethodChannel(
    'van.merchant/call_intents',
  );
  static const MethodChannel _appStateChannel = MethodChannel(
    'van.merchant/app_state',
  );
  static const String _methodDrainPending = 'drain_pending_intents';
  static const String _methodCanUseFullScreenIntent =
      'can_use_full_screen_intent';
  static const String _methodOpenFullScreenIntentSettings =
      'open_full_screen_intent_settings';
  static const String _methodCanDrawOverlays = 'can_draw_overlays';
  static const String _methodOpenOverlaySettings = 'open_overlay_settings';
  static const String _methodShowIncomingCallActivity =
      'show_incoming_call_activity';

  static const List<String> _registrationCollections = <String>[
    'market_registrations',
    'shop_registrations',
    'restaurant_registrations',
    'pharmacy_registrations',
    'other_registrations',
  ];
  static const List<String> _chatProfileCollections = <String>[
    'users',
    'customer_users',
    'riders',
    'market_registrations',
    'shop_registrations',
    'restaurant_registrations',
    'pharmacy_registrations',
    'other_registrations',
  ];

  final FirebaseMessaging _firebaseMessaging = FirebaseMessaging.instance;
  final FlutterLocalNotificationsPlugin _localNotifications =
      FlutterLocalNotificationsPlugin();

  bool _initialized = false;
  String? _currentFcmToken;
  bool _incomingCallVisible = false;
  bool _callIntentBridgeAttached = false;
  String? _activeIncomingChannelId;
  String? _activeOrderPromptId;
  final Set<String> _queuedShopDecisionOrderIds = <String>{};
  StreamSubscription<User?>? _shopDecisionAuthSubscription;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>?
  _shopDecisionNotificationSubscription;
  bool _shopDecisionListenerPrimed = false;
  String? _handledInitialMessageId;
  final Set<String> _handledShopDecisionNotificationIds = <String>{};
  final Set<String> _shownProductAiNotificationIds = <String>{};
  final Set<String> _cancelledChannelIds = <String>{};
  String? _backgroundReturnChannelId;
  bool _shouldReturnAppToBackground = false;

  /// เริ่มต้นระบบ Notification
  Future<void> initialize() async {
    if (_initialized) return;

    _setupCallIntentBridge();

    final systemPermissionGranted = await _ensureSystemNotificationPermission();
    if (!systemPermissionGranted) {
      debugPrint('Notification permission denied at system level');
    }

    // Request permission
    NotificationSettings settings = await _firebaseMessaging.requestPermission(
      alert: true,
      badge: true,
      sound: true,
      provisional: false,
    );

    if (settings.authorizationStatus == AuthorizationStatus.authorized) {
      debugPrint('User granted notification permission');
    }

    await _firebaseMessaging.setForegroundNotificationPresentationOptions(
      alert: true,
      badge: true,
      sound: true,
    );

    // Initialize local notifications
    const androidSettings = AndroidInitializationSettings(
      '@mipmap/ic_launcher',
    );
    const iosSettings = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );

    const initializationSettings = InitializationSettings(
      android: androidSettings,
      iOS: iosSettings,
    );

    await _localNotifications.initialize(
      initializationSettings,
      onDidReceiveNotificationResponse: _onNotificationTapped,
    );

    await _ensureAndroidNotificationChannel();
    await _ensureAndroidIncomingCallPresentationPermission();
    await _ensureAndroidOverlayPermission();

    // Get FCM token
    final token = await _firebaseMessaging.getToken();
    if (token != null) {
      await _saveFCMToken(token);
    }

    // Listen to token refresh
    _firebaseMessaging.onTokenRefresh.listen(_saveFCMToken);

    // Handle foreground messages
    FirebaseMessaging.onMessage.listen(_handleForegroundMessage);

    // Handle background messages
    FirebaseMessaging.onBackgroundMessage(
      firebaseMessagingBackgroundHandlerVan1,
    );

    // Handle notification tap when app is in background
    FirebaseMessaging.onMessageOpenedApp.listen(_handleNotificationTap);

    final initialMessage = await _firebaseMessaging.getInitialMessage();
    if (initialMessage != null) {
      final messageId =
          initialMessage.messageId ??
          (initialMessage.data['notificationId'] as String?)?.trim();
      final sentAt = initialMessage.sentTime;
      final isFresh =
          sentAt == null ||
          DateTime.now().difference(sentAt) <= const Duration(minutes: 2);
      if (isFresh &&
          (messageId == null || messageId != _handledInitialMessageId)) {
        _handledInitialMessageId = messageId;
        _handleNotificationTap(initialMessage);
      }
    }

    _startShopDecisionNotificationListener();

    _initialized = true;
  }

  void _startShopDecisionNotificationListener() {
    _shopDecisionAuthSubscription ??= FirebaseAuth.instance
        .authStateChanges()
        .listen((user) {
          _shopDecisionNotificationSubscription?.cancel();
          _shopDecisionNotificationSubscription = null;
          _shopDecisionListenerPrimed = false;
          _handledShopDecisionNotificationIds.clear();
          _shownProductAiNotificationIds.clear();

          final uid = user?.uid.trim();
          if (uid == null || uid.isEmpty) {
            return;
          }

          debugPrint('Listening for van1 app_notifications uid=$uid');
          _shopDecisionNotificationSubscription = FirebaseFirestore.instance
              .collection('app_notifications')
              .where('targetApp', isEqualTo: 'van1')
              .where('recipientUid', isEqualTo: uid)
              .where('read', isEqualTo: false)
              .snapshots()
              .listen(
                _handleShopDecisionNotificationSnapshot,
                onError: (error) {
                  debugPrint(
                    'Failed to listen for shop decision notifications: $error',
                  );
                },
              );
        });
  }

  Future<void> _handleShopDecisionNotificationSnapshot(
    QuerySnapshot<Map<String, dynamic>> snapshot,
  ) async {
    if (!_shopDecisionListenerPrimed) {
      _shopDecisionListenerPrimed = true;
      for (final doc in snapshot.docs) {
        _handledShopDecisionNotificationIds.add(doc.id);
      }
      return;
    }
    debugPrint(
      'van1 app_notifications snapshot changes=${snapshot.docChanges.length}',
    );
    final changes = snapshot.docChanges
        .where((change) {
          return change.type == DocumentChangeType.added ||
              change.type == DocumentChangeType.modified;
        })
        .toList(growable: false);

    changes.sort((a, b) {
      final aTime =
          (a.doc.data()?['createdAt'] as Timestamp?)?.millisecondsSinceEpoch ??
          0;
      final bTime =
          (b.doc.data()?['createdAt'] as Timestamp?)?.millisecondsSinceEpoch ??
          0;
      return aTime.compareTo(bTime);
    });

    for (final change in changes) {
      final notificationId = change.doc.id;
      if (!_handledShopDecisionNotificationIds.add(notificationId)) {
        continue;
      }

      final data = change.doc.data();
      if (data == null) {
        continue;
      }
      if (_isProductAiReadyNotification(data)) {
        final payload = <String, dynamic>{
          ...data,
          'type': data['type'] ?? 'product_ai_ready',
          'notificationId': notificationId,
        };
        unawaited(_showProductAiReadyNotification(payload));
        continue;
      }
      if (!_isIncomingShopDecisionNotification(data)) {
        await _showInboxFallbackNotification(notificationId, data);
        continue;
      }

      final payload = <String, dynamic>{
        ...data,
        'type': data['type'] ?? 'app_notification',
        'notificationId': notificationId,
      };
      await _showIncomingOrderDecisionPrompt(payload);
    }
  }

  Future<void> _showInboxFallbackNotification(
    String notificationId,
    Map<String, dynamic> data,
  ) async {
    final currentUid = FirebaseAuth.instance.currentUser?.uid.trim();
    final recipientUid = (data['recipientUid'] as String?)?.trim();
    if (currentUid == null ||
        currentUid.isEmpty ||
        recipientUid == null ||
        recipientUid != currentUid) {
      return;
    }

    final title = (data['title'] as String?)?.trim();
    final body = (data['body'] as String?)?.trim();
    if (title?.isNotEmpty != true && body?.isNotEmpty != true) {
      return;
    }

    await _showLocalNotification(
      title: title?.isNotEmpty == true ? title! : 'แจ้งเตือน',
      body: body ?? '',
      payload: jsonEncode(<String, dynamic>{
        'type': data['type'] ?? 'app_notification',
        'notificationId': notificationId,
        'orderId': data['orderId'],
        'ticketId': data['ticketId'],
        'action': data['action'],
        'title': title,
        'body': body,
      }),
    );
  }

  Future<bool> _ensureSystemNotificationPermission() async {
    if (!Platform.isAndroid && !Platform.isIOS) {
      return true;
    }
    final status = await Permission.notification.status;
    if (status.isGranted || status.isLimited) {
      return true;
    }
    if (status.isPermanentlyDenied) {
      return false;
    }
    final requested = await Permission.notification.request();
    return requested.isGranted || requested.isLimited;
  }

  Future<void> _ensureAndroidNotificationChannel() async {
    if (!Platform.isAndroid) {
      return;
    }
    final androidPlugin = _localNotifications
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    if (androidPlugin == null) {
      return;
    }
    const channel = AndroidNotificationChannel(
      'order_channel',
      'การแจ้งเตือนทั่วไป',
      description: 'ใช้สำหรับแจ้งเตือนข้อความและออเดอร์',
      importance: Importance.high,
      playSound: true,
    );
    await androidPlugin.createNotificationChannel(channel);
  }

  Future<void> _ensureAndroidIncomingCallPresentationPermission() async {
    if (!Platform.isAndroid) {
      return;
    }
    try {
      final bool canUseFullScreenIntent =
          await _appStateChannel.invokeMethod<bool>(
            _methodCanUseFullScreenIntent,
          ) ??
          true;
      if (canUseFullScreenIntent) {
        return;
      }
      debugPrint(
        'Full-screen intent permission not granted. Opening app settings.',
      );
      await _appStateChannel.invokeMethod<void>(
        _methodOpenFullScreenIntentSettings,
      );
    } catch (error) {
      if (kDebugMode) {
        debugPrint('Unable to verify full-screen intent permission: $error');
      }
    }
  }

  Future<void> _ensureAndroidOverlayPermission() async {
    if (!Platform.isAndroid) {
      return;
    }
    try {
      final bool canDrawOverlays =
          await _appStateChannel.invokeMethod<bool>(_methodCanDrawOverlays) ??
          true;
      if (canDrawOverlays) {
        return;
      }
      debugPrint('Overlay permission not granted. Opening overlay settings.');
      await _appStateChannel.invokeMethod<void>(_methodOpenOverlaySettings);
    } catch (error) {
      if (kDebugMode) {
        debugPrint('Unable to verify overlay permission: $error');
      }
    }
  }

  /// บันทึก FCM Token ลง Firestore
  Future<void> _saveFCMToken(String token) async {
    try {
      if (_currentFcmToken == token) {
        debugPrint('FCM Token unchanged, skip update');
        return;
      }
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) return;

      final batch = FirebaseFirestore.instance.batch();
      final String? registrationCollection =
          await _resolveRegistrationCollection(user.uid);

      if (registrationCollection != null) {
        final docRef = FirebaseFirestore.instance
            .collection(registrationCollection)
            .doc(user.uid);
        batch.set(docRef, {'shopFCMToken': token}, SetOptions(merge: true));
      } else {
        debugPrint(
          '⚠️ ไม่พบคอลเลกชันร้านค้าของ ${user.uid} ข้ามการอัปเดต shopFCMToken',
        );
      }

      // อัพเดทใน users collection (สร้างหรืออัปเดตได้เสมอ)
      final userDocRef = FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid);
      batch.set(userDocRef, {'fcmToken': token}, SetOptions(merge: true));

      await batch.commit();
      _currentFcmToken = token;
      debugPrint('FCM Token saved successfully');
    } catch (e) {
      debugPrint('Error saving FCM token: $e');
    }
  }

  Future<String?> _resolveRegistrationCollection(String userId) async {
    String? collection;
    try {
      final userDoc = await FirebaseFirestore.instance
          .collection('users')
          .doc(userId)
          .get();
      collection = _collectionFromServiceType(
        (userDoc.data()?['serviceType'] as String?)?.trim(),
      );
      if (collection != null) return collection;
    } catch (_) {}

    try {
      final contractDoc = await FirebaseFirestore.instance
          .collection('contracts')
          .doc(userId)
          .get();
      collection = _collectionFromServiceType(
        (contractDoc.data()?['serviceType'] as String?)?.trim(),
      );
      if (collection != null) return collection;
    } catch (_) {}

    for (final candidate in _registrationCollections) {
      final snapshot = await FirebaseFirestore.instance
          .collection(candidate)
          .doc(userId)
          .get();
      if (snapshot.exists) {
        return candidate;
      }
    }
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

  /// บันทึก FCM token ของผู้ใช้ลง Firestore
  Future<void> saveUserFcmToken(String userId) async {
    final token = await _firebaseMessaging.getToken().timeout(
      const Duration(seconds: 8),
    );
    if (token == null) return;

    try {
      final currentUser = FirebaseAuth.instance.currentUser;
      if (currentUser != null && currentUser.uid == userId) {
        await _saveFCMToken(token);
        return;
      }

      await FirebaseFirestore.instance.collection('users').doc(userId).set({
        'fcmToken': token,
      }, SetOptions(merge: true));
    } catch (e) {
      debugPrint('Error saving user FCM token directly: $e');
    }
  }

  /// จัดการ notification เมื่อแอพอยู่ foreground
  Future<void> _handleForegroundMessage(RemoteMessage message) async {
    debugPrint(
      'Received foreground message: ${message.messageId} '
      'type=${message.data['type']} channel=${message.data['channelId']} '
      'appId=${message.data['appId']}',
    );

    final notification = message.notification;
    final data = message.data;

    if (!_isProductAiReadyNotification(data)) {
      await _persistVan1RemoteMessageToInbox(
        data,
        messageId: message.messageId,
        title: notification?.title,
        body: notification?.body,
      );
    }

    if (data['type'] == 'call_cancel') {
      _handleCallCancelFromNative(data['channelId'] as String?);
      return;
    }

    // แจ้งเตือนข้อความแชตเข้า
    if (data['type'] == 'chat') {
      final context = MyApp.navigatorKey.currentState?.context;
      final senderName = data['senderName'] ?? 'ข้อความใหม่';
      final messageText = data['message'] ?? '';
      void handleTap() {
        _openChatFromNotificationData(data);
      }

      if (context != null) {
        ChatMessagePopup.show(
          context,
          senderName: senderName,
          message: messageText,
          onTap: handleTap,
        );
      } else {
        await _showLocalNotification(
          title: senderName,
          body: messageText,
          payload: jsonEncode({
            'type': 'chat',
            'chatId': data['chatId'],
            'senderId': data['senderId'],
            'senderName': senderName,
          }),
        );
      }
      return;
    }

    // แจ้งเตือนสายเข้า/วิดีโอคอลจริง
    if (data['type'] == 'call') {
      final currentUid = FirebaseAuth.instance.currentUser?.uid;
      final callerId = data['callerId'] ?? data['caller_id'];
      if (currentUid != null && callerId != null && currentUid == callerId) {
        debugPrint('Skip showing incoming UI for own outgoing call');
        return;
      }
      // พยายามเปิดหน้า Native (IncomingCallActivity) เสมอ
      // แต่ไม่พึ่งพา result ของ method call เพื่อแสดง UI
      // เพราะระบบอาจไม่อนุญาต full-screen intent ในบางสถานะหน้าจอ
      try {
        await _showIncomingCallActivity(
          channelId: data['channelId'] ?? '',
          token: data['token'],
          callerId: data['callerId'] ?? data['caller_id'] ?? '',
          callerName: data['callerName'] ?? 'ผู้โทร',
          callerPhotoUrl: data['callerPhotoUrl'],
          isVideo: _resolveIsVideoFlag(data),
        );
      } catch (_) {
        // ignore – Flutter UI ด้านล่างยังทำงานได้ตามปกติ
      }

      // เปิดหน้า CallScreen (Flutter) ทุกครั้ง เพื่อให้แน่ใจว่า
      // ในทุกสถานะของแอป (foreground) จะมีหน้ารับสายเด้งขึ้นมา
      _navigateToIncomingCall(
        channelId: data['channelId'] ?? '',
        appId: data['appId'],
        token: data['token'],
        callerId: data['callerId'] ?? data['caller_id'] ?? '',
        callerName: data['callerName'] ?? 'ผู้โทร',
        callerPhotoUrl: data['callerPhotoUrl'],
        isVideo: _resolveIsVideoFlag(data),
      );
      return;
    }

    if (_isIncomingShopDecisionNotification(data)) {
      await _showIncomingOrderDecisionPrompt(data);
      return;
    }

    if (_isProductAiReadyNotification(data)) {
      await _showProductAiReadyNotification(data);
      return;
    }

    final fallbackTitle = (data['title'] as String?)?.trim();
    final fallbackBody = (data['body'] as String?)?.trim();
    if (notification != null ||
        (fallbackTitle?.isNotEmpty == true ||
            fallbackBody?.isNotEmpty == true)) {
      await _showLocalNotification(
        title: notification?.title?.trim().isNotEmpty == true
            ? notification!.title!.trim()
            : (fallbackTitle?.isNotEmpty == true
                  ? fallbackTitle!
                  : 'แจ้งเตือน'),
        body: notification?.body?.trim().isNotEmpty == true
            ? notification!.body!.trim()
            : (fallbackBody ?? ''),
        payload: jsonEncode(<String, dynamic>{
          'type': data['type'] ?? 'app_notification',
          'orderId': data['orderId'],
          'action': data['action'],
          'title': fallbackTitle ?? notification?.title,
          'body': fallbackBody ?? notification?.body,
        }),
      );
    }

    // เปิดหน้ารับสายอัตโนมัติถ้าเป็น notification ประเภท call
    // ลบโค้ดซ้ำซ้อนที่เปิด CallScreen อัตโนมัติ (จัดการใน showDialog ด้านบนแล้ว)
  }

  /// ดึง navigatorKey จาก MyApp (ต้องตั้ง navigatorKey ใน MaterialApp)
  // หมายเหตุ: วิธีนี้อาจไม่เสถียร ควรใช้ DI หรือ Service Locator ในแอปขนาดใหญ่
  // ลบฟังก์ชัน _getNavigatorKey ที่ไม่ได้ใช้งาน

  /// แสดง local notification
  Future<void> _showLocalNotification({
    required String title,
    required String body,
    String? payload,
  }) async {
    debugPrint('Showing local notification: $title');
    const androidDetails = AndroidNotificationDetails(
      'order_channel',
      'การแจ้งเตือนออเดอร์',
      channelDescription: 'แจ้งเตือนเกี่ยวกับสถานะออเดอร์',
      importance: Importance.high,
      priority: Priority.high,
      enableVibration: true,
      playSound: true,
    );

    const iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
    );

    const notificationDetails = NotificationDetails(
      android: androidDetails,
      iOS: iosDetails,
    );

    await _localNotifications.show(
      DateTime.now().millisecond,
      title,
      body,
      notificationDetails,
      payload: payload,
    );
  }

  /// จัดการเมื่อกด notification
  void _onNotificationTapped(NotificationResponse response) {
    final payload = response.payload;
    if (payload == null || payload.isEmpty) {
      return;
    }
    try {
      final decoded = jsonDecode(payload);
      if (decoded is Map<String, dynamic>) {
        if (decoded['type'] == 'call') {
          _navigateToIncomingCall(
            channelId: decoded['channelId'] as String? ?? '',
            appId: decoded['appId'] as String?,
            token: decoded['token'] as String?,
            callerId: decoded['callerId'] as String? ?? '',
            callerName: decoded['callerName'] as String? ?? 'ผู้โทร',
            callerPhotoUrl: decoded['callerPhotoUrl'] as String?,
            isVideo: decoded['isVideo'] == true,
          );
          return;
        }
        if (decoded['type'] == 'chat') {
          _openChatFromNotificationData(decoded);
          return;
        }
        if (_isProductAiReadyNotification(decoded)) {
          final notificationId = _resolveProductAiNotificationId(decoded);
          if (notificationId != null) {
            unawaited(markAppNotificationRead(notificationId));
          }
          return;
        }
        if (decoded['type'] == 'app_notification') {
          if (_isWalletNotificationAction(decoded['action'] as String?)) {
            _openWallet();
            return;
          }
          _openOrderManagement(decoded['orderId'] as String?);
          return;
        }
      }
      debugPrint('Notification tapped with payload: $payload');
    } catch (error) {
      _openOrderManagement(payload);
      debugPrint('Failed to parse notification payload: $error');
    }
  }

  /// จัดการเมื่อกด notification จาก background
  void _handleNotificationTap(RemoteMessage message) {
    debugPrint('Notification tapped from background: ${message.messageId}');
    if (!_isProductAiReadyNotification(message.data)) {
      unawaited(
        _persistVan1RemoteMessageToInbox(
          message.data,
          messageId: message.messageId,
          title: message.notification?.title,
          body: message.notification?.body,
        ),
      );
    }
    if (_isIncomingShopDecisionNotification(message.data)) {
      unawaited(_showIncomingOrderDecisionPrompt(message.data));
      return;
    }

    if (_isProductAiReadyNotification(message.data)) {
      final notificationId = _resolveProductAiNotificationId(message.data);
      if (notificationId != null) {
        unawaited(markAppNotificationRead(notificationId));
      }
      return;
    }

    if (message.data['type'] == 'app_notification') {
      if (_isWalletNotificationAction(message.data['action'] as String?)) {
        _openWallet();
        return;
      }
      final orderId = message.data['orderId'] as String?;
      if (orderId != null && orderId.isNotEmpty) {
        _openOrderManagement(orderId);
      }
    }

    // เปิดหน้ารับสายอัตโนมัติเมื่อแตะ notification ประเภท call
    if (message.data['type'] == 'call') {
      final currentUid = FirebaseAuth.instance.currentUser?.uid;
      final callerId = message.data['callerId'] ?? message.data['caller_id'];
      if (currentUid != null && callerId != null && currentUid == callerId) {
        debugPrint(
          'Skip navigating to CallScreen for self-originated notification',
        );
        return;
      }
      _navigateToIncomingCall(
        channelId: message.data['channelId'] ?? '',
        appId: message.data['appId'],
        token: message.data['token'],
        callerId: message.data['callerId'] ?? message.data['caller_id'] ?? '',
        callerName: message.data['callerName'] ?? 'ผู้โทร',
        callerPhotoUrl: message.data['callerPhotoUrl'],
        isVideo: _resolveIsVideoFlag(message.data),
      );
    }

    if (message.data['type'] == 'call_cancel') {
      _handleCallCancelFromNative(message.data['channelId'] as String?);
      return;
    }

    if (message.data['type'] == 'chat') {
      _openChatFromNotificationData(message.data);
    }
  }

  bool _isIncomingShopDecisionNotification(Map<String, dynamic> data) {
    final type = (data['type'] as String?)?.trim();
    final action = (data['action'] as String?)?.trim();
    return (type == null || type.isEmpty || type == 'app_notification') &&
        action == 'order_accepted';
  }

  bool _isProductAiReadyNotification(Map<String, dynamic> data) {
    return (data['action'] as String?)?.trim() == 'product_ai_ready' ||
        (data['type'] as String?)?.trim() == 'product_ai_ready';
  }

  String? _resolveProductAiNotificationId(Map<String, dynamic> data) {
    final fromPayload = (data['notificationId'] as String?)?.trim();
    if (fromPayload != null && fromPayload.isNotEmpty) {
      return fromPayload;
    }
    final jobId = (data['jobId'] as String?)?.trim();
    if (jobId != null && jobId.isNotEmpty) {
      return 'product_ai_$jobId';
    }
    return null;
  }

  String _productAiNotificationBody(Map<String, dynamic> data) {
    const prefix = 'พร้อมเติมข้อมูล: ';
    final rawBody = (data['body'] as String?)?.trim() ?? '';
    if (rawBody.startsWith(prefix)) {
      final productName = rawBody.substring(prefix.length).trim();
      if (productName.isNotEmpty) {
        return productName;
      }
    }
    if (rawBody.isNotEmpty && rawBody != 'แตะเพื่อดูผลและเติมข้อมูลสินค้า') {
      return rawBody;
    }
    return 'พร้อมเติมข้อมูล';
  }

  Future<void> markAppNotificationRead(String id) async {
    final normalizedId = id.trim();
    if (normalizedId.isEmpty) {
      return;
    }
    await FirebaseFirestore.instance
        .collection('app_notifications')
        .doc(normalizedId)
        .set(<String, dynamic>{
          'read': true,
          'readAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
  }

  Future<void> createInboxNotification({
    required String title,
    required String body,
    String? orderId,
    String action = 'general',
    String? recipientUid,
    String? documentId,
    Map<String, dynamic>? extraData,
  }) async {
    final currentUid = FirebaseAuth.instance.currentUser?.uid.trim();
    final toUid = recipientUid?.trim().isNotEmpty == true
        ? recipientUid!.trim()
        : currentUid;
    if (toUid == null || toUid.isEmpty) {
      return;
    }

    final collection = FirebaseFirestore.instance.collection(
      'app_notifications',
    );
    final payload = <String, dynamic>{
      'targetApp': 'van1',
      'recipientUid': toUid,
      if (orderId?.trim().isNotEmpty == true) 'orderId': orderId!.trim(),
      'title': title.trim().isNotEmpty ? title.trim() : 'แจ้งเตือน',
      'body': body.trim(),
      'read': false,
      'createdAt': FieldValue.serverTimestamp(),
      'source': 'van1_shop',
      'sourceApp': 'van1',
      'action': action.trim().isNotEmpty ? action.trim() : 'general',
      if (extraData != null) ...extraData,
    };

    if (documentId?.trim().isNotEmpty == true) {
      await collection
          .doc(documentId!.trim())
          .set(payload, SetOptions(merge: true));
      return;
    }

    await collection.add(payload);
  }

  Future<DetailedOrder?> loadActionableShopOrder(String orderId) {
    return _loadActionableShopOrder(orderId);
  }

  Future<void> acceptShopOrder(
    DetailedOrder order, {
    bool openOrderManagementAfterAccept = true,
    String? notificationId,
  }) async {
    await _acceptShopOrder(order);
    if (notificationId != null && notificationId.trim().isNotEmpty) {
      await markAppNotificationRead(notificationId);
    }
    if (openOrderManagementAfterAccept) {
      openOrderManagement(order.orderId);
    }
  }

  Future<void> rejectShopOrder(
    DetailedOrder order, {
    String? notificationId,
  }) async {
    await _rejectShopOrder(order);
    if (notificationId != null && notificationId.trim().isNotEmpty) {
      await markAppNotificationRead(notificationId);
    }
  }

  void openOrderManagement([String? orderId]) {
    _openOrderManagement(orderId);
  }

  Future<void> openChatFromNotificationData(Map<String, dynamic> data) {
    return _openChatFromNotificationData(data);
  }

  Future<void> _showProductAiReadyNotification(
    Map<String, dynamic> data,
  ) async {
    final notificationId = _resolveProductAiNotificationId(data);
    if (notificationId == null ||
        !_shownProductAiNotificationIds.add(notificationId)) {
      return;
    }

    await _showLocalNotification(
      title: 'AI วิเคราะห์เสร็จแล้ว',
      body: _productAiNotificationBody(data),
      payload: jsonEncode(<String, dynamic>{
        'type': 'product_ai_ready',
        'action': 'product_ai_ready',
        'notificationId': notificationId,
      }),
    );

    unawaited(markAppNotificationRead(notificationId));
  }

  Future<void> _showIncomingOrderDecisionPrompt(
    Map<String, dynamic> data, {
    int retryCount = 40,
  }) async {
    final String orderId = (data['orderId'] as String?)?.trim() ?? '';
    final String notificationId =
        (data['notificationId'] as String?)?.trim() ?? '';
    if (orderId.isEmpty || _activeOrderPromptId == orderId) {
      return;
    }

    final navigator = MyApp.navigatorKey.currentState;
    final overlayContext = navigator?.overlay?.context;
    if (overlayContext == null) {
      if (retryCount <= 0 || !_queuedShopDecisionOrderIds.add(orderId)) {
        return;
      }
      Future.delayed(const Duration(milliseconds: 300), () {
        _queuedShopDecisionOrderIds.remove(orderId);
        unawaited(
          _showIncomingOrderDecisionPrompt(data, retryCount: retryCount - 1),
        );
      });
      return;
    }

    final order = await _loadActionableShopOrder(orderId);
    if (order == null) {
      return;
    }

    final operationsSettings = await ShopOperationsService.fetchSettings(
      order.shopId,
    );
    if (!operationsSettings.notifyNewOrders) {
      return;
    }

    _activeOrderPromptId = orderId;
    try {
      final accepted = await navigator!.push<bool>(
        MaterialPageRoute<bool>(
          fullscreenDialog: true,
          builder: (_) => IncomingShopOrderScreen(
            order: order,
            autoStartVoiceListening:
                operationsSettings.autoListenIncomingOrders,
            title: data['title'] as String?,
            message: data['body'] as String?,
            onAccept: () => acceptShopOrder(
              order,
              openOrderManagementAfterAccept: false,
              notificationId: notificationId,
            ),
            onReject: () =>
                rejectShopOrder(order, notificationId: notificationId),
          ),
        ),
      );
      if (accepted == true) {
        openOrderManagement(order.orderId);
      }
    } finally {
      if (_activeOrderPromptId == orderId) {
        _activeOrderPromptId = null;
      }
    }
  }

  Future<DetailedOrder?> _loadActionableShopOrder(String orderId) async {
    try {
      final snapshot = await FirebaseFirestore.instance
          .collection('orders')
          .doc(orderId)
          .get();
      final data = snapshot.data();
      if (!snapshot.exists || data == null) {
        return null;
      }

      final currentUser = FirebaseAuth.instance.currentUser;
      final shopId = (data['shopId'] as String?)?.trim();
      final shopOwnerId = (data['shopOwnerId'] as String?)?.trim();
      final isShopParticipant =
          currentUser != null &&
          ((shopOwnerId != null && shopOwnerId == currentUser.uid) ||
              (shopId != null && shopId == currentUser.uid));
      if (!isShopParticipant) {
        return null;
      }

      final order = DetailedOrder.fromSnapshot(snapshot);
      final driverId = (data['driverId'] as String?)?.trim() ?? '';
      final orderType = (data['orderType'] as String?)?.trim() ?? '';
      final fulfillmentType =
          (data['fulfillmentType'] as String?)?.trim() ?? '';
      final bool awaitingNationwideShopDecision =
          orderType == 'nationwide_parcel' &&
          fulfillmentType == 'external_courier' &&
          order.preparingStartTime == null &&
          data['shopDecisionStatus'] != 'rejected' &&
          data['shopRejectedAt'] == null &&
          <String>{
            'accepted',
            'awaiting_shipping_booking',
            'awaiting_shop_confirmation',
          }.contains(order.status);
      final bool awaitingShopDecision =
          (order.status == 'accepted' &&
          driverId.isNotEmpty &&
          order.preparingStartTime == null &&
          data['shopDecisionStatus'] != 'rejected' &&
          data['shopRejectedAt'] == null);
      return (awaitingShopDecision || awaitingNationwideShopDecision)
          ? order
          : null;
    } catch (error) {
      debugPrint('Failed to load actionable order $orderId: $error');
      return null;
    }
  }

  Future<void> _acceptShopOrder(DetailedOrder order) async {
    final shopId = order.shopId.trim();
    if (shopId.isNotEmpty) {
      final settings = await ShopOperationsService.fetchSettings(shopId);
      final blockMessage = ShopOperationsService.penaltyBlockMessage(settings);
      if (blockMessage != null) {
        throw Exception(blockMessage);
      }
    }

    final now = DateTime.now();
    final preparationMinutes = (order.preparingDuration / 60000)
        .ceil()
        .clamp(1, 240)
        .toDouble();
    final updatedOrder = order.copyWith(
      status: 'preparing',
      acceptedAt: now,
      preparingStartTime: now,
      notifications: <String, NotificationStatus>{
        'firstWarning': NotificationStatus(
          sent: false,
          timeInMinutes: preparationMinutes * 0.5,
        ),
        'secondWarning': NotificationStatus(
          sent: false,
          timeInMinutes: preparationMinutes * 0.75,
        ),
        'finalWarning': NotificationStatus(
          sent: false,
          timeInMinutes: preparationMinutes,
        ),
      },
    );

    await FirebaseFirestore.instance
        .collection('orders')
        .doc(order.orderId)
        .update(<String, dynamic>{
          ...updatedOrder.toMap(),
          'shopDecisionStatus': 'accepted',
          'shopAcceptedAt': Timestamp.fromDate(now),
          if (order.orderType == 'nationwide_parcel') ...<String, dynamic>{
            'shippingStatus': 'merchant_preparing',
            'shippingStatusLabel': 'ร้านกำลังเตรียมพัสดุ',
          },
          'shopRejectedAt': FieldValue.delete(),
          'shopRejectedBy': FieldValue.delete(),
          'customerShopChoice': FieldValue.delete(),
          'customerShopWaitUntil': FieldValue.delete(),
          'customerShopWaitRequestedAt': FieldValue.delete(),
        });

    await _sendOrderAppNotification(
      targetApp: 'van3',
      recipientUid: order.driverId,
      orderId: order.orderId,
      title: 'ร้านรับออเดอร์แล้ว',
      body:
          'ออเดอร์ #${order.orderId.substring(0, order.orderId.length >= 8 ? 8 : order.orderId.length)} ร้านเริ่มเตรียมสินค้าแล้ว',
      action: 'shop_accepted_order',
    );
  }

  Future<void> _rejectShopOrder(DetailedOrder order) async {
    await FirebaseFirestore.instance
        .collection('orders')
        .doc(order.orderId)
        .update(<String, dynamic>{
          'status': order.status == 'accepted' ? 'accepted' : 'pending',
          'shopDecisionStatus': 'rejected',
          'shopRejectedAt': FieldValue.serverTimestamp(),
          'shopRejectedBy': FirebaseAuth.instance.currentUser?.uid,
          'cancelReason': 'shop_rejected_waiting_customer_decision',
          'updatedAt': FieldValue.serverTimestamp(),
        });

    await _sendOrderAppNotification(
      targetApp: 'van3',
      recipientUid: order.driverId,
      orderId: order.orderId,
      title: 'ร้านปฏิเสธออเดอร์',
      body:
          'ออเดอร์ #${order.orderId.substring(0, order.orderId.length >= 8 ? 8 : order.orderId.length)} รอลูกค้าเลือกรอหรือแคนเซิล',
      action: 'shop_rejected_order',
    );

    await _sendOrderAppNotification(
      targetApp: 'van2',
      recipientUid: order.customerId,
      orderId: order.orderId,
      title: 'ร้านค้าปฏิเสธออเดอร์',
      body: 'เลือกรออีก 15 นาทีหรือแคนเซิลออเดอร์ได้ในการ์ดออเดอร์',
      action: 'shop_rejected_order',
    );
  }

  Future<void> _sendOrderAppNotification({
    required String targetApp,
    required String? recipientUid,
    required String orderId,
    required String title,
    required String body,
    required String action,
  }) async {
    final toUid = recipientUid?.trim();
    if (toUid == null || toUid.isEmpty) {
      return;
    }

    await FirebaseFirestore.instance
        .collection('app_notifications')
        .add(<String, dynamic>{
          'targetApp': targetApp,
          'recipientUid': toUid,
          'orderId': orderId,
          'title': title,
          'body': body,
          'read': false,
          'createdAt': FieldValue.serverTimestamp(),
          'source': 'van1_shop',
          'sourceApp': 'van1',
          'action': action,
        });
  }

  void openWalletFromNotification() {
    _openWallet();
  }

  void _openWallet() {
    final navigator = MyApp.navigatorKey.currentState;
    if (navigator == null) {
      return;
    }

    navigator.push(
      MaterialPageRoute<void>(builder: (_) => const WalletScreen()),
    );
  }

  void _openOrderManagement([String? orderId]) {
    final navigator = MyApp.navigatorKey.currentState;
    final context = navigator?.overlay?.context;
    if (navigator == null || context == null) {
      return;
    }

    navigator.push(
      MaterialPageRoute<void>(
        builder: (_) => OrderManagementScreen(focusOrderId: orderId),
      ),
    );
  }

  void _setupCallIntentBridge() {
    if (!Platform.isAndroid || _callIntentBridgeAttached) {
      return;
    }
    _callIntentBridgeAttached = true;
    _callIntentChannel.setMethodCallHandler((call) async {
      if (call.method != 'incoming_call_intent') {
        return;
      }
      _handleIncomingCallPayload(call.arguments);
    });
    _drainPendingAndroidIntents();
  }

  Map<String, dynamic>? _normalizePlatformPayload(dynamic arguments) {
    if (arguments is! Map) {
      return null;
    }
    final normalized = <String, dynamic>{};
    arguments.forEach((key, value) {
      normalized[key.toString()] = value;
    });
    return normalized;
  }

  Future<void> _drainPendingAndroidIntents() async {
    try {
      final List<dynamic>? pending = await _callIntentChannel
          .invokeListMethod<dynamic>(_methodDrainPending);
      if (pending == null) return;
      for (final dynamic rawPayload in pending) {
        _handleIncomingCallPayload(rawPayload);
      }
    } catch (error) {
      debugPrint('Unable to drain Android call intents: $error');
    }
  }

  Future<bool> _showIncomingCallActivity({
    required String channelId,
    required String? token,
    required String callerId,
    required String callerName,
    String? callerPhotoUrl,
    required bool isVideo,
  }) async {
    if (!Platform.isAndroid ||
        channelId.isEmpty ||
        token == null ||
        token.isEmpty) {
      return false;
    }
    try {
      await _appStateChannel.invokeMethod<void>(
        _methodShowIncomingCallActivity,
        <String, dynamic>{
          'extra_channel_id': channelId,
          'extra_call_token': token,
          'extra_caller_id': callerId,
          'extra_caller_name': callerName,
          'extra_caller_photo': callerPhotoUrl,
          'extra_is_video': isVideo,
        },
      );
      return true;
    } catch (error) {
      debugPrint('Unable to open native incoming call activity: $error');
      return false;
    }
  }

  void _handleIncomingCallPayload(dynamic payloadData) {
    final payload = _normalizePlatformPayload(payloadData);
    if (payload == null) {
      return;
    }
    if (payload['orderDecision'] == true) {
      unawaited(_showIncomingOrderDecisionPrompt(payload));
      return;
    }
    if (payload['type'] == 'chat') {
      unawaited(_openChatFromNotificationData(payload));
      return;
    }
    if (payload['cancelOnly'] == true) {
      _handleCallCancelFromNative(payload['channelId'] as String?);
      return;
    }
    final bool minimizeOnEnd = payload['appWasForeground'] == false;
    _navigateToIncomingCall(
      channelId: payload['channelId'] as String? ?? '',
      appId: payload['appId'] as String?,
      token: payload['token'] as String?,
      callerId: payload['callerId'] as String? ?? '',
      callerName: payload['callerName'] as String? ?? 'ผู้โทร',
      callerPhotoUrl: payload['callerPhotoUrl'] as String?,
      isVideo: payload['isVideo'] == true,
      minimizeOnEnd: minimizeOnEnd,
    );
  }

  void _handleCallCancelFromNative(String? channelId) {
    if (channelId != null) {
      _cancelledChannelIds.add(channelId);
    }
    _dismissIncomingCallUI(channelId: channelId);
  }

  void _dismissIncomingCallUI({String? channelId}) {
    if (!_incomingCallVisible) {
      return;
    }
    if (_activeIncomingChannelId != null &&
        channelId != null &&
        _activeIncomingChannelId != channelId) {
      return;
    }
    final navigatorState = MyApp.navigatorKey.currentState;
    if (navigatorState != null) {
      navigatorState.maybePop();
    }
    _incomingCallVisible = false;
    _activeIncomingChannelId = null;
    _maybeReturnAppToBackground(channelId: channelId);
  }

  void _navigateToIncomingCall({
    required String channelId,
    required String? appId,
    required String? token,
    required String callerId,
    required String callerName,
    String? callerPhotoUrl,
    required bool isVideo,
    int retryCount = 40,
    bool minimizeOnEnd = false,
  }) {
    if (channelId.isEmpty || token == null || token.isEmpty) {
      debugPrint(
        'Incoming call payload missing channel/token, skip UI presentation',
      );
      return;
    }
    if (_cancelledChannelIds.contains(channelId)) {
      debugPrint('Call $channelId already cancelled, skip presenting UI');
      return;
    }
    if (_incomingCallVisible) {
      debugPrint('Incoming call UI already visible, skip duplicate navigation');
      return;
    }
    final navigatorState = MyApp.navigatorKey.currentState;
    final context = navigatorState?.context;
    if (context == null) {
      if (retryCount <= 0) {
        debugPrint('Navigator context unavailable, cannot open CallScreen');
        return;
      }
      Future.delayed(const Duration(milliseconds: 300), () {
        _navigateToIncomingCall(
          channelId: channelId,
          appId: appId,
          token: token,
          callerId: callerId,
          callerName: callerName,
          callerPhotoUrl: callerPhotoUrl,
          isVideo: isVideo,
          retryCount: retryCount - 1,
          minimizeOnEnd: minimizeOnEnd,
        );
      });
      return;
    }

    _incomingCallVisible = true;
    _activeIncomingChannelId = channelId;
    if (minimizeOnEnd) {
      _backgroundReturnChannelId = channelId;
      _shouldReturnAppToBackground = true;
    }
    navigatorState!
        .push(
          MaterialPageRoute(
            fullscreenDialog: true,
            builder: (_) => CallScreen(
              channelName: channelId,
              targetProfile: UserProfile.fromMap(callerId, {
                'displayName': callerName,
                'photoUrl': callerPhotoUrl,
              }),
              isVideo: isVideo,
              isIncoming: true,
              appIdOverride: appId,
              tokenOverride: token,
            ),
          ),
        )
        .whenComplete(() {
          _incomingCallVisible = false;
          if (_activeIncomingChannelId == channelId) {
            _activeIncomingChannelId = null;
          }
          _cancelledChannelIds.remove(channelId);
          _maybeReturnAppToBackground(channelId: channelId);
        });
  }

  bool _resolveIsVideoFlag(Map<String, dynamic> data) {
    final raw = data['callType'] ?? data['isVideo'];
    if (raw is bool) return raw;
    if (raw is String) {
      final lower = raw.toLowerCase();
      return lower == 'video' || lower == 'true';
    }
    return false;
  }

  /// ส่ง notification แบบ manual (สำหรับทดสอบ)
  Future<void> sendTestNotification() async {
    await _showLocalNotification(
      title: 'ทดสอบการแจ้งเตือน',
      body: 'นี่คือการแจ้งเตือนทดสอบจากระบบ',
    );
  }

  Future<void> _maybeReturnAppToBackground({String? channelId}) async {
    if (!_shouldReturnAppToBackground) {
      return;
    }
    if (_backgroundReturnChannelId != null &&
        channelId != null &&
        _backgroundReturnChannelId != channelId) {
      return;
    }
    _shouldReturnAppToBackground = false;
    _backgroundReturnChannelId = null;
    if (!Platform.isAndroid) {
      return;
    }
    try {
      await _appStateChannel.invokeMethod('move_task_to_back');
    } catch (error) {
      debugPrint('Unable to return app to background: $error');
    }
  }

  Future<void> _openChatFromNotificationData(
    Map<String, dynamic> data, {
    int retryCount = 6,
  }) async {
    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser == null) {
      debugPrint('Skip navigating to chat: no authenticated user');
      return;
    }
    final navigatorState = MyApp.navigatorKey.currentState;
    if (navigatorState == null) {
      if (retryCount <= 0) {
        debugPrint('Navigator not ready, cannot navigate to chat');
        return;
      }
      Future.delayed(const Duration(milliseconds: 250), () {
        _openChatFromNotificationData(data, retryCount: retryCount - 1);
      });
      return;
    }

    final senderIdRaw = data['senderId'] ?? data['sender_id'];
    final String? senderId = senderIdRaw?.toString();
    final senderName = (data['senderName'] ?? data['title'] ?? 'คู่สนทนา')
        .toString();

    UserProfile? profile;
    if (senderId != null && senderId.isNotEmpty) {
      profile = await _resolveChatProfile(senderId);
    }

    profile ??= UserProfile(
      uid: senderId ?? 'unknown',
      displayName: senderName,
    );

    navigatorState.push(
      MaterialPageRoute(
        builder: (_) => ChatRoomScreen(friendProfile: profile!),
      ),
    );
  }

  Future<UserProfile?> _resolveChatProfile(String uid) async {
    for (final collection in _chatProfileCollections) {
      try {
        final doc = await FirebaseFirestore.instance
            .collection(collection)
            .doc(uid)
            .get();
        if (!doc.exists) {
          continue;
        }

        final data = doc.data();
        if (data == null) {
          continue;
        }

        return UserProfile.fromMap(uid, data);
      } catch (error) {
        debugPrint(
          'Failed to load chat profile for $uid from $collection: $error',
        );
      }
    }

    return null;
  }

  // ฟังก์ชันสำหรับโทรจริง (voice/video call)
  // เรียก Cloud Function callUser
  Future<void> callUser({
    required String callerId,
    required String callerName,
    required String callerPhotoUrl,
    required String calleeId,
    required String calleeFCMToken,
    required String callType, // 'voice' หรือ 'video'
  }) async {
    await AppCheckGuard.ensureFinancialReady();
    final callable = FirebaseFunctions.instanceFor(
      region: 'asia-southeast1',
    ).httpsCallable('callUser');
    final result = await callable.call({
      'callerId': callerId,
      'callerName': callerName,
      'callerPhotoUrl': callerPhotoUrl,
      'calleeId': calleeId,
      'calleeFCMToken': calleeFCMToken,
      'callType': callType,
    });
    print('Call result: ${result.data}');
  }

  Future<void> cancelCallInvite({
    required String channelId,
    required String calleeId,
  }) async {
    try {
      await AppCheckGuard.ensureFinancialReady();
      final callable = FirebaseFunctions.instanceFor(
        region: 'asia-southeast1',
      ).httpsCallable('cancelCallInvite');
      await callable.call({
        'channelId': channelId,
        'calleeId': calleeId,
        'callerId': FirebaseAuth.instance.currentUser?.uid,
      });
    } catch (error) {
      debugPrint('Failed to cancel call invite: $error');
    }
  }

  /// เริ่มการโทรโดยเรียก Cloud Function เพื่อสร้าง token และส่ง notification
  Future<Map<String, dynamic>> initiateCall({
    required UserProfile caller,
    required UserProfile callee,
    required bool isVideo,
  }) async {
    try {
      await AppCheckGuard.ensureFinancialReady();
    } catch (error) {
      throw _CallStartException(_cleanExceptionMessage(error));
    }

    const List<String> preferredRegions = <String>[
      'asia-southeast1',
      'us-central1',
    ];
    FirebaseFunctionsException? lastError;

    for (final region in preferredRegions) {
      try {
        final callable = FirebaseFunctions.instanceFor(
          region: region,
        ).httpsCallable('initiateCall');
        final result = await callable.call(<String, dynamic>{
          'calleeId': callee.uid,
          'callerId': caller.uid,
          'callerName': caller.displayName,
          'callerPhotoUrl': caller.photoUrl,
          'isVideo': isVideo,
          'callType': isVideo ? 'video' : 'voice',
          'callerData': caller.toFirestore()..['uid'] = caller.uid,
        });
        return Map<String, dynamic>.from(result.data);
      } on FirebaseFunctionsException catch (e) {
        lastError = e;
        debugPrint(
          'Error initiating call via $region: ${e.code} - ${e.message}',
        );
        if (_isAppCheckRequiredError(e)) {
          throw const _CallStartException(
            'ไม่สามารถยืนยันความปลอดภัยของอุปกรณ์ได้ กรุณาปิดแอปแล้วเปิดใหม่ หรืออัปเดตจาก TestFlight แล้วลองใหม่',
          );
        }
        if (e.code != 'not-found') {
          throw _CallStartException(_callStartMessageForFunctionsError(e));
        }
      }
    }

    if (lastError != null) {
      throw lastError;
    }
    throw FirebaseFunctionsException(
      code: 'unknown',
      message: 'Unknown error initiating call',
    );
  }

  static bool _isAppCheckRequiredError(FirebaseFunctionsException error) {
    final text = [
      error.code,
      error.message,
      error.details,
    ].whereType<Object>().join(' ').toLowerCase();
    return text.contains('app check') ||
        text.contains('appcheck') ||
        text.contains('verification required');
  }

  static String _cleanExceptionMessage(Object error) {
    return error.toString().replaceFirst('Exception: ', '').trim();
  }

  static String _callStartMessageForFunctionsError(
    FirebaseFunctionsException error,
  ) {
    final message = error.message ?? '';
    final lower = message.toLowerCase();

    if (error.code == 'failed-precondition') {
      if (lower.contains('agora') ||
          lower.contains('app_id') ||
          lower.contains('certificate')) {
        return 'ระบบโทรยังไม่ได้ตั้งค่า Agora Secret บน Cloud Functions ครบ ต้องตั้ง AGORA_APP_ID และ AGORA_APP_CERTIFICATE แล้ว deploy function initiateCall';
      }
      if (lower.contains('fcm') || lower.contains('token')) {
        return 'เครื่องปลายทางยังไม่มีโทเคนแจ้งเตือน กรุณาเปิดแอปปลายทางและอนุญาตแจ้งเตือนก่อน';
      }
      return message.isNotEmpty ? message : 'ยังไม่สามารถเริ่มโทรได้ในตอนนี้';
    }

    if (error.code == 'internal') {
      return 'Cloud Function สำหรับโทรยังผิดพลาดภายใน กรุณา deploy function initiateCall เวอร์ชันล่าสุดแล้วลองใหม่';
    }

    return message.isNotEmpty
        ? message
        : 'เริ่มการโทรไม่สำเร็จ (${error.code})';
  }
}

class _CallStartException implements Exception {
  const _CallStartException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Background message handler (ต้องเป็น top-level function)
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandlerVan1(
  RemoteMessage message,
) async {
  debugPrint('Background message received: ${message.messageId}');
  if (Firebase.apps.isEmpty) {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
  }
  await _persistVan1RemoteMessageToInbox(
    message.data,
    messageId: message.messageId,
    title: message.notification?.title,
    body: message.notification?.body,
  );
}
