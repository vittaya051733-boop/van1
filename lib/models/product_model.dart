import 'package:cloud_firestore/cloud_firestore.dart';

class Product {
  final String? id; // Add ID field
  final String name;
  final String description;
  final String? toppings;
  final String? productCategory;
  final bool isFreshProduct;
  final bool isProcessed;
  final String? taxStatus;
  final double price;
  final double discountPercent;
  final int stock;
  final int preparationTimeMinutes;
  final List<String> imageUrls;
  final List<String> thumbnailUrls;
  final List<String> colors;
  final List<String> sizes;
  final String unit;
  final double? weight;
  final double? parcelLengthCm;
  final double? parcelWidthCm;
  final double? parcelHeightCm;
  final String? videoUrl;
  final String? videoThumbnailUrl;
  final bool aiDescriptionRequested;
  final bool aiWhiteBackgroundRequested;
  final bool aiProductAnalysisRequested;
  final bool? aiIsLegalInThailand;
  final String? aiLegalAnalysisReason;
  final String? aiProductType;
  final String? taxAiReason;
  final bool? canShipNationwide;
  final String? nationwideShippingReason;
  final bool isPendingAdminReview;
  final String? adminReviewId;

  Product({
    this.id, // Add to constructor
    required this.name,
    required this.description,
    this.toppings,
    this.productCategory,
    this.isFreshProduct = false,
    this.isProcessed = false,
    this.taxStatus,
    required this.price,
    this.discountPercent = 0,
    required this.stock,
    this.preparationTimeMinutes = 10,
    required this.imageUrls,
    required this.thumbnailUrls,
    required this.colors,
    required this.sizes,
    required this.unit,
    this.weight,
    this.parcelLengthCm,
    this.parcelWidthCm,
    this.parcelHeightCm,
    this.videoUrl,
    this.videoThumbnailUrl,
    this.aiDescriptionRequested = false,
    this.aiWhiteBackgroundRequested = false,
    this.aiProductAnalysisRequested = false,
    this.aiIsLegalInThailand,
    this.aiLegalAnalysisReason,
    this.aiProductType,
    this.taxAiReason,
    this.canShipNationwide,
    this.nationwideShippingReason,
    this.isPendingAdminReview = false,
    this.adminReviewId,
  });

  // Method to convert a Product instance to a map.
  Map<String, dynamic> toMap() {
    return {
      'name': name,
      'description': description,
      'toppings': toppings,
      'productCategory': productCategory,
      'isFreshProduct': isFreshProduct,
      'isProcessed': isProcessed,
      'taxStatus': taxStatus,
      'price': price,
      if (discountPercent > 0) 'discountPercent': discountPercent,
      'stock': stock,
      'preparationTimeMinutes': preparationTimeMinutes,
      'preparingDuration': preparationTimeMinutes * 60 * 1000,
      'imageUrls': imageUrls,
      'thumbnailUrls': thumbnailUrls,
      'colors': colors,
      'sizes': sizes,
      'unit': unit,
      'weight': weight,
      'parcelLengthCm': parcelLengthCm,
      'parcelWidthCm': parcelWidthCm,
      'parcelHeightCm': parcelHeightCm,
      'videoUrl': videoUrl,
      'videoThumbnailUrl': videoThumbnailUrl,
      'aiDescriptionRequested': aiDescriptionRequested,
      'aiWhiteBackgroundRequested': aiWhiteBackgroundRequested,
      'aiProductAnalysisRequested': aiProductAnalysisRequested,
      'aiIsLegalInThailand': aiIsLegalInThailand,
      'aiLegalAnalysisReason': aiLegalAnalysisReason,
      'aiProductType': aiProductType,
      'taxAiReason': taxAiReason,
      'canShipNationwide': canShipNationwide,
      'nationwideShippingReason': nationwideShippingReason,
      'createdAt':
          FieldValue.serverTimestamp(), // Automatically add a timestamp
    };
  }

  // Factory constructor to create a Product from a Firestore document.
  factory Product.fromSnapshot(DocumentSnapshot<Map<String, dynamic>> doc) {
    return Product._fromMap(doc.id, doc.data() ?? <String, dynamic>{});
  }

  /// Creates a product from the app's local cache without using Firestore.
  factory Product.fromMap(String id, Map<String, dynamic> map) {
    return Product._fromMap(id, map);
  }

  /// สินค้าที่รอแอดมินอนุมัติ (ยังไม่อยู่ใน collection products)
  factory Product.fromAdminReviewSnapshot(
    DocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    return Product._fromMap(
      doc.id,
      doc.data() ?? <String, dynamic>{},
      isPendingAdminReview: true,
      adminReviewId: doc.id,
    );
  }

