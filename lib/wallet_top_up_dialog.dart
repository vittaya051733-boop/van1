import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:image_gallery_saver_plus/image_gallery_saver_plus.dart';
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:van1/utils/app_check_guard.dart';

import 'firebase_options.dart';
import 'services/pending_top_up_session.dart';
import 'services/promptpay_qr_payload.dart';
import 'storage_helper.dart';

class WalletTopUpDialog extends StatefulWidget {
  const WalletTopUpDialog({
    super.key,
    this.initialAmount,
    this.minimumAmount,
    this.isSecurityDeposit = false,
    this.resumeConfirmed = false,
  });

  final double? initialAmount;
  final double? minimumAmount;
  final bool isSecurityDeposit;
  final bool resumeConfirmed;

  @override
  State<WalletTopUpDialog> createState() => _WalletTopUpDialogState();
}

enum _TopUpGuideStep { pending, active, done, processing }

class _WalletTopUpDialogState extends State<WalletTopUpDialog> {
  static const List<double> _presets = <double>[500, 1000, 2000, 3000];
  static const double _maxTopUpAmount = 5000;
  static const String _appLogoAsset = 'assets/app_logo.png';
  static const String _twoStepGuideDateKey = 'merchant_topup_two_step_guide_date';

  final TextEditingController _customAmountController = TextEditingController();
  final GlobalKey _qrBoundaryKey = GlobalKey();

  bool _loadingConfig = true;
  bool _isBusy = false;
  int _verifyProgress = 0;
  Timer? _verifyProgressTimer;
  Timer? _inlineBannerTimer;
  String? _inlineBanner;
  bool _inlineBannerSuccess = false;

  String? _promptPayNationalId;
  String? _recipientDisplayName;
  double? _selectedAmount;
  double? _confirmedAmount;
  XFile? _selectedSlipImage;

  @override
  void initState() {
    super.initState();
    PendingTopUpSession.markDialogOpen();
    if (widget.resumeConfirmed) {
      PendingTopUpSession.markActive();
    }
    unawaited(_loadPaymentConfig());
  }

  @override
  void dispose() {
    PendingTopUpSession.markDialogClosed();
    _inlineBannerTimer?.cancel();
    _stopVerifyProgressTicker();
    _customAmountController.dispose();
    super.dispose();
  }

  void _updateVerifyProgress(int value) {
    if (!mounted) return;
    final next = value.clamp(0, 100);
    if (next == _verifyProgress) return;
    setState(() => _verifyProgress = next);
  }

  void _startVerifyProgressTicker({int cap = 92}) {
    _verifyProgressTimer?.cancel();
    _verifyProgressTimer = Timer.periodic(const Duration(milliseconds: 320), (_) {
      if (!mounted || _verifyProgress >= cap) return;
      _updateVerifyProgress(_verifyProgress + 1);
    });
  }

  void _stopVerifyProgressTicker() {
    _verifyProgressTimer?.cancel();
    _verifyProgressTimer = null;
  }

  Future<void> _loadPaymentConfig() async {
    try {
      final snapshot = await FirebaseFirestore.instance
          .collection('payment_config')
          .doc('collection')
          .get()
          .timeout(const Duration(seconds: 5));
      final data = snapshot.data() ?? const <String, dynamic>{};
      _promptPayNationalId = _resolvePromptPayId(data) ?? '1410400168710';
      final name = data['recipientDisplayName']?.toString().trim();
      _recipientDisplayName =
          name != null && name.isNotEmpty ? name : 'วิทยา ทนหงษา';
    } catch (_) {
      _promptPayNationalId = '1410400168710';
      _recipientDisplayName = 'วิทยา ทนหงษา';
    } finally {
      if (mounted) {
        setState(() => _loadingConfig = false);
      }
      _applyInitialAmountIfNeeded();
    }
  }

  void _applyInitialAmountIfNeeded() {
    final initial = widget.initialAmount;
    if (initial == null || initial <= 0 || !mounted) {
      return;
    }
    setState(() {
      _selectedAmount = initial.clamp(0, _maxTopUpAmount);
      if (widget.resumeConfirmed) {
        _confirmedAmount = _selectedAmount;
      }
      _customAmountController.text = '';
    });
  }

  void _selectPreset(double amount) {
    setState(() {
      _selectedAmount = amount.clamp(0, _maxTopUpAmount);
      _confirmedAmount = null;
      _selectedSlipImage = null;
      _customAmountController.text = '';
    });
  }

  void _onCustomAmountChanged(String value) {
    final parsed = double.tryParse(value);
    setState(() {
      _confirmedAmount = null;
      _selectedSlipImage = null;
      if (parsed == null || parsed <= 0) {
        _selectedAmount = null;
        return;
      }
      _selectedAmount = parsed > _maxTopUpAmount ? _maxTopUpAmount : parsed;
      if (parsed > _maxTopUpAmount) {
        _customAmountController.value = TextEditingValue(
          text: _maxTopUpAmount.toStringAsFixed(0),
          selection: TextSelection.collapsed(
            offset: _maxTopUpAmount.toStringAsFixed(0).length,
          ),
        );
      }
    });
  }

