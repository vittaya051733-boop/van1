import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';

/// On-device cache of AI product analysis, keyed by image identity.
///
/// Gallery re-picks often recompress the same photo, so lookup uses SHA-256
/// first and falls back to average-hash with a Hamming distance threshold.
class ProductAiImageCache {
  ProductAiImageCache._();

  static final ProductAiImageCache instance = ProductAiImageCache._();

  static const String _keyPrefix = 'product_ai_image_cache_v1_';
  static const int _maxEntries = 30;
  static const int _ahashHammingThreshold = 32;

  String _prefsKey(String ownerUid) => '$_keyPrefix$ownerUid';

  Future<void> save({
    required String ownerUid,
    required Uint8List imageBytes,
    required Map<String, dynamic> aiResult,
  }) async {
    if (ownerUid.isEmpty || imageBytes.isEmpty || aiResult.isEmpty) {
      return;
    }

    try {
      final fingerprint = await compute(_fingerprintImage, imageBytes);
      final prefs = await SharedPreferences.getInstance();
      final entries = await _loadEntries(prefs, ownerUid);
      entries.removeWhere(
        (entry) =>
            entry.sha256Hex == fingerprint.sha256Hex ||
            (fingerprint.ahash != null &&
                entry.ahash != null &&
                _hamming(entry.ahash!, fingerprint.ahash!) <=
                    _ahashHammingThreshold),
      );
      entries.insert(
        0,
        _CachedAiImageEntry(
          sha256Hex: fingerprint.sha256Hex,
          ahash: fingerprint.ahash,
          aiResult: Map<String, dynamic>.from(aiResult),
          savedAtMillis: DateTime.now().millisecondsSinceEpoch,
        ),
      );
      if (entries.length > _maxEntries) {
        entries.removeRange(_maxEntries, entries.length);
      }
      await prefs.setString(
        _prefsKey(ownerUid),
        jsonEncode(entries.map((entry) => entry.toJson()).toList()),
      );
    } catch (error) {
      debugPrint('ProductAiImageCache.save failed: $error');
    }
  }

  Future<Map<String, dynamic>?> find({
    required String ownerUid,
    required Uint8List imageBytes,
  }) async {
    if (ownerUid.isEmpty || imageBytes.isEmpty) {
      return null;
    }

    try {
      final fingerprint = await compute(_fingerprintImage, imageBytes);
      final prefs = await SharedPreferences.getInstance();
      final entries = await _loadEntries(prefs, ownerUid);
      for (final entry in entries) {
        if (entry.sha256Hex == fingerprint.sha256Hex) {
          return Map<String, dynamic>.from(entry.aiResult);
        }
      }
      if (fingerprint.ahash == null) {
        return null;
      }
      _CachedAiImageEntry? best;
      var bestDistance = _ahashHammingThreshold + 1;
      for (final entry in entries) {
        final cachedHash = entry.ahash;
        if (cachedHash == null) {
          continue;
        }
        final distance = _hamming(cachedHash, fingerprint.ahash!);
        if (distance < bestDistance) {
          bestDistance = distance;
          best = entry;
        }
      }
      if (best == null || bestDistance > _ahashHammingThreshold) {
        return null;
      }
      return Map<String, dynamic>.from(best.aiResult);
    } catch (error) {
      debugPrint('ProductAiImageCache.find failed: $error');
      return null;
    }
  }

  Future<List<_CachedAiImageEntry>> _loadEntries(
    SharedPreferences prefs,
    String ownerUid,
  ) async {
    final raw = prefs.getString(_prefsKey(ownerUid));
    if (raw == null || raw.isEmpty) {
      return <_CachedAiImageEntry>[];
    }
    final decoded = jsonDecode(raw);
    if (decoded is! List) {
      return <_CachedAiImageEntry>[];
    }
    return decoded
        .whereType<Map>()
        .map((item) => _CachedAiImageEntry.fromJson(Map<String, dynamic>.from(item)))
        .where((entry) => entry.aiResult.isNotEmpty)
        .toList();
  }
}

class _ImageFingerprint {
  const _ImageFingerprint({required this.sha256Hex, this.ahash});

  final String sha256Hex;
  final String? ahash;
}

class _CachedAiImageEntry {
  const _CachedAiImageEntry({
    required this.sha256Hex,
    required this.ahash,
    required this.aiResult,
    required this.savedAtMillis,
  });

  final String sha256Hex;
  final String? ahash;
  final Map<String, dynamic> aiResult;
  final int savedAtMillis;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'sha256': sha256Hex,
      'ahash': ahash,
      'aiResult': aiResult,
      'savedAtMillis': savedAtMillis,
    };
  }

  factory _CachedAiImageEntry.fromJson(Map<String, dynamic> json) {
    final result = json['aiResult'];
    return _CachedAiImageEntry(
      sha256Hex: (json['sha256'] ?? '').toString(),
      ahash: (json['ahash'] as String?)?.trim(),
      aiResult: result is Map
          ? Map<String, dynamic>.from(result)
          : <String, dynamic>{},
      savedAtMillis: json['savedAtMillis'] is num
          ? (json['savedAtMillis'] as num).toInt()
          : 0,
    );
  }
}

_ImageFingerprint _fingerprintImage(Uint8List bytes) {
  return _ImageFingerprint(
    sha256Hex: sha256.convert(bytes).toString(),
    ahash: _averageHash(bytes),
  );
}

String? _averageHash(Uint8List bytes) {
  final decoded = img.decodeImage(bytes);
  if (decoded == null) {
    return null;
  }
  final small = img.copyResize(
    decoded,
    width: 16,
    height: 16,
    interpolation: img.Interpolation.average,
  );
  final luminances = <int>[];
  var sum = 0;
  for (var y = 0; y < 16; y++) {
    for (var x = 0; x < 16; x++) {
      final pixel = small.getPixel(x, y);
      final lum = (pixel.r + pixel.g + pixel.b) ~/ 3;
      luminances.add(lum.toInt());
      sum += lum.toInt();
    }
  }
  if (luminances.isEmpty) {
    return null;
  }
  final average = sum ~/ luminances.length;
  final bits = StringBuffer();
  for (final lum in luminances) {
    bits.write(lum >= average ? '1' : '0');
  }
  return bits.toString();
}

int _hamming(String left, String right) {
  if (left.length != right.length) {
    return 1 << 20;
  }
  var distance = 0;
  for (var i = 0; i < left.length; i++) {
    if (left.codeUnitAt(i) != right.codeUnitAt(i)) {
      distance++;
    }
  }
  return distance;
}
