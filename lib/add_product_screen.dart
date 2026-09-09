import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'widgets/cached_app_image.dart';
import 'widgets/product_video_player.dart';
import 'package:image_picker/image_picker.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:video_compress/video_compress.dart';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:http/http.dart' as http;
import '../models/product_model.dart'; // Import the model
import '../models/product_variant.dart';
import 'product_variant_setup_screen.dart';
import 'utils/app_colors.dart';
import 'utils/network_image_url.dart';
import 'utils/shop_profile_resolver.dart';
import 'widgets/product_network_image.dart';
import 'storage_helper.dart';
import 'services/product_cache_service.dart';
import 'services/shop_profile_cache_service.dart';
import 'services/media_cache_service.dart';
import 'services/product_image_upload_web.dart';
import 'services/product_draft_service.dart';
import 'services/product_add_draft_store.dart';
import 'services/product_ai_image_cache.dart';

class _ProductImageUploadResult {
  final String originalUrl;
  final String thumbnailUrl;
  final String? originalLocalPath;
  final String? thumbnailLocalPath;

  const _ProductImageUploadResult({
    required this.originalUrl,
    required this.thumbnailUrl,
    this.originalLocalPath,
    this.thumbnailLocalPath,
  });
}

class _ProductVideoUploadResult {
  final String videoUrl;
  final String? thumbnailUrl;
  final String? localVideoPath;
  final String? localThumbnailPath;

  const _ProductVideoUploadResult({
    required this.videoUrl,
    this.thumbnailUrl,
    this.localVideoPath,
    this.localThumbnailPath,
  });
}

class _AiProductAnalysisResult {
  const _AiProductAnalysisResult({
    this.productName,
    this.description,
    this.taxStatus,
    this.taxReason,
    this.productCategory,
    this.productType,
    this.isLegalInThailand,
    this.legalReason,
    this.isFreshProduct,
    this.isProcessed,
    this.canShipNationwide,
    this.nationwideShippingReason,
    this.productNameConfidence,
    this.taxConfidence,
    this.productTypeConfidence,
    this.nationwideShippingConfidence,
    this.legalConfidence,
    this.parcelLengthCm,
    this.parcelWidthCm,
    this.parcelHeightCm,
    this.parcelDimensionReason,
    this.parcelDimensionConfidence,
    this.saleUnit,
    this.requiresAdminReview,
    this.reviewReasonLabels,
  });

  final String? productName;
  final String? description;
  final String? taxStatus;
  final String? taxReason;
  final String? productCategory;
  final String? productType;
  final bool? isLegalInThailand;
  final String? legalReason;
  final bool? isFreshProduct;
  final bool? isProcessed;
  final bool? canShipNationwide;
  final String? nationwideShippingReason;
  final int? productNameConfidence;
  final int? taxConfidence;
  final int? productTypeConfidence;
  final int? nationwideShippingConfidence;
  final int? legalConfidence;
  final double? parcelLengthCm;
  final double? parcelWidthCm;
  final double? parcelHeightCm;
  final String? parcelDimensionReason;
  final int? parcelDimensionConfidence;
  final String? saleUnit;
  final bool? requiresAdminReview;
  final List<String>? reviewReasonLabels;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'productName': productName,
      'description': description,
      'taxStatus': taxStatus,
      'taxReason': taxReason,
      'productCategory': productCategory,
      'productType': productType,
      'isLegalInThailand': isLegalInThailand,
      'legalReason': legalReason,
      'isFreshProduct': isFreshProduct,
      'isProcessed': isProcessed,
      'canShipNationwide': canShipNationwide,
      'nationwideShippingReason': nationwideShippingReason,
      'productNameConfidence': productNameConfidence,
      'taxConfidence': taxConfidence,
      'productTypeConfidence': productTypeConfidence,
      'nationwideShippingConfidence': nationwideShippingConfidence,
      'legalConfidence': legalConfidence,
      'parcelLengthCm': parcelLengthCm,
      'parcelWidthCm': parcelWidthCm,
      'parcelHeightCm': parcelHeightCm,
      'parcelDimensionReason': parcelDimensionReason,
      'parcelDimensionConfidence': parcelDimensionConfidence,
      'saleUnit': saleUnit,
      'requiresAdminReview': requiresAdminReview,
      if (reviewReasonLabels != null) 'reviewReasonLabels': reviewReasonLabels,
    };
  }
}

/// แอดมิน (van4) อัปโหลดสินค้าแทนร้าน — ใช้ UI เดียวกับฝั่งร้านค้า
class AdminProductUploadContext {
  const AdminProductUploadContext({
    required this.ownerUid,
    required this.shopName,
    required this.serviceType,
  });

  final String ownerUid;
  final String shopName;
  final String serviceType;
}

class AddProductScreen extends StatefulWidget {
  final Product? productToEdit;
  final AdminProductUploadContext? adminUploadContext;
  final String? draftId;

  const AddProductScreen({
    super.key,
    this.productToEdit,
    this.adminUploadContext,
    this.draftId,
  });

  @override
  AddProductScreenState createState() => AddProductScreenState();
}

