import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';

import 'models/order_model.dart';
import 'admin_support_thread_screen.dart';
import 'services/notification_service.dart';
import 'services/shop_order_credit_gate.dart';
import 'wallet_screen.dart';

enum _NotificationCategory {
  order,
  chat,
  call,
  system,
}

enum _NotificationFilter {
  all,
  unread,
  chat,
  order,
  call,
  system,
}

class NotificationsScreen extends StatefulWidget {
  const NotificationsScreen({Key? key}) : super(key: key);

  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<NotificationsScreen> {
  static const String _targetApp = 'van1';
  static const Set<String> _walletActions = {
    'payout_pending',
    'payout_paid',
    'credit_released',
    'top_up_verified',
    'credit_adjusted',
    'security_deposit_paid',
  };
  User? _currentUser;
  final NotificationService _notificationService = NotificationService();
  _NotificationFilter _selectedFilter = _NotificationFilter.all;

  Stream<QuerySnapshot<Map<String, dynamic>>>? get _notificationsStream {
    final uid = _currentUser?.uid;
    if (uid == null || uid.isEmpty) {
      return null;
    }
    return FirebaseFirestore.instance
        .collection('app_notifications')
        .where('targetApp', isEqualTo: _targetApp)
        .where('recipientUid', isEqualTo: uid)
        .snapshots();
  }

  Stream<QuerySnapshot<Map<String, dynamic>>>? get _shopOwnerOrdersStream {
    final uid = _currentUser?.uid;
    if (uid == null || uid.isEmpty) {
      return null;
    }
    return FirebaseFirestore.instance
        .collection('orders')
        .where('shopOwnerId', isEqualTo: uid)
        .snapshots();
  }

  Stream<QuerySnapshot<Map<String, dynamic>>>? get _shopIdOrdersStream {
    final uid = _currentUser?.uid;
    if (uid == null || uid.isEmpty) {
      return null;
    }
    return FirebaseFirestore.instance
        .collection('orders')
        .where('shopId', isEqualTo: uid)
        .snapshots();
  }

  @override
  void initState() {
    super.initState();
    _currentUser = FirebaseAuth.instance.currentUser;
  }

  Future<void> _markAppNotificationRead(String id) async {
    await _notificationService.markAppNotificationRead(id);
  }

  bool _shouldHideUnverifiedPromptPayOrder(Map<String, dynamic> data) {
    final paymentMethod = (data['paymentMethod'] as String?)?.trim() ?? '';
    final paymentStatus = (data['paymentStatus'] as String?)?.trim() ?? '';

    return paymentMethod == 'promptpay_qr' &&
        paymentStatus.isNotEmpty &&
        paymentStatus != 'verified';
  }

  bool _isAwaitingShopDecisionData(Map<String, dynamic> data) {
    final status = (data['status'] as String?)?.trim() ?? '';
    final driverId = (data['driverId'] as String?)?.trim() ?? '';
    return status == 'accepted' &&
        driverId.isNotEmpty &&
        data['preparingStartTime'] == null &&
        data['shopDecisionStatus'] != 'rejected' &&
        data['shopRejectedAt'] == null;
  }

  bool _isShopOrderForCurrentUser(Map<String, dynamic> data) {
    final shopId = (data['shopId'] as String?)?.trim();
    final shopOwnerId = (data['shopOwnerId'] as String?)?.trim();
    return shopId == _currentUser?.uid || shopOwnerId == _currentUser?.uid;
  }

  _NotificationCategory _resolveCategory(Map<String, dynamic> data) {
    final action = (data['action'] as String?)?.trim() ?? '';
    final type = (data['type'] as String?)?.trim() ?? '';
    final hasOrderId = (data['orderId'] as String?)?.trim().isNotEmpty == true;

    if (type == 'chat' || action == 'chat_message') {
      return _NotificationCategory.chat;
    }
    if (action == 'admin_support_reply') {
      return _NotificationCategory.system;
    }
    if (type == 'call' || action == 'incoming_call') {
      return _NotificationCategory.call;
    }
    if (_walletActions.contains(action)) {
      return _NotificationCategory.system;
    }
    if (hasOrderId ||
        <String>{
          'order_accepted',
          'order_rejected',
          'shop_rejected_order',
          'shop_accepted_order',
          'low_stock_alert',
        }.contains(action)) {
      return _NotificationCategory.order;
    }
    return _NotificationCategory.system;
  }

  String _categoryTitle(_NotificationCategory category) {
    switch (category) {
      case _NotificationCategory.order:
        return 'ออเดอร์';
      case _NotificationCategory.chat:
        return 'แชต';
      case _NotificationCategory.call:
        return 'สายเข้า';
      case _NotificationCategory.system:
        return 'ระบบ';
    }
  }

  IconData _categoryIcon(_NotificationCategory category) {
    switch (category) {
      case _NotificationCategory.order:
        return Icons.receipt_long_outlined;
      case _NotificationCategory.chat:
        return Icons.chat_bubble_outline;
      case _NotificationCategory.call:
        return Icons.call_outlined;
      case _NotificationCategory.system:
        return Icons.campaign_outlined;
    }
  }

  Color _categoryColor(_NotificationCategory category) {
    switch (category) {
      case _NotificationCategory.order:
        return Colors.orange;
      case _NotificationCategory.chat:
        return Colors.blue;
      case _NotificationCategory.call:
        return Colors.green;
      case _NotificationCategory.system:
        return Colors.deepPurple;
    }
  }

  String _filterLabel(_NotificationFilter filter) {
    switch (filter) {
      case _NotificationFilter.all:
        return 'ทั้งหมด';
      case _NotificationFilter.unread:
        return 'ยังไม่อ่าน';
      case _NotificationFilter.chat:
        return 'แชต';
      case _NotificationFilter.order:
        return 'ออเดอร์';
      case _NotificationFilter.call:
        return 'สายเข้า';
      case _NotificationFilter.system:
        return 'ระบบ';
    }
  }

  bool _matchesFilter(QueryDocumentSnapshot<Map<String, dynamic>> notification) {
    final data = notification.data();
    switch (_selectedFilter) {
      case _NotificationFilter.all:
        return true;
      case _NotificationFilter.unread:
        return data['read'] != true;
      case _NotificationFilter.chat:
        return _resolveCategory(data) == _NotificationCategory.chat;
      case _NotificationFilter.order:
        return _resolveCategory(data) == _NotificationCategory.order;
      case _NotificationFilter.call:
        return _resolveCategory(data) == _NotificationCategory.call;
      case _NotificationFilter.system:
        return _resolveCategory(data) == _NotificationCategory.system;
    }
  }

  Future<void> _markAllNotificationsRead(
    List<QueryDocumentSnapshot<Map<String, dynamic>>> notifications,
  ) async {
    final unread = notifications.where((notification) {
      return notification.data()['read'] != true;
    }).toList(growable: false);
    if (unread.isEmpty) {
      return;
    }

    final batch = FirebaseFirestore.instance.batch();
    for (final notification in unread) {
      batch.set(notification.reference, <String, dynamic>{
        'read': true,
        'readAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    }
    await batch.commit();
  }

  Widget _buildFilterChips(
    List<QueryDocumentSnapshot<Map<String, dynamic>>> notifications,
  ) {
    final unreadCount = notifications.where((notification) {
      return notification.data()['read'] != true;
    }).length;
    final chatCount = notifications.where((notification) {
      return _resolveCategory(notification.data()) == _NotificationCategory.chat;
    }).length;
    final orderCount = notifications.where((notification) {
      return _resolveCategory(notification.data()) == _NotificationCategory.order;
    }).length;
    final callCount = notifications.where((notification) {
      return _resolveCategory(notification.data()) == _NotificationCategory.call;
    }).length;
    final systemCount = notifications.where((notification) {
      return _resolveCategory(notification.data()) == _NotificationCategory.system;
    }).length;
    final counts = <_NotificationFilter, int>{
      _NotificationFilter.all: notifications.length,
      _NotificationFilter.unread: unreadCount,
      _NotificationFilter.chat: chatCount,
      _NotificationFilter.order: orderCount,
      _NotificationFilter.call: callCount,
      _NotificationFilter.system: systemCount,
    };

    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
        children: _NotificationFilter.values.map((filter) {
          final selected = filter == _selectedFilter;
          final count = counts[filter] ?? 0;
          return Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilterChip(
              selected: selected,
              showCheckmark: false,
              label: Text('${_filterLabel(filter)} ($count)'),
              selectedColor: Theme.of(context).colorScheme.primary.withValues(alpha: 0.14),
              backgroundColor: Colors.white,
              side: BorderSide(
                color: selected
                    ? Theme.of(context).colorScheme.primary
                    : Colors.grey.shade300,
              ),
              labelStyle: TextStyle(
                fontWeight: FontWeight.w600,
                color: selected
                    ? Theme.of(context).colorScheme.primary
                    : Colors.black87,
              ),
              onSelected: (_) {
                setState(() => _selectedFilter = filter);
              },
            ),
          );
        }).toList(growable: false),
      ),
    );
  }

  Future<void> _handleNotificationTap(
    QueryDocumentSnapshot<Map<String, dynamic>> notificationDoc,
  ) async {
    final data = notificationDoc.data();
    final category = _resolveCategory(data);
    final isRead = data['read'] == true;
    if (!isRead) {
      await _markAppNotificationRead(notificationDoc.id);
    }

    final action = (data['action'] as String?)?.trim() ?? '';
    if (_walletActions.contains(action)) {
      if (!mounted) {
        return;
      }
      await Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => const WalletScreen()),
      );
      return;
    }
    if (action == 'admin_support_reply') {
      final ticketId = (data['ticketId'] as String?)?.trim();
      if (!mounted) {
        return;
      }
      if (ticketId == null || ticketId.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('แจ้งเตือนนี้ไม่มีรหัสข้อความ')),
        );
        return;
      }
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => AdminSupportThreadScreen(
            ticketId: ticketId,
            accentColor: const Color(0xFF2563EB),
          ),
        ),
      );
      return;
    }

    switch (category) {
      case _NotificationCategory.chat:
        await _notificationService.openChatFromNotificationData(data);
        return;
      case _NotificationCategory.call:
        if (!mounted) return;
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => _CallNotificationDetailScreen(data: data),
          ),
        );
        return;
      case _NotificationCategory.order:
        _notificationService.openOrderManagement(
          (data['orderId'] as String?)?.trim(),
        );
        return;
      case _NotificationCategory.system:
        final orderId = (data['orderId'] as String?)?.trim();
        if (orderId != null && orderId.isNotEmpty) {
          _notificationService.openOrderManagement(orderId);
        }
        return;
    }
  }

  Widget _buildCategorySection({
    required _NotificationCategory category,
    required List<QueryDocumentSnapshot<Map<String, dynamic>>> notifications,
  }) {
    if (notifications.isEmpty) {
      return const SizedBox.shrink();
    }

    final color = _categoryColor(category);
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
            child: Row(
              children: [
                Icon(_categoryIcon(category), color: color, size: 20),
                const SizedBox(width: 8),
                Text(
                  _categoryTitle(category),
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    '${notifications.length}',
                    style: TextStyle(
                      color: color,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          ),
          ...notifications.map(_buildNotificationCard),
        ],
      ),
    );
  }

  Widget _buildOptionalPendingOrdersSection() {
    final shopOwnerOrdersStream = _shopOwnerOrdersStream;
    final shopIdOrdersStream = _shopIdOrdersStream;
    if (shopOwnerOrdersStream == null || shopIdOrdersStream == null) {
      return const SizedBox.shrink();
    }

    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: shopOwnerOrdersStream,
      builder: (context, ownerSnapshot) {
        return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: shopIdOrdersStream,
          builder: (context, shopSnapshot) {
            final mergedOrders =
                <String, QueryDocumentSnapshot<Map<String, dynamic>>>{
              if (!ownerSnapshot.hasError)
                for (final doc in (ownerSnapshot.data?.docs ??
                    <QueryDocumentSnapshot<Map<String, dynamic>>>[]))
                  doc.id: doc,
              if (!shopSnapshot.hasError)
                for (final doc in (shopSnapshot.data?.docs ??
                    <QueryDocumentSnapshot<Map<String, dynamic>>>[]))
                  doc.id: doc,
            };

            final pendingOrders = mergedOrders.values
                .where((doc) {
                  final data = doc.data();
                  return _isShopOrderForCurrentUser(data) &&
                      !_shouldHideUnverifiedPromptPayOrder(data) &&
                      _isAwaitingShopDecisionData(data);
                })
                .toList(growable: false)
              ..sort((a, b) {
                final aTime =
                    (a.data()['timestamp'] as Timestamp?)
                        ?.millisecondsSinceEpoch ??
                    0;
                final bTime =
                    (b.data()['timestamp'] as Timestamp?)
                        ?.millisecondsSinceEpoch ??
                    0;
                return bTime.compareTo(aTime);
              });

            return _buildPendingOrdersSection(pendingOrders);
          },
        );
      },
    );
  }

  Widget _buildPendingOrdersSection(
    List<QueryDocumentSnapshot<Map<String, dynamic>>> orders,
  ) {
    if (orders.isEmpty) {
      return const SizedBox.shrink();
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
            child: Row(
              children: [
                const Icon(
                  Icons.storefront_outlined,
                  color: Colors.orange,
                  size: 20,
                ),
                const SizedBox(width: 8),
                const Text(
                  'ออเดอร์รอร้านยืนยัน',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.orange.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    '${orders.length}',
                    style: const TextStyle(
                      color: Colors.orange,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          ),
          ...orders.map(_buildPendingOrderCard),
        ],
      ),
    );
  }

  String _formatCreatedAt(Timestamp? timestamp) {
    final createdAt = timestamp?.toDate();
    if (createdAt == null) {
      return 'ไม่มีข้อมูลเวลา';
    }
    try {
      return DateFormat('d MMM y, HH:mm', 'th_TH').format(createdAt);
    } catch (_) {
      return DateFormat('d MMM y, HH:mm').format(createdAt);
    }
  }

  Future<void> _acceptOrderFromNotification({
    required DetailedOrder order,
    String? notificationId,
  }) async {
    try {
      final decision = await ShopOrderCreditGate.ensureCanAccept(
        context: context,
        order: order,
      );
      if (!mounted) return;
      if (decision == ShopOrderCreditDecision.reject) {
        await _rejectOrderFromNotification(
          order: order,
          notificationId: notificationId,
        );
        return;
      }
      if (decision != ShopOrderCreditDecision.accept) {
        return;
      }
      await _notificationService.acceptShopOrder(
        order,
        notificationId: notificationId,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('รับออเดอร์เรียบร้อยแล้ว')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('เกิดข้อผิดพลาด: $e'),
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
      );
    }
  }

  Future<void> _rejectOrderFromNotification({
    required DetailedOrder order,
    String? notificationId,
  }) async {
    try {
      await _notificationService.rejectShopOrder(
        order,
        notificationId: notificationId,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('ปฏิเสธออเดอร์แล้ว')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('เกิดข้อผิดพลาด: $e'),
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final notificationsStream = _notificationsStream;
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        title: const Text('การแจ้งเตือน'),
        automaticallyImplyLeading: false,
        actions: [
          if (notificationsStream != null)
            StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream: notificationsStream,
              builder: (context, snapshot) {
                final notifications =
                    (snapshot.data?.docs ??
                            <QueryDocumentSnapshot<Map<String, dynamic>>>[])
                        .toList(growable: false);
                final unreadCount = notifications.where((notification) {
                  return notification.data()['read'] != true;
                }).length;
                return TextButton(
                  onPressed: unreadCount == 0
                      ? null
                      : () => _markAllNotificationsRead(notifications),
                  child: Text(
                    'อ่านทั้งหมด',
                    style: TextStyle(
                      color: unreadCount == 0 ? Colors.grey : Colors.white,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                );
              },
            ),
        ],
      ),
      body: _currentUser == null
          ? const Center(child: Text('กรุณาเข้าสู่ระบบเพื่อดูการแจ้งเตือน'))
          : StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream: notificationsStream,
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting &&
                    !snapshot.hasData &&
                    !snapshot.hasError) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    final notifs =
                      (snapshot.hasError ?
                          <QueryDocumentSnapshot<Map<String, dynamic>>>[] :
                          snapshot.data?.docs ??
                                <QueryDocumentSnapshot<Map<String, dynamic>>>[])
                            .toList(growable: false);

                    notifs.sort((a, b) {
                      final aTime =
                          (a.data()['createdAt'] as Timestamp?)
                              ?.millisecondsSinceEpoch ??
                          0;
                      final bTime =
                          (b.data()['createdAt'] as Timestamp?)
                              ?.millisecondsSinceEpoch ??
                          0;
                      return bTime.compareTo(aTime);
                    });

                    if (notifs.isEmpty) {
                      return Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              Icons.notifications_off_outlined,
                              size: 80,
                              color: Colors.grey[400],
                            ),
                            const SizedBox(height: 16),
                            const Text(
                              'ยังไม่มีการแจ้งเตือน',
                              style: TextStyle(
                                fontSize: 18,
                                color: Colors.grey,
                              ),
                            ),
                          ],
                        ),
                      );
                    }

                    final filteredNotifs = notifs
                        .where(_matchesFilter)
                        .toList(growable: false);

                    if (filteredNotifs.isEmpty) {
                      return Column(
                        children: [
                          _buildFilterChips(notifs),
                          Expanded(
                            child: Center(
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(
                                    Icons.filter_list_off,
                                    size: 72,
                                    color: Colors.grey[400],
                                  ),
                                  const SizedBox(height: 16),
                                  Text(
                                    'ไม่มีรายการในตัวกรอง ${_filterLabel(_selectedFilter)}',
                                    style: const TextStyle(
                                      fontSize: 16,
                                      color: Colors.grey,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      );
                    }

                    final grouped = <_NotificationCategory,
                        List<QueryDocumentSnapshot<Map<String, dynamic>>>>{
                      for (final category in _NotificationCategory.values)
                        category: <QueryDocumentSnapshot<Map<String, dynamic>>>[],
                    };
                    for (final notification in filteredNotifs) {
                      grouped[_resolveCategory(notification.data())]!
                          .add(notification);
                    }

                    return ListView(
                      padding: const EdgeInsets.all(8),
                      children: [
                        _buildFilterChips(notifs),
                        _buildOptionalPendingOrdersSection(),
                        _buildCategorySection(
                          category: _NotificationCategory.order,
                          notifications: grouped[_NotificationCategory.order]!,
                        ),
                        _buildCategorySection(
                          category: _NotificationCategory.chat,
                          notifications: grouped[_NotificationCategory.chat]!,
                        ),
                        _buildCategorySection(
                          category: _NotificationCategory.call,
                          notifications: grouped[_NotificationCategory.call]!,
                        ),
                        _buildCategorySection(
                          category: _NotificationCategory.system,
                          notifications: grouped[_NotificationCategory.system]!,
                        ),
                      ],
                    );
              },
            ),
    );
  }

  Widget _buildPendingOrderCard(
    QueryDocumentSnapshot<Map<String, dynamic>> order,
  ) {
    final data = order.data();
    final timestamp = (data['timestamp'] as Timestamp?)?.toDate();
    final formattedDate = timestamp == null
        ? 'ไม่มีข้อมูลเวลา'
        : _formatCreatedAt(Timestamp.fromDate(timestamp));

    return Card(
      elevation: 3,
      margin: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'ออเดอร์ใหม่ #${order.id.substring(0, 6)}',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text('เวลา: $formattedDate'),
            Text('จำนวน: ${(data['products'] as List?)?.length ?? 0} รายการ'),
            Text('ยอดรวม: ฿${(data['totalPrice'] as num?)?.toStringAsFixed(2) ?? 'N/A'}'),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () async {
                    final actionableOrder = await _notificationService
                        .loadActionableShopOrder(order.id);
                    if (!mounted || actionableOrder == null) return;
                    await _rejectOrderFromNotification(order: actionableOrder);
                  },
                  child: Text(
                    'ปฏิเสธ',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton.icon(
                  onPressed: () async {
                    final actionableOrder = await _notificationService
                        .loadActionableShopOrder(order.id);
                    if (!mounted || actionableOrder == null) return;
                    await _acceptOrderFromNotification(order: actionableOrder);
                  },
                  icon: const Icon(Icons.check_circle_outline),
                  label: const Text('รับออเดอร์'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.green,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNotificationCard(
    QueryDocumentSnapshot<Map<String, dynamic>> notificationDoc,
  ) {
    final data = notificationDoc.data();
    final action = (data['action'] as String?)?.trim();
    final orderId = (data['orderId'] as String?)?.trim() ?? '';
    final isRead = data['read'] == true;
    final createdAtLabel = _formatCreatedAt(data['createdAt'] as Timestamp?);
    final category = _resolveCategory(data);
    final iconColor = _categoryColor(category);

    if (action == 'order_accepted' && orderId.isNotEmpty) {
      return FutureBuilder<DetailedOrder?>(
        future: _notificationService.loadActionableShopOrder(orderId),
        builder: (context, snapshot) {
          final order = snapshot.data;
          if (snapshot.connectionState == ConnectionState.waiting) {
            return Card(
              elevation: 2,
              margin: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Padding(
                padding: EdgeInsets.all(16),
                child: Center(child: CircularProgressIndicator()),
              ),
            );
          }

          if (order == null) {
            return Card(
              elevation: 2,
              margin: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              child: _buildStandardNotificationTile(
                notificationDoc: notificationDoc,
                leading: Icon(_categoryIcon(category), color: iconColor),
                title: (data['title'] as String?) ?? 'แจ้งเตือน',
                subtitle: '${(data['body'] as String?) ?? '-'}\n$createdAtLabel',
              ),
            );
          }

          return _buildActionableNotificationOrderCard(
            order: order,
            notificationId: notificationDoc.id,
            title: (data['title'] as String?)?.trim(),
            body: (data['body'] as String?)?.trim(),
          );
        },
      );
    }

    return Card(
      color: isRead ? Colors.grey.shade50 : null,
      elevation: 2,
      margin: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: _buildStandardNotificationTile(
        notificationDoc: notificationDoc,
        leading: Icon(_categoryIcon(category), color: iconColor),
        title: (data['title'] as String?) ?? 'แจ้งเตือน',
        subtitle: '${(data['body'] as String?) ?? '-'}\n$createdAtLabel',
      ),
    );
  }

  Widget _buildStandardNotificationTile({
    required QueryDocumentSnapshot<Map<String, dynamic>> notificationDoc,
    required Widget leading,
    required String title,
    required String subtitle,
  }) {
    final data = notificationDoc.data();
    final isRead = data['read'] == true;
    final category = _resolveCategory(data);
    final canOpen = category != _NotificationCategory.system ||
        ((data['orderId'] as String?)?.trim().isNotEmpty == true);

    return ListTile(
      leading: leading,
      title: Text(title),
      subtitle: Text(subtitle),
      isThreeLine: true,
      onTap: canOpen ? () => _handleNotificationTap(notificationDoc) : null,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (canOpen)
            const Padding(
              padding: EdgeInsets.only(right: 4),
              child: Icon(Icons.chevron_right),
            ),
          IconButton(
            icon: Icon(isRead ? Icons.done_all : Icons.done),
            color: isRead ? Colors.green : null,
            onPressed: isRead
                ? null
                : () => _markAppNotificationRead(notificationDoc.id),
          ),
        ],
      ),
    );
  }

  Widget _buildActionableNotificationOrderCard({
    required DetailedOrder order,
    required String notificationId,
    String? title,
    String? body,
  }) {
    final shortOrderId = order.orderId.substring(
      0,
      order.orderId.length >= 8 ? 8 : order.orderId.length,
    );

    return Card(
      color: order.status == 'accepted' && order.preparingStartTime == null
          ? null
          : Colors.grey.shade50,
      elevation: 3,
      margin: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title?.isNotEmpty == true ? title! : 'มีออเดอร์รอร้านยืนยัน',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            if (body?.isNotEmpty == true) ...<Widget>[
              const SizedBox(height: 8),
              Text(body!),
            ],
            const SizedBox(height: 12),
            Text('ออเดอร์ #$shortOrderId'),
            Text(
              'ลูกค้า: ${order.customerName.isNotEmpty ? order.customerName : '-'}',
            ),
            Text(
              'เบอร์ลูกค้า: ${order.customerPhone.isNotEmpty ? order.customerPhone : '-'}',
            ),
            Text(
              'จุดส่ง: ${order.customerAddress.isNotEmpty ? order.customerAddress : '-'}',
            ),
            Text('จำนวนสินค้า: ${order.totalItems} รายการ'),
            Text('ยอดรวม: ฿${order.totalAmount.toStringAsFixed(2)}'),
            if (order.items.isNotEmpty) ...<Widget>[
              const SizedBox(height: 10),
              const Text(
                'รายการสินค้า',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 6),
              ...order.items.map(
                (item) => Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text('• ${item.productName} x${item.quantity}'),
                ),
              ),
            ],
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => _notificationService.openOrderManagement(order.orderId),
                  child: const Text('เปิดออเดอร์'),
                ),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: () => _rejectOrderFromNotification(
                    order: order,
                    notificationId: notificationId,
                  ),
                  child: Text(
                    'ปฏิเสธ',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton.icon(
                  onPressed: () => _acceptOrderFromNotification(
                    order: order,
                    notificationId: notificationId,
                  ),
                  icon: const Icon(Icons.check_circle_outline),
                  label: const Text('รับออเดอร์'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.green,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _CallNotificationDetailScreen extends StatelessWidget {
  const _CallNotificationDetailScreen({required this.data});

  final Map<String, dynamic> data;

  String _readText(String key, {String fallback = '-'}) {
    final value = data[key]?.toString().trim();
    return value != null && value.isNotEmpty ? value : fallback;
  }

  String _formatTimestamp(Timestamp? timestamp) {
    final date = timestamp?.toDate();
    if (date == null) {
      return 'ไม่มีข้อมูลเวลา';
    }
    try {
      return DateFormat('d MMM y, HH:mm', 'th_TH').format(date);
    } catch (_) {
      return DateFormat('d MMM y, HH:mm').format(date);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isVideo = data['isVideo'] == true || data['callType'] == 'video';
    final createdAt = _formatTimestamp(data['createdAt'] as Timestamp?);
    final callerName = _readText('callerName', fallback: _readText('title', fallback: 'ผู้โทร'));
    final callerId = _readText('callerId');
    final channelId = _readText('channelId');
    final body = _readText('body');

    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        title: const Text('รายละเอียดสายเข้า'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            color: Colors.white,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      CircleAvatar(
                        radius: 24,
                        backgroundColor: Colors.green.withValues(alpha: 0.12),
                        child: Icon(
                          isVideo ? Icons.videocam_outlined : Icons.call_outlined,
                          color: Colors.green,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              callerName,
                              style: const TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(isVideo ? 'วิดีโอคอลเข้า' : 'สายเข้า'),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  _CallDetailRow(label: 'เวลา', value: createdAt),
                  _CallDetailRow(label: 'ข้อความ', value: body),
                  _CallDetailRow(label: 'Caller ID', value: callerId),
                  _CallDetailRow(label: 'Channel', value: channelId),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CallDetailRow extends StatelessWidget {
  const _CallDetailRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              color: Colors.grey.shade600,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: const TextStyle(fontSize: 15),
          ),
        ],
      ),
    );
  }
}
