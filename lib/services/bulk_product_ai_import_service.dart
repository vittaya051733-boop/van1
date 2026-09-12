import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'media_cache_service.dart';
import 'product_add_draft_store.dart';
import 'product_ai_image_cache.dart';
import 'product_draft_service.dart';

class BulkAiImportBatch {
  const BulkAiImportBatch({
    required this.id,
    required this.status,
    required this.totalCount,
    required this.completedCount,
    required this.failedCount,
    required this.reviewRequiredCount,
  });

  final String id;
  final String status;
  final int totalCount;
  final int completedCount;
  final int failedCount;
  final int reviewRequiredCount;

  int get pendingCount => max(0, totalCount - completedCount - failedCount);

  double get progress =>
      totalCount <= 0 ? 0 : (completedCount + failedCount) / totalCount;
}

class BulkAiImportProgress {
  const BulkAiImportProgress({
    this.batchId,
    this.uploading = false,
    this.uploaded = 0,
    this.total = 0,
    this.error,
  });

  final String? batchId;
  final bool uploading;
  final int uploaded;
  final int total;
  final String? error;

  bool get hasActiveWork =>
      uploading || (batchId != null && batchId!.isNotEmpty);
}

class BulkAiImportItem {
  const BulkAiImportItem({
    required this.draftId,
    required this.status,
    required this.bulkIndex,
    this.batchId,
    this.imageUrl,
    this.thumbnailUrl,
    this.localImagePath,
    this.productName,
    this.productType,
    this.aiError,
    this.aiResult = const <String, dynamic>{},
    this.imageSha256,
    this.imageAhash,
    this.requiresReview = false,
  });

  final String draftId;
  final String status;
  final int bulkIndex;
  final String? batchId;
  final String? imageUrl;
  final String? thumbnailUrl;
  final String? localImagePath;
  final String? productName;
  final String? productType;
  final String? aiError;
  final Map<String, dynamic> aiResult;
  final String? imageSha256;
  final String? imageAhash;
  final bool requiresReview;

  bool get isReady => status == 'completed';
  bool get isAwaitingAi =>
      status == 'uploaded' || status == 'queued' || status == 'processing';
  bool get isInProgress =>
      status == 'selected' ||
      status == 'uploading' ||
      isAwaitingAi;
  bool get hasLocalPreview =>
      (localImagePath ?? '').trim().isNotEmpty ||
      (imageUrl ?? '').trim().isNotEmpty;

  factory BulkAiImportItem.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data() ?? const <String, dynamic>{};
    return BulkAiImportItem.fromMap({...data, 'draftId': doc.id});
  }

  static String? resolveStoredImageUrl(Map<String, dynamic> data) {
    for (final key in ['imageUrl', 'thumbnailUrl']) {
      final value = data[key]?.toString().trim();
      if (value != null && value.isNotEmpty) {
        return value;
      }
    }
    final existing = data['existingImageUrls'];
    if (existing is List) {
      for (final entry in existing) {
        final value = entry?.toString().trim();
        if (value != null && value.isNotEmpty) {
          return value;
        }
      }
    }
    return null;
  }

  factory BulkAiImportItem.fromMap(Map<String, dynamic> data) {
    final aiResult = data['aiResult'] is Map
        ? Map<String, dynamic>.from(data['aiResult'] as Map)
        : const <String, dynamic>{};
    final storedImageUrl = resolveStoredImageUrl(data);
    return BulkAiImportItem(
      draftId: (data['draftId'] ?? '').toString(),
      status:
          data['aiStatus']?.toString() ??
          data['status']?.toString() ??
          'queued',
      bulkIndex: (data['bulkIndex'] as num?)?.toInt() ?? 0,
      batchId: data['bulkBatchId']?.toString() ?? data['batchId']?.toString(),
      imageUrl: storedImageUrl,
      thumbnailUrl: data['thumbnailUrl']?.toString() ?? storedImageUrl,
      localImagePath: data['localImagePath']?.toString(),
      productName:
          aiResult['productName']?.toString() ??
          data['productName']?.toString() ??
          data['name']?.toString(),
      productType:
          aiResult['productType']?.toString() ??
          data['productType']?.toString(),
      aiError: data['aiError']?.toString(),
      aiResult: aiResult,
      imageSha256: data['imageSha256']?.toString(),
      imageAhash: data['imageAhash']?.toString(),
      requiresReview:
          data['reviewStatus'] == 'required' ||
          aiResult['requiresAdminReview'] == true,
    );
  }

  Map<String, dynamic> toLocalMap() {
    return <String, dynamic>{
      'draftId': draftId,
      'aiStatus': status,
      'bulkIndex': bulkIndex,
      'bulkBatchId': batchId,
      'imageUrl': imageUrl,
      'thumbnailUrl': thumbnailUrl,
      'localImagePath': localImagePath,
      'productName': productName,
      'productType': productType,
      'aiError': aiError,
      'aiResult': aiResult,
      'imageSha256': imageSha256,
      'imageAhash': imageAhash,
      'reviewStatus': requiresReview ? 'required' : 'ready',
    };
  }

  BulkAiImportItem copyWith({
    String? status,
    String? localImagePath,
    bool clearLocalImagePath = false,
    String? imageUrl,
    String? thumbnailUrl,
    Map<String, dynamic>? aiResult,
    String? productName,
    String? productType,
    String? imageSha256,
    String? imageAhash,
  }) {
    return BulkAiImportItem(
      draftId: draftId,
      status: status ?? this.status,
      bulkIndex: bulkIndex,
      batchId: batchId,
      imageUrl: imageUrl ?? this.imageUrl,
      thumbnailUrl: thumbnailUrl ?? this.thumbnailUrl,
      localImagePath: clearLocalImagePath
          ? null
          : (localImagePath ?? this.localImagePath),
      productName: productName ?? this.productName,
      productType: productType ?? this.productType,
      aiError: aiError,
      aiResult: aiResult ?? this.aiResult,
      imageSha256: imageSha256 ?? this.imageSha256,
      imageAhash: imageAhash ?? this.imageAhash,
      requiresReview: requiresReview,
    );
  }
}

