import 'dart:async';
import 'dart:io';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import 'add_product_screen.dart';
import 'services/bulk_product_ai_import_service.dart';
import 'services/media_cache_service.dart';
import 'utils/app_colors.dart';
import 'widgets/cached_app_image.dart';
import 'widgets/merchant_premium_ui.dart';

class BulkAiProductImportScreen extends StatefulWidget {
  const BulkAiProductImportScreen({super.key});

  @override
  State<BulkAiProductImportScreen> createState() =>
      _BulkAiProductImportScreenState();
}

class _BulkAiProductImportScreenState extends State<BulkAiProductImportScreen> {
  final ImagePicker _picker = ImagePicker();
  final BulkProductAiImportService _service =
      BulkProductAiImportService.instance;

  StreamSubscription<BulkAiImportProgress>? _progressSub;
  StreamSubscription<List<BulkAiImportItem>>? _itemsSub;
  String? _batchId;
  bool _picking = false;
  bool _restoring = true;
  List<BulkAiImportItem> _items = const <BulkAiImportItem>[];
  BulkAiImportProgress _progress = const BulkAiImportProgress();

  @override
  void initState() {
    super.initState();
    _progress = _service.progress;
    _items = _service.items;
    _batchId = _progress.batchId;
    _progressSub = _service.progressChanges.listen((progress) {
      if (!mounted) return;
      final error = progress.error;
      setState(() {
        _progress = progress;
        _batchId = progress.batchId ?? _batchId;
      });
      if (error != null && error.isNotEmpty) {
        _showSnack('เริ่ม bulk AI ไม่สำเร็จ: $error');
      }
    });
    _itemsSub = _service.itemsChanges.listen((items) {
      if (!mounted) return;
      setState(() => _items = items);
    });
    unawaited(_restore());
  }

  @override
  void dispose() {
    _progressSub?.cancel();
    _itemsSub?.cancel();
    super.dispose();
  }

