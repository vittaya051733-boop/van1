import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';

Future<String?> uploadProfileImage({
  required Reference ref,
  required XFile image,
}) async {
  try {
    final bytes = await image.readAsBytes();
    final uploadBytes = kIsWeb
        ? await FlutterImageCompress.compressWithList(
            bytes,
            format: CompressFormat.jpeg,
            quality: 70,
          )
        : bytes;
    final snapshot = await ref.putData(
      uploadBytes.isNotEmpty ? uploadBytes : bytes,
      SettableMetadata(contentType: 'image/jpeg'),
    );
    return await snapshot.ref.getDownloadURL();
  } catch (_) {
    return null;
  }
}