class BulkProductAiImportService {
  BulkProductAiImportService._();

  static final BulkProductAiImportService instance =
      BulkProductAiImportService._();

  static const int maxItemsPerBatch = 300;
  static const int uploadChunkSize = 3;
  static const String _prefsPrefix = 'bulk_ai_import_v1_';

  final StreamController<BulkAiImportProgress> _progressController =
      StreamController<BulkAiImportProgress>.broadcast();
  final StreamController<List<BulkAiImportItem>> _itemsController =
      StreamController<List<BulkAiImportItem>>.broadcast();

  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _itemsSubscription;
  String? _watchingOwnerUid;
  BulkAiImportProgress _progress = const BulkAiImportProgress();
  List<BulkAiImportItem> _items = const <BulkAiImportItem>[];

  FirebaseFunctions get _functions =>
      FirebaseFunctions.instanceFor(region: 'asia-southeast1');

  Stream<BulkAiImportProgress> get progressChanges =>
      _progressController.stream;

  Stream<List<BulkAiImportItem>> get itemsChanges => _itemsController.stream;

  BulkAiImportProgress get progress => _progress;

  List<BulkAiImportItem> get items =>
      List<BulkAiImportItem>.unmodifiable(_items);

  bool get isUploading => _progress.uploading;

  CollectionReference<Map<String, dynamic>> _draftItems(String ownerUid) {
    return FirebaseFirestore.instance
        .collection('product_drafts')
        .doc(ownerUid)
        .collection('items');
  }

  BulkAiImportBatch batchFromItems(
    String batchId,
    List<BulkAiImportItem> items,
  ) {
    final scoped = items.where((item) => item.batchId == batchId).toList();
    final completedCount = scoped.where((item) => item.isReady).length;
    final failedCount = scoped.where((item) => item.status == 'failed').length;
    final reviewRequiredCount = scoped
        .where((item) => item.requiresReview)
        .length;
    final finished = completedCount + failedCount;
    return BulkAiImportBatch(
      id: batchId,
      status: scoped.isEmpty
          ? (_progress.uploading ? 'uploading' : 'queued')
          : (finished >= scoped.length ? 'completed' : 'queued'),
      totalCount: scoped.isEmpty ? _progress.total : scoped.length,
      completedCount: completedCount,
      failedCount: failedCount,
      reviewRequiredCount: reviewRequiredCount,
    );
  }

  Future<void> restoreSession(String ownerUid) async {
    if (ownerUid.trim().isEmpty) return;
    final snapshot = await _loadLocal(ownerUid);
    _items = snapshot.items;
    _progress = snapshot.progress;
    _emitItems();
    _emitProgress();
    ensureWatching(ownerUid);
    unawaited(_syncPendingBulkAiJobs(ownerUid));
    unawaited(_hydrateLocalPreviewsFromCache(ownerUid));
    if (_items.any(
      (item) => item.status == 'queued' || item.status == 'processing',
    )) {
      unawaited(_kickProductAiWorker());
    }
  }

