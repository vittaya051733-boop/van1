import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'map_picker_screen.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img; // เพิ่ม: สำหรับแปลงรูปภาพ
import 'utils/app_colors.dart';
import 'utils/shop_profile_resolver.dart';
import 'services/shop_profile_fetcher.dart';
import 'services/branch_assignment_service.dart';
import 'services/promptpay_qr_payload.dart';
import 'storage_helper.dart';
import 'widgets/cached_app_image.dart';

class ShopRegistrationScreen extends StatefulWidget {
  final String? serviceType;
  final DocumentSnapshot? shopData; // optional: existing shop doc to edit
  final Map<String, dynamic>?
  prefilledData; // optional: cached/normalized map for offline mode

  const ShopRegistrationScreen({
    super.key,
    this.serviceType,
    this.shopData,
    this.prefilledData,
  });

  @override
  State<ShopRegistrationScreen> createState() => _ShopRegistrationScreenState();
}

class _ShopRegistrationScreenState extends State<ShopRegistrationScreen> {
  static const Duration _firestoreTimeout = Duration(seconds: 12);
  static const List<String> _nameKeys = <String>[
    'shopName',
    'name',
    'displayName',
    'businessName',
    'storeName',
    'brandName',
    'title',
  ];
  static const List<String> _descriptionKeys = <String>[
    'description',
    'shopDescription',
    'detail',
    'summary',
    'about',
  ];
  static const List<String> _addressKeys = <String>[
    'address',
    'shopAddress',
    'addressLine',
    'locationText',
  ];
  static const List<String> _phoneKeys = <String>[
    'phone',
    'phoneNumber',
    'contactPhone',
    'mobile',
    'tel',
  ];
  static const List<String> _emailKeys = <String>['email', 'contactEmail'];
  static const List<String> _bankNameKeys = <String>[
    'bankName',
    'bank',
    'bankname',
    'financialInstitution',
  ];
  static const List<String> _accountNumberKeys = <String>[
    'accountNumber',
    'bankAccountNumber',
    'accountNo',
    'acctNumber',
  ];
  static const List<String> _accountOwnerKeys = <String>[
    'accountOwner',
    'accountName',
    'ownerName',
    'accountHolder',
    'accountHolderName',
  ];
  static const List<String> _serviceTypeKeys = <String>[
    'serviceType',
    'service_type',
    'category',
    'type',
  ];
  static const List<String> _bookBankImageKeys = <String>[
    'bookBankImageUrl',
    'bankBookImageUrl',
    'bookBankImage',
    'passbookImageUrl',
  ];

  final _formKey = GlobalKey<FormState>();
  AutovalidateMode _autoValidateMode = AutovalidateMode.disabled;
  final _shopNameController = TextEditingController();
  final _shopDescriptionController = TextEditingController();
  final _addressController = TextEditingController();
  final _phoneController = TextEditingController();
  final _emailController = TextEditingController();

  // ข้อมูลสมุดบัญชีธนาคาร
  final _bankNameController = TextEditingController();
  final _accountNumberController = TextEditingController();
  final _accountOwnerController = TextEditingController();
  final _promptPayPhoneController = TextEditingController();
  final _promptPayNationalIdController = TextEditingController();

  // รายชื่อธนาคารในประเทศไทยสำหรับตัวเลือก
  static const List<String> _thaiBanks = <String>[
    'ธนาคารกรุงเทพ (BBL)',
    'ธนาคารกสิกรไทย (KBank)',
    'ธนาคารไทยพาณิชย์ (SCB)',
    'ธนาคารกรุงไทย (KTB)',
    'ธนาคารกรุงศรีอยุธยา (BAY)',
    'ทีเอ็มบีธนชาต (TTB)',
    'ธนาคารยูโอบี (UOB)',
    'ธนาคารซีไอเอ็มบีไทย (CIMB)',
    'ธนาคารเกียรตินาคินภัทร (KKP)',
    'ธนาคารทิสโก้ (TISCO)',
    'ธนาคารแลนด์แอนด์เฮ้าส์ (LH Bank)',
    'ธนาคารออมสิน',
    'ธ.ก.ส. (ธนาคารเพื่อการเกษตรและสหกรณ์การเกษตร)',
    'อื่นๆ',
  ];

  File? _selectedImage;
  bool _isSaving = false;
  String? _existingShopImageUrl;

  File? _selectedBookBankImage;
  bool _isUploadingBookBank = false;
  String? _existingBookBankImageUrl;
  bool _isCheckingExisting = true;
  String? _resolvedServiceType;
  bool _hasAttemptedRemotePrefill = false;

  static const double _bookBankMinSharpnessStdDev = 20;

  // พิกัด GPS
  double? _latitude;
  double? _longitude;

