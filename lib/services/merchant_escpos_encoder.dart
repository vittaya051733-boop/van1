import 'dart:math' as math;
import 'dart:typed_data';

import 'package:esc_pos_utils_plus/esc_pos_utils_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

import 'merchant_receipt_raster.dart';
import 'order_qr_receipt_bitmap.dart';

/// BLE pocket printers have tiny buffers — send raster in short bands.
const int pocketPrinterBandHeight = 48;

CapabilityProfile? _cachedEscPosProfile;

Future<CapabilityProfile> _loadEscPosProfile() async {
  return _cachedEscPosProfile ??= await CapabilityProfile.load();
}

Future<List<int>> buildEscPosReceiptBytes(
  Uint8List receiptPng, {
  bool pocketPrinter = false,
  double? qrTopRatio,
  double? qrHeightRatio,
}) async {
  final profile = await _loadEscPosProfile();
  final generator = Generator(PaperSize.mm58, profile);
  final decoded = img.decodePng(receiptPng);
  if (decoded == null) {
    throw Exception('ไม่สามารถอ่านภาพใบเสร็จได้');
  }

  final raster = _prepareRasterImage(decoded);
  if (pocketPrinter) {
    final qrBand = _qrBandFromRatios(raster, qrTopRatio, qrHeightRatio);
    if (qrBand != null) {
      try {
        return _buildPocketPrinterReceiptBytes(
          generator,
          raster,
          qrBand: qrBand,
        );
      } catch (error) {
        // Some BLE firmware chokes on mixed band sizes; fall back to uniform bands.
        debugPrint('Printer pocket QR-band encode failed, retrying: $error');
      }
    }
    return _buildPocketPrinterReceiptBytes(generator, raster);
  }

  final bytes = <int>[...generator.reset()];
  bytes.addAll(generator.imageRaster(raster, align: PosAlign.center));
  bytes.addAll(generator.feed(receiptTrailingBlankLines));
  bytes.addAll(generator.cut());
  return bytes;
}

List<int> _buildPocketPrinterReceiptBytes(
  Generator generator,
  img.Image raster, {
  ({int top, int height})? qrBand,
}) {
  final bytes = <int>[...generator.reset()];

  if (qrBand != null) {
    if (qrBand.top > 0) {
      _addRasterBands(
        bytes,
        generator,
        img.copyCrop(
          raster,
          x: 0,
          y: 0,
          width: raster.width,
          height: qrBand.top,
        ),
      );
    }

    final box = qrBand.height;
    final left =
        ((raster.width - box) / 2).round().clamp(0, raster.width - box);
    final qrCrop = img.copyCrop(
      raster,
      x: left,
      y: qrBand.top,
      width: box,
      height: box,
    );
    if (qrCrop.width > 0 && qrCrop.height > 0) {
      _addRasterBands(bytes, generator, qrCrop);
    }

    final footerTop = qrBand.top + qrBand.height;
    if (footerTop < raster.height) {
      _addRasterBands(
        bytes,
        generator,
        img.copyCrop(
          raster,
          x: 0,
          y: footerTop,
          width: raster.width,
          height: raster.height - footerTop,
        ),
      );
    }
  } else {
    _addRasterBands(bytes, generator, raster);
  }

  bytes.addAll(generator.feed(receiptTrailingBlankLines));
  return bytes;
}

void _addRasterBands(
  List<int> bytes,
  Generator generator,
  img.Image raster,
) {
  if (raster.width <= 0 || raster.height <= 0) {
    return;
  }
  var y = 0;
  while (y < raster.height) {
    final bandHeight = math.min(pocketPrinterBandHeight, raster.height - y);
    if (bandHeight <= 0) {
      break;
    }
    final band = img.copyCrop(
      raster,
      x: 0,
      y: y,
      width: raster.width,
      height: bandHeight,
    );
    if (band.width <= 0 || band.height <= 0) {
      break;
    }
    bytes.addAll(
      generator.imageRaster(
        band,
        align: PosAlign.center,
        highDensityHorizontal: true,
        highDensityVertical: true,
      ),
    );
    y += bandHeight;
  }
}

({int top, int height})? _qrBandFromRatios(
  img.Image raster,
  double? qrTopRatio,
  double? qrHeightRatio,
) {
  if (qrTopRatio == null ||
      qrHeightRatio == null ||
      qrHeightRatio <= 0 ||
      raster.height <= 0 ||
      raster.width <= 0) {
    return null;
  }
  final top = (qrTopRatio * raster.height).round().clamp(0, raster.height - 1);
  final height = (qrHeightRatio * raster.height)
      .round()
      .clamp(1, raster.height - top);
  final box = math.min(height, raster.width);
  if (box <= 0 || top + box > raster.height) {
    return null;
  }
  return (top: top, height: box);
}

img.Image _prepareRasterImage(img.Image source) {
  var prepared = img.grayscale(source);
  if (prepared.width != thermalRasterWidthDots) {
    final height = (prepared.height * thermalRasterWidthDots / prepared.width)
        .round()
        .clamp(1, 4096);
    prepared = img.copyResize(
      prepared,
      width: thermalRasterWidthDots,
      height: height,
      interpolation: img.Interpolation.nearest,
    );
  }
  prepared = thresholdReceiptMono(prepared, threshold: receiptTextThreshold);
  if (prepared.numChannels != 4) {
    prepared = prepared.convert(numChannels: 4);
  }
  return prepared;
}
