import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'wallet_screen.dart';
import 'notifications_screen.dart';
import 'settings_screen.dart';
import 'shipping_screen.dart';
import 'shop_management_screen.dart';
import 'order_management_screen_new.dart';
import 'driver_scanner_screen.dart';
import 'utils/app_colors.dart';
import 'chat_screen.dart';
import 'widgets/product_video_player.dart';
import 'services/product_cache_service.dart';
import 'services/shop_profile_cache_service.dart';
import 'services/shop_operations_service.dart';
import 'services/video_prefetch_service.dart';
import 'services/friend_warmup_service.dart';
import 'services/ecosystem_heartbeat_service.dart';
import 'models/shop_operations_settings.dart';
import 'merchant_pricing_policy.dart';
import 'models/product_variant.dart';
import 'utils/product_variant_color.dart';
import 'utils/shop_profile_resolver.dart';
import 'utils/product_image_url.dart';
import 'widgets/product_network_image.dart';
import 'widgets/merchant_premium_ui.dart';

class _HomeProductVariantDisplay {
  const _HomeProductVariantDisplay({
    required this.priceLabel,
    required this.discountedPriceLabel,
    required this.stockLabel,
    required this.colors,
    required this.sizes,
    required this.discountPercent,
  });

  final String priceLabel;
  final String discountedPriceLabel;
  final String stockLabel;
  final List<String> colors;
  final List<String> sizes;
  final double discountPercent;

  bool get hasOptions => colors.isNotEmpty || sizes.isNotEmpty;
}