  @override
  void initState() {
    super.initState();
    _loadUserEmail();
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _initRegistrationStatus(),
    );
    _prefillIfEditing();
    Future.microtask(_ensureShopProfileLoaded);
  }

  void _prefillIfEditing() {
    final Map<String, dynamic> merged = <String, dynamic>{};
    if (widget.prefilledData != null && widget.prefilledData!.isNotEmpty) {
      merged.addAll(_stringKeyedMap(widget.prefilledData!));
    }
    if (widget.shopData != null && widget.shopData!.exists) {
      final data = widget.shopData!.data() as Map<String, dynamic>?;
      if (data != null) {
        merged.addAll(_stringKeyedMap(data));
      }
    }
    if (merged.isEmpty) return;
    _hydrateFromMap(merged);
    _isCheckingExisting = false; // ready to edit with prefilled data
  }

  Future<void> _ensureShopProfileLoaded() async {
    if (_hasAttemptedRemotePrefill) return;
    if (_shopNameController.text.trim().isNotEmpty ||
        _phoneController.text.trim().isNotEmpty ||
        _addressController.text.trim().isNotEmpty) {
      return;
    }

    _hasAttemptedRemotePrefill = true;
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final ShopProfileFetchResult? result = await ShopProfileFetcher.findByUser(
      user.uid,
      email: user.email,
    );

    if (result == null) {
      return;
    }

    final Map<String, dynamic> merged = Map<String, dynamic>.from(result.data)
      ..['_collection'] = result.collection;
    _hydrateFromMap(merged);
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _initRegistrationStatus() async {
    // ถ้าเป็นโหมดแก้ไข (มี shopData) ให้ข้ามการ redirect
    if ((widget.shopData != null && widget.shopData!.exists) ||
        (widget.prefilledData != null && widget.prefilledData!.isNotEmpty)) {
      if (mounted) setState(() => _isCheckingExisting = false);
      return;
    }
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      if (mounted) setState(() => _isCheckingExisting = false);
      return;
    }

    String? serviceType = widget.serviceType;
    if (serviceType == null) {
      try {
        final snapshot = await FirebaseFirestore.instance
            .collection('contracts')
            .doc(user.uid)
            .get()
            .timeout(_firestoreTimeout);
        serviceType = (snapshot.data()?['serviceType'] as String?)?.trim();
      } on TimeoutException {
        debugPrint('Timed out loading serviceType from contracts');
      } catch (e) {
        debugPrint('Failed to load serviceType: $e');
      }
    }

    if (mounted) {
      _resolvedServiceType = serviceType;
    }

    if (serviceType == null) {
      if (mounted) setState(() => _isCheckingExisting = false);
      return;
    }

    try {
      final collection = _collectionForService(serviceType);
      final doc = await FirebaseFirestore.instance
          .collection(collection)
          .doc(user.uid)
          .get()
          .timeout(_firestoreTimeout);
      if (doc.exists) {
        final Map<String, dynamic>? data = doc.data();
        final alreadyComplete = _hasCompletedProfile(data);
        // ถ้าลงทะเบียนครบแล้ว และไม่ได้อยู่ในโหมดแก้ไข ให้กลับหน้า Home
        if (alreadyComplete && widget.shopData == null) {
          if (!mounted) return;
          _navigateHome();
          return;
        }
      }
    } on TimeoutException {
      debugPrint('Timed out checking existing registration');
    } catch (e) {
      debugPrint('Failed to check existing registration: $e');
    }

    if (mounted) setState(() => _isCheckingExisting = false);
  }

  Future<void> _loadUserEmail() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user != null && user.email != null) {
      setState(() {
        _emailController.text = user.email!;
      });
    }
  }

  void _navigateHome() {
    if (!mounted) return;
    Navigator.of(context).pushNamedAndRemoveUntil('/home', (route) => false);
  }

  String _collectionForService(String serviceType) {
    final normalized = serviceType.trim().toLowerCase();
    switch (normalized) {
      case 'ตลาด':
      case 'market':
        return 'market_registrations';
      case 'ร้านค้า':
      case 'shop':
      case 'store':
        return 'shop_registrations';
      case 'ร้านอาหาร':
      case 'restaurant':
      case 'food':
        return 'restaurant_registrations';
      case 'ร้านขายยา':
      case 'pharmacy':
        return 'pharmacy_registrations';
      case 'อื่นๆ':
      case 'อื่น':
      case 'other':
      case 'others':
        return 'other_registrations';
      default:
        throw Exception('ประเภทบริการไม่ถูกต้อง: $serviceType');
    }
  }

  bool _hasCompletedProfile(Map<String, dynamic>? data) {
    if (data == null) return false;
    final completedFlag = data['isProfileCompleted'];
    if (completedFlag is bool && completedFlag) {
      return true;
    }

    final status = (data['status'] as String?)?.toLowerCase();
    if (status == null || status == 'pending_contract') {
      return false;
    }

    final hasCoreDetails =
        (data['name']?.toString().isNotEmpty ?? false) &&
        (data['address']?.toString().isNotEmpty ?? false) &&
        (data['shopImageUrl']?.toString().isNotEmpty ?? false) &&
        (data['bankName']?.toString().isNotEmpty ?? false);

    return hasCoreDetails;
  }

  @override
  void dispose() {
    _shopNameController.dispose();
    _shopDescriptionController.dispose();
    _addressController.dispose();
    _phoneController.dispose();
    _emailController.dispose();
    _bankNameController.dispose();
    _accountNumberController.dispose();
    _accountOwnerController.dispose();
    _promptPayPhoneController.dispose();
    _promptPayNationalIdController.dispose();
    super.dispose();
  }

  Future<void> _pickImage() async {
    // ลบโค้ดขอ permission ออก (ใช้ ImagePicker ตามปกติ)
    final ImagePicker picker = ImagePicker();
    final XFile? image = await picker.pickImage(
      source: ImageSource.gallery,
      maxWidth: 1200,
      maxHeight: 1200,
      imageQuality: 85,
    );
    if (image != null) {
      setState(() {
        _selectedImage = File(image.path);
      });
    }
  }

  Future<bool> _isBookBankImageBlurry(File imageFile) async {
    final bytes = await imageFile.readAsBytes();
    final image = img.decodeImage(bytes);
    if (image == null) return true;

    final grayscale = img.grayscale(image);
    final pixels = grayscale.getBytes();
    if (pixels.isEmpty) return true;

    final mean = pixels.reduce((a, b) => a + b) / pixels.length;
    final variance =
        pixels.map((p) => (p - mean) * (p - mean)).reduce((a, b) => a + b) /
        pixels.length;
    final stddev = math.sqrt(variance);
    return stddev < _bookBankMinSharpnessStdDev;
  }

  Future<void> _pickBookBankImage() async {
    final ImagePicker picker = ImagePicker();
    final XFile? image = await picker.pickImage(
      source: ImageSource.gallery,
      maxWidth: 1400,
      maxHeight: 1400,
      imageQuality: 90,
    );
    if (image == null) return;

    setState(() {
      _selectedBookBankImage = File(image.path);
      _isUploadingBookBank = true;
    });

    try {
      final blurry = await _isBookBankImageBlurry(_selectedBookBankImage!);
      if (blurry) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).clearSnackBars();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('❌ ภาพเบลอหรือไม่ชัด กรุณาเลือกรูปใหม่'),
            backgroundColor: Colors.red,
          ),
        );
        setState(() {
          _selectedBookBankImage = null;
        });
        return;
      }

      if (!mounted) return;
      ScaffoldMessenger.of(context).clearSnackBars();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('✅ รูปภาพสมุดบัญชีผ่านการตรวจสอบความชัดเจน'),
          backgroundColor: Colors.green,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).clearSnackBars();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('❌ เกิดข้อผิดพลาดในการตรวจสอบรูปภาพ'),
          backgroundColor: Colors.red,
        ),
      );
      setState(() {
        _selectedBookBankImage = null;
      });
    } finally {
      if (mounted) {
        setState(() {
          _isUploadingBookBank = false;
        });
      }
    }
  }

  Future<void> _pickLocationFromMap() async {
    final result = await Navigator.of(context).push<Map<String, double>>(
      MaterialPageRoute(
        builder: (context) => MapPickerScreen(
          initialLatitude: _latitude,
          initialLongitude: _longitude,
        ),
      ),
    );

    if (result != null) {
      setState(() {
        _latitude = result['latitude'];
        _longitude = result['longitude'];
      });

      _showSnackBar('✅ ปักหมุดตำแหน่งสำเร็จ!', Colors.green);
    }
  }

  Future<void> _saveShopRegistration() async {
    // เปิดโหมดแสดงข้อผิดพลาดในฟอร์ม
    setState(() {
      _autoValidateMode = AutovalidateMode.always;
    });

    // 1. ตรวจสอบ FormFields ทั้งหมดด้วย validator
    final formIsValid = _formKey.currentState?.validate() ?? false;

    // 2. รวบรวมข้อผิดพลาดทั้งหมดจาก FormFields
    final allErrors = _validateFields();
    if (!formIsValid || allErrors.isNotEmpty) {
      _showValidationDialog(allErrors);
      return; // หยุดการทำงานถ้ามีข้อผิดพลาด
    }

    setState(() => _isSaving = true);

    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) throw Exception('ไม่พบข้อมูลผู้ใช้');
      final serviceType = _resolvedServiceType ?? widget.serviceType;
      if (serviceType == null) throw Exception('ประเภทบริการไม่ถูกต้อง');

      // เตรียมรูปภาพ: ถ้าไม่อัปโหลดใหม่ ให้ใช้ของเดิม
      String? shopImageUrl = _existingShopImageUrl;
      String? bookBankImageUrl = _existingBookBankImageUrl;

      // อัปโหลดไฟล์ใหม่ถ้ามี และลบไฟล์เก่าใน Storage
      if (_selectedImage != null) {
        final newUrl = await _uploadImage();
        if (newUrl == null) throw Exception('อัปโหลดรูปร้านค้าล้มเหลว');
        final oldUrl = _existingShopImageUrl;
        shopImageUrl = newUrl;
        if (oldUrl != null && oldUrl.isNotEmpty && oldUrl != newUrl) {
          _deleteOldStorageFile(oldUrl);
        }
      }

      if (_selectedBookBankImage != null) {
        final newUrl = await _uploadBookBankImage();
        if (newUrl == null) throw Exception('อัปโหลดรูปสมุดบัญชีล้มเหลว');
        final oldUrl = _existingBookBankImageUrl;
        bookBankImageUrl = newUrl;
        if (oldUrl != null && oldUrl.isNotEmpty && oldUrl != newUrl) {
          _deleteOldStorageFile(oldUrl);
        }
      }

      final collection = _collectionForService(serviceType);
      final orderNumber = DateTime.now().millisecondsSinceEpoch;
      final shopLatitude = _latitude ?? 0.0;
      final shopLongitude = _longitude ?? 0.0;
      final branchAssignment =
          await BranchAssignmentService.resolveForCoordinates(
            latitude: shopLatitude,
            longitude: shopLongitude,
          );

      // บันทึกข้อมูลร้านค้าลง Firestore (แต่ละประเภทเป็น Collection แยก)
      await FirebaseFirestore.instance.collection(collection).doc(user.uid).set(
        {
          'name': _shopNameController.text.trim(),
          'serviceType': serviceType, // ใช้ field นี้เป็นหลัก
          'rating': 0.0, // เริ่มต้นที่ 0 รอรีวิว
          'location': {'latitude': shopLatitude, 'longitude': shopLongitude},
          ...branchAssignment.toFirestoreFields(),
          'ownerId': user.uid,
          'order': orderNumber, // ลำดับที่ของร้านในประเภทนี้
          'description': _shopDescriptionController.text.trim(),
          'address': _addressController.text.trim(), // ใช้ที่อยู่ที่กรอกเอง
          'phone': _phoneController.text.trim(),
          'email': _emailController.text.trim(),
          'shopImageUrl': shopImageUrl,
          'bookBankImageUrl': bookBankImageUrl,
          'bankName': _bankNameController.text.trim(),
          'accountNumber': _accountNumberController.text.trim(),
          'accountOwner': _accountOwnerController.text.trim(),
          if (_promptPayPhoneController.text.trim().isNotEmpty)
            'promptPayPhoneNumber':
                _promptPayPhoneController.text.replaceAll(RegExp(r'\D'), ''),
          if (_promptPayNationalIdController.text.trim().isNotEmpty)
            'promptPayNationalId':
                _promptPayNationalIdController.text.replaceAll(RegExp(r'\D'), ''),
          'status': 'pending', // รอการอนุมัติ
          'isProfileCompleted': true,
          'createdAt': FieldValue.serverTimestamp(),
        },
        SetOptions(merge: true),
      );

      await _upsertPublicShopProfile(
        ownerUid: user.uid,
        shopName: _shopNameController.text.trim(),
        shopImageUrl: shopImageUrl,
        latitude: _latitude ?? 0.0,
        longitude: _longitude ?? 0.0,
        branchAssignment: branchAssignment,
        serviceType: serviceType,
        address: _addressController.text.trim(),
        phone: _phoneController.text.trim(),
        email: _emailController.text.trim(),
      );

      await FirebaseFirestore.instance
          .collection('contracts')
          .doc(user.uid)
          .set(branchAssignment.toFirestoreFields(), SetOptions(merge: true));

      final contactEmail = _emailController.text.trim();
      if (contactEmail.isNotEmpty) {
        await FirebaseFirestore.instance.collection('users').doc(user.uid).set(
          {
            'email': contactEmail,
            'contactEmail': contactEmail,
          },
          SetOptions(merge: true),
        );
      }

      _showSnackBar('✅ ลงทะเบียนร้านค้าสำเร็จ!', Colors.green);

      await Future.delayed(const Duration(seconds: 1));

      _navigateHome();
    } catch (e) {
      _showSnackBar('❌ เกิดข้อผิดพลาด: $e', Colors.red);
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }

  Future<void> _deleteOldStorageFile(String url) async {
    try {
      final ref = StorageHelper.instance.refFromURL(url);
      await ref.delete();
    } catch (e) {
      debugPrint('Skip delete old file: $e');
    }
  }

  Future<void> _upsertPublicShopProfile({
    required String ownerUid,
    required String shopName,
    String? shopImageUrl,
    required double latitude,
    required double longitude,
    required BranchAssignment branchAssignment,
    required String serviceType,
    String? address,
    String? phone,
    String? email,
  }) async {
    final normalizedShopName = shopName.trim();
    final normalizedShopImageUrl = shopImageUrl?.trim();
    final normalizedAddress = address?.trim();
    final normalizedPhone = phone?.trim();
    final normalizedEmail = email?.trim();
    final normalizedServiceType = serviceType.trim();

    final publicData = <String, dynamic>{
      'ownerUid': ownerUid,
      'ownerId': ownerUid,
      'shopName': normalizedShopName,
      'name': normalizedShopName,
      'serviceType': normalizedServiceType,
      'location': <String, double>{
        'latitude': latitude,
        'longitude': longitude,
      },
      'shopLocation': <String, double>{
        'latitude': latitude,
        'longitude': longitude,
      },
      'shopLatitude': latitude,
      'shopLongitude': longitude,
      'adminMaxImageCount': 1,
      'adminCanUploadVideo': false,
      ...branchAssignment.toFirestoreFields(),
      'updatedAt': FieldValue.serverTimestamp(),
    };

    if (normalizedShopImageUrl != null && normalizedShopImageUrl.isNotEmpty) {
      publicData['shopImageUrl'] = normalizedShopImageUrl;
    }
    if (normalizedAddress != null && normalizedAddress.isNotEmpty) {
      publicData['address'] = normalizedAddress;
      publicData['shopAddress'] = normalizedAddress;
    }
    if (normalizedPhone != null && normalizedPhone.isNotEmpty) {
      publicData['phone'] = normalizedPhone;
      publicData['shopPhone'] = normalizedPhone;
    }
    if (normalizedEmail != null && normalizedEmail.isNotEmpty) {
      publicData['email'] = normalizedEmail;
    }

    await FirebaseFirestore.instance
        .collection('public_shops')
        .doc(ownerUid)
        .set(publicData, SetOptions(merge: true));
  }

  // ตรวจสอบอีเมลรูปแบบทั่วไป
  bool _isValidEmail(String email) {
    final regex = RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$');
    return regex.hasMatch(email);
  }

  // ตรวจสอบเบอร์โทรแบบไทย: รองรับ 0XXXXXXXXX (10 หลัก) หรือ +66XXXXXXXXX/66XXXXXXXXX (11 หลัก)
  bool _isValidThaiPhone(String input) {
    final digits = input.replaceAll(RegExp(r'\D'), '');
    if (digits.startsWith('0')) {
      return digits.length == 10;
    }
    if (digits.startsWith('66')) {
      return digits.length == 11; // 66 + 9 หลักที่เหลือ
    }
    return false;
  }

  // รวมตรวจสอบทุกช่องที่จำเป็น และคืนรายการข้อความผิดพลาด
  List<String> _validateFields() {
    final errors = <String>[];

    final name = _shopNameController.text.trim();
    final phone = _phoneController.text.trim();
    final email = _emailController.text.trim();

    if (name.isEmpty || name.length < 2) {
      errors.add('• ชื่อร้านค้า: กรุณากรอกอย่างน้อย 2 ตัวอักษร');
    }
    if (_latitude == null || _longitude == null) {
      errors.add('• ที่อยู่: กรุณาปักหมุดตำแหน่งร้านค้าบนแผนที่');
    }
    if (phone.isEmpty || !_isValidThaiPhone(phone)) {
      errors.add(
        '• เบอร์โทรศัพท์: รูปแบบไม่ถูกต้อง (เช่น 0812345678 หรือ +66812345678)',
      );
    }
    if (email.isEmpty || !_isValidEmail(email)) {
      errors.add('• อีเมล: รูปแบบไม่ถูกต้อง');
    }

    final promptPayError = PromptPayQrPayload.validatePayoutProfile(
      phone: _promptPayPhoneController.text,
      nationalId: _promptPayNationalIdController.text,
    );
    if (promptPayError != null) {
      errors.add('• PromptPay: $promptPayError');
    }

    // หมายเหตุ: คำอธิบายร้าน ไม่บังคับ ตามที่ผู้ใช้ระบุ
    // สมุดบัญชีธนาคาร: อนุญาตให้เว้นได้ (ไม่บังคับ)

    return errors;
  }

  void _showSnackBar(String message, Color color) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: color,
        duration: const Duration(seconds: 3),
      ),
    );
  }

  void _showValidationDialog(List<String> errors) {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('กรุณากรอกข้อมูลให้ครบถ้วน'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: errors.map((e) => Text(e)).toList(),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('ตกลง'),
            ),
          ],
        );
      },
    );
  }

  // เพิ่มฟังก์ชัน _uploadImage ที่หายไป เพื่อให้อัปโหลดรูปร้านค้าได้
  Future<String?> _uploadImage() async {
    if (_selectedImage == null) {
      debugPrint('❌ _selectedImage is null');
      return null;
    }
    if (!await _selectedImage!.exists()) {
      debugPrint(
        '❌ _selectedImage file does not exist: ${_selectedImage!.path}',
      );
      return null;
    }
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) throw Exception('ไม่พบข้อมูลผู้ใช้');
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final fileName = 'contracts/${user.uid}/shop_images/$timestamp.png';
      final storageRef = StorageHelper.instance.ref().child(fileName);

      final bytes = await _selectedImage!.readAsBytes();
      debugPrint('✅ Read shop image bytes: ${bytes.length}');
      final image = img.decodeImage(bytes);
      if (image == null) {
        debugPrint('❌ Could not decode shop image.');
        throw Exception('ไม่สามารถอ่านข้อมูลรูปภาพร้านค้าได้ (ไฟล์อาจเสียหาย)');
      }
      final pngBytes = img.encodePng(image);

      final uploadTask = await storageRef.putData(
        Uint8List.fromList(pngBytes),
        SettableMetadata(contentType: 'image/png'),
      );
      final downloadUrl = await uploadTask.ref.getDownloadURL();
      debugPrint('✅ Uploaded shop image: $downloadUrl');
      return downloadUrl;
    } catch (e) {
      debugPrint('❌ อัปโหลดรูปร้านค้าล้มเหลว: $e');
      throw Exception('อัปโหลดรูปร้านค้าล้มเหลว: $e');
    }
  }

  void _hydrateFromMap(Map<String, dynamic> rawData) {
    final Map<String, dynamic> data = _stringKeyedMap(rawData);

    final String? shopName =
        ShopProfileResolver.resolveName(data) ??
        _resolveStringField(data, _nameKeys);
    _setTextIfEmpty(_shopNameController, shopName);

    final String? description = _resolveStringField(data, _descriptionKeys);
    _setTextIfEmpty(_shopDescriptionController, description);

    final String? address = _resolveStringField(data, _addressKeys);
    _setTextIfEmpty(_addressController, address);

    final String? phone = _resolveStringField(data, _phoneKeys);
    _setTextIfEmpty(_phoneController, phone);

    final String? email = _resolveStringField(data, _emailKeys);
    _setTextIfEmpty(_emailController, email);

    final String? bankName = _resolveStringField(data, _bankNameKeys);
    _setTextIfEmpty(_bankNameController, bankName);

    final String? accountNumber = _resolveStringField(data, _accountNumberKeys);
    _setTextIfEmpty(_accountNumberController, accountNumber);

    final String? accountOwner = _resolveStringField(data, _accountOwnerKeys);
    _setTextIfEmpty(_accountOwnerController, accountOwner);

    _setTextIfEmpty(
      _promptPayPhoneController,
      data['promptPayPhoneNumber']?.toString(),
    );
    _setTextIfEmpty(
      _promptPayNationalIdController,
      data['promptPayNationalId']?.toString() ??
          data['promptPayNationalIdOrTaxId']?.toString(),
    );

    final String? shopImageUrl = ShopProfileResolver.resolveImageUrl(data);
    if (shopImageUrl != null &&
        shopImageUrl.isNotEmpty &&
        _existingShopImageUrl == null) {
      _existingShopImageUrl = shopImageUrl;
    }

    final String? bookBankImage = _resolveStringField(data, _bookBankImageKeys);
    if (bookBankImage != null &&
        bookBankImage.isNotEmpty &&
        _existingBookBankImageUrl == null) {
      _existingBookBankImageUrl = bookBankImage;
    }

    final String? serviceType = _resolveStringField(data, _serviceTypeKeys);
    if (serviceType != null) {
      _resolvedServiceType = serviceType;
    }

    _applyLocationFromData(data);
  }

  void _applyLocationFromData(Map<String, dynamic> data) {
    final dynamic locationValue =
        data['location'] ??
        data['coordinates'] ??
        data['geo'] ??
        data['position'] ??
        data['shopLocation'];
    if (_tryApplyLocation(locationValue)) {
      return;
    }

    final String? latString = _resolveStringField(data, const <String>[
      'lat',
      'latitude',
      'y',
    ]);
    final String? lngString = _resolveStringField(data, const <String>[
      'lng',
      'long',
      'longitude',
      'x',
    ]);
    final double? lat = latString != null ? double.tryParse(latString) : null;
    final double? lng = lngString != null ? double.tryParse(lngString) : null;
    if (lat != null && lng != null) {
      _latitude = lat;
      _longitude = lng;
    }
  }

  bool _tryApplyLocation(dynamic value) {
    if (value == null) return false;
    if (value is GeoPoint) {
      _latitude = value.latitude;
      _longitude = value.longitude;
      return true;
    }
    if (value is Map) {
      final Map<String, dynamic> map = _stringKeyedMap(value);
      final double? lat = _parseDouble(
        map['latitude'] ?? map['lat'] ?? map['y'],
      );
      final double? lng = _parseDouble(
        map['longitude'] ?? map['lng'] ?? map['long'] ?? map['x'],
      );
      if (lat != null && lng != null) {
        _latitude = lat;
        _longitude = lng;
        return true;
      }
    }
    return false;
  }

  double? _parseDouble(dynamic value) {
    if (value == null) return null;
    if (value is num) {
      return value.toDouble();
    }
    if (value is String) {
      return double.tryParse(value);
    }
    return null;
  }

  String? _resolveStringField(
    Map<String, dynamic> source,
    List<String> candidateKeys,
  ) {
    if (source.isEmpty) return null;
    final Set<String> normalized = candidateKeys
        .map((key) => key.toLowerCase())
        .toSet();
    final Queue<Map<String, dynamic>> queue = Queue<Map<String, dynamic>>();
    queue.add(_stringKeyedMap(source));

    while (queue.isNotEmpty) {
      final Map<String, dynamic> current = queue.removeFirst();
      for (final MapEntry<String, dynamic> entry in current.entries) {
        final String key = entry.key.toLowerCase();
        final dynamic value = entry.value;

        if (normalized.contains(key) && value != null) {
          if (value is String) {
            final String trimmed = value.trim();
            if (trimmed.isNotEmpty) return trimmed;
          } else if (value is num) {
            return value.toString();
          }
        }

        if (value is Map) {
          queue.add(_stringKeyedMap(value));
        } else if (value is Iterable) {
          for (final dynamic nested in value) {
            if (nested is Map) {
              queue.add(_stringKeyedMap(nested));
            }
          }
        }
      }
    }
    return null;
  }

  Map<String, dynamic> _stringKeyedMap(Map<dynamic, dynamic> source) {
    return source.map(
      (dynamic key, dynamic value) =>
          MapEntry<String, dynamic>(key.toString(), value),
    );
  }

  void _setTextIfEmpty(TextEditingController controller, String? value) {
    if (value == null || value.trim().isEmpty) return;
    if (controller.text.trim().isNotEmpty) return;
    controller.text = value.trim();
  }

  // เพิ่มฟังก์ชัน _uploadBookBankImage ที่หายไป เพื่อให้อัปโหลดรูปสมุดบัญชีได้
  Future<String?> _uploadBookBankImage() async {
    if (_selectedBookBankImage == null) return null;
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) throw Exception('ไม่พบข้อมูลผู้ใช้');
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final fileName = 'contracts/${user.uid}/book_bank_images/$timestamp.png';
      final storageRef = StorageHelper.instance.ref().child(fileName);

      final bytes = await _selectedBookBankImage!.readAsBytes();
      final image = img.decodeImage(bytes);
      if (image == null) throw Exception('ไม่สามารถอ่านรูปภาพได้');
      final pngBytes = img.encodePng(image);

      final uploadTask = await storageRef.putData(
        Uint8List.fromList(pngBytes),
        SettableMetadata(contentType: 'image/png'),
      );
      final downloadUrl = await uploadTask.ref.getDownloadURL();
      return downloadUrl;
    } catch (e) {
      throw Exception('อัปโหลดรูปสมุดบัญชีล้มเหลว: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        title: const Text('ลงทะเบียนร้านค้า'),
        backgroundColor: AppColors.accent,
        foregroundColor: Colors.white,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () {
            if (Navigator.of(context).canPop()) {
              Navigator.of(context).pop();
            } else {
              // Fallback for flows that expect contract screen as the root destination
              Navigator.of(context).pushReplacementNamed('/contract');
            }
          },
        ),
      ),
      body: _isCheckingExisting
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Form(
                key: _formKey,
                autovalidateMode: _autoValidateMode,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // หัวข้อ
                    Text(
                      'กรอกข้อมูลร้านค้า',
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                        color: Colors.grey.shade800,
                      ),
                    ),
                    const SizedBox(height: 24),

                    // ชื่อร้านค้า
                    TextFormField(
                      controller: _shopNameController,
                      decoration: InputDecoration(
                        labelText: 'ชื่อร้านค้า *',
                        hintText: 'เช่น ร้านอาหารสมชาย',
                        prefixIcon: const Icon(Icons.store),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      validator: (value) {
                        final v = value?.trim() ?? '';
                        if (v.isEmpty) return 'กรุณากรอกชื่อร้านค้า';
                        if (v.length < 2) {
                          return 'กรุณากรอกชื่อร้านค้าอย่างน้อย 2 ตัวอักษร';
                        }
                        return null;
                      },
                    ),

                    const SizedBox(height: 16),

                    // คำอธิบายร้านค้า (ย้ายมาใต้ชื่อร้าน และให้สูงเท่าช่องทั่วไป)
                    TextFormField(
                      controller: _shopDescriptionController,
                      maxLines: 1,
                      textInputAction: TextInputAction.next,
                      decoration: InputDecoration(
                        labelText: 'คำอธิบายร้านค้า',
                        hintText: 'เช่น ร้านอาหารไทยพื้นบ้าน รสชาติอร่อย',
                        prefixIcon: const Icon(Icons.description),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),

                    const SizedBox(height: 24),

                    // รูปภาพร้านค้า
                    const Text(
                      'รูปภาพร้านค้า',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF2C3E50),
                      ),
                    ),
                    const SizedBox(height: 12),

                    GestureDetector(
                      onTap: _isSaving ? null : _pickImage,
                      child: Container(
                        height: 200,
                        width: double.infinity,
                        decoration: BoxDecoration(
                          color: Colors.grey.shade100,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: Colors.grey.shade300),
                        ),
                        child: _isSaving
                            ? const Center(child: CircularProgressIndicator())
                            : _selectedImage != null
                            ? ClipRRect(
                                borderRadius: BorderRadius.circular(12),
                                child: Image.file(
                                  _selectedImage!,
                                  fit: BoxFit.cover,
                                ),
                              )
                            : (_existingShopImageUrl != null &&
                                  _existingShopImageUrl!.isNotEmpty)
                            ? ClipRRect(
                                borderRadius: BorderRadius.circular(12),
                                child: CachedAppImage(
                                  imageUrl: _existingShopImageUrl!,
                                  fit: BoxFit.cover,
                                ),
                              )
                            : Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(
                                    Icons.add_photo_alternate,
                                    size: 64,
                                    color: Colors.grey.shade400,
                                  ),
                                  const SizedBox(height: 8),
                                  Text(
                                    'คลิกเพื่อเลือกรูปภาพ',
                                    style: TextStyle(
                                      color: Colors.grey.shade600,
                                      fontSize: 16,
                                    ),
                                  ),
                                ],
                              ),
                      ),
                    ),

                    const SizedBox(height: 24),

                    // สมุดบัญชีธนาคาร
                    const Text(
                      'สมุดบัญชีธนาคาร',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF2C3E50),
                      ),
                    ),
                    const SizedBox(height: 12),

                    GestureDetector(
                      onTap: _isUploadingBookBank ? null : _pickBookBankImage,
                      child: Container(
                        height: 160,
                        width: double.infinity,
                        decoration: BoxDecoration(
                          color: Colors.grey.shade100,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: Colors.grey.shade300),
                        ),
                        child: _isUploadingBookBank
                            ? const Center(child: CircularProgressIndicator())
                            : _selectedBookBankImage != null
                            ? ClipRRect(
                                borderRadius: BorderRadius.circular(12),
                                child: Image.file(
                                  _selectedBookBankImage!,
                                  fit: BoxFit.cover,
                                ),
                              )
                            : (_existingBookBankImageUrl != null &&
                                  _existingBookBankImageUrl!.isNotEmpty)
                            ? ClipRRect(
                                borderRadius: BorderRadius.circular(12),
                                child: CachedAppImage(
                                  imageUrl: _existingBookBankImageUrl!,
                                  fit: BoxFit.cover,
                                ),
                              )
                            : Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(
                                    Icons.credit_card,
                                    size: 56,
                                    color: Colors.grey.shade400,
                                  ),
                                  const SizedBox(height: 8),
                                  Text(
                                    'คลิกเพื่ออัปโหลดรูปหน้าสมุดบัญชี',
                                    style: TextStyle(
                                      color: Colors.grey.shade600,
                                      fontSize: 14,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  const Text(
                                    'ควรให้เห็นชื่อบัญชีและเลขบัญชีชัดเจน',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: Colors.grey,
                                    ),
                                  ),
                                ],
                              ),
                      ),
                    ),

                    const SizedBox(height: 16),

                    // ชื่อธนาคาร (ตัวเลือกแบบ Dropdown)
                    DropdownButtonFormField<String>(
                      isExpanded: true, // To prevent overflow
                      initialValue:
                          _thaiBanks.contains(_bankNameController.text)
                          ? _bankNameController.text
                          : null,
                      items: _thaiBanks
                          .map(
                            (bank) => DropdownMenuItem<String>(
                              value: bank,
                              child: Text(
                                bank,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          )
                          .toList(),
                      decoration: InputDecoration(
                        labelText: 'ชื่อธนาคาร *',
                        hintText: 'เลือกชื่อธนาคาร',
                        prefixIcon: const Icon(Icons.account_balance),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      onChanged: (value) {
                        setState(() {
                          _bankNameController.text = value ?? '';
                        });
                      },
                      validator: (value) {
                        // แก้ไข: ตรวจสอบจาก controller โดยตรง
                        if (_bankNameController.text.trim().isEmpty) {
                          // ถ้าผู้ใช้เลือก "อื่นๆ" แต่ไม่ได้กรอกช่องอื่น ก็อาจต้อง validate เพิ่ม
                          // แต่ในที่นี้ ตรวจสอบแค่ว่ามีการเลือกหรือไม่
                          return 'กรุณาเลือกชื่อธนาคาร';
                        }
                        return null;
                      },
                    ),

                    const SizedBox(height: 16),

                    // หมายเลขบัญชี
                    TextFormField(
                      controller: _accountNumberController,
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      decoration: InputDecoration(
                        labelText: 'หมายเลขบัญชี *',
                        hintText: 'เช่น 1643440349',
                        helperText: 'ใส่ได้เฉพาะตัวเลขเท่านั้น',
                        helperStyle: TextStyle(
                          fontSize: 12,
                          color: Colors.grey.shade600,
                        ),
                        prefixIcon: const Icon(Icons.credit_card),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      validator: (value) {
                        if (value == null || value.trim().isEmpty) {
                          return 'กรุณากรอกหมายเลขบัญชี';
                        }
                        if (value.trim().length < 10) {
                          return 'หมายเลขบัญชีต้องมีอย่างน้อย 10 หลัก';
                        }
                        return null;
                      },
                    ),

                    const SizedBox(height: 16),

                    // ชื่อเจ้าของบัญชี
                    TextFormField(
                      controller: _accountOwnerController,
                      inputFormatters: [
                        FilteringTextInputFormatter.allow(
                          RegExp(r'[ก-๙a-zA-Z\s]'),
                        ),
                      ],
                      decoration: InputDecoration(
                        labelText: 'ชื่อเจ้าของบัญชี *',
                        hintText: 'เช่น นาย สมชาย ใจดี',
                        helperText: 'ใส่ได้เฉพาะตัวอักษรไทย/อังกฤษ',
                        prefixIcon: const Icon(Icons.person),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      validator: (value) {
                        if (value == null || value.trim().isEmpty) {
                          return 'กรุณากรอกชื่อเจ้าของบัญชี';
                        }
                        return null;
                      },
                    ),

                    const SizedBox(height: 20),
                    const Text(
                      'PromptPay (ถอนเงิน) *',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF2C3E50),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      PromptPayQrPayload.payoutLinkedBankNotice,
                      style: const TextStyle(fontSize: 12, color: Color(0xFFB45309), height: 1.4),
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _promptPayPhoneController,
                      keyboardType: TextInputType.phone,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      decoration: InputDecoration(
                        labelText: 'เบอร์ PromptPay *',
                        hintText: 'เช่น 0812345678',
                        prefixIcon: const Icon(Icons.phone_android),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      validator: (value) {
                        return PromptPayQrPayload.validatePayoutProfile(
                          phone: value,
                          nationalId: _promptPayNationalIdController.text,
                        );
                      },
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _promptPayNationalIdController,
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      decoration: InputDecoration(
                        labelText: 'เลขบัตรประชาชน/นิติบุคคล PromptPay (ถ้ามี)',
                        hintText: '13 หลัก — กรอกแทนเบอร์ได้',
                        prefixIcon: const Icon(Icons.badge_outlined),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      onChanged: (_) => _formKey.currentState?.validate(),
                      validator: (value) {
                        if (value == null || value.trim().isEmpty) {
                          return null;
                        }
                        final digits = value.replaceAll(RegExp(r'\D'), '');
                        if (digits.length != 13) {
                          return 'เลขบัตร/นิติบุคคลต้องมี 13 หลัก';
                        }
                        return null;
                      },
                    ),

                    const SizedBox(height: 16),

                    // ที่อยู่ร้านค้า - ปักหมุดเท่านั้น
                    const Text(
                      'ที่อยู่ร้านค้า *',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF2C3E50),
                      ),
                    ),
                    const SizedBox(height: 12),

                    // ปุ่มปักหมุด
                    InkWell(
                      onTap: _pickLocationFromMap,
                      borderRadius: BorderRadius.circular(12),
                      child: Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: _latitude != null && _longitude != null
                              ? Colors.green.shade50
                              : Colors.grey.shade100,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: _latitude != null && _longitude != null
                                ? Colors.green.shade300
                                : Colors.grey.shade300,
                            width: 2,
                          ),
                        ),
                        child: Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: _latitude != null && _longitude != null
                                    ? Colors.green.shade100
                                    : AppColors.accentLight,
                                shape: BoxShape.circle,
                              ),
                              child: Icon(
                                Icons.location_pin,
                                color: _latitude != null && _longitude != null
                                    ? Colors.green.shade700
                                    : AppColors.accent,
                                size: 32,
                              ),
                            ),
                            const SizedBox(width: 16),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    _latitude != null && _longitude != null
                                        ? 'ปักหมุดแล้ว'
                                        : 'ปักหมุดตำแหน่งร้านค้า',
                                    style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.bold,
                                      color:
                                          _latitude != null &&
                                              _longitude != null
                                          ? Colors.green.shade700
                                          : Colors.grey.shade700,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    _latitude != null && _longitude != null
                                        ? 'Lat: ${_latitude!.toStringAsFixed(6)}\nLng: ${_longitude!.toStringAsFixed(6)}'
                                        : 'คลิกเพื่อเปิดแผนที่และเลือกตำแหน่ง',
                                    style: TextStyle(
                                      fontSize: 13,
                                      color:
                                          _latitude != null &&
                                              _longitude != null
                                          ? Colors.green.shade600
                                          : Colors.grey.shade600,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Icon(
                              Icons.arrow_forward_ios,
                              color: Colors.grey.shade400,
                              size: 20,
                            ),
                          ],
                        ),
                      ),
                    ),

                    const SizedBox(height: 16),

                    // เบอร์โทรศัพท์
                    TextFormField(
                      controller: _phoneController,
                      keyboardType: TextInputType.phone,
                      decoration: InputDecoration(
                        labelText: 'เบอร์โทรศัพท์ *',
                        hintText: 'เช่น 081-234-5678',
                        prefixIcon: const Icon(Icons.phone),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      validator: (value) {
                        final v = value?.trim() ?? '';
                        if (v.isEmpty) return 'กรุณากรอกเบอร์โทรศัพท์';
                        if (!_isValidThaiPhone(v)) {
                          return 'กรุณากรอกเบอร์โทรศัพท์ให้ถูกต้อง (เช่น 0812345678 หรือ +66812345678)';
                        }
                        return null;
                      },
                    ),

                    const SizedBox(height: 16),

                    // อีเมล
                    TextFormField(
                      controller: _emailController,
                      keyboardType: TextInputType.emailAddress,
                      decoration: InputDecoration(
                        labelText: 'อีเมล *',
                        hintText: 'example@email.com',
                        prefixIcon: const Icon(Icons.email),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      validator: (value) {
                        final v = value?.trim() ?? '';
                        if (v.isEmpty) return 'กรุณากรอกอีเมล';
                        if (!_isValidEmail(v)) return 'รูปแบบอีเมลไม่ถูกต้อง';
                        return null;
                      },
                    ),

                    const SizedBox(height: 32),

                    // ปุ่มบันทึก
                    SizedBox(
                      width: double.infinity,
                      height: 52,
                      child: ElevatedButton(
                        onPressed: (_isSaving || _isUploadingBookBank)
                            ? null
                            : _saveShopRegistration,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.accent,
                          foregroundColor: Colors.white,
                          disabledBackgroundColor: Colors.grey.shade300,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        child: _isSaving
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  valueColor: AlwaysStoppedAnimation<Color>(
                                    Colors.white,
                                  ),
                                ),
                              )
                            : const Text(
                                'บันทึกข้อมูล',
                                style: TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                      ),
                    ),

                    const SizedBox(height: 16),

                    // ข้อความเพิ่มเติม
                    Center(
                      child: Text(
                        '* หมายถึงข้อมูลที่จำเป็นต้องกรอก',
                        style: TextStyle(
                          fontSize: 14,
                          color: Colors.grey.shade600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
    );
  }
}