class AddProductScreenState extends State<AddProductScreen>
    with WidgetsBindingObserver {
  static const double _gpRate = 0.18;
  static const int _kAiConfidenceThreshold = 80;
  static const Duration _aiCallableTimeout = Duration(seconds: 120);

  bool get _isAdminDelegatedUpload => widget.adminUploadContext != null;

  /// Merchant editing an already-listed product (not admin delegated upload).
  bool get _isEditingExistingProduct =>
      widget.productToEdit != null && !_isAdminDelegatedUpload;

  bool get _draftPersistenceEnabled =>
      widget.productToEdit == null && !_isAdminDelegatedUpload;

  String? get _effectiveOwnerUid =>
      widget.adminUploadContext?.ownerUid ??
      FirebaseAuth.instance.currentUser?.uid;

  // Controllers to get text from TextFields
  final _nameController = TextEditingController();
  final _descriptionController = TextEditingController();
  final _productDescriptionController = TextEditingController();
  final _priceController = TextEditingController();
  final _stockController = TextEditingController();
  final _preparationTimeController = TextEditingController(text: '10');
  final _colorsController = TextEditingController();
  final _sizesController = TextEditingController();
  final _weightController = TextEditingController();
  final _parcelLengthController = TextEditingController();
  final _parcelWidthController = TextEditingController();
  final _parcelHeightController = TextEditingController();
  final FocusNode _priceFocusNode = FocusNode();
  final FocusNode _toppingsFocusNode = FocusNode();
  String _weightUnit = 'g';
  final _otherUnitController = TextEditingController();

  final ImagePicker _picker = ImagePicker();
  List<String> _existingImageUrls = [];
  List<String> _existingThumbnailUrls = [];
  final List<XFile> _newImageFiles = [];
  XFile? _videoFile;
  String? _existingVideoUrl;
  String? _existingVideoThumbnailUrl;
  final Map<String, String> _localMediaPaths = {};
  final Set<String> _cacheLookupInProgress = {};

  bool _isSaving = false;
  bool _isResolvingServiceType = true;
  bool _showPriceGuidance = false;
  bool _showPreparationTimeGuidance = false;
  bool _showToppingsGuidance = false;
  bool _priceGuidanceDismissedWhileFocused = false;
  bool _isGeneratingAiDescription = false;
  bool _isAnalyzingProductWithAi = false;
  bool _isCompressingVideo = false;
  bool _hasVariants = false;
  List<ProductVariantDraft> _variantDrafts = <ProductVariantDraft>[];
  List<ProductVariant> _productVariants = <ProductVariant>[];

  bool _hasUsedAiDescriptionForProduct = false;
  bool _hasUsedAiProductAnalysisForProduct = false;
  String? _aiTaxAnalysisReason;
  bool _hasAiTaxAnalysis = false;
  bool? _aiIsLegalInThailand;
  String? _aiLegalAnalysisReason;
  String? _aiProductType;
  bool? _aiCanShipNationwide;
  String? _aiNationwideShippingReason;
  String? _aiParcelDimensionReason;
  int? _aiProductNameConfidence;
  int? _aiTaxConfidence;
  int? _aiProductTypeConfidence;
  int? _aiNationwideShippingConfidence;
  int? _aiLegalConfidence;
  bool? _aiRequiresAdminReview;
  List<String> _aiReviewReasonLabels = <String>[];
  bool _manualCanShipNationwide = false;
  String? _acceptedAiRequestId;
  int _aiAnalysisEpoch = 0;
  bool _aiAnalysisDiscarded = false;
  bool _aiAppliedSaleUnit = false;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>?
  _aiQueueSubscription;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>?
  _draftWatchSubscription;
  Timer? _draftSaveDebounce;
  bool _draftRestoreComplete = false;
  bool _draftSessionClosed = false;
  Future<void>? _draftSessionFuture;
  String? _activeDraftId;
  String? _aiQueueStatusText;
  bool _aiQueueExternalRecommendation = false;
  double? _uploadProgress;
  String? _uploadStatusText;

  static const int _defaultMaxImageCount = 1;
  static const Duration _maxVideoDuration = Duration(minutes: 5);
  static const int _videoMaxEdgePx = 720;
  int? _adminMaxImageCount;
  bool? _adminCanUploadVideo;
  static const int _pickerImageQuality = 75;
  static const int _uploadImageQuality = 78;
  static const int _thumbnailImageQuality = 60;
  String? _serviceType;

  int get _currentImageCount =>
      _existingImageUrls.length + _newImageFiles.length;
  bool get _canAddVideo => _adminCanUploadVideo == true;

  int get _maxImageCount {
    if (_adminMaxImageCount != null && _adminMaxImageCount! > 0) {
      return _adminMaxImageCount!;
    }
    return _defaultMaxImageCount;
  }

  bool get _usesFirstImageAiGate =>
      _maxImageCount > 1 && !_isAdminDelegatedUpload;

  bool get _canAddAdditionalImages {
    if (!_usesFirstImageAiGate) {
      return true;
    }
    return _hasUsedAiProductAnalysisForProduct;
  }

  bool get _canPickMoreImages {
    if (_currentImageCount >= _maxImageCount) {
      return false;
    }
    if (_currentImageCount == 0) {
      return true;
    }
    return _canAddAdditionalImages && !_isAnalyzingProductWithAi;
  }

  bool get _canPickVideoNow {
    if (!_canAddVideo || _isCompressingVideo) {
      return false;
    }
    if (!_usesFirstImageAiGate) {
      return true;
    }
    return _currentImageCount > 0 && _canAddAdditionalImages;
  }

  String? get _imagePickBlockedReason {
    if (_currentImageCount >= _maxImageCount) {
      return 'ใส่รูปได้สูงสุด $_maxImageCount รูป';
    }
    if (_usesFirstImageAiGate &&
        _currentImageCount > 0 &&
        !_canAddAdditionalImages) {
      if (_isAnalyzingProductWithAi) {
        return 'กำลังให้ AI วิเคราะห์รูปแรก — รอสักครู่แล้วค่อยเพิ่มรูป 2–$_maxImageCount';
      }
      return 'อัปโหลดรูปแรกแล้วให้ AI วิเคราะห์เสร็จก่อน จึงจะเพิ่มรูป 2–$_maxImageCount ได้';
    }
    if (_isAnalyzingProductWithAi) {
      return 'กำลังให้ AI วิเคราะห์รูปแรก — รอสักครู่แล้วค่อยเพิ่มรูป';
    }
    return null;
  }

  String? get _videoPickBlockedReason {
    if (!_canAddVideo) {
      return 'แอดมินไม่อนุญาตให้อัปโหลดวิดีโอสำหรับร้านนี้';
    }
    if (_usesFirstImageAiGate && _currentImageCount == 0) {
      return 'อัปโหลดรูปแรกและให้ AI วิเคราะห์เสร็จก่อน จึงจะเพิ่มวิดีโอได้';
    }
    if (_usesFirstImageAiGate && !_canAddAdditionalImages) {
      return 'ให้ AI วิเคราะห์รูปแรกเสร็จก่อน จึงจะเพิ่มวิดีโอได้';
    }
    return null;
  }

  String? _mediaLimitHintText() {
    if (_isResolvingServiceType) {
      return 'กำลังตรวจสอบสิทธิ์การอัปโหลดรูปและวิดีโอ';
    }
    if (_maxImageCount == 1 && !_canAddVideo) {
      return 'อัปโหลดรูปได้ 1 รูป — วิดีโอและรูปเพิ่มต้องให้แอดมินอนุญาตก่อน';
    }
    if (_usesFirstImageAiGate) {
      if (_currentImageCount == 0) {
        return 'อัปโหลดรูปแรกก่อน เพื่อให้ AI วิเคราะห์ จากนั้นจึงเพิ่มรูป 2–$_maxImageCount${_canAddVideo ? ' และวิดีโอ' : ''}ได้';
      }
      if (!_canAddAdditionalImages) {
        return _isAnalyzingProductWithAi
            ? 'กำลังให้ AI วิเคราะห์รูปแรก...'
            : 'ให้ AI วิเคราะห์รูปแรกเสร็จก่อน จึงเพิ่มรูป${_canAddVideo ? 'หรือวิดีโอ' : ''}เพิ่มได้';
      }
      final videoHint = _canAddVideo ? ' และวิดีโอ 1 คลิป (บีบอัด 720p)' : '';
      return 'แอดมินอนุญาต: รูปได้สูงสุด $_maxImageCount รูป$videoHint';
    }
    if (_canAddVideo) {
      return 'แอดมินอนุญาตอัปโหลดวิดีโอ (บีบอัด 720p)';
    }
    return null;
  }

  String? _selectedUnit = 'ชิ้น';
  final List<String> _units = [
    'ชิ้น',
    'ถุง',
    'แพ็ค',
    'มัด',
    'ลูก',
    'กล่อง',
    'อื่นๆ',
  ];
  String? _selectedProductCategory;
  bool _isFreshProduct = false;
  bool _isProcessed = false;
  bool _pharmacyIsTaxable = true;
  final List<String> _productCategories = [
    'ของสด',
    'อาหารแปรรูป',
    'สินค้าทั่วไป',
    'ร้านขายยาและเวชภัณฑ์',
    'สินค้าเกษตร',
  ];

  @override
  void initState() {
    super.initState();
    _priceFocusNode.addListener(() {
      if (!mounted) return;
      setState(() {
        if (_priceFocusNode.hasFocus) {
          _showPriceGuidance = !_priceGuidanceDismissedWhileFocused;
          _showToppingsGuidance = false;
        } else {
          _priceGuidanceDismissedWhileFocused = false;
          _showPriceGuidance = false;
        }
      });
    });
    _toppingsFocusNode.addListener(() {
      if (!mounted) return;
      setState(() {
        _showToppingsGuidance = _toppingsFocusNode.hasFocus;
        if (_toppingsFocusNode.hasFocus) {
          _showPriceGuidance = false;
          _showPreparationTimeGuidance = false;
        }
      });
    });
    if (widget.adminUploadContext != null) {
      _serviceType = widget.adminUploadContext!.serviceType;
      _isResolvingServiceType = false;
    } else {
      _loadCurrentServiceType();
    }
    unawaited(_loadAdminMediaSettings());
    if (widget.productToEdit != null) {
      final p = widget.productToEdit!;
      _nameController.text = p.name;
      _productDescriptionController.text = p.description;
      final existingToppings = p.toppings?.trim();
      // Fall back to the old description value if this product was created before toppings existed.
      _descriptionController.text =
          (existingToppings != null && existingToppings.isNotEmpty)
          ? existingToppings
          : p.description;
      _priceController.text = p.price.toString();
      _stockController.text = p.stock.toString();
      _preparationTimeController.text = p.preparationTimeMinutes.toString();
      _colorsController.text = p.colors.join(', ');
      _sizesController.text = p.sizes.join(', ');
      _applyWeightFromStoredValue(p.weight);
      _parcelLengthController.text = p.parcelLengthCm?.toString() ?? '';
      _parcelWidthController.text = p.parcelWidthCm?.toString() ?? '';
      _parcelHeightController.text = p.parcelHeightCm?.toString() ?? '';
      _selectedUnit = _units.contains(p.unit) ? p.unit : 'อื่นๆ';
      if (_selectedUnit == 'อื่นๆ') _otherUnitController.text = p.unit;
      _selectedProductCategory = _productCategories.contains(p.productCategory)
          ? p.productCategory
          : null;
      _isFreshProduct = p.isFreshProduct;
      _isProcessed = p.isProcessed;
      _pharmacyIsTaxable = p.taxStatus != 'exempt';
      _hasUsedAiDescriptionForProduct = p.aiDescriptionRequested;
      _hasUsedAiProductAnalysisForProduct = _productHasCompletedAiAnalysis(p);
      _aiTaxAnalysisReason = p.taxAiReason;
      _hasAiTaxAnalysis = (p.taxAiReason ?? '').trim().isNotEmpty;
      _aiIsLegalInThailand = p.aiIsLegalInThailand;
      _aiLegalAnalysisReason = p.aiLegalAnalysisReason;
      _aiProductType = p.aiProductType;
      _aiCanShipNationwide = p.canShipNationwide;
      _aiNationwideShippingReason = p.nationwideShippingReason;
      _manualCanShipNationwide = p.canShipNationwide ?? false;
      _existingImageUrls = List<String>.from(p.imageUrls);
      _existingThumbnailUrls = p.thumbnailUrls.isNotEmpty
          ? List<String>.from(p.thumbnailUrls)
          : List<String>.from(p.imageUrls);
      _existingVideoUrl = p.videoUrl;
      _existingVideoThumbnailUrl = p.videoThumbnailUrl;
      _prefetchExistingMedia();
      unawaited(_hydrateWeightFromFirestore());
      unawaited(_loadVariantsForEdit());
    } else if (_draftPersistenceEnabled) {
      WidgetsBinding.instance.addObserver(this);
      _draftSessionFuture = _initializeDraftSession();
    }

    final ownerUid = _effectiveOwnerUid;
    if (ownerUid != null && ownerUid.isNotEmpty) {
      unawaited(_backfillProductActiveFieldsForOwner(ownerUid));
    }
  }

  Future<void> _ensureDraftReadyForAi() async {
    if (!_draftPersistenceEnabled) {
      return;
    }
    final initFuture = _draftSessionFuture;
    if (initFuture != null) {
      await initFuture;
    }
    if (_activeDraftId == null || _activeDraftId!.isEmpty) {
      throw Exception('ไม่พบ draft session สำหรับ AI');
    }
  }

  void _attachDraftFieldListeners() {
    if (!_draftPersistenceEnabled) return;
    final controllers = <TextEditingController>[
      _nameController,
      _descriptionController,
      _productDescriptionController,
      _priceController,
      _stockController,
      _preparationTimeController,
      _colorsController,
      _sizesController,
      _weightController,
      _parcelLengthController,
      _parcelWidthController,
      _parcelHeightController,
      _otherUnitController,
    ];
    for (final controller in controllers) {
      controller.addListener(_markDraftDirty);
    }
  }

  void _markDraftDirty() {
    if (!_draftPersistenceEnabled ||
        !_draftRestoreComplete ||
        _draftSessionClosed) {
      return;
    }
    _scheduleDraftSave();
  }

  void _scheduleDraftSave() {
    if (!_draftPersistenceEnabled ||
        !_draftRestoreComplete ||
        _draftSessionClosed) {
      return;
    }
    _draftSaveDebounce?.cancel();
    _draftSaveDebounce = Timer(const Duration(milliseconds: 900), () {
      unawaited(_persistDraftNow());
    });
  }

  Future<void> _initializeDraftSession() async {
    final ownerUid = _effectiveOwnerUid;
    if (ownerUid == null || ownerUid.isEmpty) {
      _draftRestoreComplete = true;
      return;
    }

    final localDraft = await ProductAddDraftStore.instance.load(ownerUid);
    var draftId = widget.draftId?.trim();
    if (draftId == null || draftId.isEmpty) {
      draftId = (localDraft?['draftId'] as String?)?.trim();
    }
    draftId = (draftId == null || draftId.isEmpty)
        ? ProductAddDraftStore.instance.createDraftId(ownerUid)
        : draftId;
    _activeDraftId = draftId;

    Map<String, dynamic>? remoteDraft;
    try {
      remoteDraft = await ProductDraftService.instance.loadDraft(
        ownerUid: ownerUid,
        draftId: draftId,
      );
    } catch (error) {
      debugPrint('Failed to load remote product draft: $error');
    }

    if (_isDraftCompleted(localDraft) || _isDraftCompleted(remoteDraft)) {
      await ProductAddDraftStore.instance.clear(ownerUid);
      if (draftId.isNotEmpty) {
        try {
          await ProductDraftService.instance.deleteDraft(
            ownerUid: ownerUid,
            draftId: draftId,
          );
        } catch (error) {
          debugPrint('Failed to delete completed remote draft: $error');
        }
        await ProductAddDraftStore.instance.deleteDraftMediaDir(
          ownerUid: ownerUid,
          draftId: draftId,
        );
      }
      draftId = ProductAddDraftStore.instance.createDraftId(ownerUid);
      _activeDraftId = draftId;
    } else {
      final merged = _mergeDraftSources(local: localDraft, remote: remoteDraft);
      if (merged != null && mounted) {
        await _applyDraftState(merged);
      }
    }

    if (!mounted) return;
    _draftRestoreComplete = true;
    _attachDraftFieldListeners();
    _startDraftWatch();
    unawaited(_persistDraftNow());
  }

  bool _isDraftCompleted(Map<String, dynamic>? draft) {
    return (draft?['productSaveStatus'] as String?)?.trim() == 'completed';
  }

  Map<String, dynamic>? _mergeDraftSources({
    Map<String, dynamic>? local,
    Map<String, dynamic>? remote,
  }) {
    if (_isDraftCompleted(local) || _isDraftCompleted(remote)) {
      return null;
    }
    if (local == null && remote == null) {
      return null;
    }
    if (local == null) {
      return Map<String, dynamic>.from(remote!);
    }
    if (remote == null) {
      return Map<String, dynamic>.from(local);
    }

    final localSavedAt = local['savedAtMillis'] is num
        ? (local['savedAtMillis'] as num).toInt()
        : 0;
    final remoteUpdatedAt = remote['updatedAt'];
    var remoteMillis = 0;
    if (remoteUpdatedAt is Timestamp) {
      remoteMillis = remoteUpdatedAt.millisecondsSinceEpoch;
    } else if (remote['expiresAtMillis'] is num) {
      remoteMillis = (remote['expiresAtMillis'] as num).toInt();
    }

    final merged = Map<String, dynamic>.from(
      remoteMillis >= localSavedAt ? remote : local,
    );
    merged.addAll(local);
    merged.addAll(remote);
    return merged;
  }

  Future<void> _applyDraftState(Map<String, dynamic> draft) async {
    if (_isDraftCompleted(draft)) {
      return;
    }

    void setText(TextEditingController controller, Object? value) {
      final text = value?.toString() ?? '';
      if (text.isNotEmpty) {
        controller.text = text;
      }
    }

    setText(_nameController, draft['name']);
    setText(_descriptionController, draft['toppings']);
    setText(_productDescriptionController, draft['productDescription']);
    setText(_priceController, draft['price']);
    setText(_stockController, draft['stock']);
    setText(_preparationTimeController, draft['preparationTime']);
    setText(_colorsController, draft['colors']);
    setText(_sizesController, draft['sizes']);
    setText(_weightController, draft['weight']);
    setText(_parcelLengthController, draft['parcelLengthCm']);
    setText(_parcelWidthController, draft['parcelWidthCm']);
    setText(_parcelHeightController, draft['parcelHeightCm']);

    final unit = (draft['unit'] as String?)?.trim();
    if (unit != null && unit.isNotEmpty) {
      if (_units.contains(unit)) {
        _selectedUnit = unit;
        _otherUnitController.clear();
      } else {
        _selectedUnit = 'อื่นๆ';
        _otherUnitController.text = unit;
      }
    }

    final weightUnit = (draft['weightUnit'] as String?)?.trim();
    if (weightUnit == 'kg' || weightUnit == 'g') {
      _weightUnit = weightUnit!;
    }

    final category = (draft['productCategory'] as String?)?.trim();
    if (category != null &&
        category.isNotEmpty &&
        _productCategories.contains(category)) {
      _selectedProductCategory = category;
    }

    _isFreshProduct = draft['isFreshProduct'] == true;
    _isProcessed = draft['isProcessed'] == true;
    _pharmacyIsTaxable = draft['pharmacyIsTaxable'] != false;
    _manualCanShipNationwide = draft['manualCanShipNationwide'] == true;
    _hasUsedAiDescriptionForProduct =
        draft['hasUsedAiDescriptionForProduct'] == true;
    _hasUsedAiProductAnalysisForProduct =
        draft['hasUsedAiProductAnalysisForProduct'] == true;
    _hasAiTaxAnalysis = draft['hasAiTaxAnalysis'] == true;
    _aiTaxAnalysisReason = (draft['aiTaxAnalysisReason'] as String?)?.trim();
    _aiIsLegalInThailand = draft['aiIsLegalInThailand'] is bool
        ? draft['aiIsLegalInThailand'] as bool
        : null;
    _aiLegalAnalysisReason = (draft['aiLegalAnalysisReason'] as String?)
        ?.trim();
    _aiProductType = (draft['aiProductType'] as String?)?.trim();
    _aiCanShipNationwide = draft['aiCanShipNationwide'] is bool
        ? draft['aiCanShipNationwide'] as bool
        : null;
    _aiNationwideShippingReason =
        (draft['aiNationwideShippingReason'] as String?)?.trim();
    _aiParcelDimensionReason = (draft['aiParcelDimensionReason'] as String?)
        ?.trim();
    _aiProductNameConfidence = draft['aiProductNameConfidence'] is num
        ? (draft['aiProductNameConfidence'] as num).toInt()
        : null;
    _aiTaxConfidence = draft['aiTaxConfidence'] is num
        ? (draft['aiTaxConfidence'] as num).toInt()
        : null;
    _aiProductTypeConfidence = draft['aiProductTypeConfidence'] is num
        ? (draft['aiProductTypeConfidence'] as num).toInt()
        : null;
    _aiNationwideShippingConfidence =
        draft['aiNationwideShippingConfidence'] is num
        ? (draft['aiNationwideShippingConfidence'] as num).toInt()
        : null;
    _aiLegalConfidence = draft['aiLegalConfidence'] is num
        ? (draft['aiLegalConfidence'] as num).toInt()
        : null;
    _aiRequiresAdminReview = draft['aiRequiresAdminReview'] is bool
        ? draft['aiRequiresAdminReview'] as bool
        : null;
    _hasVariants = draft['hasVariants'] == true;
    final variantDraftsRaw = draft['variantDrafts'];
    if (variantDraftsRaw is List) {
      _variantDrafts = variantDraftsRaw
          .whereType<Map>()
          .map(
            (entry) =>
                ProductVariantDraft.fromJson(Map<String, dynamic>.from(entry)),
          )
          .toList(growable: true);
    }
    final reviewLabels = draft['aiReviewReasonLabels'];
    if (reviewLabels is List) {
      _aiReviewReasonLabels = reviewLabels
          .map((entry) => entry?.toString().trim() ?? '')
          .where((entry) => entry.isNotEmpty)
          .toList();
    }

    final existingImages = draft['existingImageUrls'];
    if (existingImages is List) {
      _existingImageUrls = existingImages
          .map((entry) => entry?.toString().trim() ?? '')
          .where((entry) => entry.isNotEmpty)
          .toList();
    }
    final existingThumbs = draft['existingThumbnailUrls'];
    if (existingThumbs is List) {
      _existingThumbnailUrls = existingThumbs
          .map((entry) => entry?.toString().trim() ?? '')
          .where((entry) => entry.isNotEmpty)
          .toList();
    } else if (_existingImageUrls.isNotEmpty) {
      _existingThumbnailUrls = List<String>.from(_existingImageUrls);
    }

    final imageUrl = (draft['imageUrl'] as String?)?.trim();
    if (imageUrl != null &&
        imageUrl.isNotEmpty &&
        !_existingImageUrls.contains(imageUrl)) {
      _existingImageUrls = <String>[imageUrl];
      final thumbUrl = (draft['thumbnailUrl'] as String?)?.trim();
      _existingThumbnailUrls = <String>[
        thumbUrl != null && thumbUrl.isNotEmpty ? thumbUrl : imageUrl,
      ];
    }

    _existingVideoUrl = (draft['existingVideoUrl'] as String?)?.trim();
    _existingVideoThumbnailUrl = (draft['existingVideoThumbnailUrl'] as String?)
        ?.trim();

    final localImagePaths = draft['localImagePaths'];
    if (localImagePaths is List) {
      final restoredImages = <XFile>[];
      for (var index = 0; index < localImagePaths.length; index++) {
        final path = localImagePaths[index]?.toString().trim() ?? '';
        if (path.isEmpty) continue;
        if (kIsWeb) {
          restoredImages.add(XFile(path));
          continue;
        }
        if (await File(path).exists()) {
          restoredImages.add(XFile(path));
        }
      }
      _newImageFiles
        ..clear()
        ..addAll(restoredImages);
    }

    final localVideoPath = (draft['localVideoPath'] as String?)?.trim();
    if (localVideoPath != null && localVideoPath.isNotEmpty) {
      if (kIsWeb || await File(localVideoPath).exists()) {
        _videoFile = XFile(
          localVideoPath,
          name: (draft['pendingVideoName'] as String?)?.trim() ?? '',
        );
      }
    }

    final videoCompressStatus = (draft['videoCompressStatus'] as String?)
        ?.trim();
    if (videoCompressStatus == 'compressing' && _videoFile != null) {
      _isCompressingVideo = true;
      _uploadStatusText = 'กำลังบีบอัดวิดีโอ (720p)...';
      unawaited(_finishVideoCompression(_videoFile!));
    }

    final productSaveStatus = (draft['productSaveStatus'] as String?)?.trim();
    if (productSaveStatus == 'saving') {
      unawaited(_persistDraftPatch({'productSaveStatus': null}));
    }

    final restoredAiRequestId = (draft['aiRequestId'] as String?)?.trim();
    if (restoredAiRequestId != null && restoredAiRequestId.isNotEmpty) {
      _acceptedAiRequestId = restoredAiRequestId;
    }

    final aiStatus = (draft['aiStatus'] as String?)?.trim();
    if (aiStatus == 'queued' || aiStatus == 'processing') {
      _isAnalyzingProductWithAi = true;
      _aiQueueStatusText = aiStatus == 'processing'
          ? 'ถึงคิวแล้ว กำลังประมวลผล AI...'
          : 'กำลังรอคิว AI...';
    } else if (aiStatus == 'failed') {
      _isAnalyzingProductWithAi = false;
      _hasUsedAiProductAnalysisForProduct = false;
      _aiQueueStatusText =
          (draft['aiError'] as String?)?.trim().isNotEmpty == true
          ? (draft['aiError'] as String).trim()
          : 'AI ประมวลผลไม่สำเร็จ';
    }

    final aiResult = draft['aiResult'];
    if (aiResult is Map &&
        (aiStatus == 'completed' || _hasUsedAiProductAnalysisForProduct)) {
      _applyAiProductAnalysis(_aiResultFromDynamicMap(aiResult));
      _hasUsedAiProductAnalysisForProduct = true;
      _isAnalyzingProductWithAi = false;
    }

    if (mounted) {
      setState(() {});
    }
    if (_existingImageUrls.isNotEmpty || _existingVideoUrl != null) {
      _prefetchExistingMedia();
    }
  }

  Map<String, dynamic> _buildDraftPayload() {
    final resolvedUnit = _selectedUnit == 'อื่นๆ'
        ? _otherUnitController.text.trim()
        : (_selectedUnit ?? '').trim();
    return <String, dynamic>{
      'draftId': _activeDraftId,
      'name': _nameController.text.trim(),
      'toppings': _descriptionController.text.trim(),
      'productDescription': _productDescriptionController.text.trim(),
      'price': _priceController.text.trim(),
      'stock': _stockController.text.trim(),
      'preparationTime': _preparationTimeController.text.trim(),
      'colors': _colorsController.text.trim(),
      'sizes': _sizesController.text.trim(),
      'weight': _weightController.text.trim(),
      'weightUnit': _weightUnit,
      'parcelLengthCm': _parcelLengthController.text.trim(),
      'parcelWidthCm': _parcelWidthController.text.trim(),
      'parcelHeightCm': _parcelHeightController.text.trim(),
      'unit': resolvedUnit,
      'productCategory': _selectedProductCategory,
      'isFreshProduct': _isFreshProduct,
      'isProcessed': _isProcessed,
      'pharmacyIsTaxable': _pharmacyIsTaxable,
      'manualCanShipNationwide': _manualCanShipNationwide,
      'hasUsedAiDescriptionForProduct': _hasUsedAiDescriptionForProduct,
      'hasUsedAiProductAnalysisForProduct': _hasUsedAiProductAnalysisForProduct,
      'hasAiTaxAnalysis': _hasAiTaxAnalysis,
      'aiTaxAnalysisReason': _aiTaxAnalysisReason,
      'aiIsLegalInThailand': _aiIsLegalInThailand,
      'aiLegalAnalysisReason': _aiLegalAnalysisReason,
      'aiProductType': _aiProductType,
      'aiCanShipNationwide': _aiCanShipNationwide,
      'aiNationwideShippingReason': _aiNationwideShippingReason,
      'aiParcelDimensionReason': _aiParcelDimensionReason,
      'aiProductNameConfidence': _aiProductNameConfidence,
      'aiTaxConfidence': _aiTaxConfidence,
      'aiProductTypeConfidence': _aiProductTypeConfidence,
      'aiNationwideShippingConfidence': _aiNationwideShippingConfidence,
      'aiLegalConfidence': _aiLegalConfidence,
      'aiRequiresAdminReview': _aiRequiresAdminReview,
      if (_aiReviewReasonLabels.isNotEmpty)
        'aiReviewReasonLabels': _aiReviewReasonLabels,
      'hasVariants': _hasVariants,
      if (_variantDrafts.isNotEmpty)
        'variantDrafts': _variantDrafts.map((d) => d.toJson()).toList(),
      'existingImageUrls': _existingImageUrls,
      'existingThumbnailUrls': _existingThumbnailUrls,
      'existingVideoUrl': _existingVideoUrl,
      'existingVideoThumbnailUrl': _existingVideoThumbnailUrl,
      'localImagePaths': _newImageFiles.map((file) => file.path).toList(),
      'localVideoPath': _videoFile?.path,
      'isAnalyzingProductWithAi': _isAnalyzingProductWithAi,
      if (_isCompressingVideo) 'videoCompressStatus': 'compressing',
      if (_isSaving) 'productSaveStatus': 'saving',
    };
  }

  Future<void> _persistDraftPatch(Map<String, dynamic> patch) async {
    if (!_draftPersistenceEnabled || _draftSessionClosed) {
      return;
    }
    final ownerUid = _effectiveOwnerUid;
    final draftId = _activeDraftId;
    if (ownerUid == null || ownerUid.isEmpty || draftId == null) {
      return;
    }

    final existing =
        await ProductAddDraftStore.instance.load(ownerUid) ??
        <String, dynamic>{};
    final merged = <String, dynamic>{
      ...existing,
      ..._buildDraftPayload(),
      ...patch,
      'draftId': draftId,
    };

    try {
      await ProductAddDraftStore.instance.save(ownerUid, merged);
      await ProductDraftService.instance.upsertDraft(
        ownerUid: ownerUid,
        draftId: draftId,
        patch: merged,
      );
    } catch (error) {
      debugPrint('Failed to persist product draft patch: $error');
    }
  }

  Future<void> _persistDraftNow() async {
    if (!_draftPersistenceEnabled ||
        !_draftRestoreComplete ||
        _draftSessionClosed) {
      return;
    }
    final ownerUid = _effectiveOwnerUid;
    final draftId = _activeDraftId;
    if (ownerUid == null || ownerUid.isEmpty || draftId == null) {
      return;
    }

    final payload = _buildDraftPayload();
    final persistedImagePaths = <String>[];
    for (var index = 0; index < _newImageFiles.length; index++) {
      final file = _newImageFiles[index];
      final persisted = await ProductAddDraftStore.instance.persistMediaFile(
        sourcePath: file.path,
        ownerUid: ownerUid,
        draftId: draftId,
        fileName:
            'image_$index.${_extensionFromPath(file.path, fallback: 'jpg')}',
      );
      if (persisted != null && persisted.isNotEmpty) {
        persistedImagePaths.add(persisted);
      }
    }
    if (persistedImagePaths.isNotEmpty) {
      payload['localImagePaths'] = persistedImagePaths;
    }

    final videoPath = _videoFile?.path;
    if (videoPath != null && videoPath.isNotEmpty) {
      final persistedVideo = await ProductAddDraftStore.instance
          .persistMediaFile(
            sourcePath: videoPath,
            ownerUid: ownerUid,
            draftId: draftId,
            fileName: 'video.${_extensionFromPath(videoPath, fallback: 'mp4')}',
          );
      if (persistedVideo != null && persistedVideo.isNotEmpty) {
        payload['localVideoPath'] = persistedVideo;
      }
    }

    try {
      await ProductAddDraftStore.instance.save(ownerUid, payload);
      await ProductDraftService.instance.upsertDraft(
        ownerUid: ownerUid,
        draftId: draftId,
        patch: payload,
      );
    } catch (error) {
      debugPrint('Failed to persist product draft: $error');
    }
  }

  Future<void> _clearDraftSession() async {
    final ownerUid = _effectiveOwnerUid;
    final draftId = _activeDraftId;
    if (ownerUid == null || ownerUid.isEmpty) return;

    await ProductAddDraftStore.instance.clear(ownerUid);
    if (draftId != null && draftId.isNotEmpty) {
      try {
        await ProductDraftService.instance.deleteDraft(
          ownerUid: ownerUid,
          draftId: draftId,
        );
      } catch (error) {
        debugPrint('Failed to delete remote product draft: $error');
      }
      await ProductAddDraftStore.instance.deleteDraftMediaDir(
        ownerUid: ownerUid,
        draftId: draftId,
      );
    }
    _activeDraftId = null;
  }

  Future<void> _closeDraftSessionPermanently({String? savedProductId}) async {
    if (!_draftPersistenceEnabled || _draftSessionClosed) {
      return;
    }

    _draftSaveDebounce?.cancel();
    _draftSaveDebounce = null;
    _draftWatchSubscription?.cancel();
    _draftWatchSubscription = null;
    _draftSessionClosed = true;
    _draftRestoreComplete = false;

    final ownerUid = _effectiveOwnerUid;
    final draftId = _activeDraftId;
    if (ownerUid != null &&
        ownerUid.isNotEmpty &&
        draftId != null &&
        draftId.isNotEmpty) {
      final completionMarker = <String, dynamic>{
        'productSaveStatus': 'completed',
        if (savedProductId != null && savedProductId.isNotEmpty)
          'savedProductId': savedProductId,
      };
      try {
        await ProductAddDraftStore.instance.save(ownerUid, {
          ...completionMarker,
          'draftId': draftId,
        });
        await ProductDraftService.instance.upsertDraft(
          ownerUid: ownerUid,
          draftId: draftId,
          patch: completionMarker,
        );
      } catch (error) {
        debugPrint('Failed to mark draft completed before close: $error');
      }
    }

    await _clearDraftSession();
  }

  void _startDraftWatch() {
    if (!_draftPersistenceEnabled) return;
    final ownerUid = _effectiveOwnerUid;
    final draftId = _activeDraftId;
    if (ownerUid == null || draftId == null) return;

    _draftWatchSubscription?.cancel();
    _draftWatchSubscription = ProductDraftService.instance
        .watchDraft(ownerUid: ownerUid, draftId: draftId)
        .listen(
          (snapshot) {
            if (!mounted || !snapshot.exists) return;
            unawaited(
              _handleDraftSnapshot(snapshot.data() ?? <String, dynamic>{}),
            );
          },
          onError: (Object error) {
            debugPrint('Draft watch failed: $error');
          },
        );
  }

  Future<void> _handleDraftSnapshot(Map<String, dynamic> data) async {
    if (_draftSessionClosed || _isDraftCompleted(data)) {
      return;
    }

    final aiStatus = (data['aiStatus'] as String?)?.trim();
    final aiResult = data['aiResult'];
    if (!_shouldAcceptDraftAiUpdate(data)) {
      return;
    }

    if (aiStatus == 'queued' || aiStatus == 'processing') {
      if (!_isAnalyzingProductWithAi && mounted) {
        setState(() {
          _isAnalyzingProductWithAi = true;
          _aiQueueStatusText = aiStatus == 'processing'
              ? 'ถึงคิวแล้ว กำลังประมวลผล AI...'
              : 'กำลังรอคิว AI...';
        });
      }
      return;
    }

    if (aiStatus == 'failed') {
      if (mounted) {
        setState(() {
          _isAnalyzingProductWithAi = false;
          _hasUsedAiProductAnalysisForProduct = false;
          _aiQueueStatusText =
              (data['aiError'] as String?)?.trim().isNotEmpty == true
              ? (data['aiError'] as String).trim()
              : 'AI ประมวลผลไม่สำเร็จ';
        });
      }
      await _persistDraftNow();
      return;
    }

    if (aiStatus == 'completed' && aiResult is Map) {
      if (!_hasUsedAiProductAnalysisForProduct) {
        _applyAiProductAnalysis(_aiResultFromDynamicMap(aiResult));
      }
      if (mounted) {
        setState(() {
          _hasUsedAiProductAnalysisForProduct = true;
          _isAnalyzingProductWithAi = false;
          _aiQueueStatusText = 'ประมวลผล AI สำเร็จ';
        });
      }
      await _persistDraftNow();
    }
  }

  _AiProductAnalysisResult _aiResultFromDynamicMap(Map<dynamic, dynamic> data) {
    return _AiProductAnalysisResult(
      productName: (data['productName'] ?? '').toString().trim(),
      description: (data['description'] ?? '').toString().trim(),
      taxStatus: (data['taxStatus'] ?? '').toString().trim(),
      taxReason: (data['taxReason'] ?? '').toString().trim(),
      productCategory: (data['productCategory'] ?? '').toString().trim(),
      productType: (data['productType'] ?? '').toString().trim(),
      isLegalInThailand: data['isLegalInThailand'] is bool
          ? data['isLegalInThailand'] as bool
          : null,
      legalReason: (data['legalReason'] ?? '').toString().trim(),
      isFreshProduct: data['isFreshProduct'] is bool
          ? data['isFreshProduct'] as bool
          : null,
      isProcessed: data['isProcessed'] is bool
          ? data['isProcessed'] as bool
          : null,
      canShipNationwide: data['canShipNationwide'] is bool
          ? data['canShipNationwide'] as bool
          : null,
      nationwideShippingReason: (data['nationwideShippingReason'] ?? '')
          .toString()
          .trim(),
      productNameConfidence: _parseAiConfidence(data['productNameConfidence']),
      taxConfidence: _parseAiConfidence(data['taxConfidence']),
      productTypeConfidence: _parseAiConfidence(data['productTypeConfidence']),
      nationwideShippingConfidence: _parseAiConfidence(
        data['nationwideShippingConfidence'],
      ),
      legalConfidence: _parseAiConfidence(data['legalConfidence']),
      parcelLengthCm: _parseParcelDimensionCm(data['parcelLengthCm']),
      parcelWidthCm: _parseParcelDimensionCm(data['parcelWidthCm']),
      parcelHeightCm: _parseParcelDimensionCm(data['parcelHeightCm']),
      parcelDimensionReason: (data['parcelDimensionReason'] ?? '')
          .toString()
          .trim(),
      parcelDimensionConfidence: _parseAiConfidence(
        data['parcelDimensionConfidence'],
      ),
      saleUnit: (data['saleUnit'] ?? '').toString().trim(),
      requiresAdminReview: data['requiresAdminReview'] is bool
          ? data['requiresAdminReview'] as bool
          : null,
      reviewReasonLabels: _parseAiStringList(
        data['reviewReasonLabels'] ?? data['reviewReasons'],
      ),
    );
  }

  Future<({String imageUrl, String? thumbnailUrl})?>
  _resolveDraftImageUrls() async {
    if (_existingImageUrls.isNotEmpty) {
      return (
        imageUrl: _existingImageUrls.first,
        thumbnailUrl: _existingThumbnailUrls.isNotEmpty
            ? _existingThumbnailUrls.first
            : _existingImageUrls.first,
      );
    }
    if (_newImageFiles.isEmpty) {
      return null;
    }

    final uploaded = await _uploadImageToFirebase(_newImageFiles.first);
    if (uploaded == null) {
      throw Exception('อัปโหลดรูปไม่สำเร็จ — ตรวจสอบอินเทอร์เน็ตแล้วลองใหม่');
    }

    if (mounted) {
      setState(() {
        _existingImageUrls.add(uploaded.originalUrl);
        _existingThumbnailUrls.add(uploaded.thumbnailUrl);
        _newImageFiles.removeAt(0);
      });
    } else {
      _existingImageUrls.add(uploaded.originalUrl);
      _existingThumbnailUrls.add(uploaded.thumbnailUrl);
      _newImageFiles.removeAt(0);
    }
    await _persistDraftNow();
    return (
      imageUrl: uploaded.originalUrl,
      thumbnailUrl: uploaded.thumbnailUrl,
    );
  }

  Future<void> _enqueueProductAiAnalysis({required bool automatic}) async {
    final ownerUid = _effectiveOwnerUid;
    final draftId = _activeDraftId;
    if (ownerUid == null || draftId == null) {
      throw Exception('ไม่พบ draft session สำหรับ AI');
    }

    final imageUrls = await _resolveDraftImageUrls();
    if (imageUrls == null) {
      throw Exception('กรุณาเพิ่มรูปสินค้าก่อนให้ AI วิเคราะห์');
    }

    final requestId = _createAiRequestId();
    _acceptedAiRequestId = requestId;
    _aiAnalysisDiscarded = false;
    final callable = _aiCallable('enqueueProductAiAnalysis');
    await callable.call(<String, dynamic>{
      'requestId': requestId,
      'draftId': draftId,
      'imageUrl': imageUrls.imageUrl,
      'thumbnailUrl': imageUrls.thumbnailUrl,
      'productName': _nameController.text.trim(),
      'description': _productDescriptionController.text.trim(),
      'category': (_selectedProductCategory ?? '').trim(),
      'price': _priceController.text.trim(),
      'unit': _selectedUnit == 'อื่นๆ'
          ? _otherUnitController.text.trim()
          : (_selectedUnit ?? '').trim(),
      'weight': _weightController.text.trim(),
      'weightUnit': _weightUnit,
    });

    if (_aiAnalysisDiscarded || _acceptedAiRequestId != requestId) {
      return;
    }

    if (mounted) {
      setState(() {
        _isAnalyzingProductWithAi = true;
        _aiQueueStatusText = 'กำลังเข้าคิว AI...';
      });
    }
    await _persistDraftNow();

    if (!automatic && mounted) {
      _showSnack('ส่งคำขอ AI แล้ว — ออกจากหน้านี้ได้ ระบบจะแจ้งเมื่อเสร็จ');
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_draftSessionClosed) {
      return;
    }
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      unawaited(_persistDraftNow());
    }
  }

  void _applyWeightFromStoredValue(dynamic weightValue) {
    if (weightValue == null) {
      return;
    }
    if (weightValue is num) {
      _weightController.text = weightValue.toString();
      _weightUnit = 'g';
      return;
    }

    final raw = weightValue.toString().trim();
    if (raw.isEmpty) {
      return;
    }

    final match = RegExp(
      r'^([\d.]+)\s*(g|kg|grams?|kilograms?)?$',
      caseSensitive: false,
    ).firstMatch(raw);
    if (match != null) {
      _weightController.text = match.group(1) ?? '';
      final unit = (match.group(2) ?? 'g').toLowerCase();
      _weightUnit = unit.startsWith('k') ? 'kg' : 'g';
      return;
    }

    final parsed = double.tryParse(raw);
    if (parsed != null) {
      _weightController.text = raw;
      _weightUnit = 'g';
    }
  }

  Future<void> _hydrateWeightFromFirestore() async {
    if (widget.productToEdit?.id == null) {
      return;
    }
    try {
      final data = await _loadExistingProductData();
      if (!mounted || data['weight'] == null) {
        return;
      }
      setState(() => _applyWeightFromStoredValue(data['weight']));
    } catch (error) {
      debugPrint('Failed to hydrate product weight: $error');
    }
  }

  Future<void> _loadVariantsForEdit() async {
    final productId = widget.productToEdit?.id?.trim();
    if (productId == null || productId.isEmpty) {
      return;
    }
    try {
      final data = await _loadExistingProductData();
      if (!mounted) {
        return;
      }
      final variants = ProductVariantSupport.parseList(data['variants']);
      setState(() {
        _hasVariants = ProductVariantSupport.productHasVariants(data);
        _productVariants = variants;
        if (_hasVariants && variants.isNotEmpty) {
          _variantDrafts = ProductVariantSupport.draftsFromVariants(
            variants,
            imageUrls: _existingImageUrls,
          );
        }
      });
    } catch (error) {
      debugPrint('Failed to load product variants: $error');
    }
  }

  bool _validateBasicProductFields({required bool requirePriceStock}) {
    if (_isEditingExistingProduct) {
      if (_existingImageUrls.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('สินค้านี้ไม่มีรูปภาพ — ไม่สามารถบันทึกได้'),
          ),
        );
        return false;
      }
    } else if (_currentImageCount == 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('กรุณาเพิ่มรูปสินค้าอย่างน้อย 1 รูป')),
      );
      return false;
    }

    if (_nameController.text.trim().isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('กรุณากรอกชื่อสินค้า')));
      return false;
    }

    if (_weightController.text.trim().isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('กรุณากรอกน้ำหนักสินค้า')));
      return false;
    }

    if (requirePriceStock) {
      if (_priceController.text.trim().isEmpty) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('กรุณากรอกราคา')));
        return false;
      }
      if (_stockController.text.trim().isEmpty) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('กรุณากรอกสต็อกทั้งหมด')));
        return false;
      }
    }

    if ((_selectedProductCategory ?? '').trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('กรุณากรอกข้อมูลภาษีสินค้าและเลือกประเภทสินค้า'),
        ),
      );
      return false;
    }

    final preparationTimeMinutes = int.tryParse(
      _preparationTimeController.text.trim(),
    );
    if (preparationTimeMinutes == null ||
        preparationTimeMinutes <= 0 ||
        preparationTimeMinutes > 240) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('กรุณากรอกเวลาเตรียมสินค้า 1-240 นาที')),
      );
      return false;
    }

    return true;
  }

  Future<void> _openVariantSetupFlow({required bool saveAfterReturn}) async {
    if (!_validateBasicProductFields(requirePriceStock: false)) {
      return;
    }

    final drafts = await Navigator.of(context).push<List<ProductVariantDraft>>(
      MaterialPageRoute<List<ProductVariantDraft>>(
        builder: (_) => ProductVariantSetupScreen(
          productName: _nameController.text.trim(),
          existingImageUrls: List<String>.from(_existingImageUrls),
          existingThumbnailUrls: _existingThumbnailUrls.isNotEmpty
              ? List<String>.from(_existingThumbnailUrls)
              : List<String>.from(_existingImageUrls),
          localImageFiles: List<XFile>.from(_newImageFiles),
          initialDrafts: _variantDrafts.isNotEmpty
              ? List<ProductVariantDraft>.from(_variantDrafts)
              : <ProductVariantDraft>[ProductVariantDraft(imageIndex: 0)],
          isEditMode: widget.productToEdit != null,
        ),
      ),
    );

    if (!mounted || drafts == null) {
      return;
    }

    setState(() {
      _hasVariants = true;
      _variantDrafts = drafts;
    });
    unawaited(_persistDraftNow());

    if (saveAfterReturn) {
      await _saveProduct();
    }
  }

  Future<void> _onPrimarySavePressed() async {
    if (_hasVariants && widget.productToEdit == null) {
      await _openVariantSetupFlow(saveAfterReturn: true);
      return;
    }
    await _saveProduct();
  }

  @override
  void dispose() {
    if (_draftPersistenceEnabled) {
      if (!_draftSessionClosed) {
        unawaited(_persistDraftNow());
      }
      WidgetsBinding.instance.removeObserver(this);
    }
    _draftSaveDebounce?.cancel();
    _draftWatchSubscription?.cancel();
    // Dispose controllers
    _nameController.dispose();
    _descriptionController.dispose();
    _productDescriptionController.dispose();
    _priceController.dispose();
    _priceFocusNode.dispose();
    _toppingsFocusNode.dispose();
    _stockController.dispose();
    _preparationTimeController.dispose();
    _colorsController.dispose();
    _sizesController.dispose();
    _weightController.dispose();
    _parcelLengthController.dispose();
    _parcelWidthController.dispose();
    _parcelHeightController.dispose();
    _otherUnitController.dispose();
    _aiQueueSubscription?.cancel();
    super.dispose();
  }

  double? get _enteredPrice {
    final rawValue = _priceController.text.trim().replaceAll(',', '');
    if (rawValue.isEmpty) {
      return null;
    }
    return double.tryParse(rawValue);
  }

  double? get _netPriceAfterGp {
    final enteredPrice = _enteredPrice;
    if (enteredPrice == null) {
      return null;
    }
    return enteredPrice * (1 - _gpRate);
  }

  String _formatPriceDisplay(double value) {
    if (value == value.roundToDouble()) {
      return value.toStringAsFixed(0);
    }
    return value.toStringAsFixed(2);
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  void _hideFieldGuidance() {
    if (!_showPriceGuidance &&
        !_showPreparationTimeGuidance &&
        !_showToppingsGuidance) {
      return;
    }
    setState(() {
      _showPriceGuidance = false;
      _showPreparationTimeGuidance = false;
      _showToppingsGuidance = false;
    });
  }

  Widget _buildDismissibleGuidance({required String message, Widget? footer}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: AppColors.accentLight,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.accent.withValues(alpha: 0.35)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            message,
            textAlign: TextAlign.start,
            softWrap: true,
            style: const TextStyle(
              fontSize: 12,
              height: 1.35,
              color: Color(0xFF7C2D12),
              fontWeight: FontWeight.w600,
            ),
          ),
          if (footer != null) ...[
            const SizedBox(height: 6),
            Align(alignment: Alignment.centerLeft, child: footer),
          ],
        ],
      ),
    );
  }

  Widget _buildGuidedFieldOverlay({
    required Widget field,
    required bool showGuidance,
    required String guidanceMessage,
    Widget? footer,
  }) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        field,
        if (showGuidance)
          Positioned(
            left: 2,
            right: 2,
            bottom: 58,
            child: _buildDismissibleGuidance(
              message: guidanceMessage,
              footer: footer,
            ),
          ),
      ],
    );
  }

  bool get _isPharmacyCategory =>
      _selectedProductCategory == 'ร้านขายยาและเวชภัณฑ์';

  String get _computedTaxStatus {
    if (_isPharmacyCategory) {
      return _pharmacyIsTaxable ? 'taxable' : 'exempt';
    }
    return (_isFreshProduct && !_isProcessed) ? 'exempt' : 'taxable';
  }

  String get _taxStatusLabel => _computedTaxStatus == 'exempt'
      ? 'สินค้านี้ยกเว้นภาษี'
      : 'สินค้านี้เสียภาษี';

  Color get _taxStatusColor => _computedTaxStatus == 'exempt'
      ? const Color(0xFF2E7D32)
      : const Color(0xFFC62828);

  String get _taxReason {
    final aiReason = _aiTaxAnalysisReason?.trim();
    if (aiReason != null && aiReason.isNotEmpty) {
      return aiReason;
    }
    if (_isPharmacyCategory) {
      return _pharmacyIsTaxable
          ? 'ร้านค้าระบุว่ายาหรือเวชภัณฑ์รายการนี้อยู่ในกลุ่มที่เสียภาษี'
          : 'ร้านค้าระบุว่ายาหรือเวชภัณฑ์รายการนี้อยู่ในกลุ่มที่ยกเว้นภาษี';
    }
    if (_isFreshProduct && !_isProcessed) {
      return 'ของสดที่ยังไม่ผ่านการแปรรูป';
    }
    if (_isFreshProduct && _isProcessed) {
      return 'ของสดที่ผ่านการแปรรูปแล้ว';
    }
    return 'สินค้าไม่ได้เข้ากลุ่มของสดไม่แปรรูป';
  }

  bool get _resolvedCanShipNationwide =>
      _aiCanShipNationwide ?? _manualCanShipNationwide;

  String get _resolvedNationwideShippingReason {
    final aiReason = _aiNationwideShippingReason?.trim();
    if (_aiCanShipNationwide != null &&
        aiReason != null &&
        aiReason.isNotEmpty) {
      return aiReason;
    }
    return _manualCanShipNationwide
        ? 'ร้านค้าระบุว่าสินค้านี้เหมาะกับการส่งทั่วประเทศ'
        : 'ร้านค้าระบุว่าสินค้านี้ไม่เหมาะกับการส่งทั่วประเทศ';
  }

  String? _normalizeServiceType(String? rawValue) {
    final value = rawValue?.trim();
    switch (value) {
      case 'market':
      case 'ตลาดสด':
        return 'ตลาด';
      case 'shop':
      case 'store':
        return 'ร้านค้า';
      case 'restaurant':
        return 'ร้านอาหาร';
      case 'pharmacy':
        return 'ร้านขายยา';
      case 'agriculture':
      case 'farm':
      case 'สินค้าเกษตร':
        return 'สินค้าเกษตร';
      default:
        return value;
    }
  }

  String? _readServiceTypeFromData(Map<String, dynamic>? data) {
    if (data == null) return null;
    const keys = <String>['serviceType', 'service_type', 'category', 'type'];
    for (final key in keys) {
      final value = data[key]?.toString();
      final normalized = _normalizeServiceType(value);
      if (normalized != null && normalized.isNotEmpty) {
        return normalized;
      }
    }
    return null;
  }

  String? _resolveStringField(Map<String, dynamic>? data, List<String> keys) {
    if (data == null) return null;
    for (final key in keys) {
      final value = data[key]?.toString().trim();
      if (value != null && value.isNotEmpty) {
        return value;
      }
    }
    return null;
  }

  double? _parseDouble(dynamic value) {
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value.trim());
    return null;
  }

  Map<String, double?> _extractLocation(Map<String, dynamic>? data) {
    final dynamic locationValue =
        data?['location'] ??
        data?['coordinates'] ??
        data?['geo'] ??
        data?['position'] ??
        data?['shopLocation'];

    if (locationValue is GeoPoint) {
      return <String, double?>{
        'latitude': locationValue.latitude,
        'longitude': locationValue.longitude,
      };
    }

    if (locationValue is Map) {
      final map = Map<String, dynamic>.from(locationValue);
      final lat = _parseDouble(map['latitude'] ?? map['lat'] ?? map['y']);
      final lng = _parseDouble(
        map['longitude'] ?? map['lng'] ?? map['long'] ?? map['x'],
      );
      return <String, double?>{'latitude': lat, 'longitude': lng};
    }

    return <String, double?>{
      'latitude': _parseDouble(data?['latitude'] ?? data?['lat'] ?? data?['y']),
      'longitude': _parseDouble(
        data?['longitude'] ?? data?['lng'] ?? data?['long'] ?? data?['x'],
      ),
    };
  }

  bool _shopProfileReadyForSave(Map<String, dynamic>? data) {
    if (data == null || data.isEmpty) return false;
    final name =
        ShopProfileResolver.resolveName(data) ??
        _resolveStringField(data, const <String>[
          'shopName',
          'name',
          'displayName',
          'businessName',
          'storeName',
        ]);
    if (name == null || name.trim().isEmpty) return false;
    final location = _extractLocation(data);
    return location['latitude'] != null && location['longitude'] != null;
  }

  Future<Map<String, dynamic>?> _readShopRegistrationByUid({
    required String collection,
    required String userId,
    required String serviceType,
  }) async {
    try {
      final doc = await FirebaseFirestore.instance
          .collection(collection)
          .doc(userId)
          .get()
          .timeout(const Duration(seconds: 8));
      if (!doc.exists || doc.data() == null) return null;
      final data = Map<String, dynamic>.from(doc.data()!);
      data.putIfAbsent('serviceType', () => serviceType);
      return data;
    } on TimeoutException {
      debugPrint('Shop profile timeout: $collection/$userId');
      return null;
    } on FirebaseException catch (e) {
      if (e.code == 'permission-denied') {
        debugPrint('Skipping inaccessible registration $collection: ${e.code}');
        return null;
      }
      rethrow;
    }
  }

  Future<Map<String, dynamic>?> _resolveShopProfileData(
    String userId,
    String? normalizedServiceType,
    String? email,
  ) async {
    const collectionByType = <String, String>{
      'ตลาด': 'market_registrations',
      'ร้านค้า': 'shop_registrations',
      'ร้านอาหาร': 'restaurant_registrations',
      'ร้านขายยา': 'pharmacy_registrations',
      'สินค้าเกษตร': 'agriculture_registrations',
    };

    final cached = await ShopProfileCacheService.instance.loadProfile(userId);
    if (_shopProfileReadyForSave(cached)) {
      debugPrint('Save: using cached shop profile for $userId');
      return cached;
    }

    final hintedServiceType = normalizedServiceType;
    if (hintedServiceType != null &&
        collectionByType.containsKey(hintedServiceType)) {
      final hinted = await _readShopRegistrationByUid(
        collection: collectionByType[hintedServiceType]!,
        userId: userId,
        serviceType: hintedServiceType,
      );
      if (_shopProfileReadyForSave(hinted)) {
        unawaited(ShopProfileCacheService.instance.saveProfile(userId, hinted!));
        return hinted;
      }
    }

    final remaining = collectionByType.entries.where(
      (entry) => entry.key != hintedServiceType,
    );
    final parallelHits = await Future.wait(
      remaining.map(
        (entry) => _readShopRegistrationByUid(
          collection: entry.value,
          userId: userId,
          serviceType: entry.key,
        ),
      ),
    );
    for (final hit in parallelHits) {
      if (_shopProfileReadyForSave(hit)) {
        unawaited(ShopProfileCacheService.instance.saveProfile(userId, hit!));
        return hit;
      }
    }

    try {
      final publicShop = await FirebaseFirestore.instance
          .collection('public_shops')
          .doc(userId)
          .get()
          .timeout(const Duration(seconds: 8));
      if (publicShop.exists && publicShop.data() != null) {
        final data = Map<String, dynamic>.from(publicShop.data()!);
        if (_shopProfileReadyForSave(data)) {
          return data;
        }
      }
    } on TimeoutException {
      debugPrint('Shop profile timeout: public_shops/$userId');
    } on FirebaseException catch (e) {
      if (e.code != 'permission-denied') {
        rethrow;
      }
    }

    return cached;
  }

  Future<String?> _resolveServiceTypeFromRegistrations(String userId) async {
    const registrationCollections = <MapEntry<String, String>>[
      MapEntry<String, String>('market_registrations', 'ตลาด'),
      MapEntry<String, String>('shop_registrations', 'ร้านค้า'),
      MapEntry<String, String>('restaurant_registrations', 'ร้านอาหาร'),
      MapEntry<String, String>('pharmacy_registrations', 'ร้านขายยา'),
      MapEntry<String, String>('agriculture_registrations', 'สินค้าเกษตร'),
    ];

    for (final entry in registrationCollections) {
      try {
        final doc = await FirebaseFirestore.instance
            .collection(entry.key)
            .doc(userId)
            .get()
            .timeout(const Duration(seconds: 8));
        if (!doc.exists) continue;
        return _readServiceTypeFromData(doc.data()) ?? entry.value;
      } on FirebaseException catch (e) {
        if (e.code != 'permission-denied') {
          rethrow;
        }
        debugPrint(
          'Skipping inaccessible service registration ${entry.key}: ${e.message ?? e.code}',
        );
      }
    }

    return null;
  }

  Future<void> _loadCurrentServiceType() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      if (!mounted) return;
      setState(() {
        _serviceType = null;
        _isResolvingServiceType = false;
      });
      return;
    }

    try {
      final ownerUid = _effectiveOwnerUid ?? user.uid;
      final cached = await ShopProfileCacheService.instance.loadProfile(
        ownerUid,
      );
      String? serviceType = _readServiceTypeFromData(cached);
      if (serviceType != null && serviceType.isNotEmpty) {
        if (!mounted) return;
        setState(() {
          _serviceType = serviceType;
          _isResolvingServiceType = false;
        });
        return;
      }

      final userDoc = await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .get()
          .timeout(const Duration(seconds: 8));
      serviceType = _readServiceTypeFromData(userDoc.data());

      if (serviceType == null) {
        final contractDoc = await FirebaseFirestore.instance
            .collection('contracts')
            .doc(user.uid)
            .get()
            .timeout(const Duration(seconds: 8));
        serviceType = _readServiceTypeFromData(contractDoc.data());
      }

      serviceType ??= await _resolveServiceTypeFromRegistrations(user.uid);

      if (!mounted) return;
      setState(() {
        _serviceType = serviceType;
        _isResolvingServiceType = false;
      });
    } catch (e, stack) {
      debugPrint('Failed to resolve service type for product media rules: $e');
      debugPrint('$stack');
      if (!mounted) return;
      setState(() {
        _serviceType = null;
        _isResolvingServiceType = false;
      });
    }
  }

  Future<void> _loadAdminMediaSettings() async {
    final ownerUid = _effectiveOwnerUid;
    if (ownerUid == null) {
      return;
    }

    try {
      final snapshot = await FirebaseFirestore.instance
          .collection('public_shops')
          .doc(ownerUid)
          .get();
      final data = snapshot.data();
      if (!mounted || data == null) {
        return;
      }

      final maxImagesRaw = data['adminMaxImageCount'];
      final maxImages = maxImagesRaw is num
          ? maxImagesRaw.toInt()
          : int.tryParse(maxImagesRaw?.toString() ?? '');
      final canUploadVideo = data['adminCanUploadVideo'];

      setState(() {
        if (maxImages != null && maxImages > 0) {
          _adminMaxImageCount = maxImages.clamp(1, 30);
        }
        if (canUploadVideo is bool) {
          _adminCanUploadVideo = canUploadVideo;
        }
      });
    } catch (error) {
      debugPrint('Failed to load admin media settings: $error');
    }
  }

  Future<bool> _ensureGalleryPermission() async {
    if (kIsWeb) {
      return true;
    }

    if (defaultTargetPlatform == TargetPlatform.iOS) {
      final status = await Permission.photos.request();
      return status.isGranted || status.isLimited;
    }

    if (defaultTargetPlatform == TargetPlatform.android) {
      final photosStatus = await Permission.photos.request();
      if (photosStatus.isGranted || photosStatus.isLimited) {
        return true;
      }

      final storageStatus = await Permission.storage.request();
      return storageStatus.isGranted;
    }

    return true;
  }

  bool get _canReplaceProductImageAtCapacity =>
      !_isEditingExistingProduct &&
      _maxImageCount == 1 &&
      _currentImageCount >= _maxImageCount &&
      !_isAnalyzingProductWithAi;

  bool _shouldAcceptDraftAiUpdate(Map<String, dynamic> data) {
    if (_isEditingExistingProduct) {
      return true;
    }
    if (_aiAnalysisDiscarded) {
      return false;
    }
    if (!_isEditingExistingProduct && _currentImageCount == 0) {
      return false;
    }
    final accepted = _acceptedAiRequestId?.trim();
    final snapshotRequestId = (data['aiRequestId'] as String?)?.trim();
    if (accepted != null &&
        accepted.isNotEmpty &&
        snapshotRequestId != null &&
        snapshotRequestId.isNotEmpty) {
      return snapshotRequestId == accepted;
    }
    return true;
  }

  bool _shouldResetAiForImageRemoval({
    required int index,
    required bool isExisting,
  }) {
    if (_isEditingExistingProduct) {
      return false;
    }
    final removingLastImage = _currentImageCount <= 1;
    final removingAnalyzedImage =
        _maxImageCount == 1 ||
        (isExisting ? index == 0 : index == 0 && _existingImageUrls.isEmpty);
    return removingLastImage || removingAnalyzedImage;
  }

  void _clearAiProductAnalysisState({bool clearAiFilledFields = true}) {
    _aiAnalysisEpoch++;
    _acceptedAiRequestId = null;
    _aiAnalysisDiscarded = true;

    if (clearAiFilledFields) {
      _nameController.clear();
      _productDescriptionController.clear();
      _hasUsedAiDescriptionForProduct = false;
      _selectedProductCategory = null;
      _isFreshProduct = false;
      _isProcessed = false;
      _pharmacyIsTaxable = true;
      _manualCanShipNationwide = false;
      _parcelLengthController.clear();
      _parcelWidthController.clear();
      _parcelHeightController.clear();
      if (_aiAppliedSaleUnit) {
        _selectedUnit = 'ชิ้น';
        _otherUnitController.clear();
      }
      _aiAppliedSaleUnit = false;
    }

    _hasUsedAiProductAnalysisForProduct = false;
    _isAnalyzingProductWithAi = false;
    _aiQueueStatusText = null;
    _aiQueueExternalRecommendation = false;
    _hasAiTaxAnalysis = false;
    _aiTaxAnalysisReason = null;
    _aiIsLegalInThailand = null;
    _aiLegalAnalysisReason = null;
    _aiProductType = null;
    _aiCanShipNationwide = null;
    _aiNationwideShippingReason = null;
    _aiParcelDimensionReason = null;
    _aiProductNameConfidence = null;
    _aiTaxConfidence = null;
    _aiProductTypeConfidence = null;
    _aiNationwideShippingConfidence = null;
    _aiLegalConfidence = null;
    _aiRequiresAdminReview = null;
    _aiReviewReasonLabels = <String>[];

    _aiQueueSubscription?.cancel();
    _aiQueueSubscription = null;
  }

  Future<void> _resetAiProductAnalysisForImageChange() async {
    _clearAiProductAnalysisState();
    if (mounted) {
      setState(() {});
    }
    if (!_draftPersistenceEnabled) {
      return;
    }
    await _persistDraftPatch(<String, dynamic>{
      'hasUsedAiProductAnalysisForProduct': false,
      'hasUsedAiDescriptionForProduct': false,
      'hasAiTaxAnalysis': false,
      'aiTaxAnalysisReason': null,
      'aiIsLegalInThailand': null,
      'aiLegalAnalysisReason': null,
      'aiProductType': null,
      'aiCanShipNationwide': null,
      'aiNationwideShippingReason': null,
      'aiParcelDimensionReason': null,
      'aiProductNameConfidence': null,
      'aiTaxConfidence': null,
      'aiProductTypeConfidence': null,
      'aiNationwideShippingConfidence': null,
      'aiLegalConfidence': null,
      'aiRequiresAdminReview': null,
      'aiReviewReasonLabels': <String>[],
      'aiStatus': null,
      'aiResult': null,
      'aiError': null,
      'aiRequestId': null,
      'imageUrl': null,
      'thumbnailUrl': null,
      'isAnalyzingProductWithAi': false,
      'name': _nameController.text.trim(),
      'productDescription': _productDescriptionController.text.trim(),
      'productCategory': _selectedProductCategory,
      'isFreshProduct': _isFreshProduct,
      'isProcessed': _isProcessed,
      'pharmacyIsTaxable': _pharmacyIsTaxable,
      'manualCanShipNationwide': _manualCanShipNationwide,
      'parcelLengthCm': _parcelLengthController.text.trim(),
      'parcelWidthCm': _parcelWidthController.text.trim(),
      'parcelHeightCm': _parcelHeightController.text.trim(),
      'unit': _selectedUnit == 'อื่นๆ'
          ? _otherUnitController.text.trim()
          : (_selectedUnit ?? '').trim(),
    });
  }

  Future<void> _applySelectedProductImages(
    List<XFile> images, {
    required bool replaceExisting,
  }) async {
    if (images.isEmpty) {
      return;
    }

    final imagesToKeep = images.take(_maxImageCount).toList();
    if (replaceExisting) {
      await _resetAiProductAnalysisForImageChange();
      if (!mounted) {
        return;
      }
      setState(() {
        _existingImageUrls.clear();
        _existingThumbnailUrls.clear();
        _newImageFiles
          ..clear()
          ..addAll(imagesToKeep);
      });
    } else {
      setState(() => _newImageFiles.addAll(imagesToKeep));
    }

    unawaited(_persistDraftNow());
    unawaited(_analyzeProductWithAi(automatic: true));
  }

  Future<void> _pickImagesFromGallery() async {
    if (_isResolvingServiceType) return;

    final blocked = _imagePickBlockedReason;
    if (blocked != null) {
      _showSnack(blocked);
      return;
    }

    final remainingSlots = _maxImageCount - _currentImageCount;
    final replaceExisting = _canReplaceProductImageAtCapacity;
    if (remainingSlots <= 0 && !replaceExisting) {
      _showSnack('ใส่รูปได้สูงสุด $_maxImageCount รูป');
      return;
    }

    final bool pickSingleOnly =
        _maxImageCount == 1 ||
        replaceExisting ||
        (_usesFirstImageAiGate && _currentImageCount == 0);

    try {
      final List<XFile> picks;
      if (kIsWeb) {
        picks = await pickProductImagesFromGalleryWeb(
          pickSingleOnly: pickSingleOnly,
          maxCount: remainingSlots,
        );
      } else {
        if (!await _ensureGalleryPermission()) {
          _showSnack(
            'ไม่ได้รับอนุญาตเข้าถึงรูปภาพ — เปิดที่ ตั้งค่า > ความเป็นส่วนตัว > รูปภาพ',
          );
          return;
        }

        if (pickSingleOnly) {
          final singlePick = await _picker.pickImage(
            source: ImageSource.gallery,
            imageQuality: _pickerImageQuality,
          );
          picks = singlePick == null ? <XFile>[] : <XFile>[singlePick];
        } else {
          picks = await _picker.pickMultiImage(
            imageQuality: _pickerImageQuality,
          );
        }
      }
      if (picks.isEmpty) return;

      final picksToProcess = replaceExisting
          ? picks.take(_maxImageCount).toList()
          : picks.take(remainingSlots).toList();
      final compressedToAdd = await _compressPickedImages(picksToProcess);
      if (compressedToAdd.isEmpty) return;
      await _applySelectedProductImages(
        compressedToAdd,
        replaceExisting: replaceExisting,
      );

      if (!replaceExisting && picks.length > remainingSlots) {
        _showSnack(
          'ระบบเพิ่มรูปได้เพียง $_maxImageCount รูป แสดงเฉพาะ ${picksToProcess.length} รูปแรก',
        );
      }
    } on PlatformException catch (error) {
      _showSnack(
        error.message?.trim().isNotEmpty == true
            ? error.message!.trim()
            : 'เลือกรูปไม่สำเร็จ (${error.code})',
      );
    } catch (error) {
      _showSnack('เลือกรูปไม่สำเร็จ: $error');
    }
  }

  Future<void> _captureImage() async {
    if (_isResolvingServiceType) return;

    final replaceExisting = _canReplaceProductImageAtCapacity;
    final blocked = _imagePickBlockedReason;
    if (blocked != null && !replaceExisting) {
      _showSnack(blocked);
      return;
    }

    try {
      if (!kIsWeb) {
        final cameraStatus = await Permission.camera.request();
        if (!cameraStatus.isGranted) {
          _showSnack(
            'ไม่ได้รับอนุญาตใช้กล้อง — เปิดที่ ตั้งค่า > ความเป็นส่วนตัว > กล้อง',
          );
          return;
        }
      }

      final XFile? photo = await _picker.pickImage(
        source: ImageSource.camera,
        imageQuality: _pickerImageQuality,
      );
      if (photo == null) return;
      final compressed = await _compressPickedImages(<XFile>[photo]);
      if (compressed.isEmpty) return;
      await _applySelectedProductImages(
        compressed,
        replaceExisting: replaceExisting,
      );
    } on PlatformException catch (error) {
      _showSnack(
        error.message?.trim().isNotEmpty == true
            ? error.message!.trim()
            : 'ถ่ายรูปไม่สำเร็จ (${error.code})',
      );
    } catch (error) {
      _showSnack('ถ่ายรูปไม่สำเร็จ: $error');
    }
  }

  Future<List<XFile>> _compressPickedImages(List<XFile> picks) async {
    if (kIsWeb) {
      return compressPickedProductImages(
        picks,
        uploadQuality: _uploadImageQuality,
      );
    }
    final compressed = <XFile>[];
    for (final pick in picks) {
      try {
        final sourceFile = File(pick.path);
        final compressedFile = await _compressImageFile(
          sourceFile,
          forThumbnail: false,
          qualityOverride: _uploadImageQuality,
          minDimensionOverride: 1400,
          suffixOverride: 'pick',
        );
        if (compressedFile.path == sourceFile.path) {
          compressed.add(pick);
        } else {
          compressed.add(XFile(compressedFile.path, name: pick.name));
        }
      } catch (e) {
        debugPrint('Failed to pre-compress picked image: $e');
        compressed.add(pick);
      }
    }
    return compressed;
  }

  String _videoPickerErrorMessage(
    PlatformException error, {
    required ImageSource source,
  }) {
    switch (error.code) {
      case 'photo_access_denied':
      case 'camera_access_denied':
        return source == ImageSource.camera
            ? 'ไม่ได้รับอนุญาตใช้กล้อง — เปิดที่ ตั้งค่า > ความเป็นส่วนตัว > กล้อง'
            : 'ไม่ได้รับอนุญาตเข้าถึงรูป/วิดีโอ — เปิดที่ ตั้งค่า > ความเป็นส่วนตัว > รูปภาพ';
      case 'invalid_video':
      case 'invalid_image':
        return 'ไฟล์วิดีโอนี้เปิดไม่ได้ ลองเลือกคลิปอื่นหรือบันทึกลงเครื่องก่อน';
      default:
        return error.message?.trim().isNotEmpty == true
            ? error.message!.trim()
            : 'เลือกวิดีโอไม่สำเร็จ (${error.code})';
    }
  }

  Future<File> _compressProductVideoIfNeeded(File source) async {
    try {
      await VideoCompress.setLogLevel(0);
      final info = await VideoCompress.getMediaInfo(source.path);
      final width = info.width ?? 0;
      final height = info.height ?? 0;
      final maxEdge = width > height ? width : height;
      if (maxEdge > 0 && maxEdge <= _videoMaxEdgePx) {
        return source;
      }

      final mediaInfo = await VideoCompress.compressVideo(
        source.path,
        quality: VideoQuality.DefaultQuality,
        includeAudio: true,
        deleteOrigin: false,
      );
      final compressedPath = mediaInfo?.file?.path ?? mediaInfo?.path;
      if (compressedPath != null) {
        final compressed = File(compressedPath);
        if (await compressed.exists()) {
          return compressed;
        }
      }
    } catch (error, stack) {
      debugPrint('Product video compress failed: $error');
      debugPrint('$stack');
    }
    return source;
  }

  Future<void> _finishVideoCompression(XFile video) async {
    final ownerUid = _effectiveOwnerUid;
    final draftId = _activeDraftId;
    final videoName = video.name;
    var workingPath = video.path;

    try {
      final compressed = await _compressProductVideoIfNeeded(File(workingPath));
      var finalPath = compressed.path;

      if (_draftPersistenceEnabled && ownerUid != null && draftId != null) {
        final persisted = await ProductAddDraftStore.instance.persistMediaFile(
          sourcePath: finalPath,
          ownerUid: ownerUid,
          draftId: draftId,
          fileName: 'video.${_extensionFromPath(finalPath, fallback: 'mp4')}',
        );
        if (persisted != null && persisted.isNotEmpty) {
          finalPath = persisted;
        }
        await _persistDraftPatch(<String, dynamic>{
          'videoCompressStatus': 'ready',
          'localVideoPath': finalPath,
          'pendingVideoName': videoName,
        });
      }

      if (mounted) {
        setState(() {
          _videoFile = XFile(finalPath, name: videoName);
          _existingVideoUrl = null;
          _existingVideoThumbnailUrl = null;
        });
      }
    } catch (error, stack) {
      debugPrint('Product video compression pipeline failed: $error');
      debugPrint('$stack');
      if (_draftPersistenceEnabled && ownerUid != null && draftId != null) {
        await _persistDraftPatch(<String, dynamic>{
          'videoCompressStatus': 'ready',
          'localVideoPath': workingPath,
          'pendingVideoName': videoName,
        });
      }
      if (mounted) {
        setState(() {
          _videoFile = XFile(workingPath, name: videoName);
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _isCompressingVideo = false;
          if (_uploadStatusText == 'กำลังบีบอัดวิดีโอ (720p)...') {
            _uploadStatusText = null;
          }
        });
      }
    }
  }

  Future<void> _processPickedVideo(XFile video) async {
    final ownerUid = _effectiveOwnerUid;
    final draftId = _activeDraftId;
    final videoName = video.name;
    var workingPath = video.path;

    if (_draftPersistenceEnabled && ownerUid != null && draftId != null) {
      final persistedRaw = await ProductAddDraftStore.instance.persistMediaFile(
        sourcePath: video.path,
        ownerUid: ownerUid,
        draftId: draftId,
        fileName:
            'video_raw.${_extensionFromPath(video.path, fallback: 'mp4')}',
      );
      if (persistedRaw != null && persistedRaw.isNotEmpty) {
        workingPath = persistedRaw;
      }
      await _persistDraftPatch(<String, dynamic>{
        'videoCompressStatus': 'compressing',
        'localVideoPath': workingPath,
        'pendingVideoName': videoName,
      });
    }

    if (mounted) {
      setState(() {
        _videoFile = XFile(workingPath, name: videoName);
        _existingVideoUrl = null;
        _existingVideoThumbnailUrl = null;
        _isCompressingVideo = true;
        _uploadStatusText = 'กำลังบีบอัดวิดีโอ (720p)...';
      });
    }

    await _finishVideoCompression(XFile(workingPath, name: videoName));
  }

  Future<void> _pickVideo() async {
    if (_isResolvingServiceType) {
      return;
    }

    final blocked = _videoPickBlockedReason;
    if (blocked != null) {
      _showSnack(blocked);
      return;
    }

    if (kIsWeb) {
      try {
        final video = await pickProductVideoFromGalleryWeb();
        if (video == null) return;
        setState(() {
          _videoFile = video;
          _existingVideoUrl = null;
          _existingVideoThumbnailUrl = null;
        });
        unawaited(_persistDraftNow());
      } catch (error) {
        _showSnack('เลือกวิดีโอไม่สำเร็จ: $error');
      }
      return;
    }

    if (!await _ensureGalleryPermission()) {
      _showSnack(
        'ไม่ได้รับอนุญาตเข้าถึงวิดีโอ — เปิดที่ ตั้งค่า > ความเป็นส่วนตัว > รูปภาพ/วิดีโอ',
      );
      return;
    }

    final ImageSource? source = await showModalBottomSheet<ImageSource>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.videocam),
              title: const Text('ถ่ายวิดีโอ'),
              onTap: () => Navigator.pop(context, ImageSource.camera),
            ),
            const Divider(height: 0),
            ListTile(
              leading: const Icon(Icons.video_library),
              title: const Text('เลือกจากแกลเลอรี'),
              onTap: () => Navigator.pop(context, ImageSource.gallery),
            ),
          ],
        ),
      ),
    );

    if (source == null) return;

    XFile? video;
    try {
      video = await _picker.pickVideo(
        source: source,
        maxDuration: _maxVideoDuration,
      );
    } on PlatformException catch (e) {
      _showSnack(_videoPickerErrorMessage(e, source: source));
      return;
    }
    if (video == null) return;

    unawaited(_processPickedVideo(video));
  }

  void _removeExistingImageAt(int index) {
    final shouldResetAi = _shouldResetAiForImageRemoval(
      index: index,
      isExisting: true,
    );
    setState(() {
      if (index >= 0 && index < _existingImageUrls.length) {
        _localMediaPaths.remove(_existingImageUrls[index]);
        _existingImageUrls.removeAt(index);
      }
      if (index >= 0 && index < _existingThumbnailUrls.length) {
        _localMediaPaths.remove(_existingThumbnailUrls[index]);
        _existingThumbnailUrls.removeAt(index);
      }
    });
    if (shouldResetAi) {
      unawaited(_resetAiProductAnalysisForImageChange());
    }
    _scheduleDraftSave();
  }

  void _removeNewImageAt(int index) {
    final shouldResetAi = _shouldResetAiForImageRemoval(
      index: index,
      isExisting: false,
    );
    setState(() {
      _newImageFiles.removeAt(index);
    });
    if (shouldResetAi) {
      unawaited(_resetAiProductAnalysisForImageChange());
    }
    _scheduleDraftSave();
  }

  void _removeVideo() {
    setState(() {
      if (_existingVideoUrl != null) {
        _localMediaPaths.remove(_existingVideoUrl);
      }
      if (_existingVideoThumbnailUrl != null) {
        _localMediaPaths.remove(_existingVideoThumbnailUrl);
      }
      _videoFile = null;
      _existingVideoUrl = null;
      _existingVideoThumbnailUrl = null;
    });
    _scheduleDraftSave();
  }

  void _prefetchExistingMedia() {
    for (final url in _existingImageUrls) {
      _tryWarmLocalCache(url);
    }
    for (final thumb in _existingThumbnailUrls) {
      _tryWarmLocalCache(thumb);
    }
    if (_existingVideoUrl != null) {
      _tryWarmLocalCache(_existingVideoUrl!);
    }
    if (_existingVideoThumbnailUrl != null) {
      _tryWarmLocalCache(_existingVideoThumbnailUrl!);
    }
  }

  Future<File> _compressImageFile(
    File sourceFile, {
    required bool forThumbnail,
    int? qualityOverride,
    int? minDimensionOverride,
    String? suffixOverride,
  }) async {
    final suffix = suffixOverride ?? (forThumbnail ? 'thumb' : 'full');
    final targetPath =
        '${Directory.systemTemp.path}/product_${DateTime.now().microsecondsSinceEpoch}_$suffix.webp';
    final minDimension = minDimensionOverride ?? (forThumbnail ? 600 : 1600);
    final quality =
        qualityOverride ??
        (forThumbnail ? _thumbnailImageQuality : _uploadImageQuality);

    try {
      final compressed = await FlutterImageCompress.compressAndGetFile(
        sourceFile.path,
        targetPath,
        format: CompressFormat.webp,
        minWidth: minDimension,
        minHeight: minDimension,
        quality: quality,
      );
      if (compressed != null) {
        final compressedFile = File(compressed.path);
        if (await compressedFile.exists()) {
          return compressedFile;
        }
      }
    } catch (e, stack) {
      debugPrint('Image compression failed ($suffix): $e');
      debugPrint('$stack');
    }

    try {
      final sourceBytes = await sourceFile.readAsBytes();
      final compressedBytes = await FlutterImageCompress.compressWithList(
        sourceBytes,
        format: CompressFormat.webp,
        minWidth: minDimension,
        minHeight: minDimension,
        quality: quality,
      );
      if (compressedBytes.isNotEmpty) {
        return await _writeBytesToTempFile(
          compressedBytes,
          suffix: '$suffix.webp',
        );
      }
    } catch (e, stack) {
      debugPrint('Image byte compression failed ($suffix): $e');
      debugPrint('$stack');
    }

    return sourceFile;
  }

  Future<File> _writeBytesToTempFile(
    Uint8List data, {
    required String suffix,
  }) async {
    final tempPath =
        '${Directory.systemTemp.path}/product_${DateTime.now().microsecondsSinceEpoch}_$suffix';
    final file = File(tempPath);
    await file.writeAsBytes(data, flush: true);
    return file;
  }

  Future<String> _uploadFileWithOptionalProgress(
    Reference ref,
    File file, {
    bool trackProgress = false,
    SettableMetadata? metadata,
  }) async {
    final uploadTask = ref.putFile(file, metadata);
    StreamSubscription<TaskSnapshot>? progressSubscription;
    if (trackProgress) {
      progressSubscription = uploadTask.snapshotEvents.listen((event) {
        if (event.totalBytes > 0) {
          if (mounted) {
            setState(() {
              _uploadProgress = event.bytesTransferred / event.totalBytes;
            });
          }
        }
      });
    }

    try {
      final snapshot = await uploadTask.timeout(
        const Duration(minutes: 3),
        onTimeout: () {
          throw TimeoutException('การอัปโหลดไฟล์ใช้เวลานานเกินไป');
        },
      );
      return await snapshot.ref.getDownloadURL().timeout(
        const Duration(seconds: 30),
        onTimeout: () {
          throw TimeoutException('ไม่สามารถรับ URL ของไฟล์ได้');
        },
      );
    } on TimeoutException {
      try {
        await uploadTask.cancel();
      } catch (_) {
        // The upload may already have stopped.
      }
      rethrow;
    } finally {
      await progressSubscription?.cancel();
      if (trackProgress && mounted) {
        setState(() {
          _uploadProgress = null;
        });
      }
    }
  }

  String _extensionFromPath(String path, {required String fallback}) {
    final fileName = path.split(Platform.pathSeparator).last;
    final dotIndex = fileName.lastIndexOf('.');
    if (dotIndex == -1 || dotIndex == fileName.length - 1) {
      return fallback;
    }
    return fileName.substring(dotIndex + 1).toLowerCase();
  }

  String _imageContentTypeFromExtension(String extension) {
    switch (extension.toLowerCase()) {
      case 'webp':
        return 'image/webp';
      case 'png':
        return 'image/png';
      case 'gif':
        return 'image/gif';
      case 'heic':
        return 'image/heic';
      case 'heif':
        return 'image/heif';
      default:
        return 'image/jpeg';
    }
  }

  String _mimeTypeFromPathOrUrl(String pathOrUrl) {
    final normalized = pathOrUrl.toLowerCase();
    if (normalized.endsWith('.png')) return 'image/png';
    if (normalized.endsWith('.webp')) return 'image/webp';
    if (normalized.endsWith('.jpg') || normalized.endsWith('.jpeg')) {
      return 'image/jpeg';
    }
    return 'image/jpeg';
  }

  Future<Uint8List> _downloadBytes(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) {
      throw Exception('URL รูปภาพไม่ถูกต้อง');
    }
    final response = await http.get(uri);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('ดาวน์โหลดรูปไม่สำเร็จ (${response.statusCode})');
    }
    return response.bodyBytes;
  }

  String _createAiRequestId() {
    final uid = FirebaseAuth.instance.currentUser?.uid ?? 'guest';
    final millis = DateTime.now().millisecondsSinceEpoch;
    return '${uid}_${millis}_${DateTime.now().microsecondsSinceEpoch}'
        .replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
  }

  String _formatAiWait(int seconds) {
    if (seconds <= 0) return 'อีกสักครู่';
    if (seconds < 60) return 'ประมาณ $seconds วินาที';
    final minutes = (seconds / 60).ceil();
    return 'ประมาณ $minutes นาที';
  }

  String _buildAiQueueText(Map<String, dynamic> data) {
    final status = (data['status'] ?? '').toString();
    final position = data['position'] is num
        ? (data['position'] as num).toInt()
        : null;
    final estimatedSeconds = data['estimatedWaitSeconds'] is num
        ? (data['estimatedWaitSeconds'] as num).toInt()
        : null;
    final message = (data['message'] ?? '').toString().trim();

    if (status == 'queued') {
      final positionText = position != null && position > 0
          ? 'คิวที่ $position'
          : 'กำลังรอคิว';
      final waitText = estimatedSeconds != null
          ? ' ${_formatAiWait(estimatedSeconds)}'
          : '';
      return '$positionText$waitText';
    }
    if (status == 'processing') {
      return 'ถึงคิวแล้ว กำลังประมวลผล AI...';
    }
    if (status == 'rejected') {
      return message.isNotEmpty
          ? message
          : 'คิว AI เยอะมาก กรุณาลองวิเคราะห์สินค้าใหม่ภายหลัง';
    }
    if (status == 'failed') {
      return message.isNotEmpty ? message : 'AI ประมวลผลไม่สำเร็จ';
    }
    if (status == 'completed') {
      return 'ประมวลผล AI สำเร็จ';
    }
    return 'กำลังส่งคำขอ AI...';
  }

  void _listenAiQueueStatus(String requestId) {
    _aiQueueSubscription?.cancel();
    if (mounted) {
      setState(() {
        _aiQueueStatusText = 'กำลังส่งคำขอ AI...';
        _aiQueueExternalRecommendation = false;
      });
    }

    _aiQueueSubscription = FirebaseFirestore.instance
        .collection('ai_processing_queue')
        .doc(requestId)
        .snapshots()
        .listen(
          (snapshot) {
            if (!mounted || !snapshot.exists) return;
            final data = snapshot.data() ?? <String, dynamic>{};
            setState(() {
              _aiQueueStatusText = _buildAiQueueText(data);
              _aiQueueExternalRecommendation =
                  data['externalAiRecommended'] == true;
            });
          },
          onError: (_) {
            if (!mounted) return;
            setState(() {
              _aiQueueStatusText = 'กำลังเข้าคิว AI...';
              _aiQueueExternalRecommendation = false;
            });
          },
        );
  }

  void _clearAiQueueStatus() {
    _aiQueueSubscription?.cancel();
    _aiQueueSubscription = null;
    if (!mounted) return;
    setState(() {
      _aiQueueStatusText = null;
      _aiQueueExternalRecommendation = false;
    });
  }

  String _aiFunctionErrorMessage(FirebaseFunctionsException e) {
    final details = e.details;
    if (details is Map && details['externalAiRecommended'] == true) {
      final position = details['queuePosition'] is num
          ? (details['queuePosition'] as num).toInt()
          : null;
      final estimatedSeconds = details['estimatedWaitSeconds'] is num
          ? (details['estimatedWaitSeconds'] as num).toInt()
          : null;
      final queueText = position != null
          ? 'คิวที่ $position'
          : 'คิว AI เยอะมาก';
      final waitText = estimatedSeconds != null
          ? ' ${_formatAiWait(estimatedSeconds)}'
          : '';
      return '$queueText$waitText ระบบ AI ยังไม่พร้อม กรุณาลองใหม่ภายหลัง';
    }
    if (e.code == 'deadline-exceeded') {
      return 'AI ใช้เวลานานเกินไป (คิวเต็มหรือเครือข่ายช้า) กรุณารอสักครู่แล้วลองใหม่';
    }
    return e.message ?? 'AI วิเคราะห์สินค้าไม่สำเร็จ (${e.code})';
  }

  int? _parseAiConfidence(Object? value) {
    if (value is int) {
      return value.clamp(0, 100);
    }
    if (value is double) {
      return value.round().clamp(0, 100);
    }
    final parsed = int.tryParse(value?.toString() ?? '');
    if (parsed == null) {
      return null;
    }
    return parsed.clamp(0, 100);
  }

  double? _parseParcelDimensionCm(Object? value) {
    if (value is num) {
      final parsed = value.toDouble();
      if (parsed > 0 && parsed <= 200) {
        return parsed;
      }
      return null;
    }
    final parsed = double.tryParse(value?.toString().trim() ?? '');
    if (parsed == null || parsed <= 0 || parsed > 200) {
      return null;
    }
    return parsed;
  }

  String _formatParcelDimensionCm(double value) {
    final rounded = (value * 10).round() / 10;
    if (rounded == rounded.roundToDouble()) {
      return rounded.toInt().toString();
    }
    return rounded.toStringAsFixed(1);
  }

  void _applyParcelDimensionField({
    required TextEditingController controller,
    required double? value,
  }) {
    if (value == null || controller.text.trim().isNotEmpty) {
      return;
    }
    controller.text = _formatParcelDimensionCm(value);
  }

  bool get _canApplyAiSaleUnit {
    if (widget.productToEdit != null &&
        widget.productToEdit!.unit.trim().isNotEmpty) {
      return false;
    }
    return _selectedUnit == 'ชิ้น' && _otherUnitController.text.trim().isEmpty;
  }

  void _applyAiSaleUnit(String? saleUnit) {
    final normalized = saleUnit?.trim();
    if (normalized == null || normalized.isEmpty || !_canApplyAiSaleUnit) {
      return;
    }
    if (_units.contains(normalized)) {
      _selectedUnit = normalized;
      _otherUnitController.clear();
      _aiAppliedSaleUnit = true;
      return;
    }
    _selectedUnit = 'อื่นๆ';
    _otherUnitController.text = normalized;
    _aiAppliedSaleUnit = true;
  }

  List<String>? _parseAiStringList(Object? value) {
    if (value is! List) {
      return null;
    }
    final labels = <String>[];
    for (final entry in value) {
      final text = entry?.toString().trim() ?? '';
      if (text.isNotEmpty) {
        labels.add(text);
      }
    }
    if (labels.isEmpty) {
      return null;
    }
    return List<String>.unmodifiable(labels);
  }

  bool _requiresAdminAiReview() {
    if (_isEditingExistingProduct) {
      return false;
    }
    if (_aiRequiresAdminReview == true) {
      return true;
    }
    if (_aiIsLegalInThailand == false) {
      return true;
    }
    if (!_hasUsedAiProductAnalysisForProduct) {
      return false;
    }

    final confidences = <int?>[
      _aiProductNameConfidence,
      _aiTaxConfidence,
      _aiProductTypeConfidence,
      _aiNationwideShippingConfidence,
      _aiLegalConfidence,
    ];
    return confidences.any(
      (int? score) => score == null || score < _kAiConfidenceThreshold,
    );
  }

  Map<String, dynamic> _aiConfidenceProductFields() {
    return <String, dynamic>{
      if (_aiProductNameConfidence != null)
        'aiProductNameConfidence': _aiProductNameConfidence,
      if (_aiTaxConfidence != null) 'aiTaxConfidence': _aiTaxConfidence,
      if (_aiProductTypeConfidence != null)
        'aiProductTypeConfidence': _aiProductTypeConfidence,
      if (_aiNationwideShippingConfidence != null)
        'aiNationwideShippingConfidence': _aiNationwideShippingConfidence,
      if (_aiLegalConfidence != null) 'aiLegalConfidence': _aiLegalConfidence,
      'aiRequiresAdminReview': _requiresAdminAiReview(),
      if (_aiReviewReasonLabels.isNotEmpty)
        'aiReviewReasonLabels': _aiReviewReasonLabels,
    };
  }

  bool _productHasCompletedAiAnalysis(Product product) {
    if (!product.aiProductAnalysisRequested) {
      return false;
    }
    return product.aiProductType?.trim().isNotEmpty == true ||
        product.aiIsLegalInThailand != null ||
        product.taxAiReason?.trim().isNotEmpty == true ||
        product.aiLegalAnalysisReason?.trim().isNotEmpty == true;
  }

  HttpsCallable _aiCallable(String name) {
    return FirebaseFunctions.instanceFor(
      region: 'asia-southeast1',
    ).httpsCallable(
      name,
      options: HttpsCallableOptions(timeout: _aiCallableTimeout),
    );
  }

  Future<_AiProductAnalysisResult> _requestProductAnalysis({
    required Uint8List imageBytes,
    required String mimeType,
  }) async {
    final requestId = _createAiRequestId();
    _listenAiQueueStatus(requestId);
    final callable = _aiCallable('analyzeProductWithAi');
    try {
      final response = await callable.call(<String, dynamic>{
        'requestId': requestId,
        'imageBase64': base64Encode(imageBytes),
        'mimeType': mimeType,
        'productName': _nameController.text.trim(),
        'description': _productDescriptionController.text.trim(),
        'category': (_selectedProductCategory ?? '').trim(),
        'price': _priceController.text.trim(),
        'unit': _selectedUnit == 'อื่นๆ'
            ? _otherUnitController.text.trim()
            : (_selectedUnit ?? '').trim(),
        'weight': _weightController.text.trim(),
        'weightUnit': _weightUnit,
      });
      final data = response.data;
      if (data is! Map) {
        throw Exception('รูปแบบข้อมูลจาก AI ไม่ถูกต้อง');
      }
      return _AiProductAnalysisResult(
        productName: (data['productName'] ?? '').toString().trim(),
        description: (data['description'] ?? '').toString().trim(),
        taxStatus: (data['taxStatus'] ?? '').toString().trim(),
        taxReason: (data['taxReason'] ?? '').toString().trim(),
        productCategory: (data['productCategory'] ?? '').toString().trim(),
        productType: (data['productType'] ?? '').toString().trim(),
        isLegalInThailand: data['isLegalInThailand'] is bool
            ? data['isLegalInThailand'] as bool
            : null,
        legalReason: (data['legalReason'] ?? '').toString().trim(),
        isFreshProduct: data['isFreshProduct'] is bool
            ? data['isFreshProduct'] as bool
            : null,
        isProcessed: data['isProcessed'] is bool
            ? data['isProcessed'] as bool
            : null,
        canShipNationwide: data['canShipNationwide'] is bool
            ? data['canShipNationwide'] as bool
            : null,
        nationwideShippingReason: (data['nationwideShippingReason'] ?? '')
            .toString()
            .trim(),
        productNameConfidence: _parseAiConfidence(
          data['productNameConfidence'],
        ),
        taxConfidence: _parseAiConfidence(data['taxConfidence']),
        productTypeConfidence: _parseAiConfidence(
          data['productTypeConfidence'],
        ),
        nationwideShippingConfidence: _parseAiConfidence(
          data['nationwideShippingConfidence'],
        ),
        legalConfidence: _parseAiConfidence(data['legalConfidence']),
        parcelLengthCm: _parseParcelDimensionCm(data['parcelLengthCm']),
        parcelWidthCm: _parseParcelDimensionCm(data['parcelWidthCm']),
        parcelHeightCm: _parseParcelDimensionCm(data['parcelHeightCm']),
        parcelDimensionReason: (data['parcelDimensionReason'] ?? '')
            .toString()
            .trim(),
        parcelDimensionConfidence: _parseAiConfidence(
          data['parcelDimensionConfidence'],
        ),
        saleUnit: (data['saleUnit'] ?? '').toString().trim(),
        requiresAdminReview: data['requiresAdminReview'] is bool
            ? data['requiresAdminReview'] as bool
            : null,
        reviewReasonLabels: _parseAiStringList(data['reviewReasonLabels']),
      );
    } finally {
      _clearAiQueueStatus();
    }
  }

  Future<({Uint8List bytes, String mimeType})?> _readProductImageForAi() async {
    if (_newImageFiles.isNotEmpty) {
      final file = _newImageFiles.first;
      return (
        bytes: await File(file.path).readAsBytes(),
        mimeType: _mimeTypeFromPathOrUrl(file.path),
      );
    }

    if (_existingImageUrls.isNotEmpty) {
      final sourceUrl = _existingThumbnailUrls.isNotEmpty
          ? _existingThumbnailUrls.first
          : _existingImageUrls.first;
      return (
        bytes: await _downloadBytes(sourceUrl),
        mimeType: _mimeTypeFromPathOrUrl(sourceUrl),
      );
    }

    if (_videoFile != null) {
      final thumbBytes = await VideoCompress.getByteThumbnail(
        _videoFile!.path,
        quality: 75,
        position: -1,
      );
      if (thumbBytes != null && thumbBytes.isNotEmpty) {
        return (bytes: thumbBytes, mimeType: 'image/jpeg');
      }
    }

    if ((_existingVideoThumbnailUrl ?? '').isNotEmpty) {
      return (
        bytes: await _downloadBytes(_existingVideoThumbnailUrl!),
        mimeType: _mimeTypeFromPathOrUrl(_existingVideoThumbnailUrl!),
      );
    }

    return null;
  }

  void _applyAiProductAnalysis(_AiProductAnalysisResult result) {
    if (!_isEditingExistingProduct &&
        (_aiAnalysisDiscarded || _currentImageCount == 0)) {
      return;
    }

    final productName = result.productName?.trim();
    final description = result.description?.trim();
    final category = result.productCategory?.trim();
    final productType = result.productType?.trim();
    final taxStatus = result.taxStatus?.trim().toLowerCase();
    final taxReason = result.taxReason?.trim();
    final legalReason = result.legalReason?.trim();
    final nationwideReason = result.nationwideShippingReason?.trim();

    setState(() {
      if (productName != null &&
          productName.isNotEmpty &&
          _nameController.text.trim().isEmpty) {
        _nameController.text = productName;
      }

      if (description != null && description.isNotEmpty) {
        _productDescriptionController.text = description;
        _hasUsedAiDescriptionForProduct = true;
      }

      if (category != null &&
          category.isNotEmpty &&
          _productCategories.contains(category)) {
        _selectedProductCategory = category;
      } else if ((_selectedProductCategory ?? '').isEmpty) {
        _selectedProductCategory = taxStatus == 'exempt'
            ? 'ของสด'
            : 'สินค้าทั่วไป';
      }

      if (_isPharmacyCategory) {
        _isFreshProduct = false;
        _isProcessed = false;
        if (taxStatus == 'taxable' || taxStatus == 'exempt') {
          _pharmacyIsTaxable = taxStatus == 'taxable';
        }
      } else if (result.isFreshProduct != null || result.isProcessed != null) {
        _isFreshProduct = result.isFreshProduct ?? _isFreshProduct;
        _isProcessed = result.isProcessed ?? _isProcessed;
      } else if (taxStatus == 'exempt') {
        _isFreshProduct = true;
        _isProcessed = false;
      } else if (taxStatus == 'taxable') {
        _isFreshProduct = false;
        _isProcessed = true;
      }

      if (taxReason != null && taxReason.isNotEmpty) {
        _aiTaxAnalysisReason = taxReason;
      }

      if (productType != null && productType.isNotEmpty) {
        _aiProductType = productType;
      }

      if (result.isLegalInThailand != null) {
        _aiIsLegalInThailand = result.isLegalInThailand;
      }
      if (legalReason != null && legalReason.isNotEmpty) {
        _aiLegalAnalysisReason = legalReason;
      }

      if (taxStatus == 'taxable' ||
          taxStatus == 'exempt' ||
          (taxReason != null && taxReason.isNotEmpty)) {
        _hasAiTaxAnalysis = true;
      }

      if (result.canShipNationwide != null) {
        _aiCanShipNationwide = result.canShipNationwide;
      }
      if (nationwideReason != null && nationwideReason.isNotEmpty) {
        _aiNationwideShippingReason = nationwideReason;
      }

      _applyParcelDimensionField(
        controller: _parcelLengthController,
        value: result.parcelLengthCm,
      );
      _applyParcelDimensionField(
        controller: _parcelWidthController,
        value: result.parcelWidthCm,
      );
      _applyParcelDimensionField(
        controller: _parcelHeightController,
        value: result.parcelHeightCm,
      );
      final parcelReason = result.parcelDimensionReason?.trim();
      if (parcelReason != null && parcelReason.isNotEmpty) {
        _aiParcelDimensionReason = parcelReason;
      }

      _applyAiSaleUnit(result.saleUnit);

      _aiProductNameConfidence = result.productNameConfidence;
      _aiTaxConfidence = result.taxConfidence;
      _aiProductTypeConfidence = result.productTypeConfidence;
      _aiNationwideShippingConfidence = result.nationwideShippingConfidence;
      _aiLegalConfidence = result.legalConfidence;
      _aiRequiresAdminReview = result.requiresAdminReview;
      _aiReviewReasonLabels = List<String>.from(
        result.reviewReasonLabels ?? const <String>[],
      );
    });
    _scheduleDraftSave();
    final cacheImagePath =
        _newImageFiles.isNotEmpty ? _newImageFiles.first.path : null;
    unawaited(
      _saveAiResultToImageCache(result, imagePath: cacheImagePath),
    );
  }

  Future<void> _saveAiResultToImageCache(
    _AiProductAnalysisResult result, {
    String? imagePath,
  }) async {
    if (_isEditingExistingProduct) {
      return;
    }
    final ownerUid = _effectiveOwnerUid;
    if (ownerUid == null || ownerUid.isEmpty) {
      return;
    }
    Uint8List? bytes;
    if (imagePath != null && imagePath.isNotEmpty && !kIsWeb) {
      try {
        final file = File(imagePath);
        if (await file.exists()) {
          bytes = await file.readAsBytes();
        }
      } catch (_) {}
    }
    bytes ??= (await _readProductImageForAi())?.bytes;
    if (bytes == null || bytes.isEmpty) {
      return;
    }
    await ProductAiImageCache.instance.save(
      ownerUid: ownerUid,
      imageBytes: bytes,
      aiResult: result.toJson(),
    );
  }

  Future<bool> _restoreCachedAiForCurrentImage() async {
    if (_isEditingExistingProduct || _currentImageCount == 0) {
      return false;
    }
    final ownerUid = _effectiveOwnerUid;
    if (ownerUid == null || ownerUid.isEmpty) {
      return false;
    }
    final source = await _readProductImageForAi();
    if (source == null || source.bytes.isEmpty) {
      return false;
    }
    final cached = await ProductAiImageCache.instance.find(
      ownerUid: ownerUid,
      imageBytes: source.bytes,
    );
    if (cached == null || !mounted) {
      return false;
    }
    if (_currentImageCount == 0) {
      return false;
    }
    _aiAnalysisDiscarded = false;
    _applyAiProductAnalysis(_aiResultFromDynamicMap(cached));
    if (mounted) {
      setState(() {
        _hasUsedAiProductAnalysisForProduct = true;
        _isAnalyzingProductWithAi = false;
        _aiQueueStatusText = null;
      });
    }
    return true;
  }

  Future<void> _analyzeProductWithAi({bool automatic = false}) async {
    if (_hasUsedAiProductAnalysisForProduct) {
      if (automatic) return;
      _showSnack(
        'สินค้านี้ใช้ AI วิเคราะห์สินค้าไปแล้ว ใช้ได้ 1 ครั้งต่อสินค้า',
      );
      return;
    }

    if (await _restoreCachedAiForCurrentImage()) {
      return;
    }

    if (_isAnalyzingProductWithAi && _draftPersistenceEnabled) {
      if (automatic) return;
      _showSnack(
        'กำลังให้ AI วิเคราะห์อยู่ — ออกจากหน้านี้ได้ ระบบจะเก็บข้อมูลไว้',
      );
      return;
    }

    final productName = _nameController.text.trim();
    if (!automatic && productName.isEmpty) {
      _showSnack('กรุณากรอกชื่อสินค้าก่อนให้ AI วิเคราะห์');
      return;
    }

    if (_draftPersistenceEnabled) {
      if (_currentImageCount == 0) {
        _showSnack('กรุณาเพิ่มรูปสินค้าก่อนให้ AI วิเคราะห์');
        return;
      }

      setState(() {
        _isAnalyzingProductWithAi = true;
      });

      try {
        await _ensureDraftReadyForAi();
        if (!mounted || _aiAnalysisDiscarded || _currentImageCount == 0) {
          if (mounted) {
            setState(() => _isAnalyzingProductWithAi = false);
          }
          return;
        }
        await _enqueueProductAiAnalysis(automatic: automatic);
      } on FirebaseFunctionsException catch (e) {
        if (mounted) {
          setState(() => _isAnalyzingProductWithAi = false);
        }
        final message = _aiFunctionErrorMessage(e);
        debugPrint('enqueueProductAiAnalysis failed: ${e.code} $message');
        _showSnack(
          automatic
              ? 'AI วิเคราะห์อัตโนมัติไม่สำเร็จ — กดปุ่ม "วิเคราะห์สินค้า" เพื่อลองอีกครั้ง'
              : message,
        );
      } catch (e) {
        if (mounted) {
          setState(() => _isAnalyzingProductWithAi = false);
        }
        debugPrint('enqueueProductAiAnalysis failed: $e');
        _showSnack(
          automatic
              ? 'AI วิเคราะห์อัตโนมัติไม่สำเร็จ — กดปุ่ม "วิเคราะห์สินค้า" เพื่อลองอีกครั้ง'
              : 'AI วิเคราะห์สินค้าไม่สำเร็จ: $e',
        );
      }
      return;
    }

    final source = await _readProductImageForAi();
    if (source == null || source.bytes.isEmpty) {
      _showSnack('กรุณาเพิ่มรูปสินค้าก่อนให้ AI วิเคราะห์');
      return;
    }
    if (!mounted || _aiAnalysisDiscarded || _currentImageCount == 0) {
      return;
    }

    _aiAnalysisDiscarded = false;
    setState(() {
      _isAnalyzingProductWithAi = true;
    });

    final analysisEpoch = _aiAnalysisEpoch;
    try {
      final result = await _requestProductAnalysis(
        imageBytes: source.bytes,
        mimeType: source.mimeType,
      );
      if (!mounted) return;
      if (analysisEpoch != _aiAnalysisEpoch || _aiAnalysisDiscarded) {
        return;
      }
      _applyAiProductAnalysis(result);
      setState(() => _hasUsedAiProductAnalysisForProduct = true);
      await _persistProductAiUsageFlag('aiProductAnalysisRequested');
      if (!automatic) {
        _showSnack('AI วิเคราะห์สินค้าเรียบร้อยแล้ว');
      }
    } on FirebaseFunctionsException catch (e) {
      await _clearProductAiUsageFlag('aiProductAnalysisRequested');
      if (mounted) {
        setState(() => _hasUsedAiProductAnalysisForProduct = false);
      }
      final message = _aiFunctionErrorMessage(e);
      debugPrint('analyzeProductWithAi failed: ${e.code} $message');
      _showSnack(
        automatic
            ? 'AI วิเคราะห์อัตโนมัติไม่สำเร็จ — กดปุ่ม "วิเคราะห์สินค้า" เพื่อลองอีกครั้ง'
            : message,
      );
    } catch (e) {
      await _clearProductAiUsageFlag('aiProductAnalysisRequested');
      if (mounted) {
        setState(() => _hasUsedAiProductAnalysisForProduct = false);
      }
      debugPrint('analyzeProductWithAi failed: $e');
      _showSnack(
        automatic
            ? 'AI วิเคราะห์อัตโนมัติไม่สำเร็จ — กดปุ่ม "วิเคราะห์สินค้า" เพื่อลองอีกครั้ง'
            : 'AI วิเคราะห์สินค้าไม่สำเร็จ: $e',
      );
    } finally {
      if (mounted) {
        setState(() => _isAnalyzingProductWithAi = false);
      }
    }
  }

  Future<void> _persistProductAiUsageFlag(String field) async {
    final targetId = widget.productToEdit?.id;
    if (targetId == null || targetId.isEmpty) return;

    try {
      await FirebaseFirestore.instance
          .collection('products')
          .doc(targetId)
          .update(<String, dynamic>{
            field: true,
            'updatedAt': FieldValue.serverTimestamp(),
          });
    } catch (e) {
      debugPrint('Failed to persist $field on product $targetId: $e');
    }
  }

  Future<void> _clearProductAiUsageFlag(String field) async {
    final targetId = widget.productToEdit?.id;
    if (targetId == null || targetId.isEmpty) return;

    try {
      await FirebaseFirestore.instance
          .collection('products')
          .doc(targetId)
          .update(<String, dynamic>{
            field: false,
            'updatedAt': FieldValue.serverTimestamp(),
          });
    } catch (e) {
      debugPrint('Failed to clear $field on product $targetId: $e');
    }
  }

  Future<_ProductImageUploadResult?> _uploadImageToFirebase(XFile image) async {
    try {
      final ownerUid = _effectiveOwnerUid;
      if (ownerUid == null) throw Exception("User not logged in");

      if (kIsWeb) {
        final result = await uploadProductImageWeb(
          image: image,
          ownerUid: ownerUid,
          uploadQuality: _uploadImageQuality,
          thumbnailQuality: _thumbnailImageQuality,
          onProgress: (progress) {
            if (mounted) {
              setState(() => _uploadProgress = progress);
            }
          },
        );
        if (mounted) {
          setState(() => _uploadProgress = null);
        }
        if (result == null) {
          return null;
        }
        return _ProductImageUploadResult(
          originalUrl: result.originalUrl,
          thumbnailUrl: result.thumbnailUrl,
        );
      }

      final sanitizedBase = image.name
          .split('.')
          .first
          .replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');

      final sourceFile = File(image.path);
      final originalUploadFile = _isPrecompressedProductImage(sourceFile.path)
          ? sourceFile
          : await _compressImageFile(sourceFile, forThumbnail: false);
      final thumbnailBase = originalUploadFile;
      final compressedThumbnail = await _compressImageFile(
        thumbnailBase,
        forThumbnail: true,
      );
      final originalExtension = _extensionFromPath(
        originalUploadFile.path,
        fallback: 'jpg',
      );
      final thumbnailExtension = _extensionFromPath(
        compressedThumbnail.path,
        fallback: 'jpg',
      );
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final fileName = '${timestamp}_$sanitizedBase.$originalExtension';
      final thumbnailFileName =
          '${timestamp}_${sanitizedBase}_thumb.$thumbnailExtension';
      final originalMetadata = SettableMetadata(
        contentType: _imageContentTypeFromExtension(originalExtension),
      );
      final thumbnailMetadata = SettableMetadata(
        contentType: _imageContentTypeFromExtension(thumbnailExtension),
      );

      final baseRef = StorageHelper.instance
          .ref()
          .child('product_images')
          .child(ownerUid);

      final originalUrl = await _uploadFileWithOptionalProgress(
        baseRef.child(fileName),
        originalUploadFile,
        trackProgress: true,
        metadata: originalMetadata,
      );
      final thumbnailUrl = await _uploadFileWithOptionalProgress(
        baseRef.child('thumbnails').child(thumbnailFileName),
        compressedThumbnail,
        metadata: thumbnailMetadata,
      );

      final cachedOriginal = await MediaCacheService.instance.cacheUploadedFile(
        source: originalUploadFile,
        url: originalUrl,
        bucket: MediaCacheBucket.image,
      );
      final cachedThumbnail = await MediaCacheService.instance
          .cacheUploadedFile(
            source: compressedThumbnail,
            url: thumbnailUrl,
            bucket: MediaCacheBucket.thumbnail,
          );

      try {
        if (originalUploadFile.path != sourceFile.path &&
            await originalUploadFile.exists()) {
          await originalUploadFile.delete();
        }
        if (compressedThumbnail.path != sourceFile.path &&
            await compressedThumbnail.exists()) {
          await compressedThumbnail.delete();
        }
      } catch (cleanupError) {
        debugPrint('Failed to delete temp files: $cleanupError');
      }

      return _ProductImageUploadResult(
        originalUrl: originalUrl,
        thumbnailUrl: thumbnailUrl,
        originalLocalPath: cachedOriginal?.path,
        thumbnailLocalPath: cachedThumbnail?.path,
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('เกิดข้อผิดพลาดในการอัปโหลดรูป: $e')),
        );
      }
      setState(() {
        _uploadProgress = null;
      });
      return null;
    }
  }

  bool _isPrecompressedProductImage(String path) {
    final normalized = path.toLowerCase();
    return normalized.endsWith('.webp') &&
        normalized.contains('product_') &&
        normalized.contains('_pick');
  }

  Future<_ProductVideoUploadResult?> _uploadVideoToFirebase(XFile video) async {
    File? compressedFile;
    File? rawThumbFile;
    File? compressedThumbFile;
    try {
      final ownerUid = _effectiveOwnerUid;
      if (ownerUid == null) throw Exception('User not logged in');

      if (kIsWeb) {
        final result = await uploadProductVideoWeb(
          video: video,
          ownerUid: ownerUid,
          onProgress: (progress) {
            if (mounted) {
              setState(() => _uploadProgress = progress);
            }
          },
        );
        if (mounted) {
          setState(() => _uploadProgress = null);
        }
        if (result == null) {
          return null;
        }
        return _ProductVideoUploadResult(
          videoUrl: result.videoUrl,
          thumbnailUrl: result.thumbnailUrl,
        );
      }

      final sanitizedBase = video.name
          .split('.')
          .first
          .replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final videoFileName = '${timestamp}_$sanitizedBase.mp4';
      final refBase = StorageHelper.instance
          .ref()
          .child('product_videos')
          .child(ownerUid);

      final originalFile = File(video.path);
      File fileToUpload = await _compressProductVideoIfNeeded(originalFile);
      if (fileToUpload.path != originalFile.path) {
        compressedFile = fileToUpload;
      }

      final videoUrl = await _uploadFileWithOptionalProgress(
        refBase.child(videoFileName),
        fileToUpload,
        trackProgress: true,
      );

      String? thumbnailUrl;
      File? cachedVideoFile;
      File? cachedVideoThumb;
      try {
        final thumbBytes = await VideoCompress.getByteThumbnail(
          fileToUpload.path,
          quality: 70,
          position: -1,
        );
        if (thumbBytes != null) {
          rawThumbFile = await _writeBytesToTempFile(
            thumbBytes,
            suffix: 'video_thumb.jpg',
          );
          compressedThumbFile = await _compressImageFile(
            rawThumbFile,
            forThumbnail: true,
          );
          final thumbExtension = _extensionFromPath(
            compressedThumbFile.path,
            fallback: 'jpg',
          );
          final thumbName =
              '${timestamp}_${sanitizedBase}_thumb.$thumbExtension';
          thumbnailUrl = await _uploadFileWithOptionalProgress(
            refBase.child('thumbnails').child(thumbName),
            compressedThumbFile,
            metadata: SettableMetadata(
              contentType: _imageContentTypeFromExtension(thumbExtension),
            ),
          );
        }
      } catch (thumbError, stack) {
        debugPrint('Video thumbnail generation failed: $thumbError');
        debugPrint('$stack');
      }

      cachedVideoFile = await MediaCacheService.instance.cacheUploadedFile(
        source: fileToUpload,
        url: videoUrl,
        bucket: MediaCacheBucket.video,
      );
      if (thumbnailUrl != null && compressedThumbFile != null) {
        cachedVideoThumb = await MediaCacheService.instance.cacheUploadedFile(
          source: compressedThumbFile,
          url: thumbnailUrl,
          bucket: MediaCacheBucket.videoThumbnail,
        );
      }

      return _ProductVideoUploadResult(
        videoUrl: videoUrl,
        thumbnailUrl: thumbnailUrl,
        localVideoPath: cachedVideoFile?.path,
        localThumbnailPath: cachedVideoThumb?.path,
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('เกิดข้อผิดพลาดในการอัปโหลดวิดีโอ: $e')),
        );
      }
      setState(() {
        _uploadProgress = null;
      });
      return null;
    } finally {
      try {
        if (compressedFile != null && await compressedFile.exists()) {
          await compressedFile.delete();
        }
        if (rawThumbFile != null && await rawThumbFile.exists()) {
          await rawThumbFile.delete();
        }
        if (compressedThumbFile != null && await compressedThumbFile.exists()) {
          await compressedThumbFile.delete();
        }
        await VideoCompress.deleteAllCache();
      } catch (cleanupError) {
        debugPrint('Video temp cleanup failed: $cleanupError');
      }
    }
  }

  Future<void> _generateAiDescription() async {
    if (_hasUsedAiDescriptionForProduct) {
      _showSnack('สินค้านี้ใช้ AI เขียนคำอธิบายไปแล้ว ใช้ได้ 1 ครั้งต่อสินค้า');
      return;
    }

    final productName = _nameController.text.trim();
    if (productName.isEmpty) {
      _showSnack('กรุณากรอกชื่อสินค้าก่อนให้ AI ช่วยเขียนคำอธิบาย');
      return;
    }

    final category = (_selectedProductCategory ?? '').trim();
    final price = _priceController.text.trim();
    final unit = _selectedUnit == 'อื่นๆ'
        ? _otherUnitController.text.trim()
        : (_selectedUnit ?? '').trim();
    final stock = _stockController.text.trim();

    setState(() {
      _isGeneratingAiDescription = true;
      _hasUsedAiDescriptionForProduct = true;
    });
    await _persistProductAiUsageFlag('aiDescriptionRequested');

    final requestId = _createAiRequestId();
    _listenAiQueueStatus(requestId);
    try {
      final callable = _aiCallable('askGeminiFlash');
      final response = await callable.call(<String, dynamic>{
        'requestId': requestId,
        'prompt':
            'ช่วยเขียนคำอธิบายสินค้าเป็นภาษาไทยประมาณ 2 บรรทัด อ่านเป็นธรรมชาติ น่าเชื่อถือ และเน้นการขายสำหรับร้านค้าออนไลน์',
        'productName': productName,
        'category': category,
        'price': price,
        'unit': unit,
        'stock': stock,
      });

      final data = response.data;
      final text = data is Map<String, dynamic>
          ? (data['text']?.toString().trim() ?? '')
          : '';

      if (text.isEmpty) {
        _showSnack('AI ไม่ได้ส่งข้อความกลับมา ลองอีกครั้ง');
        return;
      }

      _productDescriptionController.text = text;
      _showSnack('เติมคำอธิบายสินค้าจาก AI แล้ว');
    } on FirebaseFunctionsException catch (e) {
      _showSnack(_aiFunctionErrorMessage(e));
    } catch (e) {
      _showSnack('เรียก AI ไม่สำเร็จ: $e');
    } finally {
      _clearAiQueueStatus();
      if (mounted) {
        setState(() => _isGeneratingAiDescription = false);
      }
    }
  }

  Future<Map<String, dynamic>> _loadExistingProductData() async {
    final targetId = widget.productToEdit?.id?.trim();
    if (targetId == null || targetId.isEmpty) {
      return const <String, dynamic>{};
    }
    final snapshot = await FirebaseFirestore.instance
        .collection('products')
        .doc(targetId)
        .get();
    return snapshot.data() ?? const <String, dynamic>{};
  }

  Future<void> _saveProduct() async {
    if (!_validateBasicProductFields(requirePriceStock: !_hasVariants)) {
      return;
    }

    final String weightValue = '${_weightController.text.trim()} $_weightUnit';
    final weightAmount = double.tryParse(_weightController.text.trim()) ?? 0;
    final parcelWeightGrams = _weightUnit == 'kg'
        ? (weightAmount * 1000).round()
        : weightAmount.round();
    final parcelLengthCm = double.tryParse(_parcelLengthController.text.trim());
    final parcelWidthCm = double.tryParse(_parcelWidthController.text.trim());
    final parcelHeightCm = double.tryParse(_parcelHeightController.text.trim());

    if (_hasVariants) {
      final variantError = ProductVariantSupport.validateDrafts(_variantDrafts);
      if (variantError != null) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(variantError)));
        return;
      }
    }

    final preparationTimeMinutes = int.tryParse(
      _preparationTimeController.text.trim(),
    )!;

    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('ไม่พบข้อมูลผู้ใช้ กรุณาล็อกอินใหม่')),
      );
      return;
    }

    final ownerUid = _effectiveOwnerUid;
    if (ownerUid == null || ownerUid.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('ไม่พบข้อมูลร้านที่ต้องการอัปโหลด')),
      );
      return;
    }

    setState(() {
      _isSaving = true;
      _uploadStatusText = 'กำลังเตรียมข้อมูล';
    });

    try {
      if (_draftPersistenceEnabled) {
        // The local/remote draft is a safety net, not a prerequisite for save.
        unawaited(_persistDraftNow());
        unawaited(
          _persistDraftPatch(<String, dynamic>{'productSaveStatus': 'saving'}),
        );
      }

      final Map<String, dynamic>? lockedExistingData = _isEditingExistingProduct
          ? await _runSaveStep(
              'กำลังโหลดข้อมูลสินค้าเดิม',
              _loadExistingProductData(),
            )
          : null;

      final List<String> imageUrls;
      final List<String> thumbnailUrls;
      if (lockedExistingData != null) {
        imageUrls = List<String>.from(
          lockedExistingData['imageUrls'] ?? const <String>[],
        );
        thumbnailUrls = List<String>.from(
          lockedExistingData['thumbnailUrls'] ??
              lockedExistingData['imageUrls'] ??
              const <String>[],
        );
      } else {
        imageUrls = List<String>.from(_existingImageUrls);
        thumbnailUrls = List<String>.from(_existingThumbnailUrls);
      }

      if (!_isEditingExistingProduct && _newImageFiles.isNotEmpty) {
        for (var index = 0; index < _newImageFiles.length; index++) {
          if (mounted) {
            setState(() {
              _uploadStatusText =
                  'กำลังอัปโหลดรูป ${index + 1}/${_newImageFiles.length}';
            });
          }
          final result = await _uploadImageToFirebase(_newImageFiles[index]);
          if (result == null) {
            throw Exception('การอัปโหลดรูปภาพบางรายการล้มเหลว');
          }
          imageUrls.add(result.originalUrl);
          thumbnailUrls.add(result.thumbnailUrl);
          if (result.originalLocalPath != null) {
            _localMediaPaths[result.originalUrl] = result.originalLocalPath!;
          }
          if (result.thumbnailLocalPath != null) {
            _localMediaPaths[result.thumbnailUrl] = result.thumbnailLocalPath!;
          }
        }
      }
      if (mounted) {
        setState(() => _uploadStatusText = null);
      }

      if (!_isEditingExistingProduct && imageUrls.length > _maxImageCount) {
        imageUrls.removeRange(_maxImageCount, imageUrls.length);
        if (thumbnailUrls.length > _maxImageCount) {
          thumbnailUrls.removeRange(_maxImageCount, thumbnailUrls.length);
        }
      }

      // Ensure thumbnail list mirrors images for legacy data edge cases.
      while (thumbnailUrls.length < imageUrls.length) {
        thumbnailUrls.add(imageUrls[thumbnailUrls.length]);
      }
      if (thumbnailUrls.length > imageUrls.length) {
        thumbnailUrls.removeRange(imageUrls.length, thumbnailUrls.length);
      }

      List<ProductVariant> resolvedVariants = <ProductVariant>[];
      if (_hasVariants) {
        resolvedVariants = ProductVariantSupport.bindDraftsToUploadedImages(
          drafts: _variantDrafts,
          imageUrls: imageUrls,
          thumbnailUrls: thumbnailUrls,
        );
        if (resolvedVariants.isEmpty) {
          throw Exception('ไม่พบตัวเลือกสินค้าที่ถูกต้อง');
        }
      }

      String? videoUrl = _existingVideoUrl;
      String? videoThumbnailUrl = _existingVideoThumbnailUrl;
      if (lockedExistingData != null) {
        videoUrl = lockedExistingData['videoUrl'] as String?;
        videoThumbnailUrl = lockedExistingData['videoThumbnailUrl'] as String?;
      } else if (_videoFile != null) {
        if (mounted) {
          setState(() {
            _uploadStatusText = 'กำลังอัปโหลดวิดีโอ';
          });
        }
        final uploadedVideo = await _uploadVideoToFirebase(_videoFile!);
        if (uploadedVideo != null) {
          videoUrl = uploadedVideo.videoUrl;
          videoThumbnailUrl = uploadedVideo.thumbnailUrl;
          if (uploadedVideo.localVideoPath != null) {
            _localMediaPaths[uploadedVideo.videoUrl] =
                uploadedVideo.localVideoPath!;
          }
          if (uploadedVideo.localThumbnailPath != null &&
              uploadedVideo.thumbnailUrl != null) {
            _localMediaPaths[uploadedVideo.thumbnailUrl!] =
                uploadedVideo.localThumbnailPath!;
          }
        } else {
          throw Exception('การอัปโหลดวิดีโอล้มเหลว');
        }
        if (mounted) {
          setState(() => _uploadStatusText = null);
        }
      }

      final productDescription = _productDescriptionController.text.trim();
      final toppingsText = _descriptionController.text.trim();
      final List<String> colors;
      final List<String> sizes;
      if (_hasVariants && resolvedVariants.isNotEmpty) {
        final derived = ProductVariantSupport.buildDerivedProductFields(
          resolvedVariants,
        );
        colors = List<String>.from(derived['colors'] as List? ?? const []);
        sizes = List<String>.from(derived['sizes'] as List? ?? const []);
      } else {
        colors = _colorsController.text
            .split(',')
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty)
            .toList();
        sizes = _sizesController.text
            .split(',')
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty)
            .toList();
      }
      final resolvedUnit = _selectedUnit == 'อื่นๆ'
          ? _otherUnitController.text.trim()
          : (_selectedUnit ?? '');
      final taxStatus = _computedTaxStatus;
      bool canShipNationwide = _resolvedCanShipNationwide;
      String? nationwideShippingReason = _resolvedNationwideShippingReason;
      if (lockedExistingData != null) {
        canShipNationwide = lockedExistingData['canShipNationwide'] == true;
        final existingReason = lockedExistingData['nationwideShippingReason']
            ?.toString()
            .trim();
        nationwideShippingReason =
            existingReason != null && existingReason.isNotEmpty
            ? existingReason
            : null;
      }
      final normalizedServiceType = _normalizeServiceType(_serviceType);
      final shopProfileData = await _runSaveStep(
        'กำลังตรวจสอบข้อมูลร้าน',
        _resolveShopProfileData(
          ownerUid,
          normalizedServiceType,
          _isAdminDelegatedUpload ? null : user.email,
        ),
      );
      if (shopProfileData == null) {
        throw Exception(
          'ไม่พบข้อมูลร้านจากคอลเลกชันที่ลงทะเบียน กรุณาตรวจสอบข้อมูลการสมัครร้าน',
        );
      }
      final shopName =
          ShopProfileResolver.resolveName(shopProfileData) ??
          _resolveStringField(shopProfileData, const <String>[
            'shopName',
            'name',
            'displayName',
            'businessName',
            'storeName',
          ]);
      final String? shopImageUrl = ShopProfileResolver.resolveImageUrl(
        shopProfileData,
      );
      final String shopQrCode =
          ownerUid; // Wallet QR in this app is the shop UID.
      if (shopName == null || shopName.trim().isEmpty) {
        throw Exception(
          'ไม่พบชื่อร้านจากข้อมูลที่สมัคร กรุณาแก้ไขข้อมูลร้านก่อนบันทึกสินค้า',
        );
      }
      final shopLocation = _extractLocation(shopProfileData);
      final latitude = shopLocation['latitude'];
      final longitude = shopLocation['longitude'];
      if (latitude == null || longitude == null) {
        throw Exception(
          'ไม่พบพิกัดร้านจากข้อมูลที่สมัคร กรุณาแก้ไขพิกัดร้านก่อนบันทึกสินค้า',
        );
      }
      final resolvedProductServiceType =
          _readServiceTypeFromData(shopProfileData) ??
          normalizedServiceType ??
          '';

      unawaited(
        _upsertPublicShopProfile(
          ownerUid: ownerUid,
          shopName: shopName,
          shopImageUrl: shopImageUrl,
          latitude: latitude,
          longitude: longitude,
          serviceType: resolvedProductServiceType,
        ).catchError((Object error, StackTrace stackTrace) {
          debugPrint('public_shops upsert skipped: $error');
        }),
      );

      final resolvedPrice = _hasVariants && resolvedVariants.isNotEmpty
          ? (ProductVariantSupport.buildDerivedProductFields(
                          resolvedVariants,
                        )['price']
                        as num?)
                    ?.toDouble() ??
                0.0
          : double.tryParse(_priceController.text) ?? 0.0;
      final resolvedStock = _hasVariants && resolvedVariants.isNotEmpty
          ? (ProductVariantSupport.buildDerivedProductFields(
                          resolvedVariants,
                        )['stock']
                        as num?)
                    ?.toInt() ??
                0
          : int.tryParse(_stockController.text) ?? 0;
      final resolvedImageUrls = _hasVariants && resolvedVariants.isNotEmpty
          ? List<String>.from(
              ProductVariantSupport.buildDerivedProductFields(
                        resolvedVariants,
                      )['imageUrls']
                      as List? ??
                  imageUrls,
            )
          : imageUrls;
      final resolvedThumbnailUrls = _hasVariants && resolvedVariants.isNotEmpty
          ? List<String>.from(
              ProductVariantSupport.buildDerivedProductFields(
                        resolvedVariants,
                      )['thumbnailUrls']
                      as List? ??
                  thumbnailUrls,
            )
          : thumbnailUrls;

      final productData = <String, dynamic>{
        'name': _nameController.text,
        'description': productDescription.isNotEmpty
            ? productDescription
            : toppingsText,
        'productCategory': _selectedProductCategory,
        'isFreshProduct': _isFreshProduct,
        'isProcessed': _isProcessed,
        'taxStatus': taxStatus,
        'taxStatusLabel': _taxStatusLabel,
        'price': resolvedPrice,
        'stock': resolvedStock,
        'preparationTimeMinutes': preparationTimeMinutes,
        'preparingDuration': preparationTimeMinutes * 60 * 1000,
        'imageUrls': resolvedImageUrls,
        'thumbnailUrls': resolvedThumbnailUrls,
        'colors': colors,
        'sizes': sizes,
        'weight': weightValue,
        if (parcelWeightGrams > 0) 'parcelWeightGrams': parcelWeightGrams,
        if (parcelLengthCm != null) 'parcelLengthCm': parcelLengthCm,
        if (parcelWidthCm != null) 'parcelWidthCm': parcelWidthCm,
        if (parcelHeightCm != null) 'parcelHeightCm': parcelHeightCm,
        'unit': resolvedUnit,
        'shopName': shopName,
        if (shopImageUrl != null && shopImageUrl.trim().isNotEmpty)
          'shopImageUrl': shopImageUrl,
        'shopQrCode': shopQrCode,
        'location': <String, double?>{
          'latitude': latitude,
          'longitude': longitude,
        },
        'serviceType': resolvedProductServiceType,
        'ownerUid': ownerUid,
        if (_isAdminDelegatedUpload) ...<String, dynamic>{
          'uploadedByAdmin': true,
          'adminUploadedBy': user.uid,
        },
        'aiDescriptionRequested': _hasUsedAiDescriptionForProduct,
        'aiProductAnalysisRequested': _hasUsedAiProductAnalysisForProduct,
        'aiIsLegalInThailand': _aiIsLegalInThailand,
        if ((_aiLegalAnalysisReason ?? '').trim().isNotEmpty)
          'aiLegalAnalysisReason': _aiLegalAnalysisReason!.trim(),
        if ((_aiProductType ?? '').trim().isNotEmpty)
          'aiProductType': _aiProductType!.trim(),
        if ((_aiTaxAnalysisReason ?? '').trim().isNotEmpty)
          'taxAiReason': _aiTaxAnalysisReason!.trim(),
        'canShipNationwide': canShipNationwide,
        'nationwideShippingReason': nationwideShippingReason,
        ..._aiConfidenceProductFields(),
        'updatedAt': FieldValue.serverTimestamp(),
      };

      if (_hasVariants && resolvedVariants.isNotEmpty) {
        productData.addAll(
          ProductVariantSupport.buildDerivedProductFields(resolvedVariants),
        );
      } else if (widget.productToEdit != null) {
        productData['hasVariants'] = false;
        productData['variants'] = FieldValue.delete();
      }

      if (toppingsText.isNotEmpty) {
        productData['toppings'] = toppingsText;
      } else if (widget.productToEdit != null) {
        productData['toppings'] = FieldValue.delete();
      }

      if (videoUrl != null) {
        productData['videoUrl'] = videoUrl;
      } else if (widget.productToEdit != null &&
          widget.productToEdit!.videoUrl != null) {
        productData['videoUrl'] = FieldValue.delete();
      }

      if (videoThumbnailUrl != null) {
        productData['videoThumbnailUrl'] = videoThumbnailUrl;
      } else if (widget.productToEdit != null &&
          widget.productToEdit!.videoThumbnailUrl != null) {
        productData['videoThumbnailUrl'] = FieldValue.delete();
      }

      final specificationsData = <String, dynamic>{
        'description': productDescription,
        'toppings': toppingsText,
        'productCategory': _selectedProductCategory,
        'isFreshProduct': _isFreshProduct,
        'isProcessed': _isProcessed,
        'taxStatus': taxStatus,
        'taxStatusLabel': _taxStatusLabel,
        'taxReason': _taxReason,
        'aiIsLegalInThailand': _aiIsLegalInThailand,
        if ((_aiLegalAnalysisReason ?? '').trim().isNotEmpty)
          'aiLegalAnalysisReason': _aiLegalAnalysisReason!.trim(),
        if ((_aiProductType ?? '').trim().isNotEmpty)
          'aiProductType': _aiProductType!.trim(),
        'preparationTimeMinutes': preparationTimeMinutes,
        'preparingDuration': preparationTimeMinutes * 60 * 1000,
        'canShipNationwide': canShipNationwide,
        'nationwideShippingReason': nationwideShippingReason,
        'colors': colors,
        'sizes': sizes,
        'unit': resolvedUnit,
        'weight': weightValue,
        if (parcelWeightGrams > 0) 'parcelWeightGrams': parcelWeightGrams,
        if (parcelLengthCm != null) 'parcelLengthCm': parcelLengthCm,
        if (parcelWidthCm != null) 'parcelWidthCm': parcelWidthCm,
        if (parcelHeightCm != null) 'parcelHeightCm': parcelHeightCm,
        'headings': <String, String>{
          'description': 'คำอธิบายสินค้า',
          'toppings': 'ท็อปปิ้ง',
          'productCategory': 'ประเภทสินค้า',
          'isFreshProduct': 'เป็นของสด',
          'isProcessed': 'ผ่านการแปรรูปแล้ว',
          'taxStatus': 'สถานะภาษี',
          'aiIsLegalInThailand': 'ถูกกฎหมายในประเทศไทย',
          'aiLegalAnalysisReason': 'เหตุผลด้านกฎหมายจาก AI',
          'aiProductType': 'ประเภทสินค้าที่ AI วิเคราะห์',
          'preparationTimeMinutes': 'เวลาเตรียมสินค้า (นาที)',
          'preparingDuration': 'เวลาเตรียมสินค้า (มิลลิวินาที)',
          'canShipNationwide': 'ส่งได้ทั่วไทย',
          'nationwideShippingReason': 'เหตุผลการส่งทั่วไทย',
          'colors': 'สี',
          'sizes': 'ขนาด',
          'unit': 'หน่วย',
          'weight': 'น้ำหนัก',
          'parcelWeightGrams': 'น้ำหนักพัสดุ (กรัม)',
          'parcelLengthCm': 'ความยาวพัสดุ (ซม.)',
          'parcelWidthCm': 'ความกว้างพัสดุ (ซม.)',
          'parcelHeightCm': 'ความสูงพัสดุ (ซม.)',
        },
        'updatedAt': FieldValue.serverTimestamp(),
      };
      if (widget.productToEdit == null) {
        specificationsData['createdAt'] = FieldValue.serverTimestamp();
      }

      if (_requiresAdminAiReview()) {
        final reviewData = Map<String, dynamic>.from(productData)
          ..['adminReviewStatus'] = 'pending'
          ..['submittedAt'] = FieldValue.serverTimestamp()
          ..['submittedByUid'] = user.uid
          ..['reviewType'] = 'create'
          ..['specificationsPayload'] = specificationsData;
        reviewData.remove('isActive');
        reviewData.remove('activeAt');
        await _runSaveStep(
          'กำลังส่งสินค้าให้แอดมินตรวจสอบ',
          FirebaseFirestore.instance
              .collection('product_admin_reviews')
              .add(reviewData),
        );

        if (mounted) {
          final snackMessage = _aiIsLegalInThailand == false
              ? 'AI ประเมินว่าสินค้านี้อาจผิดกฎหมาย — ส่งให้แอดมินตรวจสอบแล้ว จะขึ้นขายหลังได้รับการอนุมัติ'
              : 'AI ประเมินความมั่นใจต่ำกว่า 80% — ส่งให้แอดมินตรวจสอบแล้ว แก้ไขและส่งใหม่ได้หลังได้รับการปฏิเสธ';
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(snackMessage)));
          unawaited(_closeDraftSessionPermanently());
          if (mounted) {
            Navigator.pop(context, true);
          }
        } else {
          unawaited(_closeDraftSessionPermanently());
        }
        return;
      }

      final productsRef = FirebaseFirestore.instance.collection('products');
      DocumentReference<Map<String, dynamic>> docRef;
      if (widget.productToEdit == null) {
        productData['createdAt'] = FieldValue.serverTimestamp();
        productData['isActive'] = true;
        productData['activeAt'] = FieldValue.serverTimestamp();
        docRef = productsRef.doc();
        await _commitSaveWrite('กำลังบันทึกสินค้า', docRef.set(productData));
      } else {
        final targetId = widget.productToEdit!.id;
        if (targetId == null || targetId.isEmpty) {
          throw Exception('ไม่สามารถระบุรหัสสินค้าที่ต้องการแก้ไขได้');
        }
        docRef = productsRef.doc(targetId);
        await _commitSaveWrite('กำลังบันทึกสินค้า', docRef.update(productData));
      }

      specificationsData['productId'] = docRef.id;
      specificationsData['ownerUid'] = ownerUid;

      await _commitSaveWrite(
        'กำลังบันทึกรายละเอียดสินค้า',
        docRef
            .collection('specifications')
            .doc('main')
            .set(specificationsData, SetOptions(merge: true)),
      );

      if (mounted) {
        setState(() => _uploadStatusText = 'กำลังอัปเดตข้อมูลในเครื่อง');
      }
      final cacheData = <String, dynamic>{};
      productData.forEach((key, value) {
        if (value is FieldValue) return;
        cacheData[key] = value;
      });
      final now = Timestamp.now();
      cacheData['updatedAt'] = now;
      if (widget.productToEdit == null) {
        cacheData['createdAt'] = now;
        cacheData['activeAt'] = now;
      }
      await ProductCacheService.instance.upsertProduct(
        ownerUid,
        CachedProduct(id: docRef.id, data: cacheData),
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('บันทึกสินค้าเรียบร้อยแล้ว')),
        );
        unawaited(_closeDraftSessionPermanently(savedProductId: docRef.id));
        if (mounted) {
          Navigator.pop(context, true);
        }
      } else {
        unawaited(_closeDraftSessionPermanently(savedProductId: docRef.id));
      }
    } on TimeoutException catch (e) {
      if (_draftPersistenceEnabled) {
        unawaited(
          _persistDraftPatch(<String, dynamic>{'productSaveStatus': null}),
        );
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '${e.message ?? 'การเชื่อมต่อใช้เวลานานเกินไป'} กรุณาตรวจสอบอินเทอร์เน็ตแล้วลองใหม่ ข้อมูลที่กรอกยังถูกเก็บไว้',
            ),
          ),
        );
      }
    } on FirebaseException catch (e) {
      if (_draftPersistenceEnabled) {
        unawaited(
          _persistDraftPatch(<String, dynamic>{'productSaveStatus': null}),
        );
      }
      final message = switch (e.code) {
        'permission-denied' =>
          'ไม่มีสิทธิ์อ่านข้อมูลร้านหรือบันทึกสินค้า กรุณาตรวจสอบสิทธิ์ Firestore แล้วลองใหม่',
        'unavailable' || 'network-request-failed' =>
          'ไม่สามารถเชื่อมต่อ Firebase ได้ชั่วคราว กรุณาตรวจสอบอินเทอร์เน็ตแล้วลองใหม่',
        _ => 'เกิดข้อผิดพลาดในการบันทึก: $e',
      };
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(message)));
      }
    } catch (e) {
      if (_draftPersistenceEnabled) {
        unawaited(
          _persistDraftPatch(<String, dynamic>{'productSaveStatus': null}),
        );
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('เกิดข้อผิดพลาดในการบันทึก: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSaving = false;
          _uploadProgress = null;
          _uploadStatusText = null;
        });
      }
    }
  }

  Future<void> _commitSaveWrite(String status, Future<void> write) async {
    try {
      await _runSaveStep(
        status,
        write,
        timeout: const Duration(seconds: 12),
      );
    } on TimeoutException {
      debugPrint('$status timed out; keeping local cache and continuing');
    }
  }

  Future<T> _runSaveStep<T>(
    String status,
    Future<T> operation, {
    Duration timeout = const Duration(seconds: 25),
  }) {
    if (mounted) {
      setState(() => _uploadStatusText = status);
    }
    debugPrint('Save step start: $status');
    final stopwatch = Stopwatch()..start();
    return operation
        .timeout(
          timeout,
          onTimeout: () {
            throw TimeoutException('$statusใช้เวลานานเกินไป');
          },
        )
        .whenComplete(() {
          debugPrint(
            'Save step done: $status in ${stopwatch.elapsedMilliseconds}ms',
          );
        });
  }

  Future<void> _upsertPublicShopProfile({
    required String ownerUid,
    required String shopName,
    String? shopImageUrl,
    required double latitude,
    required double longitude,
    required String serviceType,
  }) async {
    final publicData = <String, dynamic>{
      'ownerUid': ownerUid,
      'ownerId': ownerUid,
      'shopName': shopName,
      'name': shopName,
      'serviceType': serviceType,
      'location': <String, double>{
        'latitude': latitude,
        'longitude': longitude,
      },
      'shopLocation': <String, double>{
        'latitude': latitude,
        'longitude': longitude,
      },
      'shopLatitude': latitude,
      'shopLongitude': longitude,
      'updatedAt': FieldValue.serverTimestamp(),
    };

    final normalizedShopImageUrl = shopImageUrl?.trim();
    if (normalizedShopImageUrl != null && normalizedShopImageUrl.isNotEmpty) {
      publicData['shopImageUrl'] = normalizedShopImageUrl;
    }

    await FirebaseFirestore.instance
        .collection('public_shops')
        .doc(ownerUid)
        .set(publicData, SetOptions(merge: true));
  }

  Future<void> _backfillProductActiveFieldsForOwner(String ownerUid) async {
    try {
      final snapshot = await FirebaseFirestore.instance
          .collection('products')
          .where('ownerUid', isEqualTo: ownerUid)
          .get()
          .timeout(const Duration(seconds: 8));

      if (snapshot.docs.isEmpty) return;

      WriteBatch batch = FirebaseFirestore.instance.batch();
      int operationCount = 0;

      for (final doc in snapshot.docs) {
        final data = doc.data();
        final Map<String, dynamic> updates = <String, dynamic>{};
        final dynamic isActiveRaw = data['isActive'];
        final bool isActive = isActiveRaw is bool ? isActiveRaw : true;

        if (isActiveRaw is! bool) {
          updates['isActive'] = isActive;
        }

        if (isActive) {
          if (data['activeAt'] == null) {
            updates['activeAt'] = FieldValue.serverTimestamp();
          }
          if (data.containsKey('inactiveAt') && data['inactiveAt'] != null) {
            updates['inactiveAt'] = FieldValue.delete();
          }
        } else if (data['inactiveAt'] == null) {
          updates['inactiveAt'] = FieldValue.serverTimestamp();
        }

        if (updates.isEmpty) continue;

        updates['updatedAt'] = FieldValue.serverTimestamp();
        batch.update(doc.reference, updates);
        operationCount++;

        if (operationCount >= 450) {
          await batch.commit();
          batch = FirebaseFirestore.instance.batch();
          operationCount = 0;
        }
      }

      if (operationCount > 0) {
        await batch.commit();
      }
    } catch (e) {
      debugPrint('Failed to backfill active fields in products: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      onPopInvokedWithResult: (bool didPop, Object? result) {
        if (didPop && !_draftSessionClosed) {
          unawaited(_persistDraftNow());
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(
            widget.productToEdit == null ? 'เพิ่มสินค้าใหม่' : 'แก้ไขสินค้า',
          ),
          backgroundColor: AppColors.accent,
          foregroundColor: Colors.white,
          elevation: 1,
        ),
        backgroundColor: Colors.white,
        body: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24.0, 24.0, 24.0, 80.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (_isAdminDelegatedUpload) ...<Widget>[
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFF3E0),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: const Color(0xFFFFCC80)),
                  ),
                  child: Text(
                    'อัปโหลดให้ร้าน: ${widget.adminUploadContext!.shopName}',
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      color: Color(0xFFE65100),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
              ],
              const Text(
                'รูปภาพและวิดีโอ',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 12),
              _buildMediaSection(),
              if (_uploadProgress != null ||
                  _uploadStatusText != null ||
                  _isCompressingVideo ||
                  (_isSaving &&
                      (_videoFile != null ||
                          (_existingVideoUrl?.isNotEmpty ?? false))))
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (_uploadProgress != null)
                        LinearProgressIndicator(value: _uploadProgress),
                      if (_uploadProgress != null) const SizedBox(height: 8),
                      Text(
                        _uploadProgress != null
                            ? '${_uploadStatusText ?? 'กำลังอัปโหลด'}: ${(100 * _uploadProgress!).toStringAsFixed(0)}%'
                            : (_uploadStatusText ?? 'กำลังอัปโหลด'),
                      ),
                      if (_isCompressingVideo ||
                          (_isSaving &&
                              (_videoFile != null ||
                                  (_existingVideoUrl?.isNotEmpty ?? false))))
                        const Padding(
                          padding: EdgeInsets.only(top: 6),
                          child: Text(
                            'ออกจากหน้านี้หรือปิดแอปได้ — ระบบเก็บข้อมูลไว้ให้',
                            style: TextStyle(
                              fontSize: 12,
                              color: Color(0xFF1565C0),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              const SizedBox(height: 32),

              const Text(
                'รายละเอียดสินค้า',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: _buildTextField(
                      label: 'ชื่อสินค้า',
                      controller: _nameController,
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(child: _buildWeightField()),
                ],
              ),
              const SizedBox(height: 16),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text(
                  'สินค้านี้มีหลายขนาด/สี/ราคา',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                subtitle: Text(
                  _hasVariants
                      ? 'กำหนดราคาและสต็อกต่อตัวเลือกในขั้นตอนถัดไป'
                      : 'ปิด = ใช้ราคาและสต็อกเดียวแบบเดิม',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
                ),
                value: _hasVariants,
                activeThumbColor: AppColors.accent,
                onChanged:
                    _isEditingExistingProduct && _productVariants.isNotEmpty
                    ? null
                    : (value) {
                        setState(() {
                          _hasVariants = value;
                          if (!value) {
                            _variantDrafts = <ProductVariantDraft>[];
                          }
                        });
                        unawaited(_persistDraftNow());
                      },
              ),
              if (_hasVariants && _variantDrafts.isNotEmpty) ...[
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: () =>
                      _openVariantSetupFlow(saveAfterReturn: false),
                  icon: const Icon(Icons.tune),
                  label: Text('จัดการตัวเลือก (${_variantDrafts.length})'),
                ),
              ],
              const SizedBox(height: 16),
              if (!_hasVariants)
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _buildGuidedFieldOverlay(
                            showGuidance: _showPriceGuidance,
                            guidanceMessage:
                                'ระบบจะหักค่า GP 18% จากราคาที่ระบุ แนะนำให้บวกราคาเพิ่มจากราคาขายหน้าร้านปกติ ตามราคาที่เหมาะสม',
                            footer: Text(
                              _netPriceAfterGp == null
                                  ? 'ราคาที่จะได้รับ: ระบุราคาก่อน'
                                  : 'ราคาที่จะได้รับ: ${_formatPriceDisplay(_netPriceAfterGp!)} บาท',
                              style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w800,
                                color: AppColors.accentDark,
                              ),
                            ),
                            field: _buildTextField(
                              label: 'ราคา',
                              controller: _priceController,
                              keyboardType:
                                  const TextInputType.numberWithOptions(
                                    decimal: true,
                                  ),
                              focusNode: _priceFocusNode,
                              onTap: () {
                                setState(() {
                                  _showPreparationTimeGuidance = false;
                                  _priceGuidanceDismissedWhileFocused = false;
                                  _showPriceGuidance = true;
                                });
                              },
                              onChanged: (_) {
                                if (!mounted) return;
                                if (_showPriceGuidance) {
                                  setState(() {});
                                }
                              },
                            ),
                          ),
                          const SizedBox(height: 12),
                          _buildGuidedFieldOverlay(
                            showGuidance: _showPreparationTimeGuidance,
                            guidanceMessage:
                                'เวลาที่ระบุจะแสดงต่อลูกค้า และมีผลต่อการสั่งสินค้า รวมถึงค่าปรับหากเตรียมออเดอร์ช้าเกินเวลาที่ตั้งไว้ โดยคิดช้านาทีละ 1 บาทและหักจากยอดเครดิต กรุณาระบุเวลาเตรียมที่เหมาะสม',
                            field: _buildTextField(
                              label: 'เวลาเตรียมสินค้า/ออเดอร์ (นาที)',
                              controller: _preparationTimeController,
                              keyboardType: TextInputType.number,
                              hint: 'เช่น 10',
                              onTap: () => setState(() {
                                _showPriceGuidance = false;
                                _priceGuidanceDismissedWhileFocused = false;
                                _showPreparationTimeGuidance = true;
                              }),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: _buildTextField(
                        label: 'สต็อกทั้งหมด',
                        controller: _stockController,
                        keyboardType: TextInputType.number,
                      ),
                    ),
                  ],
                )
              else
                _buildGuidedFieldOverlay(
                  showGuidance: _showPreparationTimeGuidance,
                  guidanceMessage:
                      'เวลาที่ระบุจะแสดงต่อลูกค้า และมีผลต่อการสั่งสินค้า รวมถึงค่าปรับหากเตรียมออเดอร์ช้าเกินเวลาที่ตั้งไว้ โดยคิดช้านาทีละ 1 บาทและหักจากยอดเครดิต กรุณาระบุเวลาเตรียมที่เหมาะสม',
                  field: _buildTextField(
                    label: 'เวลาเตรียมสินค้า/ออเดอร์ (นาที)',
                    controller: _preparationTimeController,
                    keyboardType: TextInputType.number,
                    hint: 'เช่น 10',
                    onTap: () => setState(() {
                      _showPriceGuidance = false;
                      _priceGuidanceDismissedWhileFocused = false;
                      _showPreparationTimeGuidance = true;
                    }),
                  ),
                ),
              const SizedBox(height: 12),
              if (!_isEditingExistingProduct) _buildProductAnalysisSection(),
              if (!_isEditingExistingProduct) ...[
                const SizedBox(height: 24),
                _buildNationwideShippingSection(),
                if (_resolvedCanShipNationwide) ...[
                  const SizedBox(height: 12),
                  _buildParcelDimensionFields(),
                ],
              ],
              if (_isEditingExistingProduct) ...[
                const SizedBox(height: 12),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFFEFF6FF),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: const Color(0xFFBFDBFE)),
                  ),
                  child: const Text(
                    'โหมดแก้ไข: เปลี่ยนได้เฉพาะชื่อ ราคา สต็อก น้ำหนัก รายละเอียด และข้อมูลจำเพาะ — '
                    'รูปและวิดีโอใช้ค่าเดิม ไม่ต้องส่งแอดมินอนุมัติใหม่',
                    style: TextStyle(fontSize: 13, color: Color(0xFF1E3A8A)),
                  ),
                ),
              ],
              const SizedBox(height: 24),
              _buildTaxSection(),
              const SizedBox(height: 32),

              OutlinedButton.icon(
                onPressed: () {
                  showModalBottomSheet(
                    context: context,
                    isScrollControlled: true,
                    backgroundColor: Colors.white,
                    shape: const RoundedRectangleBorder(
                      borderRadius: BorderRadius.vertical(
                        top: Radius.circular(20),
                      ),
                    ),
                    builder: (context) => _buildSpecificationSheet(),
                  );
                },
                icon: const Icon(Icons.tune),
                label: const Text(
                  'ข้อมูลจำเพาะสินค้า (ท็อปปิ้ง, สี, ขนาด, หน่วย)',
                  style: TextStyle(fontSize: 14),
                ),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(double.infinity, 48),
                  side: BorderSide(color: AppColors.accent, width: 1.5),
                  foregroundColor: AppColors.accent,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),

              const SizedBox(height: 40),

              ElevatedButton(
                onPressed: (_isSaving || _isGeneratingAiDescription)
                    ? null
                    : _onPrimarySavePressed,
                style: ElevatedButton.styleFrom(
                  minimumSize: const Size(double.infinity, 50),
                ),
                child: _isSaving
                    ? const CircularProgressIndicator(color: Colors.white)
                    : Text(
                        _hasVariants && widget.productToEdit == null
                            ? 'ถัดไป: กำหนดตัวเลือก'
                            : 'บันทึกสินค้า',
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMediaSection() {
    final bool hasImages = _currentImageCount > 0;
    final bool hasVideo =
        _videoFile != null || (_existingVideoUrl?.isNotEmpty ?? false);
    final bool showVideoControls = _canAddVideo || hasVideo;

    final Widget imageContent = hasImages
        ? _buildImagePreviewContent()
        : _buildPlaceholderSquare(
            icon: Icons.photo_library_outlined,
            label: 'ยังไม่มีรูปภาพ',
          );

    final Widget videoContent = hasVideo
        ? _buildVideoPreviewContent()
        : _buildPlaceholderSquare(
            icon: Icons.videocam_outlined,
            label: 'ยังไม่มีวิดีโอ',
          );

    final bool showCombinedRow = !hasImages && !hasVideo && showVideoControls;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.grey[100],
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade400),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!_isEditingExistingProduct)
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                ElevatedButton.icon(
                  onPressed: _isResolvingServiceType || !_canPickMoreImages
                      ? null
                      : _captureImage,
                  icon: const Icon(Icons.photo_camera_outlined),
                  label: Text(
                    _usesFirstImageAiGate && _currentImageCount == 0
                        ? 'ถ่ายรูปแรก'
                        : 'ถ่ายรูป',
                  ),
                ),
                ElevatedButton.icon(
                  onPressed: _isResolvingServiceType || !_canPickMoreImages
                      ? null
                      : _pickImagesFromGallery,
                  icon: const Icon(Icons.photo_library_outlined),
                  label: Text(
                    _usesFirstImageAiGate && _currentImageCount == 0
                        ? 'เลือกรูปแรก'
                        : 'เลือกรูป (${_currentImageCount}/$_maxImageCount)',
                  ),
                ),
                if (_canAddVideo)
                  ElevatedButton.icon(
                    onPressed: _canPickVideoNow ? _pickVideo : null,
                    icon: _isCompressingVideo
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.videocam_outlined),
                    label: Text(
                      _isCompressingVideo ? 'บีบอัดวิดีโอ...' : 'เพิ่มวิดีโอ',
                    ),
                  ),
              ],
            )
          else
            const Text(
              'รูปภาพและวิดีโอไม่สามารถเปลี่ยนในโหมดแก้ไข',
              style: TextStyle(fontSize: 13, color: Colors.grey),
            ),
          if (!_isEditingExistingProduct && _mediaLimitHintText() != null) ...[
            const SizedBox(height: 8),
            Text(
              _mediaLimitHintText()!,
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
          const SizedBox(height: 16),
          if (showCombinedRow)
            Row(
              children: [
                Expanded(child: imageContent),
                const SizedBox(width: 12),
                Expanded(child: videoContent),
              ],
            )
          else ...[
            if (hasImages)
              imageContent
            else
              Align(
                alignment: Alignment.centerLeft,
                child: SizedBox(width: 120, child: imageContent),
              ),
            if (showVideoControls) ...[
              const SizedBox(height: 16),
              if (hasVideo)
                videoContent
              else
                Align(
                  alignment: Alignment.centerLeft,
                  child: SizedBox(width: 120, child: videoContent),
                ),
            ],
          ],
        ],
      ),
    );
  }

  Widget _buildImagePreviewContent() {
    final List<Widget> tiles = <Widget>[];

    for (int i = 0; i < _existingImageUrls.length; i++) {
      final imageUrl = _existingImageUrls[i];
      final thumbnailUrl = i < _existingThumbnailUrls.length
          ? _existingThumbnailUrls[i]
          : imageUrl;
      final previewCandidates = normalizeImageUrlCandidates(<String?>[
        thumbnailUrl,
        imageUrl,
      ]);
      tiles.add(
        _buildImageTile(
          image: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: previewCandidates.isNotEmpty
                ? ProductNetworkImage(
                    urls: previewCandidates,
                    width: 110,
                    height: 110,
                    fit: BoxFit.cover,
                  )
                : _buildCachedImage(''),
          ),
          onRemove: _isEditingExistingProduct
              ? null
              : () => _removeExistingImageAt(i),
        ),
      );
    }

    for (int i = 0; i < _newImageFiles.length; i++) {
      final file = _newImageFiles[i];
      tiles.add(
        _buildImageTile(
          image: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: _buildNewImagePreview(file),
          ),
          onRemove: () => _removeNewImageAt(i),
        ),
      );
    }

    return Wrap(spacing: 12, runSpacing: 12, children: tiles);
  }

  Widget _buildPlaceholderSquare({
    required IconData icon,
    required String label,
  }) {
    return AspectRatio(
      aspectRatio: 1,
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.grey.shade400),
        ),
        padding: const EdgeInsets.all(12),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: Colors.grey[500], size: 36),
            const SizedBox(height: 8),
            Text(
              label,
              style: const TextStyle(color: Colors.grey, fontSize: 13),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNewImagePreview(XFile file) {
    if (kIsWeb) {
      return FutureBuilder<Uint8List>(
        future: file.readAsBytes(),
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const SizedBox(
              width: 110,
              height: 110,
              child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
            );
          }
          return Image.memory(
            snapshot.data!,
            width: 110,
            height: 110,
            fit: BoxFit.cover,
          );
        },
      );
    }

    return Image.file(
      File(file.path),
      width: 110,
      height: 110,
      fit: BoxFit.cover,
    );
  }

  Widget _buildCachedImage(String url) {
    if (url.isEmpty) {
      return const ColoredBox(
        color: Colors.black12,
        child: Icon(Icons.broken_image, size: 40, color: Colors.grey),
      );
    }
    final localPath = _localMediaPaths[url];
    if (localPath != null && !kIsWeb) {
      return Image.file(
        File(localPath),
        width: 110,
        height: 110,
        fit: BoxFit.cover,
      );
    }
    _tryWarmLocalCache(url);
    return CachedAppImage(
      imageUrl: url,
      width: 110,
      height: 110,
      fit: BoxFit.cover,
      errorWidget: const ColoredBox(
        color: Colors.black12,
        child: Icon(Icons.broken_image, size: 40, color: Colors.grey),
      ),
    );
  }

  void _tryWarmLocalCache(String url) {
    if (url.isEmpty ||
        _localMediaPaths.containsKey(url) ||
        _cacheLookupInProgress.contains(url)) {
      return;
    }
    _cacheLookupInProgress.add(url);
    MediaCacheService.instance.getCachedPath(url).then((path) {
      _cacheLookupInProgress.remove(url);
      if (!mounted || path == null) return;
      if (_localMediaPaths[url] == path) return;
      setState(() {
        _localMediaPaths[url] = path;
      });
    });
  }

  Widget _buildImageTile({required Widget image, VoidCallback? onRemove}) {
    if (onRemove == null) {
      return SizedBox(width: 110, height: 110, child: image);
    }

    return Stack(
      clipBehavior: Clip.none,
      children: [
        SizedBox(width: 110, height: 110, child: image),
        Positioned(
          top: -8,
          right: -8,
          child: InkWell(
            onTap: onRemove,
            child: Container(
              decoration: BoxDecoration(
                color: Colors.black.withAlpha(166),
                shape: BoxShape.circle,
              ),
              padding: const EdgeInsets.all(4),
              child: const Icon(Icons.close, size: 16, color: Colors.white),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildVideoPreviewContent() {
    final String? videoUrl = _videoFile != null ? null : _existingVideoUrl;
    final bool hasVideo = _videoFile != null || (videoUrl?.isNotEmpty ?? false);
    final String? cachedVideoPath = videoUrl != null
        ? _localMediaPaths[videoUrl]
        : null;
    final String? thumbnailUrl = _videoFile != null
        ? null
        : _existingVideoThumbnailUrl;
    final String? cachedThumbnailPath = thumbnailUrl != null
        ? _localMediaPaths[thumbnailUrl]
        : null;
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      elevation: 1,
      child: Column(
        children: [
          ListTile(
            leading: const Icon(
              Icons.play_circle_fill,
              color: AppColors.accent,
              size: 36,
            ),
            title: Text(
              _videoFile != null ? _videoFile!.name : 'วิดีโอที่อัปโหลดแล้ว',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              'ความยาวไม่เกิน ${_maxVideoDuration.inMinutes} นาที',
            ),
            trailing: _isEditingExistingProduct
                ? null
                : IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: _removeVideo,
                  ),
          ),
          if (hasVideo)
            Padding(
              padding: const EdgeInsets.all(8.0),
              child: SizedBox(
                height: 220,
                child: _videoFile != null
                    ? (kIsWeb
                          ? Center(
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  const Icon(
                                    Icons.videocam,
                                    size: 48,
                                    color: AppColors.accent,
                                  ),
                                  const SizedBox(height: 8),
                                  Text(
                                    _videoFile!.name,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    textAlign: TextAlign.center,
                                  ),
                                ],
                              ),
                            )
                          : ProductVideoPlayer(videoUrl: _videoFile!.path))
                    : (videoUrl != null
                          ? ProductVideoPlayer(
                              videoUrl: cachedVideoPath ?? videoUrl,
                              thumbnailUrl: cachedThumbnailPath ?? thumbnailUrl,
                            )
                          : const Text('ไม่พบวิดีโอ')),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildTextField({
    required String label,
    int maxLines = 1,
    TextInputType keyboardType = TextInputType.text,
    String? hint,
    TextEditingController? controller,
    FocusNode? focusNode,
    VoidCallback? onTap,
    ValueChanged<String>? onChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: controller,
          focusNode: focusNode,
          keyboardType: keyboardType,
          maxLines: maxLines,
          onTap: () {
            _hideFieldGuidance();
            onTap?.call();
          },
          onChanged: onChanged,
          decoration: InputDecoration(
            hintText: hint,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(40),
              borderSide: BorderSide(color: Colors.grey.shade400),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(40),
              borderSide: BorderSide(color: Colors.grey.shade400),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(40),
              borderSide: const BorderSide(
                color: AppColors.accentDark,
                width: 2,
              ),
            ),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 20,
              vertical: 14,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildWeightField() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'น้ำหนัก',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
        ),
        const SizedBox(height: 8),
        Container(
          height: 52,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(40),
            border: Border.all(color: Colors.grey.shade400),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _weightController,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(
                    hintText: 'ใส่น้ำหนัก',
                    border: InputBorder.none,
                    isCollapsed: true,
                  ),
                ),
              ),
              Container(width: 1, height: 28, color: Colors.grey.shade300),
              const SizedBox(width: 12),
              DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  value: _weightUnit,
                  icon: const Icon(
                    Icons.keyboard_arrow_down_rounded,
                    color: Colors.black54,
                  ),
                  style: const TextStyle(fontSize: 16, color: Colors.black87),
                  onChanged: (value) {
                    if (value == null) return;
                    setState(() => _weightUnit = value);
                  },
                  items: const [
                    DropdownMenuItem(value: 'g', child: Text('g')),
                    DropdownMenuItem(value: 'kg', child: Text('kg')),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildParcelDimensionFields() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade300),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'ข้อมูลพัสดุสำหรับส่งทั่วประเทศ',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 6),
          const Text(
            'เตรียมไว้สำหรับเชื่อมต่อ ShipPop ภายหลัง ระบุขนาดโดยประมาณของพัสดุหลังแพ็ก',
            style: TextStyle(fontSize: 12, color: Colors.black54),
          ),
          const SizedBox(height: 12),
          if ((_aiParcelDimensionReason ?? '').isNotEmpty) ...[
            Text(
              'AI ประเมิน: ${_aiParcelDimensionReason!}',
              style: const TextStyle(fontSize: 12, color: Colors.black87),
            ),
            const SizedBox(height: 8),
          ],
          Row(
            children: [
              Expanded(
                child: _buildTextField(
                  label: 'ยาว (ซม.)',
                  controller: _parcelLengthController,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _buildTextField(
                  label: 'กว้าง (ซม.)',
                  controller: _parcelWidthController,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _buildTextField(
                  label: 'สูง (ซม.)',
                  controller: _parcelHeightController,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildTaxSummaryCard() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: _taxStatusColor.withAlpha(18),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _taxStatusColor.withAlpha(90)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _taxStatusLabel,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: _taxStatusColor,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            _taxReason,
            style: const TextStyle(fontSize: 13, color: Colors.black87),
          ),
        ],
      ),
    );
  }

  Widget _buildNationwideShippingSummaryCard() {
    final canShip = _aiCanShipNationwide == true;
    final color = canShip ? const Color(0xFF2E7D32) : const Color(0xFFC62828);
    final reason = (_aiNationwideShippingReason ?? '').trim();

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withAlpha(18),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withAlpha(90)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            canShip
                ? 'สินค้านี้ส่งได้ทั่วไทย'
                : 'สินค้านี้ไม่เหมาะกับการส่งทั่วไทย',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: color,
            ),
          ),
          if (reason.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              reason,
              style: const TextStyle(fontSize: 13, color: Colors.black87),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildProductAnalysisSection() {
    final legalKnown = _aiIsLegalInThailand != null;
    final legalColor = _aiIsLegalInThailand == false
        ? const Color(0xFFC62828)
        : const Color(0xFF2E7D32);
    final legalReason = (_aiLegalAnalysisReason ?? '').trim();
    final productType = (_aiProductType ?? '').trim();

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.grey[100],
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade300),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'วิเคราะห์สินค้า',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed:
                  (_isAnalyzingProductWithAi ||
                      _hasUsedAiProductAnalysisForProduct)
                  ? null
                  : _analyzeProductWithAi,
              icon: _isAnalyzingProductWithAi
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.auto_awesome_outlined),
              label: Text(
                _isAnalyzingProductWithAi
                    ? 'AI กำลังวิเคราะห์สินค้า...'
                    : (_hasUsedAiProductAnalysisForProduct
                          ? 'ใช้ AI วิเคราะห์สินค้าแล้ว'
                          : 'วิเคราะห์สินค้า'),
              ),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.accent,
                side: BorderSide(color: AppColors.accent.withOpacity(0.6)),
              ),
            ),
          ),
          if (_isAnalyzingProductWithAi &&
              (_aiQueueStatusText ?? '').isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              _aiQueueStatusText!,
              style: TextStyle(
                fontSize: 12,
                color: _aiQueueExternalRecommendation
                    ? const Color(0xFFC62828)
                    : Colors.black54,
              ),
            ),
          ],
          if (legalKnown || productType.isNotEmpty) ...[
            const SizedBox(height: 12),
            if (legalKnown)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: legalColor.withAlpha(18),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: legalColor.withAlpha(90)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _aiIsLegalInThailand == true
                          ? 'AI ประเมินว่าเป็นสินค้าที่ขายได้ตามกฎหมายไทย'
                          : 'AI ประเมินว่าอาจเป็นสินค้าที่ห้ามหรือจำกัดการขายในไทย',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                        color: legalColor,
                      ),
                    ),
                    if (legalReason.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(
                        legalReason,
                        style: const TextStyle(
                          fontSize: 13,
                          color: Colors.black87,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            if (productType.isNotEmpty) ...[
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.accentLight.withOpacity(0.5),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppColors.accent.withOpacity(0.35)),
                ),
                child: Text(
                  'ประเภทสินค้า: $productType',
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: Colors.black87,
                  ),
                ),
              ),
            ],
            if (_requiresAdminAiReview() && _aiIsLegalInThailand != false) ...[
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFFFFF7ED),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(0xFFFDBA74)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'AI ประเมินความมั่นใจต่ำกว่า 80% — จะส่งให้แอดมินตรวจสอบก่อนขึ้นขาย',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFFB45309),
                      ),
                    ),
                    if (_aiReviewReasonLabels.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(
                        'จุดที่ต้องตรวจ: ${_aiReviewReasonLabels.join(', ')}',
                        style: const TextStyle(
                          fontSize: 13,
                          color: Colors.black87,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ],
        ],
      ),
    );
  }

  Widget _buildManualNationwideShippingCheckbox() {
    return CheckboxListTile(
      contentPadding: EdgeInsets.zero,
      controlAffinity: ListTileControlAffinity.leading,
      title: const Text('เหมาะกับการส่งทั่วประเทศ'),
      subtitle: const Text('ติ๊กถูกถ้าสินค้านี้แพ็กและจัดส่งไปต่างจังหวัดได้'),
      value: _manualCanShipNationwide,
      onChanged: (value) {
        setState(() {
          _manualCanShipNationwide = value ?? false;
        });
      },
      activeColor: AppColors.accent,
    );
  }

  Widget _buildNationwideShippingSection() {
    if (_aiCanShipNationwide != null) {
      return _buildNationwideShippingSummaryCard();
    }
    return _buildManualNationwideShippingCheckbox();
  }

  Widget _buildTaxSection() {
    return Material(
      color: Colors.grey[100],
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: Colors.grey.shade300),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'ภาษีสินค้า',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            if (_hasAiTaxAnalysis) ...[
              _buildTaxSummaryCard(),
            ] else ...[
              const Text(
                'ประเภทสินค้า',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
              ),
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                value: _selectedProductCategory,
                items: _productCategories.map((category) {
                  return DropdownMenuItem<String>(
                    value: category,
                    child: Text(category),
                  );
                }).toList(),
                onChanged: (value) {
                  setState(() {
                    _selectedProductCategory = value;
                    if (_isPharmacyCategory) {
                      _isFreshProduct = false;
                      _isProcessed = false;
                    }
                  });
                },
                decoration: InputDecoration(
                  hintText: 'เลือกประเภทสินค้า',
                  helperText: 'จำเป็นต้องเลือกก่อนบันทึกสินค้า',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(16),
                    borderSide: BorderSide(color: Colors.grey.shade400),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(16),
                    borderSide: const BorderSide(
                      color: AppColors.accentDark,
                      width: 2,
                    ),
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 14,
                  ),
                ),
              ),
              if (_isPharmacyCategory) ...[
                const SizedBox(height: 12),
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('เสียภาษี'),
                  subtitle: const Text(
                    'ปิดสวิตช์หากยาหรือเวชภัณฑ์รายการนี้เป็นสินค้ายกเว้นภาษี',
                  ),
                  value: _pharmacyIsTaxable,
                  onChanged: (value) {
                    setState(() {
                      _pharmacyIsTaxable = value;
                      _isFreshProduct = false;
                      _isProcessed = false;
                    });
                  },
                  activeColor: AppColors.accent,
                ),
              ] else ...[
                const SizedBox(height: 12),
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('เป็นของสด'),
                  subtitle: const Text('เช่น ผัก ผลไม้ เนื้อสด อาหารทะเลสด'),
                  value: _isFreshProduct,
                  onChanged: (value) {
                    setState(() {
                      _isFreshProduct = value;
                    });
                  },
                  activeColor: AppColors.accent,
                ),
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('ผ่านการแปรรูปแล้ว'),
                  subtitle: const Text(
                    'เช่น หั่น หมัก ปรุง บรรจุพร้อมขาย หรือแปรรูปจากสภาพสด',
                  ),
                  value: _isProcessed,
                  onChanged: (value) {
                    setState(() {
                      _isProcessed = value;
                    });
                  },
                  activeColor: AppColors.accent,
                ),
              ],
              const SizedBox(height: 12),
              _buildTaxSummaryCard(),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildSpecificationSheet() {
    return Padding(
      padding: EdgeInsets.only(
        left: 24,
        right: 24,
        top: 20,
        bottom: MediaQuery.of(context).viewInsets.bottom + 20,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'ข้อมูลจำเพาะสินค้า',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                ),
                IconButton(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            const SizedBox(height: 20),
            _buildTextField(
              label: 'คำอธิบายสินค้า',
              controller: _productDescriptionController,
              hint: 'อธิบายรายละเอียดสินค้า',
              maxLines: 3,
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed:
                    (_isGeneratingAiDescription ||
                        _hasUsedAiDescriptionForProduct)
                    ? null
                    : _generateAiDescription,
                icon: _isGeneratingAiDescription
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.auto_awesome_outlined),
                label: Text(
                  _isGeneratingAiDescription
                      ? 'AI กำลังเขียนคำอธิบาย...'
                      : (_hasUsedAiDescriptionForProduct
                            ? 'ใช้ AI เขียนคำอธิบายแล้ว'
                            : 'ให้ AI ช่วยเขียนคำอธิบายสินค้า'),
                ),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.accent,
                  side: BorderSide(color: AppColors.accent.withOpacity(0.6)),
                ),
              ),
            ),
            if (_isGeneratingAiDescription &&
                (_aiQueueStatusText ?? '').isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                _aiQueueStatusText!,
                style: TextStyle(
                  fontSize: 12,
                  color: _aiQueueExternalRecommendation
                      ? const Color(0xFFC62828)
                      : Colors.black54,
                ),
              ),
            ],
            const SizedBox(height: 16),
            _buildTextField(
              label: 'ท็อปปิ้ง',
              controller: _descriptionController,
              focusNode: _toppingsFocusNode,
              hint: 'เช่น (ระดับความเผ็ด) +เผ็ดน้อย+ เผ็ด+ กลาง+เผ็ดมาก',
              onTap: () => setState(() {
                _showPriceGuidance = false;
                _showPreparationTimeGuidance = false;
                _showToppingsGuidance = true;
              }),
            ),
            if (_showToppingsGuidance) ...[
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFFFFF7ED),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(0xFFFED7AA)),
                ),
                child: const Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'วิธีกรอกท็อปปิ้ง',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF9A3412),
                      ),
                    ),
                    SizedBox(height: 6),
                    Text(
                      '1. ถ้าใส่วงเล็บ () จะใช้เป็นหัวข้อ',
                      style: TextStyle(fontSize: 12, color: Color(0xFF7C2D12)),
                    ),
                    SizedBox(height: 2),
                    Text(
                      '2. ถ้าใส่เครื่องหมาย + นำหน้า และลงท้ายด้วย + จะใช้เป็นตัวเลือก',
                      style: TextStyle(fontSize: 12, color: Color(0xFF7C2D12)),
                    ),
                    SizedBox(height: 2),
                    Text(
                      '3. ตัวอย่าง: (ระดับความเผ็ด) +เผ็ดน้อย+ เผ็ด+ กลาง+เผ็ดมาก (เพิ่ม)+หอย 20+ เพิ่มกุ้ง 20+เพิ่มแคบหมู 10+',
                      style: TextStyle(fontSize: 12, color: Color(0xFF7C2D12)),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 16),
            if (!_hasVariants) ...[
              _buildTextField(
                label: 'สี (คั่นด้วยจุลภาค)',
                controller: _colorsController,
                hint: 'เช่น แดง, ขาว, ดำ',
              ),
              const SizedBox(height: 16),
              _buildTextField(
                label: 'ขนาด (คั่นด้วยจุลภาค)',
                controller: _sizesController,
                hint: 'เช่น S, M, L, XL',
              ),
              const SizedBox(height: 16),
            ] else ...[
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFFEFF6FF),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(0xFFBFDBFE)),
                ),
                child: const Text(
                  'สี/ขนาด/ราคา/สต็อก กำหนดในหน้า "ตัวเลือกสินค้า" แทนการพิมพ์คั่นจุลภาค',
                  style: TextStyle(fontSize: 13, color: Color(0xFF1E3A8A)),
                ),
              ),
              const SizedBox(height: 16),
            ],
            const Text(
              'หน่วย',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              value: _selectedUnit,
              items: _units.map((String unit) {
                return DropdownMenuItem<String>(value: unit, child: Text(unit));
              }).toList(),
              onChanged: (newValue) {
                setState(() {
                  _selectedUnit = newValue;
                });
              },
              decoration: InputDecoration(
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(40),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(40),
                  borderSide: BorderSide(color: Colors.grey.shade400),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(40),
                  borderSide: const BorderSide(
                    color: AppColors.accentDark,
                    width: 2,
                  ),
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 14,
                ),
              ),
            ),
            if (_selectedUnit == 'อื่นๆ') ...[
              const SizedBox(height: 16),
              _buildTextField(
                label: 'ระบุหน่วย (อื่นๆ)',
                controller: _otherUnitController,
                hint: 'เช่น หลอด, ขวด, ซอง',
              ),
            ],
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: () => Navigator.pop(context),
              style: ElevatedButton.styleFrom(
                minimumSize: const Size(double.infinity, 48),
                backgroundColor: AppColors.accent,
                foregroundColor: Colors.white,
              ),
              child: const Text(
                'บันทึก',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
