import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'models/order_model.dart';
import 'services/order_qr_printer_service.dart';
import 'services/order_qr_receipt_layout.dart';
import 'utils/app_colors.dart';

export 'services/order_qr_printer_service.dart'
    show orderQrCodeText, printOrderQr;

String orderQrOrderCode(DetailedOrder order) {
  final code = order.orderCode?.trim();
  return code != null && code.isNotEmpty ? code : '';
}

class OrderQRScreen extends StatelessWidget {
  const OrderQRScreen({
    super.key,
    required this.order,
    this.voiceCommandBar,
  });

  final DetailedOrder order;
  final Widget? voiceCommandBar;

  String _qrPayload(String type) {
    if (type == 'VAN_ORDER') return orderQrCodeText(order);
    return '$type:${order.orderId}|${orderQrOrderCode(order)}|${order.totalAmount.toStringAsFixed(2)}';
  }

  @override
  Widget build(BuildContext context) {
    final universalQr = _qrPayload('VAN_ORDER');

    return Scaffold(
      appBar: AppBar(
        title: const Text('QR Code สำหรับไรเดอร์'),
        backgroundColor: AppColors.accent,
        foregroundColor: Colors.white,
      ),
      body: Column(
        children: <Widget>[
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  FilledButton.icon(
                    onPressed: () => printOrderQr(context, order),
                    icon: const Icon(Icons.print_outlined),
                    label: const Text('พิมพ์ QR พร้อมรายละเอียดออเดอร์'),
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.accent,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                  ),
                  const SizedBox(height: 16),
                  _QrPayloadCard(
                    title: 'QR เดียวสำหรับออเดอร์นี้',
                    subtitle: 'สแกน QR เดียวตามสถานะออเดอร์',
                    icon: Icons.qr_code_2_rounded,
                    color: AppColors.accent,
                    payload: universalQr,
                  ),
                  const SizedBox(height: 16),
                  _OrderQrDetails(order: order),
                ],
              ),
            ),
          ),
          if (voiceCommandBar != null) voiceCommandBar!,
        ],
      ),
    );
  }
}

class _QrPayloadCard extends StatelessWidget {
  const _QrPayloadCard({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.color,
    required this.payload,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final Color color;
  final String payload;

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 3,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          children: [
            Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: color.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(icon, color: color),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        style: const TextStyle(color: Color(0xFF64748B)),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 18),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFFE2E8F0), width: 2),
              ),
              child: QrImageView(
                data: payload,
                version: QrVersions.auto,
                size: 300,
                backgroundColor: Colors.white,
                eyeStyle: QrEyeStyle(eyeShape: QrEyeShape.square, color: color),
                dataModuleStyle: const QrDataModuleStyle(
                  dataModuleShape: QrDataModuleShape.square,
                  color: Colors.black87,
                ),
              ),
            ),
            const SizedBox(height: 12),
            SelectableText(
              payload,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 12,
                color: Color(0xFF475569),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _OrderQrDetails extends StatelessWidget {
  const _OrderQrDetails({required this.order});

  final DetailedOrder order;

  @override
  Widget build(BuildContext context) {
    final layout = buildOrderQrReceiptLayout(order);

    return Card(
      color: const Color(0xFFFFFBEB),
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'ข้อมูลที่ใช้ตรวจ QR',
              style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
            ),
            const SizedBox(height: 10),
            Text('Order ID: ${layout.orderId}'),
            Text('เลขออเดอร์: ${layout.orderCode.isEmpty ? '-' : layout.orderCode}'),
            Text('วันที่: ${layout.dateTimeText}'),
            const SizedBox(height: 8),
            const Text(
              'รายการสินค้า',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            ...layout.items.expand((item) {
              final rows = <Widget>[
                _AmountRow(
                  label: '${item.name} x${item.quantity}',
                  value: formatOrderQrMoney(item.lineTotal),
                ),
              ];
              final toppings = item.toppings;
              if (toppings != null) {
                rows.add(
                  Padding(
                    padding: const EdgeInsets.only(left: 8, top: 2, bottom: 2),
                    child: Text(
                      'ท็อปปิ้ง: $toppings',
                      style: TextStyle(fontSize: 13, color: Colors.grey[700]),
                    ),
                  ),
                );
              }
              return rows;
            }),
            const SizedBox(height: 6),
            _AmountRow(
              label: 'ค่าส่ง',
              value: formatOrderQrMoney(layout.shippingFee),
            ),
            _AmountRow(
              label: 'ยอดรวม',
              value: formatOrderQrMoney(layout.grandTotal),
              bold: true,
            ),
          ],
        ),
      ),
    );
  }
}

class _AmountRow extends StatelessWidget {
  const _AmountRow({
    required this.label,
    required this.value,
    this.bold = false,
  });

  final String label;
  final String value;
  final bool bold;

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(
      fontWeight: bold ? FontWeight.w800 : FontWeight.normal,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: Text(label, style: style)),
          const SizedBox(width: 8),
          Text(value, style: style),
        ],
      ),
    );
  }
}