  void ensureWatching(String ownerUid) {
    if (ownerUid.trim().isEmpty) return;
    if (_watchingOwnerUid == ownerUid && _itemsSubscription != null) {
      return;
    }
    _itemsSubscription?.cancel();
    _watchingOwnerUid = ownerUid;
    _itemsSubscription = _draftItems(ownerUid).snapshots().listen(
      (snapshot) {
        final remote = snapshot.docs
            .map(BulkAiImportItem.fromDoc)
            .where((item) => (item.batchId ?? '').isNotEmpty)
            .toList();
        _mergeItems(remote);
        unawaited(_hydrateLocalPreviewsFromCache(ownerUid));
        unawaited(_persistCompletedToDevice(ownerUid));
      },
      onError: (Object error) {
        debugPrint('bulk AI watch failed: $error');
      },
    );
  }

  Future<String> beginImport({
    required String ownerUid,
    required List<XFile> images,
  }) async {
    if (ownerUid.trim().isEmpty) {
      throw Exception('ไม่พบร้านค้าที่ต้องการเพิ่มสินค้า');
    }
    if (_progress.uploading) {
      throw Exception(
        'กำลังอัปโหลดชุดก่อนหน้าอยู่ ออกจากหน้านี้ได้ ระบบทำต่อเบื้องหลัง',
      );
    }
    final selected = images.take(maxItemsPerBatch).toList(growable: false);
    if (selected.isEmpty) {
      throw Exception('กรุณาเลือกรูปสินค้าอย่างน้อย 1 รูป');
    }

    final now = DateTime.now().millisecondsSinceEpoch;
    final batchId = '${ownerUid}_bulk_$now'.replaceAll(
      RegExp(r'[^A-Za-z0-9_-]'),
      '_',
    );
    ensureWatching(ownerUid);

    final staged = await _stageImagesLocally(
      ownerUid: ownerUid,
      batchId: batchId,
      images: selected,
    );
    if (staged.isEmpty) {
      throw Exception('ไม่พบรูปใหม่ที่ยังไม่เคยเลือกในชุดนี้');
    }

    _setProgress(
      BulkAiImportProgress(
        batchId: batchId,
        uploading: true,
        uploaded: 0,
        total: staged.length,
      ),
    );
    await _saveLocal(ownerUid);
    unawaited(
      _runImport(ownerUid: ownerUid, batchId: batchId, staged: staged),
    );
    return batchId;
  }

  Future<void> retryItem({
    required String ownerUid,
    required String batchId,
    required BulkAiImportItem item,
  }) async {
    final imageUrl = (item.imageUrl ?? '').trim();
    if (imageUrl.isEmpty) {
      throw Exception('ไม่พบรูปเดิมสำหรับลองใหม่');
    }
    final callable = _functions.httpsCallable('enqueueBulkProductAiAnalysis');
    await callable.call(<String, dynamic>{
      'batchId': batchId,
      'retry': true,
      'items': [
        {
          'draftId': item.draftId,
          'requestId':
              '${batchId}_retry_${item.bulkIndex}_${DateTime.now().millisecondsSinceEpoch}',
          'imageUrl': imageUrl,
          'thumbnailUrl': item.thumbnailUrl ?? imageUrl,
          'bulkIndex': item.bulkIndex,
        },
      ],
    });
    unawaited(_kickProductAiWorker());
  }

  Future<List<BulkAiImportItem>> _stageImagesLocally({
    required String ownerUid,
    required String batchId,
    required List<XFile> images,
  }) async {
    final staged = <BulkAiImportItem>[];
    final seenIdentities = <ImageIdentity>[];
    for (var index = 0; index < images.length; index++) {
      final image = images[index];
      final bytes = await image.readAsBytes();
      if (bytes.isEmpty) continue;
      final identity = await ProductAiImageCache.instance.identify(bytes);
      if (seenIdentities.any(
        (seen) => ProductAiImageCache.similarIdentity(seen, identity),
      )) {
        continue;
      }
      if (_existingItemForIdentity(identity) != null) {
        seenIdentities.add(identity);
        continue;
      }
      seenIdentities.add(identity);

      final mimeType = _mimeTypeFromPath(image.path);
      final extension = _extensionForMimeType(mimeType);
      final draftId = '${ownerUid}_${batchId}_$index'.replaceAll(
        RegExp(r'[^A-Za-z0-9_-]'),
        '_',
      );
      final localImagePath = await ProductAddDraftStore.instance.persistMediaFile(
        sourcePath: image.path,
        ownerUid: ownerUid,
        draftId: draftId,
        fileName: 'source$extension',
      );
      staged.add(
        BulkAiImportItem(
          draftId: draftId,
          status: 'selected',
          bulkIndex: index,
          batchId: batchId,
          localImagePath: localImagePath ?? image.path,
          imageSha256: identity.sha256Hex,
          imageAhash: identity.ahash,
        ),
      );
    }
    if (staged.isNotEmpty) {
      _mergeItems(staged);
    }
    return staged;
  }

