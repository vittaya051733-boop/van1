import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'services/wallet_balance_loader.dart';
import 'services/wallet_history_loader.dart';
import 'services/merchant_wallet_service.dart';
import 'wallet_top_up_dialog.dart';
import 'wallet_withdraw_dialog.dart';
import 'widgets/security_pin_verify_dialog.dart';

class WalletScreen extends StatefulWidget {
  const WalletScreen({super.key});

  @override
  State<WalletScreen> createState() => _WalletScreenState();
}

class _WalletScreenState extends State<WalletScreen> {
  static const Color _dashboardOrangeTop = Color(0xFFFF8A00);
  static const Color _dashboardOrangeMid = Color(0xFFE95500);
  static const Color _dashboardOrangeBottom = Color(0xFF8F2600);
  static const Color _dashboardCream = Color(0xFFFFF7EE);
  static const Color _dashboardText = Color(0xFF292622);

  double _currentCredit = 0;
  double _withdrawableBalance = 0;
  double _minGrossWithdrawAmount = 11;
  bool _balanceRefreshing = false;
  String? _uid;
  MerchantWalletSnapshot? _walletSnapshot;
  List<WalletHistoryItem> _historyItems = const [];
  WalletTodayIncome _todayIncome = WalletTodayIncome.zero;
  bool _historyLoading = true;
  String? _historyError;
  StreamSubscription<void>? _historyRefreshSubscription;

  @override
  void initState() {
    super.initState();
    _fetchCurrentCredit();
    _loadHistory();
  }

  @override
  void dispose() {
    _historyRefreshSubscription?.cancel();
    super.dispose();
  }

  String _formatTimestamp(DateTime? value) {
    final dt = value;
    if (dt == null) return '';
    final dd = dt.day.toString().padLeft(2, '0');
    final mm = dt.month.toString().padLeft(2, '0');
    final yyyy = dt.year.toString();
    final hh = dt.hour.toString().padLeft(2, '0');
    final min = dt.minute.toString().padLeft(2, '0');
    return '$dd/$mm/$yyyy $hh:$min';
  }

  Future<void> _loadHistory({bool showLoading = true}) async {
    final uid = FirebaseAuth.instance.currentUser?.uid ?? _uid;
    if (uid == null || uid.isEmpty) {
      if (!mounted) return;
      setState(() {
        _historyLoading = false;
        _historyItems = const [];
        _todayIncome = WalletTodayIncome.zero;
      });
      return;
    }

    if (showLoading && mounted) {
      setState(() {
        _historyLoading = true;
        _historyError = null;
      });
    }

    try {
      final result = await WalletHistoryLoader.instance.loadMerchantHistory(
        uid: uid,
        onUpdate: (view) {
          if (!mounted) return;
          setState(() {
            _historyItems = view.items;
            _todayIncome = view.today;
            _historyLoading = false;
            _historyError = null;
          });
        },
      );

      _historyRefreshSubscription ??= WalletHistoryLoader.instance
          .watchCreditsChanges(uid)
          .listen((_) => _loadHistory(showLoading: false));

      if (!mounted) return;
      setState(() {
        _historyItems = result.items;
        _todayIncome = result.today;
        _historyLoading = false;
        _historyError = null;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _historyLoading = false;
        _historyError = 'โหลดรายการล่าสุดไม่สำเร็จ';
      });
    }
  }

  Future<void> _fetchCurrentCredit() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    if (mounted) setState(() => _uid = user.uid);

