import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import 'add_product_screen.dart';
import 'models/product_model.dart';
import 'utils/app_colors.dart';
import 'widgets/cached_app_image.dart';

class LowStockProductsScreen extends StatelessWidget {
  const LowStockProductsScreen({super.key, required this.shopId, this.threshold = 5});

  final String shopId;
  final int threshold;

  int _readStock(dynamic value) {
    if (value is num) {
      return value.toInt();
    }
    if (value is String) {
      return int.tryParse(value.trim()) ?? 0;
    }
    return 0;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('สินค้าใกล้หมด'),
        backgroundColor: AppColors.accent,
        foregroundColor: Colors.white,
      ),
      body: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: FirebaseFirestore.instance
            .collection('products')
            .where('ownerUid', isEqualTo: shopId)
            .snapshots(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          if (snapshot.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'โหลดรายการสินค้าใกล้หมดไม่สำเร็จ: ${snapshot.error}',
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }

          final productDocs = (snapshot.data?.docs ?? const [])
              .where((doc) => _readStock(doc.data()['stock']) < threshold)
              .toList(growable: false)
            ..sort((a, b) =>
                _readStock(a.data()['stock']).compareTo(_readStock(b.data()['stock'])));

          if (productDocs.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: const [
                    Icon(Icons.inventory_2_outlined, size: 72, color: Colors.grey),
                    SizedBox(height: 16),
                    Text(
                      'ยังไม่มีสินค้าใกล้หมด',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                    ),
                    SizedBox(height: 8),
                    Text(
                      'สินค้าทั้งหมดตอนนี้มีสต๊อกตั้งแต่ 5 ชิ้นขึ้นไป',
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            );
          }

          return ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: productDocs.length,
            separatorBuilder: (_, __) => const SizedBox(height: 12),
            itemBuilder: (context, index) {
              final doc = productDocs[index];
              final product = Product.fromSnapshot(doc);
              final imageUrls = product.imageUrls;
              final stock = _readStock(doc.data()['stock']);
              final unit = product.unit.trim();
              final category = product.productCategory?.trim();
              return Card(
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                child: ListTile(
                  contentPadding: const EdgeInsets.all(12),
                  onTap: () async {
                    await Navigator.of(context).push<AddProductSaveResult>(
                      MaterialPageRoute<AddProductSaveResult>(
                        builder: (_) => AddProductScreen(productToEdit: product),
                      ),
                    );
                  },
                  leading: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: imageUrls.isNotEmpty
                        ? CachedAppImage(
                            imageUrl: imageUrls.first,
                            width: 56,
                            height: 56,
                            fit: BoxFit.cover,
                          )
                        : Container(
                            width: 56,
                            height: 56,
                            color: const Color(0xFFF1F5F9),
                            child: const Icon(Icons.inventory_2_outlined),
                          ),
                  ),
                  title: Text(
                    product.name.trim().isNotEmpty ? product.name.trim() : 'สินค้าไม่มีชื่อ',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (category != null && category.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(category),
                      ],
                      const SizedBox(height: 6),
                      Text(
                        'คงเหลือ $stock ${unit.isNotEmpty ? unit : 'ชิ้น'}',
                        style: const TextStyle(
                          color: Colors.deepOrange,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                  trailing: OutlinedButton.icon(
                    onPressed: () async {
                      await Navigator.of(context).push<AddProductSaveResult>(
                        MaterialPageRoute<AddProductSaveResult>(
                          builder: (_) => AddProductScreen(productToEdit: product),
                        ),
                      );
                    },
                    icon: const Icon(Icons.edit_outlined, size: 18),
                    label: const Text('แก้สต๊อก'),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}