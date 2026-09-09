import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../merchant_pricing_policy.dart';
import '../utils/settlement_payout_support.dart';

class WalletHistoryItem {
  const WalletHistoryItem({
    required this.title,
    required this.amount,
    required this.icon,
    required this.color,
    this.subtitle,
    this.happenedAt,
  });

  final String title;
  final String? subtitle;
  final double amount;
  final DateTime? happenedAt;
  final IconData icon;
  final Color color;
}

class WalletTodayIncome {
  const WalletTodayIncome({
    required this.deliveredCount,
    required this.productRevenue,
  });

  final int deliveredCount;
  final double productRevenue;

  static const zero = WalletTodayIncome(deliveredCount: 0, productRevenue: 0);
}

class WalletHistoryLoadResult {
  const WalletHistoryLoadResult({
    required this.items,
    required this.today,
    this.fromCache = false,
  });

  final List<WalletHistoryItem> items;
  final WalletTodayIncome today;
  final bool fromCache;
}

/// Loads wallet history with simple Firestore queries (no composite index).
class WalletHistoryLoader {
  WalletHistoryLoader._();

  static final WalletHistoryLoader instance = WalletHistoryLoader._();

  static const int queryLimit = 100;
  static const int visibleLimit = 50;

  Future<WalletHistoryLoadResult> loadMerchantHistory({
    required String uid,
    void Function(WalletHistoryLoadResult result)? onUpdate,
  }) async {
    final trimmedUid = uid.trim();
    if (trimmedUid.isEmpty) {
      const empty = WalletHistoryLoadResult(
        items: <WalletHistoryItem>[],
        today: WalletTodayIncome.zero,
      );
      onUpdate?.call(empty);
      return empty;
    }

    void publish(WalletHistoryLoadResult result) {
      onUpdate?.call(result);
    }

    final creditsQuery = FirebaseFirestore.instance
        .collection('credits')
        .where('uid', isEqualTo: trimmedUid)
        .limit(queryLimit);
    final ownerOrdersQuery = FirebaseFirestore.instance
        .collection('orders')
        .where('shopOwnerId', isEqualTo: trimmedUid)
        .limit(queryLimit);
    final shopOrdersQuery = FirebaseFirestore.instance
        .collection('orders')
        .where('shopId', isEqualTo: trimmedUid)
        .limit(queryLimit);

    final cachedResults = await Future.wait([
      _readCache(creditsQuery),
      _readCache(ownerOrdersQuery),
      _readCache(shopOrdersQuery),
    ]);
    final cachedCredits = cachedResults[0];
    final cachedOwnerOrders = cachedResults[1];
    final cachedShopOrders = cachedResults[2];
    final cachedOrders = _mergeOrderDocs(cachedOwnerOrders, cachedShopOrders);

    // Always publish cache (including an empty cache) so the UI never leaves
    // a spinner running while the network refresh is in progress.
    final cachedResult = _buildResult(
      creditDocs: cachedCredits,
      orderDocs: cachedOrders,
      fromCache: true,
    );
    publish(cachedResult);

    final serverResults = await Future.wait([
      _readServer(creditsQuery),
      _readServer(ownerOrdersQuery),
      _readServer(shopOrdersQuery),
    ]);
    final serverCredits = serverResults[0];
    final serverOwnerOrders = serverResults[1];
    final serverShopOrders = serverResults[2];
    final serverOrders = _mergeOrderDocs(serverOwnerOrders, serverShopOrders);

    // Keep cached data if every server query failed or timed out.
    if (serverCredits.isEmpty &&
        serverOrders.isEmpty &&
        (cachedCredits.isNotEmpty || cachedOrders.isNotEmpty)) {
      return cachedResult;
    }

    final fresh = _buildResult(
      creditDocs: serverCredits,
      orderDocs: serverOrders,
      fromCache: false,
    );
    publish(fresh);
    return fresh;
  }