  Future<void> _runImport({
    required String ownerUid,
    required String batchId,
    required List<BulkAiImportItem> staged,
  }) async {
    try {
      if (staged.isEmpty) {
        await _saveLocal(ownerUid);
        return;
      }

      var uploaded = 0;

      for (var start = 0; start < staged.length; start += uploadChunkSize) {
        final chunk = staged.sublist(
          start,
          min(start + uploadChunkSize, staged.length),
        );
        await Future.wait(
          chunk.map(
            (item) => _uploadStagedItem(
              ownerUid: ownerUid,
              batchId: batchId,
              item: item,
            ),
          ),
        );
        uploaded += chunk.length;
        _setProgress(
          BulkAiImportProgress(
            batchId: batchId,
            uploading: true,
            uploaded: uploaded,
            total: staged.length,
          ),
        );
        await _saveLocal(ownerUid);
      }

      await _applyCacheHits(ownerUid: ownerUid, batchId: batchId);
      await _enqueueAiForBatch(ownerUid: ownerUid, batchId: batchId);
      await _syncPendingBulkAiJobs(ownerUid, batchId: batchId);

      _setProgress(
        BulkAiImportProgress(
          batchId: batchId,
          uploaded: staged.length,
          total: staged.length,
        ),
      );
      await _saveLocal(ownerUid);
    } catch (error) {
      _setProgress(
        BulkAiImportProgress(
          batchId: batchId,
          uploaded: _progress.uploaded,
          total: _progress.total,
          error: error.toString(),
        ),
      );
      await _saveLocal(ownerUid);
    }
  }

  Future<void> _applyCacheHits({
    required String ownerUid,
    required String batchId,
  }) async {
    final scoped = _items
        .where((item) => item.batchId == batchId && item.status == 'uploaded')
        .toList();
    for (final item in scoped) {
      final localPath = item.localImagePath?.trim();
      if (localPath == null || localPath.isEmpty) continue;
      try {
        final bytes = await File(localPath).readAsBytes();
        if (bytes.isEmpty) continue;
        final cachedAi = await ProductAiImageCache.instance.find(
          ownerUid: ownerUid,
          imageBytes: bytes,
        );
        if (cachedAi == null ||
            (cachedAi['productName'] ??
                    cachedAi['description'] ??
                    cachedAi['productType'])
                .toString()
                .trim()
                .isEmpty) {
          continue;
        }
        await ProductDraftService.instance.upsertDraft(
          ownerUid: ownerUid,
          draftId: item.draftId,
          patch: {
            'aiStatus': 'completed',
            'aiResult': cachedAi,
            if ((item.imageUrl ?? '').trim().isNotEmpty) ...{
              'imageUrl': item.imageUrl,
              'thumbnailUrl': item.thumbnailUrl ?? item.imageUrl,
              'existingImageUrls': <String>[item.imageUrl!],
            },
            'reviewStatus': cachedAi['requiresAdminReview'] == true
                ? 'required'
                : 'ready',
          },
        );
        _mergeItems([
          item.copyWith(
            status: 'completed',
            aiResult: cachedAi,
            productName: cachedAi['productName']?.toString(),
            productType: cachedAi['productType']?.toString(),
          ),
        ]);
      } catch (error) {
        debugPrint('bulk AI cache apply failed: $error');
      }
    }
  }

  Future<void> _enqueueAiForBatch({
    required String ownerUid,
    required String batchId,
  }) async {
    final pending = _items
        .where(
          (item) =>
              item.batchId == batchId &&
              item.status == 'uploaded' &&
              (item.imageUrl ?? '').trim().isNotEmpty,
        )
        .toList();
    if (pending.isEmpty) {
      return;
    }
    final callable = _functions.httpsCallable('enqueueBulkProductAiAnalysis');
    final jobItems = pending
        .map(
          (item) => {
            'draftId': item.draftId,
            'requestId': '${batchId}_${item.bulkIndex}',
            'imageUrl': item.imageUrl,
            'thumbnailUrl': item.thumbnailUrl ?? item.imageUrl,
            'bulkIndex': item.bulkIndex,
          },
        )
        .toList();
    await callable.call(<String, dynamic>{
      'batchId': batchId,
      'items': jobItems,
    });
    _mergeItems(
      pending.map((item) => item.copyWith(status: 'queued')).toList(),
    );
    unawaited(_kickProductAiWorker());
  }

