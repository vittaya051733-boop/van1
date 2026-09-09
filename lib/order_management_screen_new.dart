import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'models/order_model.dart';
import 'models/user_profile.dart';
import 'models/shop_operations_settings.dart';
import 'utils/app_colors.dart';
import 'utils/rider_call_launcher.dart';
import 'test_order_helper.dart';
import 'order_qr_screen.dart';
import 'chat_room_screen.dart';
import 'services/chat_warmup.dart';
import 'services/notification_service.dart';
import 'services/shop_operations_service.dart';
import 'main.dart';
import 'utils/product_variant_color.dart';

String _orderItemVariantLabel(OrderItem item) {
  final parts = <String>[
    if (item.selectedColor?.trim().isNotEmpty == true)
      ProductVariantColorSupport.displayLabel(item.selectedColor),
    if (item.selectedSize?.trim().isNotEmpty == true)
      item.selectedSize!.trim(),
  ];
  if (parts.isEmpty) {
    return '';
  }
  return 'ตัวเลือก: ${parts.join(' · ')}';
}

class OrderManagementScreen extends StatefulWidget {
  const OrderManagementScreen({super.key, this.focusOrderId});

  final String? focusOrderId;

  @override
  State<OrderManagementScreen> createState() => _OrderManagementScreenState();
}

const List<String> _shopActiveOrderStatuses = <String>[
  'accepted',
  'preparing',
  'ready',
  'delivering',
  'awaiting_shipping_booking',
];
const int _shopActiveOrdersLimit = 80;
final Map<String, QuerySnapshot<Map<String, dynamic>>>
_prefetchedShopOrderSnapshots =
    <String, QuerySnapshot<Map<String, dynamic>>>{};

/// Warm Firestore local cache so order management opens faster.
Future<void> prefetchShopOrdersCache(String shopId) async {
  if (shopId.trim().isEmpty) return;
  final activeQuery = FirebaseFirestore.instance
      .collection('orders')
      .where('shopOwnerId', isEqualTo: shopId)
      .where('status', whereIn: _shopActiveOrderStatuses)
      .orderBy('createdAt', descending: true)
      .limit(_shopActiveOrdersLimit);
  try {
    final cached = await activeQuery
        .get(const GetOptions(source: Source.cache))
        .timeout(const Duration(milliseconds: 700));
    if (cached.docs.isNotEmpty) {
      _prefetchedShopOrderSnapshots[shopId] = cached;
    }
  } catch (_) {}

  try {
    final fresh = await activeQuery
        .get(const GetOptions(source: Source.server))
        .timeout(const Duration(seconds: 6));
    _prefetchedShopOrderSnapshots[shopId] = fresh;
  } on FirebaseException catch (error) {
    if (error.code != 'failed-precondition') return;
    try {
      final fallback = await FirebaseFirestore.instance
          .collection('orders')
          .where('shopOwnerId', isEqualTo: shopId)
          .limit(_shopActiveOrdersLimit)
          .get(const GetOptions(source: Source.server))
          .timeout(const Duration(seconds: 6));
      _prefetchedShopOrderSnapshots[shopId] = fallback;
    } catch (_) {}
  } catch (_) {}
}

class _OrderManagementScreenState extends State<OrderManagementScreen> {
  static const int _lowStockThreshold = 5;
  static const int _activeOrdersLimit = _shopActiveOrdersLimit;
  static const List<String> _activeOrderStatuses = _shopActiveOrderStatuses;
  static const MethodChannel _voiceAudioChannel = MethodChannel(
    'van.merchant/voice_audio',
  );
  static const double _voiceNoiseGateDelta = 3.5;
  static const double _voiceNoiseGateMinimumPeak = 5.5;
  static const double _voiceNoiseGateAmbientGain = 0.12;
  String? _shopId;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _ordersSubscription;
  bool _ordersLoading = true;
  bool _receivedServerOrders = false;
  DateTime? _ordersWatchStartedAt;
  String? _ordersError;
  final Map<String, Future<_RiderContactState>> _riderContactFutures =
      <String, Future<_RiderContactState>>{};
  ShopOperationsSettings _operationsSettings =
      ShopOperationsSettings.defaults();
  StreamSubscription<ShopOperationsSettings>? _operationsSubscription;
  final Set<String> _autoAcceptingOrders = <String>{};
  final ScrollController _ordersScrollController = ScrollController();
  final Map<String, GlobalKey> _orderCardKeys = <String, GlobalKey>{};
  final stt.SpeechToText _speech = stt.SpeechToText();
  final ValueNotifier<_VoicePanelDisplay> _voicePanelDisplay =
      ValueNotifier<_VoicePanelDisplay>(
        const _VoicePanelDisplay(
          enabled: false,
          listening: false,
          message: 'กดปุ่มไมค์เพื่อสั่งงานด้วยเสียง',
          heardText: '',
          correctionText: '',
        ),
      );
  Timer? _voiceKeepAliveTimer;
  Timer? _voiceRestartTimer;
  final NotificationService _notificationService = NotificationService();

  List<DetailedOrder> _visibleOrders = <DetailedOrder>[];
  bool _showRetryAction = false;
  bool _voiceReady = false;
  bool _voiceAvailable = false;
  bool _isListening = false;
  bool _voiceSessionEnabled = false;
  bool _isHandlingVoiceCommand = false;
  bool _voiceRestartPending = false;
  bool _voiceContinuesOnQr = false;
  bool _nativeVoiceAudioPrepared = false;
  int _voiceRecoverableErrorStreak = 0;
  DateTime? _lastVoiceStartAt;
  double _voiceAmbientLevel = 0;
  double _voicePeakLevel = 0;
  int _voiceLevelSamples = 0;
  String _voiceMessage = 'กดปุ่มไมค์เพื่อสั่งงานด้วยเสียง';
  String _lastVoiceText = '';
  String _voiceCorrectionText = '';
  List<_VoiceCommandAction> _dialogVoiceActions = <_VoiceCommandAction>[];

  bool _shouldHideUnverifiedPromptPayOrder(Map<String, dynamic> data) {
    final paymentMethod = (data['paymentMethod'] as String?)?.trim() ?? '';
    final paymentStatus = (data['paymentStatus'] as String?)?.trim() ?? '';

    return paymentMethod == 'promptpay_qr' &&
        paymentStatus.isNotEmpty &&
        paymentStatus != 'verified';
  }

  bool _isAwaitingShopDecision(DetailedOrder order) {
    if (order.orderType == 'nationwide_parcel' &&
        order.fulfillmentType == 'external_courier') {
      return order.status == 'accepted' && order.preparingStartTime == null;
    }
    return order.status == 'accepted' &&
        order.preparingStartTime == null &&
        (order.driverId?.trim().isNotEmpty ?? false);
  }

  bool _hasRiderAcceptedOrder(Map<String, dynamic> data) {
    if ((data['orderType'] as String?)?.trim() == 'nationwide_parcel' &&
        (data['fulfillmentType'] as String?)?.trim() == 'external_courier') {
      return <String>{
        'accepted',
        'preparing',
        'ready',
        'delivering',
        'delivered',
        'awaiting_shipping_booking',
      }.contains((data['status'] as String?)?.trim() ?? '');
    }
    final status = (data['status'] as String?)?.trim() ?? '';
    final driverId = (data['driverId'] as String?)?.trim() ?? '';
    return driverId.isNotEmpty &&
        <String>{
          'accepted',
          'preparing',
          'ready',
          'delivering',
        }.contains(status);
  }

  bool _hasShopRejected(Map<String, dynamic> data) {
    final shopDecisionStatus =
        (data['shopDecisionStatus'] as String?)?.trim() ?? '';
    return shopDecisionStatus == 'rejected' || data['shopRejectedAt'] != null;
  }

  bool _isShopOrderForCurrentUser(Map<String, dynamic> data) {
    final shopId = (data['shopId'] as String?)?.trim();
    final shopOwnerId = (data['shopOwnerId'] as String?)?.trim();
    return shopId == _shopId || shopOwnerId == _shopId;
  }