  Stream<void> watchCreditsChanges(String uid) {
    final trimmedUid = uid.trim();
    if (trimmedUid.isEmpty) {
      return const Stream<void>.empty();
    }

    return FirebaseFirestore.instance
        .collection('credits')
        .where('uid', isEqualTo: trimmedUid)
        .limit(queryLimit)
        .snapshots()
        .skip(1)
        .map((_) {});
  }

  Future<List<QueryDocumentSnapshot<Map<String, dynamic>>>> _readCache(
    Query<Map<String, dynamic>> query,
  ) async {
    try {
      final snapshot = await query
          .get(const GetOptions(source: Source.cache))
          .timeout(const Duration(milliseconds: 700));
      return snapshot.docs;
    } catch (_) {
      return const <QueryDocumentSnapshot<Map<String, dynamic>>>[];
    }
  }

  Future<List<QueryDocumentSnapshot<Map<String, dynamic>>>> _readServer(
    Query<Map<String, dynamic>> query,
  ) async {
    try {
      final snapshot = await query
          .get(const GetOptions(source: Source.server))
          .timeout(const Duration(seconds: 6));
      return snapshot.docs;
    } catch (_) {
      return const <QueryDocumentSnapshot<Map<String, dynamic>>>[];
    }
  }

  List<QueryDocumentSnapshot<Map<String, dynamic>>> _mergeOrderDocs(
    List<QueryDocumentSnapshot<Map<String, dynamic>>> first,
    List<QueryDocumentSnapshot<Map<String, dynamic>>> second,
  ) {
    final merged = <String, QueryDocumentSnapshot<Map<String, dynamic>>>{};
    for (final doc in first) {
      merged[doc.id] = doc;
    }
    for (final doc in second) {
      merged[doc.id] = doc;
    }
    return merged.values.toList(growable: false);
  }

  WalletHistoryLoadResult _buildResult({
    required List<QueryDocumentSnapshot<Map<String, dynamic>>> creditDocs,
    required List<QueryDocumentSnapshot<Map<String, dynamic>>> orderDocs,
    required bool fromCache,
  }) {
    final items = <WalletHistoryItem>[];

    for (final doc in creditDocs) {
      final item = _creditItem(doc.data());
      if (item != null) {
        items.add(item);
      }
    }

    for (final doc in orderDocs) {
      final item = _orderItem(doc.data());
      if (item != null) {
        items.add(item);
      }
    }

    items.sort((a, b) {
      final at = a.happenedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      final bt = b.happenedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      return bt.compareTo(at);
    });

    return WalletHistoryLoadResult(
      items: items.take(visibleLimit).toList(growable: false),
      today: _computeTodayIncome(orderDocs),
      fromCache: fromCache,
    );
  }

  WalletHistoryItem? _creditItem(Map<String, dynamic> data) {
    final amount = _toDouble(data['amount']) ?? 0;
    final provider = data['provider']?.toString().trim().toLowerCase();
    final status = data['status']?.toString().trim().toLowerCase();
    final paymentGroupId = data['paymentGroupId']?.toString().trim();
    final slipFeedbackId = data['slipFeedbackId']?.toString().trim();
    final creditType = data['type']?.toString().trim();
    final orderId = data['orderId']?.toString().trim();
    final isTopUp = amount >= 0;

    var title = isTopUp ? 'เติมเครดิต' : 'หักเครดิต';
    if (creditType == 'order_cod_shop_credit_release') {
      title = 'รายได้ค่าสินค้า';
    } else if (creditType == 'withdraw_hold') {
      title = 'กันเงินถอน';
    } else if (provider == 'slipok' && status == 'verified') {
      title = 'เติมเครดิต (ตรวจสลิป)';
    } else if (provider != null && provider.isNotEmpty) {
      title = '$title ($provider)';
    }

    final subtitleParts = <String>[];
    if (orderId != null && orderId.isNotEmpty) {
      subtitleParts.add('ออเดอร์: ${_compactHistoryReference(orderId)}');
    }
    final slipRef = _pickSlipHistoryReference(
      paymentGroupId: paymentGroupId,
      slipFeedbackId: slipFeedbackId,
    );
    if (slipRef != null) {
      subtitleParts.add('อ้างอิง: $slipRef');
    }

    return WalletHistoryItem(
      title: title,
      subtitle: subtitleParts.isEmpty ? null : subtitleParts.join(' • '),
      amount: amount,
      happenedAt: _toDateTime(data['timestamp']),
      icon: isTopUp ? Icons.add_circle_outline : Icons.remove_circle_outline,
      color: isTopUp ? Colors.green : Colors.redAccent,
    );
  }