    await WalletBalanceLoader.instance.loadBalanced(
      uid: user.uid,
      actorType: 'merchant',
      onUpdate: (view) {
        if (!mounted) return;
        setState(() {
          _currentCredit = view.creditTotal;
          _withdrawableBalance = view.withdrawableBalance;
          _minGrossWithdrawAmount = view.minGrossWithdrawAmount;
          _balanceRefreshing = view.isRefreshing;
          _walletSnapshot = MerchantWalletSnapshot(
            totalCredit: view.creditTotal,
            withdrawableCredit: view.withdrawableBalance,
            lockedCredit: 0,
            canWithdraw: view.withdrawableBalance > 0,
            isContractCancelled: view.isContractCancelled,
            securityDepositAmount: view.securityDepositAmount,
          );
        });
      },
    );
  }

  Future<void> _promptTopUpAmount() async {
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => const WalletTopUpDialog(),
    );

    if (!mounted) return;
    if (result == true) {
      await _fetchCurrentCredit();
      await _loadHistory(showLoading: false);
    }
  }

  Future<void> _requestWithdraw() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      _showSnack('กรุณาเข้าสู่ระบบก่อน');
      return;
    }
    if (_withdrawableBalance <= 0) {
      _showSnack('ไม่มียอดที่ถอนได้');
      return;
    }
    if (_withdrawableBalance < _minGrossWithdrawAmount) {
      _showSnack(
        'ยอดถอนขั้นต่ำ ${_minGrossWithdrawAmount.toStringAsFixed(0)} บาท (หักค่าบริการ 10 บาท)',
      );
      return;
    }

    final verified = await verifySecurityPinForSensitiveAction(
      context,
      title: 'ยืนยันก่อนถอนเงิน',
    );
    if (!verified || !mounted) {
      return;
    }

    final result = await showDialog<double>(
      context: context,
      barrierDismissible: false,
      builder: (context) => const WalletWithdrawDialog(actorType: 'merchant'),
    );

    if (!mounted || result == null) {
      return;
    }

    await _fetchCurrentCredit();
    await _loadHistory(showLoading: false);
    _showSnack(
      'ส่งคำขอถอน ${result.toStringAsFixed(2)} บาท — กำลังโอนเข้าบัญชี',
    );
  }

  Widget _buildWalletBalanceCard(MerchantWalletSnapshot snapshot, String uid) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(26),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Colors.white.withValues(alpha: 0.22),
            Colors.white.withValues(alpha: 0.08),
          ],
        ),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.62),
          width: 1.2,
        ),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF5E1800).withValues(alpha: 0.24),
            blurRadius: 28,
            offset: const Offset(0, 14),
          ),
          BoxShadow(
            color: Colors.white.withValues(alpha: 0.10),
            blurRadius: 12,
            spreadRadius: -2,
          ),
        ],
      ),
      padding: const EdgeInsets.symmetric(vertical: 22, horizontal: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'ยอดเครดิตคงเหลือ',
            style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w700,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            '${_currentCredit.toStringAsFixed(2)} บาท',
            style: const TextStyle(
              fontSize: 42,
              height: 1.08,
              letterSpacing: -1.3,
              fontWeight: FontWeight.w800,
              color: Colors.white,
            ),
          ),
          if (snapshot.securityDepositAmount > 0) ...[
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                'ค่าประกัน ${snapshot.securityDepositAmount.toStringAsFixed(0)} บาท',
                style: const TextStyle(color: Colors.white70, fontSize: 12),
              ),
            ),
          ],
          const SizedBox(height: 18),
          Row(
            children: [
              Expanded(
                child: Row(
                  children: [
                    const Text(
                      'UID: ',
                      style: TextStyle(color: Colors.white70),
                    ),
                    Flexible(
                      child: SelectableText(
                        uid.length > 10
                            ? '${uid.substring(0, 6)}...${uid.substring(uid.length - 4)}'
                            : uid,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(
                        Icons.copy_rounded,
                        color: Colors.white,
                        size: 20,
                      ),
                      tooltip: 'คัดลอก UID เต็ม',
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: uid));
                        _showSnack('คัดลอก UID เรียบร้อย');
                      },
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.16),
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 7,
                      height: 7,
                      decoration: const BoxDecoration(
                        color: Color(0xFF42E37B),
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      _balanceRefreshing ? 'กำลังอัปเดต' : 'พร้อมใช้งาน',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 3),
          Text(
            _balanceRefreshing
                ? 'กำลังตรวจสอบยอดล่าสุด...'
                : 'อัปเดตล่าสุดเมื่อสักครู่',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.62),
              fontSize: 10,
            ),
          ),
          const SizedBox(height: 16),
          Divider(color: Colors.white.withValues(alpha: 0.20), height: 1),
          const SizedBox(height: 16),
          Row(
            children: [
              _buildBalanceMetric(label: 'ถอนได้', value: _withdrawableBalance),
              _buildMetricDivider(),
              _buildBalanceMetric(
                label: 'เครดิตล็อก',
                value: snapshot.lockedCredit,
              ),
              _buildMetricDivider(),
              _buildBalanceMetric(label: 'เครดิตรวม', value: _currentCredit),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildBalanceMetric({required String label, required double value}) {
    return Expanded(
      child: Column(
        children: [
          Text(
            label,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.72),
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 5),
          Text(
            value.toStringAsFixed(2),
            maxLines: 1,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMetricDivider() {
    return Container(
      width: 1,
      height: 42,
      color: Colors.white.withValues(alpha: 0.18),
    );
  }

  Widget _buildWalletActions() {
    return Row(
      children: [
        Expanded(
          child: FilledButton.icon(
            onPressed: _promptTopUpAmount,
            icon: const Icon(Icons.account_balance_wallet_outlined, size: 20),
            label: const Text('เติมเครดิต'),
            style: FilledButton.styleFrom(
              backgroundColor: _dashboardCream,
              foregroundColor: const Color(0xFFB73B00),
              minimumSize: const Size.fromHeight(54),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              textStyle: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: FilledButton.icon(
            onPressed: _requestWithdraw,
            icon: const Icon(Icons.currency_exchange_rounded, size: 20),
            label: const Text('ถอนเงิน'),
            style: FilledButton.styleFrom(
              backgroundColor: Colors.white.withValues(alpha: 0.14),
              foregroundColor: Colors.white,
              minimumSize: const Size.fromHeight(54),
              side: BorderSide(color: Colors.white.withValues(alpha: 0.32)),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              textStyle: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
      ],
    );
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Widget _buildTodayIncomeCard() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        gradient: LinearGradient(
          colors: [
            Colors.white.withValues(alpha: 0.18),
            Colors.white.withValues(alpha: 0.08),
          ],
        ),
        border: Border.all(color: Colors.white.withValues(alpha: 0.34)),
      ),
      child: Row(
        children: [
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(14),
            ),
            child: const Icon(
              Icons.query_stats_rounded,
              color: Colors.white,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'รายได้สินค้าในวันนี้',
                  style: TextStyle(
                    color: _dashboardCream,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  '${_todayIncome.productRevenue.toStringAsFixed(2)} บาท',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'ส่งสำเร็จวันนี้ ${_todayIncome.deliveredCount} ออเดอร์',
                  style: const TextStyle(
                    color: _dashboardCream,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCreditsHistory(String uid) {
    if (uid.isEmpty) {
      return const Text('กรุณาเข้าสู่ระบบเพื่อดูประวัติ');
    }
    if (_historyLoading && _historyItems.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (_historyError != null && _historyItems.isEmpty) {
      return Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(_historyError!),
          ),
          TextButton(onPressed: _loadHistory, child: const Text('ลองใหม่')),
        ],
      );
    }
    if (_historyItems.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 18),
        child: Column(
          children: [
            Container(
              width: 68,
              height: 68,
              decoration: const BoxDecoration(
                color: Color(0xFFFFE5D2),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.account_balance_wallet_outlined,
                color: Color(0xFFAF3A00),
                size: 32,
              ),
            ),
            const SizedBox(height: 14),
            const Text(
              'ยังไม่มีรายการเคลื่อนไหว',
              style: TextStyle(
                color: _dashboardText,
                fontSize: 16,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 5),
            const Text(
              'รายการเติมเครดิตและรายได้จะแสดงที่นี่',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.black54, fontSize: 12),
            ),
          ],
        ),
      );
    }

    return ListView.separated(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: _historyItems.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final item = _historyItems[index];
        final isPositive = item.amount >= 0;
        return ListTile(
          leading: Icon(item.icon, color: item.color),
          title: Text(item.title),
          subtitle: item.subtitle == null ? null : Text(item.subtitle!),
          trailing: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                '${item.amount.toStringAsFixed(2)} บาท',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: isPositive ? Colors.green : Colors.redAccent,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                _formatTimestamp(item.happenedAt),
                style: const TextStyle(fontSize: 12, color: Colors.black54),
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    final uid = user?.uid ?? _uid ?? '';
    final snapshot = _walletSnapshot;

    return Scaffold(
      backgroundColor: _dashboardOrangeMid,
      appBar: AppBar(
        title: const Text('กระเป๋าเงิน'),
        backgroundColor: Colors.transparent,
        flexibleSpace: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [_dashboardOrangeTop, _dashboardOrangeMid],
            ),
          ),
        ),
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              _dashboardOrangeTop,
              _dashboardOrangeMid,
              _dashboardOrangeBottom,
            ],
          ),
        ),
        child: Stack(
          children: [
            Positioned(
              right: -90,
              top: 30,
              child: Container(
                width: 250,
                height: 250,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.06),
                    width: 28,
                  ),
                ),
              ),
            ),
            Positioned(
              left: -140,
              top: 330,
              child: Container(
                width: 290,
                height: 290,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: const Color(0xFFFFB05D).withValues(alpha: 0.08),
                    width: 36,
                  ),
                ),
              ),
            ),
            RefreshIndicator(
              color: _dashboardOrangeMid,
              onRefresh: () async {
                await Future.wait([
                  _fetchCurrentCredit(),
                  _loadHistory(showLoading: false),
                ]);
              },
              child: SingleChildScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                child: Column(
                  children: [
                  _buildWalletBalanceCard(
                    uid.isNotEmpty
                        ? _walletSnapshot ??
                              MerchantWalletSnapshot(
                                totalCredit: _currentCredit,
                                withdrawableCredit: _withdrawableBalance,
                                lockedCredit: 0,
                                canWithdraw: _withdrawableBalance > 0,
                                isContractCancelled: false,
                                securityDepositAmount: 0,
                              )
                        : snapshot ??
                              const MerchantWalletSnapshot(
                                totalCredit: 0,
                                withdrawableCredit: 0,
                                lockedCredit: 0,
                                canWithdraw: false,
                                isContractCancelled: false,
                                securityDepositAmount: 0,
                              ),
                    uid,
                  ),
                  const SizedBox(height: 14),
                  _buildWalletActions(),
                  const SizedBox(height: 14),
                  _buildTodayIncomeCard(),
                  const SizedBox(height: 18),
                  Card(
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(24),
                    ),
                    elevation: 0,
                    color: _dashboardCream,
                    margin: EdgeInsets.zero,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Expanded(
                                child: Text(
                                  'รายการล่าสุด',
                                  style: TextStyle(
                                    fontSize: 19,
                                    fontWeight: FontWeight.w800,
                                    color: _dashboardText,
                                  ),
                                ),
                              ),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 7,
                                ),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFFFE8D6),
                                  borderRadius: BorderRadius.circular(18),
                                ),
                                child: const Text(
                                  'ล่าสุด 50 รายการ',
                                  style: TextStyle(
                                    color: Color(0xFFA83900),
                                    fontSize: 11,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          _buildCreditsHistory(uid),
                        ],
                      ),
                    ),
                  ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