  @override
  void initState() {
    super.initState();
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid != null && uid.isNotEmpty) {
      _shopId = uid;
      _listenOperationsSettings(uid);
      final prefetched = _prefetchedShopOrderSnapshots[uid];
      if (prefetched != null) {
        _visibleOrders = _parseVisibleOrders(prefetched.docs);
        _ordersLoading = false;
      }
      unawaited(_startOrdersWatch(uid));
    }
  }

  @override
  void dispose() {
    _ordersSubscription?.cancel();
    _operationsSubscription?.cancel();
    _voiceKeepAliveTimer?.cancel();
    _voiceRestartTimer?.cancel();
    _ordersScrollController.dispose();
    _speech.cancel();
    _voicePanelDisplay.dispose();
    unawaited(_restoreNativeVoiceAudio());
    super.dispose();
  }

  GlobalKey _orderCardKey(String orderId) {
    return _orderCardKeys.putIfAbsent(
      orderId,
      () => GlobalKey(debugLabel: 'order-card-$orderId'),
    );
  }

  Future<void> _startOrdersWatch(String shopId) async {
    await _ordersSubscription?.cancel();
    _receivedServerOrders = false;
    _ordersWatchStartedAt = DateTime.now();
    unawaited(_showCachedOrdersWithoutBlocking(shopId));
    _ordersSubscription = _watchShopOrders(shopId).listen(
      _applyOrdersSnapshot,
      onError: (Object error) {
        if (!mounted) return;
        debugPrint('Order management Firestore error: $error');
        setState(() {
          _ordersError = error.toString();
          _ordersLoading = false;
          _showRetryAction = true;
        });
      },
    );
  }

  Future<void> _showCachedOrdersWithoutBlocking(String shopId) async {
    try {
      final snapshot = await _activeOrdersQuery(shopId)
          .get(const GetOptions(source: Source.cache))
          .timeout(const Duration(milliseconds: 700));
      if (!mounted || _receivedServerOrders || snapshot.docs.isEmpty) return;
      debugPrint(
        'Order management disk cache ${snapshot.docs.length} docs '
        'in ${DateTime.now().difference(_ordersWatchStartedAt!).inMilliseconds}ms',
      );
      _applyOrdersSnapshot(snapshot);
    } catch (_) {
      // The real-time listener is already active; cache failure never blocks it.
    }
  }

  void _applyOrdersSnapshot(
    QuerySnapshot<Map<String, dynamic>> snapshot,
  ) {
    if (!mounted) return;
    if (!snapshot.metadata.isFromCache) {
      _receivedServerOrders = true;
    }
    if (snapshot.metadata.isFromCache &&
        snapshot.docs.isEmpty &&
        _visibleOrders.isNotEmpty) {
      return;
    }
    final shopId = _shopId;
    if (shopId != null) {
      _prefetchedShopOrderSnapshots[shopId] = snapshot;
    }
    final orders = _parseVisibleOrders(snapshot.docs);
    final startedAt = _ordersWatchStartedAt;
    if (startedAt != null) {
      debugPrint(
        'Order management ${snapshot.metadata.isFromCache ? 'cache' : 'server'} '
        '${snapshot.docs.length} docs in '
        '${DateTime.now().difference(startedAt).inMilliseconds}ms',
      );
    }
    _maybeAutoAcceptAwaitingShopDecisionOrders(orders);
    setState(() {
      _visibleOrders = orders;
      _ordersLoading = false;
      _ordersError = null;
      _showRetryAction = false;
    });
  }

  List<DetailedOrder> _parseVisibleOrders(
    List<QueryDocumentSnapshot<Map<String, dynamic>>> docs,
  ) {
    final orders = docs
        .where((doc) {
          final data = doc.data();
          return _isShopOrderForCurrentUser(data) &&
              !_shouldHideUnverifiedPromptPayOrder(data) &&
              !_hasShopRejected(data) &&
              _hasRiderAcceptedOrder(data);
        })
        .map(DetailedOrder.fromSnapshot)
        .toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

    final focusOrderId = widget.focusOrderId;
    if (focusOrderId != null && focusOrderId.isNotEmpty) {
      orders.sort((a, b) {
        final aFocused = a.orderId == focusOrderId ? 1 : 0;
        final bFocused = b.orderId == focusOrderId ? 1 : 0;
        if (aFocused != bFocused) {
          return bFocused.compareTo(aFocused);
        }
        return b.createdAt.compareTo(a.createdAt);
      });
    }
    return orders;
  }

  Widget _buildOrdersBody() {
    if (_ordersError != null && _visibleOrders.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, size: 48, color: Colors.red),
            const SizedBox(height: 16),
            Text('เกิดข้อผิดพลาด: $_ordersError'),
            const SizedBox(height: 8),
            ElevatedButton(
              onPressed: () {
                final shopId = _shopId;
                if (shopId == null) return;
                setState(() {
                  _ordersLoading = true;
                  _ordersError = null;
                });
                unawaited(_startOrdersWatch(shopId));
              },
              child: const Text('ลองใหม่'),
            ),
          ],
        ),
      );
    }

    if (_ordersLoading && _visibleOrders.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_visibleOrders.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(
              Icons.inbox_outlined,
              size: 64,
              color: Colors.grey,
            ),
            const SizedBox(height: 16),
            const Text(
              'ไม่มีออเดอร์ใหม่',
              style: TextStyle(fontSize: 18),
            ),
            const SizedBox(height: 8),
            Text(
              'Shop ID: $_shopId',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
      );
    }

    final orders = _visibleOrders;
    final hasPauseBanner = _operationsSettings.pauseNewOrders;
    final itemCount = orders.length + (hasPauseBanner ? 1 : 0);

    return ListView.builder(
      controller: _ordersScrollController,
      padding: const EdgeInsets.all(16),
      itemCount: itemCount,
      itemBuilder: (context, index) {
        if (hasPauseBanner) {
          if (index == 0) {
            return _buildPauseBanner();
          }
          return RepaintBoundary(
            child: _buildOrderCard(orders[index - 1]),
          );
        }
        return RepaintBoundary(child: _buildOrderCard(orders[index]));
      },
    );
  }

  String _normalizeVoiceText(String input) {
    return input
        .toLowerCase()
        .replaceAll('คิวอาร์', 'qr')
        .replaceAll(RegExp(r'[^a-z0-9ก-๙]+'), '');
  }

  Future<void> _prepareNativeVoiceAudio() async {
    if (_nativeVoiceAudioPrepared) return;
    try {
      final result = await _voiceAudioChannel.invokeMapMethod<String, dynamic>(
        'prepare_voice_audio',
      );
      _nativeVoiceAudioPrepared = true;
      debugPrint('Voice audio prepared: $result');
    } catch (error) {
      debugPrint('Voice audio prepare failed: $error');
    }
  }

  Future<void> _restoreNativeVoiceAudio() async {
    if (!_nativeVoiceAudioPrepared) return;
    _nativeVoiceAudioPrepared = false;
    try {
      await _voiceAudioChannel.invokeMethod<void>('restore_voice_audio');
    } catch (error) {
      debugPrint('Voice audio restore failed: $error');
    }
  }

  void _setVoiceListeningUi({
    required bool listening,
    required String message,
  }) {
    if (!mounted) return;
    if (_isListening == listening && _voiceMessage == message) return;
    _isListening = listening;
    _voiceMessage = message;
    _publishVoicePanelDisplay();
  }

  void _setVoiceFeedback({
    required String message,
    String? heardText,
    String? correctionText,
  }) {
    if (!mounted) return;
    _voiceMessage = message;
    if (heardText != null) {
      _lastVoiceText = heardText;
    }
    if (correctionText != null) {
      _voiceCorrectionText = correctionText;
    }
    _publishVoicePanelDisplay();
  }

  void _publishVoicePanelDisplay() {
    _voicePanelDisplay.value = _VoicePanelDisplay(
      enabled: _voiceSessionEnabled,
      listening: _isListening,
      message: _voiceMessage,
      heardText: _lastVoiceText,
      correctionText: _voiceCorrectionText,
    );
  }

  void _startVoiceKeepAlive() {
    _voiceKeepAliveTimer?.cancel();
    _voiceKeepAliveTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      unawaited(_ensureVoiceKeepAlive());
    });
  }

  void _stopVoiceKeepAlive() {
    _voiceKeepAliveTimer?.cancel();
    _voiceKeepAliveTimer = null;
  }

  void _scheduleVoiceRestart({
    Duration delay = const Duration(milliseconds: 500),
    String? message,
  }) {
    if (!mounted || !_voiceSessionEnabled) return;
    _voiceRestartPending = true;
    _isListening = false;
    if (message != null) {
      _voiceMessage = message;
    }
    _publishVoicePanelDisplay();
    _voiceRestartTimer?.cancel();
    _voiceRestartTimer = Timer(delay, () {
      unawaited(_restartVoiceListeningIfNeeded());
    });
  }

  Future<void> _stopSpeechEngine() async {
    try {
      if (_speech.isListening) {
        await _speech.stop();
      }
    } catch (error) {
      debugPrint('Voice stop failed: $error');
    }
    try {
      await _speech.cancel();
    } catch (error) {
      debugPrint('Voice cancel failed: $error');
    }
  }

  Future<void> _ensureVoiceKeepAlive() async {
    if (!mounted || !_voiceSessionEnabled || _isHandlingVoiceCommand) return;
    final route = ModalRoute.of(context);
    if (route != null && !route.isCurrent && !_voiceContinuesOnQr) return;

    final recentlyStarted =
        _lastVoiceStartAt != null &&
        DateTime.now().difference(_lastVoiceStartAt!) <
            const Duration(seconds: 2);
    final engineListening = _speech.isListening;
    if ((engineListening && !_voiceRestartPending) || recentlyStarted) return;

    _scheduleVoiceRestart(message: 'กำลังเชื่อมไมค์ใหม่...');
  }

  Future<void> _stopVoiceSession({String? message}) async {
    if (!_voiceSessionEnabled && !_isListening) {
      return;
    }
    _voiceSessionEnabled = false;
    _voiceRestartPending = false;
    _voiceRecoverableErrorStreak = 0;
    _stopVoiceKeepAlive();
    _voiceRestartTimer?.cancel();
    await _stopSpeechEngine();
    await _restoreNativeVoiceAudio();
    if (!mounted) return;
    _isListening = false;
    _voiceMessage = message ?? 'ปิดการฟังคำสั่งเสียงแล้ว';
    _publishVoicePanelDisplay();
  }

  Future<void> _toggleVoiceSession() async {
    if (_voiceSessionEnabled || _isListening) {
      await _stopVoiceSession();
      return;
    }

    final micAllowed = await _requestMicrophonePermission();
    if (!micAllowed) return;

    if (!_voiceReady) {
      await _initVoiceCommands();
    }
    if (!_voiceAvailable) {
      if (!mounted) return;
      _setVoiceFeedback(message: 'ไม่พบระบบรับเสียงของเครื่อง');
      return;
    }

    _voiceSessionEnabled = true;
    _voiceRecoverableErrorStreak = 0;
    _startVoiceKeepAlive();
    await _prepareNativeVoiceAudio();
    await _startVoiceListening();
  }

  Future<void> _initVoiceCommands() async {
    try {
      final available = await _speech.initialize(
        onStatus: _handleSpeechStatus,
        onError: (error) {
          if (!mounted) return;
          final rawMessage = error.errorMsg.trim();
          final normalized = rawMessage.toLowerCase();
          final fatalError =
              normalized.contains('permission') ||
              normalized.contains('not allowed') ||
              normalized.contains('notavailable') ||
              normalized.contains('audiorecord') ||
              normalized.contains('denied');
          _isListening = false;
          if (!_voiceSessionEnabled) {
            _voiceRestartPending = false;
            _voiceMessage = 'ไมค์หยุดฟังแล้ว';
            _publishVoicePanelDisplay();
            unawaited(_restoreNativeVoiceAudio());
            return;
          }

          if (fatalError) {
            _voiceSessionEnabled = false;
            _voiceRestartPending = false;
            _voiceRecoverableErrorStreak = 0;
            _stopVoiceKeepAlive();
            _voiceRestartTimer?.cancel();
            _voiceMessage = 'ไมค์ยังฟังไม่ได้: $rawMessage';
            _publishVoicePanelDisplay();
            unawaited(_restoreNativeVoiceAudio());
            return;
          }

          _voiceRecoverableErrorStreak++;
          if (_voiceRecoverableErrorStreak > 3) {
            _voiceSessionEnabled = false;
            _voiceRestartPending = false;
            _voiceRecoverableErrorStreak = 0;
            _stopVoiceKeepAlive();
            _voiceRestartTimer?.cancel();
            _voiceMessage = 'ไมค์หลุดหลายครั้ง กดปุ่มไมค์เพื่อเริ่มใหม่';
            _publishVoicePanelDisplay();
            unawaited(_restoreNativeVoiceAudio());
            return;
          }
          _scheduleVoiceRestart(
            message: 'ไมค์สะดุด กำลังฟังใหม่...',
            delay: const Duration(milliseconds: 600),
          );
        },
      );
      if (!mounted) return;
      _voiceReady = true;
      _voiceAvailable = available;
      _voiceRecoverableErrorStreak = 0;
      _voiceMessage = available
          ? 'พร้อมฟังคำสั่งเสียงตามชื่อปุ่ม'
          : 'ไม่พบระบบรับเสียงของเครื่อง';
      _publishVoicePanelDisplay();
    } catch (error) {
      if (!mounted) return;
      _voiceReady = true;
      _voiceAvailable = false;
      _voiceMessage = 'เปิดระบบเสียงไม่สำเร็จ';
      _publishVoicePanelDisplay();
    }
  }

  void _handleSpeechStatus(String status) {
    if (!mounted) return;
    if (status == 'done' || status == 'notListening') {
      if (_voiceSessionEnabled && !_isHandlingVoiceCommand) {
        _scheduleVoiceRestart(
          message: 'กำลังฟังคำสั่งถัดไป...',
          delay: const Duration(milliseconds: 500),
        );
        return;
      }
      _voiceRestartPending = false;
      _isListening = false;
      _publishVoicePanelDisplay();
      if (!_voiceSessionEnabled) {
        unawaited(_restoreNativeVoiceAudio());
      }
    }
  }

  Future<void> _restartVoiceListeningIfNeeded() async {
    if (!mounted || !_voiceSessionEnabled || _isHandlingVoiceCommand) {
      _voiceRestartPending = false;
      return;
    }
    final route = ModalRoute.of(context);
    if (route != null && !route.isCurrent && !_voiceContinuesOnQr) {
      _scheduleVoiceRestart(
        message: 'รอกลับมาหน้าจัดการออเดอร์...',
        delay: const Duration(milliseconds: 700),
      );
      return;
    }
    await _startVoiceListening();
  }

  Future<void> _startVoiceListening() async {
    if (!mounted || !_voiceAvailable) {
      _voiceRestartPending = false;
      return;
    }
    if (_isListening && !_voiceRestartPending) {
      return;
    }

    _voiceRestartPending = false;
    await _prepareNativeVoiceAudio();
    _setVoiceListeningUi(
      listening: false,
      message: 'กำลังเปิดไมค์...',
    );
    _resetVoiceNoiseGate();
    await _stopSpeechEngine();
    await Future<void>.delayed(const Duration(milliseconds: 450));

    try {
      await _speech.listen(
        localeId: 'th_TH',
        listenFor: const Duration(hours: 1),
        pauseFor: const Duration(seconds: 6),
        partialResults: true,
        cancelOnError: false,
        onSoundLevelChange: _trackVoiceSoundLevel,
        listenMode: stt.ListenMode.confirmation,
        onResult: (result) {
          final words = result.recognizedWords.trim();
          if (words.isEmpty) return;
          _handleVoiceResult(words, isFinal: result.finalResult);
        },
      );
      if (!mounted || !_voiceSessionEnabled) return;
      _voiceRecoverableErrorStreak = 0;
      _lastVoiceStartAt = DateTime.now();
      _setVoiceListeningUi(
        listening: true,
        message: 'เปิดฟังตลอดเวลา รอชื่อปุ่มถัดไป',
      );
    } catch (error) {
      debugPrint('Voice listen failed: $error');
      if (!mounted) return;
      _isListening = false;
      _voiceRecoverableErrorStreak++;
      if (_voiceSessionEnabled && _voiceRecoverableErrorStreak <= 3) {
        _scheduleVoiceRestart(
          message: 'เริ่มฟังไม่สำเร็จ กำลังลองใหม่...',
          delay: const Duration(milliseconds: 650),
        );
        return;
      }
      _voiceRestartPending = false;
      _voiceSessionEnabled = false;
      _voiceRecoverableErrorStreak = 0;
      await _restoreNativeVoiceAudio();
      _voiceMessage = 'เริ่มฟังคำสั่งเสียงไม่สำเร็จ กดไมค์เพื่อเริ่มใหม่';
      _publishVoicePanelDisplay();
    }
  }

  void _resetVoiceNoiseGate() {
    _voiceAmbientLevel = 0;
    _voicePeakLevel = 0;
    _voiceLevelSamples = 0;
  }

  void _trackVoiceSoundLevel(double level) {
    if (!level.isFinite) return;
    final sanitized = level < 0 ? 0.0 : level;
    if (sanitized > _voicePeakLevel) {
      _voicePeakLevel = sanitized;
    }

    final shouldLearnAmbient =
        _voiceLevelSamples < 5 ||
        sanitized <= (_voiceAmbientLevel + (_voiceNoiseGateDelta / 2));
    if (!shouldLearnAmbient) {
      return;
    }

    if (_voiceLevelSamples == 0) {
      _voiceAmbientLevel = sanitized;
    } else {
      _voiceAmbientLevel = (_voiceAmbientLevel * 0.8) + (sanitized * 0.2);
    }
    _voiceLevelSamples++;
  }

  bool _passesVoiceNoiseGate() {
    final requiredPeak = math.max(
      _voiceNoiseGateMinimumPeak,
      _voiceAmbientLevel +
          _voiceNoiseGateDelta +
          (_voiceAmbientLevel * _voiceNoiseGateAmbientGain),
    );
    return _voicePeakLevel >= requiredPeak;
  }

  Future<bool> _requestMicrophonePermission() async {
    final status = await Permission.microphone.status;
    if (status.isGranted) return true;

    final requested = await Permission.microphone.request();
    if (requested.isGranted) return true;

    if (!mounted) return false;
    _voiceReady = false;
    _voiceAvailable = false;
    _voiceSessionEnabled = false;
    _isListening = false;
    _voiceMessage = requested.isPermanentlyDenied
        ? 'กรุณาเปิดสิทธิ์ไมค์ในตั้งค่าเครื่องก่อนใช้คำสั่งเสียง'
        : 'ต้องอนุญาตไมค์ก่อนใช้คำสั่งเสียง';
    _publishVoicePanelDisplay();
    return false;
  }

  Future<void> _scrollOrdersBy(double delta) async {
    if (!_ordersScrollController.hasClients) {
      return;
    }
    final position = _ordersScrollController.position;
    final target = (position.pixels + delta).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    await _ordersScrollController.animateTo(
      target,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOut,
    );
  }

  DetailedOrder? _currentVoiceTargetOrder() {
    if (_visibleOrders.isEmpty) {
      return null;
    }

    final topInset = MediaQuery.of(context).padding.top + kToolbarHeight + 8;
    final bottomLimit = MediaQuery.of(context).size.height - 120;
    DetailedOrder? bestOrder;
    double? bestScore;

    for (final order in _visibleOrders) {
      final contextForKey = _orderCardKeys[order.orderId]?.currentContext;
      if (contextForKey == null) continue;
      final renderObject = contextForKey.findRenderObject();
      if (renderObject is! RenderBox || !renderObject.hasSize) continue;

      final top = renderObject.localToGlobal(Offset.zero).dy;
      final bottom = top + renderObject.size.height;
      final isVisible = bottom > topInset && top < bottomLimit;
      if (!isVisible) continue;

      final score = top < topInset ? topInset - top : top - topInset;
      if (bestScore == null || score < bestScore) {
        bestScore = score;
        bestOrder = order;
      }
    }

    return bestOrder ?? _visibleOrders.first;
  }

  Future<void> _openOrderQr(DetailedOrder order) async {
    if (!mounted) return;
    _voiceContinuesOnQr = _voiceSessionEnabled;

    final navigatorFuture = Navigator.push<void>(
      context,
      MaterialPageRoute<void>(
        builder: (context) => OrderQRScreen(
          order: order,
          voiceCommandBar: _voiceSessionEnabled
              ? _buildVoiceCommandPanel()
              : null,
        ),
      ),
    );

    if (_voiceSessionEnabled) {
      await Future<void>.delayed(const Duration(milliseconds: 400));
      if (mounted && _voiceSessionEnabled) {
        _isHandlingVoiceCommand = false;
        _scheduleVoiceRestart(
          message: 'หน้า QR — พูด ย้อนกลับ เพื่อกลับหน้าออเดอร์',
        );
      }
    }

    await navigatorFuture;
    _voiceContinuesOnQr = false;
    if (!mounted) return;
    if (_voiceSessionEnabled) {
      _scheduleVoiceRestart(message: 'พร้อมฟังคำสั่ง');
    }
  }

  Future<void> _chatVisibleOrderRider() async {
    final order = _currentVoiceTargetOrder();
    if (order == null) {
      _setVoiceMessage('ไม่มีออเดอร์ที่พร้อมให้แชทไรเดอร์');
      return;
    }
    final state = await _loadRiderContactState(order);
    final hasRiderId = order.driverId?.trim().isNotEmpty ?? false;
    if (!hasRiderId || state.profile == null) {
      _setVoiceMessage('ออเดอร์นี้ยังแชทไรเดอร์ไม่ได้');
      return;
    }
    ChatWarmup.prefetchRoom(
      myUid: FirebaseAuth.instance.currentUser!.uid,
      peer: state.profile!,
    );
    unawaited(
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ChatRoomScreen(friendProfile: state.profile!),
        ),
      ),
    );
  }

  Future<void> _handleVoiceBackNavigation() async {
    if (!mounted) return;

    if (_voiceContinuesOnQr) {
      final rootNavigator = MyApp.navigatorKey.currentState;
      if (rootNavigator != null && rootNavigator.canPop()) {
        rootNavigator.pop();
        _setVoiceMessage('กลับหน้าจัดการออเดอร์แล้ว');
        return;
      }
      final navigator = Navigator.of(context);
      if (navigator.canPop()) {
        navigator.pop();
        _setVoiceMessage('กลับหน้าจัดการออเดอร์แล้ว');
      }
      return;
    }

    final navigator = Navigator.of(context);
    if (await navigator.maybePop()) {
      return;
    }

    final rootNavigator = Navigator.of(context, rootNavigator: true);
    if (!identical(rootNavigator, navigator) && await rootNavigator.maybePop()) {
      return;
    }

    if (!mounted) return;
    await Navigator.of(
      context,
    ).pushNamedAndRemoveUntil('/home', (route) => false);
  }

  Future<void> _callVisibleOrderRider() async {
    final order = _currentVoiceTargetOrder();
    if (order == null) {
      _setVoiceMessage('ไม่มีออเดอร์ที่พร้อมให้โทรไรเดอร์');
      return;
    }
    final state = await _loadRiderContactState(order);
    final canCall =
        (order.driverId?.trim().isNotEmpty ?? false) ||
        (state.phone?.trim().isNotEmpty ?? false);
    if (!canCall) {
      _setVoiceMessage('ออเดอร์นี้ยังโทรไรเดอร์ไม่ได้');
      return;
    }
    await RiderCallLauncher.startVoiceCall(
      context: context,
      riderProfile: state.profile,
      fallbackPhone: state.phone,
    );
  }

  void _setVoiceMessage(String message) {
    if (!mounted) return;
    _voiceMessage = message;
    _publishVoicePanelDisplay();
  }

  void _armRejectDialogVoiceCommands() {
    if (!mounted) return;
    setState(() {
      _dialogVoiceActions = <_VoiceCommandAction>[
        _VoiceCommandAction(
          label: 'ยกเลิก',
          phrases: const <String>['ยกเลิก'],
          onTrigger: () async {
            Navigator.of(context, rootNavigator: true).pop(false);
          },
        ),
        _VoiceCommandAction(
          label: 'ปฏิเสธ',
          phrases: const <String>['ปฏิเสธ'],
          onTrigger: () async {
            Navigator.of(context, rootNavigator: true).pop(true);
          },
        ),
      ];
    });
    _voiceMessage = 'ยืนยันการปฏิเสธ: พูด ยกเลิก หรือ ปฏิเสธ';
    _publishVoicePanelDisplay();
  }

  void _clearDialogVoiceCommands() {
    if (!mounted) return;
    setState(() {
      _dialogVoiceActions = <_VoiceCommandAction>[];
    });
    _voiceMessage = 'พร้อมฟังคำสั่งตามชื่อปุ่ม';
    _publishVoicePanelDisplay();
  }

  List<_VoiceCommandAction> _buildVoiceActions() {
    final actions = <_VoiceCommandAction>[
      ..._dialogVoiceActions,
      _VoiceCommandAction(
        label: 'ย้อนกลับ',
        phrases: const <String>[
          'ย้อนกลับ',
          'ถอยกลับ',
          'กลับหน้าก่อน',
          'กลับหน้าแรก',
          'กลับ',
          'back',
        ],
        onTrigger: _handleVoiceBackNavigation,
      ),
      _VoiceCommandAction(
        label: 'สร้างออเดอร์ทดสอบ',
        phrases: const <String>[
          'สร้างออเดอร์ทดสอบ',
          'ออเดอร์ทดสอบ',
          'สร้างเทสออเดอร์',
        ],
        onTrigger: _createTestOrder,
      ),
      _VoiceCommandAction(
        label: 'เลื่อนขึ้น',
        phrases: const <String>['เลื่อนขึ้น', 'ขึ้น', 'scrollup'],
        onTrigger: () => _scrollOrdersBy(-320),
      ),
      _VoiceCommandAction(
        label: 'เลื่อนลง',
        phrases: const <String>['เลื่อนลง', 'ลง', 'scrolldown'],
        onTrigger: () => _scrollOrdersBy(320),
      ),
    ];

    if (_showRetryAction) {
      actions.add(
        _VoiceCommandAction(
          label: 'ลองใหม่',
          phrases: const <String>['ลองใหม่'],
          onTrigger: () async {
            setState(() {});
          },
        ),
      );
    }

    actions.addAll(<_VoiceCommandAction>[
      _VoiceCommandAction(
        label: 'แชทไรเดอร์',
        phrases: const <String>['แชทไรเดอร์', 'แชท'],
        onTrigger: _chatVisibleOrderRider,
      ),
      _VoiceCommandAction(
        label: 'โทรไรเดอร์',
        phrases: const <String>['โทรไรเดอร์', 'โทรหาไรเดอร์'],
        onTrigger: _callVisibleOrderRider,
      ),
      _VoiceCommandAction(
        label: 'แสดง QR',
        phrases: const <String>['แสดงqr', 'แสดงคิวอาร์', 'แสดงqrcode'],
        onTrigger: () async {
          final order = _currentVoiceTargetOrder();
          if (order == null) {
            _setVoiceMessage('ไม่มีออเดอร์สำหรับแสดง QR');
            return;
          }
          await _openOrderQr(order);
        },
      ),
      _VoiceCommandAction(
        label: 'พิมพ์ QR',
        phrases: const <String>['พิมพ์qr', 'พิมพ์คิวอาร์'],
        onTrigger: () async {
          final order = _currentVoiceTargetOrder();
          if (order == null) {
            _setVoiceMessage('ไม่มีออเดอร์สำหรับพิมพ์ QR');
            return;
          }
          await printOrderQr(context, order);
        },
      ),
      _VoiceCommandAction(
        label: 'รับออเดอร์',
        phrases: const <String>[
          'รับออเดอร์',
          'รับออเดอร์เข้า',
          'ยืนยันออเดอร์',
          'ตกลงรับออเดอร์',
        ],
        onTrigger: () async {
          final order = _currentVoiceTargetOrder();
          if (order == null || !_isAwaitingShopDecision(order)) {
            _setVoiceMessage('ไม่พบปุ่ม รับออเดอร์ ในการ์ดที่อยู่บนจอ');
            return;
          }
          await _acceptOrder(order);
        },
      ),
      _VoiceCommandAction(
        label: 'ปฏิเสธ',
        phrases: const <String>[
          'ปฏิเสธ',
          'ปฏิเสธออเดอร์',
          'ไม่รับออเดอร์',
          'ยกเลิกออเดอร์',
        ],
        onTrigger: () async {
          final order = _currentVoiceTargetOrder();
          if (order == null || !_isAwaitingShopDecision(order)) {
            _setVoiceMessage('ไม่พบปุ่ม ปฏิเสธ ในการ์ดที่อยู่บนจอ');
            return;
          }
          await _rejectOrder(order);
        },
      ),
      _VoiceCommandAction(
        label: 'พร้อมส่ง',
        phrases: const <String>[
          'พร้อมส่ง',
          'เตรียมสินค้าเสร็จสิ้น',
          'เตรียมเสร็จ',
          'สินค้าพร้อมแล้ว',
        ],
        onTrigger: () async {
          final order = _currentVoiceTargetOrder();
          if (order == null ||
              !<String>{'accepted', 'preparing'}.contains(order.status)) {
            _setVoiceMessage('ไม่พบปุ่ม พร้อมส่ง ในการ์ดที่อยู่บนจอ');
            return;
          }
          await _markAsReady(order);
        },
      ),
    ]);

    return actions;
  }

  _VoiceCommandMatch? _findBestVoiceCommandMatch(String normalizedInput) {
    _VoiceCommandMatch? bestMatch;
    for (final action in _buildVoiceActions()) {
      final match = action.match(normalizedInput, _normalizeVoiceText);
      if (match == null) continue;
      if (bestMatch == null || match.confidence > bestMatch.confidence) {
        bestMatch = match;
      }
    }
    return bestMatch;
  }

  Future<void> _handleVoiceResult(String words, {required bool isFinal}) async {
    if (!mounted || _isHandlingVoiceCommand) return;
    final heardText = words.trim();
    if (heardText.isEmpty) return;

    final normalized = _normalizeVoiceText(heardText);
    final commandMatch = _findBestVoiceCommandMatch(normalized);
    final correctionText = commandMatch == null
        ? ''
        : 'ได้ยิน: $heardText → ประเมินเป็น: ${commandMatch.action.label} (${(commandMatch.confidence * 100).round()}%)';

    if (!isFinal) {
      if (commandMatch != null && commandMatch.shouldTrigger) {
        await _runMatchedVoiceCommand(commandMatch, heardText, correctionText);
        return;
      }
      _setVoiceFeedback(
        message: 'กำลังฟังคำพูด...',
        heardText: heardText,
        correctionText: '',
      );
      return;
    }

    if (commandMatch == null && !_passesVoiceNoiseGate()) {
      _setVoiceFeedback(
        message: 'เสียงรบกวนมากเกินไป ลองพูดใกล้ไมค์อีกครั้ง',
        heardText: heardText,
        correctionText: '',
      );
      return;
    }

    if (commandMatch == null || !commandMatch.shouldTrigger) {
      _setVoiceFeedback(
        message: commandMatch == null
            ? 'ยังไม่ตรงกับชื่อปุ่ม'
            : 'ใกล้เคียง ${commandMatch.action.label} แต่ยังไม่มั่นใจพอ',
        heardText: heardText,
        correctionText: correctionText,
      );
      return;
    }

    await _runMatchedVoiceCommand(commandMatch, heardText, correctionText);
  }

  Future<void> _runMatchedVoiceCommand(
    _VoiceCommandMatch commandMatch,
    String heardText,
    String correctionText,
  ) async {
    if (!mounted || _isHandlingVoiceCommand) return;
    final matchedAction = commandMatch.action;
    _setVoiceFeedback(
      message: commandMatch.isFuzzy
          ? 'คำเพี้ยนเล็กน้อย กำลังทำ: ${matchedAction.label}'
          : 'กำลังทำคำสั่ง: ${matchedAction.label}',
      heardText: heardText,
      correctionText: correctionText,
    );

    _isHandlingVoiceCommand = true;
    _voiceRestartPending = true;
    await _stopSpeechEngine();

    try {
      await matchedAction.onTrigger();
    } catch (error) {
      _setVoiceMessage('ทำคำสั่ง ${matchedAction.label} ไม่สำเร็จ');
      debugPrint('Voice command failed: $error');
    } finally {
      _isHandlingVoiceCommand = false;
      if (mounted && _voiceSessionEnabled) {
        _scheduleVoiceRestart(
          message: 'ทำคำสั่งแล้ว กำลังฟังต่อ...',
          delay: const Duration(milliseconds: 550),
        );
      }
    }
  }

  Widget _buildVoiceCommandPanel() {
    return SafeArea(
      top: false,
      child: ValueListenableBuilder<_VoicePanelDisplay>(
        valueListenable: _voicePanelDisplay,
        builder: (context, display, _) {
          return Container(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
            decoration: const BoxDecoration(
              color: Colors.white,
              border: Border(top: BorderSide(color: Color(0xFFE2E8F0))),
            ),
            child: Row(
              children: [
                IconButton.filledTonal(
                  onPressed: _toggleVoiceSession,
                  icon: Icon(
                    display.enabled || display.listening
                        ? Icons.mic_rounded
                        : Icons.mic_none_rounded,
                  ),
                  tooltip: display.enabled
                      ? 'หยุดฟังคำสั่งเสียง'
                      : 'เริ่มฟังคำสั่งเสียง',
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        display.message,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        display.heardText.trim().isNotEmpty
                            ? 'คำที่พูด: ${display.heardText.trim()}'
                            : 'เปิดไว้ได้ตลอด พูดชื่อปุ่ม เช่น รับออเดอร์, ปฏิเสธ, แสดง QR, เลื่อนลง',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12,
                          color: Color(0xFF64748B),
                        ),
                      ),
                      if (display.correctionText.trim().isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          display.correctionText.trim(),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 12,
                            color: AppColors.accent,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Stream<QuerySnapshot<Map<String, dynamic>>> _watchShopOrders(String shopId) async* {
    try {
      await for (final snapshot in _activeOrdersQuery(shopId).snapshots()) {
        yield snapshot;
      }
    } on FirebaseException catch (error) {
      if (error.code != 'failed-precondition') {
        rethrow;
      }
      debugPrint(
        'Active orders index missing, falling back to shopOwnerId query: $error',
      );
      await for (final snapshot in _legacyOrdersQuery(shopId).snapshots()) {
        yield snapshot;
      }
    }
  }

  Query<Map<String, dynamic>> _activeOrdersQuery(String shopId) {
    return FirebaseFirestore.instance
        .collection('orders')
        .where('shopOwnerId', isEqualTo: shopId)
        .where('status', whereIn: _activeOrderStatuses)
        .orderBy('createdAt', descending: true)
        .limit(_activeOrdersLimit);
  }

  Query<Map<String, dynamic>> _legacyOrdersQuery(String shopId) {
    return FirebaseFirestore.instance
        .collection('orders')
        .where('shopOwnerId', isEqualTo: shopId)
        .limit(_activeOrdersLimit);
  }

  void _listenOperationsSettings(String shopId) {
    _operationsSubscription?.cancel();
    _operationsSubscription = ShopOperationsService.streamSettings(shopId)
        .listen((settings) {
          if (!mounted) return;
          setState(() => _operationsSettings = settings);
        });
  }

  Future<void> _createTestOrder() async {
    try {
      final orderId = await createTestOrder();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '✅ สร้างออเดอร์ทดสอบสำเร็จ: ${orderId.substring(0, 8)}...',
            ),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('❌ เกิดข้อผิดพลาด: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_shopId == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          onPressed: () {
            Navigator.of(
              context,
            ).pushNamedAndRemoveUntil('/home', (route) => false);
          },
          icon: const Icon(Icons.arrow_back),
          tooltip: 'กลับหน้าแรก',
        ),
        title: const Text('จัดการออเดอร์'),
        backgroundColor: AppColors.accent,
        foregroundColor: Colors.white,
      ),
      backgroundColor: Colors.white,
      bottomNavigationBar: _buildVoiceCommandPanel(),
      body: _buildOrdersBody(),
    );
  }

  Widget _buildOrderCard(DetailedOrder order) {
    final isFocused =
        widget.focusOrderId != null && widget.focusOrderId == order.orderId;
    return Card(
      key: _orderCardKey(order.orderId),
      margin: const EdgeInsets.only(bottom: 16),
      elevation: 3,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: isFocused
            ? const BorderSide(color: AppColors.accent, width: 2)
            : BorderSide.none,
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildOrderHeader(order),
            const Divider(height: 24),
            _buildOrderItems(order),
            const SizedBox(height: 16),
            _buildAmountSummary(order),
            const SizedBox(height: 16),
            _buildOrderStatus(order),
            if (order.status == 'accepted' || order.status == 'preparing')
              _buildPreparingTimer(order),
            const SizedBox(height: 12),
            _buildOrderContactActions(order),
            const SizedBox(height: 12),
            _buildQrActions(order),
            const SizedBox(height: 16),
            _buildActionButtons(order),
          ],
        ),
      ),
    );
  }

  Widget _buildPauseBanner() {
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.orange.shade50,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.orange.shade200),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.pause_circle_filled, color: Colors.orange, size: 28),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: const [
                Text(
                  'ร้านหยุดรับออเดอร์อยู่',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                SizedBox(height: 4),
                Text(
                  'เปิดรับออเดอร์อีกครั้งได้ที่เมนูตั้งค่า > การดำเนินงานร้าน',
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _maybeAutoAcceptAwaitingShopDecisionOrders(List<DetailedOrder> orders) {
    if (!_operationsSettings.autoAcceptOrders ||
        _operationsSettings.pauseNewOrders) {
      return;
    }
    for (final order in orders) {
      if (!_isAwaitingShopDecision(order) ||
          _autoAcceptingOrders.contains(order.orderId)) {
        continue;
      }
      _autoAcceptingOrders.add(order.orderId);
      _acceptOrder(order, silent: true)
          .then((_) {
            if (!mounted) return;
            final shortId = order.orderId.length > 6
                ? order.orderId.substring(0, 6)
                : order.orderId;
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('รับออเดอร์ #$shortId อัตโนมัติแล้ว'),
                duration: const Duration(seconds: 2),
                behavior: SnackBarBehavior.floating,
              ),
            );
          })
          .catchError((error) {
            debugPrint('Auto accept failed for ${order.orderId}: $error');
          })
          .whenComplete(() => _autoAcceptingOrders.remove(order.orderId));
    }
  }

  Widget _buildOrderHeader(DetailedOrder order) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'ออเดอร์ #${order.orderId.substring(0, 8)}',
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                order.customerName,
                style: TextStyle(fontSize: 14, color: Colors.grey[700]),
              ),
              Text(
                order.customerPhone,
                style: TextStyle(fontSize: 13, color: Colors.grey[600]),
              ),
            ],
          ),
        ),
        Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              '฿${order.totalAmount.toStringAsFixed(2)}',
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: AppColors.accent,
              ),
            ),
            Text(
              _formatTime(order.createdAt),
              style: TextStyle(fontSize: 12, color: Colors.grey[600]),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildOrderItems(DetailedOrder order) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'รายการสินค้า:',
          style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        ...order.items.map(
          (item) => Container(
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: const Color(0xFFF8FAFC),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xFFE2E8F0)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _OrderItemImage(imageUrl: item.imageUrl),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item.productName.isNotEmpty ? item.productName : '-',
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      if (item.toppings?.trim().isNotEmpty == true) ...[
                        const SizedBox(height: 3),
                        Text(
                          'ท็อปปิ้ง: ${item.toppings!.trim()}',
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.grey[600],
                          ),
                        ),
                      ],
                      if (_orderItemVariantLabel(item).isNotEmpty) ...[
                        const SizedBox(height: 3),
                        Text(
                          _orderItemVariantLabel(item),
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.grey[600],
                          ),
                        ),
                      ],
                      const SizedBox(height: 3),
                      Text(
                        'ราคาต่อชิ้น ฿${item.price.toStringAsFixed(2)}',
                        style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      'x${item.quantity}',
                      style: const TextStyle(fontSize: 14),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '฿${(item.price * item.quantity).toStringAsFixed(2)}',
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildAmountSummary(DetailedOrder order) {
    final productSubtotal = _productSubtotal(order);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFFFFBEB),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFFDE68A)),
      ),
      child: Column(
        children: [
          _AmountRow(label: 'ค่าสินค้า', value: productSubtotal),
          const SizedBox(height: 6),
          _AmountRow(label: 'ค่าส่ง', value: order.shippingFee),
          const Divider(height: 18),
          _AmountRow(label: 'ยอดรวม', value: order.totalAmount, isTotal: true),
        ],
      ),
    );
  }

  double _productSubtotal(DetailedOrder order) {
    final itemTotal = order.items.fold<double>(
      0,
      (runningTotal, item) => runningTotal + (item.price * item.quantity),
    );
    if (itemTotal > 0) return itemTotal;
    final fromGrandTotal = order.totalAmount - order.shippingFee;
    return fromGrandTotal > 0 ? fromGrandTotal : order.totalAmount;
  }

  Widget _buildOrderStatus(DetailedOrder order) {
    Color statusColor;
    String statusText;

    switch (order.status) {
      case 'pending':
        statusColor = Colors.orange;
        statusText = 'รออนุมัติ';
        break;
      case 'accepted':
        if (order.preparingStartTime == null) {
          statusColor = Colors.orange;
          statusText = 'ไรเดอร์รับงานแล้ว รอร้านยืนยัน';
        } else {
          statusColor = Colors.green;
          statusText = 'รับออเดอร์แล้ว';
        }
        break;
      case 'preparing':
        statusColor = Colors.blue;
        statusText = 'กำลังเตรียม';
        break;
      case 'ready':
        statusColor = Colors.purple;
        statusText = 'พร้อมส่ง';
        break;
      case 'delivering':
        statusColor = Colors.indigo;
        statusText = 'กำลังจัดส่ง';
        break;
      default:
        statusColor = Colors.grey;
        statusText = order.status;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: statusColor.withOpacity(0.1),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: statusColor, width: 1.5),
      ),
      child: Text(
        statusText,
        style: TextStyle(
          color: statusColor,
          fontSize: 14,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  Widget _buildPreparingTimer(DetailedOrder order) {
    if (order.preparingStartTime == null) return const SizedBox.shrink();

    // ใช้ StatefulBuilder เพื่อ rebuild เฉพาะ widget นี้
    return _CountdownTimerWidget(order: order);
  }
}

/// Widget แยกสำหรับ Timer เพื่อไม่ให้ rebuild ทั้งหน้า
class _CountdownTimerWidget extends StatefulWidget {
  final DetailedOrder order;

  const _CountdownTimerWidget({required this.order});

  @override
  State<_CountdownTimerWidget> createState() => _CountdownTimerWidgetState();
}

class _CountdownTimerWidgetState extends State<_CountdownTimerWidget> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    // Timer เฉพาะ widget นี้
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.order.preparingStartTime == null) {
      return const SizedBox.shrink();
    }

    final now = DateTime.now();
    final elapsed = now.difference(widget.order.preparingStartTime!);
    final remaining =
        Duration(milliseconds: widget.order.preparingDuration) - elapsed;

    if (remaining.isNegative) {
      final overtime =
          elapsed - Duration(milliseconds: widget.order.preparingDuration);
      return Container(
        margin: const EdgeInsets.only(top: 12),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.red[50],
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.red, width: 1.5),
        ),
        child: Row(
          children: [
            const Icon(Icons.warning, color: Colors.red, size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'เกินเวลา ${_formatDuration(overtime)} (ค่าปรับ: ฿${widget.order.penalty.toStringAsFixed(2)})',
                style: const TextStyle(
                  color: Colors.red,
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ),
      );
    }

    Color timerColor = Colors.green;
    if (remaining.inMinutes < 3) {
      timerColor = Colors.red;
    } else if (remaining.inMinutes < 5) {
      timerColor = Colors.orange;
    }

    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: timerColor.withOpacity(0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: timerColor, width: 1.5),
      ),
      child: Row(
        children: [
          Icon(Icons.timer, color: timerColor, size: 20),
          const SizedBox(width: 8),
          Text(
            'เหลือเวลา: ${_formatDuration(remaining)}',
            style: TextStyle(
              color: timerColor,
              fontSize: 14,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }

  String _formatDuration(Duration duration) {
    final minutes = duration.inMinutes;
    final seconds = duration.inSeconds % 60;
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }
}

class _OrderItemImage extends StatelessWidget {
  const _OrderItemImage({required this.imageUrl});

  final String? imageUrl;

  @override
  Widget build(BuildContext context) {
    final url = imageUrl?.trim();
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Container(
        width: 58,
        height: 58,
        color: const Color(0xFFE2E8F0),
        child: url == null || url.isEmpty
            ? const Icon(Icons.fastfood_outlined, color: Color(0xFF94A3B8))
            : Image.network(
                url,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => const Icon(
                  Icons.fastfood_outlined,
                  color: Color(0xFF94A3B8),
                ),
              ),
      ),
    );
  }
}

class _AmountRow extends StatelessWidget {
  const _AmountRow({
    required this.label,
    required this.value,
    this.isTotal = false,
  });

  final String label;
  final double value;
  final bool isTotal;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: TextStyle(
              fontSize: isTotal ? 15 : 14,
              fontWeight: isTotal ? FontWeight.w800 : FontWeight.w600,
              color: isTotal ? Colors.black : const Color(0xFF92400E),
            ),
          ),
        ),
        Text(
          '฿${value.toStringAsFixed(2)}',
          style: TextStyle(
            fontSize: isTotal ? 16 : 14,
            fontWeight: FontWeight.w800,
            color: isTotal ? AppColors.accent : const Color(0xFF92400E),
          ),
        ),
      ],
    );
  }
}

