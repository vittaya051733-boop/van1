import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

import 'chat_room_screen.dart';
import 'models/order_model.dart';
import 'models/user_profile.dart';
import 'services/shop_order_credit_gate.dart';
import 'services/shop_order_voice_commands.dart';
import 'utils/app_colors.dart';
import 'utils/rider_call_launcher.dart';

class IncomingShopOrderScreen extends StatefulWidget {
  const IncomingShopOrderScreen({
    super.key,
    required this.order,
    required this.onAccept,
    required this.onReject,
    this.autoStartVoiceListening = true,
    this.title,
    this.message,
  });

  final DetailedOrder order;
  final Future<void> Function() onAccept;
  final Future<void> Function() onReject;
  final bool autoStartVoiceListening;
  final String? title;
  final String? message;

  @override
  State<IncomingShopOrderScreen> createState() =>
      _IncomingShopOrderScreenState();
}

class _IncomingShopOrderScreenState extends State<IncomingShopOrderScreen>
    with WidgetsBindingObserver {
  static const MethodChannel _voiceAudioChannel = MethodChannel(
    'van.merchant/voice_audio',
  );
  static const double _voiceNoiseGateDelta = 3.5;
  static const double _voiceNoiseGateMinimumPeak = 5.5;
  static const double _voiceNoiseGateAmbientGain = 0.12;

  final stt.SpeechToText _speech = stt.SpeechToText();
  bool _isSubmitting = false;
  bool _voiceAvailable = false;
  bool _voiceReady = false;
  bool _voiceSessionEnabled = false;
  bool _isListening = false;
  bool _hasAutoStartedVoice = false;
  bool _nativeVoiceAudioPrepared = false;
  bool _voiceRestartPending = false;
  bool _isHandlingVoiceCommand = false;
  Timer? _voiceRestartTimer;
  double _voiceAmbientLevel = 0;
  double _voicePeakLevel = 0;
  int _voiceLevelSamples = 0;
  String _lastVoiceText = '';
  String? _voiceMessage;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _voiceMessage = 'กดปุ่มไมค์เพื่อใช้คำสั่งเสียง';
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Future<void>.microtask(_maybeAutoStartVoiceListening);
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _voiceRestartTimer?.cancel();
    _voiceSessionEnabled = false;
    unawaited(_stopSpeechEngine());
    unawaited(_restoreNativeVoiceAudio());
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      Future<void>.microtask(_maybeAutoStartVoiceListening);
    } else {
      _hasAutoStartedVoice = false;
    }
  }

  Future<void> _initVoiceCommands() async {
    try {
      final available = await _speech.initialize(
        onStatus: _handleSpeechStatus,
        onError: (error) {
          if (!mounted) return;
          setState(() {
            _isListening = false;
            _voiceMessage = 'ไมค์ยังฟังไม่ได้: ${error.errorMsg}';
          });
        },
      );
      if (!mounted) return;
      setState(() {
        _voiceAvailable = available;
        _voiceReady = true;
        _voiceMessage = available ? 'พร้อมรับคำสั่งเสียง' : 'ไม่พบระบบรับเสียง';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _voiceReady = true;
        _voiceAvailable = false;
        _voiceMessage = 'เปิดระบบเสียงไม่สำเร็จ';
      });
    }
  }

  void _handleSpeechStatus(String status) {
    if (!mounted) return;
    if (status == 'done' || status == 'notListening') {
      setState(() => _isListening = false);
      if (_voiceSessionEnabled &&
          !_isSubmitting &&
          !_isHandlingVoiceCommand &&
          !_voiceRestartPending) {
        _scheduleVoiceRestart(
          message: 'กำลังฟังต่อ...',
          delay: const Duration(milliseconds: 450),
        );
      }
    }
  }

  Future<void> _prepareNativeVoiceAudio() async {
    if (_nativeVoiceAudioPrepared) return;
    try {
      await _voiceAudioChannel.invokeMapMethod<String, dynamic>(
        'prepare_voice_audio',
      );
      _nativeVoiceAudioPrepared = true;
    } catch (error) {
      debugPrint('[incoming-order-voice] prepare failed: $error');
    }
  }

  Future<void> _restoreNativeVoiceAudio() async {
    if (!_nativeVoiceAudioPrepared) return;
    _nativeVoiceAudioPrepared = false;
    try {
      await _voiceAudioChannel.invokeMethod<void>('restore_voice_audio');
    } catch (error) {
      debugPrint('[incoming-order-voice] restore failed: $error');
    }
  }

  Future<void> _stopSpeechEngine() async {
    try {
      if (_speech.isListening) {
        await _speech.stop();
      }
    } catch (_) {}
    try {
      await _speech.cancel();
    } catch (_) {}
  }

  void _scheduleVoiceRestart({
    required String message,
    Duration delay = const Duration(milliseconds: 550),
  }) {
    if (!mounted || !_voiceSessionEnabled || _isSubmitting) return;
    _voiceRestartPending = true;
    setState(() => _voiceMessage = message);
    _voiceRestartTimer?.cancel();
    _voiceRestartTimer = Timer(delay, () {
      _voiceRestartPending = false;
      unawaited(_startVoiceListening());
    });
  }

  Future<void> _toggleVoiceListening() async {
    if (_isSubmitting) return;
    if (_voiceSessionEnabled || _isListening) {
      _voiceSessionEnabled = false;
      _voiceRestartPending = false;
      _voiceRestartTimer?.cancel();
      await _stopSpeechEngine();
      await _restoreNativeVoiceAudio();
      if (!mounted) return;
      setState(() {
        _isListening = false;
        _voiceMessage = 'ปิดการฟังคำสั่งเสียงแล้ว';
      });
      return;
    }

    final micAllowed = await _requestMicrophonePermission();
    if (!micAllowed) return;

    if (!_voiceReady) {
      await _initVoiceCommands();
    }
    if (!_voiceAvailable) {
      if (!mounted) return;
      setState(() => _voiceMessage = 'กรุณาอนุญาตไมค์ก่อนใช้คำสั่งเสียง');
      return;
    }

    _voiceSessionEnabled = true;
    await _startVoiceListening();
  }

  Future<void> _startVoiceListening() async {
    if (!mounted ||
        !_voiceSessionEnabled ||
        _isSubmitting ||
        _isHandlingVoiceCommand ||
        !_voiceAvailable) {
      _voiceRestartPending = false;
      return;
    }
    if (_isListening && !_voiceRestartPending) return;

    _voiceRestartPending = false;
    await _prepareNativeVoiceAudio();
    setState(() {
      _isListening = false;
      _voiceMessage = 'กำลังเปิดไมค์...';
    });
    _resetVoiceNoiseGate();
    await _stopSpeechEngine();
    await Future<void>.delayed(const Duration(milliseconds: 350));

    final localeId = await _resolveSpeechLocaleId();

    try {
      await _speech.listen(
        localeId: localeId,
        listenFor: const Duration(minutes: 30),
        pauseFor: const Duration(seconds: 4),
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
      setState(() {
        _isListening = true;
        _lastVoiceText = '';
        _voiceMessage = 'พูดว่า รับออเดอร์ หรือ ปฏิเสธออเดอร์';
      });
    } catch (error) {
      debugPrint('[incoming-order-voice] listen failed: $error');
      if (!mounted) return;
      setState(() {
        _isListening = false;
        _voiceMessage = 'เริ่มฟังไม่สำเร็จ กดไมค์เพื่อลองใหม่';
      });
      _voiceSessionEnabled = false;
      await _restoreNativeVoiceAudio();
    }
  }

  Future<String?> _resolveSpeechLocaleId() async {
    try {
      final locales = await _speech.locales();
      final hasThai = locales.any((locale) => locale.localeId.startsWith('th'));
      if (hasThai) return 'th_TH';
    } catch (_) {}
    return null;
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
        _voiceLevelSamples < 8 ||
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

  Future<void> _maybeAutoStartVoiceListening() async {
    if (!mounted ||
        !widget.autoStartVoiceListening ||
        _isSubmitting ||
        _isListening ||
        _hasAutoStartedVoice) {
      return;
    }

    final status = await Permission.microphone.status;
    if (!mounted || !status.isGranted) {
      return;
    }

    _hasAutoStartedVoice = true;
    await _toggleVoiceListening();
  }

  Future<bool> _requestMicrophonePermission() async {
    final status = await Permission.microphone.status;
    if (status.isGranted) return true;

    final requested = await Permission.microphone.request();
    if (requested.isGranted) return true;

    if (!mounted) return false;
    setState(() {
      _voiceReady = false;
      _voiceAvailable = false;
      _isListening = false;
      _voiceMessage = requested.isPermanentlyDenied
          ? 'กรุณาเปิดสิทธิ์ไมค์ในตั้งค่าเครื่องก่อนใช้คำสั่งเสียง'
          : 'ต้องอนุญาตไมค์ก่อนใช้คำสั่งเสียง';
    });
    return false;
  }

  Future<void> _openMicrophoneSettings() async {
    await openAppSettings();
  }

  bool get _showOpenSettingsAction {
    final message = _voiceMessage?.trim() ?? '';
    return message.contains('ตั้งค่าเครื่อง') || message.contains('อนุญาตไมค์');
  }

  void _handleVoiceResult(String words, {required bool isFinal}) {
    if (!mounted || _isSubmitting || _isHandlingVoiceCommand) return;
    final heardText = words.trim();
    if (heardText.isEmpty) return;

    final command = ShopOrderVoiceCommands.matchAcceptReject(heardText);
    final label = ShopOrderVoiceCommands.describeMatch(heardText);
    final passesNoiseGate = _passesVoiceNoiseGate();

    if (!isFinal) {
      if (command != null && passesNoiseGate) {
        unawaited(_executeVoiceCommand(command, heardText, label));
      } else {
        setState(() {
          _lastVoiceText = heardText;
          _voiceMessage = command == null
              ? 'กำลังฟัง...'
              : 'ได้ยินใกล้เคียง ${label ?? ''}';
        });
      }
      return;
    }

    if (command == null) {
      setState(() {
        _lastVoiceText = heardText;
        _voiceMessage = passesNoiseGate
            ? 'ได้ยิน: $heardText (ลองพูด รับออเดอร์ หรือ ปฏิเสธออเดอร์)'
            : 'เสียงรบกวนมากเกินไป ลองพูดใกล้ไมค์อีกครั้ง';
      });
      return;
    }

    unawaited(_executeVoiceCommand(command, heardText, label));
  }

  Future<void> _executeVoiceCommand(
    bool accept,
    String heardText,
    String? label,
  ) async {
    if (!mounted || _isSubmitting || _isHandlingVoiceCommand) return;
    _isHandlingVoiceCommand = true;
    _voiceSessionEnabled = false;
    _voiceRestartPending = true;
    _voiceRestartTimer?.cancel();
    await _stopSpeechEngine();

    setState(() {
      _lastVoiceText = heardText;
      _voiceMessage = accept
          ? 'กำลังรับออเดอร์...'
          : 'กำลังปฏิเสธออเดอร์...';
      _isListening = false;
    });

    try {
      await _submit(accept: accept);
    } finally {
      _isHandlingVoiceCommand = false;
      _voiceRestartPending = false;
    }
  }


  Future<void> _submit({required bool accept}) async {
    if (_isSubmitting) return;
    setState(() => _isSubmitting = true);
    try {
      if (accept) {
        final decision = await ShopOrderCreditGate.ensureCanAccept(
          context: context,
          order: widget.order,
        );
        if (!mounted) return;
        if (decision == ShopOrderCreditDecision.reject) {
          await widget.onReject();
          if (!mounted) return;
          Navigator.of(context).pop(false);
          return;
        }
        if (decision != ShopOrderCreditDecision.accept) {
          setState(() => _isSubmitting = false);
          return;
        }
        await widget.onAccept();
      } else {
        await widget.onReject();
      }
      if (!mounted) return;
      Navigator.of(context).pop(accept);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('ดำเนินการไม่สำเร็จ: $error'),
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
      );
      setState(() => _isSubmitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final order = widget.order;
    final title = widget.title?.trim().isNotEmpty == true
        ? widget.title!.trim()
        : 'มีออเดอร์รอร้านยืนยัน';
    final isNationwideParcel =
        order.orderType == 'nationwide_parcel' &&
        order.fulfillmentType == 'external_courier';
    final deliveryAddressLabel = order.customerAddress.trim().isNotEmpty
        ? order.customerAddress.trim()
        : '-';
    final shortOrderId = order.orderId.substring(
      0,
      order.orderId.length >= 8 ? 8 : order.orderId.length,
    );

    return Scaffold(
      backgroundColor: Colors.black.withOpacity(0.38),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 430, maxHeight: 720),
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(22),
                child: Material(
                  color: Colors.white,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
                        color: AppColors.accent,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(
                              'ออเดอร์ #$shortOrderId',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 20,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              title,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Flexible(
                        child: ListView(
                          shrinkWrap: true,
                          padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
                          children: <Widget>[
                            _SectionCard(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: <Widget>[
                                  Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: <Widget>[
                                      Container(
                                        width: 54,
                                        height: 54,
                                        decoration: BoxDecoration(
                                          color: AppColors.accent.withOpacity(
                                            0.12,
                                          ),
                                          borderRadius: BorderRadius.circular(
                                            12,
                                          ),
                                        ),
                                        child: const Icon(
                                          Icons.receipt_long_rounded,
                                          color: AppColors.accent,
                                          size: 30,
                                        ),
                                      ),
                                      const SizedBox(width: 12),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: <Widget>[
                                            Text(
                                              title,
                                              style: const TextStyle(
                                                fontSize: 20,
                                                fontWeight: FontWeight.w800,
                                              ),
                                            ),
                                            const SizedBox(height: 6),
                                            Text(
                                              'Order ID: ${order.orderId}',
                                              style: const TextStyle(
                                                color: Color(0xFF64748B),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                  if (widget.message?.trim().isNotEmpty ==
                                      true) ...<Widget>[
                                    const SizedBox(height: 14),
                                    Text(
                                      widget.message!.trim(),
                                      style: const TextStyle(
                                        color: Color(0xFF475569),
                                      ),
                                    ),
                                  ],
                                  const SizedBox(height: 16),
                                  Wrap(
                                    spacing: 10,
                                    runSpacing: 10,
                                    children: <Widget>[
                                      _InfoChip(
                                        label: 'ยอดรวม',
                                        value:
                                            '฿${order.totalAmount.toStringAsFixed(2)}',
                                      ),
                                      _InfoChip(
                                        label: 'ค่าส่ง',
                                        value:
                                            '฿${order.shippingFee.toStringAsFixed(2)}',
                                      ),
                                      _InfoChip(
                                        label: 'จำนวนสินค้า',
                                        value: '${order.totalItems} รายการ',
                                      ),
                                      _InfoChip(
                                        label: 'สถานะ',
                                        value: order.preparingStartTime == null
                                            ? 'รอร้านยืนยัน'
                                            : order.status,
                                      ),
                                      if (isNationwideParcel)
                                        const _InfoChip(
                                          label: 'รูปแบบ',
                                          value: 'ส่งทั่วประเทศ',
                                        ),
                                      if (isNationwideParcel)
                                        const _InfoChip(
                                          label: 'ขนส่ง',
                                          value: 'ภายนอก',
                                        ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 14),
                            _SectionCard(
                              title: 'รายการสินค้า',
                              child: order.items.isEmpty
                                  ? const Align(
                                      alignment: Alignment.centerLeft,
                                      child: Text('ไม่พบรายละเอียดสินค้า'),
                                    )
                                  : Column(
                                      children: order.items
                                          .map(
                                            (item) => _ProductTile(item: item),
                                          )
                                          .toList(growable: false),
                                    ),
                            ),
                            if (isNationwideParcel) ...<Widget>[
                              const SizedBox(height: 14),
                              _SectionCard(
                                title: 'ข้อมูลจัดส่งทั่วประเทศ',
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: <Widget>[
                                    const _ExternalCourierBanner(),
                                    const SizedBox(height: 10),
                                    _DetailLine(
                                      label: 'ผู้รับ',
                                      value:
                                          (order.deliveryAddress['recipientName'] ??
                                                  '-')
                                              .toString(),
                                    ),
                                    _DetailLine(
                                      label: 'เบอร์โทร',
                                      value:
                                          (order.deliveryAddress['phoneNumber'] ??
                                                  '-')
                                              .toString(),
                                    ),
                                    _DetailLine(
                                      label: 'ที่อยู่',
                                      value: deliveryAddressLabel,
                                    ),
                                    _DetailLine(
                                      label: 'สถานะขนส่ง',
                                      value:
                                          order.shippingStatusLabel
                                              .trim()
                                              .isNotEmpty
                                          ? order.shippingStatusLabel
                                          : 'รอจองขนส่งภายนอก',
                                    ),
                                  ],
                                ),
                              ),
                            ],
                            if (order.driverName?.trim().isNotEmpty == true ||
                                order.driverId?.trim().isNotEmpty ==
                                    true) ...<Widget>[
                              const SizedBox(height: 14),
                              _SectionCard(
                                title: 'ไรเดอร์',
                                child: _RiderContactPanel(order: order),
                              ),
                            ],
                          ],
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                        child: _VoiceCommandPanel(
                          isListening: _isListening,
                          isEnabled: !_isSubmitting,
                          showOpenSettingsAction: _showOpenSettingsAction,
                          message: _voiceMessage,
                          lastText: _lastVoiceText,
                          onTap: _toggleVoiceListening,
                          onOpenSettings: _openMicrophoneSettings,
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                        child: Row(
                          children: <Widget>[
                            Expanded(
                              child: OutlinedButton.icon(
                                onPressed: _isSubmitting
                                    ? null
                                    : () => _submit(accept: false),
                                icon: const Icon(Icons.close_rounded),
                                label: const Text('ปฏิเสธออเดอร์'),
                                style: OutlinedButton.styleFrom(
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 14,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: FilledButton.icon(
                                onPressed: _isSubmitting
                                    ? null
                                    : () => _submit(accept: true),
                                icon: _isSubmitting
                                    ? const SizedBox(
                                        width: 18,
                                        height: 18,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                          color: Colors.white,
                                        ),
                                      )
                                    : const Icon(
                                        Icons.check_circle_outline_rounded,
                                      ),
                                label: Text(
                                  _isSubmitting
                                      ? 'กำลังบันทึก...'
                                      : 'รับออเดอร์',
                                ),
                                style: FilledButton.styleFrom(
                                  backgroundColor: Colors.green,
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 14,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _VoiceCommandPanel extends StatelessWidget {
  const _VoiceCommandPanel({
    required this.isListening,
    required this.isEnabled,
    required this.showOpenSettingsAction,
    required this.onTap,
    required this.onOpenSettings,
    this.message,
    this.lastText,
  });

  final bool isListening;
  final bool isEnabled;
  final bool showOpenSettingsAction;
  final VoidCallback onTap;
  final VoidCallback onOpenSettings;
  final String? message;
  final String? lastText;

  @override
  Widget build(BuildContext context) {
    final statusText = message?.trim().isNotEmpty == true
        ? message!.trim()
        : (isListening ? 'กำลังฟัง...' : 'สั่งงานด้วยเสียง');
    final recognizedText = lastText?.trim();

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: isListening ? const Color(0xFFFFF7ED) : const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: isListening ? AppColors.accent : const Color(0xFFE2E8F0),
        ),
      ),
      child: Row(
        children: <Widget>[
          IconButton.filledTonal(
            onPressed: isEnabled ? onTap : null,
            icon: Icon(
              isListening ? Icons.mic_rounded : Icons.mic_none_rounded,
            ),
            tooltip: isListening ? 'หยุดฟัง' : 'เริ่มฟังคำสั่งเสียง',
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  statusText,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 2),
                Text(
                  recognizedText?.isNotEmpty == true
                      ? recognizedText!
                      : 'พูดว่า รับออเดอร์ หรือ ปฏิเสธออเดอร์',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xFF64748B),
                  ),
                ),
              ],
            ),
          ),
          if (showOpenSettingsAction) ...<Widget>[
            const SizedBox(width: 10),
            TextButton(
              onPressed: onOpenSettings,
              child: const Text('ตั้งค่าไมค์'),
            ),
          ],
        ],
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({this.title, required this.child});

  final String? title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (title != null) ...<Widget>[
            Text(
              title!,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 12),
          ],
          child,
        ],
      ),
    );
  }
}

class _ExternalCourierBanner extends StatelessWidget {
  const _ExternalCourierBanner();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF7ED),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFFED7AA)),
      ),
      child: const Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(Icons.local_shipping_outlined, color: AppColors.accent),
          SizedBox(width: 10),
          Expanded(
            child: Text(
              'ออเดอร์นี้เป็นสินค้าส่งทั่วประเทศ ใช้ขนส่งภายนอก ไม่ใช่งานไรเดอร์ในพื้นที่',
              style: TextStyle(
                color: Color(0xFF9A3412),
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DetailLine extends StatelessWidget {
  const _DetailLine({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 86,
            child: Text(
              label,
              style: const TextStyle(
                color: Color(0xFF64748B),
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value.trim().isEmpty ? '-' : value.trim(),
              style: const TextStyle(
                color: Color(0xFF0F172A),
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _InfoChip extends StatelessWidget {
  const _InfoChip({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF7ED),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFFED7AA)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            label,
            style: const TextStyle(fontSize: 12, color: Color(0xFF9A3412)),
          ),
          const SizedBox(height: 2),
          Text(value, style: const TextStyle(fontWeight: FontWeight.w800)),
        ],
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(icon, size: 20, color: AppColors.accent),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  label,
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xFF64748B),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  value,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ProductTile extends StatelessWidget {
  const _ProductTile({required this.item});

  final OrderItem item;

  @override
  Widget build(BuildContext context) {
    final imageUrl = item.imageUrl?.trim();
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _ProductImage(imageUrl: imageUrl),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  item.productName.isNotEmpty ? item.productName : '-',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                if (item.toppings?.trim().isNotEmpty == true) ...<Widget>[
                  const SizedBox(height: 4),
                  Text(
                    'ท็อปปิ้ง: ${item.toppings!.trim()}',
                    style: const TextStyle(color: Color(0xFF64748B)),
                  ),
                ],
                const SizedBox(height: 4),
                Text(
                  'ราคาต่อชิ้น ฿${item.price.toStringAsFixed(2)}',
                  style: const TextStyle(color: Color(0xFF64748B)),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Text('x${item.quantity}'),
          const SizedBox(width: 12),
          Text('฿${(item.price * item.quantity).toStringAsFixed(2)}'),
        ],
      ),
    );
  }
}

class _ProductImage extends StatelessWidget {
  const _ProductImage({required this.imageUrl});

  final String? imageUrl;

  @override
  Widget build(BuildContext context) {
    final url = imageUrl?.trim();
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Container(
        width: 64,
        height: 64,
        color: const Color(0xFFF1F5F9),
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

class _RiderContactPanel extends StatelessWidget {
  const _RiderContactPanel({required this.order});

  final DetailedOrder order;

  Future<_RiderContactState> _loadRiderContactState() async {
    final riderId = order.driverId?.trim();
    if (riderId == null || riderId.isEmpty) {
      return const _RiderContactState(profile: null, phone: null);
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
    } catch (_) {}

    profile ??= UserProfile(
      uid: riderId,
      displayName: order.driverName?.trim().isNotEmpty == true
          ? order.driverName!.trim()
          : 'ไรเดอร์',
      phoneNumber: order.driverPhone,
    );

    final phoneCandidates = <String?>[
      order.driverPhone,
      profile.phoneNumber,
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

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_RiderContactState>(
      future: _loadRiderContactState(),
      builder: (context, snapshot) {
        final state = snapshot.data;
        final profile = state?.profile;
        final phone = state?.phone;
        final canChat = profile != null;
        final hasRider = order.driverId?.trim().isNotEmpty == true;
        final canCall = hasRider || phone?.trim().isNotEmpty == true;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            _DetailRow(
              icon: Icons.delivery_dining_rounded,
              label: 'ผู้รับงาน',
              value:
                  profile?.displayName ??
                  order.driverName ??
                  order.driverId ??
                  '-',
            ),
            Row(
              children: <Widget>[
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: !canChat
                        ? null
                        : () async {
                            await Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (_) =>
                                    ChatRoomScreen(friendProfile: profile),
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
                            riderProfile: profile,
                            fallbackPhone: phone,
                          ),
                    icon: const Icon(Icons.phone_in_talk_outlined),
                    label: Text(canCall ? 'โทรไรเดอร์' : 'โทรไรเดอร์ไม่ได้'),
                  ),
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}

class _RiderContactState {
  const _RiderContactState({required this.profile, required this.phone});

  final UserProfile? profile;
  final String? phone;
}