  Future<void> _hydrateLocalPreviewsFromCache(String ownerUid) async {
    final updated = <BulkAiImportItem>[];
    for (final item in _items) {
      if (_preferReadableLocalPath(item.localImagePath, null) != null) {
        continue;
      }
      final url = (item.imageUrl ?? item.thumbnailUrl ?? '').trim();
      if (url.isEmpty) {
        continue;
      }
      final cached = await MediaCacheService.instance.getCachedPath(url);
      if (cached == null ||
          cached.isEmpty ||
          !File(cached).existsSync()) {
        continue;
      }
      updated.add(item.copyWith(localImagePath: cached));
    }
    if (updated.isEmpty) {
      return;
    }
    _mergeItems(updated);
    await _saveLocal(ownerUid);
  }

  Future<void> _kickProductAiWorker() async {
    try {
      final callable = _functions.httpsCallable('kickProductAiWorker');
      await callable.call(<String, dynamic>{}).timeout(const Duration(minutes: 3));
    } on FirebaseFunctionsException catch (error) {
      if (error.code == 'not-found' || error.code == 'unavailable') {
        return;
      }
      debugPrint('kickProductAiWorker failed: ${error.code} ${error.message}');
    } catch (error) {
      debugPrint('kickProductAiWorker failed: $error');
    }
  }

  Future<void> _syncPendingBulkAiJobs(
    String ownerUid, {
    String? batchId,
  }) async {
    final hasQueued = _items.any((item) {
      if (batchId != null && item.batchId != batchId) return false;
      return item.status == 'queued' || item.status == 'processing';
    });
    if (hasQueued) {
      unawaited(_kickProductAiWorker());
    }

    final pending = _items.where((item) {
      if ((item.imageUrl ?? '').trim().isEmpty) return false;
      if (item.isReady || item.status == 'failed') return false;
      if (batchId != null && item.batchId != batchId) return false;
      return item.status == 'uploaded';
    }).toList();
    if (pending.isEmpty) {
      await _saveLocal(ownerUid);
      return;
    }

    final grouped = <String, List<BulkAiImportItem>>{};
    for (final item in pending) {
      final id = item.batchId?.trim();
      if (id == null || id.isEmpty) continue;
      grouped.putIfAbsent(id, () => <BulkAiImportItem>[]).add(item);
    }

    final callable = _functions.httpsCallable('enqueueBulkProductAiAnalysis');
    for (final entry in grouped.entries) {
      final items = entry.value
          .where((item) => item.status == 'uploaded')
          .toList();
      if (items.isEmpty) continue;
      try {
        await callable.call(<String, dynamic>{
          'batchId': entry.key,
          'retry': true,
          'items': items
              .map(
                (item) => {
                  'draftId': item.draftId,
                  'requestId':
                      '${entry.key}_sync_${item.bulkIndex}_${DateTime.now().millisecondsSinceEpoch}',
                  'imageUrl': item.imageUrl,
                  'thumbnailUrl': item.thumbnailUrl ?? item.imageUrl,
                  'bulkIndex': item.bulkIndex,
                },
              )
              .toList(),
        });
        _mergeItems(
          items.map((item) => item.copyWith(status: 'queued')).toList(),
        );
      } catch (error) {
        debugPrint('bulk AI sync pending jobs failed: $error');
      }
    }
    if (_items.any((item) => item.status == 'queued')) {
      unawaited(_kickProductAiWorker());
    }
    await _saveLocal(ownerUid);
  }

  BulkAiImportItem? _existingItemForIdentity(ImageIdentity identity) {
    for (final item in _items) {
      final existing = ImageIdentity(
        sha256Hex: item.imageSha256 ?? '',
        ahash: item.imageAhash,
      );
      if (ProductAiImageCache.similarIdentity(existing, identity)) {
        return item;
      }
    }
    return null;
  }