  Future<void> _restore() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      await _service.restoreSession(user.uid);
      if (mounted) {
        setState(() {
          _progress = _service.progress;
          _items = _service.items;
          _batchId = _progress.batchId ?? _batchId;
        });
      }
    }
    if (mounted) {
      setState(() => _restoring = false);
    }
  }

  bool _isPickerCancelled(PlatformException error) {
    return error.code == 'multiple_request' ||
        error.code == 'already_active' ||
        error.code == 'canceled' ||
        error.code == 'cancelled';
  }

  Future<void> _pickAndStart() async {
    if (_service.isUploading || _picking) return;
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      _showSnack('กรุณาเข้าสู่ระบบก่อนเพิ่มสินค้า');
      return;
    }

    _picking = true;
    final List<XFile> images;
    try {
      images = await _picker.pickMultiImage(imageQuality: 82);
    } on PlatformException catch (error) {
      if (!_isPickerCancelled(error) && mounted) {
        _showSnack(
          error.message?.trim().isNotEmpty == true
              ? error.message!.trim()
              : 'เลือกรูปไม่สำเร็จ',
        );
      }
      return;
    } catch (error) {
      if (mounted) _showSnack('เลือกรูปไม่สำเร็จ: $error');
      return;
    } finally {
      _picking = false;
    }
    if (images.isEmpty) return;

    try {
      final batchId = await _service.beginImport(
        ownerUid: user.uid,
        images: images,
      );
      if (!mounted) return;
      setState(() {
        _batchId = batchId;
        _progress = _service.progress;
        _items = _service.items;
      });
      _showSnack(
        'เลือก ${images.length} รูปแล้ว — ระบบจะอัปโหลดครบก่อน แล้วค่อยส่งวิเคราะห์ AI',
      );
    } catch (e) {
      if (!mounted) return;
      _showSnack('เริ่ม bulk AI ไม่สำเร็จ: $e');
    }
  }

  void _showSnack(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _openDraft(BulkAiImportItem item) async {
    final user = FirebaseAuth.instance.currentUser;
    String? localPath = item.localImagePath?.trim();
    if (localPath != null && localPath.isEmpty) localPath = null;
    String? imageUrl = (item.imageUrl ?? item.thumbnailUrl)?.trim();
    if (imageUrl != null && imageUrl.isEmpty) imageUrl = null;
    Map<String, dynamic> aiResult = item.aiResult;
    if (user != null) {
      final localDraft = await _service.prepareLocalDraft(
        ownerUid: user.uid,
        item: item,
      );
      localPath =
          (localDraft['localImagePath'] as String?)?.trim() ?? localPath;
      imageUrl = (localDraft['imageUrl'] as String?)?.trim() ?? imageUrl;
      final draftResult = localDraft['aiResult'];
      if (draftResult is Map && draftResult.isNotEmpty) {
        aiResult = Map<String, dynamic>.from(draftResult);
      }
    }
    if ((aiResult['productName'] ?? '').toString().trim().isEmpty &&
        (item.productName ?? '').trim().isNotEmpty) {
      aiResult = {...aiResult, 'productName': item.productName};
    }
    if ((aiResult['productType'] ?? '').toString().trim().isEmpty &&
        (item.productType ?? '').trim().isNotEmpty) {
      aiResult = {...aiResult, 'productType': item.productType};
    }
    if (localPath != null &&
        localPath.isNotEmpty &&
        !File(localPath).existsSync()) {
      localPath = null;
    }
    if (!mounted) return;
    await Navigator.of(context).push<AddProductSaveResult>(
      MaterialPageRoute<AddProductSaveResult>(
        builder: (_) => AddProductScreen(
          initialLocalImagePath: localPath,
          initialImageUrl: imageUrl,
          initialAiResult: aiResult,
        ),
      ),
    );
  }

  List<BulkAiImportItem> get _readyItems =>
      _items.where((item) => item.isReady).toList();

  List<BulkAiImportItem> get _pendingItems =>
      _items.where((item) => !item.isReady).toList();

  List<BulkAiImportItem> get _selectedItems =>
      _items.where((item) => item.status == 'selected').toList();

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    final uploading = _progress.uploading;
    final hasWork = _items.isNotEmpty || uploading || _batchId != null;
    return Scaffold(
      backgroundColor: MerchantPremiumUi.pageBackground,
      appBar: AppBar(
        title: const Text('เพิ่มหลายสินค้าด้วย AI'),
        backgroundColor: MerchantPremiumUi.pageBackground,
        foregroundColor: MerchantPremiumUi.ink,
        surfaceTintColor: Colors.transparent,
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: (uploading || _picking) ? null : _pickAndStart,
        backgroundColor: AppColors.accent,
        foregroundColor: Colors.white,
        icon: uploading
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              )
            : const Icon(Icons.add_photo_alternate_outlined),
        label: Text(
          uploading
              ? 'กำลังอัปโหลด ${_progress.uploaded}/${_progress.total}'
              : 'เลือกรูป',
        ),
      ),
      body: user == null
          ? const Center(child: Text('กรุณาเข้าสู่ระบบ'))
          : Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  _buildIntroCard(),
                  const SizedBox(height: 12),
                  if (_restoring)
                    const Expanded(
                      child: Center(child: CircularProgressIndicator()),
                    )
                  else if (!hasWork)
                    Expanded(
                      child: PremiumEmptyState(
                        icon: Icons.auto_awesome_motion_outlined,
                        title: 'เลือกหลายรูปเพื่อให้ AI ต่อคิววิเคราะห์',
                        message:
                            'เลือกรูปแล้วจะเห็นในรายการทันที อัปโหลดครบก่อน แล้วค่อยวิเคราะห์ AI ทั้งชุด',
                        action: FilledButton.icon(
                          onPressed: (uploading || _picking)
                              ? null
                              : _pickAndStart,
                          icon: const Icon(Icons.add_photo_alternate_outlined),
                          label: const Text('เลือกรูปสินค้า'),
                        ),
                      ),
                    )
                  else
                    Expanded(
                      child: ListView(
                        children: [
                          if (uploading || _batchId != null)
                            _buildBatchProgress(),
                          if (_readyItems.isNotEmpty) ...[
                            const SizedBox(height: 14),
                            const Text(
                              'รูปที่วิเคราะห์เสร็จแล้ว',
                              style: TextStyle(
                                color: MerchantPremiumUi.ink,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                            const SizedBox(height: 8),
                            ..._readyItems.map(
                              (item) => Padding(
                                padding: const EdgeInsets.only(bottom: 10),
                                child: _buildItemCard(item, readyToUse: true),
                              ),
                            ),
                          ],
                          if (_selectedItems.isNotEmpty) ...[
                            const SizedBox(height: 6),
                            const Text(
                              'รูปที่เลือกแล้ว',
                              style: TextStyle(
                                color: MerchantPremiumUi.ink,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                            const SizedBox(height: 8),
                            ..._selectedItems.map(
                              (item) => Padding(
                                padding: const EdgeInsets.only(bottom: 10),
                                child: _buildItemCard(item),
                              ),
                            ),
                          ],
                          if (_pendingItems
                              .where((item) => item.status != 'selected')
                              .isNotEmpty) ...[
                            const SizedBox(height: 6),
                            const Text(
                              'กำลังอัปโหลด / รอวิเคราะห์ AI',
                              style: TextStyle(
                                color: MerchantPremiumUi.ink,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                            const SizedBox(height: 8),
                            ..._pendingItems
                                .where((item) => item.status != 'selected')
                                .map(
                              (item) => Padding(
                                padding: const EdgeInsets.only(bottom: 10),
                                child: _buildItemCard(item),
                              ),
                            ),
                          ],
                          const SizedBox(height: 72),
                        ],
                      ),
                    ),
                ],
              ),
            ),
    );
  }

  Widget _buildIntroCard() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: MerchantPremiumUi.cardDecoration(radius: 18),
      child: const Text(
        'เลือกรูปให้ครบก่อน ระบบจะแสดงรูปจากเครื่องทันที อัปโหลดครบแล้วค่อยส่งวิเคราะห์ AI ทั้งชุด รูปที่รอคิวจะถูกวิเคราะห์ต่อ',
        style: TextStyle(
          color: MerchantPremiumUi.muted,
          height: 1.35,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _buildBatchProgress() {
    final batchId = _batchId;
    final batch = batchId == null
        ? null
        : _service.batchFromItems(batchId, _items);
    final progress = uploadingProgress(batch);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: MerchantPremiumUi.cardDecoration(radius: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'งานล่าสุด',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: MerchantPremiumUi.ink,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
              Text('${(progress * 100).round()}%'),
            ],
          ),
          const SizedBox(height: 8),
          LinearProgressIndicator(
            value: progress,
            color: AppColors.accent,
            backgroundColor: const Color(0xFFFFE7D1),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              if (_progress.uploading)
                _statusChip('อัปโหลด ${_progress.uploaded}/${_progress.total}'),
              _statusChip('พร้อมใช้ ${_readyItems.length}'),
              if (_selectedItems.isNotEmpty)
                _statusChip('เลือกแล้ว ${_selectedItems.length}'),
              _statusChip('รอ/ทำ ${_pendingItems.length}'),
              if (batch != null) ...[
                _statusChip('เสร็จ ${batch.completedCount}'),
                _statusChip('ล้มเหลว ${batch.failedCount}'),
              ],
            ],
          ),
        ],
      ),
    );
  }

  double uploadingProgress(BulkAiImportBatch? batch) {
    if (_progress.uploading && _progress.total > 0) {
      return _progress.uploaded / _progress.total;
    }
    return batch?.progress ?? 0;
  }

  Widget _statusChip(String label) {
    return Chip(
      label: Text(label),
      visualDensity: VisualDensity.compact,
      backgroundColor: const Color(0xFFFFF4E8),
      side: BorderSide(color: AppColors.accent.withValues(alpha: 0.2)),
    );
  }

  Future<void> _retryItem(BulkAiImportItem item) async {
    final user = FirebaseAuth.instance.currentUser;
    final batchId = item.batchId;
    if (user == null || batchId == null || batchId.isEmpty) return;
    try {
      await _service.retryItem(
        ownerUid: user.uid,
        batchId: batchId,
        item: item,
      );
      if (mounted) _showSnack('ส่งรายการนี้เข้าคิวใหม่แล้ว');
    } catch (e) {
      if (mounted) _showSnack('ลองใหม่ไม่สำเร็จ: $e');
    }
  }

  Widget _buildItemCard(BulkAiImportItem item, {bool readyToUse = false}) {
    final imageUrl = item.thumbnailUrl ?? item.imageUrl ?? '';
    final localPath = item.localImagePath;
    final statusColor = switch (item.status) {
      'completed' => MerchantPremiumUi.success,
      'failed' => Colors.red,
      'processing' => AppColors.accent,
      _ => MerchantPremiumUi.muted,
    };
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: MerchantPremiumUi.cardDecoration(radius: 18),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: _BulkItemThumb(imageUrl: imageUrl, localPath: localPath),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.productName?.isNotEmpty == true
                      ? item.productName!
                      : 'รูปที่ ${item.bulkIndex + 1}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: MerchantPremiumUi.ink,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  item.aiError?.isNotEmpty == true
                      ? item.aiError!
                      : (item.productType?.isNotEmpty == true
                            ? item.productType!
                            : _statusLabel(item.status)),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: statusColor, fontSize: 12),
                ),
                if (item.requiresReview)
                  const Padding(
                    padding: EdgeInsets.only(top: 4),
                    child: Text(
                      'ต้องตรวจข้อมูลก่อนบันทึก',
                      style: TextStyle(
                        color: Color(0xFFB45309),
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (item.status == 'failed')
            TextButton(
              onPressed: () => _retryItem(item),
              child: const Text('ลองใหม่'),
            )
          else if (readyToUse)
            TextButton(
              onPressed: () => _openDraft(item),
              child: const Text('ใช้รูปนี้'),
            )
          else
            TextButton(
              onPressed: item.isInProgress ? null : () => _openDraft(item),
              child: const Text('ตรวจ'),
            ),
        ],
      ),
    );
  }

  String _statusLabel(String status) {
    switch (status) {
      case 'selected':
        return 'เลือกแล้ว รออัปโหลด';
      case 'uploaded':
        return 'อัปโหลดแล้ว รอส่งเข้าคิว AI';
      case 'completed':
        return 'AI วิเคราะห์เสร็จแล้ว';
      case 'processing':
        return 'AI กำลังวิเคราะห์';
      case 'failed':
        return 'วิเคราะห์ไม่สำเร็จ';
      case 'uploading':
        return 'กำลังอัปโหลด';
      default:
        return 'รอคิว AI';
    }
  }
}

