import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'order_qr_receipt_layout.dart';

/// Mini Pocket Printer S1: 57mm paper, 384-dot / 203dpi head.
/// Render supersampled then downscale to 384 dots for crisp QR + Thai text.
const int receiptRenderScale = 3;
const double receiptPaperWidth = 384;
const double receiptPadding = 16;
const double receiptQrSize = 240;
const double receiptQrQuietZone = 12;
const double receiptBodyLineHeight = 18;
const int receiptTrailingBlankLines = 3;

double _s(double value) => value * receiptRenderScale;

class OrderQrReceiptImage {
  const OrderQrReceiptImage({
    required this.pngBytes,
    required this.qrTopRatio,
    required this.qrHeightRatio,
  });

  final Uint8List pngBytes;
  final double qrTopRatio;
  final double qrHeightRatio;
}

Future<OrderQrReceiptImage> buildOrderQrReceiptPngBytes({
  required String qrPayload,
  required OrderQrReceiptLayout layout,
  String receiptTitle = 'แว๊นตลาด ORDER QR',
}) async {
  await GoogleFonts.pendingFonts([GoogleFonts.notoSansThai()]);

  final titleStyle = GoogleFonts.notoSansThai(
    fontSize: _s(20),
    fontWeight: FontWeight.w800,
    color: Colors.black,
    height: 1.15,
  );
  final sectionStyle = GoogleFonts.notoSansThai(
    fontSize: _s(17),
    fontWeight: FontWeight.w800,
    color: Colors.black,
    height: 1.2,
  );
  final bodyStyle = GoogleFonts.notoSansThai(
    fontSize: _s(16),
    fontWeight: FontWeight.w900,
    color: Colors.black,
    height: 1.2,
  );
  final toppingStyle = GoogleFonts.notoSansThai(
    fontSize: _s(14),
    fontWeight: FontWeight.w900,
    color: Colors.black,
    height: 1.15,
  );
  final totalStyle = GoogleFonts.notoSansThai(
    fontSize: _s(17),
    fontWeight: FontWeight.w800,
    color: Colors.black,
    height: 1.2,
  );

  final contentWidth = _s(receiptPaperWidth - (receiptPadding * 2));
  final qrLabel = layout.orderCode.isNotEmpty
      ? 'เลขที่ ${layout.orderCode}'
      : 'Order ${layout.orderId}';
  final blocks = <_ReceiptBlock>[
    _ReceiptBlock.text(receiptTitle, titleStyle, center: true),
    _ReceiptBlock.gap(_s(4)),
    _ReceiptBlock.text(qrLabel, sectionStyle, center: true),
    _ReceiptBlock.gap(_s(6)),
    _ReceiptBlock.qr(qrPayload),
    _ReceiptBlock.gap(_s(4)),
    _ReceiptBlock.text(qrPayload, toppingStyle, center: true),
    _ReceiptBlock.gap(_s(8)),
    _ReceiptBlock.divider(),
    _ReceiptBlock.gap(_s(6)),
    _ReceiptBlock.text('Order ID: ${layout.orderId}', bodyStyle),
    _ReceiptBlock.gap(_s(2)),
    _ReceiptBlock.text(
      'เลขออเดอร์: ${layout.orderCode.isEmpty ? '-' : layout.orderCode}',
      bodyStyle,
    ),
    _ReceiptBlock.gap(_s(2)),
    _ReceiptBlock.text('วันที่: ${layout.dateTimeText}', bodyStyle),
    _ReceiptBlock.gap(_s(4)),
    _ReceiptBlock.text('รายการสินค้า', sectionStyle),
    _ReceiptBlock.gap(_s(3)),
  ];

  for (final item in layout.items) {
    blocks.add(
      _ReceiptBlock.leftRight(
        '${item.name} x${item.quantity}',
        formatOrderQrMoney(item.lineTotal),
        bodyStyle,
      ),
    );
    final toppings = item.toppings;
    if (toppings != null) {
      blocks.add(_ReceiptBlock.text('  ท็อปปิ้ง: $toppings', toppingStyle));
    }
  }

  blocks.addAll(<_ReceiptBlock>[
    _ReceiptBlock.gap(_s(4)),
    _ReceiptBlock.leftRight(
      'ค่าส่ง',
      formatOrderQrMoney(layout.shippingFee),
      bodyStyle,
    ),
    _ReceiptBlock.gap(_s(2)),
    _ReceiptBlock.leftRight(
      'ยอดรวม',
      formatOrderQrMoney(layout.grandTotal),
      totalStyle,
      rightStyle: totalStyle,
    ),
    _ReceiptBlock.gap(_s(receiptBodyLineHeight * receiptTrailingBlankLines)),
  ]);

  final totalHeight = blocks.fold<double>(
        _s(receiptPadding * 2),
        (height, block) => height + block.height(contentWidth),
      ) +
      _s(4);

  final renderWidth = (receiptPaperWidth * receiptRenderScale).round();
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
    Rect.fromLTWH(0, 0, renderWidth.toDouble(), totalHeight),
    Paint()..color = const Color(0xFFFFFFFF),
  );

  var y = _s(receiptPadding);
  var qrTop = 0.0;
  var qrHeight = 0.0;
  for (final block in blocks) {
    if (block.isQr) {
      qrTop = y;
      qrHeight = block.height(contentWidth);
    }
    y += block.paint(canvas, y, contentWidth);
  }

  final picture = recorder.endRecording();
  final image = await picture.toImage(
    renderWidth,
    totalHeight.ceil(),
  );
  final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();

  if (byteData == null) {
    throw StateError('ไม่สามารถสร้างภาพใบพิมพ์ได้');
  }
  return OrderQrReceiptImage(
    pngBytes: byteData.buffer.asUint8List(),
    qrTopRatio: totalHeight > 0 ? qrTop / totalHeight : 0,
    qrHeightRatio: totalHeight > 0 ? qrHeight / totalHeight : 0,
  );
}

