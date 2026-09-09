import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// 58mm thermal head width in dots (384 for 57mm pocket / standard 58mm).
const int thermalRasterWidthDots = 384;
const int receiptTextThreshold = 235;
const int _s1FeedDots = 80;

/// Builds a complete Lujiang/LuckPrinter S1PRO BLE job.
///
/// The S1PRO has a 384-dot head. Rendering wider data makes QR modules and
/// text get clipped or resampled by firmware, so the bitmap is reduced to the
/// native head width before converting it to one-bit GS v 0 raster data.
Uint8List buildS1ProReceiptBytes(Uint8List receiptPng) {
  final decoded = img.decodePng(receiptPng);
  if (decoded == null) {
    throw Exception('ไม่สามารถอ่านภาพใบเสร็จได้');
  }

  var prepared = img.grayscale(decoded);
  if (prepared.width != thermalRasterWidthDots) {
    final height =
        (prepared.height * thermalRasterWidthDots / prepared.width)
            .round()
            .clamp(1, 8192);
    prepared = img.copyResize(
      prepared,
      width: thermalRasterWidthDots,
      height: height,
      interpolation: img.Interpolation.average,
    );
  }
  // Keep anti-aliased Thai/number strokes after the 3x -> 384-dot downscale.
  // QR pixels are pure black/white, so this does not change its modules.
  prepared = thresholdReceiptMono(prepared, threshold: receiptTextThreshold);

  final width = prepared.width;
  final height = prepared.height;
  if (width <= 0 || height <= 0) {
    throw Exception('ภาพใบเสร็จว่าง');
  }

  final widthBytes = width % 8 == 0 ? width ~/ 8 : width ~/ 8 + 1;
  final rasterData = Uint8List(widthBytes * height);
  var offset = 0;
  for (var y = 0; y < height; y++) {
    for (var byteIndex = 0; byteIndex < widthBytes; byteIndex++) {
      var value = 0;
      for (var bit = 0; bit < 8; bit++) {
        final x = byteIndex * 8 + bit;
        var dot = 0;
        if (x < width) {
          dot = prepared.getPixel(x, y).r < 128 ? 1 : 0;
        }
        value = (value << 1) | dot;
      }
      rasterData[offset++] = value;
    }
  }

  final bytes = BytesBuilder(copy: false);
  bytes.add(<int>[0x10, 0xFF, 0x10, 0x00, 0x02]); // density: dark (text); QR stays pure B/W
  bytes.add(<int>[0x10, 0xFF, 0xF1, 0x03]); // enable Lujiang printer
  bytes.add(Uint8List(12)); // wake
  bytes.add(<int>[0x1D, 0x76, 0x30, 0x00]); // GS v 0 m=0
  bytes.add(<int>[widthBytes & 0xFF, (widthBytes >> 8) & 0xFF]);
  bytes.add(<int>[height & 0xFF, (height >> 8) & 0xFF]);
  bytes.add(rasterData);
  bytes.add(<int>[0x1B, 0x4A, _s1FeedDots]); // feed paper 80 dots
  bytes.add(<int>[0x10, 0xFF, 0xF1, 0x45]); // stop Lujiang print job
  return bytes.toBytes();
}

img.Image thresholdReceiptMono(img.Image source, {int threshold = 128}) {
  final out = img.Image.from(source);
  for (final pixel in out) {
    final lum = img.getLuminanceRgb(pixel.r, pixel.g, pixel.b);
    final value = lum < threshold ? 0 : 255;
    pixel
      ..r = value
      ..g = value
      ..b = value
      ..a = 255;
  }
  return out;
}