class _BulkItemThumb extends StatefulWidget {
  const _BulkItemThumb({required this.imageUrl, this.localPath});

  final String imageUrl;
  final String? localPath;

  @override
  State<_BulkItemThumb> createState() => _BulkItemThumbState();
}

class _BulkItemThumbState extends State<_BulkItemThumb> {
  String? _cachedPath;

  @override
  void initState() {
    super.initState();
    unawaited(_resolveCachedPath());
  }

  @override
  void didUpdateWidget(_BulkItemThumb oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.imageUrl != widget.imageUrl ||
        oldWidget.localPath != widget.localPath) {
      _cachedPath = null;
      unawaited(_resolveCachedPath());
    }
  }

  Future<void> _resolveCachedPath() async {
    final localPath = widget.localPath?.trim();
    if (localPath != null &&
        localPath.isNotEmpty &&
        File(localPath).existsSync()) {
      return;
    }
    final url = widget.imageUrl.trim();
    if (url.isEmpty) {
      return;
    }
    final cached = await MediaCacheService.instance.getCachedPath(url);
    if (!mounted || cached == null || cached.isEmpty) {
      return;
    }
    if (!File(cached).existsSync()) {
      return;
    }
    setState(() => _cachedPath = cached);
  }

  Widget _placeholder() {
    return Container(
      width: 72,
      height: 72,
      color: const Color(0xFFFFE7D1),
      child: const Icon(Icons.image_outlined),
    );
  }

  @override
  Widget build(BuildContext context) {
    final localPath = widget.localPath?.trim();
    if (localPath != null &&
        localPath.isNotEmpty &&
        File(localPath).existsSync()) {
      return Image.file(
        File(localPath),
        width: 72,
        height: 72,
        fit: BoxFit.cover,
      );
    }
    final cachedPath = _cachedPath?.trim();
    if (cachedPath != null &&
        cachedPath.isNotEmpty &&
        File(cachedPath).existsSync()) {
      return Image.file(
        File(cachedPath),
        width: 72,
        height: 72,
        fit: BoxFit.cover,
      );
    }
    if (widget.imageUrl.trim().isEmpty) {
      return _placeholder();
    }
    return CachedAppImage(
      imageUrl: widget.imageUrl,
      width: 72,
      height: 72,
      fit: BoxFit.cover,
      placeholder: _placeholder(),
      errorWidget: _placeholder(),
    );
  }
}