  void _confirmAmount() {
    final amount = _selectedAmount;
    if (amount == null || amount <= 0 || _buildPromptPayPayload(amount) == null) {
      _showSnack('กรุณาเลือกจำนวนเงินให้ถูกต้อง');
      return;
    }
    setState(() {
      _confirmedAmount = amount;
      _selectedSlipImage = null;
    });
    unawaited(
      PendingTopUpSession.save(
        amount: amount,
        isSecurityDeposit: widget.isSecurityDeposit,
        minimumAmount: widget.minimumAmount,
      ),
    );
    unawaited(_showTwoStepGuideIfNeeded());
  }

  Future<void> _showTwoStepGuideIfNeeded() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final now = DateTime.now();
      final today =
          '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
      if (prefs.getString(_twoStepGuideDateKey) == today) {
        return;
      }
      if (!mounted) {
        return;
      }

      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('วิธีเติมเครดิต'),
          content: const Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'เติมเครดิตมี 2 ขั้นตอน:',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              SizedBox(height: 12),
              Text('1. สแกน QR แล้วโอนเงินตามยอด'),
              SizedBox(height: 8),
              Text(
                '2. แนบสลิปยืนยันการโอน — ไม่แนบ = เติมเครดิตยังไม่สำเร็จ',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
            ],
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('เข้าใจแล้ว'),
            ),
          ],
        ),
      );

      await prefs.setString(_twoStepGuideDateKey, today);
    } catch (_) {
      // ไม่บล็อก flow หลักถ้าอ่าน prefs ไม่ได้
    }
  }

  void _resetConfirmedAmount() {
    setState(() {
      _confirmedAmount = null;
      _selectedSlipImage = null;
    });
    unawaited(PendingTopUpSession.clear());
  }

  Future<void> _closeWithoutCompleting() async {
    await PendingTopUpSession.clear();
    if (!mounted) return;
    Navigator.of(context).pop(false);
  }

  double? get _amount => _selectedAmount;

  double? get _qrAmount => _confirmedAmount;

  String? _resolvePromptPayId(Map<String, dynamic> data) {
    const fallback = '1410400168710';

    String digitsOnly(String? raw) =>
        raw?.replaceAll(RegExp(r'\D'), '') ?? '';

    final nationalDigits = digitsOnly(
      data['promptPayNationalIdOrTaxId']?.toString(),
    );
    if (nationalDigits.length == 13) {
      return nationalDigits;
    }

    final phoneDigits = digitsOnly(data['promptPayPhoneNumber']?.toString());
    if (phoneDigits.length >= 9 && phoneDigits.length <= 10) {
      return phoneDigits;
    }

    if (nationalDigits.length >= 9 && nationalDigits.length <= 10) {
      return nationalDigits;
    }

    final fallbackDigits = digitsOnly(fallback);
    return fallbackDigits.length == 13 ? fallbackDigits : null;
  }

  String? _buildPromptPayPayload(double amount) {
    final promptPayId = _promptPayNationalId;
    if (promptPayId == null || promptPayId.isEmpty) {
      return null;
    }
    return PromptPayQrPayload.build(promptPayId: promptPayId, amount: amount);
  }

  bool get _canConfirmAmount {
    final amount = _amount;
    if (amount == null || amount <= 0) {
      return false;
    }
    return _buildPromptPayPayload(amount) != null;
  }

  bool get _canGeneratePromptPayQr {
    final amount = _qrAmount;
    if (amount == null || amount <= 0) {
      return false;
    }
    return _buildPromptPayPayload(amount) != null;
  }

  Future<void> _saveQrToGallery() async {
    if (kIsWeb) {
      _showSnack('บันทึก QR บน Web ยังไม่รองรับ');
      return;
    }

    if (!_canGeneratePromptPayQr) {
      _showSnack('ยังไม่มี QR สำหรับบันทึก');
      return;
    }

    setState(() => _isBusy = true);
    try {
      final double pixelRatio = View.of(context).devicePixelRatio;

      try {
        final permission = await Permission.photos.request();
        if (!permission.isGranted) {
          final storagePermission = await Permission.storage.request();
          if (!storagePermission.isGranted) {
            _showSnack('ไม่ได้รับสิทธิ์เข้าถึงรูปภาพ/พื้นที่จัดเก็บ');
            return;
          }
        }
      } catch (_) {
        _showSnack('ไม่สามารถขอสิทธิ์เข้าถึงรูปภาพได้');
        return;
      }

      if (!mounted) {
        return;
      }

      final boundary =
          _qrBoundaryKey.currentContext?.findRenderObject()
              as RenderRepaintBoundary?;
      if (boundary == null) {
        _showSnack('บันทึก QR ไม่สำเร็จ');
        return;
      }
      final ui.Image image = await boundary.toImage(pixelRatio: pixelRatio);
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      if (byteData == null) {
        _showSnack('บันทึก QR ไม่สำเร็จ');
        return;
      }

      final bytes = byteData.buffer.asUint8List();
      final result = await ImageGallerySaverPlus.saveImage(
        bytes,
        quality: 100,
        name: 'promptpay_topup_${DateTime.now().millisecondsSinceEpoch}',
      );

      final success = result['isSuccess'] == true;
      _showSnack(success ? 'บันทึก QR ลงเครื่องเรียบร้อย' : 'บันทึก QR ไม่สำเร็จ');
    } catch (error) {
      _showSnack('บันทึก QR ไม่สำเร็จ: $error');
    } finally {
      if (mounted) {
        setState(() => _isBusy = false);
      }
    }
  }

  Future<void> _pickSlipImage() async {
    if (kIsWeb) {
      _showSnack('แนบสลิปบน Web ยังไม่รองรับ');
      return;
    }

    if (!_canGeneratePromptPayQr) {
      _showSnack('กรุณาเลือกจำนวนเงินก่อน');
      return;
    }

    try {
      final picker = ImagePicker();
      final image = await picker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 92,
      );
      if (image == null || !mounted) {
        return;
      }

      setState(() => _selectedSlipImage = image);
    } catch (error) {
      _showSnack('เลือกสลิปไม่สำเร็จ: $error');
    }
  }

  Future<void> _verifySelectedSlip() async {
    if (kIsWeb) {
      _showSnack('แนบสลิปบน Web ยังไม่รองรับ');
      return;
    }

    final image = _selectedSlipImage;
    if (image == null) {
      _showSnack('กรุณาเลือกรูปสลิปก่อน');
      return;
    }

    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      _showSnack('กรุณาเข้าสู่ระบบก่อน');
      return;
    }

    final amount = _qrAmount;
    if (amount == null || amount <= 0) {
      _showSnack('กรุณายืนยันจำนวนเงินก่อน');
      return;
    }
    if (amount > _maxTopUpAmount) {
      _showSnack('ยอดเติมสูงสุด ${_maxTopUpAmount.toStringAsFixed(0)} บาทต่อครั้ง');
      return;
    }

    setState(() {
      _isBusy = true;
      _verifyProgress = 1;
    });

    _logTopUpVerify('เริ่มส่งสลิป amount=${amount.toStringAsFixed(2)} uid=${user.uid}');

    try {
      try {
        _logTopUpVerify('App Check: กำลังขอ token...');
        await AppCheckGuard.ensureFinancialReady();
        _logTopUpVerify('App Check: พร้อม');
      } catch (error) {
        _logTopUpVerify('App Check: ล้มเหลว — $error');
        _showSnack(error.toString().replaceFirst('Exception: ', ''));
        return;
      }
      _updateVerifyProgress(8);

      const source = ImageSource.gallery;
      final paymentGroupId = _newPaymentGroupId(user.uid);
      final fileName = image.name.isNotEmpty ? image.name : 'slip.jpg';
      final contentType = _guessContentType(fileName);
      final objectPath = 'shops/${user.uid}/topups/$paymentGroupId/$fileName';
      final storageBucket = _topUpStorageBucket;
      _logTopUpVerify(
        'paymentGroupId=$paymentGroupId path=$objectPath bucket=$storageBucket',
      );

      await _ensureTopUpSlipDocExists(
        uid: user.uid,
        paymentGroupId: paymentGroupId,
        expectedAmount: amount,
        storagePath: objectPath,
        fileName: fileName,
        contentType: contentType,
        source: source,
      );
      _updateVerifyProgress(18);

      final ref = StorageHelper.instance.ref().child(objectPath);
      _logTopUpVerify('Storage: กำลังอัปโหลดสลิป...');
      await ref.putFile(
        File(image.path),
        SettableMetadata(contentType: contentType),
      );
      _logTopUpVerify('Storage: อัปโหลดเสร็จ');
      _updateVerifyProgress(42);

      unawaited(
        _uploadWebpCopyInBackground(
          uid: user.uid,
          paymentGroupId: paymentGroupId,
          imagePath: image.path,
        ),
      );

      await _patchTopUpSlipDoc(
        uid: user.uid,
        paymentGroupId: paymentGroupId,
        patch: <String, dynamic>{
          'status': 'uploaded',
          'uploadedAt': FieldValue.serverTimestamp(),
        },
      );
      _updateVerifyProgress(50);

      final callable = FirebaseFunctions.instanceFor(region: 'asia-southeast1')
          .httpsCallable('verifyTopUpSlip');

      _startVerifyProgressTicker();
      _logTopUpVerify('Callable: เรียก verifyTopUpSlip (region=asia-southeast1)...');
      final startedAt = DateTime.now();
      final response = await callable
          .call(<String, dynamic>{
            'uid': user.uid,
            'expectedAmount': amount,
            'storagePath': objectPath,
            'bucket': storageBucket,
            'paymentGroupId': paymentGroupId,
            'fileName': fileName,
            'contentType': contentType,
            'sourceApp': 'van1_merchant',
            if (widget.isSecurityDeposit) 'purpose': 'security_deposit',
          })
          .timeout(const Duration(seconds: 90));
      _logTopUpVerify(
        'Callable: ตอบกลับใน ${DateTime.now().difference(startedAt).inMilliseconds}ms',
      );
      _stopVerifyProgressTicker();
      _updateVerifyProgress(96);

      final data = (response.data is Map)
          ? Map<String, dynamic>.from(response.data as Map)
          : const <String, dynamic>{};

      final success = data['success'] == true;
      final message = data['message']?.toString().trim();
      _logTopUpVerify(
        'ผลลัพธ์ success=$success status=${data['status']} message=${message ?? '-'}',
      );
      final verifiedAmount = (data['verifiedAmount'] is num)
          ? (data['verifiedAmount'] as num).toDouble()
          : null;
      final remainingAmount = (data['remainingAmount'] is num)
          ? (data['remainingAmount'] as num).toDouble()
          : null;
      final overpaidAmount = (data['overpaidAmount'] is num)
          ? (data['overpaidAmount'] as num).toDouble()
          : null;

      await _patchTopUpSlipDoc(
        uid: user.uid,
        paymentGroupId: paymentGroupId,
        patch: <String, dynamic>{
          'status': success ? 'verified' : 'failed',
          'verifiedAt': FieldValue.serverTimestamp(),
          'success': success,
          if (message != null && message.isNotEmpty) 'message': message,
          if (verifiedAmount != null) 'verifiedAmount': verifiedAmount,
          if (remainingAmount != null) 'remainingAmount': remainingAmount,
          if (overpaidAmount != null) 'overpaidAmount': overpaidAmount,
          'rawResponse': data,
        },
      );
      _updateVerifyProgress(100);
      await Future<void>.delayed(const Duration(milliseconds: 220));

      if (!mounted) {
        return;
      }

      if (success) {
        final details = <String>[];
        if (verifiedAmount != null) {
          details.add('เติมเครดิต ${verifiedAmount.toStringAsFixed(2)} บาท');
        }
        if (remainingAmount != null && remainingAmount > 0) {
          details.add('คงเหลือต้องจ่ายอีก ${remainingAmount.toStringAsFixed(2)} บาท');
        }
        if (overpaidAmount != null && overpaidAmount > 0) {
          details.add(
            'จ่ายเกิน ${overpaidAmount.toStringAsFixed(2)} บาท (ระบบเติมตามยอดที่จ่าย)',
          );
        }

        final shouldContinueForRemaining = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('ผลตรวจสลิป'),
            content: Text(
              [
                if (message != null && message.isNotEmpty) message,
                if (details.isNotEmpty) details.join('\n'),
              ].where((line) => line.trim().isNotEmpty).join('\n\n'),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('ปิด'),
              ),
              if (remainingAmount != null && remainingAmount > 0)
                FilledButton(
                  onPressed: () => Navigator.of(context).pop(true),
                  child: const Text('สร้าง QR ยอดคงเหลือ'),
                )
              else
                FilledButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: const Text('ตกลง'),
                ),
            ],
          ),
        );

        if (!mounted) {
          return;
        }

        if (remainingAmount != null &&
            remainingAmount > 0 &&
            shouldContinueForRemaining == true) {
          setState(() {
            _selectedAmount = remainingAmount;
            _confirmedAmount = null;
            _customAmountController.text = remainingAmount.toStringAsFixed(2);
            _selectedSlipImage = null;
          });
          unawaited(PendingTopUpSession.clear());
          _showSnack('สร้าง QR สำหรับยอดคงเหลือเรียบร้อย');
          return;
        }

        if (widget.isSecurityDeposit) {
          final minimum = widget.minimumAmount ?? 0;
          final paidEnough = data['securityDepositPaid'] == true ||
              (verifiedAmount != null && verifiedAmount >= minimum);
          if (!paidEnough) {
            _showSnack(
              'ยอดที่ตรวจสอบได้ยังไม่ครบ ${minimum.toStringAsFixed(0)} บาท',
            );
            return;
          }
        }

        await PendingTopUpSession.clear();
        if (!mounted) return;
        Navigator.of(context).pop(true);
      } else {
        await showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('ผลตรวจสลิป'),
            content: Text(
              message?.isNotEmpty == true ? message! : 'ตรวจสลิปไม่สำเร็จ',
            ),
            actions: [
              FilledButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('ตกลง'),
              ),
            ],
          ),
        );
      }
    } on FirebaseFunctionsException catch (error) {
      _logTopUpVerify(
        'Callable error code=${error.code} message=${error.message} details=${error.details}',
      );
      _showSnack(error.message ?? 'ตรวจสลิปไม่สำเร็จ');
    } on TimeoutException catch (error) {
      _logTopUpVerify('Callable timeout — $error');
      _showSnack('ตรวจสลิปใช้เวลานานเกินไป กรุณาลองใหม่');
    } catch (error, stackTrace) {
      _logTopUpVerify('Unexpected error — $error');
      debugPrintStack(stackTrace: stackTrace, label: '[TopUpVerify]');
      _showSnack('ตรวจสลิปไม่สำเร็จ: $error');
    } finally {
      _stopVerifyProgressTicker();
      _logTopUpVerify('จบ flow (busy=false)');
      if (mounted) {
        setState(() {
          _isBusy = false;
          _verifyProgress = 0;
        });
      }
    }
  }

  Future<void> _uploadWebpCopyInBackground({
    required String uid,
    required String paymentGroupId,
    required String imagePath,
  }) async {
    try {
      final webpBytes = await _tryEncodeToWebpBytes(imagePath);
      if (webpBytes == null || webpBytes.isEmpty) {
        return;
      }

      final webpPath = 'shops/$uid/topups/$paymentGroupId/slip.webp';
      await StorageHelper.instance.ref().child(webpPath).putData(
        webpBytes,
        SettableMetadata(contentType: 'image/webp'),
      );

      await _patchTopUpSlipDoc(
        uid: uid,
        paymentGroupId: paymentGroupId,
        patch: <String, dynamic>{
          'webpPath': webpPath,
          'webpContentType': 'image/webp',
          'webpBytes': webpBytes.length,
        },
      );
    } catch (_) {}
  }

  DocumentReference<Map<String, dynamic>> _topUpSlipDocRef({
    required String uid,
    required String paymentGroupId,
  }) {
    return FirebaseFirestore.instance
        .collection('shop_topup_slips')
        .doc(uid)
        .collection('items')
        .doc(paymentGroupId);
  }

  Future<void> _ensureTopUpSlipDocExists({
    required String uid,
    required String paymentGroupId,
    required double expectedAmount,
    required String storagePath,
    required String fileName,
    required String contentType,
    required ImageSource source,
  }) async {
    try {
      final ref = _topUpSlipDocRef(uid: uid, paymentGroupId: paymentGroupId);
      final snap = await ref.get();
      if (snap.exists) {
        return;
      }

      await ref.set(<String, dynamic>{
        'uid': uid,
        'paymentGroupId': paymentGroupId,
        'expectedAmount': expectedAmount,
        'storagePath': storagePath,
        'fileName': fileName,
        'contentType': contentType,
        'source': source.name,
        'status': 'picked',
        'sourceApp': 'van1_merchant',
        'createdAt': FieldValue.serverTimestamp(),
      });
    } catch (_) {}
  }

  Future<void> _patchTopUpSlipDoc({
    required String uid,
    required String paymentGroupId,
    required Map<String, dynamic> patch,
  }) async {
    try {
      final ref = _topUpSlipDocRef(uid: uid, paymentGroupId: paymentGroupId);
      await ref.set(
        <String, dynamic>{
          ...patch,
          'updatedAt': FieldValue.serverTimestamp(),
        },
        SetOptions(merge: true),
      );
    } catch (_) {}
  }

  String _newPaymentGroupId(String uid) {
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final rand = Random().nextInt(999999).toString().padLeft(6, '0');
    return 'shop_topup_${uid}_$stamp$rand';
  }

  String _guessContentType(String fileName) {
    final lower = fileName.toLowerCase();
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.webp')) return 'image/webp';
    return 'image/jpeg';
  }

  Future<Uint8List?> _tryEncodeToWebpBytes(String inputPath) async {
    try {
      return await FlutterImageCompress.compressWithFile(
        inputPath,
        format: CompressFormat.webp,
        quality: 92,
      );
    } catch (_) {
      return null;
    }
  }

  void _showSnack(String message) {
    if (!mounted) return;
    final isSuccess =
        message.contains('เรียบร้อย') ||
        (message.contains('สำเร็จ') && !message.contains('ไม่สำเร็จ'));
    _inlineBannerTimer?.cancel();
    setState(() {
      _inlineBanner = message;
      _inlineBannerSuccess = isSuccess;
    });
    _inlineBannerTimer = Timer(const Duration(seconds: 3), () {
      if (!mounted) return;
      setState(() => _inlineBanner = null);
    });
  }

  void _logTopUpVerify(String message) {
    debugPrint('[TopUpVerify] $message');
  }

  String get _topUpStorageBucket {
    final configured = DefaultFirebaseOptions.currentPlatform.storageBucket?.trim();
    if (configured != null && configured.isNotEmpty) {
      return configured;
    }
    return Firebase.app().options.storageBucket?.trim() ?? '';
  }

  _TopUpGuideStep get _step1State {
    if (_selectedSlipImage != null || _isBusy) {
      return _TopUpGuideStep.done;
    }
    return _TopUpGuideStep.active;
  }

  _TopUpGuideStep get _step2State {
    if (_isBusy && _verifyProgress > 0) {
      return _TopUpGuideStep.processing;
    }
    if (_selectedSlipImage != null) {
      return _TopUpGuideStep.active;
    }
    return _TopUpGuideStep.pending;
  }

  Widget _buildTopUpStepper() {
    return Row(
      children: [
        Expanded(
          child: _buildStepperNode(
            number: 1,
            label: 'สแกนจ่าย',
            state: _step1State,
          ),
        ),
        _buildStepperConnector(_step1State == _TopUpGuideStep.done),
        Expanded(
          child: _buildStepperNode(
            number: 2,
            label: 'แนบสลิป',
            state: _step2State,
          ),
        ),
      ],
    );
  }

  Widget _buildStepperConnector(bool completed) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: SizedBox(
        width: 28,
        child: Divider(
          thickness: 2,
          color: completed ? const Color(0xFF16A34A) : Colors.black26,
        ),
      ),
    );
  }

  Widget _buildStepperNode({
    required int number,
    required String label,
    required _TopUpGuideStep state,
  }) {
    final Color circleColor;
    final Color textColor;
    final Widget? centerChild;

    switch (state) {
      case _TopUpGuideStep.done:
        circleColor = const Color(0xFF16A34A);
        textColor = const Color(0xFF16A34A);
        centerChild = const Icon(Icons.check, color: Colors.white, size: 16);
      case _TopUpGuideStep.active:
        circleColor = const Color(0xFF0E55AA);
        textColor = const Color(0xFF0E55AA);
        centerChild = Text(
          '$number',
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w700,
            fontSize: 12,
          ),
        );
      case _TopUpGuideStep.processing:
        circleColor = const Color(0xFFE95500);
        textColor = const Color(0xFFE95500);
        centerChild = const SizedBox(
          width: 14,
          height: 14,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: Colors.white,
          ),
        );
      case _TopUpGuideStep.pending:
        circleColor = Colors.black26;
        textColor = Colors.black54;
        centerChild = Text(
          '$number',
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w700,
            fontSize: 12,
          ),
        );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(color: circleColor, shape: BoxShape.circle),
          alignment: Alignment.center,
          child: centerChild,
        ),
        const SizedBox(height: 4),
        Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: textColor,
          ),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }

  Widget _buildTopUpWarningBanner() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF7ED),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFFED7AA)),
      ),
      child: const Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline, size: 18, color: Color(0xFFC2410C)),
          SizedBox(width: 8),
          Expanded(
            child: Text(
              'โอนแล้วต้องแนบสลิป — ไม่แนบ = เติมเครดิตยังไม่สำเร็จ',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                height: 1.35,
                color: Color(0xFF9A3412),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStep2SlipSection() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF7ED),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE95500), width: 1.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'ขั้นที่ 2 · แนบสลิป (จำเป็น)',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: const Color(0xFFE95500),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: const Text(
                  'จำเป็นต้องทำ',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'หลังโอนแล้ว แนบสลิปเพื่อยืนยัน — ไม่แนบ = เติมเครดิตยังไม่สำเร็จ',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: const Color(0xFF9A3412),
              height: 1.35,
            ),
          ),
          const SizedBox(height: 10),
          Center(child: _buildSlipPickerPanel()),
          if (_selectedSlipImage == null && !_isBusy)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text(
                'ยังไม่แนบสลิป — การเติมเครดิตยังไม่เสร็จ',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFFC2410C),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildVerifyProgressOverlay() {
    if (_verifyProgress <= 0) {
      return const SizedBox.shrink();
    }

    return Positioned.fill(
      child: ColoredBox(
        color: Colors.white.withValues(alpha: 0.9),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 76,
                height: 76,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    CircularProgressIndicator(
                      strokeWidth: 5,
                      value: _verifyProgress >= 100 ? 1 : null,
                    ),
                    Text(
                      '$_verifyProgress%',
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              const Text(
                'กำลังตรวจสอบสลิป...',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 4),
              Text(
                _verifyProgress < 50
                    ? 'กำลังอัปโหลดสลิป'
                    : 'กำลังตรวจสอบกับระบบ',
                style: const TextStyle(fontSize: 12, color: Colors.black54),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSlipPickerPanel() {
    final enabled = !_isBusy && _canGeneratePromptPayQr;
    final selectedSlipImage = _selectedSlipImage;

    return Container(
      width: 240,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: Colors.black12),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              const Icon(Icons.receipt_long_outlined, size: 20),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'แนบสลิป',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              IconButton(
                tooltip: selectedSlipImage == null
                    ? 'เลือกจากแกลเลอรี'
                    : 'เปลี่ยนรูปสลิป',
                visualDensity: VisualDensity.compact,
                onPressed: enabled ? () => unawaited(_pickSlipImage()) : null,
                icon: const Icon(Icons.photo_library_outlined),
              ),
            ],
          ),
          if (selectedSlipImage != null) ...[
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(
                width: double.infinity,
                height: 140,
                child: Image.file(
                  File(selectedSlipImage.path),
                  fit: BoxFit.cover,
                ),
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: enabled ? _verifySelectedSlip : null,
                child: _isBusy
                    ? const SizedBox(
                        height: 16,
                        width: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text('ส่งสลิปเพื่อตรวจสอบ'),
                      ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final canGenerateQr = _canGeneratePromptPayQr;
    final canConfirmAmount = _canConfirmAmount;
    final qrAmount = _qrAmount;
    final nationalId = _promptPayNationalId;
    final recipientName = _recipientDisplayName ?? 'วิทยา ทนหงษา';
    final maskedPromptPay = nationalId == null
        ? 'PromptPay'
        : PromptPayQrPayload.maskedDisplayLabel(nationalId);
    final amountLabel = (qrAmount ?? 0).toStringAsFixed(2);
    final title = widget.isSecurityDeposit
        ? 'เติมเครดิต — ค่าประกัน'
        : 'เติมเครดิต';

    return AlertDialog(
      backgroundColor: Colors.white,
      surfaceTintColor: Colors.white,
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_inlineBanner != null) ...[
            Material(
              color: _inlineBannerSuccess
                  ? const Color(0xFF15803D)
                  : const Color(0xFFB45309),
              borderRadius: BorderRadius.circular(10),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                child: Text(
                  _inlineBanner!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                    fontSize: 14,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 10),
          ],
          Text(title),
        ],
      ),
      content: SizedBox(
        width: 420,
        child: Stack(
          children: [
            if (_loadingConfig)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Center(child: CircularProgressIndicator()),
              )
            else
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.sizeOf(context).height * 0.72,
                ),
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (widget.isSecurityDeposit) ...[
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: const Color(0xFFFFF7ED),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: const Color(0xFFFED7AA)),
                          ),
                          child: Text(
                            'ชำระค่าประกัน '
                            '${(widget.minimumAmount ?? widget.initialAmount ?? 0).toStringAsFixed(0)} บาท '
                            'ผ่านการเติมเครดิตและตรวจสลิปให้ผ่านก่อนเริ่มอัปโหลดสินค้า',
                            style: const TextStyle(
                              fontWeight: FontWeight.w600,
                              height: 1.4,
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                      ],
                      if (!canGenerateQr) ...[
                        const Text('เลือกจำนวนเงิน'),
                        Text(
                          'สูงสุด ${_maxTopUpAmount.toStringAsFixed(0)} บาทต่อครั้ง · ส่งสลิปได้ไม่เกิน 3 ครั้งต่อวัน',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        const SizedBox(height: 10),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            for (final preset in _presets)
                              ChoiceChip(
                                label: Text(preset.toStringAsFixed(0)),
                                selected: _selectedAmount == preset,
                                onSelected: _isBusy
                                    ? null
                                    : (_) => _selectPreset(preset),
                              ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: _customAmountController,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          enabled: !_isBusy,
                          decoration: InputDecoration(
                            labelText: 'กำหนดเอง',
                            hintText:
                                'เช่น 1500 (สูงสุด ${_maxTopUpAmount.toStringAsFixed(0)})',
                            border: const OutlineInputBorder(),
                          ),
                          onChanged: _onCustomAmountChanged,
                        ),
                        const SizedBox(height: 14),
                        if (canConfirmAmount)
                          SizedBox(
                            width: double.infinity,
                            child: FilledButton(
                              onPressed: _isBusy ? null : _confirmAmount,
                              child: const Text('ยืนยันจำนวนเงิน'),
                            ),
                          )
                        else
                          const Text('กรุณาเลือกจำนวนเงินเพื่อสร้าง QR'),
                      ] else
                        Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _buildTopUpStepper(),
                            const SizedBox(height: 10),
                            _buildTopUpWarningBanner(),
                            const SizedBox(height: 14),
                            const Text(
                              'ขั้นที่ 1 · สแกนจ่าย',
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'เปิดแอปธนาคาร สแกน QR แล้วโอนตามยอดด้านล่าง',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                            const SizedBox(height: 8),
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    'ยอดโอน ${qrAmount!.toStringAsFixed(2)} บาท',
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                                TextButton(
                                  onPressed: _isBusy ? null : _resetConfirmedAmount,
                                  child: const Text('เปลี่ยนจำนวน'),
                                ),
                              ],
                            ),
                            const SizedBox(height: 4),
                            Center(
                              child: RepaintBoundary(
                                key: _qrBoundaryKey,
                                child: Container(
                                  width: 240,
                                  padding: const EdgeInsets.fromLTRB(
                                    14,
                                    8,
                                    14,
                                    14,
                                  ),
                                  decoration: BoxDecoration(
                                    color: Colors.white,
                                    borderRadius: BorderRadius.circular(16),
                                  ),
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Container(
                                        height: 28,
                                        width: double.infinity,
                                        color: const Color(0xFF0E55AA),
                                        alignment: Alignment.center,
                                        child: Image.asset(
                                          'assets/images/thai_qr_payment.png',
                                          package: 'promptpay_qrcode_generate',
                                          height: 22,
                                          fit: BoxFit.contain,
                                        ),
                                      ),
                                      const SizedBox(height: 8),
                                      Image.asset(
                                        'assets/images/prompt_pay_logo.png',
                                        package: 'promptpay_qrcode_generate',
                                        height: 28,
                                        fit: BoxFit.contain,
                                      ),
                                      const SizedBox(height: 10),
                                      SizedBox(
                                        width: 150,
                                        height: 150,
                                        child: Stack(
                                          fit: StackFit.expand,
                                          children: [
                                            Builder(
                                              builder: (context) {
                                                final data =
                                                    _buildPromptPayPayload(
                                                      qrAmount,
                                                    );

                                                if (data == null ||
                                                    data.isEmpty) {
                                                  return const Center(
                                                    child: Text(
                                                      'PromptPay ID ไม่ถูกต้อง',
                                                    ),
                                                  );
                                                }

                                                return QrImageView(
                                                  data: data,
                                                  errorCorrectionLevel:
                                                      QrErrorCorrectLevel.H,
                                                  backgroundColor: Colors.white,
                                                );
                                              },
                                            ),
                                            Positioned.fill(
                                              child: IgnorePointer(
                                                child: Align(
                                                  alignment:
                                                      const Alignment(0, -0.06),
                                                  child: _TrimmedAssetImage(
                                                    assetName: _appLogoAsset,
                                                    size: 16,
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      const SizedBox(height: 10),
                                      Text(
                                        'โอนให้ $recipientName',
                                        style: const TextStyle(
                                          fontSize: 12,
                                          fontWeight: FontWeight.w600,
                                        ),
                                        textAlign: TextAlign.center,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        maskedPromptPay,
                                        style: const TextStyle(
                                          fontSize: 12,
                                          fontWeight: FontWeight.w400,
                                        ),
                                        textAlign: TextAlign.center,
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        'Amount $amountLabel Baht',
                                        style: const TextStyle(
                                          fontSize: 12,
                                          fontWeight: FontWeight.w400,
                                        ),
                                        textAlign: TextAlign.center,
                                        overflow: TextOverflow.ellipsis,
                                        maxLines: 1,
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              'สแกน QR นี้ในแอปธนาคาร แล้วโอนตามยอดที่ยืนยันไว้',
                              style: Theme.of(context).textTheme.bodySmall,
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 16),
                            _buildStep2SlipSection(),
                          ],
                        ),
                    ],
                  ),
                ),
              ),
            _buildVerifyProgressOverlay(),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _isBusy ? null : () => unawaited(_closeWithoutCompleting()),
          child: const Text('ปิด'),
        ),
        FilledButton(
          onPressed: (_isBusy || !canGenerateQr) ? null : _saveQrToGallery,
          child: _isBusy
              ? const SizedBox(
                  height: 16,
                  width: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text('บันทึก QR ลงเครื่อง'),
                ),
        ),
      ],
    );
  }
}

class _TrimInfo {
  const _TrimInfo({required this.image, required this.srcRect});

  final ui.Image image;
  final Rect srcRect;
}

class _TrimmedAssetImage extends StatefulWidget {
  const _TrimmedAssetImage({required this.assetName, required this.size});

  final String assetName;
  final double size;

  @override
  State<_TrimmedAssetImage> createState() => _TrimmedAssetImageState();
}

class _TrimmedAssetImageState extends State<_TrimmedAssetImage> {
  static final Map<String, Future<_TrimInfo>> _cache =
      <String, Future<_TrimInfo>>{};

  late final Future<_TrimInfo> _future =
      _cache[widget.assetName] ??= _loadAndTrim(widget.assetName);

  static Future<_TrimInfo> _loadAndTrim(String assetName) async {
    final byteData = await rootBundle.load(assetName);
    final bytes = byteData.buffer.asUint8List();
    final completer = Completer<ui.Image>();
    ui.decodeImageFromList(bytes, completer.complete);
    final image = await completer.future;

    final raw = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (raw == null) {
      return _TrimInfo(
        image: image,
        srcRect: Rect.fromLTWH(
          0,
          0,
          image.width.toDouble(),
          image.height.toDouble(),
        ),
      );
    }

    final Uint8List data = raw.buffer.asUint8List();
    final int width = image.width;
    final int height = image.height;

    int minX = width;
    int minY = height;
    int maxX = -1;
    int maxY = -1;

    const int alphaThreshold = 12;
    for (int y = 0; y < height; y++) {
      final int rowStart = y * width * 4;
      for (int x = 0; x < width; x++) {
        final int a = data[rowStart + (x * 4) + 3];
        if (a > alphaThreshold) {
          if (x < minX) minX = x;
          if (y < minY) minY = y;
          if (x > maxX) maxX = x;
          if (y > maxY) maxY = y;
        }
      }
    }

    if (maxX < minX || maxY < minY) {
      return _TrimInfo(
        image: image,
        srcRect: Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
      );
    }

    minX = max(0, minX - 1);
    minY = max(0, minY - 1);
    maxX = min(width - 1, maxX + 1);
    maxY = min(height - 1, maxY + 1);

    final srcRect = Rect.fromLTRB(
      minX.toDouble(),
      minY.toDouble(),
      (maxX + 1).toDouble(),
      (maxY + 1).toDouble(),
    );

    return _TrimInfo(image: image, srcRect: srcRect);
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_TrimInfo>(
      future: _future,
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return SizedBox(width: widget.size, height: widget.size);
        }

        final info = snapshot.data!;
        return CustomPaint(
          size: Size(widget.size, widget.size),
          painter: _TrimmedImagePainter(image: info.image, srcRect: info.srcRect),
        );
      },
    );
  }
}

class _TrimmedImagePainter extends CustomPainter {
  const _TrimmedImagePainter({required this.image, required this.srcRect});

  final ui.Image image;
  final Rect srcRect;

  @override
  void paint(Canvas canvas, Size size) {
    final dstRect = Offset.zero & size;
    final paint = Paint()..filterQuality = FilterQuality.high;
    canvas.drawImageRect(image, srcRect, dstRect, paint);
  }

  @override
  bool shouldRepaint(covariant _TrimmedImagePainter oldDelegate) {
    return oldDelegate.image != image || oldDelegate.srcRect != srcRect;
  }
}
