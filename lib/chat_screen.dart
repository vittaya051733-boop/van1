import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import 'chat_room_screen.dart';
import 'models/user_profile.dart';
import 'services/friend_list_cache_service.dart';
import 'services/friend_service.dart';
import 'services/friend_warmup_service.dart';
import 'services/chat_warmup.dart';
import 'utils/app_colors.dart';
import 'utils/network_image_url.dart';
import 'widgets/cached_app_avatar.dart';

/// Conversation list with friend management similar to LINE.
class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  static const Color _lineOrange = AppColors.accent;

  final FriendService _friendService = FriendService.instance;
  Stream<List<FriendPreview>>? _friendsStream;
  List<FriendPreview> _cachedFriends = const <FriendPreview>[];
  bool _loadedDiskCache = false;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  void _bootstrap() {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      return;
    }

    _friendsStream = FriendWarmupService.instance.watchFriends(user.uid);
    unawaited(_loadDiskCache(user.uid));
  }

  Future<void> _loadDiskCache(String ownerId) async {
    final cached = await FriendListCacheService.instance.load(ownerId);
    if (!mounted) return;
    setState(() {
      _cachedFriends = cached;
      _loadedDiskCache = true;
    });
  }

  Future<void> _openAddFriendSheet() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    final added = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => AddFriendSheet(
        friendService: _friendService,
        ownerId: user.uid,
      ),
    );
    if (added == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('เพิ่มเพื่อนสำเร็จ')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: _lineOrange,
        elevation: 0,
        titleSpacing: 0,
        title: const Text('แชต'),
        actions: [
          IconButton(
            icon: const Icon(Icons.search),
            onPressed: () {},
            tooltip: 'ค้นหา',
          ),
          IconButton(
            icon: const Icon(Icons.person_add_alt_1),
            onPressed: _openAddFriendSheet,
            tooltip: 'เพิ่มเพื่อน',
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: Column(
        children: [
          _SearchField(accent: _lineOrange),
          Expanded(child: _buildFriendList()),
        ],
      ),
    );
  }

  Widget _buildFriendList() {
    if (_friendsStream == null) {
      return const _EmptyState(message: 'ไม่พบผู้ใช้');
    }

    return StreamBuilder<List<FriendPreview>>(
      stream: _friendsStream,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          if (_cachedFriends.isNotEmpty) {
            return _buildFriendsListView(_cachedFriends);
          }
          return const _EmptyState(
            message: 'เกิดข้อผิดพลาดในการโหลดรายชื่อเพื่อน',
          );
        }

        final friends = snapshot.data;
        if (friends != null && friends.isNotEmpty) {
          _cachedFriends = friends;
          return _buildFriendsListView(friends);
        }

        if (_cachedFriends.isNotEmpty) {
          return _buildFriendsListView(_cachedFriends);
        }

        final warmupFriends = FriendWarmupService.instance.latestFriends;
        if (warmupFriends.isNotEmpty) {
          return _buildFriendsListView(warmupFriends);
        }

        if (snapshot.connectionState == ConnectionState.waiting &&
            !_loadedDiskCache) {
          return const _FriendListSkeleton();
        }

        if (snapshot.connectionState == ConnectionState.waiting) {
          if (_cachedFriends.isNotEmpty) {
            return _buildFriendsListView(_cachedFriends);
          }
          return const _EmptyState(message: 'ยังไม่มีเพื่อนในระบบ');
        }

        return const _EmptyState(message: 'ยังไม่มีเพื่อนในระบบ');
      },
    );
  }

  Widget _buildFriendsListView(List<FriendPreview> friends) {
    final user = FirebaseAuth.instance.currentUser;
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 12),
      itemBuilder: (context, index) => _ChatTile(
        friend: friends[index],
        accent: _lineOrange,
        onTap: () => _openChat(friends[index]),
        onLongPress: user == null
            ? null
            : () => _showFriendActions(user.uid, friends[index]),
      ),
      separatorBuilder: (context, index) =>
          const Divider(height: 1, indent: 88),
      itemCount: friends.length,
    );
  }

  Future<void> _showFriendActions(String ownerId, FriendPreview friend) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.person_remove_outlined),
              title: const Text('ลบเพื่อน'),
              onTap: () => Navigator.pop(context, 'delete'),
            ),
            ListTile(
              leading: const Icon(Icons.block, color: Colors.red),
              title: const Text('บล็อก'),
              onTap: () => Navigator.pop(context, 'block'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;

    if (action == 'delete') {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('ลบเพื่อน'),
          content: Text('ลบ ${friend.profile.displayName} ออกจากรายชื่อเพื่อน?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('ยกเลิก'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('ลบเพื่อน'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
      try {
        await _friendService.removeFriend(
          ownerId: ownerId,
          friendId: friend.profile.uid,
        );
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('ลบเพื่อนแล้ว')),
        );
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('ลบเพื่อนไม่สำเร็จ: $e')),
        );
      }
      return;
    }

    if (action == 'block') {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('บล็อก'),
          content: Text(
            'บล็อก ${friend.profile.displayName}?\nจะลบออกจากรายชื่อเพื่อนและไม่สามารถส่งข้อความได้',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('ยกเลิก'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('บล็อก'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
      try {
        await _friendService.blockUser(
          ownerId: ownerId,
          target: friend.profile,
        );
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('บล็อกแล้ว')),
        );
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('บล็อกไม่สำเร็จ: $e')),
        );
      }
    }
  }

  void _openChat(FriendPreview friend) {
    final user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      ChatWarmup.prefetchRoom(
        myUid: user.uid,
        peer: friend.profile,
        friendService: _friendService,
      );
    }
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ChatRoomScreen(friendProfile: friend.profile),
      ),
    );
  }
}