// ย้าย _buildActionButtons กลับไปที่ _OrderManagementScreenState
extension on _OrderManagementScreenState {
  Future<_RiderContactState> _loadRiderContactState(DetailedOrder order) {
    final riderId = order.driverId?.trim();
    if (riderId == null || riderId.isEmpty) {
      return Future<_RiderContactState>.value(
        const _RiderContactState(profile: null, phone: null),
      );
    }
    return _riderContactFutures.putIfAbsent(
      riderId,
      () => _fetchRiderContactState(order),
    );
  }

  Future<_RiderContactState> _fetchRiderContactState(DetailedOrder order) async {
    final riderId = order.driverId!.trim();
    final embeddedName = order.driverName?.trim();
    final embeddedPhone = order.driverPhone?.trim();
    if (embeddedName != null &&
        embeddedName.isNotEmpty &&
        embeddedPhone != null &&
        embeddedPhone.isNotEmpty) {
      return _RiderContactState(
        profile: UserProfile(
          uid: riderId,
          displayName: embeddedName,
          phoneNumber: embeddedPhone,
        ),
        phone: embeddedPhone,
      );
    }

    UserProfile? profile;
    Map<String, dynamic>? riderData;
    try {
      final riderDoc = await FirebaseFirestore.instance
          .collection('riders')
          .doc(riderId)
          .get();
      if (riderDoc.exists) {
        riderData = riderDoc.data();
        profile = UserProfile.fromMap(riderId, riderData);
      }
    } catch (_) {
      // Fallback profile is used when riders lookup fails.
    }

    profile ??= UserProfile(
      uid: riderId,
      displayName: (order.driverName?.trim().isNotEmpty ?? false)
          ? order.driverName!.trim()
          : 'ไรเดอร์',
      phoneNumber: order.driverPhone,
    );

    final phoneCandidates = <String?>[
      profile.phoneNumber,
      order.driverPhone,
      riderData?['phoneNumber'] as String?,
      riderData?['phone'] as String?,
      riderData?['contactPhone'] as String?,
      riderData?['mobile'] as String?,
    ];

    String? resolvedPhone;
    for (final candidate in phoneCandidates) {
      final text = candidate?.trim();
      if (text != null && text.isNotEmpty) {
        resolvedPhone = text;
        break;
      }
    }

    return _RiderContactState(profile: profile, phone: resolvedPhone);
  }

