import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../models/order_model.dart';
import '../wallet_top_up_dialog.dart';
import 'wallet_balance_loader.dart';

enum ShopOrderCreditDecision { accept, reject, abort }

enum _CreditChoice { topUp, reject }

class ShopOrderCreditGate {
  ShopOrderCreditGate._();

  static const double _maxTopUpAmount = 5000;

  static double productAmount(DetailedOrder order) {
    final itemTotal = order.items.fold<double>(
      0,
      (sum, item) => sum + (item.price * item.quantity),
    );
    if (itemTotal > 0) return itemTotal;
    final fromGrandTotal = order.totalAmount - order.shippingFee;
    return fromGrandTotal > 0 ? fromGrandTotal : order.totalAmount;
  }

  static Future<double> loadCredit(String uid) async {
    final view = await WalletBalanceLoader.instance.loadBalanced(
      uid: uid,
      actorType: 'merchant',
    );
    return view.creditTotal;
  }

  static Future<bool> hasEnoughCredit(DetailedOrder order) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return false;
    final needed = productAmount(order);
    if (needed <= 0) return true;
    try {
      final credit = await loadCredit(uid);
      return credit + 0.009 >= needed;
    } catch (_) {
      return false;
    }
  }

  static Future<ShopOrderCreditDecision> ensureCanAccept({
    required BuildContext context,
    required DetailedOrder order,
  }) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return ShopOrderCreditDecision.abort;

    final needed = productAmount(order);
    var credit = 0.0;
    try {
      credit = await loadCredit(uid);
    } catch (_) {}

    if (needed <= 0 || credit + 0.009 >= needed) {
      return ShopOrderCreditDecision.accept;
    }
    if (!context.mounted) return ShopOrderCreditDecision.abort;

    final action = await showDialog<_CreditChoice>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('เครดิตไม่พอรับออเดอร์'),
          content: Text(
            'ราคาสินค้า ฿${needed.toStringAsFixed(2)}\n'
            'เครดิตคงเหลือ ฿${credit.toStringAsFixed(2)}\n\n'
            'เลือกเติมเครดิต หรือปฏิเสธออเดอร์ไปก่อน',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(
                _CreditChoice.reject,
              ),
              child: const Text('ปฏิเสธออเดอร์ไปก่อน'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(
                _CreditChoice.topUp,
              ),
              child: const Text('เติมเครดิต'),
            ),
          ],
        );
      },
    );

    if (action == _CreditChoice.reject) {
      return ShopOrderCreditDecision.reject;
    }
    if (action != _CreditChoice.topUp) {
      return ShopOrderCreditDecision.abort;
    }
    if (!context.mounted) return ShopOrderCreditDecision.abort;

    final shortfall = (needed - credit).clamp(1, _maxTopUpAmount).toDouble();
    final toppedUp = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => WalletTopUpDialog(initialAmount: shortfall),
    );
    if (toppedUp == true && context.mounted) {
      return ensureCanAccept(context: context, order: order);
    }
    return ShopOrderCreditDecision.abort;
  }
}