Widget _buildHomeVariantOptionsDisplay(
  _HomeProductVariantDisplay display, {
  required bool onDarkBackground,
}) {
  if (!display.hasOptions) {
    return const SizedBox.shrink();
  }

  final sizeStyle = TextStyle(
    fontSize: 11,
    color: onDarkBackground ? Colors.white70 : Colors.black87,
  );

  return Row(
    crossAxisAlignment: CrossAxisAlignment.center,
    children: [
      if (display.colors.isNotEmpty)
        ProductVariantColorSwatchRow(
          colors: display.colors,
          size: onDarkBackground ? 16 : 22,
          spacing: 5,
          lightBorder: onDarkBackground,
        ),
      if (display.colors.isNotEmpty && display.sizes.isNotEmpty)
        SizedBox(width: onDarkBackground ? 6 : 8),
      if (display.sizes.isNotEmpty)
        Expanded(
          child: Text(
            display.sizes.join(' · '),
            style: sizeStyle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
    ],
  );
}

_HomeProductVariantDisplay _resolveHomeProductDisplay(
  Map<String, dynamic> data, {
  int imageIndex = 0,
}) {
  final fallbackPrice = MerchantPricingPolicy.parseNumber(data['price']);
  final fallbackStock = (data['stock'] as num?)?.toInt() ?? 0;
  final discountPercent = MerchantPricingPolicy.parseDiscountPercent(
    data['discountPercent'],
  );
  final hasVariants = ProductVariantSupport.productHasVariants(data);
  final variants = ProductVariantSupport.parseList(data['variants']);
  final scopedVariants = hasVariants
      ? ProductVariantSupport.variantsForImageIndex(variants, data, imageIndex)
      : const <ProductVariant>[];

  if (!hasVariants || scopedVariants.isEmpty) {
    final priceLabel = MerchantPricingPolicy.formatPrice(fallbackPrice);
    final discountedPriceLabel = MerchantPricingPolicy.formatPrice(
      MerchantPricingPolicy.applyDiscount(fallbackPrice, discountPercent),
    );
    return _HomeProductVariantDisplay(
      priceLabel: priceLabel,
      discountedPriceLabel: discountedPriceLabel,
      stockLabel: fallbackStock.toString(),
      colors: const <String>[],
      sizes: const <String>[],
      discountPercent: discountPercent,
    );
  }

  final basePrices = scopedVariants.map((variant) => variant.price);
  final priceLabel = ProductVariantSupport.formatPriceRange(basePrices);
  final discountedPriceLabel = ProductVariantSupport.formatPriceRange(
    scopedVariants.map(
      (variant) =>
          MerchantPricingPolicy.applyDiscount(variant.price, discountPercent),
    ),
  );
  final stockLabel = ProductVariantSupport.sumStock(scopedVariants).toString();
  final colors = ProductVariantSupport.uniqueOptionValues(
    scopedVariants,
    colors: true,
  );
  final sizes = ProductVariantSupport.uniqueOptionValues(
    scopedVariants,
    colors: false,
  );

  return _HomeProductVariantDisplay(
    priceLabel: priceLabel,
    discountedPriceLabel: discountedPriceLabel,
    stockLabel: stockLabel,
    colors: colors,
    sizes: sizes,
    discountPercent: discountPercent,
  );
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  static const String _shopOperationsCollection = 'shop_operations';
  static const String _notificationTargetApp = 'van1';
  static const String _shopCollectionKeyPrefix = 'merchant_shop_collection_';
  static const Duration _firestoreReadTimeout = Duration(seconds: 8);
  static const Duration _firestoreCacheTimeout = Duration(seconds: 2);
  static const Duration _firestoreServerTimeout = Duration(seconds: 8);
  static const List<String> _registrationFallbackCollections = <String>[
    'shop_registrations',
    'market_registrations',
    'restaurant_registrations',
    'pharmacy_registrations',
    'other_registrations',
  ];

  int _notificationCount = 0;
  String? _activeNotification;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>?
  _notificationSubscription;
  StreamSubscription<ShopOperationsSettings>? _shopOperationsSubscription;
  Set<String> _knownNotificationIds = <String>{};
  bool _didPrimeNotifications = false;
  bool _notifyNewOrdersEnabled = true;
  static const int _tabCount = 9;

  late final TabController _tabController;
  int _currentIndex = 0;
  late final List<Widget?> _pages = List<Widget?>.filled(
    _tabCount,
    null,
    growable: false,
  );
  String? _shopImageUrl;
  String? _shopName;
  Set<String> _homeProductIds = <String>{};
  Future<List<CachedProduct>>? _homeProductsFuture;
  List<CachedProduct> _localCachedProducts = const [];
  bool _isShopOpen = true;
  DocumentReference<Map<String, dynamic>>? _shopDocRef;
  String? _currentUserId;
  int _unreadChatCount = 0;
  Timer? _shopProfileRetryTimer;
  int _shopProfileRetryAttempt = 0;

  void showOverlayNotification(String message) {
    setState(() {
      _activeNotification = message;
    });
    Future.delayed(const Duration(seconds: 5), () {
      if (mounted && _activeNotification == message) {
        setState(() => _activeNotification = null);
      }
    });
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _tabController = TabController(length: _tabCount, vsync: this);
    _pages[0] = _buildPage(0);
    // Mount the order listener with Home so the tab is warm before first tap.
    _pages[2] = const OrderManagementScreen();
    _tabController.addListener(_handleTabChange);
    _loadShopDetails();
    _startChatWarmup();
    _startBackgroundListeners();
    EcosystemHeartbeatService.instance.start();

    // บังคับให้ System Navigation Bar เป็นสีขาวเมื่อเข้า Home
    SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(
        systemNavigationBarColor: Colors.white,
        systemNavigationBarIconBrightness: Brightness.dark,
        systemNavigationBarDividerColor: Colors.white,
        systemNavigationBarContrastEnforced: false,
      ),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Keep heartbeat while backgrounded so van4 health stays green when
    // switching apps on the same device. Stop only when process is gone.
    if (state == AppLifecycleState.resumed) {
      EcosystemHeartbeatService.instance.start();
    } else if (state == AppLifecycleState.detached) {
      EcosystemHeartbeatService.instance.stop();
    }
  }

  void _startBackgroundListeners() {
    // Keep Firestore available for the profile and product reads that make the
    // home screen useful before attaching non-critical real-time listeners.
    Future<void>.delayed(const Duration(seconds: 2), () {
      if (!mounted) return;
      _listenUnreadChats();
      _listenShopOperationsSettings();
      _listenUnreadAppNotifications();
    });
  }

  void _listenShopOperationsSettings() {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      return;
    }

    _shopOperationsSubscription?.cancel();
    _shopOperationsSubscription = ShopOperationsService.streamSettings(user.uid)
        .listen(
          (settings) {
            final changed = _notifyNewOrdersEnabled != settings.notifyNewOrders;
            if (!mounted) {
              _notifyNewOrdersEnabled = settings.notifyNewOrders;
              return;
            }
            setState(() {
              _notifyNewOrdersEnabled = settings.notifyNewOrders;
            });
            if (changed) {
              _listenUnreadAppNotifications();
            }
          },
          onError: (error) {
            debugPrint('Failed to listen shop operation settings: $error');
          },
        );
  }

  bool _isIncomingOrderNotification(Map<String, dynamic> data) {
    final type = (data['type'] as String?)?.trim();
    final action = (data['action'] as String?)?.trim();
    return (type == null || type.isEmpty || type == 'app_notification') &&
        action == 'order_accepted';
  }

  bool _isProductAiReadyNotification(Map<String, dynamic> data) {
    return (data['action'] as String?)?.trim() == 'product_ai_ready' ||
        (data['type'] as String?)?.trim() == 'product_ai_ready';
  }

  Future<void> _loadShopDetails() async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) return;

      _currentUserId = user.uid;
      unawaited(_hydrateCachedProducts(user.uid));
      await _hydrateCachedShopProfile(user.uid);
      unawaited(_ensureShopOperationsDoc(user.uid));
      unawaited(prefetchShopOrdersCache(user.uid));

      final collectionsToCheck = await _collectionsToCheck(user);
      if (collectionsToCheck.isEmpty) {
        _scheduleShopProfileRetry(user.uid);
        return;
      }

      DocumentSnapshot<Map<String, dynamic>>? foundSnapshot;
      var bestScore = -1;

      for (final collectionName in collectionsToCheck) {
        final snapshot = await _readRegistrationDoc(
          collectionName,
          user.uid,
          logOnFailure: collectionsToCheck.length == 1,
        );
        if (snapshot == null) continue;
        final score = _shopProfileSnapshotScore(snapshot);
        if (score > bestScore) {
          foundSnapshot = snapshot;
          bestScore = score;
          unawaited(_rememberShopCollection(user.uid, collectionName));
        }
        if (score >= 2) break;
      }

      if (foundSnapshot == null || !foundSnapshot.exists) {
        await _probeOtherRegistrationCollections(user.uid);
        _scheduleShopProfileRetry(user.uid);
        return;
      }

      await _applyShopProfileSnapshot(
        userId: user.uid,
        snapshot: foundSnapshot,
      );
      if (_shopProfileLooksIncomplete) {
        _scheduleShopProfileRetry(user.uid);
      } else {
        _shopProfileRetryTimer?.cancel();
        _shopProfileRetryAttempt = 0;
      }
    } catch (e) {
      debugPrint('Failed to load shop details: $e');
      final uid = _currentUserId ?? FirebaseAuth.instance.currentUser?.uid;
      if (uid != null) {
        _scheduleShopProfileRetry(uid);
      }
    }
  }

  Future<void> _applyShopProfileSnapshot({
    required String userId,
    required DocumentSnapshot<Map<String, dynamic>> snapshot,
  }) async {
    final data = snapshot.data();
    if (data == null || !mounted) return;

    final String? imageUrl = ShopProfileResolver.resolveImageUrl(data);
    final String? name = ShopProfileResolver.resolveName(data);
    final bool isOpen = data['isOpen'] as bool? ?? true;
    final Set<String> homeIds = ((data['homeProductIds'] as List?) ?? const [])
        .whereType<String>()
        .toSet();

    setState(() {
      _shopDocRef = snapshot.reference;
      if (imageUrl != null && imageUrl.isNotEmpty) {
        _shopImageUrl = imageUrl;
      }
      if (name != null && name.isNotEmpty) {
        _shopName = name;
      }
      _isShopOpen = isOpen;
      _homeProductIds = homeIds;
      _pages[0] = _buildPage(0);
    });
    final profileForCache = <String, dynamic>{
      ...data,
      'registrationCollection': snapshot.reference.parent.id,
    };
    if ((imageUrl == null || imageUrl.isEmpty) &&
        _shopImageUrl != null &&
        _shopImageUrl!.trim().isNotEmpty) {
      profileForCache['shopImageUrl'] = _shopImageUrl;
    }
    if ((name == null || name.isEmpty) &&
        _shopName != null &&
        _shopName!.trim().isNotEmpty) {
      profileForCache['shopName'] = _shopName;
    }
    unawaited(
      ShopProfileCacheService.instance.saveProfile(userId, profileForCache),
    );
    unawaited(_syncShopOperationsStatus(userId, isOpen));
    _updateHomeProductsCache();

    if (imageUrl != null && imageUrl.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          precacheImage(NetworkImage(imageUrl), context);
        }
      });
    }
  }

  bool get _shopProfileLooksIncomplete {
    final hasName = _shopName != null && _shopName!.trim().isNotEmpty;
    final hasImage = _shopImageUrl != null && _shopImageUrl!.trim().isNotEmpty;
    return !hasName || !hasImage;
  }

  void _scheduleShopProfileRetry(String userId) {
    if (!_shopProfileLooksIncomplete) return;

    _shopProfileRetryTimer?.cancel();
    if (_shopProfileRetryAttempt >= 4) return;

    final delaySeconds = 2 + (_shopProfileRetryAttempt * 2);
    _shopProfileRetryAttempt++;
    _shopProfileRetryTimer = Timer(Duration(seconds: delaySeconds), () {
      if (!mounted || !_shopProfileLooksIncomplete) return;
      unawaited(_loadShopDetails());
    });
  }

  void _startChatWarmup() {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      return;
    }
    Future<void>.delayed(const Duration(seconds: 2), () {
      if (!mounted) {
        return;
      }
      FriendWarmupService.instance.start(ownerId: user.uid);
    });
    if (_pages[7] == null) {
      Future<void>.delayed(const Duration(milliseconds: 800), () {
        if (!mounted || _pages[7] != null) {
          return;
        }
        setState(() => _pages[7] = _buildPage(7));
      });
    }
  }

  void _listenUnreadChats() {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    FirebaseFirestore.instance
        .collection('chats')
        .where('participants', arrayContains: user.uid)
        .snapshots()
        .listen((snapshot) {
          int totalUnread = 0;
          for (final doc in snapshot.docs) {
            final data = doc.data();
            final unreadMap = data['unreadCounts'] as Map<String, dynamic>?;
            if (unreadMap != null) {
              final userCount = unreadMap[user.uid];
              if (userCount is int) {
                totalUnread += userCount;
              } else if (userCount is num) {
                totalUnread += userCount.toInt();
              }
            }
          }
          if (mounted) {
            setState(() => _unreadChatCount = totalUnread);
          }
        });
  }

  void _listenUnreadAppNotifications() {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      return;
    }

    _notificationSubscription?.cancel();
    _notificationSubscription = FirebaseFirestore.instance
        .collection('app_notifications')
        .where('targetApp', isEqualTo: _notificationTargetApp)
        .where('recipientUid', isEqualTo: user.uid)
        .where('read', isEqualTo: false)
        .snapshots()
        .listen(
          (snapshot) {
            final docs =
                snapshot.docs
                    .where((doc) {
                      if (_notifyNewOrdersEnabled) {
                        return true;
                      }
                      return !_isIncomingOrderNotification(doc.data());
                    })
                    .toList(growable: false)
                  ..sort((a, b) {
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

            final currentIds = docs.map((doc) => doc.id).toSet();
            final newDocs = _didPrimeNotifications
                ? docs
                      .where((doc) => !_knownNotificationIds.contains(doc.id))
                      .toList(growable: false)
                : const <QueryDocumentSnapshot<Map<String, dynamic>>>[];

            if (mounted) {
              setState(() {
                _notificationCount = docs.length;
              });
            }

            if (newDocs.isNotEmpty) {
              final overlayDocs = newDocs
                  .where((doc) => !_isProductAiReadyNotification(doc.data()))
                  .toList(growable: false);
              if (overlayDocs.isNotEmpty) {
                final latest = overlayDocs.first.data();
                final title = (latest['title'] as String?)?.trim();
                final body = (latest['body'] as String?)?.trim();
                final overlayMessage = [
                  if (title != null && title.isNotEmpty) title,
                  if (body != null && body.isNotEmpty) body,
                ].join(' - ');
                if (overlayMessage.isNotEmpty) {
                  showOverlayNotification(overlayMessage);
                }
              }
            }

            _knownNotificationIds = currentIds;
            _didPrimeNotifications = true;
          },
          onError: (error) {
            debugPrint('Failed to listen app notifications: $error');
          },
        );
  }

  Future<void> _hydrateCachedProducts(String userId) async {
    final cached = await ProductCacheService.instance.loadProducts(userId);
    if (!mounted || cached.isEmpty) return;
    setState(() {
      _localCachedProducts = cached;
      _pages[0] = _buildPage(0);
    });
  }

  Future<void> _hydrateCachedShopProfile(String userId) async {
    final cached = await ShopProfileCacheService.instance.loadProfile(userId);
    if (!mounted || cached == null) return;

    final imageUrl = ShopProfileResolver.resolveImageUrl(cached);
    final name = ShopProfileResolver.resolveName(cached);
    final homeIds = ((cached['homeProductIds'] as List?) ?? const [])
        .whereType<String>()
        .toSet();
    final isOpen = cached['isOpen'] as bool? ?? true;
    final registrationCollection = (cached['registrationCollection'] as String?)
        ?.trim();

    setState(() {
      if (registrationCollection != null && registrationCollection.isNotEmpty) {
        _shopDocRef = FirebaseFirestore.instance
            .collection(registrationCollection)
            .doc(userId);
      }
      if (imageUrl != null && imageUrl.isNotEmpty) {
        _shopImageUrl = imageUrl;
      }
      if (name != null && name.isNotEmpty) {
        _shopName = name;
      }
      _homeProductIds = homeIds;
      _isShopOpen = isOpen;
      _pages[0] = _buildPage(0);
    });

    if (homeIds.isNotEmpty && isOpen) {
      final cachedProducts = await ProductCacheService.instance.loadProducts(
        userId,
      );
      final orderedProducts = _orderHomeProducts(cachedProducts, homeIds);
      if (!mounted || orderedProducts.isEmpty) return;
      setState(() {
        _localCachedProducts = orderedProducts;
        _pages[0] = _buildPage(0);
      });
    }
  }

  Future<List<CachedProduct>> _fetchHomeProducts(
    String userId,
    Set<String> ids,
  ) async {
    if (ids.isEmpty) {
      return const <CachedProduct>[];
    }

    final orderedIds = ids.toList();
    final Map<String, int> ordering = {
      for (var i = 0; i < orderedIds.length; i++) orderedIds[i]: i,
    };
    const int chunkSize = 10;
    final productsCollection = FirebaseFirestore.instance.collection(
      'products',
    );
    final futures = <Future<QuerySnapshot<Map<String, dynamic>>>>[];

    for (var start = 0; start < orderedIds.length; start += chunkSize) {
      final end = (start + chunkSize) > orderedIds.length
          ? orderedIds.length
          : start + chunkSize;
      futures.add(
        productsCollection
            .where(
              FieldPath.documentId,
              whereIn: orderedIds.sublist(start, end),
            )
            .get()
            .timeout(_firestoreReadTimeout),
      );
    }

    final snapshots = await Future.wait(futures);
    final docs = snapshots.expand((snap) => snap.docs).toList();
    docs.sort((a, b) {
      final orderA = ordering[a.id] ?? 0;
      final orderB = ordering[b.id] ?? 0;
      return orderA.compareTo(orderB);
    });
    final products = docs
        .map((doc) => CachedProduct(id: doc.id, data: doc.data()))
        .toList(growable: false);
    await ProductCacheService.instance.saveProducts(userId, products);
    if (mounted) {
      setState(() {
        _localCachedProducts = products;
        _pages[0] = _buildPage(0);
      });
    }
    return products;
  }

  List<CachedProduct> _orderHomeProducts(
    Iterable<CachedProduct> products,
    Set<String> ids,
  ) {
    final byId = <String, CachedProduct>{
      for (final product in products) product.id: product,
    };
    return <CachedProduct>[
      for (final id in ids)
        if (byId.containsKey(id)) byId[id]!,
    ];
  }

  Future<void> _refreshHomeProductsAfterCatalogChange() async {
    if (!mounted) return;

    final userId = _currentUserId;
    if (userId != null && _homeProductIds.isNotEmpty && _isShopOpen) {
      final cached = await ProductCacheService.instance.loadProducts(userId);
      final ordered = _orderHomeProducts(cached, _homeProductIds);
      if (mounted && ordered.isNotEmpty) {
        setState(() {
          _localCachedProducts = ordered;
          _pages[0] = _buildPage(0);
        });
      }
    }

    if (!mounted) return;
    _updateHomeProductsCache();
  }

  void _updateHomeProductsCache() {
    final userId = _currentUserId;
    if (!mounted) return;
    if (userId == null || _homeProductIds.isEmpty) {
      if (userId != null && _homeProductIds.isEmpty) {
        unawaited(ProductCacheService.instance.clear(userId));
      }
      setState(() {
        _homeProductsFuture = null;
        _localCachedProducts = const [];
      });
      return;
    }
    if (!_isShopOpen) {
      setState(() {
        _homeProductsFuture = null;
        _localCachedProducts = const [];
      });
      return;
    }
    setState(() {
      _homeProductsFuture = _fetchHomeProducts(userId, _homeProductIds);
      _pages[0] = _buildPage(0);
    });
  }

  Future<List<String>> _collectionsToCheck(User user) async {
    final ordered = <String>[];
    void addCollection(String? collection) {
      final trimmed = collection?.trim();
      if (trimmed == null || trimmed.isEmpty || ordered.contains(trimmed)) {
        return;
      }
      ordered.add(trimmed);
    }

    final knownCollection = await _loadKnownShopCollection(user.uid);
    if (knownCollection != null) {
      addCollection(knownCollection);
    }

    try {
      final contractDoc = await FirebaseFirestore.instance
          .collection('contracts')
          .doc(user.uid)
          .get(const GetOptions(source: Source.cache))
          .timeout(_firestoreCacheTimeout);
      final serviceType = contractDoc.data()?['serviceType'] as String?;
      if (serviceType != null && serviceType.trim().isNotEmpty) {
        addCollection(_collectionForServiceType(serviceType));
      }
    } catch (_) {}

    try {
      final contractDoc = await FirebaseFirestore.instance
          .collection('contracts')
          .doc(user.uid)
          .get(const GetOptions(source: Source.server))
          .timeout(_firestoreServerTimeout);
      final serviceType = contractDoc.data()?['serviceType'] as String?;
      if (serviceType != null && serviceType.trim().isNotEmpty) {
        addCollection(_collectionForServiceType(serviceType));
      }
    } catch (error) {
      if (error is! TimeoutException) {
        debugPrint('Failed to read service type: $error');
      }
    }

    for (final collection in _registrationFallbackCollections) {
      addCollection(collection);
    }
    return ordered;
  }

  int _shopProfileSnapshotScore(
    DocumentSnapshot<Map<String, dynamic>> snapshot,
  ) {
    final data = snapshot.data();
    if (data == null) return 0;
    var score = 0;
    final imageUrl = ShopProfileResolver.resolveImageUrl(data);
    final name = ShopProfileResolver.resolveName(data);
    if (name != null && name.trim().isNotEmpty) score++;
    if (imageUrl != null && imageUrl.trim().isNotEmpty) score++;
    return score;
  }

  Future<void> _probeOtherRegistrationCollections(String userId) async {
    for (final collectionName in _registrationFallbackCollections) {
      if (collectionName == 'shop_registrations') continue;
      final snapshot = await _readRegistrationDoc(
        collectionName,
        userId,
        logOnFailure: false,
      );
      if (snapshot == null || !snapshot.exists) continue;
      await _rememberShopCollection(userId, collectionName);
      await _applyShopProfileSnapshot(userId: userId, snapshot: snapshot);
      return;
    }
  }

  Future<String?> _loadKnownShopCollection(String userId) async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString('$_shopCollectionKeyPrefix$userId')?.trim();
    if (saved != null && saved.isNotEmpty) {
      return saved;
    }

    final pendingServiceType = prefs
        .getString('pending_reg_service_type')
        ?.trim();
    if (pendingServiceType != null && pendingServiceType.isNotEmpty) {
      return _collectionForServiceType(pendingServiceType);
    }

    final cached = await ShopProfileCacheService.instance.loadProfile(userId);
    final cachedCollection = (cached?['registrationCollection'] as String?)
        ?.trim();
    if (cachedCollection != null && cachedCollection.isNotEmpty) {
      return cachedCollection;
    }
    return null;
  }

  Future<void> _rememberShopCollection(String userId, String collection) async {
    if (userId.isEmpty || collection.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('$_shopCollectionKeyPrefix$userId', collection);
  }

  Future<DocumentSnapshot<Map<String, dynamic>>?> _readRegistrationDoc(
    String collectionName,
    String userId, {
    required bool logOnFailure,
  }) async {
    final docRef = FirebaseFirestore.instance
        .collection(collectionName)
        .doc(userId);
    try {
      final cached = await docRef
          .get(const GetOptions(source: Source.cache))
          .timeout(_firestoreCacheTimeout);
      if (cached.exists) {
        return cached;
      }
    } catch (_) {}

    try {
      final snapshot = await docRef
          .get(const GetOptions(source: Source.server))
          .timeout(_firestoreServerTimeout);
      if (snapshot.exists) {
        return snapshot;
      }
    } catch (error) {
      if (logOnFailure) {
        debugPrint('Shop doc read failed ($collectionName): $error');
      }
    }
    return null;
  }

  String _collectionForServiceType(String serviceType) {
    switch (serviceType.trim()) {
      case 'ตลาด':
        return 'market_registrations';
      case 'ร้านค้า':
        return 'shop_registrations';
      case 'ร้านอาหาร':
        return 'restaurant_registrations';
      case 'ร้านขายยา':
        return 'pharmacy_registrations';
      default:
        return 'other_registrations';
    }
  }

  Future<void> _saveShopOpenStatus(bool isOpen) async {
    try {
      final docRef = await _getOrFindShopDocRef();
      if (docRef != null) {
        await docRef.set({'isOpen': isOpen}, SetOptions(merge: true));
      }
      final user = FirebaseAuth.instance.currentUser;
      if (user != null) {
        await _syncShopOperationsStatus(user.uid, isOpen);
        await _syncProductActiveFlagsForShop(user.uid, isOpen: isOpen);
      }
      _updateHomeProductsCache();
      debugPrint('Updated isOpen=$isOpen');
    } catch (e) {
      debugPrint('Failed to save shop open status: $e');
    }
  }

  Future<void> _ensureShopOperationsDoc(String shopId) async {
    final docRef = FirebaseFirestore.instance
        .collection(_shopOperationsCollection)
        .doc(shopId);
    final snapshot = await docRef.get();
    if (snapshot.exists) return;

    await docRef.set({
      'shopId': shopId,
      'isOpen': _isShopOpen,
      'openProductIds': _isShopOpen ? _homeProductIds.toList() : <String>[],
      'openProductCount': _isShopOpen ? _homeProductIds.length : 0,
      'createdAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  Future<void> _syncShopOperationsStatus(String shopId, bool isOpen) async {
    final List<String> openProductIds = isOpen
        ? await _fetchCurrentShopProductIds(shopId)
        : <String>[];

    await FirebaseFirestore.instance
        .collection(_shopOperationsCollection)
        .doc(shopId)
        .set({
          'shopId': shopId,
          'isOpen': isOpen,
          'openProductIds': openProductIds,
          'openProductCount': openProductIds.length,
          'openProductsUpdatedAt': FieldValue.serverTimestamp(),
          'updatedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
  }

  Future<List<String>> _fetchCurrentShopProductIds(String shopId) async {
    final snapshot = await FirebaseFirestore.instance
        .collection('products')
        .where('ownerUid', isEqualTo: shopId)
        .get();

    return snapshot.docs.map((doc) => doc.id).toList(growable: false);
  }

  Future<void> _saveHomeProductIds(Set<String> ids) async {
    try {
      final docRef = await _getOrFindShopDocRef();
      if (docRef == null) return;
      await docRef.update({'homeProductIds': ids.toList()});
      final user = FirebaseAuth.instance.currentUser;
      if (user != null) {
        await _syncProductActiveFlagsForShop(user.uid, isOpen: _isShopOpen);
      }
      debugPrint('Saved homeProductIds (${ids.length}) to ${docRef.path}');
    } catch (e) {
      debugPrint('Failed to save home product ids: $e');
    }
  }

  Future<void> _syncProductActiveFlagsForShop(
    String shopId, {
    required bool isOpen,
  }) async {
    try {
      final snapshot = await FirebaseFirestore.instance
          .collection('products')
          .where('ownerUid', isEqualTo: shopId)
          .get();

      if (snapshot.docs.isEmpty) {
        return;
      }

      final Set<String> activeIds = isOpen ? _homeProductIds : <String>{};
      WriteBatch batch = FirebaseFirestore.instance.batch();
      int operationCount = 0;

      for (final doc in snapshot.docs) {
        final data = doc.data();
        final bool shouldBeActive = activeIds.contains(doc.id);
        final bool? currentActive = data['isActive'] as bool?;
        final Map<String, dynamic> updates = <String, dynamic>{};

        if (currentActive != shouldBeActive) {
          updates['isActive'] = shouldBeActive;
        }

        if (shouldBeActive) {
          if (data['activeAt'] == null) {
            updates['activeAt'] = FieldValue.serverTimestamp();
          }
          if (data.containsKey('inactiveAt') && data['inactiveAt'] != null) {
            updates['inactiveAt'] = FieldValue.delete();
          }
        } else if (data['inactiveAt'] == null) {
          updates['inactiveAt'] = FieldValue.serverTimestamp();
        }

        if (updates.isEmpty) {
          continue;
        }

        updates['updatedAt'] = FieldValue.serverTimestamp();
        batch.update(doc.reference, updates);
        operationCount++;

        if (operationCount >= 450) {
          await batch.commit();
          batch = FirebaseFirestore.instance.batch();
          operationCount = 0;
        }
      }

      if (operationCount > 0) {
        await batch.commit();
      }
    } catch (e) {
      debugPrint('Failed to sync product active flags for $shopId: $e');
    }
  }

  Future<DocumentReference<Map<String, dynamic>>?>
  _getOrFindShopDocRef() async {
    if (_shopDocRef != null) return _shopDocRef;
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return null;

    final collections = await _collectionsToCheck(user);
    for (final name in collections) {
      final snapshot = await _readRegistrationDoc(
        name,
        user.uid,
        logOnFailure: collections.length == 1,
      );
      if (snapshot != null) {
        _shopDocRef = snapshot.reference;
        unawaited(_rememberShopCollection(user.uid, name));
        return _shopDocRef;
      }
    }
    return null;
  }

  void _handleTabChange() {
    if (_tabController.indexIsChanging) return;
    final int newIndex = _tabController.index;
    if (newIndex != _currentIndex) {
      final shouldRefreshHome = newIndex == 0 && _currentIndex == 1;
      setState(() {
        _currentIndex = newIndex;
        _pages[newIndex] ??= _buildPage(newIndex);
      });
      if (shouldRefreshHome) {
        _refreshHomeProductsAfterCatalogChange();
      }
    }
  }

  @override
  void dispose() {
    EcosystemHeartbeatService.instance.stop();
    WidgetsBinding.instance.removeObserver(this);
    _notificationSubscription?.cancel();
    _shopOperationsSubscription?.cancel();
    _tabController.removeListener(_handleTabChange);
    _tabController.dispose();
    _shopProfileRetryTimer?.cancel();
    super.dispose();
  }

  Widget _buildPage(int index) {
    switch (index) {
      case 0:
        return _HomeDashboard(
          onProfileTap: () => _switchToTab(5),
          shopImageUrl: _shopImageUrl,
          shopName: _shopName,
          homeProductIds: _homeProductIds,
          homeProductsFuture: _homeProductsFuture,
          cachedProducts: _localCachedProducts,
          isShopOpen: _isShopOpen,
          onToggleShopStatus: (value) async {
            setState(() {
              _isShopOpen = value;
              _pages[0] = _buildPage(0);
            });

            // บันทึกสถานะลง Firestore
            await _saveShopOpenStatus(value);

            final messenger = ScaffoldMessenger.of(context);
            messenger.hideCurrentSnackBar();
            messenger.showSnackBar(
              SnackBar(
                content: Text(
                  value ? 'ร้านเปิดให้บริการแล้ว' : 'ร้านถูกปิดชั่วคราว',
                ),
                duration: const Duration(seconds: 2),
              ),
            );
          },
        );
      case 1:
        return ShopManagementScreen(
          initialHomeProductIds: _homeProductIds,
          onHomeProductIdsChanged: (ids) {
            setState(() {
              _homeProductIds = ids;
              _pages[0] = _buildPage(0); // สร้างหน้าโฮมขึ้นมาใหม่
            });
            _updateHomeProductsCache();
            _saveHomeProductIds(ids);
          },
          onHomeProductsChanged: _refreshHomeProductsAfterCatalogChange,
        );
      case 2:
        return const OrderManagementScreen();
      case 3:
        return const DriverScannerScreen();
      case 4:
        return const ShippingScreen();
      case 5:
        return const WalletScreen();
      case 6:
        return const NotificationsScreen();
      case 7:
        return const ChatScreen();
      case 8:
        return const SettingsScreen();
      default:
        return const SizedBox.shrink();
    }
  }

  void _switchToTab(int index) {
    if (index == _currentIndex) return;
    if (_pages[index] == null) {
      setState(() => _pages[index] = _buildPage(index));
    }
    _tabController.animateTo(index);
  }

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: const SystemUiOverlayStyle(
        systemNavigationBarColor: Colors.white,
        systemNavigationBarIconBrightness: Brightness.dark,
        systemNavigationBarDividerColor: Colors.white,
        systemNavigationBarContrastEnforced: false,
      ),
      child: Stack(
        children: [
          Scaffold(
            body: IndexedStack(
              index: _currentIndex,
              children: _pages
                  .map((page) => page ?? const SizedBox.shrink())
                  .toList(),
            ),
            bottomNavigationBar: SafeArea(
              top: false,
              minimum: EdgeInsets.zero,
              child: ColoredBox(
                color: MerchantPremiumUi.pageBackground,
                child: Padding(
                  padding: const EdgeInsets.only(top: 6, bottom: 4),
                  child: SizedBox(
                    height: 66,
                    child: Center(
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.symmetric(horizontal: 14),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _buildNavButton(
                              icon: Icons.home_outlined,
                              index: 0,
                            ),
                            _buildNavButton(
                              icon: Icons.store_outlined,
                              index: 1,
                            ),
                            _buildNavButton(icon: Icons.receipt_long, index: 2),
                            // Hidden QR scanner button (index 3) – feature paused for shop app UX
                            _buildNavButton(
                              icon: Icons.insights_outlined,
                              index: 4,
                            ),
                            _buildNavButton(icon: Icons.wallet, index: 5),
                            _buildNavButton(
                              icon: Icons.notifications_outlined,
                              index: 6,
                              badgeCount: _notificationCount,
                            ),
                            _buildNavButton(
                              icon: Icons.chat_bubble_outline,
                              index: 7,
                              badgeCount: _unreadChatCount,
                            ),
                            _buildNavButton(
                              icon: Icons.settings_outlined,
                              index: 8,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          if (_activeNotification != null)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: Material(
                color: Colors.transparent,
                child: Container(
                  margin: const EdgeInsets.all(12),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.orange.shade700,
                    borderRadius: BorderRadius.circular(12),
                    boxShadow: [
                      BoxShadow(color: Colors.black26, blurRadius: 8),
                    ],
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.notifications_active,
                        color: Colors.white,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          _activeNotification ?? '',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close, color: Colors.white),
                        onPressed: () =>
                            setState(() => _activeNotification = null),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildNavButton({
    required IconData icon,
    required int index,
    int badgeCount = 0,
  }) {
    final bool isSelected = _currentIndex == index;
    final Color iconColor = isSelected
        ? AppColors.accentDark
        : AppColors.neutralIcon;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 5),
      child: InkWell(
        onTap: () => _switchToTab(index),
        borderRadius: BorderRadius.circular(48),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              width: 54,
              height: 54,
              decoration: BoxDecoration(
                color: isSelected ? Colors.white : const Color(0xFFFFF0E1),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: isSelected
                      ? AppColors.accent.withValues(alpha: 0.36)
                      : Colors.white,
                ),
                boxShadow: isSelected ? MerchantPremiumUi.softShadow : null,
              ),
              child: Icon(icon, color: iconColor, size: 26),
            ),
            if (badgeCount > 0)
              Positioned(
                right: -4,
                top: -4,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.red,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.white, width: 2),
                  ),
                  child: Text(
                    badgeCount > 99 ? '99+' : badgeCount.toString(),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _HomeDashboard extends StatelessWidget {
  const _HomeDashboard({
    required this.onProfileTap,
    required this.isShopOpen,
    required this.onToggleShopStatus,
    required this.cachedProducts,
    this.shopImageUrl,
    this.shopName,
    this.homeProductIds,
    this.homeProductsFuture,
  });

  final VoidCallback onProfileTap;
  final bool isShopOpen;
  final ValueChanged<bool> onToggleShopStatus;
  final String? shopImageUrl;
  final String? shopName;
  final Set<String>? homeProductIds;
  final Future<List<CachedProduct>>? homeProductsFuture;
  final List<CachedProduct> cachedProducts;

  Widget _buildHomeDiscountBadge(double discountPercent) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xFFD32F2F),
        borderRadius: BorderRadius.circular(8),
        boxShadow: const [
          BoxShadow(
            color: Color(0x66000000),
            blurRadius: 4,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: Text(
        'ลด ${MerchantPricingPolicy.formatDiscountPercent(discountPercent)}%',
        style: const TextStyle(
          color: Colors.white,
          fontSize: 12,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }

  void _showProductGallery(
    BuildContext context,
    Map<String, dynamic> data, {
    String? preferredFirstUrl,
  }) {
    final List<String> imageUrls = _extractGalleryImages(
      data,
      preferredFirstUrl: preferredFirstUrl,
    );
    final videoUrl = data['videoUrl'] as String?;
    final name = (data['name'] ?? '').toString();
    final description = (data['description'] ?? '').toString();
    final productId = (data['documentId'] ?? data['id'] ?? '').toString();
    final videoThumbnailUrl = (data['videoThumbnailUrl'] ?? '')
        .toString()
        .trim();
    final discountPercent = MerchantPricingPolicy.parseDiscountPercent(
      data['discountPercent'],
    );
    final variants = ProductVariantSupport.parseList(data['variants']);

    showDialog(
      context: context,
      barrierColor: Colors.black87,
      builder: (ctx) => Dialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: _ProductGalleryContent(
          images: imageUrls,
          videoUrl: videoUrl,
          videoThumbnailUrl: videoThumbnailUrl.isNotEmpty
              ? videoThumbnailUrl
              : null,
          name: name,
          description: description,
          productId: productId,
          productData: data,
          variants: variants,
          discountPercent: discountPercent,
        ),
      ),
    );
  }

  /// One URL per logical product image (original preferred, else thumbnail).
  /// Avoids counting thumbnail + original as two separate gallery pages.
  List<String> _extractGalleryImages(
    Map<String, dynamic> data, {
    String? preferredFirstUrl,
  }) {
    List<String> readList(String key) =>
        (data[key] as List?)
            ?.whereType<String>()
            .where((url) => url.trim().isNotEmpty)
            .map((url) => url.trim())
            .toList() ??
        const [];

    final thumbnails = readList('thumbnailUrls');
    final originals = readList('imageUrls');
    final imageCount = originals.isNotEmpty
        ? originals.length
        : thumbnails.length;

    final urls = <String>[];
    final seen = <String>{};
    for (var i = 0; i < imageCount; i++) {
      final original = i < originals.length ? originals[i] : '';
      final thumb = i < thumbnails.length ? thumbnails[i] : '';
      final pick = original.isNotEmpty ? original : thumb;
      if (pick.isNotEmpty && seen.add(pick)) {
        urls.add(pick);
      }
    }

    final videoUrl = (data['videoUrl'] as String?)?.trim();
    final filtered = videoUrl != null && videoUrl.isNotEmpty
        ? urls.where((url) => url != videoUrl).toList(growable: false)
        : List<String>.from(urls);

    final preferred = preferredFirstUrl?.trim();
    if (preferred == null || preferred.isEmpty || filtered.isEmpty) {
      return filtered;
    }

    var matchIndex = filtered.indexOf(preferred);
    if (matchIndex < 0) {
      for (var i = 0; i < imageCount; i++) {
        final original = i < originals.length ? originals[i] : '';
        final thumb = i < thumbnails.length ? thumbnails[i] : '';
        if (preferred == original || preferred == thumb) {
          if (i < filtered.length) {
            matchIndex = i;
          }
          break;
        }
      }
    }

    if (matchIndex <= 0) {
      return filtered;
    }
    return [
      filtered[matchIndex],
      ...filtered.where((url) => url != filtered[matchIndex]),
    ];
  }

  void _prefetchProductVideos(List<CachedProduct> docs, int selectedIndex) {
    if (selectedIndex < 0 || selectedIndex >= docs.length) {
      return;
    }

    final Set<String> urls = <String>{};
    final String? current = (docs[selectedIndex].data['videoUrl'] as String?)
        ?.trim();
    if (current != null && current.isNotEmpty) {
      urls.add(current);
    }

    int offset = 1;
    int neighborCount = 0;
    while (neighborCount < 5 &&
        (selectedIndex - offset >= 0 || selectedIndex + offset < docs.length)) {
      final prevIndex = selectedIndex - offset;
      if (prevIndex >= 0) {
        final prevUrl = (docs[prevIndex].data['videoUrl'] as String?)?.trim();
        if (prevUrl != null && prevUrl.isNotEmpty && urls.add(prevUrl)) {
          neighborCount++;
        }
      }

      final nextIndex = selectedIndex + offset;
      if (nextIndex < docs.length) {
        final nextUrl = (docs[nextIndex].data['videoUrl'] as String?)?.trim();
        if (nextUrl != null && nextUrl.isNotEmpty && urls.add(nextUrl)) {
          neighborCount++;
        }
      }

      offset++;
    }

    if (urls.isNotEmpty) {
      VideoPrefetchService.instance.preloadVideos(urls);
    }
  }

  Widget _buildHomeHero() {
    final String displayName = (shopName != null && shopName!.isNotEmpty)
        ? shopName!
        : 'ร้านค้าของฉัน';
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 10),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: MerchantPremiumUi.heroGradient,
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: MerchantPremiumUi.line),
        boxShadow: MerchantPremiumUi.softShadow,
      ),
      child: Row(
        children: [
          Container(
            width: 58,
            height: 58,
            padding: const EdgeInsets.all(3),
            decoration: const BoxDecoration(
              color: Colors.white,
              shape: BoxShape.circle,
            ),
            child: CircleAvatar(
              backgroundColor: AppColors.accentLight,
              backgroundImage:
                  (shopImageUrl != null && shopImageUrl!.isNotEmpty)
                  ? NetworkImage(shopImageUrl!)
                  : null,
              child: shopImageUrl == null || shopImageUrl!.isEmpty
                  ? const Icon(
                      Icons.storefront,
                      color: AppColors.accentDark,
                      size: 30,
                    )
                  : null,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: MerchantPremiumUi.ink,
                          fontSize: 20,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    _ShopStatusToggle(
                      isOpen: isShopOpen,
                      onToggle: onToggleShopStatus,
                      width: 124,
                    ),
                  ],
                ),
                const SizedBox(height: 7),
                PremiumStatusChip(
                  icon: isShopOpen
                      ? Icons.check_circle_rounded
                      : Icons.pause_circle_filled_rounded,
                  label: isShopOpen ? 'ออนไลน์ / เปิดทำการ' : 'ปิดชั่วคราว',
                  color: isShopOpen
                      ? MerchantPremiumUi.success
                      : AppColors.accentDark,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: MerchantPremiumUi.pageBackground,
      body: SafeArea(
        child: Column(
          children: [
            GestureDetector(onTap: onProfileTap, child: _buildHomeHero()),
            Expanded(
              child: !isShopOpen
                  ? const PremiumEmptyState(
                      icon: Icons.store_mall_directory_outlined,
                      title: 'ร้านปิดชั่วคราว',
                      message:
                          'ขออภัยค่ะ ร้านค้าปิดทำการในขณะนี้\nกรุณากลับมาใหม่ภายหลัง',
                    )
                  : homeProductIds == null || homeProductIds!.isEmpty
                  ? const PremiumEmptyState(
                      icon: Icons.widgets_outlined,
                      title: 'ยังไม่มีสินค้าในหน้าโฮม',
                      message:
                          'เลือกสินค้าจากหน้า จัดการร้านค้า เพื่อแสดงบนหน้าโฮม',
                    )
                  : FutureBuilder<List<CachedProduct>>(
                      future: homeProductsFuture,
                      builder: (context, snapshot) {
                        final List<CachedProduct> docs =
                            snapshot.data ?? cachedProducts;
                        final bool showLoading =
                            snapshot.connectionState ==
                                ConnectionState.waiting &&
                            docs.isEmpty;

                        if (showLoading) {
                          return const Center(
                            child: CircularProgressIndicator(),
                          );
                        }

                        if (snapshot.hasError && docs.isEmpty) {
                          return Center(
                            child: Text(
                              'เกิดข้อผิดพลาดในการโหลดสินค้า: ${snapshot.error}',
                              textAlign: TextAlign.center,
                            ),
                          );
                        }

                        if (docs.isEmpty) {
                          return const Center(
                            child: Text(
                              'ไม่พบสินค้าที่เลือก',
                              style: TextStyle(fontSize: 18),
                            ),
                          );
                        }
                        String? selectedTypeKey;
                        final typeGroups = _groupHomeProductsByType(docs);
                        final showTypeFilters =
                            typeGroups.length > 1 ||
                            (typeGroups.isNotEmpty &&
                                typeGroups.first.label != 'อื่นๆ');

                        return StatefulBuilder(
                          builder: (context, setFilterState) {
                            final visibleDocs = selectedTypeKey == null
                                ? docs
                                : typeGroups
                                      .where(
                                        (group) => group.key == selectedTypeKey,
                                      )
                                      .expand((group) => group.products)
                                      .toList(growable: false);

                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                if (showTypeFilters) ...[
                                  SizedBox(
                                    height: 58,
                                    child: ListView(
                                      scrollDirection: Axis.horizontal,
                                      padding: const EdgeInsets.fromLTRB(
                                        16,
                                        10,
                                        16,
                                        8,
                                      ),
                                      children: [
                                        Padding(
                                          padding: const EdgeInsets.only(
                                            right: 8,
                                          ),
                                          child: FilterChip(
                                            label: const Text('ทั้งหมด'),
                                            selected: selectedTypeKey == null,
                                            onSelected: (_) => setFilterState(
                                              () => selectedTypeKey = null,
                                            ),
                                            selectedColor: const Color(
                                              0xFFFFEDD5,
                                            ),
                                            checkmarkColor: AppColors.accent,
                                          ),
                                        ),
                                        for (final group in typeGroups)
                                          Padding(
                                            padding: const EdgeInsets.only(
                                              right: 8,
                                            ),
                                            child: FilterChip(
                                              label: Text(group.label),
                                              selected:
                                                  selectedTypeKey == group.key,
                                              onSelected: (_) => setFilterState(
                                                () =>
                                                    selectedTypeKey = group.key,
                                              ),
                                              selectedColor: const Color(
                                                0xFFFFEDD5,
                                              ),
                                              checkmarkColor: AppColors.accent,
                                            ),
                                          ),
                                      ],
                                    ),
                                  ),
                                ],
                                Expanded(
                                  child: GridView.builder(
                                    padding: const EdgeInsets.fromLTRB(
                                      16,
                                      8,
                                      16,
                                      18,
                                    ),
                                    gridDelegate:
                                        const SliverGridDelegateWithFixedCrossAxisCount(
                                          crossAxisCount: 2,
                                          mainAxisSpacing: 16,
                                          crossAxisSpacing: 16,
                                        ),
                                    itemCount: visibleDocs.length,
                                    itemBuilder: (context, index) {
                                      final doc = visibleDocs[index];
                                      final data = doc.data;
                                      final imageCandidates =
                                          readProductImageUrlCandidates(data);
                                      final String? imageUrl =
                                          imageCandidates.isNotEmpty
                                          ? imageCandidates.first
                                          : null;
                                      final name = (data['name'] ?? '')
                                          .toString();
                                      final discountPercent =
                                          MerchantPricingPolicy.parseDiscountPercent(
                                            data['discountPercent'],
                                          );
                                      final display =
                                          _resolveHomeProductDisplay(
                                            data,
                                            imageIndex: 0,
                                          );
                                      final description =
                                          (data['description'] ?? '')
                                              .toString();

                                      return GestureDetector(
                                        onTap: () {
                                          _prefetchProductVideos(
                                            visibleDocs,
                                            index,
                                          );
                                          final modalData =
                                              Map<String, dynamic>.from(data);
                                          modalData['documentId'] = doc.id;
                                          _showProductGallery(
                                            context,
                                            modalData,
                                            preferredFirstUrl: imageUrl,
                                          );
                                        },
                                        child: Container(
                                          decoration:
                                              MerchantPremiumUi.cardDecoration(),
                                          child: ClipRRect(
                                            borderRadius: BorderRadius.circular(
                                              22,
                                            ),
                                            child: Stack(
                                              children: [
                                                Positioned.fill(
                                                  child: ProductNetworkImage(
                                                    key: ValueKey<String>(
                                                      'home-img-${doc.id}',
                                                    ),
                                                    urls: imageCandidates,
                                                    fit: BoxFit.cover,
                                                    memCacheWidth: 400,
                                                  ),
                                                ),
                                                Positioned(
                                                  left: 0,
                                                  right: 0,
                                                  bottom: 0,
                                                  child: Container(
                                                    padding:
                                                        const EdgeInsets.fromLTRB(
                                                          12,
                                                          14,
                                                          12,
                                                          12,
                                                        ),
                                                    decoration:
                                                        const BoxDecoration(
                                                          gradient:
                                                              LinearGradient(
                                                                begin: Alignment
                                                                    .bottomCenter,
                                                                end: Alignment
                                                                    .topCenter,
                                                                colors: [
                                                                  Color(
                                                                    0xCC000000,
                                                                  ),
                                                                  Color(
                                                                    0x66000000,
                                                                  ),
                                                                  Color(
                                                                    0x00000000,
                                                                  ),
                                                                ],
                                                              ),
                                                        ),
                                                    child: Column(
                                                      crossAxisAlignment:
                                                          CrossAxisAlignment
                                                              .start,
                                                      mainAxisSize:
                                                          MainAxisSize.min,
                                                      children: [
                                                        Text(
                                                          name,
                                                          style: const TextStyle(
                                                            fontSize: 16,
                                                            fontWeight:
                                                                FontWeight.w700,
                                                            color: Colors.white,
                                                            shadows: [
                                                              Shadow(
                                                                color: Colors
                                                                    .black54,
                                                                offset: Offset(
                                                                  0,
                                                                  1,
                                                                ),
                                                                blurRadius: 2,
                                                              ),
                                                            ],
                                                          ),
                                                          maxLines: 1,
                                                          overflow: TextOverflow
                                                              .ellipsis,
                                                        ),
                                                        const SizedBox(
                                                          height: 2,
                                                        ),
                                                        if (display
                                                            .hasOptions) ...[
                                                          _buildHomeVariantOptionsDisplay(
                                                            display,
                                                            onDarkBackground:
                                                                true,
                                                          ),
                                                          const SizedBox(
                                                            height: 2,
                                                          ),
                                                        ],
                                                        if (discountPercent >
                                                            0) ...[
                                                          Text(
                                                            'ราคาเต็ม: ${display.priceLabel} บาท',
                                                            style: const TextStyle(
                                                              fontSize: 12,
                                                              color: Colors
                                                                  .white60,
                                                              decoration:
                                                                  TextDecoration
                                                                      .lineThrough,
                                                            ),
                                                            maxLines: 1,
                                                            overflow:
                                                                TextOverflow
                                                                    .ellipsis,
                                                          ),
                                                          const SizedBox(
                                                            height: 2,
                                                          ),
                                                          Text(
                                                            'หลังลด: ${display.discountedPriceLabel} บาท',
                                                            style:
                                                                const TextStyle(
                                                                  fontSize: 13,
                                                                  fontWeight:
                                                                      FontWeight
                                                                          .w700,
                                                                  color: Color(
                                                                    0xFFFFD180,
                                                                  ),
                                                                ),
                                                            maxLines: 1,
                                                            overflow:
                                                                TextOverflow
                                                                    .ellipsis,
                                                          ),
                                                        ] else
                                                          Text(
                                                            'ราคา: ${display.priceLabel} บาท',
                                                            style:
                                                                const TextStyle(
                                                                  fontSize: 13,
                                                                  color: Colors
                                                                      .white70,
                                                                ),
                                                            maxLines: 1,
                                                            overflow:
                                                                TextOverflow
                                                                    .ellipsis,
                                                          ),
                                                        Text(
                                                          'สต๊อก: ${display.stockLabel}',
                                                          style:
                                                              const TextStyle(
                                                                fontSize: 13,
                                                                color: Colors
                                                                    .white70,
                                                              ),
                                                          maxLines: 1,
                                                          overflow: TextOverflow
                                                              .ellipsis,
                                                        ),
                                                        _MerchantProductRatingSummary(
                                                          productId: doc.id,
                                                          compact: true,
                                                        ),
                                                        if (description
                                                            .isNotEmpty) ...[
                                                          const SizedBox(
                                                            height: 4,
                                                          ),
                                                          Text(
                                                            description,
                                                            style:
                                                                const TextStyle(
                                                                  fontSize: 12,
                                                                  color: Colors
                                                                      .white70,
                                                                  fontStyle:
                                                                      FontStyle
                                                                          .italic,
                                                                ),
                                                            maxLines: 2,
                                                            overflow:
                                                                TextOverflow
                                                                    .ellipsis,
                                                          ),
                                                        ],
                                                      ],
                                                    ),
                                                  ),
                                                ),
                                                if (discountPercent > 0)
                                                  Positioned(
                                                    top: 8,
                                                    right: 8,
                                                    child:
                                                        _buildHomeDiscountBadge(
                                                          discountPercent,
                                                        ),
                                                  ),
                                              ],
                                            ),
                                          ),
                                        ),
                                      );
                                    },
                                  ),
                                ),
                              ],
                            );
                          },
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HomeProductTypeGroup {
  const _HomeProductTypeGroup({
    required this.key,
    required this.label,
    required this.sortOrder,
    required this.products,
  });

  final String key;
  final String label;
  final int sortOrder;
  final List<CachedProduct> products;
}

List<_HomeProductTypeGroup> _groupHomeProductsByType(
  List<CachedProduct> products,
) {
  const fallbackType = 'อื่นๆ';
  const fallbackSort = 999999;
  final byType = <String, List<CachedProduct>>{};
  final labelsByKey = <String, String>{};
  final sortByKey = <String, int>{};

  for (final product in products) {
    final label = _readHomeProductTypeLabel(product.data);
    final key = _homeProductTypeKey(label);
    labelsByKey[key] = label;
    byType.putIfAbsent(key, () => <CachedProduct>[]).add(product);

    final sort = _parseHomeProductTypeSort(product.data['catalogTypeSort']);
    if (label != fallbackType && sort != null) {
      sortByKey[key] = sort;
    }
  }

  final groups =
      byType.entries
          .map((entry) {
            final label = labelsByKey[entry.key] ?? fallbackType;
            return _HomeProductTypeGroup(
              key: entry.key,
              label: label,
              sortOrder: label == fallbackType
                  ? fallbackSort
                  : (sortByKey[entry.key] ??
                        _defaultHomeProductTypeSort(label)),
              products: entry.value,
            );
          })
          .toList(growable: false)
        ..sort((left, right) {
          final sortCompare = left.sortOrder.compareTo(right.sortOrder);
          if (sortCompare != 0) {
            return sortCompare;
          }
          return left.label.compareTo(right.label);
        });

  return groups;
}

String _readHomeProductTypeLabel(Map<String, dynamic> data) {
  const fallbackType = 'อื่นๆ';
  final semanticSource = [
    data['name'],
    data['description'],
    data['productName'],
  ].map((value) => value?.toString().trim() ?? '').join(' ').toLowerCase();

  // ชื่อและรายละเอียดสินค้าที่รู้จักต้องชนะค่าหมวดเก่าที่อาจค้างอยู่
  // เช่น แก้วมังกรที่เคยถูกบันทึก catalogType เป็นยาและเวชภัณฑ์
  final marketType = _readHomeMarketProductTypeLabel(semanticSource);
  if (marketType != null) {
    return marketType;
  }
  if (_isHomePharmacyProduct(semanticSource)) {
    return 'ยาและเวชภัณฑ์';
  }

  // ใช้หมวดมาตรฐานที่ Cloud Function/AI จำแนกไว้เป็นแหล่งข้อมูลหลัก
  final catalogType = (data['catalogType'] ?? '').toString().trim();
  if (catalogType.isNotEmpty) {
    return catalogType;
  }

  final aiSource = [
    data['productCategory'],
    data['aiProductType'],
    data['productType'],
    data['catalogHeading'],
  ].map((value) => value?.toString().trim() ?? '').join(' ').toLowerCase();
  final aiMarketType = _readHomeMarketProductTypeLabel(aiSource);
  if (aiMarketType != null) {
    return aiMarketType;
  }
  if (_isHomePharmacyProduct(aiSource)) {
    return 'ยาและเวชภัณฑ์';
  }

  final aiType = (data['aiProductType'] ?? '').toString().trim();
  if (aiType.isNotEmpty) {
    return aiType;
  }
  final productType = (data['productType'] ?? '').toString().trim();
  if (productType.isNotEmpty) {
    return productType;
  }
  return fallbackType;
}

bool _homeProductContainsAny(String source, List<String> values) {
  return values.any((value) => source.contains(value));
}

String? _readHomeMarketProductTypeLabel(String source) {
  final isSeafood = _homeProductContainsAny(source, const <String>[
    'ปลา',
    'กุ้ง',
    'ปู',
    'หอย',
    'ปลาหมึก',
    'อาหารทะเล',
    'seafood',
    'fish',
    'shrimp',
    'crab',
    'squid',
    'shellfish',
  ]);
  final isDriedOrProcessed = _homeProductContainsAny(source, const <String>[
    'อาหารทะเลแปรรูป',
    'แปรรูป',
    'ของแห้ง',
    'แห้ง',
    'อบแห้ง',
    'ตากแห้ง',
    'แดดเดียว',
    'เค็ม',
    'รมควัน',
    'ถนอมอาหาร',
    'processed',
    'dried',
    'dry',
    'smoked',
    'salted',
  ]);

  if (isSeafood && isDriedOrProcessed) return 'อาหารทะเลแปรรูป';
  if (isSeafood) return 'อาหารทะเลสด';
  if (_homeProductContainsAny(source, const <String>[
    'เนื้อ',
    'หมู',
    'ไก่',
    'เป็ด',
    'วัว',
    'beef',
    'meat',
    'chicken',
    'pork',
    'duck',
  ])) {
    return 'เนื้อสัตว์';
  }
  if (_homeProductContainsAny(source, const <String>[
    'ไข่',
    'เต้าหู้',
    'tofu',
    'egg',
  ])) {
    return 'ไข่ / เต้าหู้';
  }
  if (_homeProductContainsAny(source, const <String>[
    'แก้วมังกร',
    'มังกร',
    'ผลไม้',
    'fruit',
    'มะม่วง',
    'กล้วย',
    'ส้ม',
    'ทุเรียน',
    'แอปเปิล',
    'แอปเปิ้ล',
    'องุ่น',
    'แตงโม',
    'สับปะรด',
    'ลำไย',
    'ลิ้นจี่',
    'ฝรั่ง',
    'มังคุด',
    'เงาะ',
  ])) {
    return 'ผลไม้';
  }
  if (_homeProductContainsAny(source, const <String>[
    'ผัก',
    'ผักสด',
    'vegetable',
    'คะน้า',
    'กะหล่ำ',
    'ผักบุ้ง',
    'แตงกวา',
    'มะเขือ',
    'ต้นหอม',
    'ผักชี',
    'พริก',
  ])) {
    return 'ผักสด';
  }
  if (_homeProductContainsAny(source, const <String>[
    'เครื่องปรุง',
    'น้ำปลา',
    'ซีอิ๊ว',
    'ซอส',
    'น้ำมันหอย',
    'ผงชูรส',
    'เกลือ',
    'น้ำตาล',
    'กะปิ',
    'ปลาร้า',
    'seasoning',
    'sauce',
  ])) {
    return 'เครื่องปรุง / ซอส';
  }
  if (isDriedOrProcessed ||
      _homeProductContainsAny(source, const <String>[
        'ข้าวสาร',
        'แป้ง',
        'ถั่ว',
        'ธัญพืช',
        'เส้นหมี่',
        'วุ้นเส้น',
        'บะหมี่',
        'มาม่า',
        'กะทิ',
        'วัตถุดิบ',
        'grocery',
        'pantry',
      ])) {
    return 'ของแห้ง / วัตถุดิบ';
  }
  if (_homeProductContainsAny(source, const <String>[
    'อาหารพร้อมทาน',
    'พร้อมทาน',
    'ข้าวกล่อง',
    'ข้าวแกง',
    'แกง',
    'ผัด',
    'ทอด',
    'ต้ม',
    'ยำ',
    'กับข้าว',
    'prepared',
    'cooked',
  ])) {
    return 'อาหารพร้อมทาน';
  }
  if (_homeProductContainsAny(source, const <String>[
    'ขนม',
    'เบเกอรี่',
    'เค้ก',
    'ปัง',
    'คุกกี้',
    'ของหวาน',
    'snack',
    'bakery',
    'dessert',
  ])) {
    return 'ขนม / เบเกอรี่';
  }
  if (_homeProductContainsAny(source, const <String>[
    'เครื่องดื่ม',
    'น้ำดื่ม',
    'น้ำอัดลม',
    'ชา',
    'กาแฟ',
    'นม',
    'beverage',
    'drink',
    'coffee',
    'tea',
  ])) {
    return 'เครื่องดื่ม';
  }
  if (_homeProductContainsAny(source, const <String>[
    'ชุดนักเรียน',
    'เครื่องแบบ',
    'uniform',
  ])) {
    return 'ชุดนักเรียน / เครื่องแบบ';
  }
  if (_homeProductContainsAny(source, const <String>[
    'รองเท้า',
    'กระเป๋า',
    'แตะ',
    'sneaker',
    'shoe',
    'bag',
  ])) {
    return 'รองเท้า / กระเป๋า';
  }
  if (_homeProductContainsAny(source, const <String>[
    'เสื้อ',
    'กางเกง',
    'กระโปรง',
    'เดรส',
    'ผ้า',
    'เสื้อผ้า',
    'clothes',
    'shirt',
    'pants',
    'dress',
  ])) {
    return 'เสื้อผ้า';
  }
  if (_homeProductContainsAny(source, const <String>[
    'สมุด',
    'หนังสือ',
    'ดินสอ',
    'ปากกา',
    'ยางลบ',
    'ไม้บรรทัด',
    'เครื่องเขียน',
    'อุปกรณ์เรียน',
    'stationery',
    'notebook',
    'pencil',
    'pen',
  ])) {
    return 'เครื่องเขียน / อุปกรณ์เรียน';
  }
  if (_homeProductContainsAny(source, const <String>[
    'น้ำยาล้างจาน',
    'ผงซักฟอก',
    'น้ำยาปรับผ้านุ่ม',
    'ไม้กวาด',
    'ถุงขยะ',
    'ทิชชู่',
    'ของใช้ในบ้าน',
    'household',
    'detergent',
  ])) {
    return 'ของใช้ในบ้าน';
  }
  if (_homeProductContainsAny(source, const <String>[
    'สบู่',
    'แชมพู',
    'ยาสีฟัน',
    'แปรงสีฟัน',
    'ครีม',
    'โลชั่น',
    'ของใช้ส่วนตัว',
    'personal care',
    'shampoo',
    'soap',
  ])) {
    return 'ของใช้ส่วนตัว';
  }
  return null;
}

bool _isHomePharmacyProduct(String source) {
  return _homeProductContainsAny(source, const <String>[
    'ยา',
    'เวชภัณฑ์',
    'เภสัช',
    'pharmacy',
    'medicine',
    'drug',
    'medical',
    'พารา',
    'paracetamol',
    'ibuprofen',
    'ไอบู',
    'แก้แพ้',
    'loratadine',
    'cetirizine',
    'แก้ไอ',
    'ลดน้ำมูก',
    'ท้องเสีย',
    'ลดกรด',
    'ยาระบาย',
    'เกลือแร่',
    'ยาหม่อง',
    'เบตาดีน',
    'betadine',
    'พลาสเตอร์',
    'ผ้าก๊อซ',
    'สำลี',
    'แอลกอฮอล์',
    'หน้ากาก',
    'ถุงมือ',
    'ปรอทวัดไข้',
    'เครื่องวัดความดัน',
    'วิตามิน',
    'อาหารเสริม',
    'คอลลาเจน',
    'แคลเซียม',
    'ผ้าอ้อม',
    'ขวดนม',
    'นมผง',
    'ยาสีฟัน',
    'แปรงสีฟัน',
    'น้ำยาบ้วนปาก',
    'ครีมกันแดด',
    'โลชั่น',
    'โฟมล้างหน้า',
    'น้ำเกลือ',
  ]);
}

String _homeProductTypeKey(String label) {
  final normalized = label.trim();
  return normalized.isEmpty ? 'อื่นๆ' : normalized;
}

int? _parseHomeProductTypeSort(Object? value) {
  if (value is num) {
    return value.toInt();
  }
  if (value is String) {
    return int.tryParse(value.trim());
  }
  return null;
}

int _defaultHomeProductTypeSort(String label) {
  switch (label) {
    case 'ผักสด':
      return 10;
    case 'ผลไม้':
      return 20;
    case 'เนื้อสัตว์':
      return 30;
    case 'อาหารทะเลสด':
      return 40;
    case 'อาหารทะเลแปรรูป':
      return 50;
    case 'ไข่ / เต้าหู้':
      return 60;
    case 'อาหารพร้อมทาน':
      return 70;
    case 'ของแห้ง / วัตถุดิบ':
    case 'ของแห้ง':
      return 80;
    case 'เครื่องปรุง / ซอส':
      return 90;
    case 'ขนม / เบเกอรี่':
      return 100;
    case 'เครื่องดื่ม':
      return 110;
    case 'เสื้อผ้า':
      return 120;
    case 'ชุดนักเรียน / เครื่องแบบ':
      return 130;
    case 'รองเท้า / กระเป๋า':
      return 140;
    case 'ของใช้ในบ้าน':
      return 150;
    case 'ของใช้ส่วนตัว':
      return 160;
    case 'เครื่องเขียน / อุปกรณ์เรียน':
      return 170;
    case 'ยาและเวชภัณฑ์':
      return 180;
    case 'ของสด':
      return 190;
    default:
      return 500000;
  }
}

class _MerchantProductRatingSummary extends StatelessWidget {
  const _MerchantProductRatingSummary({
    required this.productId,
    this.compact = false,
  });

  final String productId;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    if (productId.trim().isEmpty) {
      return const SizedBox.shrink();
    }

    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('product_review_stats')
          .doc(productId)
          .snapshots(),
      builder: (context, snapshot) {
        final data = snapshot.data?.data();
        final count = (data?['ratingCount'] as num?)?.toInt() ?? 0;
        final average = (data?['ratingAverage'] as num?)?.toDouble() ?? 0;
        if (count <= 0 || average <= 0) {
          return const SizedBox.shrink();
        }

        return Padding(
          padding: EdgeInsets.only(top: compact ? 2 : 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(
                Icons.star_rounded,
                size: compact ? 14 : 16,
                color: const Color(0xFFF59E0B),
              ),
              const SizedBox(width: 3),
              Flexible(
                child: Text(
                  '${average.toStringAsFixed(1)} ($count รีวิว)',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: compact ? Colors.white70 : const Color(0xFF92400E),
                    fontSize: compact ? 12 : 13,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _MerchantProductRecentReviews extends StatelessWidget {
  const _MerchantProductRecentReviews({required this.productId});

  final String productId;

  @override
  Widget build(BuildContext context) {
    if (productId.trim().isEmpty) {
      return const SizedBox.shrink();
    }

    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('product_reviews')
          .where('productId', isEqualTo: productId)
          .where('status', isEqualTo: 'visible')
          .limit(5)
          .snapshots(),
      builder: (context, snapshot) {
        final docs = snapshot.data?.docs ?? const [];
        if (docs.isEmpty) {
          return const SizedBox.shrink();
        }

        final reviews = docs.map((doc) => doc.data()).toList(growable: false)
          ..sort((left, right) {
            final leftTs = left['updatedAt'] ?? left['createdAt'];
            final rightTs = right['updatedAt'] ?? right['createdAt'];
            final leftMs = leftTs is Timestamp
                ? leftTs.millisecondsSinceEpoch
                : 0;
            final rightMs = rightTs is Timestamp
                ? rightTs.millisecondsSinceEpoch
                : 0;
            return rightMs.compareTo(leftMs);
          });

        return Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                'รีวิวจากลูกค้า',
                style: Theme.of(
                  context,
                ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 6),
              for (final review in reviews) ...<Widget>[
                _MerchantReviewPreview(review: review),
                if (review != reviews.last) const Divider(height: 14),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _MerchantReviewPreview extends StatelessWidget {
  const _MerchantReviewPreview({required this.review});

  final Map<String, dynamic> review;

  @override
  Widget build(BuildContext context) {
    final rating = (review['rating'] as num?)?.toInt() ?? 0;
    final comment = (review['comment'] as String?)?.trim() ?? '';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            for (var index = 1; index <= 5; index++)
              Icon(
                index <= rating
                    ? Icons.star_rounded
                    : Icons.star_border_rounded,
                size: 16,
                color: const Color(0xFFF59E0B),
              ),
          ],
        ),
        if (comment.isNotEmpty) ...<Widget>[
          const SizedBox(height: 4),
          Text(
            comment,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 13, color: Colors.black87),
          ),
        ],
      ],
    );
  }
}

class _KeepAlivePage extends StatefulWidget {
  const _KeepAlivePage({required this.child});

  final Widget child;

  @override
  State<_KeepAlivePage> createState() => _KeepAlivePageState();
}

class _KeepAlivePageState extends State<_KeepAlivePage>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}

class _ProductGalleryContent extends StatefulWidget {
  const _ProductGalleryContent({
    required this.images,
    required this.name,
    required this.description,
    required this.productId,
    required this.productData,
    required this.variants,
    required this.discountPercent,
    this.videoUrl,
    this.videoThumbnailUrl,
    Key? key,
  }) : super(key: key);

  final List<String> images;
  final String? videoUrl;
  final String? videoThumbnailUrl;
  final String name;
  final String description;
  final String productId;
  final Map<String, dynamic> productData;
  final List<ProductVariant> variants;
  final double discountPercent;

  @override
  State<_ProductGalleryContent> createState() => _ProductGalleryContentState();
}

class _ProductGalleryContentState extends State<_ProductGalleryContent> {
  late final PageController _pageController;
  int _currentIndex = 0;

  @override
  void initState() {
    super.initState();
    _pageController = PageController();
    if (widget.videoUrl != null && widget.videoUrl!.isNotEmpty) {
      VideoPrefetchService.instance.preloadVideo(widget.videoUrl!);
    }
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hasImages = widget.images.isNotEmpty;
    final theme = Theme.of(context);
    final hasVideo = widget.videoUrl != null && widget.videoUrl!.isNotEmpty;
    final totalPages = hasImages
        ? widget.images.length + (hasVideo ? 1 : 0)
        : (hasVideo ? 1 : 0);
    final canSwipe = totalPages > 1;
    final onVideoPage = hasVideo && _currentIndex == totalPages - 1;
    final imageIndex =
        hasImages && !onVideoPage && _currentIndex < widget.images.length
        ? _currentIndex
        : 0;
    final display = onVideoPage
        ? _resolveHomeProductDisplay(widget.productData, imageIndex: 0)
        : _resolveHomeProductDisplay(
            widget.productData,
            imageIndex: imageIndex,
          );
    final priceLine = display.discountPercent > 0
        ? 'ราคาเต็ม: ${display.priceLabel} บาท · หลังลด: ${display.discountedPriceLabel} บาท'
        : 'ราคา: ${display.priceLabel} บาท';

    return SizedBox(
      width: MediaQuery.of(context).size.width * 0.85,
      height: MediaQuery.of(context).size.height * 0.7,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  widget.name.isNotEmpty ? widget.name : 'รายละเอียดสินค้า',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              IconButton(
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close),
                tooltip: 'ปิด',
              ),
            ],
          ),
          const SizedBox(height: 12),
          Expanded(
            child: _buildGalleryArea(
              hasImages: hasImages,
              hasVideo: hasVideo,
              canSwipe: canSwipe,
              totalPages: totalPages,
            ),
          ),
          if (canSwipe && totalPages > 1)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(totalPages, (index) {
                  final isActive = index == _currentIndex;
                  return AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    margin: const EdgeInsets.symmetric(horizontal: 3),
                    width: isActive ? 12 : 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: isActive ? AppColors.accent : Colors.grey[400],
                      borderRadius: BorderRadius.circular(8),
                    ),
                  );
                }),
              ),
            ),
          const Divider(),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(4, 0, 4, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    priceLine,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (display.hasOptions) ...[
                    const SizedBox(height: 6),
                    if (display.colors.isNotEmpty) ...[
                      Text(
                        'สี',
                        style: theme.textTheme.labelLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 6),
                      ProductVariantColorSwatchRow(
                        colors: display.colors,
                        size: 28,
                        spacing: 8,
                      ),
                    ],
                    if (display.sizes.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Text(
                        'ขนาด',
                        style: theme.textTheme.labelLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        display.sizes.join(' · '),
                        style: const TextStyle(
                          fontSize: 14,
                          color: Colors.black87,
                        ),
                      ),
                    ],
                  ],
                  _MerchantProductRatingSummary(productId: widget.productId),
                  _MerchantProductRecentReviews(productId: widget.productId),
                  const SizedBox(height: 4),
                  Text(
                    'สต๊อก: ${display.stockLabel}',
                    style: const TextStyle(fontSize: 14, color: Colors.black87),
                  ),
                  if (widget.description.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Text(
                      'คำอธิบาย',
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      widget.description,
                      style: const TextStyle(
                        fontSize: 14,
                        color: Colors.black87,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGalleryArea({
    required bool hasImages,
    required bool hasVideo,
    required bool canSwipe,
    required int totalPages,
  }) {
    if (!hasImages && !hasVideo) {
      return _buildGalleryPlaceholder();
    }

    if (!canSwipe) {
      if (hasImages) {
        return _buildGalleryImage(widget.images.first);
      }
      return _buildGalleryVideo(isActive: true);
    }

    return PageView.builder(
      controller: _pageController,
      itemCount: totalPages,
      onPageChanged: (index) => setState(() => _currentIndex = index),
      itemBuilder: (context, index) {
        if (hasImages && index < widget.images.length) {
          return _buildGalleryImage(widget.images[index]);
        }
        if (hasVideo && index == totalPages - 1) {
          return _buildGalleryVideo(isActive: _currentIndex == index);
        }
        return _buildGalleryPlaceholder();
      },
    );
  }

  Widget _buildGalleryImage(String url) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: ProductNetworkImage(
        urls: <String>[url],
        fit: BoxFit.cover,
        memCacheWidth: 800,
      ),
    );
  }

  Widget _buildGalleryVideo({required bool isActive}) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: _KeepAlivePage(
        child: ProductVideoPlayer(
          videoUrl: widget.videoUrl!,
          thumbnailUrl: widget.videoThumbnailUrl,
          isActive: isActive,
        ),
      ),
    );
  }

  Widget _buildGalleryPlaceholder() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.grey[200],
        borderRadius: BorderRadius.circular(12),
      ),
      alignment: Alignment.center,
      child: const Icon(
        Icons.image_not_supported,
        size: 64,
        color: Colors.grey,
      ),
    );
  }
}

class _ShopStatusToggle extends StatefulWidget {
  const _ShopStatusToggle({
    required this.isOpen,
    required this.onToggle,
    this.width = 160,
  });

  final bool isOpen;
  final ValueChanged<bool> onToggle;
  final double width;

  @override
  State<_ShopStatusToggle> createState() => _ShopStatusToggleState();
}

class _ShopStatusToggleState extends State<_ShopStatusToggle> {
  static const double _padding = 4;

  double? _dragFraction;
  double _dragBaseFraction = 0;
  late bool _localOpen;

  double get _currentFraction => _dragFraction ?? (_localOpen ? 0.0 : 1.0);

  @override
  void didUpdateWidget(covariant _ShopStatusToggle oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isOpen != widget.isOpen && _dragFraction == null) {
      _localOpen = widget.isOpen;
      _dragBaseFraction = _localOpen ? 0.0 : 1.0;
    }
  }

  @override
  void initState() {
    super.initState();
    _localOpen = widget.isOpen;
    _dragBaseFraction = _localOpen ? 0.0 : 1.0;
  }

  void _handleTap() {
    final next = !_localOpen;
    widget.onToggle(next);
    setState(() {
      _localOpen = next;
      _dragBaseFraction = next ? 0.0 : 1.0;
      _dragFraction = null;
    });
  }

  void _handleDragStart(DragStartDetails details) {
    _dragBaseFraction = _currentFraction;
    _dragFraction = _dragBaseFraction;
  }

  void _handleDragUpdate(DragUpdateDetails details) {
    final availableWidth = widget.width - (_padding * 2);
    if (availableWidth <= 0) return;
    final delta = (details.primaryDelta ?? 0) / availableWidth;
    setState(() {
      final current = _dragFraction ?? _dragBaseFraction;
      final next = (current + delta).clamp(0.0, 1.0);
      _dragFraction = next;
      _dragBaseFraction = next;
    });
  }

  void _handleDragEnd([DragEndDetails? details]) {
    final fraction = _currentFraction;
    final velocity = details?.velocity.pixelsPerSecond.dx ?? 0;
    final shouldOpen = velocity.abs() > 200 ? velocity < 0 : fraction < 0.5;
    widget.onToggle(shouldOpen);
    setState(() {
      _localOpen = shouldOpen;
      _dragBaseFraction = shouldOpen ? 0.0 : 1.0;
      _dragFraction = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final fraction = _currentFraction;
    final bool highlightOpen = _localOpen;
    final alignment = Alignment(fraction * 2 - 1, 0);

    return Tooltip(
      message: highlightOpen ? 'เลื่อนเพื่อปิดร้าน' : 'เลื่อนเพื่อเปิดร้าน',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _handleTap,
        onHorizontalDragStart: _handleDragStart,
        onHorizontalDragUpdate: _handleDragUpdate,
        onHorizontalDragEnd: _handleDragEnd,
        onHorizontalDragCancel: () => setState(() => _dragFraction = null),
        child: Container(
          width: widget.width,
          height: 40,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: Colors.white70),
            boxShadow: const [
              BoxShadow(
                color: Colors.black12,
                blurRadius: 6,
                offset: Offset(0, 2),
              ),
            ],
          ),
          child: Stack(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: _padding,
                  vertical: 4,
                ),
                child: AnimatedAlign(
                  alignment: alignment,
                  duration: Duration(
                    milliseconds: _dragFraction != null ? 0 : 220,
                  ),
                  curve: Curves.easeOut,
                  child: FractionallySizedBox(
                    widthFactor: 0.5,
                    heightFactor: 1,
                    child: Container(
                      decoration: BoxDecoration(
                        color: highlightOpen ? Colors.green : AppColors.accent,
                        borderRadius: BorderRadius.circular(18),
                        boxShadow: const [
                          BoxShadow(
                            color: Colors.black26,
                            blurRadius: 6,
                            offset: Offset(0, 3),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              Row(
                children: [
                  Expanded(
                    child: Center(
                      child: Text(
                        'เปิดร้าน',
                        style: TextStyle(
                          color: highlightOpen
                              ? Colors.white
                              : Colors.grey[700],
                          fontSize: widget.width < 140 ? 12 : 14,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                  Expanded(
                    child: Center(
                      child: Text(
                        'ปิดร้าน',
                        style: TextStyle(
                          color: highlightOpen
                              ? Colors.grey[700]
                              : Colors.white,
                          fontSize: widget.width < 140 ? 12 : 14,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
