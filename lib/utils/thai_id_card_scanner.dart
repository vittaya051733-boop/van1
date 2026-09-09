import 'dart:io';
import 'dart:math' as math;

import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

class ThaiIdCardQualityIssue {
  const ThaiIdCardQualityIssue(this.code, this.messageTh);

  final String code;
  final String messageTh;
}

class ThaiIdCardQualityResult {
  const ThaiIdCardQualityResult.pass()
      : passed = true,
        issues = const <ThaiIdCardQualityIssue>[];

  const ThaiIdCardQualityResult.fail(this.issues) : passed = false;

  final bool passed;
  final List<ThaiIdCardQualityIssue> issues;
}

class ThaiIdCardScanResult {
  const ThaiIdCardScanResult({
    required this.nationalId,
    required this.checksumValid,
    required this.ocrTextLength,
  });

  final String nationalId;
  final bool checksumValid;
  final int ocrTextLength;

  bool get isValid => checksumValid && nationalId.length == 13;
}

/// ML Kit OCR + ความชัด + checksum เลขบัตรไทย
class ThaiIdCardScanner {
  ThaiIdCardScanner._();

  static const int minShortEdgePx = 720;
  static const double minSharpnessStdDev = 20;

  static Future<ThaiIdCardQualityResult> validateImageQuality(File file) async {
    final issues = <ThaiIdCardQualityIssue>[];
    final bytes = await file.readAsBytes();
    if (bytes.length < 40 * 1024) {
      issues.add(
        const ThaiIdCardQualityIssue(
          'file_too_small',
          'ไฟล์เล็กเกินไป — ถ่ายใหม่ให้ชัดและใกล้ขึ้น',
        ),
      );
    }

    final decoded = img.decodeImage(bytes);
    if (decoded == null) {
      issues.add(
        const ThaiIdCardQualityIssue(
          'decode_failed',
          'อ่านไฟล์รูปไม่ได้ — ลองถ่ายใหม่',
        ),
      );
      return ThaiIdCardQualityResult.fail(issues);
    }

    final shortEdge = math.min(decoded.width, decoded.height);
    if (shortEdge < minShortEdgePx) {
      issues.add(
        ThaiIdCardQualityIssue(
          'resolution_low',
          'ความละเอียดต่ำ ($shortEdge px) — ใกล้บัตรและให้เต็มกรอบ',
        ),
      );
    }

    if (_isBlurry(decoded)) {
      issues.add(
        const ThaiIdCardQualityIssue(
          'blurry',
          'ภาพเบลอหรือไม่ชัด — ถ่ายในที่แสงดี ไม่สั่น',
        ),
      );
    }

    if (issues.isNotEmpty) {
      return ThaiIdCardQualityResult.fail(issues);
    }
    return const ThaiIdCardQualityResult.pass();
  }

  static Future<ThaiIdCardScanResult> scanNationalId(File file) async {
    final quality = await validateImageQuality(file);
    if (!quality.passed) {
      throw ThaiIdCardScanException(
        quality.issues.map((issue) => issue.messageTh).join('\n'),
      );
    }

    final recognizer = TextRecognizer(script: TextRecognitionScript.latin);
    final tempFiles = <File>[];
    try {
      final result = await _scanFileAtOrientations(
        recognizer: recognizer,
        source: file,
        tempFiles: tempFiles,
      );
      if (result != null) {
        return result;
      }

      throw const ThaiIdCardScanException(
        'ไม่พบเลขบัตรประชาชน 13 หลัก — จัดบัตรให้ตรงและชัด (แนวตั้งหรือแนวนอน)',
      );
    } finally {
      await recognizer.close();
      for (final temp in tempFiles) {
        try {
          if (await temp.exists()) {
            await temp.delete();
          }
        } catch (_) {}
      }
    }
  }