class _FriendListSkeleton extends StatelessWidget {
  const _FriendListSkeleton();

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 12),
      itemCount: 6,
      separatorBuilder: (context, index) =>
          const Divider(height: 1, indent: 88),
      itemBuilder: (context, index) {
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            children: [
              Container(
                width: 60,
                height: 60,
                decoration: const BoxDecoration(
                  color: Color(0xFFECECEC),
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      height: 14,
                      width: double.infinity,
                      decoration: BoxDecoration(
                        color: const Color(0xFFECECEC),
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Container(
                      height: 12,
                      width: 180,
                      decoration: BoxDecoration(
                        color: const Color(0xFFF3F3F3),
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _SearchField extends StatelessWidget {
  const _SearchField({required this.accent});

  final Color accent;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      color: AppColors.accentLight,
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFFF0F0F0),
          borderRadius: BorderRadius.circular(24),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            Icon(Icons.search, color: accent),
            const SizedBox(width: 8),
            const Expanded(
              child: Text(
                'ค้นหาเพื่อนหรือข้อความ',
                style: TextStyle(color: AppColors.accent, fontSize: 15),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ChatTile extends StatelessWidget {
  const _ChatTile({
    required this.friend,
    required this.accent,
    this.onTap,
    this.onLongPress,
  });

  final FriendPreview friend;
  final Color accent;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final titleStyle =
        theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600);
    final subtitleStyle =
        theme.textTheme.bodyMedium?.copyWith(color: Colors.grey[600]);

    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Container(
        color: Colors.white,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            _Avatar(profile: friend.profile),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          friend.profile.displayName,
                          style: titleStyle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      Text(
                        friend.lastActivityLabel,
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: Colors.grey[500]),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          friend.lastMessage,
                          style: subtitleStyle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (friend.isMuted) ...[
                        const SizedBox(width: 6),
                        const Icon(Icons.volume_off,
                            size: 16, color: Colors.grey),
                      ],
                      if (friend.unreadCount > 0) ...[
                        const SizedBox(width: 6),
                        _UnreadBadge(count: friend.unreadCount, color: accent),
                      ],
                    ],
                  ),
                  if (friend.profile.isOfficial)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: AppColors.accentSoft,
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.verified, color: accent, size: 14),
                            const SizedBox(width: 4),
                            Text(
                              'บัญชีทางการ',
                              style: TextStyle(
                                color: accent,
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Avatar extends StatelessWidget {
  const _Avatar({required this.profile});

  final UserProfile profile;

  @override
  Widget build(BuildContext context) {
    final String name = profile.displayName.trim();
    final String initial = name.isNotEmpty
        ? name.characters.first.toUpperCase()
        : '?';

    return CachedAppAvatar(
      imageUrl: profile.photoUrl,
      fallbackUrls: readProfilePhotoCandidates(<String, dynamic>{
        'photoUrl': profile.photoUrl,
      }),
      radius: 30,
      fallback: Text(
        initial,
        style: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.bold,
          fontSize: 24,
        ),
      ),
    );
  }
}

class _UnreadBadge extends StatelessWidget {
  const _UnreadBadge({required this.count, required this.color});

  final int count;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: AppColors.accent,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        count > 99 ? '99+' : '$count',
        style: const TextStyle(
          color: Colors.white,
          fontSize: 12,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.chat_bubble_outline,
                size: 64, color: Colors.grey),
            const SizedBox(height: 16),
            Text(
              message,
              style: const TextStyle(fontSize: 16),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

class AddFriendSheet extends StatefulWidget {
  const AddFriendSheet({required this.friendService, required this.ownerId});

  final FriendService friendService;
  final String ownerId;

  @override
  State<AddFriendSheet> createState() => _AddFriendSheetState();
}

class _AddFriendSheetState extends State<AddFriendSheet> {
  final TextEditingController _controller = TextEditingController();
  UserProfile? _result;
  bool _searching = false;
  late Future<List<UserProfile>> _suggestionsFuture;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _suggestionsFuture = widget.friendService.fetchSuggestedProfiles(
      ownerId: widget.ownerId,
    );
  }

  @override
  Widget build(BuildContext context) {
    final viewInsets = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: viewInsets),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'เพิ่มเพื่อนด้วยชื่อร้าน',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            const Text(
              'เลือกจากรายชื่อร้านค้าด้านล่างเพื่อเพิ่มเป็นเพื่อน',
              style: TextStyle(fontSize: 16),
            ),
            const SizedBox(height: 20),
            const Text(
              'ร้านค้าที่อาจรู้จัก',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            FutureBuilder<List<UserProfile>>(
              future: _suggestionsFuture,
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }
                final suggestions = snapshot.data ?? const [];
                if (suggestions.isEmpty) {
                  return const Text(
                    'ยังไม่มีร้านค้าอื่นที่พร้อมให้เพิ่มเป็นเพื่อน',
                  );
                }
                return Column(
                  children: suggestions
                      .map(
                        (profile) => Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: _FriendResultCard(
                            profile: profile,
                            onAdd:
                                _searching ? null : () => _addSuggested(profile),
                          ),
                        ),
                      )
                      .toList(),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _addFriend() async {
    final target = _result;
    if (target == null) return;
    setState(() => _searching = true);
    try {
      await widget.friendService.addFriend(
        ownerId: widget.ownerId,
        friend: target,
      );
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (_) {
      // Optionally show error with SnackBar or ignore
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  Future<void> _addSuggested(UserProfile profile) async {
    setState(() {
      _result = profile;
    });
    await _addFriend();
  }
}

class _FriendResultCard extends StatelessWidget {
  const _FriendResultCard({required this.profile, required this.onAdd});

  final UserProfile profile;
  final VoidCallback? onAdd;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: const [
          BoxShadow(
            color: Colors.black12,
            blurRadius: 8,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        children: [
          _Avatar(profile: profile),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  profile.displayName,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                if (profile.phoneNumber != null)
                  Text(
                    profile.phoneNumber!,
                    style: const TextStyle(color: Colors.grey),
                  ),
                if (profile.serviceType != null)
                  Text(
                    profile.serviceType!,
                    style: const TextStyle(color: Colors.grey),
                  ),
              ],
            ),
          ),
          ElevatedButton(
            onPressed: onAdd,
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.accent,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(24),
              ),
            ),
            child: const Text('เพิ่ม'),
          ),
        ],
      ),
    );
  }
}
