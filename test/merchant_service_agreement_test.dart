import 'package:flutter_test/flutter_test.dart';
import 'package:van1/data/merchant_service_agreement.dart';

void main() {
  test('merchant agreement has 16 sections and no company wording', () {
    final text = MerchantServiceAgreement.buildTemplate(
      day: '27',
      monthName: 'มิถุนายน',
      monthNumber: '06',
      year: '2569',
    );

    expect(text, contains('ผู้ให้บริการแพลตฟอร์มแว๊นตลาด'));
    expect(text, isNot(contains('บริษัท')));
    expect(text, isNot(contains('จำกัด')));

    for (var i = 1; i <= 16; i++) {
      expect(text, contains('หมวดที่ $i :'));
    }

    expect(text, contains('สัญญาการให้บริการแพลตฟอร์ม แว๊นตลาด'));
  });

  test('sanitizeContractText removes legacy company signature block', () {
    const legacyFooter = '''
[หมายเหตุ: การลงลายมือชื่อในระบบ]

ลงชื่อ ____________________
(นายวิทยา ทนหงษา)
ผู้มีอำนาจลงนามฝ่ายบริษัท
วันที่ 29/11/2568
''';

    final sanitized = MerchantServiceAgreement.sanitizeContractText(legacyFooter);

    expect(sanitized, isNot(contains('วิทยา ทนหงษา')));
    expect(sanitized, isNot(contains('ผู้มีอำนาจลงนามฝ่ายบริษัท')));
    expect(sanitized, isNot(contains('29/11/2568')));
    expect(sanitized, contains('[หมายเหตุ: การลงลายมือชื่อในระบบ]'));
  });

  test('sanitizeContractText replaces legacy company legal name', () {
    const legacy = 'ระหว่าง (1) บริษัทแว๊นตลาดจำกัด กับ (2) ร้านค้า';
    final sanitized = MerchantServiceAgreement.sanitizeContractText(legacy);

    expect(sanitized, contains('ผู้ให้บริการแพลตฟอร์มแว๊นตลาด'));
    expect(sanitized, isNot(contains('บริษัท')));
    expect(sanitized, isNot(contains('จำกัด')));
  });

  test('applyContractDate refreshes contract header date', () {
    const legacy = 'สัญญาฉบับนี้ จัดทำขึ้น ณ วันที่ 29 เดือน พฤศจิกายน พ.ศ. 2568';
    final updated = MerchantServiceAgreement.applyContractDate(
      text: legacy,
      day: '6',
      monthName: 'กันยายน',
      year: '2569',
    );

    expect(updated, contains('วันที่ 6 เดือน กันยายน พ.ศ. 2569'));
    expect(updated, isNot(contains('29 เดือน พฤศจิกายน')));
  });
}
