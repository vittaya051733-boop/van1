import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

class PendingTopUpDraft {
  const PendingTopUpDraft({
    required this.amount,
    required this.isSecurityDeposit,
    this.minimumAmount,
  });

  final double amount;
  final bool isSecurityDeposit;
  final double? minimumAmount;
}

/// Remembers a confirmed top-up so the merchant can leave to pay
/// (bank app) and return to the same slip-upload step.
class PendingTopUpSession {
  PendingTopUpSession._();

  static const String _prefsKey = 'merchant_pending_topup_v1';
  static const Duration _maxAge = Duration(hours: 24);

  static bool _memoryActive = false;
  static bool _dialogOpen = false;
  static bool _restoreInFlight = false;

  static bool get isActive => _memoryActive;
  static bool get isDialogOpen => _dialogOpen;
  static bool get isRestoreInFlight => _restoreInFlight;

  static void markDialogOpen() => _dialogOpen = true;
  static void markDialogClosed() => _dialogOpen = false;

  static void beginRestore() => _restoreInFlight = true;
  static void endRestore() => _restoreInFlight = false;

  static void markActive() => _memoryActive = true;

  static Future<void> save({
    required double amount,
    required bool isSecurityDeposit,
    double? minimumAmount,
  }) async {
    if (amount <= 0) return;
    _memoryActive = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _prefsKey,
        jsonEncode(<String, dynamic>{
          'amount': amount,
          'isSecurityDeposit': isSecurityDeposit,
          'minimumAmount': minimumAmount,
          'savedAt': DateTime.now().millisecondsSinceEpoch,
        }),
      );
    } catch (_) {}
  }

  static Future<PendingTopUpDraft?> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      if (raw == null || raw.isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final map = Map<String, dynamic>.from(decoded);
      final amount = (map['amount'] as num?)?.toDouble() ?? 0;
      final savedAt = (map['savedAt'] as num?)?.toInt() ?? 0;
      if (amount <= 0 || savedAt <= 0) {
        await clear();
        return null;
      }
      final age = DateTime.now().difference(
        DateTime.fromMillisecondsSinceEpoch(savedAt),
      );
      if (age > _maxAge) {
        await clear();
        return null;
      }
      return PendingTopUpDraft(
        amount: amount,
        isSecurityDeposit: map['isSecurityDeposit'] == true,
        minimumAmount: (map['minimumAmount'] as num?)?.toDouble(),
      );
    } catch (_) {
      return null;
    }
  }

  static Future<void> clear() async {
    _memoryActive = false;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_prefsKey);
    } catch (_) {}
  }
}