  /// ลอง OCR ทั้งแนวตั้งและแนวนอน — ML Kit อ่านเลขแนวนอนได้ดีกว่า
  static Future<ThaiIdCardScanResult?> _scanFileAtOrientations({
    required TextRecognizer recognizer,
    required File source,
    required List<File> tempFiles,
  }) async {
    final attempts = <File>[source];

    final bytes = await source.readAsBytes();
    final decoded = img.decodeImage(bytes);
    if (decoded != null) {
      for (final degrees in const [90, 270]) {
        final rotated = img.copyRotate(decoded, angle: degrees);
        final tempPath = p.join(
          Directory.systemTemp.path,
          'id_ocr_${degrees}_${DateTime.now().millisecondsSinceEpoch}.jpg',
        );
        final tempFile = File(tempPath);
        await tempFile.writeAsBytes(img.encodeJpg(rotated, quality: 92));
        tempFiles.add(tempFile);
        attempts.add(tempFile);
      }
    }

    var sawReadableText = false;
    for (final attempt in attempts) {
      final recognized = await recognizer.processImage(
        InputImage.fromFilePath(attempt.path),
      );
      final rawText = recognized.text;
      if (rawText.trim().length < 8) {
        continue;
      }
      sawReadableText = true;

      final nationalId = _extractNationalId(rawText);
      if (nationalId == null ||
          !validateThaiNationalIdChecksum(nationalId)) {
        continue;
      }

      return ThaiIdCardScanResult(
        nationalId: nationalId,
        checksumValid: true,
        ocrTextLength: rawText.length,
      );
    }

    if (!sawReadableText) {
      throw const ThaiIdCardScanException(
        'อ่านตัวเลขจากบัตรไม่ได้ — ถ่ายด้านหน้าให้ชัดและไม่สะท้อนแสง',
      );
    }
    return null;
  }

  static bool validateThaiNationalIdChecksum(String id) {
    final digits = id.replaceAll(RegExp(r'\D'), '');
    if (digits.length != 13) {
      return false;
    }
    var sum = 0;
    for (var i = 0; i < 12; i++) {
      sum += int.parse(digits[i]) * (13 - i);
    }
    final check = (11 - (sum % 11)) % 10;
    return check == int.parse(digits[12]);
  }

  static String? derivePdfPasswordDdMmYyyyCe(String nationalId) {
    final id = nationalId.replaceAll(RegExp(r'\D'), '');
    if (!validateThaiNationalIdChecksum(id)) {
      return null;
    }
    final type = int.tryParse(id.substring(0, 1));
    if (type == null || type < 1 || type > 4) {
      return null;
    }
    final yy = int.parse(id.substring(1, 3));
    final mm = int.parse(id.substring(3, 5));
    final dd = int.parse(id.substring(5, 7));
    if (mm < 1 || mm > 12 || dd < 1 || dd > 31) {
      return null;
    }
    final yearBe = 2500 + yy;
    final yearCe = yearBe - 543;
    if (yearCe < 1900 || yearCe > 2100) {
      return null;
    }
    return '${dd.toString().padLeft(2, '0')}'
        '${mm.toString().padLeft(2, '0')}'
        '$yearCe';
  }

  static String? _extractNationalId(String rawText) {
    final compact = rawText.replaceAll(RegExp(r'\D'), '');
    for (var i = 0; i + 13 <= compact.length; i++) {
      final candidate = compact.substring(i, i + 13);
      if (validateThaiNationalIdChecksum(candidate)) {
        return candidate;
      }
    }
    return null;
  }

  static bool _isBlurry(img.Image image) {
    final grayscale = img.grayscale(image);
    final pixels = grayscale.getBytes();
    if (pixels.isEmpty) {
      return true;
    }
    final mean = pixels.reduce((a, b) => a + b) / pixels.length;
    final variance = pixels
            .map((p) => (p - mean) * (p - mean))
            .reduce((a, b) => a + b) /
        pixels.length;
    final stddev = math.sqrt(variance);
    return stddev < minSharpnessStdDev;
  }
}

class ThaiIdCardScanException implements Exception {
  const ThaiIdCardScanException(this.message);
  final String message;

  @override
  String toString() => message;
}
