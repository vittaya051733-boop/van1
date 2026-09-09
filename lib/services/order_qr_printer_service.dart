import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:blue_thermal_printer/blue_thermal_printer.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../models/order_model.dart';
import '../widgets/merchant_print_options_sheet.dart';
import 'merchant_bluetooth_printer_service.dart';
import 'merchant_thermal_printer_service.dart';
import 'order_qr_receipt_bitmap.dart';
import 'order_qr_receipt_layout.dart';

const String orderQrReceiptTitle = 'แว๊นตลาด ORDER QR';

String orderQrCodeText(DetailedOrder order) {
  final code = order.orderCode?.trim();
  final orderCode = code != null && code.isNotEmpty ? code : '';
  return 'VAN_ORDER:${order.orderId}|$orderCode|${order.totalAmount.toStringAsFixed(2)}';
}

/// Use the exact same payload shown on the rider QR screen.
String orderQrPrintPayload(DetailedOrder order) {
  return orderQrCodeText(order);
}

Future<void> printOrderQr(BuildContext context, DetailedOrder order) async {
  final printQr = orderQrPrintPayload(order);
  final receiptLayout = buildOrderQrReceiptLayout(order);
  ScaffoldMessengerState? progressMessenger;

  try {
    final receipt = await buildOrderQrReceiptPngBytes(
      qrPayload: printQr,
      layout: receiptLayout,
      receiptTitle: orderQrReceiptTitle,
    );

    if (!context.mounted) return;
    final savedBleReady = Platform.isIOS &&
        await MerchantThermalPrinterService.instance.hasBlePrinterReady();
    final MerchantPrintChannel? channel = savedBleReady
        ? MerchantPrintChannel.bluetoothBle
        : await showMerchantPrintOptionsSheet(context);
    if (channel == null || !context.mounted) return;

    progressMessenger = ScaffoldMessenger.of(context);
    final bleReady = savedBleReady ||
        (channel == MerchantPrintChannel.bluetoothBle &&
            await MerchantThermalPrinterService.instance.hasBlePrinterReady());
    progressMessenger.showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 30),
        content: Row(
          children: <Widget>[
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Colors.white,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                bleReady
                    ? 'กำลังพิมพ์...'
                    : channel == MerchantPrintChannel.bluetoothBle
                        ? 'กำลังเชื่อมต่อเครื่องพิมพ์...'
                        : 'กำลังค้นหาและเชื่อมต่อเครื่องพิมพ์...',
              ),
            ),
          ],
        ),
      ),
    );

    switch (channel) {
      case MerchantPrintChannel.bluetoothClassic:
        await _printReceiptViaBluetooth(context, receipt.pngBytes);
      case MerchantPrintChannel.bluetoothBle:
        await MerchantThermalPrinterService.instance.printViaBle(
          context,
          receipt.pngBytes,
        );
      case MerchantPrintChannel.wifi:
        await MerchantThermalPrinterService.instance.printViaWifi(
          context,
          receipt.pngBytes,
        );
      case MerchantPrintChannel.usb:
        await MerchantThermalPrinterService.instance.printViaUsb(
          context,
          receipt.pngBytes,
        );
      case MerchantPrintChannel.system:
        await _printReceiptViaSystemPrint(context, receipt.pngBytes);
    }
  } on PrinterUserException catch (error) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error.message)),
      );
    }
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('เกิดข้อผิดพลาด: $e')),
      );
    }
  } finally {
    if (progressMessenger?.mounted ?? false) {
      progressMessenger!.hideCurrentSnackBar();
    }
  }
}

Future<void> _printReceiptViaBluetooth(
  BuildContext context,
  Uint8List receiptPng,
) async {
  final printerService = MerchantBluetoothPrinterService.instance;
  final device = await printerService.resolvePrinterDevice(context);
  await printerService.connect(device);
  final printer = printerService.printer;

  await printer.printImageBytes(receiptPng);
  await _feedLines(printer, receiptTrailingBlankLines);
  await printer.paperCut();

  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('พิมพ์ QR และรายละเอียดออเดอร์แล้ว')),
    );
  }
}

Future<void> _printReceiptViaSystemPrint(
  BuildContext context,
  Uint8List receiptPng,
) async {
  await Printing.layoutPdf(
    name: 'van_order_qr_receipt.pdf',
    format: _receiptPageFormat(receiptPng),
    onLayout: (_) => _buildReceiptPdfBytes(receiptPng),
  );

  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'เปิดหน้าพิมพ์แล้ว — เลือกเครื่องพิมพ์ AirPrint หรือบันทึก PDF',
        ),
      ),
    );
  }
}

PdfPageFormat _receiptPageFormat(Uint8List receiptPng) {
  final decoded = img.decodePng(receiptPng);
  final pageWidth = 58 * PdfPageFormat.mm;
  if (decoded == null || decoded.width <= 0) {
    return PdfPageFormat(pageWidth, pageWidth * 2, marginAll: 0);
  }
  final pageHeight = pageWidth * decoded.height / decoded.width;
  return PdfPageFormat(pageWidth, pageHeight, marginAll: 0);
}

Future<Uint8List> _buildReceiptPdfBytes(Uint8List receiptPng) async {
  final format = _receiptPageFormat(receiptPng);
  final doc = pw.Document();
  doc.addPage(
    pw.Page(
      pageFormat: format,
      margin: pw.EdgeInsets.zero,
      build: (context) => pw.Image(
        pw.MemoryImage(receiptPng),
        fit: pw.BoxFit.fill,
      ),
    ),
  );
  return doc.save();
}

Future<void> _feedLines(BlueThermalPrinter printer, int count) async {
  for (var i = 0; i < count; i++) {
    await printer.printNewLine();
  }
}