  WalletHistoryItem? _orderItem(Map<String, dynamic> data) {
    if (data['status']?.toString().trim() != 'delivered') {
      return null;
    }
    if (!shouldShowShopOrderRevenueInWallet(data)) {
      return null;
    }

    final productRevenue =
        MerchantPricingPolicy.readMerchantProductRevenue(data);
    if (productRevenue <= 0) {
      return null;
    }

    final orderCode = data['orderCode']?.toString().trim();
    return WalletHistoryItem(
      title: 'รายได้ค่าสินค้า',
      subtitle: orderCode == null || orderCode.isEmpty
          ? 'ออเดอร์ส่งสำเร็จ'
          : 'ออเดอร์: $orderCode',
      amount: productRevenue,
      happenedAt: shopOrderRevenueWalletTimestamp(data),
      icon: Icons.shopping_bag_outlined,
      color: const Color(0xFFE95500),
    );
  }

  WalletTodayIncome _computeTodayIncome(
    List<QueryDocumentSnapshot<Map<String, dynamic>>> orderDocs,
  ) {
    var deliveredTodayCount = 0;
    var productRevenueToday = 0.0;
    final now = DateTime.now();

    for (final doc in orderDocs) {
      final data = doc.data();
      if (data['status']?.toString().trim() != 'delivered') {
        continue;
      }

      final deliveredAt = _orderDeliveredAt(data);
      if (deliveredAt == null ||
          deliveredAt.year != now.year ||
          deliveredAt.month != now.month ||
          deliveredAt.day != now.day) {
        continue;
      }

      deliveredTodayCount += 1;
      productRevenueToday +=
          MerchantPricingPolicy.readMerchantProductRevenue(data);
    }

    return WalletTodayIncome(
      deliveredCount: deliveredTodayCount,
      productRevenue: productRevenueToday,
    );
  }

  DateTime? _orderDeliveredAt(Map<String, dynamic> data) {
    return _toDateTime(data['deliveredAt']) ??
        _toDateTime(data['deliveryCompletedAt']) ??
        _toDateTime(data['updatedAt']) ??
        _toDateTime(data['createdAt']);
  }

  String? _pickSlipHistoryReference({
    String? paymentGroupId,
    String? slipFeedbackId,
  }) {
    final payment = paymentGroupId?.trim();
    final slip = slipFeedbackId?.trim();
    if (payment != null && payment.isNotEmpty) {
      return _compactHistoryReference(payment);
    }
    if (slip != null && slip.isNotEmpty) {
      return _compactHistoryReference(slip);
    }
    return null;
  }

  String _compactHistoryReference(String value) {
    final trimmed = value.trim();
    if (trimmed.length <= 20) {
      return trimmed;
    }
    return '…${trimmed.substring(trimmed.length - 8)}';
  }

  DateTime? _toDateTime(Object? value) {
    if (value is Timestamp) {
      return value.toDate();
    }
    if (value is DateTime) {
      return value;
    }
    if (value is String) {
      return DateTime.tryParse(value);
    }
    return null;
  }

  double? _toDouble(Object? value) {
    if (value is num) {
      return value.toDouble();
    }
    if (value is String) {
      return double.tryParse(value.trim());
    }
    return null;
  }
}
