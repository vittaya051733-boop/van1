import 'package:flutter/material.dart';

import 'data/merchant_security_deposit.dart';
import 'utils/app_colors.dart';

class MerchantSecurityDepositScreen extends StatelessWidget {
  const MerchantSecurityDepositScreen({
    super.key,
    required this.requiredAmountBaht,
  });

  final double requiredAmountBaht;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: AppColors.accent,
        foregroundColor: Colors.white,
        title: Text(MerchantSecurityDepositPolicy.title),
      ),
      body: SafeArea(
        child: Column(
          children: <Widget>[
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
                children: <Widget>[
                  Container(
                    padding: const EdgeInsets.all(18),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFFF7ED),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: const Color(0xFFFED7AA)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          'ค่าประกัน ${requiredAmountBaht.toStringAsFixed(0)} บาท',
                          style: const TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.w800,
                            color: Color(0xFF9A3412),
                          ),
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          'ก่อนอัปโหลดสินค้าครั้งแรก ร้านค้าต้องชำระค่าประกันและเติมเครดิตตามจำนวนด้านบน '
                          'เมื่อตรวจสลิปผ่านแล้วจึงเริ่มอัปโหลดสินค้าได้',
                          style: TextStyle(height: 1.5, color: Color(0xFF6B7280)),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                  const Text(
                    'แพ็กเกจที่ได้รับ',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 12),
                  ...MerchantSecurityDepositPolicy.packageBenefits.map(
                    (benefit) => _BenefitTile(benefit: benefit),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'หมายเหตุ: ยอดจะเข้าเป็นเครดิตในหน้ากระเป๋าเงิน '
                    'และยังถอนไม่ได้จนกว่าจะยกเลิกสัญญาร้าน',
                    style: TextStyle(fontSize: 13, color: Color(0xFF6B7280), height: 1.4),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  FilledButton(
                    onPressed: () => Navigator.of(context).pop(true),
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.accent,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    child: const Text('ตกลง — ไปเติมเครดิต'),
                  ),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(false),
                    child: const Text('ไว้ทีหลัง'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BenefitTile extends StatelessWidget {
  const _BenefitTile({required this.benefit});

  final MerchantSecurityDepositBenefit benefit;

  IconData _icon() {
    switch (benefit.iconName) {
      case 'print':
        return Icons.print_outlined;
      case 'qr':
        return Icons.qr_code_2_outlined;
      default:
        return Icons.inventory_2_outlined;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: const Color(0xFFFFEDD5),
          child: Icon(_icon(), color: AppColors.accent),
        ),
        title: Text(
          benefit.label,
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        subtitle: Text(benefit.description),
      ),
    );
  }
}