  Future<BulkAiImportItem?> _uploadStagedItem({
    required String ownerUid,
    required String batchId,
    required BulkAiImportItem item,
  }) async {
    final localPath = item.localImagePath?.trim();
    if (localPath == null || localPath.isEmpty) {
      return null;
    }

    _mergeItems([item.copyWith(status: 'uploading')]);

    final file = File(localPath);
    if (!await file.exists()) {
      return null;
    }
    final bytes = await file.readAsBytes();
    if (bytes.isEmpty) {
      return null;
    }

    final mimeType = _mimeTypeFromPath(localPath);
    final extension = _extensionForMimeType(mimeType);
    final objectPath =
        'product_images/$ownerUid/bulk_ai/$batchId/${item.bulkIndex + 1}$extension';
    final ref = FirebaseStorage.instance.ref().child(objectPath);
    final imageUrl = await _withRetry(() async {
      await ref.putData(bytes, SettableMetadata(contentType: mimeType));
      return ref.getDownloadURL();
    });
    await MediaCacheService.instance.cacheUploadedFile(
      source: file,
      url: imageUrl,
      bucket: MediaCacheBucket.image,
    );

    await ProductDraftService.instance.upsertDraft(
      ownerUid: ownerUid,
      draftId: item.draftId,
      patch: {
        'draftId': item.draftId,
        'bulkBatchId': batchId,
        'bulkIndex': item.bulkIndex,
        'imageUrl': imageUrl,
        'thumbnailUrl': imageUrl,
        'aiStatus': 'uploaded',
        'imageSha256': item.imageSha256,
        'imageAhash': item.imageAhash,
      },
    );

    final uploaded = item.copyWith(
      status: 'uploaded',
      imageUrl: imageUrl,
      thumbnailUrl: imageUrl,
      localImagePath: localPath,
    );
    _mergeItems([uploaded]);
    return uploaded;
  }

  void _mergeItems(List<BulkAiImportItem> incoming) {
    final byId = <String, BulkAiImportItem>{
      for (final item in _items)
        if (item.draftId.isNotEmpty) item.draftId: item,
    };
    for (final item in incoming) {
      if (item.draftId.isEmpty) continue;
      final previous = byId[item.draftId];
      byId[item.draftId] = BulkAiImportItem(
        draftId: item.draftId,
        status: item.status,
        bulkIndex: item.bulkIndex,
        batchId: item.batchId ?? previous?.batchId,
        imageUrl: _preferText(item.imageUrl, previous?.imageUrl),
        thumbnailUrl: _preferText(item.thumbnailUrl, previous?.thumbnailUrl),
        localImagePath: _preferReadableLocalPath(
          item.localImagePath,
          previous?.localImagePath,
        ),
        productName: _preferText(item.productName, previous?.productName),
        productType: _preferText(item.productType, previous?.productType),
        aiError: item.aiError ?? previous?.aiError,
        aiResult: item.aiResult.isNotEmpty
            ? item.aiResult
            : (previous?.aiResult ?? const <String, dynamic>{}),
        imageSha256: _preferText(item.imageSha256, previous?.imageSha256),
        imageAhash: _preferText(item.imageAhash, previous?.imageAhash),
        requiresReview:
            item.requiresReview || (previous?.requiresReview ?? false),
      );
    }
    _items = byId.values.toList()
      ..sort((a, b) {
        final batchCompare = (b.batchId ?? '').compareTo(a.batchId ?? '');
        if (batchCompare != 0) return batchCompare;
        return a.bulkIndex.compareTo(b.bulkIndex);
      });
    _emitItems();
  }

  String? _preferText(String? preferred, String? fallback) {
    final value = preferred?.trim();
    if (value != null && value.isNotEmpty) return value;
    final other = fallback?.trim();
    if (other != null && other.isNotEmpty) return other;
    return null;
  }

  String? _preferReadableLocalPath(String? preferred, String? fallback) {
    for (final candidate in [preferred, fallback]) {
      final value = candidate?.trim();
      if (value != null &&
          value.isNotEmpty &&
          File(value).existsSync()) {
        return value;
      }
    }
    return null;
  }

  BulkAiImportItem _sanitizeLocalPaths(BulkAiImportItem item) {
    if (_preferReadableLocalPath(item.localImagePath, null) != null) {
      return item;
    }
    if ((item.localImagePath ?? '').trim().isEmpty) {
      return item;
    }
    return item.copyWith(clearLocalImagePath: true);
  }

