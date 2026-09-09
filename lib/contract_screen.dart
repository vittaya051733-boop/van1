import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data'; // เพิ่มบรรทัดนี้
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:signature/signature.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:image_picker/image_picker.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:path/path.dart' as p;
import './shop_registration_screen.dart';
import 'package:file_saver/file_saver.dart'; // เพิ่ม
import 'package:image/image.dart' as img; // เพิ่มบรรทัดนี้
import 'register_shop_next.dart'; // เพิ่ม import สำหรับ RegisterShopNextScreen ด้านบนไฟล์
import 'data/merchant_service_agreement.dart';
import 'utils/app_colors.dart';
import 'storage_helper.dart';
import 'utils/thai_id_card_scanner.dart';

class ContractScreen extends StatefulWidget {
  final String? serviceType;

  const ContractScreen({super.key, this.serviceType});

  @override
  State<ContractScreen> createState() => _ContractScreenState();
}

class _CompressedImageResult {
  const _CompressedImageResult({
    required this.bytes,
    required this.extension,
    required this.mimeType,
  });

  final Uint8List bytes;
  final String extension;
  final String mimeType;
}

class _ContractScreenState extends State<ContractScreen> {
  String _buildDefaultContractTemplate() {
    return MerchantServiceAgreement.buildTemplate(
      day: _currentDay,
      monthName: _currentMonthName,
      monthNumber: _currentMonthNumber,
      year: _currentYear,
    );
  }

  bool _accepted = false;
  bool _isUploading = false;
  final SignatureController _signatureController = SignatureController(
    penStrokeWidth: 2.5,
    penColor: Colors.black,
    exportBackgroundColor: Colors.transparent,
  );

  File? _selectedIdCardFrontImage;
  File? _selectedIdCardBackImage;
  bool _isProcessingIdCardFront = false;
  bool _isProcessingIdCardBack = false;
  String? _verifiedNationalId;
  String? _resolvedServiceType;

  String _currentDay = '';
  String _currentMonthNumber = '';
  String _currentYear = '';
  String _currentMonthName = '';

  // เพิ่มฟังก์ชัน _setCurrentDate
  void _setCurrentDate() {
    final now = DateTime.now();
    _currentDay = now.day.toString();
    _currentMonthNumber = now.month.toString().padLeft(2, '0');
    _currentYear = (now.year + 543).toString();
    _currentMonthName = MerchantServiceAgreement.thaiMonthNames[now.month - 1];
  }