  factory Product._fromMap(
    String id,
    Map<String, dynamic> map, {
    bool isPendingAdminReview = false,
    String? adminReviewId,
  }) {
    double? parsedWeight;
    final weightValue = map['weight'];
    if (weightValue is num) {
      parsedWeight = weightValue.toDouble();
    } else if (weightValue is String) {
      parsedWeight = double.tryParse(weightValue);
    }
    return Product(
      id: id,
      name: map['name'] ?? '',
      description: map['description'] ?? '',
      toppings: map['toppings'] as String?,
      productCategory: map['productCategory'] as String?,
      isFreshProduct: (map['isFreshProduct'] as bool?) ?? false,
      isProcessed: (map['isProcessed'] as bool?) ?? false,
      taxStatus: map['taxStatus'] as String?,
      price: (map['price'] as num?)?.toDouble() ?? 0.0,
      discountPercent: (map['discountPercent'] as num?)?.toDouble() ?? 0.0,
      stock: (map['stock'] as num?)?.toInt() ?? 0,
      preparationTimeMinutes:
          (map['preparationTimeMinutes'] as num?)?.toInt() ??
          (((map['preparingDuration'] as num?)?.toInt() ?? 600000) / 60000)
              .round(),
      imageUrls: List<String>.from(map['imageUrls'] ?? []),
      thumbnailUrls: List<String>.from(
        (map['thumbnailUrls'] ?? map['imageUrls']) ?? [],
      ),
      colors: List<String>.from(map['colors'] ?? []),
      sizes: List<String>.from(map['sizes'] ?? []),
      unit: map['unit'] ?? '',
      weight: parsedWeight,
      parcelLengthCm: (map['parcelLengthCm'] as num?)?.toDouble(),
      parcelWidthCm: (map['parcelWidthCm'] as num?)?.toDouble(),
      parcelHeightCm: (map['parcelHeightCm'] as num?)?.toDouble(),
      videoUrl: map['videoUrl'] as String?,
      videoThumbnailUrl: map['videoThumbnailUrl'] as String?,
      aiDescriptionRequested: (map['aiDescriptionRequested'] as bool?) ?? false,
      aiWhiteBackgroundRequested:
          (map['aiWhiteBackgroundRequested'] as bool?) ?? false,
      aiProductAnalysisRequested:
          (map['aiProductAnalysisRequested'] as bool?) ?? false,
      aiIsLegalInThailand: map['aiIsLegalInThailand'] as bool?,
      aiLegalAnalysisReason: map['aiLegalAnalysisReason'] as String?,
      aiProductType: map['aiProductType'] as String?,
      taxAiReason: map['taxAiReason'] as String?,
      canShipNationwide: map['canShipNationwide'] as bool?,
      nationwideShippingReason: map['nationwideShippingReason'] as String?,
      isPendingAdminReview: isPendingAdminReview,
      adminReviewId: adminReviewId,
    );
  }

  Product copyWith({double? discountPercent}) {
    return Product(
      id: id,
      name: name,
      description: description,
      toppings: toppings,
      productCategory: productCategory,
      isFreshProduct: isFreshProduct,
      isProcessed: isProcessed,
      taxStatus: taxStatus,
      price: price,
      discountPercent: discountPercent ?? this.discountPercent,
      stock: stock,
      preparationTimeMinutes: preparationTimeMinutes,
      imageUrls: imageUrls,
      thumbnailUrls: thumbnailUrls,
      colors: colors,
      sizes: sizes,
      unit: unit,
      weight: weight,
      parcelLengthCm: parcelLengthCm,
      parcelWidthCm: parcelWidthCm,
      parcelHeightCm: parcelHeightCm,
      videoUrl: videoUrl,
      videoThumbnailUrl: videoThumbnailUrl,
      aiDescriptionRequested: aiDescriptionRequested,
      aiWhiteBackgroundRequested: aiWhiteBackgroundRequested,
      aiProductAnalysisRequested: aiProductAnalysisRequested,
      aiIsLegalInThailand: aiIsLegalInThailand,
      aiLegalAnalysisReason: aiLegalAnalysisReason,
      aiProductType: aiProductType,
      taxAiReason: taxAiReason,
      canShipNationwide: canShipNationwide,
      nationwideShippingReason: nationwideShippingReason,
      isPendingAdminReview: isPendingAdminReview,
      adminReviewId: adminReviewId,
    );
  }
}
