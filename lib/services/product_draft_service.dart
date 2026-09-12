import 'package:cloud_firestore/cloud_firestore.dart';

/// Persists in-progress add-product sessions so AI results survive navigation.
class ProductDraftService {
  ProductDraftService._();

  static final ProductDraftService instance = ProductDraftService._();

  CollectionReference<Map<String, dynamic>> _items(String ownerUid) {
    return FirebaseFirestore.instance
        .collection('product_drafts')
        .doc(ownerUid)
        .collection('items');
  }

  DocumentReference<Map<String, dynamic>> draftRef(
    String ownerUid,
    String draftId,
  ) {
    return _items(ownerUid).doc(draftId);
  }

  Future<void> upsertDraft({
    required String ownerUid,
    required String draftId,
    required Map<String, dynamic> patch,
  }) async {
    await draftRef(ownerUid, draftId).set(
      {
        ...patch,
        'updatedAt': FieldValue.serverTimestamp(),
        'expiresAtMillis':
            DateTime.now().add(const Duration(hours: 48)).millisecondsSinceEpoch,
      },
      SetOptions(merge: true),
    );
  }

  Future<Map<String, dynamic>?> loadDraft({
    required String ownerUid,
    required String draftId,
    Source source = Source.serverAndCache,
  }) async {
    final snap = await draftRef(ownerUid, draftId).get(
      GetOptions(source: source),
    );
    if (!snap.exists) {
      return null;
    }
    return snap.data();
  }

  Stream<DocumentSnapshot<Map<String, dynamic>>> watchDraft({
    required String ownerUid,
    required String draftId,
  }) {
    return draftRef(ownerUid, draftId).snapshots();
  }

  Future<void> deleteDraft({
    required String ownerUid,
    required String draftId,
  }) async {
    await draftRef(ownerUid, draftId).delete();
  }
}
