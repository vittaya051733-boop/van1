class LegalDocument {
  const LegalDocument({
    required this.titleTh,
    required this.titleEn,
    required this.bodyTh,
    required this.bodyEn,
    required this.updatedAtLabel,
    this.publicUrl,
  });

  final String titleTh;
  final String titleEn;
  final String bodyTh;
  final String bodyEn;
  final String updatedAtLabel;
  final String? publicUrl;
}

class LegalContent {
  LegalContent._();

  static const privacyPolicy = LegalDocument(
    titleTh: 'นโยบายความเป็นส่วนตัว',
    titleEn: 'Privacy Policy',
    updatedAtLabel: '12 ก.ย. 2026',
    publicUrl: 'https://vantalad.web.app/merchant-privacy.html',
    bodyTh:
        '''แอป Van Market สำหรับร้านค้า (van1) เป็นส่วนหนึ่งของแพลตฟอร์ม VANTALAD

ข้อมูลที่เราเก็บ
• บัญชีร้านค้า (อีเมล, ชื่อ, รูปโปรไฟล์จาก Google)
• ข้อมูลร้าน ที่อยู่ เอกสารยืนยันตัวตน และรูปสินค้า/วิดีโอ
• ออเดอร์จากลูกค้า ประวัติการจัดส่ง และรายได้ร้าน
• ข้อความติดต่อแอดมินและรูปแนบ
• โทเคนแจ้งเตือน (FCM) เพื่อแจ้งออเดอร์ใหม่และสถานะงาน

การใช้ข้อมูล
• ให้บริการลงขายสินค้า รับออเดอร์ และจัดการร้าน
• ปรับปรุงความปลอดภัยและประสบการณ์ใช้งาน
• ไม่ขายข้อมูลส่วนบุคคลให้บุคคลที่สาม

การเก็บรักษา
• เก็บตามระยะเวลาที่จำเป็นต่อบริการและข้อกำหนดทางกฎหมาย

สิทธิของคุณ (PDPA)
• ขอเข้าถึงหรือแก้ไขข้อมูล — ติดต่อแอดมินผ่านแอป
• ลบบัญชีได้จากเมนู ตั้งค่าและบัญชี → ลบบัญชีถาวร
• หลังลบบัญชี ระบบจะลบบัญชีเข้าสู่ระบบ ปิดร้าน/สินค้า และลบข้อมูลส่วนตัวที่ไม่จำเป็น
• ประวัติออเดอร์ กระเป๋าเงิน สัญญา และข้อมูลธุรกรรมที่จำเป็นอาจยังถูกเก็บไว้เพื่อบัญชี ภาษี ความปลอดภัย และข้อพิพาท

ติดต่อ
• ใช้เมนู ตั้งค่า → ติดต่อแอดมิน''',
    bodyEn: '''Van Market merchant app (van1) is part of the VANTALAD platform.

Data we collect
• Shop account (email, name, Google profile photo)
• Shop profile, address, verification documents, product media
• Customer orders, delivery history, and shop earnings
• Admin support messages and attachments
• Push notification token (FCM)

How we use data
• To list products, receive orders, and manage your shop
• To improve security and user experience
• We do not sell personal data to third parties

Retention
• Kept as long as needed for service and legal requirements

Your rights (PDPA)
• Request access or correction via Contact admin
• Delete your account from Settings and account → Delete account permanently
• Account deletion removes your sign-in account, hides your shop/products, and deletes personal data that is no longer required
• Order history, wallet, contract, and transaction records may be retained as required for accounting, tax, safety, and dispute handling

Contact
• Settings → Contact admin''',
  );

  static const termsOfService = LegalDocument(
    titleTh: 'ข้อกำหนดการใช้บริการ',
    titleEn: 'Terms of Service',
    updatedAtLabel: '12 ก.ย. 2026',
    publicUrl: 'https://vantalad.web.app/merchant-terms.html',
    bodyTh: '''การใช้แอป Van Market สำหรับร้านค้า ถือว่าคุณยอมรับข้อกำหนดนี้

บัญชีร้านค้า
• คุณต้องให้ข้อมูลร้านที่ถูกต้องและรักษาความปลอดภัยบัญชี
• ร้านต้องผ่านการอนุมัติจากแอดมินก่อนเปิดขาย

การลงขายสินค้า
• สินค้าต้องถูกกฎหมาย ตรงตามที่แสดง และไม่ละเมิดนโยบายแพลตฟอร์ม
• ราคา ส่วนลด และข้อมูลจำเพาะเป็นความรับผิดชอบของร้าน
• แพลตฟอร์มอาจตรวจสอบสินค้าด้วย AI หรือแอดมิน

การรับออเดอร์และจัดส่ง
• ร้านต้องเตรียมสินค้าตามเวลาที่กำหนดและอัปเดตสถานะให้ถูกต้อง
• ค่าบริการ ค่าส่ง และรายได้ร้านเป็นไปตามนโยบายที่แอดมินกำหนด

การชำระเงินและรายได้
• รายได้ร้านคำนวณตามนโยบายแพลตฟอร์มและแสดงในกระเป๋าเงินร้าน
• การถอน/โอนเงินเป็นไปตามเงื่อนไขที่แอดมินกำหนด

พฤติกรรมต้องห้าม
• ขายสินค้าผิดกฎหมาย ฉ้อโกง หรือรบกวนลูกค้า/แพลตฟอร์ม

การระงับบริการ
• แพลตฟอร์มอาจระงับร้านที่ละเมิดข้อกำหนด''',
    bodyEn: '''By using the Van Market merchant app you agree to these terms.

Shop account
• Provide accurate shop information and keep your account secure
• Shops must be approved by admin before selling

Product listings
• Products must be legal, as described, and comply with platform policy
• Prices, discounts, and variants are the shop's responsibility
• Platform may review products via AI or admin

Orders & fulfillment
• Prepare orders on time and update status accurately
• Fees, delivery, and shop earnings follow admin-configured policy

Payments & earnings
• Earnings are calculated per platform policy and shown in shop wallet
• Withdrawals/transfers follow admin terms

Prohibited conduct
• Illegal products, fraud, or harassment

Suspension
• Shops violating terms may be suspended''',
  );
}
