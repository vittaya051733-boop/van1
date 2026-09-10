import 'dart:async';
import 'dart:math' as math;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

class BranchAssignment {
  const BranchAssignment({
    required this.branchId,
    this.branchName,
    this.latitude,
    this.longitude,
    this.distanceKm,
    this.source = 'fallback',
  });

  final String branchId;
  final String? branchName;
  final double? latitude;
  final double? longitude;
  final double? distanceKm;
  final String source;

  Map<String, dynamic> toFirestoreFields() {
    return <String, dynamic>{
      'branchId': branchId,
      'branchLabel': branchId,
      if (branchName != null && branchName!.trim().isNotEmpty)
        'branchName': branchName!.trim(),
      if (distanceKm != null) 'branchDistanceKm': distanceKm,
      if (latitude != null && longitude != null)
        'branchMatchedFromLocation': <String, double>{
          'latitude': latitude!,
          'longitude': longitude!,
        },
      'branchAssignmentSource': source,
      'branchAssignedAt': FieldValue.serverTimestamp(),
      'marketId': branchId,
    };
  }
}

class BranchAssignmentService {
  BranchAssignmentService._();

  static const String defaultBranchId = 'central';
  static const String defaultBranchName = 'ตลาดโนนสูง';

  static BranchAssignment central({
    double? latitude,
    double? longitude,
    String source = 'fallback',
  }) {
    return BranchAssignment(
      branchId: defaultBranchId,
      branchName: defaultBranchName,
      latitude: latitude,
      longitude: longitude,
      source: source,
    );
  }

  static Future<BranchAssignment> resolveForCurrentLocation() async {
    try {
      final position = await _requestCurrentPosition();
      if (position == null) {
        return central(source: 'location_unavailable');
      }
      return await resolveForCoordinates(
        latitude: position.latitude,
        longitude: position.longitude,
      );
    } catch (e) {
      debugPrint('Branch assignment from current location failed: $e');
      return central(source: 'location_error');
    }
  }

  static Future<BranchAssignment> resolveForCoordinates({
    required double latitude,
    required double longitude,
  }) async {
    try {
      final branches = await FirebaseFirestore.instance
          .collection('branches')
          .where('isActive', isEqualTo: true)
          .get();

      _BranchCandidate? best;
      for (final doc in branches.docs) {
        final candidate = _candidateFromDoc(doc, latitude, longitude);
        if (candidate == null) continue;
        if (best == null || candidate.distanceKm < best.distanceKm) {
          best = candidate;
        }
      }

      if (best == null) {
        return central(
          latitude: latitude,
          longitude: longitude,
          source: 'no_matching_branch',
        );
      }

      return BranchAssignment(
        branchId: best.branchId,
        branchName: best.branchName,
        latitude: latitude,
        longitude: longitude,
        distanceKm: best.distanceKm,
        source: 'matched_by_distance',
      );
    } catch (e) {
      debugPrint('Branch assignment query failed: $e');
      return central(
        latitude: latitude,
        longitude: longitude,
        source: 'branch_query_error',
      );
    }
  }

  static Future<Position?> _requestCurrentPosition() async {
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) return null;

    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      return null;
    }

    return Geolocator.getCurrentPosition(
      desiredAccuracy: LocationAccuracy.high,
      timeLimit: const Duration(seconds: 10),
    ).timeout(
      const Duration(seconds: 12),
      onTimeout: () => throw TimeoutException('GPS timeout'),
    );
  }

  static _BranchCandidate? _candidateFromDoc(
    QueryDocumentSnapshot<Map<String, dynamic>> doc,
    double userLatitude,
    double userLongitude,
  ) {
    final data = doc.data();
    final location = data['gpsLocation'];
    if (location is! Map) return null;

    final branchLatitude = _toDouble(location['latitude']);
    final branchLongitude = _toDouble(location['longitude']);
    final radiusKm = _toDouble(data['deliveryRadiusKm']) ?? 0;
    if (branchLatitude == null || branchLongitude == null || radiusKm <= 0) {
      return null;
    }

    final distanceMeters = Geolocator.distanceBetween(
      userLatitude,
      userLongitude,
      branchLatitude,
      branchLongitude,
    );
    final distanceKm = _roundDistanceKm(distanceMeters / 1000);
    if (distanceKm > radiusKm) return null;

    final rawBranchId = (data['branchId'] ?? doc.id).toString().trim();
    final branchId = rawBranchId.isNotEmpty ? rawBranchId : doc.id;
    final branchName = (data['branchName'] ?? '').toString().trim();

    return _BranchCandidate(
      branchId: branchId,
      branchName: branchName.isEmpty ? null : branchName,
      distanceKm: distanceKm,
    );
  }

  static double? _toDouble(dynamic value) {
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value.trim());
    return null;
  }

  static double _roundDistanceKm(double value) {
    final multiplier = math.pow(10, 3).toDouble();
    return (value * multiplier).round() / multiplier;
  }
}

class _BranchCandidate {
  const _BranchCandidate({
    required this.branchId,
    this.branchName,
    required this.distanceKm,
  });

  final String branchId;
  final String? branchName;
  final double distanceKm;
}