void _paintBoldText(Canvas canvas, TextPainter painter, Offset offset) {
  painter.paint(canvas, offset);
  painter.paint(canvas, offset + Offset(_s(0.8), 0));
}

class _ReceiptBlock {
  _ReceiptBlock._(this._height, this._paint, {this.isQr = false});

  factory _ReceiptBlock.text(
    String text,
    TextStyle style, {
    bool center = false,
  }) {
    return _ReceiptBlock._(
      0,
      (canvas, y, contentWidth) {
        final painter = TextPainter(
          text: TextSpan(text: text, style: style),
          textAlign: center ? TextAlign.center : TextAlign.left,
          textDirection: TextDirection.ltr,
          maxLines: null,
        )..layout(maxWidth: contentWidth);

        final dx = center
            ? _s(receiptPadding) + ((contentWidth - painter.width) / 2)
            : _s(receiptPadding);
        _paintBoldText(canvas, painter, Offset(dx, y));
        return painter.height;
      },
    );
  }

  factory _ReceiptBlock.leftRight(
    String left,
    String right,
    TextStyle leftStyle, {
    TextStyle? rightStyle,
  }) {
    return _ReceiptBlock._(
      0,
      (canvas, y, contentWidth) {
        final resolvedRightStyle = rightStyle ?? leftStyle;
        final rightPainter = TextPainter(
          text: TextSpan(text: right, style: resolvedRightStyle),
          textDirection: TextDirection.ltr,
        )..layout();

        final leftMaxWidth = math.max(
          40.0,
          contentWidth - rightPainter.width - 8,
        );
        final leftPainter = TextPainter(
          text: TextSpan(text: left, style: leftStyle),
          textDirection: TextDirection.ltr,
          maxLines: null,
        )..layout(maxWidth: leftMaxWidth);

        _paintBoldText(canvas, leftPainter, Offset(_s(receiptPadding), y));
        _paintBoldText(
          canvas,
          rightPainter,
          Offset(_s(receiptPadding) + contentWidth - rightPainter.width, y),
        );
        return math.max(leftPainter.height, rightPainter.height).toDouble();
      },
    );
  }

  factory _ReceiptBlock.divider() {
    final line = receiptRenderScale.toDouble();
    return _ReceiptBlock._(
      line,
      (canvas, y, contentWidth) {
        final paint = Paint()
          ..color = Colors.black
          ..isAntiAlias = false
          ..strokeWidth = line;
        canvas.drawLine(
          Offset(_s(receiptPadding), y),
          Offset(_s(receiptPadding) + contentWidth, y),
          paint,
        );
        return line;
      },
    );
  }

  factory _ReceiptBlock.gap(double size) {
    return _ReceiptBlock._(size, (_, __, ___) => size);
  }

  factory _ReceiptBlock.qr(String payload) {
    final qrCode = QrCode.fromData(
      data: payload,
      errorCorrectLevel: QrErrorCorrectLevel.L,
    );
    final qrSideFinal =
        _qrPixelPerfectSize(qrCode.moduleCount, receiptQrSize);
    final qrSide = qrSideFinal * receiptRenderScale;
    final box = qrSide + (receiptQrQuietZone * 2 * receiptRenderScale);
    return _ReceiptBlock._(
      box,
      (canvas, y, _) {
        final left = (_s(receiptPaperWidth) - box) / 2;
        canvas.drawRect(
          Rect.fromLTWH(left, y, box, box),
          Paint()..color = Colors.white,
        );
        final painter = QrPainter.withQr(
          qr: qrCode,
          gapless: true,
          eyeStyle: const QrEyeStyle(
            eyeShape: QrEyeShape.square,
            color: Colors.black,
          ),
          dataModuleStyle: const QrDataModuleStyle(
            dataModuleShape: QrDataModuleShape.square,
            color: Colors.black,
          ),
        );
        canvas.save();
        final quiet = receiptQrQuietZone * receiptRenderScale;
        canvas.translate(left + quiet, y + quiet);
        painter.paint(canvas, Size(qrSide, qrSide));
        canvas.restore();
        return box;
      },
      isQr: true,
    );
  }

  final double _height;
  final bool isQr;
  final double Function(Canvas canvas, double y, double contentWidth) _paint;

  double height(double contentWidth) {
    if (_height > 0) {
      return _height;
    }
    return _measureHeight(contentWidth);
  }

  double paint(Canvas canvas, double y, double contentWidth) {
    return _paint(canvas, y, contentWidth);
  }

  double _measureHeight(double contentWidth) {
    final measureCanvas = Canvas(ui.PictureRecorder());
    return _paint(measureCanvas, 0, contentWidth);
  }
}

double _qrPixelPerfectSize(int moduleCount, double targetSize) {
  if (moduleCount <= 0) {
    return targetSize;
  }
  final modulePixels = (targetSize / moduleCount).floor().clamp(1, 64);
  return modulePixels * moduleCount.toDouble();
}
