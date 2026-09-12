import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Local persistence for in-progress "เพิ่มสินค้าใหม่" sessions.
class ProductAddDraftStore {
  ProductAddDraftStore._();

  static final ProductAddDraftStore instance = ProductAddDraftStore._();

  static const String _keyPrefix = 'product_add_draft_v1_';

  String _prefsKey(String ownerUid) => '$_keyPrefix$ownerUid';

  String createDraftId(String ownerUid) {
    final millis = DateTime.now().millisecondsSinceEpoch;
    return '${ownerUid}_$millis'.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
  }

  Future<void> save(String ownerUid, Map<String, dynamic> draft) async {
    if (ownerUid.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    final payload = <String, dynamic>{
      ...draft,
      'savedAtMillis': DateTime.now().millisecondsSinceEpoch,
    };
    await prefs.setString(_prefsKey(ownerUid), jsonEncode(payload));
  }

  Future<Map<String, dynamic>?> load(String ownerUid) async {
    if (ownerUid.isEmpty) return null;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey(ownerUid));
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      return Map<String, dynamic>.from(decoded);
    } catch (error) {
      debugPrint('ProductAddDraftStore.load failed: $error');
      return null;
    }
  }

  Future<void> clear(String ownerUid) async {
    if (ownerUid.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefsKey(ownerUid));
  }

  Future<String?> persistMediaBytes({
    required List<int> bytes,
    required String ownerUid,
    required String draftId,
    required String fileName,
  }) async {
    if (kIsWeb || bytes.isEmpty || ownerUid.isEmpty || draftId.isEmpty) {
      return null;
    }
    try {
      final docsDir = await getApplicationDocumentsDirectory();
      final draftDir = Directory(
        '${docsDir.path}/product_drafts/$ownerUid/$draftId',
      );
      if (!await draftDir.exists()) {
        await draftDir.create(recursive: true);
      }
      final destination = File('${draftDir.path}/$fileName');
      await destination.writeAsBytes(bytes, flush: true);
      return destination.path;
    } catch (error) {
      debugPrint('ProductAddDraftStore.persistMediaBytes failed: $error');
      return null;
    }
  }

  Future<String?> persistMediaFile({
    required String sourcePath,
    required String ownerUid,
    required String draftId,
    required String fileName,
  }) async {
    if (kIsWeb || sourcePath.isEmpty) {
      return sourcePath.isEmpty ? null : sourcePath;
    }

    try {
      final source = File(sourcePath);
      if (!await source.exists()) {
        return null;
      }

      final docsDir = await getApplicationDocumentsDirectory();
      final draftDir = Directory(
        '${docsDir.path}/product_drafts/$ownerUid/$draftId',
      );
      if (!await draftDir.exists()) {
        await draftDir.create(recursive: true);
      }

      final destination = File('${draftDir.path}/$fileName');
      if (destination.path != source.path) {
        await source.copy(destination.path);
      }
      return destination.path;
    } catch (error) {
      debugPrint('ProductAddDraftStore.persistMediaFile failed: $error');
      return null;
    }
  }

  Future<void> deleteDraftMediaDir({
    required String ownerUid,
    required String draftId,
  }) async {
    if (kIsWeb || ownerUid.isEmpty || draftId.isEmpty) return;
    try {
      final docsDir = await getApplicationDocumentsDirectory();
      final draftDir = Directory(
        '${docsDir.path}/product_drafts/$ownerUid/$draftId',
      );
      if (await draftDir.exists()) {
        await draftDir.delete(recursive: true);
      }
    } catch (error) {
      debugPrint('ProductAddDraftStore.deleteDraftMediaDir failed: $error');
    }
  }
}