  Widget _buildOrderContactActions(DetailedOrder order) {
    return FutureBuilder<_RiderContactState>(
      future: _loadRiderContactState(order),
      builder: (context, snapshot) {
        final state = snapshot.data;
        final hasRider = order.driverId?.trim().isNotEmpty ?? false;
        final canChat = hasRider && state?.profile != null;
        final canCall = hasRider || (state?.phone?.trim().isNotEmpty ?? false);
        final riderName = state?.profile?.displayName.trim().isNotEmpty == true
            ? state!.profile!.displayName.trim()
            : (order.driverName?.trim().isNotEmpty == true
                  ? order.driverName!.trim()
                  : 'ไรเดอร์');
        final riderPhone = state?.phone?.trim().isNotEmpty == true
            ? state!.phone!.trim()
            : (order.driverPhone?.trim().isNotEmpty == true
                  ? order.driverPhone!.trim()
                  : '-');

        return Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: const Color(0xFFF0FDF4),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: const Color(0xFFBBF7D0)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(
                    Icons.delivery_dining_rounded,
                    color: Colors.green,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'รายละเอียดไรเดอร์',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text('ชื่อ: $riderName'),
                        Text('เบอร์โทร: $riderPhone'),
                        if (order.driverId?.trim().isNotEmpty == true)
                          Text(
                            'รหัสไรเดอร์: ${order.driverId!.trim()}',
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.grey[600],
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: !canChat
                          ? null
                          : () async {
                              ChatWarmup.prefetchRoom(
                                myUid: FirebaseAuth.instance.currentUser!.uid,
                                peer: state!.profile!,
                              );
                              await Navigator.of(context).push(
                                MaterialPageRoute<void>(
                                  builder: (_) => ChatRoomScreen(
                                    friendProfile: state.profile!,
                                  ),
                                ),
                              );
                            },
                      icon: const Icon(Icons.chat_bubble_outline_rounded),
                      label: const Text('แชทไรเดอร์'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: !canCall
                          ? null
                          : () => RiderCallLauncher.startVoiceCall(
                              context: context,
                              riderProfile: state?.profile,
                              fallbackPhone: state?.phone,
                            ),
                      icon: const Icon(Icons.phone_in_talk_outlined),
                      label: Text(canCall ? 'โทรไรเดอร์' : 'โทรไรเดอร์ไม่ได้'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildQrActions(DetailedOrder order) {
    return Row(
      children: [
        Expanded(
          child: OutlinedButton.icon(
            onPressed: () => unawaited(_openOrderQr(order)),
            icon: const Icon(Icons.qr_code_2_rounded),
            label: const Text('แสดง QR'),
            style: OutlinedButton.styleFrom(
              foregroundColor: AppColors.accent,
              side: const BorderSide(color: AppColors.accent),
              minimumSize: const Size(double.infinity, 46),
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: FilledButton.icon(
            onPressed: () => printOrderQr(context, order),
            icon: const Icon(Icons.print_outlined),
            label: const Text('พิมพ์ QR'),
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.accent,
              foregroundColor: Colors.white,
              minimumSize: const Size(double.infinity, 46),
            ),
          ),
        ),
      ],
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

    await FirebaseFirestore.instance.collection('app_notifications').add({
      'targetApp': targetApp,
      'recipientUid': toUid,
      'orderId': orderId,
      'title': title,
      'body': body,
      'read': false,
      'createdAt': FieldValue.serverTimestamp(),
      'source': 'van1_shop',
      'action': action,
    });
  }

  int _readProductStock(dynamic value) {
    if (value is num) {
      return value.toInt();
    }
    if (value is String) {
      return int.tryParse(value.trim()) ?? 0;
    }
    return 0;
  }

  Future<List<String>> _markOrderReadyAndDeductStock(DetailedOrder order) {
    return FirebaseFirestore.instance.runTransaction<List<String>>((
      transaction,
    ) async {
      final orderRef = FirebaseFirestore.instance
          .collection('orders')
          .doc(order.orderId);
      final orderSnapshot = await transaction.get(orderRef);
      final orderData = orderSnapshot.data();
      final currentStatus = orderData?['status']?.toString() ?? '';
      if (!<String>{'accepted', 'preparing'}.contains(currentStatus)) {
        throw StateError('order-not-ready-transition');
      }

      final Map<String, int> mergedQuantities = <String, int>{};
      final Map<String, String> productNames = <String, String>{};
      for (final item in order.items) {
        final productId = item.productId.trim();
        if (productId.isEmpty) continue;
        mergedQuantities.update(
          productId,
          (value) => value + item.quantity,
          ifAbsent: () => item.quantity,
        );
        productNames.putIfAbsent(productId, () => item.productName.trim());
      }

      final productRefs = <String, DocumentReference<Map<String, dynamic>>>{};
      final productSnapshots =
          <String, DocumentSnapshot<Map<String, dynamic>>>{};
      for (final productId in mergedQuantities.keys) {
        final productRef = FirebaseFirestore.instance
            .collection('products')
            .doc(productId);
        productRefs[productId] = productRef;
        productSnapshots[productId] = await transaction.get(productRef);
      }

      final List<String> lowStockAlerts = <String>[];
      final stockUpdates = <String, int>{};
      for (final entry in mergedQuantities.entries) {
        final productSnapshot = productSnapshots[entry.key];
        if (productSnapshot == null || !productSnapshot.exists) {
          continue;
        }
        final data = productSnapshot.data();
        final currentStock = _readProductStock(data?['stock']);
        final remainingStock = math.max(0, currentStock - entry.value);
        stockUpdates[entry.key] = remainingStock;
        if (_operationsSettings.notifyLowStock &&
            remainingStock < _OrderManagementScreenState._lowStockThreshold) {
          final name = (data?['name']?.toString().trim().isNotEmpty ?? false)
              ? data!['name'].toString().trim()
              : (productNames[entry.key]?.isNotEmpty ?? false)
              ? productNames[entry.key]!
              : entry.key;
          lowStockAlerts.add('$name เหลือ $remainingStock ชิ้น');
        }
      }

      final now = DateTime.now();
      transaction.update(orderRef, {
        'status': 'ready',
        'readyAt': Timestamp.fromDate(now),
        'updatedAt': Timestamp.now(),
      });

      for (final entry in stockUpdates.entries) {
        transaction.update(productRefs[entry.key]!, {
          'stock': entry.value,
          'updatedAt': FieldValue.serverTimestamp(),
        });
      }

      return lowStockAlerts;
    });
  }

  Widget _buildActionButtons(DetailedOrder order) {
    if (_isAwaitingShopDecision(order)) {
      return Row(
        children: [
          Expanded(
            child: ElevatedButton.icon(
              onPressed: () => _acceptOrder(order),
              icon: const Icon(Icons.check_circle),
              label: const Text('รับออเดอร์'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.green,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: OutlinedButton.icon(
              onPressed: () => _rejectOrder(order),
              icon: const Icon(Icons.cancel),
              label: const Text('ปฏิเสธ'),
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.red,
                side: const BorderSide(color: Colors.red),
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
            ),
          ),
        ],
      );
    }

    switch (order.status) {
      case 'accepted':
      case 'preparing':
        return ElevatedButton.icon(
          onPressed: () => _markAsReady(order),
          icon: const Icon(Icons.done_all),
          label: const Text('พร้อมส่ง'),
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.accent,
            foregroundColor: Colors.white,
            minimumSize: const Size(double.infinity, 48),
          ),
        );
      case 'ready':
        return Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: Colors.green.shade50,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: Colors.green.shade200),
          ),
          child: const Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.check_circle, color: Colors.green, size: 20),
              SizedBox(width: 8),
              Flexible(
                child: Text(
                  'พร้อมส่งแล้ว · รอไรเดอร์สแกน QR รับสินค้า',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 14,
                    color: Colors.green,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        );
      case 'delivering':
        return const Text(
          'กำลังจัดส่งสินค้า',
          style: TextStyle(
            fontSize: 14,
            color: Colors.blue,
            fontStyle: FontStyle.italic,
          ),
          textAlign: TextAlign.center,
        );
      default:
        return const SizedBox.shrink();
    }
  }

  Future<void> _acceptOrder(DetailedOrder order, {bool silent = false}) async {
    final blockMessage = ShopOperationsService.penaltyBlockMessage(_operationsSettings);
    if (blockMessage != null) {
      if (!silent && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(blockMessage), backgroundColor: Colors.orange),
        );
      }
      return;
    }

    try {
      final now = DateTime.now();
      final preparationMinutes = (order.preparingDuration / 60000)
          .ceil()
          .clamp(1, 240)
          .toDouble();
      final updatedOrder = order.copyWith(
        status: 'preparing',
        acceptedAt: now,
        preparingStartTime: now,
        notifications: {
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
          .update({
            ...updatedOrder.toMap(),
            'shopDecisionStatus': 'accepted',
            'shopAcceptedAt': Timestamp.fromDate(now),
            if (order.orderType == 'nationwide_parcel') ...{
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
            'ออเดอร์ #${order.orderId.substring(0, 8)} ร้านเริ่มเตรียมสินค้าแล้ว',
        action: 'shop_accepted_order',
      );

      if (!silent && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'รับออเดอร์เรียบร้อยแล้ว! เริ่มจับเวลาตามเวลาที่ตั้งไว้',
            ),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('เกิดข้อผิดพลาด: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _rejectOrder(DetailedOrder order) async {
    _armRejectDialogVoiceCommands();

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('ยืนยันการปฏิเสธออเดอร์'),
        content: const Text('คุณแน่ใจหรือไม่ว่าต้องการปฏิเสธออเดอร์นี้?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('ยกเลิก'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('ปฏิเสธ'),
          ),
        ],
      ),
    );

    _clearDialogVoiceCommands();

    if (confirmed == true) {
      try {
        await FirebaseFirestore.instance
            .collection('orders')
            .doc(order.orderId)
            .update({
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
              'ออเดอร์ #${order.orderId.substring(0, 8)} รอลูกค้าเลือกรอหรือแคนเซิล',
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

        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('ปฏิเสธออเดอร์แล้ว')));
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('เกิดข้อผิดพลาด: $e'),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    }
  }

  Future<void> _markAsReady(DetailedOrder order) async {
    try {
      final lowStockAlerts = await _markOrderReadyAndDeductStock(order);

      if (lowStockAlerts.isNotEmpty) {
        unawaited(
          _notificationService
              .createInboxNotification(
                title: 'เตือนสต๊อกใกล้หมด',
                body: lowStockAlerts.join(', '),
                orderId: order.orderId,
                action: 'low_stock_alert',
              )
              .catchError((Object error, StackTrace stackTrace) {
                debugPrint(
                  'Low-stock inbox notification failed for order '
                  '${order.orderId}: $error',
                );
              }),
        );
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('เตรียมสินค้าเสร็จสิ้น! รอพนักงานขนส่งมารับ'),
            backgroundColor: Colors.green,
          ),
        );
        if (lowStockAlerts.isNotEmpty) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('เตือนสต๊อกใกล้หมด: ${lowStockAlerts.join(', ')}'),
              backgroundColor: Colors.orange,
              duration: const Duration(seconds: 5),
            ),
          );
        }
      }

      try {
        await _sendOrderAppNotification(
          targetApp: 'van3',
          recipientUid: order.driverId,
          orderId: order.orderId,
          title: 'ร้านเตรียมสินค้าเสร็จแล้ว',
          body:
              'ออเดอร์ #${order.orderId.substring(0, 8)} พร้อมให้ไรเดอร์รับสินค้า',
          action: 'shop_ready_for_pickup',
        );
      } catch (notificationError) {
        debugPrint(
          'Ready notification failed for order ${order.orderId}: $notificationError',
        );
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'เปลี่ยนสถานะออเดอร์แล้ว แต่ยังส่งแจ้งเตือนไปไรเดอร์ไม่สำเร็จ',
              ),
              backgroundColor: Colors.orange,
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('เกิดข้อผิดพลาด: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  String _formatTime(DateTime dateTime) {
    return '${dateTime.hour.toString().padLeft(2, '0')}:${dateTime.minute.toString().padLeft(2, '0')}';
  }
}

class _VoiceCommandAction {
  const _VoiceCommandAction({
    required this.label,
    required this.phrases,
    required this.onTrigger,
  });

  final String label;
  final List<String> phrases;
  final Future<void> Function() onTrigger;

  _VoiceCommandMatch? match(
    String normalizedInput,
    String Function(String) normalize,
  ) {
    if (normalizedInput.isEmpty) return null;

    _VoiceCommandMatch? bestMatch;
    for (final phrase in phrases) {
      final normalizedPhrase = normalize(phrase);
      if (normalizedPhrase.isEmpty) continue;

      final exact = normalizedInput.contains(normalizedPhrase);
      final confidence = exact
          ? 1.0
          : _voiceSimilarity(normalizedInput, normalizedPhrase);
      final candidate = _VoiceCommandMatch(
        action: this,
        phrase: phrase,
        confidence: confidence,
        isFuzzy: !exact,
      );
      if (bestMatch == null || candidate.confidence > bestMatch.confidence) {
        bestMatch = candidate;
      }
    }
    if (bestMatch == null || bestMatch.confidence < 0.45) return null;
    return bestMatch;
  }
}

class _VoicePanelDisplay {
  const _VoicePanelDisplay({
    required this.enabled,
    required this.listening,
    required this.message,
    required this.heardText,
    required this.correctionText,
  });

  final bool enabled;
  final bool listening;
  final String message;
  final String heardText;
  final String correctionText;
}

class _VoiceCommandMatch {
  const _VoiceCommandMatch({
    required this.action,
    required this.phrase,
    required this.confidence,
    required this.isFuzzy,
  });

  final _VoiceCommandAction action;
  final String phrase;
  final double confidence;
  final bool isFuzzy;

  bool get shouldTrigger {
    final normalizedPhraseLength = phrase.replaceAll(RegExp(r'\s+'), '').length;
    final threshold = normalizedPhraseLength <= 4 ? 0.78 : 0.68;
    return confidence >= threshold;
  }
}

double _voiceSimilarity(String input, String phrase) {
  if (input == phrase) return 1;
  if (input.contains(phrase) || phrase.contains(input)) {
    final shorter = math.min(input.length, phrase.length);
    final longer = math.max(input.length, phrase.length);
    if (longer == 0) return 0;
    return shorter / longer;
  }

  final windowScore = input.length > phrase.length
      ? _bestWindowSimilarity(input, phrase)
      : 0.0;
  final directDistance = _levenshteinDistance(input, phrase);
  final directMax = math.max(input.length, phrase.length);
  final directScore = directMax == 0 ? 0.0 : 1 - (directDistance / directMax);
  return math.max(windowScore, directScore).clamp(0.0, 1.0);
}

double _bestWindowSimilarity(String input, String phrase) {
  if (phrase.isEmpty || input.length < phrase.length) return 0;
  var bestScore = 0.0;
  final minWindow = math.max(1, phrase.length - 2);
  final maxWindow = math.min(input.length, phrase.length + 2);
  for (
    var windowLength = minWindow;
    windowLength <= maxWindow;
    windowLength++
  ) {
    for (var start = 0; start <= input.length - windowLength; start++) {
      final window = input.substring(start, start + windowLength);
      final distance = _levenshteinDistance(window, phrase);
      final maxLength = math.max(window.length, phrase.length);
      final score = maxLength == 0 ? 0.0 : 1 - (distance / maxLength);
      if (score > bestScore) bestScore = score;
    }
  }
  return bestScore;
}

int _levenshteinDistance(String a, String b) {
  if (a == b) return 0;
  if (a.isEmpty) return b.length;
  if (b.isEmpty) return a.length;

  var previous = List<int>.generate(b.length + 1, (index) => index);
  for (var i = 0; i < a.length; i++) {
    final current = List<int>.filled(b.length + 1, 0);
    current[0] = i + 1;
    for (var j = 0; j < b.length; j++) {
      final insertion = current[j] + 1;
      final deletion = previous[j + 1] + 1;
      final substitution = previous[j] + (a[i] == b[j] ? 0 : 1);
      current[j + 1] = math.min(insertion, math.min(deletion, substitution));
    }
    previous = current;
  }
  return previous[b.length];
}

class _RiderContactState {
  const _RiderContactState({required this.profile, required this.phone});

  final UserProfile? profile;
  final String? phone;
}