  bool _isLoading = true;
  String? _error;
  final TextEditingController _contractTextController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _resolvedServiceType = widget.serviceType;
    _setCurrentDate();
    WidgetsBinding.instance.addPostFrameCallback((_) => _ensureContractState());
  }

  Future<void> _ensureContractState() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      await _fetchContractText();
      return;
    }
    try {
      final snapshot =
          await FirebaseFirestore.instance.collection('contracts').doc(user.uid).get();
      final data = snapshot.data();
      final storedServiceType = data?['serviceType'] as String?;
      final status = data?['status'] as String?;
      if (mounted && storedServiceType != null && storedServiceType != _resolvedServiceType) {
        setState(() => _resolvedServiceType = storedServiceType);
      }
      final serviceType = _resolvedServiceType ?? storedServiceType;
      if (status == 'accepted') {
        if (!mounted) return;
        if (serviceType == null) {
          Navigator.of(context).pushReplacement(
            MaterialPageRoute(builder: (_) => const RegisterShopNextScreen()),
          );
        } else {
          Navigator.of(context).pushReplacement(
            MaterialPageRoute(builder: (_) => ShopRegistrationScreen(serviceType: serviceType)),
          );
        }
        return;
      }
    } catch (e) {
      debugPrint('Failed to check existing contract status: $e');
    }
    if (!mounted) return;
    await _fetchContractText();
  }

  Future<void> _fetchContractText() async {
    if (!mounted) return;
    setState(() {
      _isLoading = true;
      _error = null;
    });

    _setCurrentDate();
    final template = _buildDefaultContractTemplate();

    if (!mounted) return;
    setState(() {
      _isLoading = false;
      _contractTextController.text = template;
    });
  }
  Future<void> _captureAndUploadContract() async {
    if (!_accepted) {
  _showSnackBar('กรุณายอมรับข้อกำหนดก่อน', AppColors.accent);
      return;
    }
    if (_signatureController.isEmpty) {
  _showSnackBar('กรุณาลงลายมือชื่อของเจ้าของร้านค้า', AppColors.accent);
      return;
    }
    if (_selectedIdCardFrontImage == null) {
  _showSnackBar('กรุณาอัปโหลดรูปบัตรประชาชน (ด้านหน้า)', AppColors.accent);
      return;
    }
    if (_verifiedNationalId == null) {
      _showSnackBar('ไม่สามารถอ่านเลขบัตรจากรูปด้านหน้าได้ — ถ่ายใหม่ให้ชัด', AppColors.accent);
      return;
    }
    if (_selectedIdCardBackImage == null) {
  _showSnackBar('กรุณาอัปโหลดรูปบัตรประชาชน (ด้านหลัง)', AppColors.accent);
      return;
    }

    setState(() => _isUploading = true);

    try {
      _setCurrentDate();
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) throw Exception('กรุณาเข้าสู่ระบบก่อน');
      await user.reload();
      final freshUser = FirebaseAuth.instance.currentUser;
      if (freshUser == null) throw Exception('Session หมดอายุ กรุณาเข้าสู่ระบบใหม่');
      if (!mounted) return;
      if (mounted) {
        _showSnackBar('กำลังอัปโหลดรูปบัตรประชาชน...', Colors.blue);
      }
      String? signatureUrl;
      
      // อัปโหลดรูปบัตรประชาชน (ไม่ต้องเก็บ URL)
      if (_selectedIdCardFrontImage != null) {
        await _uploadImageOnly(_selectedIdCardFrontImage!, 'id_card_images');
      }
      if (_selectedIdCardBackImage != null) {
        await _uploadImageOnly(_selectedIdCardBackImage!, 'id_card_images');
      }

      // อัปโหลดลายเซ็นเป็น WebP
      if (!mounted) return;
      if (mounted) {
        _showSnackBar('กำลังอัปโหลดลายเซ็น...', Colors.blue);
      }
      final signatureBytes = await _signatureController.toPngBytes();
      if (signatureBytes != null) {
        final signatureFile = File('${Directory.systemTemp.path}/signature_${freshUser.uid}.png');
        await signatureFile.writeAsBytes(signatureBytes);
        signatureUrl = await _uploadImageAsWebp(signatureFile, 'signatures');
      }

      // อัปโหลดข้อความสัญญาเป็น .txt
      if (!mounted) return;
      if (mounted) {
        _showSnackBar('กำลังบันทึกไฟล์สัญญา (.txt)...', Colors.blue);
      }
      final contractBody = MerchantServiceAgreement.applyContractDate(
        text: MerchantServiceAgreement.sanitizeContractText(
          _contractTextController.text,
        ),
        day: _currentDay,
        monthName: _currentMonthName,
        year: _currentYear,
      );
      final contractText =
          '$contractBody\n\nลายมือชื่อ (ฝั่งร้านค้า): [ลงลายมือชื่อในระบบ]\nวันที่ $_currentDay/$_currentMonthNumber/$_currentYear';
      final contractBytes = utf8.encode(contractText);
      final timestamp = DateTime.now().millisecondsSinceEpoch;
        final contractFileName =
          'contracts/${freshUser.uid}/agreements/${_resolvedServiceType ?? 'unknown'}_$timestamp.txt';
      final contractStorageRef = StorageHelper.instance.ref().child(contractFileName);
      final contractUploadTask = contractStorageRef.putData(
        Uint8List.fromList(contractBytes),
        SettableMetadata(
          contentType: 'text/plain',
          customMetadata: {
            'userId': freshUser.uid,
            'serviceType': widget.serviceType ?? 'unknown',
            'timestamp': timestamp.toString(),
          },
        ),
      );
      await contractUploadTask.timeout(const Duration(seconds: 60));
      final contractDownloadUrl = await contractStorageRef.getDownloadURL();

      // Update Firestore: บันทึก URL ของแต่ละไฟล์แยกกัน
      await FirebaseFirestore.instance.collection('contracts').doc(freshUser.uid).set({
        'serviceType': _resolvedServiceType,
        'status': 'accepted',
        'contractTextUrl': contractDownloadUrl,
        'signatureImageUrl': signatureUrl,
        'contractText': contractBody,
        'acceptedAt': FieldValue.serverTimestamp(),
        if (_verifiedNationalId != null) ...<String, dynamic>{
          'verifiedNationalId': _verifiedNationalId,
          'nationalIdVerifiedAt': FieldValue.serverTimestamp(),
          'nationalIdSource': 'mlkit',
        },
      }, SetOptions(merge: true));

      if (mounted) {
        _showSnackBar('✅ ยอมรับสัญญาและบันทึกข้อมูลสำเร็จ!', Colors.green);
      }

      // บันทึกไฟล์ลงเครื่องผู้ใช้ (ข้อความสัญญา)
      try {
        await FileSaver.instance.saveFile(
            name: 'contract_${freshUser.uid}_$timestamp',
            bytes: Uint8List.fromList(contractBytes),
            fileExtension: 'txt',
            mimeType: MimeType.text);
        if (mounted) {
          _showSnackBar('📄 สัญญาถูกบันทึกในโฟลเดอร์ Downloads แล้ว', Colors.blue);
        }
      } catch (e) {
        if (mounted) {
          _showErrorDialog('ไม่สามารถบันทึกไฟล์ลงเครื่องได้: $e');
        }
      }

      // บันทึกลายเซ็นลงเครื่องผู้ใช้ (PNG)
      if (signatureBytes != null) {
        try {
          await FileSaver.instance.saveFile(
              name: 'signature_${freshUser.uid}_$timestamp',
              bytes: signatureBytes,
              fileExtension: 'png',
              mimeType: MimeType.png);
        } catch (e) {
          if (mounted) {
            _showErrorDialog('ไม่สามารถบันทึกลายเซ็นลงเครื่องได้: $e');
          }
        }
      }

      // บันทึกรูปบัตรประชาชนลงเครื่องผู้ใช้ (พยายาม WebP ถ้าไม่ได้ fallback เป็น JPG)
      if (_selectedIdCardFrontImage != null) {
        try {
          final frontResult = await _compressWithWebpFallback(
            await _selectedIdCardFrontImage!.readAsBytes(),
            originalExtension: p.extension(_selectedIdCardFrontImage!.path),
          );
          await FileSaver.instance.saveFile(
            name: 'id_card_front_${freshUser.uid}_$timestamp',
            bytes: frontResult.bytes,
            fileExtension: frontResult.extension,
            mimeType: _fileSaverMimeForExtension(frontResult.extension),
          );
        } catch (e) {
          if (mounted) {
            _showErrorDialog('ไม่สามารถบันทึกรูปบัตรประชาชน (หน้า) ลงเครื่องได้: $e');
          }
        }
      }
      if (_selectedIdCardBackImage != null) {
        try {
          final backResult = await _compressWithWebpFallback(
            await _selectedIdCardBackImage!.readAsBytes(),
            originalExtension: p.extension(_selectedIdCardBackImage!.path),
          );
          await FileSaver.instance.saveFile(
            name: 'id_card_back_${freshUser.uid}_$timestamp',
            bytes: backResult.bytes,
            fileExtension: backResult.extension,
            mimeType: _fileSaverMimeForExtension(backResult.extension),
          );
        } catch (e) {
          if (mounted) {
            _showErrorDialog('ไม่สามารถบันทึกรูปบัตรประชาชน (หลัง) ลงเครื่องได้: $e');
          }
        }
      }

      // Navigate to the next step
      final serviceType = _resolvedServiceType ??
          (await FirebaseFirestore.instance
                  .collection('contracts')
                  .doc(freshUser.uid)
                  .get())
              .data()
              ?['serviceType'] as String?;

      if (!mounted) return;

      if (serviceType == null) {
        _showSnackBar('❌ ไม่พบประเภทบริการของบัญชีนี้ กรุณาเลือกบริการใหม่', Colors.red);
        if (!mounted) return;
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => const RegisterShopNextScreen()),
        );
        return;
      }

      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (context) => ShopRegistrationScreen(serviceType: serviceType),
        ),
      );
    } catch (e) {
      if (mounted) {
        _showErrorDialog('เกิดข้อผิดพลาดทั่วไป: $e');
      }
    } finally {
      if (mounted) {
        setState(() => _isUploading = false);
      }
    }
  }

  Future<_CompressedImageResult> _compressWithWebpFallback(
    Uint8List originalBytes, {
    String? originalExtension,
  }) async {
    Future<_CompressedImageResult?> tryFlutterCompress(
      CompressFormat format,
      String extension,
      String mimeType,
      int quality,
    ) async {
      try {
        final result = await FlutterImageCompress.compressWithList(
          originalBytes,
          format: format,
          quality: quality,
        );
        if (result.isNotEmpty) {
          return _CompressedImageResult(
            bytes: Uint8List.fromList(result),
            extension: extension,
            mimeType: mimeType,
          );
        }
      } catch (e) {
        debugPrint('⚠️ Compression to $extension failed: $e');
      }
      return null;
    }

    final webpResult = await tryFlutterCompress(CompressFormat.webp, 'webp', 'image/webp', 85);
    if (webpResult != null) return webpResult;

    final jpegResult = await tryFlutterCompress(CompressFormat.jpeg, 'jpg', 'image/jpeg', 90);
    if (jpegResult != null) return jpegResult;

    final decoded = img.decodeImage(originalBytes);
    if (decoded != null) {
      final jpegBytes = Uint8List.fromList(img.encodeJpg(decoded, quality: 90));
      return _CompressedImageResult(
        bytes: jpegBytes,
        extension: 'jpg',
        mimeType: 'image/jpeg',
      );
    }

    final sanitizedExt = originalExtension?.replaceAll('.', '').toLowerCase();
    return _CompressedImageResult(
      bytes: originalBytes,
      extension: sanitizedExt?.isNotEmpty == true ? sanitizedExt! : 'png',
      mimeType: _guessMimeType(sanitizedExt),
    );
  }

  String _guessMimeType(String? extension) {
    switch (extension) {
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'heic':
        return 'image/heic';
      case 'heif':
        return 'image/heif';
      case 'bmp':
        return 'image/bmp';
      case 'gif':
        return 'image/gif';
      case 'webp':
        return 'image/webp';
      case 'png':
      default:
        return 'image/png';
    }
  }

  MimeType _fileSaverMimeForExtension(String extension) {
    switch (extension.toLowerCase()) {
      case 'jpg':
      case 'jpeg':
        return MimeType.jpeg;
      case 'webp':
        return MimeType.webp;
      case 'gif':
        return MimeType.gif;
      case 'bmp':
        return MimeType.bmp;
      case 'heic':
        return MimeType.heic;
      case 'heif':
        return MimeType.heif;
      case 'png':
        return MimeType.png;
      default:
        return MimeType.other;
    }
  }

  // ฟังก์ชันอัปโหลดรูปภาพ (พยายาม WebP ถ้าเป็นไปได้)
  /// อัปโหลดไฟล์แบบไม่ดึง URL กลับมา (สำหรับบัตรประชาชน)
  Future<void> _uploadImageOnly(File file, String path) async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) throw Exception('ไม่พบข้อมูลผู้ใช้');

      if (!await file.exists()) {
        throw Exception('ไม่พบไฟล์ที่เลือก กรุณาเลือกรูปภาพใหม่');
      }

      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final originalBytes = await file.readAsBytes();
      final compressed = await _compressWithWebpFallback(
        originalBytes,
        originalExtension: p.extension(file.path),
      );
      final fileName = 'contracts/${user.uid}/$path/$timestamp.${compressed.extension}';

      final storage = StorageHelper.instance;
      final storageRef = storage.ref().child(fileName);
      print('📤 กำลังอัปโหลดไฟล์: $fileName');
      print('📍 Bucket: ${storage.bucket}');

      await storageRef.putData(
        compressed.bytes,
        SettableMetadata(contentType: compressed.mimeType),
      );

      print('✅ อัปโหลดสำเร็จ (ไม่ดึง URL)');
    } catch (e) {
      print('❌ Error อัปโหลด $path: $e');
      throw Exception('อัปโหลดไฟล์ใน $path ล้มเหลว: $e');
    }
  }

  Future<String?> _uploadImageAsWebp(File file, String path) async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) throw Exception('ไม่พบข้อมูลผู้ใช้');

      if (!await file.exists()) {
        throw Exception('ไม่พบไฟล์ที่เลือก กรุณาเลือกรูปภาพใหม่');
      }

      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final originalBytes = await file.readAsBytes();
      final compressed = await _compressWithWebpFallback(
        originalBytes,
        originalExtension: p.extension(file.path),
      );
      final fileName = 'contracts/${user.uid}/$path/$timestamp.${compressed.extension}';

      final storage = StorageHelper.instance;
      final storageRef = storage.ref().child(fileName);
      print('📤 กำลังอัปโหลดไฟล์: $fileName');
      final uploadTask = await storageRef.putData(
        compressed.bytes,
        SettableMetadata(contentType: compressed.mimeType),
      );
      final downloadUrl = await uploadTask.ref.getDownloadURL();
      print('✅ อัปโหลดสำเร็จ: $downloadUrl');
      return downloadUrl;
    } catch (e) {
      print('❌ Error อัปโหลด $path: $e');
      throw Exception('อัปโหลดไฟล์ใน $path ล้มเหลว: $e');
    }
  }

  /// ฟังก์ชันตัวอย่างสำหรับตัดขอบรูปให้พอดีกับกรอบที่กำหนด (mock)
  /// ในโปรเจกต์จริงควรใช้ package เช่น 'image' หรือ API ภายนอก
  Future<File> cropImageToFrame(File imageFile, {int width = 180, int height = 180}) async {
    final bytes = await imageFile.readAsBytes();
    final original = img.decodeImage(bytes);
    if (original == null) return imageFile;

    // ปรับขนาดให้ด้านสั้นเท่ากับกรอบก่อน
    img.Image resized;
    if (original.width > original.height) {
      // กว้างกว่าสูง: resize สูงให้ตรง, กว้างตามอัตราส่วน
      resized = img.copyResize(original, height: height);
    } else {
      // สูงกว่ากว้างหรือเท่ากัน: resize กว้างให้ตรง, สูงตามอัตราส่วน
      resized = img.copyResize(original, width: width);
    }

    // crop ตรงกลางให้ได้ขนาด width x height
    int startX = (resized.width - width) ~/ 2;
    int startY = (resized.height - height) ~/ 2;
    final cropped = img.copyCrop(
      resized,
      x: startX,
      y: startY,
      width: width,
      height: height,
    );
    final outBytes = img.encodeJpg(cropped);
    final outFile = await imageFile.writeAsBytes(outBytes, flush: true);
    return outFile;
  }

  // ฟังก์ชันตรวจสอบความเบลอของภาพ (แบบง่าย)
  Future<bool> isImageBlurry(File imageFile) async {
    final bytes = await imageFile.readAsBytes();
    final image = img.decodeImage(bytes);
    if (image == null) return true;

    // แปลงเป็น grayscale
    final grayscale = img.grayscale(image);

    // วัดค่า contrast (ส่วนเบี่ยงเบนมาตรฐานของ pixel)
    final pixels = grayscale.getBytes();
    final mean = pixels.reduce((a, b) => a + b) / pixels.length;
    final variance = pixels.map((p) => (p - mean) * (p - mean)).reduce((a, b) => a + b) / pixels.length;
    final stddev = math.sqrt(variance);

    // threshold ต่ำถือว่าเบลอ
    return stddev < 20;
  }

  // ฟังก์ชันเลือกและตรวจสอบรูปภาพบัตรประชาชน
  Future<void> _pickAndValidateIdCardImage({required ImageSource source, required bool isFront}) async {
    String? imagePath;

    try {
      final ImagePicker picker = ImagePicker();
      final XFile? image = await picker.pickImage(
        source: source,
        maxWidth: 1400,
        maxHeight: 1400,
        imageQuality: 90,
      );
      if (image == null) return;
      imagePath = image.path;
    } catch (e) {
      _showSnackBar('เกิดข้อผิดพลาดในการสแกน: $e', Colors.red);
    }

    if (imagePath == null) return;

    final originalFile = File(imagePath);

    if (!mounted) return;
    setState(() {
      if (isFront) {
        _selectedIdCardFrontImage = null;
        _isProcessingIdCardFront = true;
      } else {
        _selectedIdCardBackImage = null;
        _isProcessingIdCardBack = true;
      }
    });

    try {
      if (isFront) {
        final scan = await ThaiIdCardScanner.scanNationalId(originalFile);
        _verifiedNationalId = scan.nationalId;
      } else {
        final quality = await ThaiIdCardScanner.validateImageQuality(originalFile);
        if (!quality.passed) {
          if (!mounted) return;
          _showSnackBar(
            quality.issues.map((issue) => issue.messageTh).join('\n'),
            Colors.red,
          );
          setState(() {
            _selectedIdCardBackImage = null;
          });
          return;
        }
      }

      final persistedFile = await _persistTemporaryImage(originalFile, isFront: isFront);
      if (!mounted) return;

      setState(() {
        if (isFront) {
          _selectedIdCardFrontImage = persistedFile;
        } else {
          _selectedIdCardBackImage = persistedFile;
        }
      });

      if (isFront) {
        _showSnackBar(
          '✅ อ่านเลขบัตรจากรูปแล้ว (${_maskNationalId(_verifiedNationalId!)})',
          Colors.green,
        );
      } else {
        _showSnackBar('✅ รูปภาพผ่านการตรวจสอบความชัดเจน', Colors.green);
      }
    } on ThaiIdCardScanException catch (error) {
      if (!mounted) return;
      _showSnackBar('❌ ${error.message}', Colors.red);
      setState(() {
        if (isFront) {
          _selectedIdCardFrontImage = null;
          _verifiedNationalId = null;
        } else {
          _selectedIdCardBackImage = null;
        }
      });
    } catch (e) {
      if (!mounted) return;
      _showSnackBar('❌ เกิดข้อผิดพลาดในการตรวจสอบรูปภาพ: $e', Colors.red);
      setState(() {
        if (isFront) {
          _selectedIdCardFrontImage = null;
        } else {
          _selectedIdCardBackImage = null;
        }
      });
    } finally {
      if (mounted) {
        setState(() {
          if (isFront) {
            _isProcessingIdCardFront = false;
          } else {
            _isProcessingIdCardBack = false;
          }
        });
      }
    }
  }

  Future<File> _persistTemporaryImage(File source, {required bool isFront}) async {
    final suffix = isFront ? 'front' : 'back';
    final targetPath =
        '${Directory.systemTemp.path}/id_card_${suffix}_${DateTime.now().millisecondsSinceEpoch}.jpg';
    return source.copy(targetPath);
  }

  String _maskNationalId(String id) {
    if (id.length < 4) {
      return id;
    }
    return '${id.substring(0, 3)}******${id.substring(id.length - 2)}';
  }

  void _showErrorDialog(String error) {
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('❌ เกิดข้อผิดพลาด'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              SelectableText(error), // Make error selectable
              const SizedBox(height: 16),
              const Divider(),
              const SizedBox(height: 8),
              const Text('💡 วิธีแก้ไข (สำหรับ Permission Denied):', style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              const SelectableText(
                '''
rules_version = '2';
service firebase.storage {
  match /b/{bucket}/o {
    match /contracts/{userId}/{allPaths=**} {
      allow read, write: if request.auth != null && request.auth.uid == userId;
    }
  }
}''',
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('ปิด'),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
              // Retry
              _captureAndUploadContract();
            },
            child: const Text('ลองใหม่'),
          ),
        ],
      ),
    );
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

  @override
  void dispose() {
    _signatureController.dispose();
    _contractTextController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          color: Colors.white,
          onPressed: () {
            // เมื่อกดปุ่มย้อนกลับ ให้ไปหน้า register_shop_next.dart
            Navigator.of(context).pushReplacement(
              MaterialPageRoute(
                builder: (context) => RegisterShopNextScreen(),
              ),
            );
          },
        ),
        title: const Text('สัญญาการให้บริการ'),
  backgroundColor: AppColors.accent,
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      body: Container(
        color: Colors.white,
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'สัญญาการให้บริการ แว๊นตลาด',
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF2C3E50),
                ),
              ),
              const SizedBox(height: 8),
              const Divider(),
              const SizedBox(height: 24),
              const Text(
                'เนื้อหาสัญญา ',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF2C3E50),
                ),
              ),
              const SizedBox(height: 16),
              if (_isLoading)
                const Center(child: CircularProgressIndicator())
              else if (_error != null)
                Text(_error!, style: const TextStyle(color: Colors.red))
              else
                TextField(
                  controller: _contractTextController,
                  readOnly: true,
                  maxLines: null,
                  minLines: 10,
                  style: const TextStyle(
                    fontSize: 16,
                    height: 1.6,
                    color: Color(0xFF2C3E50),
                  ),
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    labelText: 'เนื้อหาสัญญา',
                    alignLabelWithHint: true,
                  ),
                ),
              const SizedBox(height: 40),
              const Text(
                'ลายมือชื่อ (ฝั่งร้านค้า)',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF2C3E50),
                ),
              ),
              const SizedBox(height: 12),
              Container(
                height: 200,
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.grey.shade400),
                  borderRadius: BorderRadius.circular(12),
                  color: Colors.grey.shade50,
                ),
                child: Signature(
                  controller: _signatureController,
                  backgroundColor: Colors.transparent,
                ),
              ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: () => _signatureController.clear(),
                  icon: const Icon(Icons.clear, size: 20),
                  label: const Text('ล้างลายเซ็น'),
                ),
              ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.center,
                child: Text(
                  'วันที่ $_currentDay/$_currentMonthNumber/$_currentYear',
                  style: const TextStyle(fontSize: 16, color: Color(0xFF2C3E50)),
                ),
              ),
              const SizedBox(height: 32),
              const Text(
                'เอกสารยืนยันตัวตน',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF2C3E50),
                ),
              ),
              const SizedBox(height: 4),
              const Text(
                'กรุณาอัปโหลดรูปถ่ายบัตรประชาชนที่ชัดเจน',
                style: TextStyle(fontSize: 14, color: Colors.grey),
              ),
              const SizedBox(height: 16),
              _buildIdCardUploader(
                title: 'บัตรประชาชน (ด้านหน้า)',
                imageFile: _selectedIdCardFrontImage,
                isProcessing: _isProcessingIdCardFront,
                onTap: () => _showImageSourceDialog(isFront: true),
              ),
              const SizedBox(height: 16),
              _buildIdCardUploader(
                title: 'บัตรประชาชน (ด้านหลัง)',
                imageFile: _selectedIdCardBackImage,
                isProcessing: _isProcessingIdCardBack,
                onTap: () => _showImageSourceDialog(isFront: false),
              ),
              const SizedBox(height: 32),
              Row(
                children: [
                  SizedBox(
                    width: 24,
                    height: 24,
                    child: Checkbox(
                      value: _accepted,
                      onChanged: (value) {
                        setState(() => _accepted = value ?? false);
                      },
                      activeColor: AppColors.accent,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text(
                      'ข้าพเจ้ายอมรับข้อกำหนดและเงื่อนไขในสัญญานี้',
                      style: TextStyle(
                        fontSize: 16,
                        color: Color(0xFF2C3E50),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                height: 52,
                child: ElevatedButton(
                  onPressed: (_accepted && !_isUploading) ? _captureAndUploadContract : null,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.accent,
                    foregroundColor: Colors.white,
                    disabledBackgroundColor: Colors.grey.shade300,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    textStyle: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  child: _isUploading
                      ? const Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                              ),
                            ),
                            SizedBox(width: 12),
                            Text('กำลังบันทึกสัญญา...'),
                          ],
                        )
                      : const Text('ยอมรับและดำเนินการต่อ'),
                ),
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }

  // Dialog สำหรับเลือกแหล่งที่มาของรูป (กล้อง/คลังภาพ)
  Future<void> _showImageSourceDialog({required bool isFront}) async {
    showModalBottomSheet(
      context: context,
      builder: (context) {
        return SafeArea(
          child: Wrap(
            children: <Widget>[
              ListTile(
                leading: const Icon(Icons.photo_camera),
                title: const Text('ใช้กล้องถ่ายรูป'),
                onTap: () {
                  Navigator.of(context).pop();
                  _pickAndValidateIdCardImage(source: ImageSource.camera, isFront: isFront);
                },
              ),
              ListTile(
                leading: const Icon(Icons.photo_library),
                title: const Text('เลือกจากคลังภาพ'),
                onTap: () {
                  Navigator.of(context).pop();
                  _pickAndValidateIdCardImage(source: ImageSource.gallery, isFront: isFront);
                },
              ),
            ],
          ),
        );
      },
    );
  }

  // Widget สำหรับสร้าง UI ของการอัปโหลดบัตร
  Widget _buildIdCardUploader({
    required String title,
    required File? imageFile,
    required bool isProcessing,
    required VoidCallback onTap,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        GestureDetector(
          onTap: isProcessing ? null : onTap,
          child: Container(
            height: 200,
            width: double.infinity,
            decoration: BoxDecoration(
              color: Colors.grey.shade100,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.grey.shade300, width: 2),
            ),
            child: isProcessing
                ? const Center(child: CircularProgressIndicator())
                : imageFile != null
                    ? Center(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(10),
                          child: Image.file(
                            imageFile,
                            fit: BoxFit.contain,
                            width: 180,
                            height: 180,
                          ),
                        ),
                      )
                    : Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.add_a_photo_outlined,
                            size: 64,
                            color: Colors.grey.shade400,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'แตะเพื่ออัปโหลดรูปภาพ',
                            style: TextStyle(
                              color: Colors.grey.shade600,
                              fontSize: 16,
                            ),
                          ),
                        ],
                      ),
          ),
        ),
      ],
    );
  }
}
