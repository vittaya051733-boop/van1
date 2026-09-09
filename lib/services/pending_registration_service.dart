import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'branch_assignment_service.dart';

/// Persists registration data locally before Firebase Auth completes so
/// [AuthWrapper] can finish setup even if [RegisterScreen] is disposed.
class PendingRegistrationService {
  PendingRegistrationService._();

  static const _keyServiceType = 'pending_reg_service_type';
  static const _keyBranchJson = 'pending_reg_branch_json';

  static Future<void> stage({
    required String serviceType,
    BranchAssignment? branch,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyServiceType, serviceType.trim());
    if (branch != null) {
      await prefs.setString(
        _keyBranchJson,
        jsonEncode(_branchToJson(branch)),
      );
    }
  }

  static Future<void> stageBranch(BranchAssignment branch) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _keyBranchJson,
      jsonEncode(_branchToJson(branch)),
    );
  }

  static Future<String?> applyIfNeeded(User user) async {
    final prefs = await SharedPreferences.getInstance();
    final serviceType = prefs.getString(_keyServiceType)?.trim();
    if (serviceType == null || serviceType.isEmpty) {
      return null;
    }

    final branchJson = prefs.getString(_keyBranchJson);
    BranchAssignment? branch;
    if (branchJson != null && branchJson.isNotEmpty) {
      try {
        branch = _branchFromJson(
          jsonDecode(branchJson) as Map<String, dynamic>,
        );
      } catch (e) {
        debugPrint('Pending registration branch parse failed: $e');
      }
    }
    branch ??= BranchAssignmentService.central(source: 'pending_fallback');

    try {
      final collectionName = _collectionForServiceName(serviceType);
      final branchFields = branch.toFirestoreFields();

      await FirebaseFirestore.instance
          .collection('contracts')
          .doc(user.uid)
          .set(
            {
              'serviceType': serviceType,
              'status': 'pending_acceptance',
              ...branchFields,
              'createdAt': FieldValue.serverTimestamp(),
            },
            SetOptions(merge: true),
          );

      await FirebaseFirestore.instance
          .collection(collectionName)
          .doc(user.uid)
          .set(
            {
              'email': user.email ?? '',
              'phone': user.phoneNumber ?? '',
              'serviceType': serviceType,
              'userId': user.uid,
              ...branchFields,
              'createdAt': FieldValue.serverTimestamp(),
              'status': 'pending_contract',
              'isProfileCompleted': false,
            },
            SetOptions(merge: true),
          );

      await prefs.remove(_keyServiceType);
      await prefs.remove(_keyBranchJson);
      return serviceType;
    } catch (e) {
      debugPrint('Pending registration apply failed: $e');
      return serviceType;
    }
  }

  static Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyServiceType);
    await prefs.remove(_keyBranchJson);
  }

  static String _collectionForServiceName(String serviceType) {
    switch (serviceType) {
      case 'ตลาด':
        return 'market_registrations';
      case 'ร้านค้า':
        return 'shop_registrations';
      case 'ร้านอาหาร':
        return 'restaurant_registrations';
      case 'ร้านขายยา':
        return 'pharmacy_registrations';
      default:
        return 'shop_registrations';
    }
  }

  static Map<String, dynamic> _branchToJson(BranchAssignment branch) {
    return {
      'branchId': branch.branchId,
      'branchName': branch.branchName,
      'latitude': branch.latitude,
      'longitude': branch.longitude,
      'distanceKm': branch.distanceKm,
      'source': branch.source,
    };
  }

  static BranchAssignment _branchFromJson(Map<String, dynamic> json) {
    return BranchAssignment(
      branchId: (json['branchId'] as String?) ?? BranchAssignmentService.defaultBranchId,
      branchName: json['branchName'] as String?,
      latitude: (json['latitude'] as num?)?.toDouble(),
      longitude: (json['longitude'] as num?)?.toDouble(),
      distanceKm: (json['distanceKm'] as num?)?.toDouble(),
      source: (json['source'] as String?) ?? 'pending',
    );
  }
}
