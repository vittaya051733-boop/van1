import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:image_picker/image_picker.dart';
import 'storage_helper.dart';
import 'utils/io_platform.dart';
import 'utils/web_profile_upload.dart';

class EditProfileScreen extends StatefulWidget {
  const EditProfileScreen({super.key});

  @override
  State<EditProfileScreen> createState() => _EditProfileScreenState();
}

class _EditProfileScreenState extends State<EditProfileScreen> {
  final _displayNameController = TextEditingController();
  final _auth = FirebaseAuth.instance;
  final _storage = StorageHelper.instance;
  final _picker = ImagePicker();

  User? _user;
  bool _isLoading = false;
  XFile? _imageFile;
  String? _networkImageUrl;

  @override
  void initState() {
    super.initState();
    _user = _auth.currentUser;
    if (_user != null) {
      _displayNameController.text = _user!.displayName ?? '';
      _networkImageUrl = _user!.photoURL;
    }
  }

  Future<void> _pickImage() async {
    final pickedFile = await _picker.pickImage(source: ImageSource.gallery, imageQuality: 70);
    if (pickedFile != null) {
      setState(() {
        _imageFile = pickedFile;
      });
    }
  }

  Future<String?> _uploadImage(XFile image) async {
    if (_user == null) return null;
    try {
      final ref = _storage.ref(
        'profile_pictures/${_user!.uid}/${DateTime.now().millisecondsSinceEpoch}',
      );
      if (kIsWeb) {
        return await uploadProfileImage(ref: ref, image: image);
      }
      return await uploadXFilePathToStorage(ref, image.path);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('อัปโหลดรูปภาพล้มเหลว: $e')));
      }
      return null;
    }
  }

  Future<void> _updateProfile() async {
    if (_user == null) return;

    setState(() => _isLoading = true);

    try {
      String? photoUrl = _networkImageUrl;

      // Upload new image if selected
      if (_imageFile != null) {
        photoUrl = await _uploadImage(_imageFile!);
      }

      // Update display name and photo URL
      await _user!.updateDisplayName(_displayNameController.text.trim());
      await _user!.updatePhotoURL(photoUrl);

      // Reload user to get updated info
      await _user!.reload();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('อัปเดตโปรไฟล์สำเร็จ!'), backgroundColor: Colors.green),
        );
        Navigator.of(context).pop();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('เกิดข้อผิดพลาด: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  Widget _buildAvatarChild() {
    if (_imageFile != null && kIsWeb) {
      return FutureBuilder<Uint8List>(
        future: _imageFile!.readAsBytes(),
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const Icon(Icons.person, size: 60, color: Colors.white);
          }
          return ClipOval(
            child: Image.memory(
              snapshot.data!,
              width: 120,
              height: 120,
              fit: BoxFit.cover,
            ),
          );
        },
      );
    }
    if (_imageFile == null && _networkImageUrl == null) {
      return const Icon(Icons.person, size: 60, color: Colors.white);
    }
    return const SizedBox.shrink();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('แก้ไขโปรไฟล์'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Stack(
                children: [
                  CircleAvatar(
                    radius: 60,
                    backgroundColor: Colors.grey.shade300,
                    backgroundImage: _imageFile != null && !kIsWeb
                        ? buildFileImageProvider(_imageFile!.path)
                        : (_networkImageUrl != null && _imageFile == null
                              ? NetworkImage(_networkImageUrl!)
                              : null),
                    child: _buildAvatarChild(),
                  ),
                  Positioned(
                    bottom: 0,
                    right: 0,
                    child: CircleAvatar(
                      backgroundColor: Theme.of(context).primaryColor,
                      child: IconButton(
                        icon: const Icon(Icons.camera_alt, color: Colors.white),
                        onPressed: _pickImage,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 32),
            TextFormField(
              controller: _displayNameController,
              decoration: InputDecoration(
                labelText: 'ชื่อที่แสดง',
                prefixIcon: const Icon(Icons.person),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
            const SizedBox(height: 32),
            ElevatedButton(
              onPressed: _isLoading ? null : _updateProfile,
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
              ),
              child: _isLoading
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.white))
                  : const Text('บันทึกการเปลี่ยนแปลง', style: TextStyle(fontSize: 16)),
            ),
          ],
        ),
      ),
    );
  }
}