  Future<Uint8List?> _readItemImageBytes(BulkAiImportItem item) async {
    final localPath = _preferReadableLocalPath(item.localImagePath, null);
    if (localPath != null) {
      try {
        return await File(localPath).readAsBytes();
      } catch (_) {
        // Fall through to media cache / download.
      }
    }
    final imageUrl = (item.imageUrl ?? item.thumbnailUrl ?? '').trim();
    if (imageUrl.isEmpty) {
      return null;
    }
    final cachedPath = await MediaCacheService.instance.getCachedPath(imageUrl);
    if (cachedPath != null && cachedPath.isNotEmpty) {
      try {
        return await File(cachedPath).readAsBytes();
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  void _setProgress(BulkAiImportProgress progress) {
    _progress = progress;
    _emitProgress();
  }

  void _emitProgress() {
    if (!_progressController.isClosed) {
      _progressController.add(_progress);
    }
  }

  void _emitItems() {
    if (!_itemsController.isClosed) {
      _itemsController.add(items);
    }
  }

  String _prefsKey(String ownerUid) => '$_prefsPrefix$ownerUid';

  Future<({List<BulkAiImportItem> items, BulkAiImportProgress progress})>
  _loadLocal(String ownerUid) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey(ownerUid));
      if (raw == null || raw.isEmpty) {
        return (
          items: const <BulkAiImportItem>[],
          progress: const BulkAiImportProgress(),
        );
      }
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        return (
          items: const <BulkAiImportItem>[],
          progress: const BulkAiImportProgress(),
        );
      }
      final data = Map<String, dynamic>.from(decoded);
      final rawItems = data['items'];
      final items = rawItems is List
          ? rawItems
                .whereType<Map>()
                .map(
                  (item) => _sanitizeLocalPaths(
                    BulkAiImportItem.fromMap(Map<String, dynamic>.from(item)),
                  ),
                )
                .where((item) => item.draftId.isNotEmpty)
                .toList()
          : const <BulkAiImportItem>[];
      return (
        items: items,
        progress: BulkAiImportProgress(
          batchId: data['activeBatchId']?.toString(),
          uploaded: (data['uploaded'] as num?)?.toInt() ?? 0,
          total: (data['total'] as num?)?.toInt() ?? 0,
        ),
      );
    } catch (error) {
      debugPrint('bulk AI local load failed: $error');
      return (
        items: const <BulkAiImportItem>[],
        progress: const BulkAiImportProgress(),
      );
    }
  }

  Future<Map<String, dynamic>> prepareLocalDraft({
    required String ownerUid,
    required BulkAiImportItem item,
  }) async {
    final localPath = await _ensureLocalImage(ownerUid: ownerUid, item: item);
    var aiResult = Map<String, dynamic>.from(item.aiResult);
    final hasUsefulAi =
        (aiResult['productName'] ??
                aiResult['description'] ??
                aiResult['productType'] ??
                aiResult['productCategory'])
            .toString()
            .trim()
            .isNotEmpty;
    if (!hasUsefulAi) {
      try {
        final remote = await ProductDraftService.instance.loadDraft(
          ownerUid: ownerUid,
          draftId: item.draftId,
        );
        final remoteResult = remote?['aiResult'];
        if (remoteResult is Map && remoteResult.isNotEmpty) {
          aiResult = Map<String, dynamic>.from(remoteResult);
        }
      } catch (error) {
        debugPrint('bulk AI load remote result failed: $error');
      }
    }
    if ((aiResult['productName'] ?? '').toString().trim().isEmpty &&
        (item.productName ?? '').trim().isNotEmpty) {
      aiResult['productName'] = item.productName;
    }
    if ((aiResult['productType'] ?? '').toString().trim().isEmpty &&
        (item.productType ?? '').trim().isNotEmpty) {
      aiResult['productType'] = item.productType;
    }
    final localItem = item.copyWith(
      localImagePath: localPath,
      aiResult: aiResult,
      productName:
          (aiResult['productName'] as String?)?.trim() ?? item.productName,
      productType:
          (aiResult['productType'] as String?)?.trim() ?? item.productType,
    );
    if (localPath != null && localPath != item.localImagePath) {
      _mergeItems([localItem]);
    } else if (localPath == null &&
        (item.localImagePath ?? '').trim().isNotEmpty) {
      _mergeItems([item.copyWith(clearLocalImagePath: true)]);
    }
    await _saveLocal(ownerUid);
    if (localItem.aiResult.isNotEmpty) {
      try {
        final bytes = await _readItemImageBytes(localItem);
        if (bytes != null && bytes.isNotEmpty) {
          await ProductAiImageCache.instance.save(
            ownerUid: ownerUid,
            imageBytes: bytes,
            aiResult: localItem.aiResult,
          );
        }
      } catch (error) {
        debugPrint('bulk AI local result cache failed: $error');
      }
    }
    final imageUrl = (localItem.imageUrl ?? '').trim();
    return <String, dynamic>{
      'draftId': localItem.draftId,
      'aiStatus': localItem.status,
      'aiResult': localItem.aiResult,
      'hasUsedAiProductAnalysisForProduct': localItem.isReady,
      'name': localItem.productName,
      if (imageUrl.isNotEmpty) ...{
        'imageUrl': imageUrl,
        'thumbnailUrl': (localItem.thumbnailUrl ?? imageUrl).trim(),
        'existingImageUrls': <String>[imageUrl],
      },
      if (localPath != null && localPath.isNotEmpty) ...{
        'localImagePath': localPath,
        'sourceImageLocalPath': localPath,
        'localImagePaths': <String>[localPath],
      },
    };
  }

  Future<void> _persistCompletedToDevice(String ownerUid) async {
    final completed = _items.where((item) => item.isReady).toList();
    if (completed.isEmpty) {
      await _saveLocal(ownerUid);
      return;
    }
    final updated = <BulkAiImportItem>[];
    for (final item in completed) {
      final hadStaleLocalPath =
          (item.localImagePath ?? '').trim().isNotEmpty &&
          _preferReadableLocalPath(item.localImagePath, null) == null;
      final localPath = await _ensureLocalImage(ownerUid: ownerUid, item: item);
      if (localPath != null && localPath != item.localImagePath) {
        updated.add(item.copyWith(localImagePath: localPath));
      } else if (localPath == null && hadStaleLocalPath) {
        updated.add(item.copyWith(clearLocalImagePath: true));
      }
      if (item.aiResult.isNotEmpty) {
        try {
          final itemForBytes = localPath != null
              ? item.copyWith(localImagePath: localPath)
              : item.copyWith(clearLocalImagePath: true);
          final bytes = await _readItemImageBytes(itemForBytes);
          if (bytes != null && bytes.isNotEmpty) {
            await ProductAiImageCache.instance.save(
              ownerUid: ownerUid,
              imageBytes: bytes,
              aiResult: item.aiResult,
            );
          }
        } catch (error) {
          debugPrint('bulk AI completed cache failed: $error');
        }
      }
    }
    if (updated.isNotEmpty) {
      _mergeItems(updated);
    }
    await _saveLocal(ownerUid);
  }

  Future<String?> _ensureLocalImage({
    required String ownerUid,
    required BulkAiImportItem item,
  }) async {
    final existing = _preferReadableLocalPath(item.localImagePath, null);
    if (existing != null) {
      return existing;
    }
    final imageUrl = (item.imageUrl ?? item.thumbnailUrl ?? '').trim();
    if (imageUrl.isNotEmpty) {
      final cached = await MediaCacheService.instance.getCachedPath(imageUrl);
      if (cached != null &&
          cached.isNotEmpty &&
          await File(cached).exists()) {
        return cached;
      }
    }
    if (imageUrl.isEmpty || kIsWeb) {
      return null;
    }
    try {
      final response = await http
          .get(Uri.parse(imageUrl))
          .timeout(const Duration(seconds: 20));
      if (response.statusCode != 200 || response.bodyBytes.isEmpty) {
        return null;
      }
      final path = await ProductAddDraftStore.instance.persistMediaBytes(
        bytes: response.bodyBytes,
        ownerUid: ownerUid,
        draftId: item.draftId,
        fileName: 'source.jpg',
      );
      if (path != null && path.isNotEmpty) {
        await MediaCacheService.instance.cacheUploadedFile(
          source: File(path),
          url: imageUrl,
          bucket: MediaCacheBucket.image,
        );
      }
      return path;
    } catch (error) {
      debugPrint('bulk AI download image failed: $error');
      return null;
    }
  }

  Future<void> _saveLocal(String ownerUid) async {
    if (ownerUid.trim().isEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final readyOrActive = _items
          .where(
            (item) =>
                item.isReady ||
                item.isInProgress ||
                item.status == 'failed' ||
                item.status == 'selected' ||
                item.status == 'uploaded',
          )
          .take(300)
          .map((item) => item.toLocalMap())
          .toList();
      await prefs.setString(
        _prefsKey(ownerUid),
        jsonEncode(<String, dynamic>{
          'activeBatchId': _progress.batchId,
          'uploaded': _progress.uploaded,
          'total': _progress.total,
          'savedAtMillis': DateTime.now().millisecondsSinceEpoch,
          'items': readyOrActive,
        }),
      );
    } catch (error) {
      debugPrint('bulk AI local save failed: $error');
    }
  }

  String _mimeTypeFromPath(String path) {
    final lower = path.toLowerCase();
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.webp')) return 'image/webp';
    return 'image/jpeg';
  }

  String _extensionForMimeType(String mimeType) {
    switch (mimeType) {
      case 'image/png':
        return '.png';
      case 'image/webp':
        return '.webp';
      default:
        return '.jpg';
    }
  }

  Future<T> _withRetry<T>(Future<T> Function() action) async {
    Object? lastError;
    for (var attempt = 0; attempt < 3; attempt += 1) {
      try {
        return await action();
      } catch (error) {
        lastError = error;
        await Future<void>.delayed(Duration(milliseconds: 350 * (attempt + 1)));
      }
    }
    throw Exception(lastError ?? 'upload_failed');
  }
}
