import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';

import '../storage_helper.dart';

class ProductVideoUploadResult {
  const ProductVideoUploadResult({
    required this.videoUrl,
    this.thumbnailUrl,
  });

  final String videoUrl;
  final String? thumbnailUrl;
}

const _imageExtensions = <String>['jpg', 'jpeg', 'png', 'webp', 'heic', 'gif'];
const _videoExtensions = <String>['mp4', 'mov', 'webm', 'mkv'];

String? _imageMimeType(String name) {
  final extension = name.contains('.')
      ? name.split('.').last.toLowerCase()
      : '';
  switch (extension) {
    case 'png':
      return 'image/png';
    case 'webp':
      return 'image/webp';
    case 'gif':
      return 'image/gif';
    case 'heic':
      return 'image/heic';
    default:
      return 'image/jpeg';
  }
}

String _videoContentType(String name) {
  final extension = name.contains('.')
      ? name.split('.').last.toLowerCase()
      : 'mp4';
  switch (extension) {
    case 'mov':
      return 'video/quicktime';
    case 'webm':
      return 'video/webm';
    case 'mkv':
      return 'video/x-matroska';
    default:
      return 'video/mp4';
  }
}

Future<List<XFile>> pickProductImagesFromGalleryWeb({
  required bool pickSingleOnly,
  required int maxCount,
}) async {
  final result = await FilePicker.platform.pickFiles(
    type: FileType.custom,
    allowedExtensions: _imageExtensions,
    allowMultiple: !pickSingleOnly && maxCount > 1,
    withData: true,
  );
  if (result == null || result.files.isEmpty) {
    return const <XFile>[];
  }

  final picks = <XFile>[];
  for (final file in result.files.take(maxCount)) {
    final bytes = file.bytes;
    if (bytes == null || bytes.isEmpty) {
      continue;
    }
    picks.add(
      XFile.fromData(
        bytes,
        name: file.name,
        mimeType: _imageMimeType(file.name),
      ),
    );
  }
  return picks;
}

Future<XFile?> pickProductVideoFromGalleryWeb() async {
  final result = await FilePicker.platform.pickFiles(
    type: FileType.custom,
    allowedExtensions: _videoExtensions,
    allowMultiple: false,
    withData: true,
  );
  if (result == null || result.files.isEmpty) {
    return null;
  }

  final file = result.files.single;
  final bytes = file.bytes;
  if (bytes == null || bytes.isEmpty) {
    return null;
  }

  return XFile.fromData(
    bytes,
    name: file.name,
    mimeType: _videoContentType(file.name),
  );
}

class ProductImageUploadResult {
  const ProductImageUploadResult({
    required this.originalUrl,
    required this.thumbnailUrl,
    this.originalLocalPath,
    this.thumbnailLocalPath,
  });

  final String originalUrl;
  final String thumbnailUrl;
  final String? originalLocalPath;
  final String? thumbnailLocalPath;
}

Future<List<XFile>> compressPickedProductImages(
  List<XFile> picks, {
  required int uploadQuality,
}) async {
  final compressed = <XFile>[];
  for (final pick in picks) {
    try {
      final sourceBytes = await pick.readAsBytes();
      final compressedBytes = await FlutterImageCompress.compressWithList(
        sourceBytes,
        format: CompressFormat.webp,
        minWidth: 1400,
        minHeight: 1400,
        quality: uploadQuality,
      );
      compressed.add(
        XFile.fromData(
          compressedBytes.isNotEmpty ? compressedBytes : sourceBytes,
          name: pick.name.endsWith('.webp')
              ? pick.name
              : '${pick.name.split('.').first}.webp',
          mimeType: 'image/webp',
        ),
      );
    } catch (_) {
      compressed.add(pick);
    }
  }
  return compressed;
}

Future<ProductImageUploadResult?> uploadProductImageWeb({
  required XFile image,
  required String ownerUid,
  required int uploadQuality,
  required int thumbnailQuality,
  void Function(double progress)? onProgress,
}) async {
  final sanitizedBase = image.name
      .split('.')
      .first
      .replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
  final sourceBytes = await image.readAsBytes();
  final originalBytes = await FlutterImageCompress.compressWithList(
    sourceBytes,
    format: CompressFormat.webp,
    minWidth: 1600,
    minHeight: 1600,
    quality: uploadQuality,
  );
  final thumbnailBytes = await FlutterImageCompress.compressWithList(
    sourceBytes,
    format: CompressFormat.webp,
    minWidth: 600,
    minHeight: 600,
    quality: thumbnailQuality,
  );
  final timestamp = DateTime.now().millisecondsSinceEpoch;
  final fileName = '${timestamp}_$sanitizedBase.webp';
  final thumbnailFileName = '${timestamp}_${sanitizedBase}_thumb.webp';
  final baseRef = StorageHelper.instance
      .ref()
      .child('product_images')
      .child(ownerUid);

  Future<String> uploadBytes(Reference ref, Uint8List bytes) async {
    final task = ref.putData(
      bytes,
      SettableMetadata(contentType: 'image/webp'),
    );
    if (onProgress != null) {
      task.snapshotEvents.listen((event) {
        if (event.totalBytes > 0) {
          onProgress(event.bytesTransferred / event.totalBytes);
        }
      });
    }
    final snapshot = await task;
    return snapshot.ref.getDownloadURL();
  }

  final originalUrl = await uploadBytes(baseRef.child(fileName), originalBytes);
  final thumbnailUrl = await uploadBytes(
    baseRef.child('thumbnails').child(thumbnailFileName),
    thumbnailBytes,
  );

  return ProductImageUploadResult(
    originalUrl: originalUrl,
    thumbnailUrl: thumbnailUrl,
  );
}

Future<ProductVideoUploadResult?> uploadProductVideoWeb({
  required XFile video,
  required String ownerUid,
  void Function(double progress)? onProgress,
}) async {
  final sanitizedBase = video.name
      .split('.')
      .first
      .replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
  final extension = video.name.contains('.')
      ? video.name.split('.').last.toLowerCase()
      : 'mp4';
  final timestamp = DateTime.now().millisecondsSinceEpoch;
  final videoFileName = '${timestamp}_$sanitizedBase.$extension';
  final ref = StorageHelper.instance
      .ref()
      .child('product_videos')
      .child(ownerUid)
      .child(videoFileName);

  final bytes = await video.readAsBytes();
  final task = ref.putData(
    bytes,
    SettableMetadata(contentType: _videoContentType(video.name)),
  );
  if (onProgress != null) {
    task.snapshotEvents.listen((event) {
      if (event.totalBytes > 0) {
        onProgress(event.bytesTransferred / event.totalBytes);
      }
    });
  }
  final snapshot = await task;
  final videoUrl = await snapshot.ref.getDownloadURL();
  return ProductVideoUploadResult(videoUrl: videoUrl);
}
