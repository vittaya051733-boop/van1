abstract final class MerchantSecurityDepositPolicy {
  /// Fallback when `platform_config/merchant` is missing (admin can override).
  static const double defaultRequiredAmountBaht = 1000;

  @Deprecated('Use MerchantSecurityDepositService.getRequiredAmountBaht()')
  static const double requiredAmountBaht = defaultRequiredAmountBaht;

  static const String title = 'ค่าประกันเปิดร้าน';

  static const List<MerchantSecurityDepositBenefit> packageBenefits =
      <MerchantSecurityDepositBenefit>[
    MerchantSecurityDepositBenefit(
      iconName: 'print',
      label: 'เครื่องปริ้น',
      description: 'สำหรับพิมพ์ใบเสร็จ/ใบสั่งซื้อในร้าน',
    ),
    MerchantSecurityDepositBenefit(
      iconName: 'shield',
      label: 'ผ้ากันเปื้อน',
      description: 'อุปกรณ์ใช้งานประจำร้านตามแพ็กเกจ',
    ),
    MerchantSecurityDepositBenefit(
      iconName: 'qr',
      label: 'ป้ายคิวอาร์',
      description: 'ป้าย QR สำหรับร้านค้า VANTALAD',
    ),
  ];
}

class MerchantSecurityDepositBenefit {
  const MerchantSecurityDepositBenefit({
    required this.iconName,
    required this.label,
    required this.description,
  });

  final String iconName;
  final String label;
  final String description;
}
