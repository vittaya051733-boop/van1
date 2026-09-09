import 'package:flutter_test/flutter_test.dart';
import 'package:van1/data/merchant_security_deposit.dart';

void main() {
  test('security deposit default is 1000 baht when admin config missing', () {
    expect(MerchantSecurityDepositPolicy.defaultRequiredAmountBaht, 1000);
  });

  test('package includes printer, apron, and qr sign', () {
    final labels = MerchantSecurityDepositPolicy.packageBenefits
        .map((item) => item.label)
        .toList(growable: false);
    expect(labels, contains('เครื่องปริ้น'));
    expect(labels, contains('ผ้ากันเปื้อน'));
    expect(labels, contains('ป้ายคิวอาร์'));
  });
}
