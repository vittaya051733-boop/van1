// ...existing code...
const functions = require('firebase-functions/v1');
const { defineSecret } = require('firebase-functions/params');
const logger = require('firebase-functions/logger');
const { HttpsError, onCall } = require('firebase-functions/v2/https');
const { onSchedule } = require('firebase-functions/v2/scheduler');
const { onDocumentWritten, onDocumentCreated } = require('firebase-functions/v2/firestore');
const admin = require('firebase-admin');
const crypto = require('crypto');
const nodemailer = require('nodemailer');
const Redis = require('ioredis');
const sharp = require('sharp');
const catalogTaxonomy = require('./catalog_taxonomy');
const DEFAULT_REGION = 'asia-southeast1';
const CALL_TTL_MS = 30 * 1000; // 30 seconds
const ACTIVE_CALL_INVITES_COLLECTION = 'active_call_invites';
// แจ้งเตือนข้อความแชตใหม่ (Firestore Trigger)
exports.notifyNewChatMessage = functions.region(DEFAULT_REGION).firestore
  .document('chats/{chatId}/messages/{messageId}')
  .onCreate((snap, context) => _handleChatMessageTrigger('chats', snap, context));

exports.notifyLegacyChatMessage = functions.region(DEFAULT_REGION).firestore
  .document('chatRooms/{chatId}/messages/{messageId}')
  .onCreate((snap, context) => _handleChatMessageTrigger('chatRooms', snap, context));

async function _handleChatMessageTrigger(collectionName, snap, context) {
  const message = snap.data();
  if (!message) {
    console.warn(`[notifyNewChatMessage:${collectionName}] Empty snapshot`);
    return;
  }

  const chatId = context.params.chatId;
  const senderId = message.senderId;
  let receiverId = message.receiverId;

  if (!receiverId) {
    receiverId = await _resolveReceiverId(chatId, senderId);
  }

  if (!receiverId) {
    console.warn(`[notifyNewChatMessage:${collectionName}] Unable to resolve receiver for chat ${chatId}`);
    return;
  }

  const fcmToken = await resolveAnyRecipientFcmToken(receiverId);
  if (!fcmToken) {
    console.warn(`[notifyNewChatMessage:${collectionName}] No FCM token for user ${receiverId}`);
    return;
  }

  await _sendChatNotification({
    title: message.senderName || 'ข้อความใหม่',
    previewText: _resolveMessagePreview(message),
    chatId,
    senderId,
    receiverId,
    fcmToken,
    orderId: await _resolveChatOrderId(chatId, message),
    collectionName,
  });
}

async function resolveAnyRecipientFcmToken(recipientUid) {
  if (!recipientUid) return null;

  for (const collection of CUSTOMER_COLLECTIONS) {
    try {
      const doc = await db.collection(collection).doc(recipientUid).get();
      const token = String(doc.data()?.fcmToken || '').trim();
      if (token) return token;
    } catch (_) {}
  }

  for (const collection of RIDER_COLLECTIONS) {
    try {
      const doc = await db.collection(collection).doc(recipientUid).get();
      const token = String(doc.data()?.fcmToken || '').trim();
      if (token) return token;
    } catch (_) {}
  }

  for (const collection of SHOP_COLLECTIONS) {
    try {
      const doc = await db.collection(collection).doc(recipientUid).get();
      const token = String(doc.data()?.shopFCMToken || '').trim();
      if (token) return token;
    } catch (_) {}
  }

  return null;
}

async function resolveCallRecipientFcmToken(recipientUid) {
  if (!recipientUid) return null;

  try {
    const userDoc = await db.collection('users').doc(recipientUid).get();
    const token = String(userDoc.data()?.fcmToken || '').trim();
    if (token) return token;
  } catch (_) {}

  for (const collection of SHOP_COLLECTIONS) {
    try {
      const doc = await db.collection(collection).doc(recipientUid).get();
      const token = String(doc.data()?.shopFCMToken || '').trim();
      if (token) return token;
    } catch (_) {}
  }

  for (const collection of RIDER_COLLECTIONS) {
    try {
      const doc = await db.collection(collection).doc(recipientUid).get();
      const token = String(doc.data()?.fcmToken || '').trim();
      if (token) return token;
    } catch (_) {}
  }

  for (const collection of CUSTOMER_COLLECTIONS) {
    try {
      const doc = await db.collection(collection).doc(recipientUid).get();
      const token = String(doc.data()?.fcmToken || '').trim();
      if (token) return token;
    } catch (_) {}
  }

  return null;
}

function isUnregisteredFcmTokenError(error) {
  const text = [
    error?.code,
    error?.errorInfo?.code,
    error?.message,
  ].filter(Boolean).join(' ').toLowerCase();
  return text.includes('notregistered') ||
    text.includes('registration-token-not-registered') ||
    text.includes('requested entity was not found');
}

async function clearInvalidRecipientFcmToken(recipientUid, invalidToken) {
  if (!recipientUid || !invalidToken) return;

  const targets = [
    { collection: 'users', field: 'fcmToken' },
    ...SHOP_COLLECTIONS.map((collection) => ({ collection, field: 'shopFCMToken' })),
    ...RIDER_COLLECTIONS.map((collection) => ({ collection, field: 'fcmToken' })),
    ...CUSTOMER_COLLECTIONS.map((collection) => ({ collection, field: 'fcmToken' })),
  ];

  await Promise.all(targets.map(async ({ collection, field }) => {
    try {
      const ref = db.collection(collection).doc(recipientUid);
      const snap = await ref.get();
      const token = String(snap.data()?.[field] || '').trim();
      if (token === invalidToken) {
        await ref.set({ [field]: FieldValue.delete() }, { merge: true });
        console.warn('[fcm] cleared invalid recipient token', { recipientUid, collection, field });
      }
    } catch (error) {
      console.warn('[fcm] failed to clear invalid token', {
        recipientUid,
        collection,
        field,
        message: error?.message,
      });
    }
  }));
}

async function _sendChatNotification({
  title,
  previewText,
  chatId,
  senderId,
  receiverId,
  fcmToken,
  orderId,
  collectionName,
}) {
  const payload = {
    data: {
      chatId,
      senderId: senderId || '',
      senderName: title,
      message: previewText,
      orderId: orderId || '',
      type: 'chat',
      title,
      body: previewText,
      click_action: 'FLUTTER_NOTIFICATION_CLICK',
    },
    android: {
      priority: 'high',
    },
    apns: {
      payload: {
        aps: {
          sound: 'default',
          alert: {
            title,
            body: previewText,
          },
        },
      },
    },
    token: fcmToken,
  };

  try {
    await admin.messaging().send(payload);
    console.log(`[notifyNewChatMessage:${collectionName}] Sent to ${receiverId}`);
  } catch (error) {
    console.error(`[notifyNewChatMessage:${collectionName}] Error:`, error);
  }
}

async function _resolveChatOrderId(chatId, message) {
  const messageOrderId = String(message?.orderId || '').trim();
  if (messageOrderId) {
    return messageOrderId;
  }

  try {
    const chatDoc = await admin.firestore().collection('chats').doc(chatId).get();
    if (!chatDoc.exists) {
      return null;
    }

    const chatOrderId = String(chatDoc.data()?.orderId || '').trim();
    return chatOrderId || null;
  } catch (error) {
    console.error(`[notifyNewChatMessage] Failed to resolve order for chat ${chatId}`, error);
    return null;
  }
}

async function _resolveReceiverId(chatId, senderId) {
  try {
    const chatDoc = await admin.firestore().collection('chats').doc(chatId).get();
    if (!chatDoc.exists) {
      return null;
    }
    const participants = chatDoc.data().participants || [];
    return participants.find((participantId) => participantId !== senderId) || null;
  } catch (error) {
    console.error(`[notifyNewChatMessage] Failed to resolve receiver for chat ${chatId}`, error);
    return null;
  }
}

function _resolveMessagePreview(message) {
  if (message.text) {
    return message.text;
  }
  switch (message.type) {
    case 'image':
      return 'ส่งรูปภาพ';
    case 'video':
      return 'ส่งวิดีโอ';
    case 'file':
      return 'ส่งไฟล์แนบ';
    case 'call':
      return message.callType === 'video' ? 'วิดีโอคอล' : 'สายเสียง';
    default:
      return 'คุณได้รับข้อความใหม่';
  }
}
// ...existing code...
const { RtcTokenBuilder, RtcRole } = require('agora-access-token');
admin.initializeApp();

const db = admin.firestore();
const FieldValue = admin.firestore.FieldValue;

const merchantWallet = require('./merchant_wallet');
merchantWallet.init({
  db,
  FieldValue,
  HttpsError,
  onCall,
  onDocumentWritten,
  logger,
  DEFAULT_REGION,
});

const AGORA_APP_ID_SECRET = defineSecret('AGORA_APP_ID');
const AGORA_APP_CERT_SECRET = defineSecret('AGORA_APP_CERTIFICATE');
const AGORA_TTL_SECRET = defineSecret('AGORA_APP_TTL_SECONDS');
const GOOGLE_ROUTES_API_KEY = defineSecret('GOOGLE_ROUTES_API_KEY');
const REDIS_URL = defineSecret('REDIS_URL');
const REDIS_TOKEN = defineSecret('REDIS_TOKEN');
const SMTP_HOST = defineSecret('SMTP_HOST');
const SMTP_PORT = defineSecret('SMTP_PORT');
const SMTP_USER = defineSecret('SMTP_USER');
const SMTP_PASS = defineSecret('SMTP_PASS');
const SMTP_FROM = defineSecret('SMTP_FROM');
const SLIPOK_API_KEY_SECRET = defineSecret('SLIPOK_API_KEY');

const AI_QUEUE_COLLECTION = 'ai_processing_queue';
const AI_QUEUE_MAX_CONCURRENT = 2;
const AI_QUEUE_MAX_VISIBLE_POSITION = 5;
const AI_QUEUE_AVERAGE_SECONDS = 45;
const AI_QUEUE_POLL_MS = 2500;
const AI_QUEUE_MAX_WAIT_MS = 60 * 1000;
const AI_QUEUE_JOB_TTL_MS = 4 * 60 * 1000;
const PRODUCT_AI_WORKER_MAX_JOBS = 2;
const PRODUCT_AI_WORKER_MAX_PER_OWNER = 1;
const PRODUCT_AI_BULK_MAX_ITEMS = 300;
const PRODUCT_AI_PRIORITY_INTERACTIVE = 1000;
const PRODUCT_AI_PRIORITY_BULK = 0;
const PRODUCT_AI_PRIORITY_BULK_RETRY = 5;
const PRODUCT_AI_BACKGROUND_DEFER_MS = 2 * 60 * 1000;
const PRODUCT_AI_INTERACTIVE_QUEUE_TTL_MS = 15 * 60 * 1000;
const PRODUCT_AI_WORKER_KICK_MAX_ROUNDS = 8;
const AI_BACKGROUND_DEFAULT_PATH = 'gs://van-merchant.firebasestorage.app/image_background';
const AI_BACKGROUND_MAX_BYTES = 5 * 1024 * 1024;
const AI_BACKGROUND_MAX_CANDIDATES = 10;

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function parseStorageLocation(rawValue) {
  const value = String(rawValue || '').trim();
  if (!value) {
    return { bucketName: null, objectPath: '' };
  }

  if (value.startsWith('gs://')) {
    const withoutScheme = value.slice('gs://'.length);
    const firstSlash = withoutScheme.indexOf('/');
    if (firstSlash < 0) {
      return { bucketName: withoutScheme, objectPath: '' };
    }
    return {
      bucketName: withoutScheme.slice(0, firstSlash),
      objectPath: withoutScheme.slice(firstSlash + 1).replace(/^\/+/, ''),
    };
  }

  return {
    bucketName: null,
    objectPath: value.replace(/^\/+/, ''),
  };
}

function guessImageMimeTypeFromName(fileName) {
  const lower = String(fileName || '').toLowerCase();
  if (lower.endsWith('.png')) return 'image/png';
  if (lower.endsWith('.webp')) return 'image/webp';
  return 'image/jpeg';
}

function isSupportedBackgroundName(fileName) {
  const lower = String(fileName || '').toLowerCase();
  return lower.endsWith('.jpg') ||
    lower.endsWith('.jpeg') ||
    lower.endsWith('.png') ||
    lower.endsWith('.webp');
}

async function loadAiBackgroundAssets(rawPath) {
  const target = String(rawPath || AI_BACKGROUND_DEFAULT_PATH).trim();
  const { bucketName, objectPath } = parseStorageLocation(target);
  const bucket = bucketName ? admin.storage().bucket(bucketName) : admin.storage().bucket();

  const normalizedPath = String(objectPath || '').trim().replace(/^\/+/, '');
  if (!normalizedPath) {
    return [];
  }

  const candidates = [];

  // Allow both a direct object path and a folder prefix.
  if (!target.endsWith('/')) {
    const directFile = bucket.file(normalizedPath);
    const [exists] = await directFile.exists();
    if (exists && isSupportedBackgroundName(directFile.name)) {
      candidates.push(directFile);
    }
  }

  const prefix = normalizedPath.endsWith('/') ? normalizedPath : `${normalizedPath}/`;
  try {
    const [listedFiles] = await bucket.getFiles({ prefix, maxResults: 100 });
    for (const file of listedFiles) {
      if (!file || !file.name) continue;
      if (!isSupportedBackgroundName(file.name)) continue;
      candidates.push(file);
    }
  } catch (listError) {
    logger.warn('loadAiBackgroundAsset list files failed', {
      target,
      bucket: bucket.name,
      prefix,
      message: listError instanceof Error ? listError.message : String(listError),
    });
  }

  const uniqueByName = new Map();
  for (const file of candidates) {
    uniqueByName.set(file.name, file);
  }
  const uniqueCandidates = [...uniqueByName.values()];

  if (uniqueCandidates.length === 0) {
    return [];
  }

  const assets = [];
  for (const file of uniqueCandidates.sort((a, b) => a.name.localeCompare(b.name))) {
    if (assets.length >= AI_BACKGROUND_MAX_CANDIDATES) break;

    const [buffer] = await file.download();
    if (!buffer || buffer.length === 0) {
      continue;
    }

    if (buffer.length > AI_BACKGROUND_MAX_BYTES) {
      logger.warn('loadAiBackgroundAssets skipped oversized background', {
        file: file.name,
        bytes: buffer.length,
        maxBytes: AI_BACKGROUND_MAX_BYTES,
      });
      continue;
    }

    assets.push({
      index: assets.length + 1,
      mimeType: guessImageMimeTypeFromName(file.name),
      data: buffer.toString('base64'),
      buffer,
      name: file.name,
      source: `gs://${bucket.name}/${file.name}`,
    });
  }

  return assets;
}

async function composeProductCutoutOnBackground(productBuffer, backgroundAsset) {
  const productMeta = await sharp(productBuffer, { failOn: 'none' }).metadata();
  const canvasWidth = Math.min(Math.max(Number(productMeta.width) || 1024, 512), 1600);
  const canvasHeight = Math.min(Math.max(Number(productMeta.height) || 1024, 512), 1600);

  const backgroundBuffer = backgroundAsset?.buffer
    ? await sharp(backgroundAsset.buffer, { failOn: 'none' })
      .rotate()
      .resize(canvasWidth, canvasHeight, { fit: 'cover', position: 'center' })
      .jpeg({ quality: 88, chromaSubsampling: '4:4:4' })
      .toBuffer()
    : await sharp({
      create: {
        width: canvasWidth,
        height: canvasHeight,
        channels: 3,
        background: '#ffffff',
      },
    }).jpeg({ quality: 88 }).toBuffer();

  let cutoutBuffer = productBuffer;
  try {
    cutoutBuffer = await sharp(productBuffer, { failOn: 'none' })
      .ensureAlpha()
      .trim({ background: { r: 0, g: 0, b: 0, alpha: 0 }, threshold: 10 })
      .png()
      .toBuffer();
  } catch (trimError) {
    logger.warn('composeProductCutoutOnBackground trim failed, using original cutout canvas', {
      message: trimError instanceof Error ? trimError.message : String(trimError),
    });
  }

  const resizedCutout = await sharp(cutoutBuffer, { failOn: 'none' })
    .ensureAlpha()
    .resize({
      width: Math.round(canvasWidth * 0.78),
      height: Math.round(canvasHeight * 0.78),
      fit: 'inside',
      withoutEnlargement: true,
    })
    .png()
    .toBuffer();

  const cutoutMeta = await sharp(resizedCutout, { failOn: 'none' }).metadata();
  const left = Math.max(0, Math.round((canvasWidth - (Number(cutoutMeta.width) || canvasWidth)) / 2));
  const top = Math.max(0, Math.round((canvasHeight - (Number(cutoutMeta.height) || canvasHeight)) / 2));

  return sharp(backgroundBuffer, { failOn: 'none' })
    .composite([{ input: resizedCutout, left, top }])
    .jpeg({ quality: 88, chromaSubsampling: '4:4:4' })
    .toBuffer();
}

function normalizeAiRequestId(rawValue) {
  const value = String(rawValue || '').trim();
  if (/^[A-Za-z0-9_-]{8,100}$/.test(value)) {
    return value;
  }
  return crypto.randomUUID();
}

function formatExternalAiRecommendation(queuePosition, estimatedWaitSeconds) {
  const minutes = Math.max(1, Math.ceil(estimatedWaitSeconds / 60));
  return `คิว AI ตอนนี้เยอะมาก (คิวที่ ${queuePosition}, ประมาณ ${minutes} นาที) หากต้องการลงสินค้าเร็ว แนะนำใช้ AI ภายนอกลบ/เปลี่ยนพื้นหลังเป็นสีขาวก่อน แล้วค่อยอัปโหลดรูปเข้าระบบ หรือรอสักครู่แล้วลองใหม่`;
}

async function mirrorProductAiJobQueueStatus(productAiJobRef, patch) {
  if (!productAiJobRef) return;
  try {
    await productAiJobRef.set({
      ...patch,
      updatedAt: FieldValue.serverTimestamp(),
    }, { merge: true });
  } catch (error) {
    logger.warn('mirrorProductAiJobQueueStatus failed', {
      jobId: productAiJobRef.id,
      message: error instanceof Error ? error.message : String(error),
    });
  }
}

function productAiJobCreatedAtMillis(data) {
  const createdAt = data?.createdAt;
  if (createdAt && typeof createdAt.toMillis === 'function') {
    return createdAt.toMillis();
  }
  return Number(data?.nextRunAt || 0) || 0;
}

async function acquireAiProcessingSlot({
  uid,
  requestId,
  allowLargeQueue = false,
  maxWaitMs = AI_QUEUE_MAX_WAIT_MS,
  productAiJobRef = null,
}) {
  const jobId = normalizeAiRequestId(requestId);
  const jobRef = db.collection(AI_QUEUE_COLLECTION).doc(jobId);
  const createdAtMillis = Date.now();

  await jobRef.set({
    uid,
    status: 'queued',
    position: null,
    estimatedWaitSeconds: null,
    activeProcessing: null,
    createdAtMillis,
    updatedAt: FieldValue.serverTimestamp(),
    expiresAtMillis: createdAtMillis + AI_QUEUE_JOB_TTL_MS,
  }, { merge: true });

  while (Date.now() - createdAtMillis < maxWaitMs) {
    const now = Date.now();
    const snapshot = await db.collection(AI_QUEUE_COLLECTION)
      .where('expiresAtMillis', '>', now)
      .get();
    const jobs = snapshot.docs
      .map((doc) => ({ id: doc.id, ref: doc.ref, data: doc.data() || {} }))
      .filter((job) => job.data.status === 'queued' || job.data.status === 'processing')
      .sort((left, right) => {
        const leftCreatedAt = Number(left.data.createdAtMillis || 0);
        const rightCreatedAt = Number(right.data.createdAtMillis || 0);
        if (leftCreatedAt !== rightCreatedAt) return leftCreatedAt - rightCreatedAt;
        return left.id.localeCompare(right.id);
      });

    const currentIndex = jobs.findIndex((job) => job.id === jobId);
    const activeProcessing = jobs.filter((job) => job.data.status === 'processing').length;
    const queuePosition = currentIndex >= 0 ? currentIndex + 1 : jobs.length + 1;
    const estimatedWaitSeconds = Math.max(10, Math.ceil((queuePosition - 1) * AI_QUEUE_AVERAGE_SECONDS));

    if (!allowLargeQueue && queuePosition > AI_QUEUE_MAX_VISIBLE_POSITION) {
      const message = formatExternalAiRecommendation(queuePosition, estimatedWaitSeconds);
      await jobRef.set({
        uid,
        status: 'rejected',
        position: queuePosition,
        estimatedWaitSeconds,
        activeProcessing,
        message,
        externalAiRecommended: true,
        updatedAt: FieldValue.serverTimestamp(),
        expiresAtMillis: now + AI_QUEUE_JOB_TTL_MS,
      }, { merge: true });
      throw new HttpsError('resource-exhausted', message, {
        queuePosition,
        estimatedWaitSeconds,
        externalAiRecommended: true,
      });
    }

    const reachedProcessingSlot = currentIndex >= 0 && currentIndex < AI_QUEUE_MAX_CONCURRENT;
    const queueMessage = reachedProcessingSlot
      ? 'ถึงคิวแล้ว กำลังประมวลผล AI'
      : `กำลังรอคิว AI ลำดับที่ ${queuePosition}`;

    await jobRef.set({
      status: reachedProcessingSlot ? 'processing' : 'queued',
      position: queuePosition,
      estimatedWaitSeconds,
      activeProcessing,
      message: queueMessage,
      updatedAt: FieldValue.serverTimestamp(),
      expiresAtMillis: now + AI_QUEUE_JOB_TTL_MS,
    }, { merge: true });

    await mirrorProductAiJobQueueStatus(productAiJobRef, {
      status: reachedProcessingSlot ? 'processing' : 'queued',
      position: queuePosition,
      queuePosition,
      estimatedWaitSeconds,
      message: queueMessage,
    });

    if (reachedProcessingSlot) {
      return { jobRef, position: queuePosition, estimatedWaitSeconds };
    }

    await sleep(AI_QUEUE_POLL_MS);
  }

  const message = formatExternalAiRecommendation(AI_QUEUE_MAX_VISIBLE_POSITION, maxWaitMs / 1000);
  await jobRef.set({
    status: 'rejected',
    message,
    externalAiRecommended: true,
    updatedAt: FieldValue.serverTimestamp(),
    expiresAtMillis: Date.now() + AI_QUEUE_JOB_TTL_MS,
  }, { merge: true });
  throw new HttpsError('deadline-exceeded', message, {
    estimatedWaitSeconds: maxWaitMs / 1000,
    externalAiRecommended: true,
  });
}

async function releaseAiProcessingSlot(queueLease, status, message) {
  if (!queueLease?.jobRef) return;
  try {
    await queueLease.jobRef.set({
      status,
      position: 0,
      estimatedWaitSeconds: 0,
      message: message || (status === 'completed' ? 'ประมวลผล AI สำเร็จ' : 'ประมวลผล AI ไม่สำเร็จ'),
      updatedAt: FieldValue.serverTimestamp(),
      expiresAtMillis: Date.now() + 2 * 60 * 1000,
    }, { merge: true });
  } catch (error) {
    logger.warn('releaseAiProcessingSlot failed', {
      message: error instanceof Error ? error.message : String(error),
    });
  }
}
const GEMINI_API_KEY = defineSecret('GEMINI_API_KEY');

const OTP_TTL_MS = 10 * 60 * 1000;
const OTP_RESEND_INTERVAL_MS = 60 * 1000;
const MAX_VERIFY_ATTEMPTS = 5;
const ROUTE_CACHE_TTL_SEC = 24 * 60 * 60;

let redisClient = null;
let redisClientReady = false;

const SHOP_COLLECTIONS = [
  'market_registrations',
  'shop_registrations',
  'restaurant_registrations',
  'pharmacy_registrations',
  'other_registrations',
];
const CUSTOMER_COLLECTIONS = ['users', 'customer_users'];
const RIDER_COLLECTIONS = ['riders'];
const PROFILE_COLLECTIONS = [...CUSTOMER_COLLECTIONS, ...RIDER_COLLECTIONS, ...SHOP_COLLECTIONS];
const PAYMENT_CONFIG_COLLECTION = 'payment_config';
const PAYMENT_CONFIG_DOC_ID = 'collection';
const SLIPOK_ENDPOINT = 'https://api.slipok.com/api/line/apikey/64492';
const SLIPOK_FEEDBACK_COLLECTION = 'slipok_feedback';
const SHOP_TOPUP_SLIPS_COLLECTION = 'shop_topup_slips';
const SLIP_TRANS_REF_COLLECTION = 'slip_trans_refs';
const TOPUP_SLIP_DAILY_ATTEMPTS_COLLECTION = 'topup_slip_daily_attempts';
const TOP_UP_MAX_AMOUNT = 5000;
const TOP_UP_MAX_DAILY_VERIFICATION_ATTEMPTS = 3;
const MERCHANT_PLATFORM_CONFIG_DOC = 'platform_config/merchant';
const DEFAULT_MERCHANT_SECURITY_DEPOSIT_AMOUNT = 1000;
const ALLOWED_TOPUP_STORAGE_BUCKETS = new Set([
  'van-merchant-van1-storage-802503541368',
  'van-merchant-van2-storage-802503541368',
  'van-merchant-van3-storage-802503541368',
  // Legacy default bucket (iOS GoogleService-Info.plist เคยชี้ค่านี้)
  'van-merchant.firebasestorage.app',
  'van-merchant.appspot.com',
]);

function parseNumber(value) {
  if (typeof value === 'number' && Number.isFinite(value)) {
    return value;
  }
  if (typeof value === 'string') {
    const parsed = Number(value.trim());
    return Number.isFinite(parsed) ? parsed : 0;
  }
  return 0;
}

const MERCHANT_ACTIVE_ORDER_STATUSES = [
  'pending',
  'accepted',
  'awaiting_shop_confirmation',
  'awaiting_shipping_booking',
  'preparing',
  'ready',
  'delivering',
];

const PENDING_WITHDRAW_STATUSES = new Set([
  'pending',
  'approved',
  'processing',
  'transferring',
]);

exports.deleteMerchantAccount = functions
  .region(DEFAULT_REGION)
  .https.onCall(async (data, context) => {
    const uid = context.auth?.uid;
    if (!uid) {
      throw new functions.https.HttpsError(
        'unauthenticated',
        'กรุณาเข้าสู่ระบบก่อนลบบัญชี',
      );
    }

    const dryRun = data?.dryRun === true;
    const blockedReason = await getMerchantDeletionBlockedReason(uid);
    if (blockedReason) {
      if (!dryRun) {
        await db.collection('account_deletion_requests').doc(uid).set({
          uid,
          targetApp: 'van1',
          status: 'blocked',
          reason: blockedReason.code,
          message: blockedReason.message,
          updatedAt: FieldValue.serverTimestamp(),
          createdAt: FieldValue.serverTimestamp(),
        }, { merge: true });
      }
      throw new functions.https.HttpsError(
        'failed-precondition',
        blockedReason.message,
        { reason: blockedReason.code },
      );
    }

    if (dryRun) {
      return { canDelete: true };
    }

    await db.collection('account_deletion_requests').doc(uid).set({
      uid,
      targetApp: 'van1',
      status: 'processing',
      requestedAt: FieldValue.serverTimestamp(),
      updatedAt: FieldValue.serverTimestamp(),
    }, { merge: true });

    await Promise.all([
      deleteDocumentTreeIfExists(db.collection('users').doc(uid)),
      deleteDocumentTreeIfExists(db.collection('product_drafts').doc(uid)),
      deleteDocumentTreeIfExists(db.collection('shop_operations').doc(uid)),
      anonymizeMerchantRegistrationDocs(uid),
      hideMerchantPublicShop(uid),
      hideMerchantProducts(uid),
      markRetainedMerchantOrders(uid),
      deleteQueryInBatches(
        db.collection('app_notifications').where('recipientUid', '==', uid),
      ),
      deleteQueryInBatches(
        db.collection('active_call_invites').where('callerId', '==', uid),
      ),
      deleteQueryInBatches(
        db.collection('active_call_invites').where('calleeId', '==', uid),
      ),
    ]);

    try {
      await admin.auth().deleteUser(uid);
    } catch (error) {
      if (error?.code !== 'auth/user-not-found') {
        await db.collection('account_deletion_requests').doc(uid).set({
          status: 'auth_delete_failed',
          errorCode: error?.code || null,
          errorMessage: error?.message || String(error),
          updatedAt: FieldValue.serverTimestamp(),
        }, { merge: true });
        throw new functions.https.HttpsError(
          'internal',
          'ลบบัญชีเข้าสู่ระบบไม่สำเร็จ กรุณาลองใหม่',
        );
      }
    }

    await db.collection('account_deletion_requests').doc(uid).set({
      status: 'completed',
      completedAt: FieldValue.serverTimestamp(),
      updatedAt: FieldValue.serverTimestamp(),
      retainedRecords: ['orders', 'merchant_wallets', 'contracts'],
    }, { merge: true });

    return {
      deleted: true,
      deletedAt: new Date().toISOString(),
      retainedRecords: ['orders', 'merchant_wallets', 'contracts'],
    };
  });

async function getMerchantDeletionBlockedReason(uid) {
  const activeOrder = await findActiveMerchantOrder(uid);
  if (activeOrder) {
    return {
      code: 'active_orders',
      message: 'ยังมีออเดอร์ที่กำลังดำเนินการอยู่ กรุณาปิดงานให้เรียบร้อยก่อนลบบัญชี',
    };
  }

  const pendingWithdraw = await findPendingWithdrawRequest(uid);
  if (pendingWithdraw) {
    return {
      code: 'pending_withdraw',
      message: 'ยังมีรายการถอนเงินที่รอดำเนินการ กรุณารอให้เสร็จสิ้นก่อนลบบัญชี',
    };
  }

  const wallet = await db.collection('merchant_wallets').doc(uid).get();
  if (wallet.exists && walletHasOutstandingBalance(wallet.data() || {})) {
    return {
      code: 'outstanding_balance',
      message: 'ยังมียอดเงินหรือเงินประกันในบัญชี กรุณาถอนเงินหรือให้แอดมินเคลียร์ยอดก่อนลบบัญชี',
    };
  }

  return null;
}

async function findActiveMerchantOrder(uid) {
  const queries = [
    db.collection('orders')
      .where('shopId', '==', uid)
      .where('status', 'in', MERCHANT_ACTIVE_ORDER_STATUSES)
      .limit(1),
    db.collection('orders')
      .where('shopOwnerId', '==', uid)
      .where('status', 'in', MERCHANT_ACTIVE_ORDER_STATUSES)
      .limit(1),
  ];

  for (const query of queries) {
    const snapshot = await query.get();
    if (!snapshot.empty) {
      return snapshot.docs[0];
    }
  }
  return null;
}

async function findPendingWithdrawRequest(uid) {
  const snapshot = await db.collection('withdraw_requests')
    .where('uid', '==', uid)
    .limit(25)
    .get();
  return snapshot.docs.find((doc) => {
    const status = String(doc.data()?.status || '').trim().toLowerCase();
    return PENDING_WITHDRAW_STATUSES.has(status);
  });
}

function walletHasOutstandingBalance(data) {
  return [
    'totalCredit',
    'withdrawableCredit',
    'lockedCredit',
    'omisePendingCredit',
    'omiseWithdrawableCredit',
    'securityDepositAmount',
  ].some((field) => parseNumber(data[field]) > 0.009);
}

async function deleteDocumentTreeIfExists(ref) {
  const snapshot = await ref.get();
  if (!snapshot.exists) {
    return;
  }
  await db.recursiveDelete(ref);
}

async function anonymizeMerchantRegistrationDocs(uid) {
  const refs = new Map();
  for (const collection of SHOP_COLLECTIONS) {
    const directRef = db.collection(collection).doc(uid);
    const directDoc = await directRef.get();
    if (directDoc.exists) {
      refs.set(directRef.path, directRef);
    }

    const ownerSnapshot = await db.collection(collection)
      .where('ownerId', '==', uid)
      .limit(25)
      .get();
    ownerSnapshot.docs.forEach((doc) => refs.set(doc.ref.path, doc.ref));
  }

  const update = {
    accountDeleted: true,
    accountDeletedAt: FieldValue.serverTimestamp(),
    status: 'account_deleted',
    isDeleted: true,
    isOpen: false,
    fcmToken: FieldValue.delete(),
    shopFCMToken: FieldValue.delete(),
    email: FieldValue.delete(),
    phone: FieldValue.delete(),
    phoneNumber: FieldValue.delete(),
    contactName: FieldValue.delete(),
    displayName: FieldValue.delete(),
    ownerName: FieldValue.delete(),
    bookBankImageUrl: FieldValue.delete(),
    bankAccountName: FieldValue.delete(),
    bankAccountNumber: FieldValue.delete(),
  };

  await updateRefsInBatches([...refs.values()], update);
}

async function hideMerchantPublicShop(uid) {
  const ref = db.collection('public_shops').doc(uid);
  const snapshot = await ref.get();
  if (!snapshot.exists) {
    return;
  }

  await ref.set({
    accountDeleted: true,
    accountDeletedAt: FieldValue.serverTimestamp(),
    active: false,
    isActive: false,
    isDeleted: true,
    isOpen: false,
    visible: false,
    hidden: true,
    shopName: 'ร้านค้าที่ลบบัญชีแล้ว',
    displayName: 'ร้านค้าที่ลบบัญชีแล้ว',
    name: 'ร้านค้าที่ลบบัญชีแล้ว',
    phone: FieldValue.delete(),
    phoneNumber: FieldValue.delete(),
    email: FieldValue.delete(),
    imageUrl: FieldValue.delete(),
    logoUrl: FieldValue.delete(),
    photoUrl: FieldValue.delete(),
    searchKeywords: [],
  }, { merge: true });
}

async function hideMerchantProducts(uid) {
  const refs = new Map();
  const queries = [
    db.collection('products').where('ownerUid', '==', uid).limit(500),
    db.collection('products').where('ownerId', '==', uid).limit(500),
  ];

  for (const query of queries) {
    const snapshot = await query.get();
    snapshot.docs.forEach((doc) => refs.set(doc.ref.path, doc.ref));
  }

  await updateRefsInBatches([...refs.values()], {
    accountDeleted: true,
    ownerAccountDeleted: true,
    accountDeletedAt: FieldValue.serverTimestamp(),
    active: false,
    isActive: false,
    available: false,
    visible: false,
    isDeleted: true,
  });
}

async function markRetainedMerchantOrders(uid) {
  const refs = new Map();
  const queries = [
    db.collection('orders').where('shopId', '==', uid).limit(500),
    db.collection('orders').where('shopOwnerId', '==', uid).limit(500),
  ];

  for (const query of queries) {
    const snapshot = await query.get();
    snapshot.docs.forEach((doc) => refs.set(doc.ref.path, doc.ref));
  }

  await updateRefsInBatches([...refs.values()], {
    merchantAccountDeleted: true,
    merchantAccountDeletedAt: FieldValue.serverTimestamp(),
  });
}

async function updateRefsInBatches(refs, update) {
  for (let index = 0; index < refs.length; index += 400) {
    const batch = db.batch();
    refs.slice(index, index + 400).forEach((ref) => batch.set(ref, update, { merge: true }));
    await batch.commit();
  }
}

async function deleteQueryInBatches(query) {
  let snapshot = await query.limit(400).get();
  while (!snapshot.empty) {
    const batch = db.batch();
    snapshot.docs.forEach((doc) => batch.delete(doc.ref));
    await batch.commit();
    snapshot = await query.limit(400).get();
  }
}

function amountsMatch(actualAmount, expectedAmount) {
  if (!Number.isFinite(actualAmount) || !Number.isFinite(expectedAmount)) {
    return false;
  }
  return Math.abs(actualAmount - expectedAmount) < 0.01;
}

function assertTopUpStoragePathForActor(uid, storagePath, sourceApp) {
  const path = String(storagePath || '').trim();
  const normalizedSource = String(sourceApp || '').trim().toLowerCase();
  if (normalizedSource === 'van3_rider' || normalizedSource.startsWith('van3')) {
    const riderPrefix = `riders/${uid}/topups/`;
    if (!path.startsWith(riderPrefix)) {
      throw new HttpsError('permission-denied', 'เส้นทางสลิปไม่ถูกต้องสำหรับไรเดอร์');
    }
    return;
  }
  const merchantPrefix = `shops/${uid}/topups/`;
  if (!path.startsWith(merchantPrefix)) {
    throw new HttpsError('permission-denied', 'เส้นทางสลิปไม่ถูกต้องสำหรับร้านค้า');
  }
}

function resolveTopUpTargetApp(sourceApp) {
  const normalized = String(sourceApp || '').trim().toLowerCase();
  if (normalized === 'van3_rider' || normalized.startsWith('van3')) {
    return 'van3';
  }
  return 'van1';
}

function formatShortBaht(amount) {
  const n = Number(amount);
  if (!Number.isFinite(n)) {
    return '0';
  }
  const rounded = Math.round(n * 100) / 100;
  return Number.isInteger(rounded) ? String(rounded) : rounded.toFixed(2);
}

function getBangkokDateKey(date = new Date()) {
  return new Intl.DateTimeFormat('en-CA', {
    timeZone: 'Asia/Bangkok',
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
  }).format(date);
}

function getTopUpDailyAttemptDocId(uid) {
  return `${uid}_${getBangkokDateKey()}`;
}

async function consumeTopUpDailyVerificationAttempt(uid) {
  const docId = getTopUpDailyAttemptDocId(uid);
  const ref = db.collection(TOPUP_SLIP_DAILY_ATTEMPTS_COLLECTION).doc(docId);

  await db.runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    const count = snap.exists ? Number(snap.data()?.count || 0) : 0;
    if (count >= TOP_UP_MAX_DAILY_VERIFICATION_ATTEMPTS) {
      throw new HttpsError(
        'resource-exhausted',
        'ส่งสลิปครบ 3 ครั้งต่อวันแล้ว กรุณาลองใหม่พรุ่งนี้',
      );
    }
    tx.set(
      ref,
      {
        uid,
        dateKey: getBangkokDateKey(),
        count: count + 1,
        updatedAt: FieldValue.serverTimestamp(),
      },
      { merge: true },
    );
  });
}

function readRequiredConfiguredSecret(secret, label, purpose) {
  const value = String(secret.value() || '').trim();
  if (!value) {
    throw new HttpsError(
      'failed-precondition',
      `ยังไม่ได้ตั้งค่า ${label} สำหรับ${purpose}`,
    );
  }
  return value;
}

function defaultPaymentCollectionSettings() {
  return {
    recipientDisplayName: 'วิทยา ทนหงษา',
    bankAccountNumber: '1643440349',
    promptPayPhoneNumber: '',
    promptPayNationalIdOrTaxId: '1410400168710',
  };
}

async function getPaymentCollectionSettings() {
  const defaults = defaultPaymentCollectionSettings();

  try {
    const snapshot = await db
      .collection(PAYMENT_CONFIG_COLLECTION)
      .doc(PAYMENT_CONFIG_DOC_ID)
      .get();
    const data = snapshot.data() || {};

    return normalizePaymentCollectionSettings(data);
  } catch (error) {
    logger.warn('Failed to read payment config. Falling back to defaults.', {
      message: error instanceof Error ? error.message : String(error),
    });
    return defaults;
  }
}

async function getMerchantSecurityDepositRequiredBaht() {
  try {
    const snapshot = await db.doc(MERCHANT_PLATFORM_CONFIG_DOC).get();
    const amount = parseNumber(snapshot.data()?.securityDepositRequiredBaht);
    if (Number.isFinite(amount) && amount >= 0) {
      return amount;
    }
  } catch (error) {
    logger.warn('Failed to read merchant platform config. Falling back to default.', {
      message: error instanceof Error ? error.message : String(error),
    });
  }
  return DEFAULT_MERCHANT_SECURITY_DEPOSIT_AMOUNT;
}

function normalizePaymentCollectionSettings(raw = {}) {
  const defaults = defaultPaymentCollectionSettings();
  let promptPayPhoneNumber = String(raw.promptPayPhoneNumber || '').trim();
  let promptPayNationalIdOrTaxId = String(
    raw.promptPayNationalIdOrTaxId || defaults.promptPayNationalIdOrTaxId,
  ).trim();

  if (!isPromptPayPhoneDigits(promptPayPhoneNumber)) {
    promptPayPhoneNumber = '';
  } else {
    promptPayPhoneNumber = normalizeDigits(promptPayPhoneNumber);
  }

  const nationalDigits = normalizeDigits(promptPayNationalIdOrTaxId);
  if (nationalDigits.length === 13) {
    promptPayNationalIdOrTaxId = nationalDigits;
  } else if (isPromptPayPhoneDigits(nationalDigits) && !promptPayPhoneNumber) {
    promptPayPhoneNumber = nationalDigits;
    promptPayNationalIdOrTaxId = defaults.promptPayNationalIdOrTaxId;
  } else if (nationalDigits.length !== 13) {
    promptPayNationalIdOrTaxId = defaults.promptPayNationalIdOrTaxId;
  }

  return {
    recipientDisplayName:
      String(raw.recipientDisplayName || defaults.recipientDisplayName).trim()
      || defaults.recipientDisplayName,
    recipientDisplayNameAlt: String(raw.recipientDisplayNameAlt || '').trim(),
    bankAccountNumber:
      String(raw.bankAccountNumber || defaults.bankAccountNumber).trim()
      || defaults.bankAccountNumber,
    promptPayPhoneNumber,
    promptPayNationalIdOrTaxId,
  };
}

function normalizeMaskedDigits(value) {
  return String(value || '')
    .trim()
    .replace(/\*/g, 'X')
    .replace(/[^0-9xX]/g, '')
    .toUpperCase();
}

function buildDigitMaskPattern(value) {
  let pattern = '';
  for (const char of String(value || '')) {
    if (/[0-9]/.test(char)) {
      pattern += char;
    } else if (char === '*' || char === 'X' || char === 'x') {
      pattern += '?';
    }
  }
  return pattern;
}

function digitMaskPatternMatches(pattern, expectedDigits) {
  if (!pattern || !expectedDigits || pattern.length !== expectedDigits.length) {
    return false;
  }

  for (let index = 0; index < pattern.length; index += 1) {
    const patternChar = pattern[index];
    if (patternChar !== '?' && patternChar !== expectedDigits[index]) {
      return false;
    }
  }

  return true;
}

function promptPayFormattedIdMatches(actualValue, expectedValue) {
  const expectedDigits = normalizeDigits(expectedValue);
  if (expectedDigits.length !== 13) {
    return false;
  }

  const pattern = buildDigitMaskPattern(actualValue);
  if (digitMaskPatternMatches(pattern, expectedDigits)) {
    return true;
  }

  const masked = normalizeMaskedDigits(actualValue);
  if (masked.length === expectedDigits.length) {
    for (let index = 0; index < expectedDigits.length; index += 1) {
      const maskedChar = masked[index];
      if (maskedChar !== 'X' && maskedChar !== expectedDigits[index]) {
        return false;
      }
    }
    return true;
  }

  return false;
}

function normalizeDigits(value) {
  return String(value || '')
    .trim()
    .replace(/\D/g, '');
}

function maskedDigitsMatch(maskedValue, expectedValue) {
  const masked = normalizeMaskedDigits(maskedValue);
  const expected = normalizeDigits(expectedValue);

  if (!masked || !expected || masked.length !== expected.length) {
    return false;
  }

  for (let index = 0; index < masked.length; index += 1) {
    const maskedChar = masked[index];
    if (maskedChar !== 'X' && maskedChar !== expected[index]) {
      return false;
    }
  }

  return true;
}

function normalizeNameForComparison(value) {
  return String(value || '')
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9ก-๙]/g, '');
}

function namePartiallyMatches(actualValue, expectedValue) {
  const actual = normalizeNameForComparison(actualValue);
  const expected = normalizeNameForComparison(expectedValue);

  if (!actual || !expected) {
    return false;
  }

  if (actual.includes(expected) || expected.includes(actual)) {
    return true;
  }

  const minPrefix = Math.min(actual.length, expected.length, 6);
  if (minPrefix >= 4) {
    const actualPrefix = actual.slice(0, minPrefix);
    const expectedPrefix = expected.slice(0, minPrefix);
    if (actual.includes(expectedPrefix) || expected.includes(actualPrefix)) {
      return true;
    }
  }

  return false;
}

function extractVisibleDigits(value) {
  return normalizeMaskedDigits(value).replace(/X/g, '');
}

function isPromptPayPhoneDigits(value) {
  const digits = normalizeDigits(value);
  return digits.length >= 9 && digits.length <= 10;
}

function receiverTargetMatches(actualTarget, expectedTarget) {
  if (maskedDigitsMatch(actualTarget, expectedTarget)) {
    return true;
  }

  if (promptPayFormattedIdMatches(actualTarget, expectedTarget)) {
    return true;
  }

  const actualDigits = normalizeDigits(actualTarget);
  const expectedDigits = normalizeDigits(expectedTarget);
  if (actualDigits && expectedDigits && actualDigits === expectedDigits) {
    return true;
  }

  const visibleDigits = extractVisibleDigits(actualTarget);
  if (visibleDigits.length >= 4 && expectedDigits.endsWith(visibleDigits)) {
    return true;
  }

  return false;
}

function buildExpectedReceiverTargets(settings) {
  const defaults = defaultPaymentCollectionSettings();
  const targets = new Set();

  for (const value of [
    settings.bankAccountNumber,
    settings.promptPayPhoneNumber,
    settings.promptPayNationalIdOrTaxId,
    defaults.promptPayNationalIdOrTaxId,
  ]) {
    const digits = normalizeDigits(value);
    if (!digits) {
      continue;
    }
    targets.add(digits);
    if (isPromptPayPhoneDigits(digits)) {
      const local = digits.startsWith('0') ? digits.slice(1) : digits;
      targets.add(`66${local}`);
      if (!digits.startsWith('0')) {
        targets.add(`0${digits}`);
      }
    }
  }

  return [...targets];
}

function collectReceiverMatchCandidates(receiver) {
  const candidates = new Set();

  const walk = (node) => {
    if (node == null) {
      return;
    }
    if (typeof node === 'string' || typeof node === 'number') {
      const text = String(node).trim();
      if (text) {
        candidates.add(text);
      }
      return;
    }
    if (Array.isArray(node)) {
      for (const item of node) {
        walk(item);
      }
      return;
    }
    if (typeof node === 'object') {
      for (const value of Object.values(node)) {
        walk(value);
      }
    }
  };

  walk(receiver);
  return [...candidates];
}

function validateSlipReceiver(providerPayload, settings, options = {}) {
  const relaxNameFallback = options.relaxNameFallback === true;
  const scanAllReceiverFields = options.scanAllReceiverFields === true;
  const receiver = providerPayload?.data?.receiver || {};
  const accountValue = String(receiver?.account?.value || '').trim();
  const proxyValue = String(receiver?.proxy?.value || '').trim();
  const actualNames = [receiver?.displayName, receiver?.name]
    .map((value) => String(value || '').trim())
    .filter(Boolean);
  const expectedTargets = buildExpectedReceiverTargets(settings);
  const actualTargets = scanAllReceiverFields
    ? collectReceiverMatchCandidates(receiver)
    : [accountValue, proxyValue].filter(Boolean);

  const accountMatched =
    actualTargets.length > 0 &&
    expectedTargets.some((expectedTarget) =>
      actualTargets.some((actualTarget) =>
        receiverTargetMatches(actualTarget, expectedTarget),
      ),
    );

  const expectedNames = [
    settings.recipientDisplayName,
    settings.recipientDisplayNameAlt,
  ]
    .map((value) => String(value || '').trim())
    .filter(Boolean);

  const nameMatched = actualNames.some((actualName) =>
    expectedNames.some((expectedName) => namePartiallyMatches(actualName, expectedName)),
  );

  const matched = relaxNameFallback
    ? accountMatched || nameMatched
    : accountMatched || (!actualTargets.length && nameMatched);

  return {
    matched,
    accountMatched,
    nameMatched,
    actualAccountValue: accountValue,
    actualProxyValue: proxyValue,
    actualNames,
    actualTargets,
    expectedRecipientDisplayName: settings.recipientDisplayName,
    expectedTargets,
  };
}

function normalizedNameContainsToken(name, token) {
  const normalizedName = normalizeNameForComparison(name);
  const normalizedToken = normalizeNameForComparison(token);
  return Boolean(
    normalizedName &&
      normalizedToken &&
      normalizedName.includes(normalizedToken),
  );
}

function validateTopUpSlipReceiver(providerPayload, settings, expectedPromptPayId) {
  const base = validateSlipReceiver(providerPayload, settings, {
    relaxNameFallback: true,
    scanAllReceiverFields: true,
  });
  if (base.matched) {
    return { ...base, topUpRelaxedMatch: false };
  }

  const receiver = providerPayload?.data?.receiver || {};
  const actualNames = [receiver?.displayName, receiver?.name]
    .map((value) => String(value || '').trim())
    .filter(Boolean);
  const nationalId = normalizeDigits(
    String(expectedPromptPayId || settings.promptPayNationalIdOrTaxId || '').trim(),
  );

  const nameHint = actualNames.some(
    (actualName) =>
      normalizedNameContainsToken(actualName, 'วิทยา') ||
      normalizedNameContainsToken(actualName, settings.recipientDisplayName),
  );

  let nationalIdHint = false;
  if (nationalId.length === 13) {
    const suffix = nationalId.slice(-4);
    const prefix = nationalId.slice(0, 9);
    const candidates = collectReceiverMatchCandidates(receiver);
    nationalIdHint = candidates.some(
      (candidate) =>
        promptPayFormattedIdMatches(candidate, nationalId) ||
        receiverTargetMatches(candidate, nationalId) ||
        normalizeDigits(candidate).endsWith(suffix),
    );
    if (!nationalIdHint) {
      const receiverBlob = JSON.stringify(receiver);
      nationalIdHint = receiverBlob.includes(suffix) || receiverBlob.includes(prefix);
    }
  }

  const relaxedMatched = nameHint || nationalIdHint;

  return {
    ...base,
    matched: relaxedMatched,
    accountMatched: base.accountMatched || nationalIdHint,
    nameMatched: base.nameMatched || nameHint,
    nationalIdHint,
    nameHint,
    topUpRelaxedMatch: relaxedMatched && !base.matched,
  };
}

function buildSlipVerificationMessage(status, providerPayload, fallbackMessage) {
  const rawCode = Number(providerPayload?.code);
  const providerMessage = String(
    providerPayload?.message || providerPayload?.data?.message || fallbackMessage || '',
  ).trim();

  if (status === 'verified') {
    return 'ตรวจสอบสลิปถูกต้องแล้ว ระบบเติมเครดิตเรียบร้อย';
  }

  switch (rawCode) {
    case 1012:
      return 'สลิปนี้ถูกใช้ตรวจสอบไปแล้ว กรุณาใช้สลิปที่ยังไม่เคยส่ง';
    case 1013:
      return 'ยอดเงินในสลิปไม่ตรงกับยอดที่ต้องเติม กรุณาตรวจสอบแล้วแนบสลิปใหม่';
    case 1014:
      return 'บัญชีผู้รับในสลิปไม่ตรงกับบัญชีร้าน กรุณาตรวจสอบแล้วชำระใหม่';
    default:
      break;
  }

  if (providerMessage.includes('ยอดที่ส่งมาไม่ตรงกับยอดสลิป')) {
    return 'ยอดเงินในสลิปไม่ตรงกับยอดที่ต้องเติม กรุณาตรวจสอบแล้วแนบสลิปใหม่';
  }
  if (providerMessage.includes('สลิปซ้ำ')) {
    return 'สลิปนี้ถูกใช้ตรวจสอบไปแล้ว กรุณาใช้สลิปที่ยังไม่เคยส่ง';
  }
  if (providerMessage.includes('บัญชีผู้รับไม่ตรงกับบัญชีหลักของร้าน')) {
    return 'บัญชีผู้รับในสลิปไม่ตรงกับบัญชีร้าน กรุณาตรวจสอบแล้วชำระใหม่';
  }
  if (providerMessage.includes('QR Code ไม่ใช่ QR สำหรับตรวจสอบการชำระเงิน')) {
    return 'สลิปนี้ไม่ใช่สลิปโอนเงินที่ตรวจสอบได้ กรุณาแนบสลิปที่ถูกต้อง';
  }
  if (providerMessage.includes('QR Code หมดอายุ') || providerMessage.includes('ไม่มีรายการอยู่จริง')) {
    return 'สลิปนี้หมดอายุหรือไม่พบรายการ กรุณาแนบสลิปใหม่ที่ถูกต้อง';
  }
  if (providerMessage.includes('รูปภาพไม่มี QR Code')) {
    return 'ระบบอ่าน QR จากสลิปไม่เจอ กรุณาแนบรูปสลิปที่ชัดเจนกว่าเดิม';
  }
  if (providerMessage.includes('รูปภาพไม่ถูกต้อง')) {
    return 'รูปสลิปไม่ถูกต้องหรือไฟล์เสียหาย กรุณาแนบรูปใหม่';
  }
  if (providerMessage.includes('Authorization Header ไม่ถูกต้อง')) {
    return 'ระบบตรวจสลิปมีปัญหาชั่วคราว กรุณาลองใหม่อีกครั้ง';
  }
  if (providerMessage.includes('กรุณาใส่ข้อมูล QR Code ให้ครบ')) {
    return 'ระบบอ่านข้อมูลสลิปไม่ครบ กรุณาแนบสลิปใหม่อีกครั้ง';
  }

  if (status === 'failed') {
    return providerMessage || 'สลิปไม่ผ่านการตรวจสอบ กรุณาตรวจสอบแล้วแนบใหม่';
  }

  return providerMessage || 'ส่งสลิปไปตรวจสอบไม่สำเร็จ กรุณาลองใหม่อีกครั้ง';
}

async function writeSlipOkFeedbackLog({
  feedbackId,
  customerUid,
  paymentGroupId,
  storagePath,
  fileName,
  contentType,
  expectedAmount,
  verifiedAmount,
  verificationStatus,
  verificationMessage,
  responseCode,
  providerPayload,
  providerRawText,
  transRef,
  receiverValidation,
  sourceApp,
}) {
  const docId = String(feedbackId || paymentGroupId || '').trim();
  const feedbackRef = docId
    ? db.collection(SLIPOK_FEEDBACK_COLLECTION).doc(docId)
    : db.collection(SLIPOK_FEEDBACK_COLLECTION).doc();

  await feedbackRef.set({
    provider: 'slipok',
    providerLabel: 'Slip OK',
    customerUid,
    orderIds: [],
    paymentGroupId,
    storagePath,
    fileName,
    contentType,
    expectedCombinedAmount: expectedAmount,
    verifiedSlipAmount: verifiedAmount,
    status: verificationStatus,
    message: verificationMessage,
    responseCode,
    apiEndpoint: SLIPOK_ENDPOINT,
    response: providerPayload,
    rawResponseText: providerRawText,
    transRef: transRef || null,
    receiverValidation: receiverValidation || null,
    sourceApp: sourceApp || null,
    createdAt: FieldValue.serverTimestamp(),
    updatedAt: FieldValue.serverTimestamp(),
  }, { merge: true });

  return feedbackRef.id;
}

function normalizeEmail(email) {
  return String(email || '').trim().toLowerCase();
}

function otpDocId(email) {
  return Buffer.from(normalizeEmail(email)).toString('base64url');
}

function generateOtp() {
  return `${crypto.randomInt(0, 1000000)}`.padStart(6, '0');
}

function hashOtp(email, otp) {
  return crypto
    .createHash('sha256')
    .update(`${normalizeEmail(email)}:${otp}`)
    .digest('hex');
}

function readRequiredSecret(secret, label) {
  const value = String(secret.value() || '').trim();
  if (!value) {
    throw new HttpsError(
      'failed-precondition',
      `ยังไม่ได้ตั้งค่า ${label} สำหรับระบบ Email OTP`,
    );
  }
  return value;
}

function buildTransport() {
  const host = readRequiredSecret(SMTP_HOST, 'SMTP_HOST');
  const port = Number(readRequiredSecret(SMTP_PORT, 'SMTP_PORT'));
  const user = readRequiredSecret(SMTP_USER, 'SMTP_USER');
  const pass = readRequiredSecret(SMTP_PASS, 'SMTP_PASS');

  if (Number.isNaN(port)) {
    throw new HttpsError(
      'failed-precondition',
      'ค่า SMTP_PORT ไม่ถูกต้องสำหรับระบบ Email OTP',
    );
  }

  return nodemailer.createTransport({
    host,
    port,
    secure: port === 465,
    auth: {
      user,
      pass,
    },
  });
}

async function readShopOperationsDoc(shopId) {
  if (!shopId) return {};
  try {
    const snapshot = await db.collection('shop_operations').doc(shopId).get();
    return snapshot.exists ? (snapshot.data() || {}) : {};
  } catch (error) {
    logger.warn('Unable to read shop_operations', {
      shopId,
      message: error instanceof Error ? error.message : String(error),
    });
    return {};
  }
}

async function resolveShopEmailAndName(shopId) {
  if (!shopId) {
    return { email: '', name: '' };
  }

  for (const collection of SHOP_COLLECTIONS) {
    try {
      const snapshot = await db.collection(collection).doc(shopId).get();
      if (!snapshot.exists) continue;
      const data = snapshot.data() || {};
      const email = String(data.email || '').trim().toLowerCase();
      const name = String(data.shopName || data.name || data.storeName || '').trim();
      if (email) {
        return { email, name };
      }
    } catch (_) {}
  }

  try {
    const userRecord = await admin.auth().getUser(shopId);
    return {
      email: normalizeEmail(userRecord.email),
      name: String(userRecord.displayName || '').trim(),
    };
  } catch (_) {
    return { email: '', name: '' };
  }
}

function getPreviousBangkokMonthRange() {
  const bangkokOffsetMs = 7 * 60 * 60 * 1000;
  const bangkokNow = new Date(Date.now() + bangkokOffsetMs);
  const year = bangkokNow.getUTCFullYear();
  const month = bangkokNow.getUTCMonth();
  const startMs = Date.UTC(year, month - 1, 1, 0, 0, 0) - bangkokOffsetMs;
  const endMs = Date.UTC(year, month, 1, 0, 0, 0) - bangkokOffsetMs;
  const labelYear = month === 0 ? year - 1 : year;
  const labelMonth = month === 0 ? 12 : month;
  const label = `${labelYear}-${`${labelMonth}`.padStart(2, '0')}`;
  return {
    start: admin.firestore.Timestamp.fromMillis(startMs),
    end: admin.firestore.Timestamp.fromMillis(endMs),
    label,
  };
}

function formatMoney(value) {
  return Number(value || 0).toLocaleString('th-TH', {
    minimumFractionDigits: 2,
    maximumFractionDigits: 2,
  });
}

function buildMonthlyReportRows(orders) {
  let totalRevenue = 0;
  let totalItems = 0;
  const itemTotals = new Map();

  for (const order of orders) {
    totalRevenue += Number(order.totalAmount || 0);
    const items = Array.isArray(order.items) ? order.items : [];
    for (const item of items) {
      const quantity = Number(item.quantity || 0);
      if (!quantity) continue;
      totalItems += quantity;
      const name = String(item.productName || item.name || 'สินค้าไม่ระบุชื่อ').trim();
      itemTotals.set(name, (itemTotals.get(name) || 0) + quantity);
    }
  }

  const topItems = [...itemTotals.entries()]
    .sort((a, b) => b[1] - a[1])
    .slice(0, 5);

  return {
    totalRevenue,
    totalItems,
    topItems,
  };
}

exports.sendMonthlySalesReports = onSchedule(
  {
    region: DEFAULT_REGION,
    schedule: '10 0 1 * *',
    timeZone: 'Asia/Bangkok',
    secrets: [SMTP_HOST, SMTP_PORT, SMTP_USER, SMTP_PASS, SMTP_FROM],
  },
  async () => {
    const { start, end, label } = getPreviousBangkokMonthRange();
    const operationsSnapshot = await db
      .collection('shop_operations')
      .where('emailDailyReports', '==', true)
      .get();

    if (operationsSnapshot.empty) {
      logger.info('No shop has enabled monthly sales reports');
      return;
    }

    const transport = buildTransport();
    const from = readRequiredSecret(SMTP_FROM, 'SMTP_FROM');
    const tasks = operationsSnapshot.docs.map(async (doc) => {
      const shopId = doc.id;
      const operations = doc.data() || {};
      if (operations.lastMonthlyReportSentFor === label) {
        return;
      }

      const { email, name } = await resolveShopEmailAndName(shopId);
      if (!email) {
        logger.warn('Skip monthly report because shop email is missing', {
          shopId,
          label,
        });
        return;
      }

      const ordersSnapshot = await db
        .collection('orders')
        .where('shopOwnerId', '==', shopId)
        .where('deliveredAt', '>=', start)
        .where('deliveredAt', '<', end)
        .get();

      const deliveredOrders = ordersSnapshot.docs
        .map((orderDoc) => orderDoc.data())
        .filter((order) => String(order.status || '').trim() === 'delivered');

      const summary = buildMonthlyReportRows(deliveredOrders);
      const itemLines = summary.topItems.length > 0
        ? summary.topItems.map(([itemName, qty]) => `<li>${itemName} x${qty}</li>`).join('')
        : '<li>ไม่มีสินค้าเด่นในช่วงเดือนดังกล่าว</li>';

      await transport.sendMail({
        from,
        to: email,
        subject: `สรุปยอดขายรายเดือน ${label}`,
        text: [
          `สรุปรายงานยอดขายรายเดือน ${label}`,
          `ร้าน: ${name || shopId}`,
          `จำนวนออเดอร์ส่งสำเร็จ: ${deliveredOrders.length}`,
          `ยอดขายรวม: ฿${formatMoney(summary.totalRevenue)}`,
          `จำนวนสินค้าที่ขายได้: ${summary.totalItems}`,
          summary.topItems.length > 0
            ? `สินค้าเด่น: ${summary.topItems.map(([itemName, qty]) => `${itemName} x${qty}`).join(', ')}`
            : 'สินค้าเด่น: ไม่มีข้อมูล',
        ].join('\n'),
        html: `
          <div style="font-family: Arial, sans-serif; line-height: 1.6; color: #1f2937;">
            <h2 style="color: #ea580c;">สรุปยอดขายรายเดือน</h2>
            <p><strong>เดือน:</strong> ${label}</p>
            <p><strong>ร้าน:</strong> ${name || shopId}</p>
            <p><strong>จำนวนออเดอร์ส่งสำเร็จ:</strong> ${deliveredOrders.length}</p>
            <p><strong>ยอดขายรวม:</strong> ฿${formatMoney(summary.totalRevenue)}</p>
            <p><strong>จำนวนสินค้าที่ขายได้:</strong> ${summary.totalItems}</p>
            <p><strong>สินค้าเด่น:</strong></p>
            <ul>${itemLines}</ul>
          </div>
        `,
      });

      await doc.ref.set({
        lastMonthlyReportSentFor: label,
        lastMonthlyReportSentAt: admin.firestore.FieldValue.serverTimestamp(),
      }, { merge: true });
    });

    await Promise.all(tasks);
  },
);

exports.askGeminiFlash = onCall(
  {
    region: DEFAULT_REGION,
    secrets: [GEMINI_API_KEY],
    timeoutSeconds: 60,
    memory: '512MiB',
  },
  async (request) => {
    if (!request.auth?.uid) {
      throw new HttpsError('unauthenticated', 'กรุณาเข้าสู่ระบบก่อนใช้งาน AI');
    }

    const prompt = String(request.data?.prompt || '').trim();
    const productName = String(request.data?.productName || '').trim();
    const category = String(request.data?.category || '').trim();
    const price = String(request.data?.price || '').trim();
    const unit = String(request.data?.unit || '').trim();
    const stock = String(request.data?.stock || '').trim();

    if (!prompt) {
      throw new HttpsError('invalid-argument', 'กรุณาระบุคำสั่งที่ต้องการให้ AI ช่วยเขียน');
    }

    const inputSummary = [
      productName ? `ชื่อสินค้า: ${productName}` : null,
      category ? `หมวดหมู่: ${category}` : null,
      price ? `ราคา: ${price}` : null,
      unit ? `หน่วย: ${unit}` : null,
      stock ? `สต็อก: ${stock}` : null,
    ]
      .filter(Boolean)
      .join('\n');

    const finalPrompt = [
      prompt,
      inputSummary,
      'ข้อกำหนด: ตอบเป็นภาษาไทยเท่านั้น, ใช้ถ้อยคำสุภาพ, ไม่ใส่ข้อมูลที่ไม่แน่ใจ, ไม่ใส่ markdown',
    ]
      .filter(Boolean)
      .join('\n\n')
      .slice(0, 4000);

    const apiKey = String(GEMINI_API_KEY.value() || '').trim();
    if (!apiKey) {
      throw new HttpsError('failed-precondition', 'ยังไม่ได้ตั้งค่า GEMINI_API_KEY');
    }

    const queueLease = await acquireAiProcessingSlot({
      uid: request.auth.uid,
      requestId: request.data?.requestId,
    });
    let queueFinalStatus = 'completed';

    try {

    const apiVersions = ['v1beta', 'v1'];
    const preferredTextModels = [
      'gemini-2.5-flash',
      'gemini-2.0-flash',
      'gemini-2.5-flash-lite',
      'gemini-1.5-flash',
    ];

    const discoveredModelNames = new Set();
    for (const apiVersion of apiVersions) {
      try {
        const listResp = await fetch(
          `https://generativelanguage.googleapis.com/${apiVersion}/models?key=${encodeURIComponent(apiKey)}`,
        );
        if (!listResp.ok) {
          const listErr = await listResp.text();
          logger.warn('askGeminiFlash listModels failed', {
            uid: request.auth.uid,
            apiVersion,
            status: listResp.status,
            body: listErr.slice(0, 400),
          });
          continue;
        }

        const listPayload = await listResp.json();
        const models = Array.isArray(listPayload?.models) ? listPayload.models : [];
        for (const model of models) {
          const name = String(model?.name || '').trim();
          const shortName = name.startsWith('models/') ? name.slice('models/'.length) : name;
          const methods = Array.isArray(model?.supportedGenerationMethods)
            ? model.supportedGenerationMethods.map((value) => String(value || '').trim())
            : [];
          if (!shortName || !methods.includes('generateContent')) {
            continue;
          }
          discoveredModelNames.add(shortName);
        }
      } catch (listError) {
        logger.warn('askGeminiFlash listModels network error', {
          uid: request.auth.uid,
          apiVersion,
          message: listError instanceof Error ? listError.message : String(listError),
        });
      }
    }

    const discoveredTextModels = [...discoveredModelNames].filter((name) =>
      !/image|imagen|tts|embedding|embed|aqa/i.test(name),
    );
    const textModelCandidates = [
      ...new Set([
        ...preferredTextModels,
        ...discoveredTextModels,
      ]),
    ];
    let payload = null;
    let selectedModel = null;
    let selectedApiVersion = null;

    for (const modelName of textModelCandidates) {
      for (const apiVersion of apiVersions) {
        const endpoint =
          `https://generativelanguage.googleapis.com/${apiVersion}/models/${modelName}:generateContent`;

        let response;
        try {
          response = await fetch(`${endpoint}?key=${encodeURIComponent(apiKey)}`, {
            method: 'POST',
            headers: {
              'Content-Type': 'application/json',
            },
            body: JSON.stringify({
              contents: [
                {
                  role: 'user',
                  parts: [{ text: finalPrompt }],
                },
              ],
              generationConfig: {
                temperature: 0.7,
                topP: 0.9,
                maxOutputTokens: 512,
              },
            }),
          });
        } catch (error) {
          logger.error('askGeminiFlash network error', {
            uid: request.auth.uid,
            model: modelName,
            apiVersion,
            message: error instanceof Error ? error.message : String(error),
          });
          throw new HttpsError('unavailable', 'ไม่สามารถเชื่อมต่อบริการ AI ได้ในขณะนี้');
        }

        if (!response.ok) {
          const errorBody = await response.text();
          logger.error('askGeminiFlash upstream error', {
            uid: request.auth.uid,
            model: modelName,
            apiVersion,
            status: response.status,
            body: errorBody.slice(0, 1000),
          });

          const loweredErrorBody = errorBody.toLowerCase();
          const canFallback =
            loweredErrorBody.includes('not found') ||
            loweredErrorBody.includes('unsupported') ||
            loweredErrorBody.includes('no longer available') ||
            loweredErrorBody.includes('model');
          if (canFallback) {
            continue;
          }

          if (
            loweredErrorBody.includes('resource_exhausted') ||
            loweredErrorBody.includes('prepayment credits are depleted') ||
            loweredErrorBody.includes('credits are depleted') ||
            loweredErrorBody.includes('quota')
          ) {
            throw new HttpsError(
              'resource-exhausted',
              'เครดิต Gemini API หมด กรุณาเติมเครดิตหรือเปิด Billing แล้วลองใหม่อีกครั้ง',
            );
          }

          throw new HttpsError('internal', 'บริการ AI ตอบกลับผิดพลาด');
        }

        payload = await response.json();
        selectedModel = modelName;
        selectedApiVersion = apiVersion;
        break;
      }

      if (payload != null && selectedModel != null) {
        break;
      }
    }

    if (payload == null || selectedModel == null) {
      throw new HttpsError('internal', 'ไม่พบโมเดล AI สำหรับสร้างข้อความในโปรเจกต์นี้');
    }

    const text = String(
      payload?.candidates?.[0]?.content?.parts
        ?.map((part) => part?.text || '')
        .join('') || '',
    ).trim();

    if (!text) {
      throw new HttpsError('internal', 'ไม่ได้รับข้อความจาก AI');
    }

    return {
      text,
      model: `${selectedModel}@${selectedApiVersion || 'unknown'}`,
      queuePosition: queueLease.position,
      estimatedWaitSeconds: queueLease.estimatedWaitSeconds,
    };
    } catch (error) {
      queueFinalStatus = 'failed';
      throw error;
    } finally {
      await releaseAiProcessingSlot(queueLease, queueFinalStatus);
    }
  },
);

const GEMINI_API_VERSIONS = ['v1beta', 'v1'];
const GEMINI_PRO_ESCALATION_CONFIDENCE = 65;
const GEMINI_PRO_MODELS = [
  'gemini-2.5-pro',
];
const GEMINI_PREFERRED_MODELS = [
  'gemini-2.5-flash',
  'gemini-2.0-flash',
  'gemini-1.5-flash',
];
const AI_CATALOG_CLASSIFIER_VERSION = 'v9';
const CATALOG_AI_CACHE_COLLECTION = 'catalog_ai_cache';
const PRODUCT_AI_CACHE_COLLECTION = 'product_ai_cache';
const AI_CONFIDENCE_THRESHOLD = 80;
const AI_REVIEW_REASON_LABELS = {
  productName: 'ชื่อสินค้า',
  tax: 'การวิเคราะห์ภาษี',
  productType: 'ประเภทสินค้า',
  nationwideShipping: 'การส่งทั่วประเทศ',
  legal: 'ความถูกกฎหมาย',
  illegal: 'สินค้าผิดกฎหมาย',
};
const AI_CATALOG_IGNORED_DIFF_KEYS = new Set([
  'catalogType',
  'catalogTypeSlug',
  'catalogTypeSort',
  'catalogHeading',
  'catalogHeadingSlug',
  'catalogHeadingSort',
  'catalogTypeConfidence',
  'catalogHeadingConfidence',
  'catalogReviewStatus',
  'catalogReviewReasons',
  'catalogReviewReasonLabels',
  'catalogReviewedAt',
  'catalogReviewedBy',
  'catalogAdminLocked',
  'aiCatalogClassifiedAt',
  'aiCatalogClassifierVersion',
  'aiCatalogInputHash',
  'updatedAt',
]);

function parseJsonFromGeminiParts(parts) {
  const textOutput = Array.isArray(parts)
    ? parts.map((part) => String(part?.text || '').trim()).filter(Boolean).join('\n')
    : '';
  if (!textOutput) return {};
  try {
    const jsonMatch = textOutput.match(/\{[\s\S]*\}/);
    if (jsonMatch) return JSON.parse(jsonMatch[0]);
  } catch (parseError) {
    logger.warn('parseJsonFromGeminiParts failed', {
      message: parseError instanceof Error ? parseError.message : String(parseError),
      text: textOutput.slice(0, 800),
    });
  }
  return {};
}

function uniqueValues(values) {
  return [...new Set(values.filter((value) => String(value || '').trim()))];
}

function isGeminiProModel(modelName) {
  return /(^|-)pro($|-)/i.test(String(modelName || ''));
}

function buildGeminiModelPasses(discoveredModelNames, preferredModels = GEMINI_PREFERRED_MODELS) {
  const discovered = [...discoveredModelNames]
    .map((name) => String(name || '').trim())
    .filter((name) => name && !/image|imagen/i.test(name));
  return {
    flashModels: uniqueValues([
      ...preferredModels.filter((name) => !isGeminiProModel(name)),
      ...discovered.filter((name) => !isGeminiProModel(name)),
    ]),
    proModels: uniqueValues([
      ...GEMINI_PRO_MODELS,
      ...discovered.filter(isGeminiProModel),
    ]),
  };
}

function lowestAiConfidence(analysis) {
  const scores = Object.entries(analysis || {})
    .filter(([key]) => key.endsWith('Confidence'))
    .map(([, value]) => Number(value))
    .filter(Number.isFinite);
  if (scores.length === 0) return null;
  return Math.min(...scores);
}

function shouldEscalateAiAnalysisToPro(analysis) {
  const lowest = lowestAiConfidence(analysis);
  return lowest != null && lowest < GEMINI_PRO_ESCALATION_CONFIDENCE;
}

async function discoverGeminiModelNames(apiKey) {
  const discovered = new Set();
  for (const apiVersion of GEMINI_API_VERSIONS) {
    try {
      const listResp = await fetch(
        `https://generativelanguage.googleapis.com/${apiVersion}/models?key=${encodeURIComponent(apiKey)}`,
      );
      if (!listResp.ok) continue;
      const listPayload = await listResp.json();
      const models = Array.isArray(listPayload?.models) ? listPayload.models : [];
      for (const model of models) {
        const name = String(model?.name || '').trim();
        const shortName = name.startsWith('models/') ? name.slice('models/'.length) : name;
        const methods = Array.isArray(model?.supportedGenerationMethods)
          ? model.supportedGenerationMethods.map((value) => String(value || '').trim())
          : [];
        if (shortName && methods.includes('generateContent') && !/image|imagen/i.test(shortName)) {
          discovered.add(shortName);
        }
      }
    } catch (listError) {
      logger.warn('discoverGeminiModelNames failed', {
        apiVersion,
        message: listError instanceof Error ? listError.message : String(listError),
      });
    }
  }
  return discovered;
}

async function runGeminiJsonPrompt({
  apiKey,
  prompt,
  imageInlineData,
  logContext = {},
  temperature = 0.1,
}) {
  const discoveredModelNames = await discoverGeminiModelNames(apiKey);
  const { flashModels, proModels } = buildGeminiModelPasses(discoveredModelNames);
  let lastErrorStatus = null;
  let lastErrorBody = '';

  async function tryModelCandidates(modelCandidates) {
    for (const modelName of modelCandidates) {
    for (const apiVersion of GEMINI_API_VERSIONS) {
      const endpoint = `https://generativelanguage.googleapis.com/${apiVersion}/models/${modelName}:generateContent`;
      const parts = [{ text: prompt }];
      if (imageInlineData?.data) {
        parts.push({
          inlineData: {
            mimeType: imageInlineData.mimeType || 'image/jpeg',
            data: imageInlineData.data,
          },
        });
      }

      let response;
      try {
        response = await fetch(`${endpoint}?key=${encodeURIComponent(apiKey)}`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({
            contents: [{ role: 'user', parts }],
            generationConfig: {
              temperature,
              responseMimeType: 'application/json',
            },
          }),
        });
      } catch (error) {
        logger.error('runGeminiJsonPrompt network error', {
          ...logContext,
          model: modelName,
          apiVersion,
          message: error instanceof Error ? error.message : String(error),
        });
        throw error;
      }

      if (!response.ok) {
        const errorBody = await response.text();
        lastErrorStatus = response.status;
        lastErrorBody = errorBody;
        const lowered = errorBody.toLowerCase();
        const canTryNext =
          lowered.includes('not found') ||
          lowered.includes('unsupported') ||
          lowered.includes('method not found') ||
          lowered.includes('model') ||
          lowered.includes('invalid json payload') ||
          lowered.includes('unknown name') ||
          lowered.includes('cannot find field') ||
          lowered.includes('responsemimetype');
        if (canTryNext) continue;
        throw new Error(`Gemini upstream error ${response.status}`);
      }

      const payload = await response.json();
      const resultParts = payload?.candidates?.[0]?.content?.parts;
      const analysis = parseJsonFromGeminiParts(resultParts);
      if (Object.keys(analysis).length > 0) {
        return {
          analysis,
          model: `${modelName}@${apiVersion}`,
        };
      }

      lastErrorStatus = 200;
      lastErrorBody = JSON.stringify(payload).slice(0, 1000);
    }
  }
    return null;
  }

  const flashResult = await tryModelCandidates(flashModels);
  if (flashResult) {
    if (!shouldEscalateAiAnalysisToPro(flashResult.analysis)) {
      return flashResult;
    }
    const proResult = await tryModelCandidates(proModels);
    if (proResult) {
      return {
        ...proResult,
        model: `${proResult.model} escalatedFrom=${flashResult.model}`,
      };
    }
    return flashResult;
  }

  logger.error('runGeminiJsonPrompt no available model', {
    ...logContext,
    lastErrorStatus,
    lastErrorBody: String(lastErrorBody || '').slice(0, 1000),
  });
  throw new Error('No Gemini model available for JSON prompt');
}

function readFirstProductImageUrl(product) {
  const thumbnailUrls = Array.isArray(product?.thumbnailUrls) ? product.thumbnailUrls : [];
  for (const url of thumbnailUrls) {
    const trimmed = String(url || '').trim();
    if (trimmed) return trimmed;
  }
  const imageUrls = Array.isArray(product?.imageUrls) ? product.imageUrls : [];
  for (const url of imageUrls) {
    const trimmed = String(url || '').trim();
    if (trimmed) return trimmed;
  }
  return '';
}

async function fetchImageAsInlineData(imageUrl) {
  const url = String(imageUrl || '').trim();
  if (!url) return null;

  try {
    const response = await fetch(url);
    if (!response.ok) {
      logger.warn('fetchImageAsInlineData upstream error', {
        status: response.status,
        url: url.slice(0, 160),
      });
      return null;
    }

    const buffer = Buffer.from(await response.arrayBuffer());
    if (buffer.length > 5 * 1024 * 1024) {
      logger.warn('fetchImageAsInlineData image too large', { bytes: buffer.length });
      return null;
    }

    const contentType = String(response.headers.get('content-type') || 'image/jpeg')
      .split(';')[0]
      .trim()
      .toLowerCase();
    const allowedMimeTypes = new Set(['image/jpeg', 'image/jpg', 'image/png', 'image/webp']);
    const normalizedMimeType = contentType === 'image/jpg' ? 'image/jpeg' : contentType;
    const mimeType = allowedMimeTypes.has(normalizedMimeType) ? normalizedMimeType : 'image/jpeg';
    return { mimeType, data: buffer.toString('base64') };
  } catch (error) {
    logger.warn('fetchImageAsInlineData failed', {
      url: url.slice(0, 160),
      message: error instanceof Error ? error.message : String(error),
    });
    return null;
  }
}

function resolveCatalogTypeFromProduct(product) {
  const type = String(product?.aiProductType || product?.productType || '').trim();
  const semanticSource = [
    String(product?.name || '').trim(),
    String(product?.description || '').trim(),
  ].join(' ').toLowerCase();

  // Known product semantics win over stale AI/category fields.
  const marketClassification = resolveMarketCatalogClassification(semanticSource);
  if (marketClassification) return marketClassification.catalogType;
  if (resolvePharmacyCatalogHeadingFromSource(semanticSource)) return 'ยาและเวชภัณฑ์';

  const catalogType = String(product?.catalogType || '').trim();
  if (catalogType) return catalogType;

  const category = String(product?.productCategory || '').trim();
  return type || category || 'อื่นๆ';
}

function marketCatalogResult(catalogType, catalogHeading) {
  return {
    catalogType,
    catalogTypeSlug: normalizeCatalogHeadingSlug(null, catalogType),
    catalogHeading,
    catalogHeadingSlug: normalizeCatalogHeadingSlug(null, catalogHeading),
    model: 'keyword-rule',
  };
}

function resolveMarketCatalogClassification(source) {
  const text = String(source || '').toLowerCase();
  const has = (pattern) => pattern.test(text);
  const isSeafood = has(/ปลา|กุ้ง|ปู|หอย|ปลาหมึก|อาหารทะเล|ทะเล|seafood|fish|shrimp|crab|squid|shellfish/);
  const isDriedOrProcessed = has(/อาหารทะเลแปรรูป|แปรรูป|ของแห้ง|แห้ง|อบแห้ง|ตากแห้ง|แดดเดียว|เค็ม|รมควัน|ถนอมอาหาร|processed|dried|dry|smoked|salted/);

  if (has(/ชุดนักเรียน|เครื่องแบบ|uniform/)) {
    return marketCatalogResult('ชุดนักเรียน / เครื่องแบบ', 'ชุดนักเรียน');
  }
  if (has(/รองเท้านักเรียน/)) {
    return marketCatalogResult('รองเท้า / กระเป๋า', 'รองเท้านักเรียน');
  }
  if (has(/รองเท้า|แตะ|sneaker|shoe/)) {
    return marketCatalogResult('รองเท้า / กระเป๋า', 'รองเท้า');
  }
  if (has(/กระเป๋า|bag/)) {
    return marketCatalogResult('รองเท้า / กระเป๋า', 'กระเป๋า');
  }
  if (has(/เสื้อ|shirt/)) return marketCatalogResult('เสื้อผ้า', 'เสื้อ');
  if (has(/กางเกง|pants/)) return marketCatalogResult('เสื้อผ้า', 'กางเกง');
  if (has(/กระโปรง|skirt/)) return marketCatalogResult('เสื้อผ้า', 'กระโปรง');
  if (has(/เดรส|ผ้า|เสื้อผ้า|clothes|dress/)) return marketCatalogResult('เสื้อผ้า', 'เสื้อผ้า');
  if (has(/สมุด|กระดาษ|notebook|paper/)) {
    return marketCatalogResult('เครื่องเขียน / อุปกรณ์เรียน', 'สมุด / กระดาษ');
  }
  if (has(/ปากกา|ดินสอ|ยางลบ|ไม้บรรทัด|เครื่องเขียน|อุปกรณ์เรียน|stationery|pencil|pen/)) {
    return marketCatalogResult('เครื่องเขียน / อุปกรณ์เรียน', 'ปากกา / ดินสอ');
  }
  if (isSeafood && isDriedOrProcessed) {
    if (has(/ปลาหมึก/)) return marketCatalogResult('อาหารทะเลแปรรูป', 'ปลาหมึกแห้ง');
    if (has(/ปลาแดดเดียว|ปลาแห้ง/)) return marketCatalogResult('อาหารทะเลแปรรูป', 'ปลาแห้ง / ปลาแดดเดียว');
    return marketCatalogResult('อาหารทะเลแปรรูป', 'อาหารทะเลแปรรูป');
  }
  if (isSeafood) {
    if (has(/กุ้ง/)) return marketCatalogResult('อาหารทะเลสด', 'กุ้งสด');
    if (has(/ปู/)) return marketCatalogResult('อาหารทะเลสด', 'ปูสด');
    if (has(/หอย/)) return marketCatalogResult('อาหารทะเลสด', 'หอยสด');
    if (has(/ปลาหมึก/)) return marketCatalogResult('อาหารทะเลสด', 'ปลาหมึกสด');
    if (has(/ปลา|fish/)) return marketCatalogResult('อาหารทะเลสด', 'ปลาสด');
    return marketCatalogResult('อาหารทะเลสด', 'อาหารทะเลสด');
  }
  if (has(/หมู|pork/)) return marketCatalogResult('เนื้อสัตว์', 'หมูสด');
  if (has(/ไก่|chicken/)) return marketCatalogResult('เนื้อสัตว์', 'ไก่สด');
  if (has(/เนื้อ|วัว|beef/)) return marketCatalogResult('เนื้อสัตว์', 'เนื้อสด');
  if (has(/เป็ด|duck|meat/)) return marketCatalogResult('เนื้อสัตว์', 'เนื้อสัตว์');
  if (has(/ไข่|egg/)) return marketCatalogResult('ไข่ / เต้าหู้', 'ไข่');
  if (has(/เต้าหู้|tofu/)) return marketCatalogResult('ไข่ / เต้าหู้', 'เต้าหู้');
  if (has(/แก้วมังกร|มังกร|ผลไม้|fruit|มะม่วง|กล้วย|ส้ม|ทุเรียน|แอปเปิล|แอปเปิ้ล|องุ่น|แตงโม|สับปะรด|ลำไย|ลิ้นจี่|ฝรั่ง|มังคุด|เงาะ/)) {
    return marketCatalogResult('ผลไม้', 'ผลไม้สด');
  }
  if (has(/ผัก|ผักสด|vegetable|คะน้า|กะหล่ำ|ผักบุ้ง|แตงกวา|มะเขือ|ต้นหอม|ผักชี|พริก/)) {
    return marketCatalogResult('ผักสด', has(/ต้นหอม|ผักชี|พริก/) ? 'ผักสวนครัว' : 'ผักใบ');
  }
  if (has(/น้ำปลา/)) return marketCatalogResult('เครื่องปรุง / ซอส', 'น้ำปลา');
  if (has(/ซีอิ๊ว|ซอส|น้ำมันหอย|seasoning|sauce/)) {
    return marketCatalogResult('เครื่องปรุง / ซอส', 'ซอส / ซีอิ๊ว');
  }
  if (has(/เครื่องปรุง|ผงชูรส|เกลือ|น้ำตาล|กะปิ|ปลาร้า/)) {
    return marketCatalogResult('เครื่องปรุง / ซอส', 'เครื่องปรุง');
  }
  if (has(/ข้าวสาร/)) return marketCatalogResult('ของแห้ง / วัตถุดิบ', 'ข้าวสาร');
  if (has(/เส้นหมี่|วุ้นเส้น|บะหมี่|มาม่า/)) {
    return marketCatalogResult('ของแห้ง / วัตถุดิบ', 'เส้น / บะหมี่');
  }
  if (isDriedOrProcessed || has(/แป้ง|ถั่ว|ธัญพืช|กะทิ|วัตถุดิบ|grocery|pantry/)) {
    return marketCatalogResult('ของแห้ง / วัตถุดิบ', 'ของแห้ง / วัตถุดิบ');
  }
  if (has(/อาหารพร้อมทาน|พร้อมทาน|ข้าวกล่อง|ข้าวแกง|แกง|ผัด|ทอด|ต้ม|ยำ|กับข้าว|prepared|cooked/)) {
    return marketCatalogResult('อาหารพร้อมทาน', 'อาหารพร้อมทาน');
  }
  if (has(/เบเกอรี่|เค้ก|ปัง|bakery/)) return marketCatalogResult('ขนม / เบเกอรี่', 'เบเกอรี่');
  if (has(/ขนม|คุกกี้|ของหวาน|snack|dessert/)) return marketCatalogResult('ขนม / เบเกอรี่', 'ขนม');
  if (has(/น้ำดื่ม|น้ำเปล่า/)) return marketCatalogResult('เครื่องดื่ม', 'น้ำดื่ม');
  if (has(/ชา|tea/)) return marketCatalogResult('เครื่องดื่ม', 'ชา');
  if (has(/กาแฟ|coffee/)) return marketCatalogResult('เครื่องดื่ม', 'กาแฟ');
  if (has(/เครื่องดื่ม|น้ำอัดลม|นม|beverage|drink/)) return marketCatalogResult('เครื่องดื่ม', 'เครื่องดื่ม');
  if (has(/ผงซักฟอก|น้ำยาปรับผ้านุ่ม/)) return marketCatalogResult('ของใช้ในบ้าน', 'ซักผ้า');
  if (has(/น้ำยาล้างจาน/)) return marketCatalogResult('ของใช้ในบ้าน', 'ล้างจาน');
  if (has(/ไม้กวาด|ถุงขยะ|ทิชชู่|ของใช้ในบ้าน|household|detergent/)) {
    return marketCatalogResult('ของใช้ในบ้าน', 'ของใช้ในบ้าน');
  }
  if (has(/สบู่|แชมพู|ยาสีฟัน|แปรงสีฟัน|ครีม|โลชั่น|ของใช้ส่วนตัว|personal care|shampoo|soap/)) {
    return marketCatalogResult('ของใช้ส่วนตัว', 'ของใช้ส่วนตัว');
  }
  return null;
}

function resolvePharmacyCatalogHeadingFromSource(source) {
  const text = String(source || '').toLowerCase();
  const hasPharmacySignal =
    /ยา|เวชภัณฑ์|เภสัช|pharmacy|medicine|drug|medical/.test(text) ||
    /พารา|paracetamol|ibuprofen|ไอบู|แก้แพ้|loratadine|cetirizine|แก้ไอ|ลดน้ำมูก|ท้องเสีย|ลดกรด|ยาระบาย|เกลือแร่|ยาหม่อง|เบตาดีน|betadine|พลาสเตอร์|ผ้าก๊อซ|สำลี|แอลกอฮอล์|หน้ากาก|ถุงมือ|ปรอทวัดไข้|เครื่องวัดความดัน|วิตามิน|อาหารเสริม|คอลลาเจน|แคลเซียม|ผ้าอ้อม|ขวดนม|นมผง|ยาสีฟัน|แปรงสีฟัน|น้ำยาบ้วนปาก|ครีมกันแดด|โลชั่น|โฟมล้างหน้า|น้ำเกลือ/.test(text);
  if (!hasPharmacySignal) {
    return null;
  }

  if (/พารา|paracetamol|ไอบู|ibuprofen|แก้ปวด|ลดไข้|ปวดหัว|ปวดเมื่อย|ไข้/.test(text)) {
    return 'ยาแก้ปวด / ลดไข้';
  }
  if (/แก้แพ้|loratadine|cetirizine|หวัด|แก้ไอ|ไอ|ลดน้ำมูก|คัดจมูก|เจ็บคอ/.test(text)) {
    return 'ยาแก้แพ้ / หวัด / ไอ';
  }
  if (/ท้องเสีย|ลดกรด|กรดไหลย้อน|ยาระบาย|เกลือแร่|ors|ท้องอืด|ย่อยอาหาร|คลื่นไส้|อาเจียน/.test(text)) {
    return 'ยาทางเดินอาหาร';
  }
  if (/ยาทา|ยาหม่อง|เบตาดีน|betadine|ครีมยา|ขี้ผึ้ง|แผล|เชื้อรา|ผื่น|สเปรย์ยา|บาล์ม/.test(text)) {
    return 'ยาภายนอก';
  }
  if (/ผ้าก๊อซ|ก๊อซ|สำลี|พลาสเตอร์|แอลกอฮอล์|น้ำเกลือ|povidone|cotton|gauze|bandage/.test(text)) {
    return 'เวชภัณฑ์';
  }
  if (/หน้ากาก|ถุงมือ|ปรอทวัดไข้|เครื่องวัดความดัน|เทอร์โมมิเตอร์|ชุดตรวจ|เครื่องพ่นยา|อุปกรณ์การแพทย์/.test(text)) {
    return 'อุปกรณ์การแพทย์';
  }
  if (/วิตามิน|อาหารเสริม|คอลลาเจน|แคลเซียม|ซิงค์|zinc|วิตามินซี|vitamin|supplement|fish oil|น้ำมันปลา/.test(text)) {
    return 'วิตามิน / อาหารเสริม';
  }
  if (/แม่และเด็ก|เด็ก|ทารก|ผ้าอ้อม|ขวดนม|นมผง|จุกนม|baby|infant/.test(text)) {
    return 'แม่และเด็ก';
  }
  if (/ยาสีฟัน|แปรงสีฟัน|น้ำยาบ้วนปาก|ไหมขัดฟัน|ช่องปาก|oral|tooth|mouthwash/.test(text)) {
    return 'สุขภาพช่องปาก';
  }
  if (/ครีมกันแดด|โลชั่น|สบู่|แชมพู|โฟมล้างหน้า|เจลล้างมือ|สกินแคร์|ดูแลผิว|ของใช้ส่วนตัว|skincare|sunscreen|lotion|shampoo/.test(text)) {
    return 'ดูแลผิว / ของใช้ส่วนตัว';
  }

  return 'ยาและเวชภัณฑ์';
}

function resolveRuleBasedCatalogClassification(product, serviceType = '') {
  const source = [
    String(product?.name || '').trim(),
    String(product?.description || '').trim(),
  ].join(' ').toLowerCase();
  const normalizedService = catalogTaxonomy.normalizeShopServiceType(serviceType);

  if (normalizedService === 'ร้านขายยา') {
    const pharmacyHeading = resolvePharmacyCatalogHeadingFromSource(source);
    if (pharmacyHeading) {
      return {
        catalogType: 'ยาและเวชภัณฑ์',
        catalogTypeSlug: normalizeCatalogHeadingSlug(null, 'ยาและเวชภัณฑ์'),
        catalogHeading: pharmacyHeading,
        catalogHeadingSlug: normalizeCatalogHeadingSlug(null, pharmacyHeading),
        catalogTypeConfidence: 100,
        catalogHeadingConfidence: 100,
        model: 'keyword-rule',
      };
    }
    return null;
  }

  if (normalizedService === 'ตลาด' || !normalizedService) {
    const marketResult = resolveMarketCatalogClassification(source);
    if (marketResult) {
      return {
        ...marketResult,
        catalogTypeConfidence: 100,
        catalogHeadingConfidence: 100,
      };
    }
  }

  return null;
}

function computeAiCatalogInputHash(product) {
  const payload = JSON.stringify({
    name: String(product?.name || '').trim(),
    description: String(product?.description || '').trim(),
    firstImageUrl: readFirstProductImageUrl(product),
    productCategory: String(product?.productCategory || '').trim(),
    aiProductType: String(product?.aiProductType || product?.productType || '').trim(),
  });
  return crypto.createHash('sha256').update(payload).digest('hex');
}

function normalizeCatalogHeadingSlug(raw, fallbackLabel) {
  const source = String(raw || fallbackLabel || '').trim();
  if (!source) return 'other';
  const slug = source
    .normalize('NFKC')
    .replace(/\s+/g, '-')
    .replace(/[^\p{L}\p{N}\-_]/gu, '')
    .slice(0, 80);
  if (slug) return slug;
  return crypto.createHash('sha256').update(source).digest('hex').slice(0, 16);
}

function catalogAiFieldsOnlyChanged(before, after) {
  const allKeys = new Set([
    ...Object.keys(before || {}),
    ...Object.keys(after || {}),
  ]);

  for (const key of allKeys) {
    if (AI_CATALOG_IGNORED_DIFF_KEYS.has(key)) continue;
    const beforeValue = before?.[key];
    const afterValue = after?.[key];
    if (JSON.stringify(beforeValue) !== JSON.stringify(afterValue)) {
      return false;
    }
  }
  return true;
}

function shouldSkipProductCatalogClassify({ before, after, productId }) {
  if (!after) {
    return 'deleted';
  }

  if (after.isActive !== true) {
    return 'inactive';
  }

  if (String(after.adminReviewStatus || '').trim() === 'pending') {
    return 'pending_review';
  }

  if (after.aiIsLegalInThailand === false) {
    return 'illegal';
  }

  if (after.aiRequiresAdminReview === true) {
    return 'low_confidence_review';
  }

  if (after.catalogAdminLocked === true) {
    return 'admin_locked';
  }

  const productName = String(after.name || '').trim();
  const firstImageUrl = readFirstProductImageUrl(after);
  if (!productName && !firstImageUrl) {
    return 'missing_input';
  }

  const inputHash = computeAiCatalogInputHash(after);
  const classifierVersion = String(after.aiCatalogClassifierVersion || '').trim();
  const expectedType = resolveCatalogTypeFromProduct(after);
  if (
    String(after.aiCatalogInputHash || '').trim() === inputHash
    && String(after.catalogType || '').trim() === expectedType
    && String(after.catalogHeading || '').trim()
    && classifierVersion === AI_CATALOG_CLASSIFIER_VERSION
  ) {
    return 'already_classified';
  }

  if (
    before
    && String(before.catalogHeading || '').trim()
    && catalogAiFieldsOnlyChanged(before, after)
  ) {
    return 'catalog_fields_only';
  }

  return null;
}

async function loadCatalogAiCache(inputHash) {
  const snap = await db.collection(CATALOG_AI_CACHE_COLLECTION).doc(inputHash).get();
  if (!snap.exists) {
    return null;
  }
  const data = snap.data() || {};
  const cacheVersion = String(data.aiCatalogClassifierVersion || '').trim();
  if (cacheVersion !== AI_CATALOG_CLASSIFIER_VERSION) {
    return null;
  }
  const catalogHeading = String(data.catalogHeading || '').trim();
  if (!catalogHeading) {
    return null;
  }
  const catalogType = String(data.catalogType || '').trim();
  const catalogHeadingSlug = String(data.catalogHeadingSlug || '').trim()
    || normalizeCatalogHeadingSlug(catalogHeading, catalogHeading);
  return {
    catalogType,
    catalogTypeSlug: String(data.catalogTypeSlug || '').trim()
      || (catalogType ? normalizeCatalogHeadingSlug(null, catalogType) : ''),
    catalogHeading,
    catalogHeadingSlug,
    aiCatalogClassifierVersion: cacheVersion,
    model: String(data.model || 'cache').trim(),
  };
}

async function saveCatalogAiCache(inputHash, classification, sourceProductId) {
  const ref = db.collection(CATALOG_AI_CACHE_COLLECTION).doc(inputHash);
  const existing = await ref.get();
  await ref.set({
    inputHash,
    catalogType: classification.catalogType || null,
    catalogTypeSlug: classification.catalogTypeSlug || null,
    catalogHeading: classification.catalogHeading,
    catalogHeadingSlug: classification.catalogHeadingSlug,
    aiCatalogClassifierVersion:
      classification.aiCatalogClassifierVersion || AI_CATALOG_CLASSIFIER_VERSION,
    sourceProductId: sourceProductId || null,
    model: classification.model || null,
    usageCount: FieldValue.increment(1),
    updatedAt: FieldValue.serverTimestamp(),
    createdAt: existing.exists
      ? existing.data()?.createdAt || FieldValue.serverTimestamp()
      : FieldValue.serverTimestamp(),
  }, { merge: true });
}

async function loadShopServiceType(shopId) {
  const normalizedShopId = String(shopId || '').trim();
  if (!normalizedShopId) {
    return '';
  }
  const snap = await db.collection('public_shops').doc(normalizedShopId).get();
  if (!snap.exists) {
    return '';
  }
  const data = snap.data() || {};
  return catalogTaxonomy.normalizeShopServiceType(
    data.serviceType || data.service_type || data.businessType || '',
  );
}

async function finalizeCatalogClassification(product, shopId, headingResult) {
  const catalogType =
    String(headingResult.catalogType || '').trim() ||
    resolveCatalogTypeFromProduct(product);
  const catalogTypeSlug =
    String(headingResult.catalogTypeSlug || '').trim() ||
    normalizeCatalogHeadingSlug(null, catalogType);
  const { catalogTypeSort, catalogHeadingSort } = await applyCatalogClassificationToShop({
    shopId,
    catalogType,
    catalogTypeSlug,
    catalogHeading: headingResult.catalogHeading,
    catalogHeadingSlug: headingResult.catalogHeadingSlug,
  });
  return {
    catalogType,
    catalogTypeSlug,
    catalogTypeSort,
    catalogHeading: headingResult.catalogHeading,
    catalogHeadingSlug: headingResult.catalogHeadingSlug,
    catalogHeadingSort,
    catalogTypeConfidence: catalogTaxonomy.normalizeConfidence(
      headingResult.catalogTypeConfidence,
      headingResult.model === 'keyword-rule' ? 100 : 0,
    ),
    catalogHeadingConfidence: catalogTaxonomy.normalizeConfidence(
      headingResult.catalogHeadingConfidence,
      headingResult.model === 'keyword-rule' ? 100 : 0,
    ),
    aiCatalogInputHash: computeAiCatalogInputHash(product),
    aiCatalogClassifierVersion: AI_CATALOG_CLASSIFIER_VERSION,
    model: headingResult.model || null,
  };
}

async function findPriorClassifiedProduct(inputHash) {
  const snapshot = await db.collection('products')
    .where('aiCatalogInputHash', '==', inputHash)
    .limit(5)
    .get();
  for (const doc of snapshot.docs) {
    const data = doc.data() || {};
    const classifierVersion = String(data.aiCatalogClassifierVersion || '').trim();
    if (classifierVersion !== AI_CATALOG_CLASSIFIER_VERSION) {
      continue;
    }
    const catalogHeading = String(data.catalogHeading || '').trim();
    if (!catalogHeading) {
      continue;
    }
    const catalogType = String(data.catalogType || '').trim();
    return {
      productId: doc.id,
      catalogType,
      catalogTypeSlug: String(data.catalogTypeSlug || '').trim()
        || (catalogType ? normalizeCatalogHeadingSlug(null, catalogType) : ''),
      catalogHeading,
      catalogHeadingSlug: String(data.catalogHeadingSlug || '').trim()
        || normalizeCatalogHeadingSlug(catalogHeading, catalogHeading),
      aiCatalogClassifierVersion: classifierVersion,
    };
  }
  return null;
}

async function applyCatalogClassificationToShop({
  shopId,
  catalogType,
  catalogTypeSlug,
  catalogHeading,
  catalogHeadingSlug,
}) {
  const catalogTypeSort = await upsertShopCatalogType({
    shopId,
    slug: catalogTypeSlug,
    label: catalogType,
  });
  const catalogHeadingSort = await upsertShopCatalogHeading({
    shopId,
    slug: catalogHeadingSlug,
    label: catalogHeading,
    catalogTypeSlug,
    reuseExisting: true,
  });
  return { catalogTypeSort, catalogHeadingSort };
}

async function resolveProductCatalogClassification({
  product,
  shopId,
  productId,
  apiKey,
}) {
  const inputHash = computeAiCatalogInputHash(product);
  const serviceType = await loadShopServiceType(shopId);

  const ruleBased = resolveRuleBasedCatalogClassification(product, serviceType);
  if (ruleBased) {
    const classification = await finalizeCatalogClassification(product, shopId, ruleBased);
    await saveCatalogAiCache(inputHash, classification, productId);
    return {
      ...classification,
      fromCache: 'keyword_rule',
      serviceType,
    };
  }

  const cached = await loadCatalogAiCache(inputHash);
  if (cached) {
    await db.collection(CATALOG_AI_CACHE_COLLECTION).doc(inputHash).set({
      usageCount: FieldValue.increment(1),
      updatedAt: FieldValue.serverTimestamp(),
    }, { merge: true });
    const classification = await finalizeCatalogClassification(product, shopId, cached);
    return {
      ...classification,
      fromCache: 'catalog_ai_cache',
      serviceType,
    };
  }

  const priorProduct = await findPriorClassifiedProduct(inputHash);
  if (priorProduct) {
    const classification = await finalizeCatalogClassification(product, shopId, priorProduct);
    await saveCatalogAiCache(inputHash, classification, priorProduct.productId);
    return {
      ...classification,
      fromCache: 'prior_product',
      serviceType,
    };
  }

  const headingResult = await classifyProductCatalogHeading({
    product,
    shopId,
    productId,
    apiKey,
    serviceType,
  });
  const classification = await finalizeCatalogClassification(product, shopId, headingResult);
  await saveCatalogAiCache(inputHash, classification, productId);
  return {
    ...classification,
    fromCache: false,
    serviceType,
  };
}

const PRODUCT_AI_ANALYSIS_VERSION = 4;

const STANDARD_SALE_UNITS = ['ชิ้น', 'ถุง', 'แพ็ค', 'มัด', 'ลูก', 'กล่อง'];

function normalizeSaleUnit(value) {
  const text = String(value || '').trim();
  if (!text) {
    return '';
  }
  const compact = text.replace(/\s+/g, '');
  const aliases = {
    แพค: 'แพ็ค',
    pack: 'แพ็ค',
    Pack: 'แพ็ค',
    ชิ้น: 'ชิ้น',
    ถุง: 'ถุง',
    มัด: 'มัด',
    ลูก: 'ลูก',
    กล่อง: 'กล่อง',
    แพ็ค: 'แพ็ค',
  };
  if (STANDARD_SALE_UNITS.includes(compact)) {
    return compact;
  }
  if (aliases[compact]) {
    return aliases[compact];
  }
  return text.slice(0, 24);
}

function computeProductAiAnalysisHash({
  productName,
  description,
  category,
  unit,
  price,
  weight,
  weightUnit,
  imageBase64,
  imageUrl,
}) {
  const imageHash = imageBase64
    ? crypto.createHash('sha256').update(String(imageBase64 || '')).digest('hex')
    : crypto.createHash('sha256').update(String(imageUrl || '')).digest('hex');
  return crypto.createHash('sha256').update(JSON.stringify({
    version: PRODUCT_AI_ANALYSIS_VERSION,
    productName: String(productName || '').trim(),
    description: String(description || '').trim(),
    category: String(category || '').trim(),
    unit: String(unit || '').trim(),
    price: String(price || '').trim(),
    weight: String(weight || '').trim(),
    weightUnit: String(weightUnit || '').trim(),
    imageHash,
  })).digest('hex');
}

function normalizeAiConfidence(value) {
  const num = Number(value);
  if (!Number.isFinite(num)) {
    return null;
  }
  return Math.max(0, Math.min(100, Math.round(num)));
}

function normalizeParcelDimensionCm(value) {
  const num = Number(value);
  if (!Number.isFinite(num) || num <= 0) {
    return null;
  }
  return Math.min(200, Math.round(num * 10) / 10);
}

function buildAiConfidencePayload(analysis) {
  return {
    productNameConfidence: normalizeAiConfidence(analysis?.productNameConfidence),
    taxConfidence: normalizeAiConfidence(analysis?.taxConfidence),
    productTypeConfidence: normalizeAiConfidence(analysis?.productTypeConfidence),
    nationwideShippingConfidence: normalizeAiConfidence(analysis?.nationwideShippingConfidence),
    legalConfidence: normalizeAiConfidence(analysis?.legalConfidence),
  };
}

function evaluateAiAdminReviewRequired({ confidences, isLegalInThailand }) {
  if (isLegalInThailand !== true) {
    return {
      required: true,
      reasons: ['illegal'],
      reasonLabels: [AI_REVIEW_REASON_LABELS.illegal],
    };
  }

  const checks = [
    ['productName', confidences.productNameConfidence],
    ['tax', confidences.taxConfidence],
    ['productType', confidences.productTypeConfidence],
    ['nationwideShipping', confidences.nationwideShippingConfidence],
    ['legal', confidences.legalConfidence],
  ];
  const reasons = [];
  for (const [key, score] of checks) {
    if (score == null || score < AI_CONFIDENCE_THRESHOLD) {
      reasons.push(key);
    }
  }

  return {
    required: reasons.length > 0,
    reasons,
    reasonLabels: reasons.map((key) => AI_REVIEW_REASON_LABELS[key] || key),
  };
}

function buildProductAiCallableResult(analysis, extras = {}) {
  const isLegalInThailand = analysis.isLegalInThailand === true;
  const confidences = buildAiConfidencePayload(analysis);
  const reviewEval = evaluateAiAdminReviewRequired({
    confidences,
    isLegalInThailand,
  });

  return {
    productName: String(analysis.productName || '').trim(),
    description: String(analysis.description || '').trim(),
    isLegalInThailand,
    legalReason: String(analysis.legalReason || '').trim(),
    productType: String(analysis.productType || '').trim(),
    productCategory: String(analysis.productCategory || '').trim(),
    taxStatus: String(analysis.taxStatus || '').trim(),
    taxStatusLabel: String(analysis.taxStatusLabel || '').trim(),
    taxReason: String(analysis.taxReason || '').trim(),
    isFreshProduct: analysis.isFreshProduct === true,
    isProcessed: analysis.isProcessed === true,
    canShipNationwide: analysis.canShipNationwide === true,
    nationwideShippingReason: String(analysis.nationwideShippingReason || '').trim(),
    parcelLengthCm: normalizeParcelDimensionCm(analysis.parcelLengthCm),
    parcelWidthCm: normalizeParcelDimensionCm(analysis.parcelWidthCm),
    parcelHeightCm: normalizeParcelDimensionCm(analysis.parcelHeightCm),
    parcelDimensionReason: String(analysis.parcelDimensionReason || '').trim(),
    parcelDimensionConfidence: normalizeAiConfidence(analysis.parcelDimensionConfidence),
    saleUnit: normalizeSaleUnit(analysis.saleUnit),
    productNameConfidence: confidences.productNameConfidence,
    taxConfidence: confidences.taxConfidence,
    productTypeConfidence: confidences.productTypeConfidence,
    nationwideShippingConfidence: confidences.nationwideShippingConfidence,
    legalConfidence: confidences.legalConfidence,
    requiresAdminReview: reviewEval.required,
    reviewReasons: reviewEval.reasons,
    reviewReasonLabels: reviewEval.reasonLabels,
    ...extras,
  };
}

async function loadProductAiCache(inputHash) {
  const snap = await db.collection(PRODUCT_AI_CACHE_COLLECTION).doc(inputHash).get();
  if (!snap.exists) {
    return null;
  }
  const data = snap.data() || {};
  if (!String(data.productCategory || data.productType || data.description || '').trim()) {
    return null;
  }
  if (data.productNameConfidence == null) {
    return null;
  }
  return data;
}

async function saveProductAiCache(inputHash, analysis, model) {
  const ref = db.collection(PRODUCT_AI_CACHE_COLLECTION).doc(inputHash);
  const existing = await ref.get();
  await ref.set({
    inputHash,
    productName: String(analysis.productName || '').trim(),
    description: String(analysis.description || '').trim(),
    isLegalInThailand: analysis.isLegalInThailand === true,
    legalReason: String(analysis.legalReason || '').trim(),
    productType: String(analysis.productType || '').trim(),
    productCategory: String(analysis.productCategory || '').trim(),
    taxStatus: String(analysis.taxStatus || '').trim(),
    taxStatusLabel: String(analysis.taxStatusLabel || '').trim(),
    taxReason: String(analysis.taxReason || '').trim(),
    isFreshProduct: analysis.isFreshProduct === true,
    isProcessed: analysis.isProcessed === true,
    canShipNationwide: analysis.canShipNationwide === true,
    nationwideShippingReason: String(analysis.nationwideShippingReason || '').trim(),
    parcelLengthCm: normalizeParcelDimensionCm(analysis.parcelLengthCm),
    parcelWidthCm: normalizeParcelDimensionCm(analysis.parcelWidthCm),
    parcelHeightCm: normalizeParcelDimensionCm(analysis.parcelHeightCm),
    parcelDimensionReason: String(analysis.parcelDimensionReason || '').trim(),
    parcelDimensionConfidence: normalizeAiConfidence(analysis.parcelDimensionConfidence),
    saleUnit: normalizeSaleUnit(analysis.saleUnit),
    productNameConfidence: normalizeAiConfidence(analysis.productNameConfidence),
    taxConfidence: normalizeAiConfidence(analysis.taxConfidence),
    productTypeConfidence: normalizeAiConfidence(analysis.productTypeConfidence),
    nationwideShippingConfidence: normalizeAiConfidence(analysis.nationwideShippingConfidence),
    legalConfidence: normalizeAiConfidence(analysis.legalConfidence),
    model: model || null,
    usageCount: FieldValue.increment(1),
    updatedAt: FieldValue.serverTimestamp(),
    createdAt: existing.exists
      ? existing.data()?.createdAt || FieldValue.serverTimestamp()
      : FieldValue.serverTimestamp(),
  }, { merge: true });
}

async function loadShopCatalogTypes(shopId) {
  const snapshot = await db
    .collection('public_shops')
    .doc(shopId)
    .collection('catalog_types')
    .get();

  return snapshot.docs.map((doc) => ({
    slug: doc.id,
    label: String(doc.data()?.label || doc.id).trim(),
    sortOrder: parseNumber(doc.data()?.sortOrder),
  }));
}

async function loadShopCatalogHeadings(shopId) {
  const snapshot = await db
    .collection('public_shops')
    .doc(shopId)
    .collection('catalog_headings')
    .get();

  return snapshot.docs.map((doc) => ({
    slug: doc.id,
    label: String(doc.data()?.label || doc.id).trim(),
    sortOrder: parseNumber(doc.data()?.sortOrder),
    catalogTypeSlug: String(doc.data()?.catalogTypeSlug || '').trim(),
  }));
}

async function resolveCatalogTypeSortOrder(shopId, slug) {
  const ref = db
    .collection('public_shops')
    .doc(shopId)
    .collection('catalog_types')
    .doc(slug);
  const existing = await ref.get();
  if (existing.exists) {
    return parseNumber(existing.data()?.sortOrder) || 0;
  }

  const snapshot = await db
    .collection('public_shops')
    .doc(shopId)
    .collection('catalog_types')
    .get();
  let maxSort = 0;
  snapshot.docs.forEach((doc) => {
    maxSort = Math.max(maxSort, parseNumber(doc.data()?.sortOrder));
  });
  return maxSort + 10;
}

async function upsertShopCatalogType({
  shopId,
  slug,
  label,
}) {
  const ref = db
    .collection('public_shops')
    .doc(shopId)
    .collection('catalog_types')
    .doc(slug);
  const existing = await ref.get();

  if (existing.exists) {
    await ref.set({
      label,
      usageCount: FieldValue.increment(1),
      updatedAt: FieldValue.serverTimestamp(),
      source: 'ai',
    }, { merge: true });
    return parseNumber(existing.data()?.sortOrder) || 0;
  }

  const sortOrder = await resolveCatalogTypeSortOrder(shopId, slug);
  await ref.set({
    label,
    sortOrder,
    source: 'ai',
    usageCount: 1,
    createdAt: FieldValue.serverTimestamp(),
    updatedAt: FieldValue.serverTimestamp(),
  }, { merge: true });
  return sortOrder;
}

async function resolveCatalogHeadingSortOrder(shopId, slug) {
  const ref = db
    .collection('public_shops')
    .doc(shopId)
    .collection('catalog_headings')
    .doc(slug);
  const existing = await ref.get();
  if (existing.exists) {
    return parseNumber(existing.data()?.sortOrder) || 0;
  }

  const snapshot = await db
    .collection('public_shops')
    .doc(shopId)
    .collection('catalog_headings')
    .get();
  let maxSort = 0;
  snapshot.docs.forEach((doc) => {
    maxSort = Math.max(maxSort, parseNumber(doc.data()?.sortOrder));
  });
  return maxSort + 10;
}

async function upsertShopCatalogHeading({
  shopId,
  slug,
  label,
  catalogTypeSlug,
  reuseExisting,
}) {
  const ref = db
    .collection('public_shops')
    .doc(shopId)
    .collection('catalog_headings')
    .doc(slug);
  const existing = await ref.get();
  const normalizedTypeSlug = String(catalogTypeSlug || '').trim();

  if (existing.exists) {
    await ref.set({
      label,
      catalogTypeSlug: normalizedTypeSlug || existing.data()?.catalogTypeSlug || null,
      usageCount: FieldValue.increment(1),
      updatedAt: FieldValue.serverTimestamp(),
      source: 'ai',
    }, { merge: true });
    return parseNumber(existing.data()?.sortOrder) || 0;
  }

  const sortOrder = await resolveCatalogHeadingSortOrder(shopId, slug);
  await ref.set({
    label,
    catalogTypeSlug: normalizedTypeSlug || null,
    sortOrder,
    source: 'ai',
    usageCount: 1,
    createdAt: FieldValue.serverTimestamp(),
    updatedAt: FieldValue.serverTimestamp(),
  }, { merge: true });
  return sortOrder;
}

async function classifyProductCatalogHeading({
  product,
  shopId,
  productId,
  apiKey,
  serviceType = '',
}) {
  const existingHeadings = await loadShopCatalogHeadings(shopId);
  const existingTypes = await loadShopCatalogTypes(shopId);
  const normalizedService = catalogTaxonomy.normalizeShopServiceType(serviceType);
  const allowedTypes = normalizedService === 'ร้านขายยา'
    ? [catalogTaxonomy.pharmacyTypeLabel()]
    : catalogTaxonomy.marketTypeLabels();
  const allowedTypeSummary = allowedTypes.join(', ');
  const existingTypeSummary = existingTypes.length > 0
    ? existingTypes.map((entry) => `${entry.slug}:${entry.label}`).join(', ')
    : '(none yet)';
  const existingHeadingSummary = existingHeadings.length > 0
    ? existingHeadings
      .map((entry) => `${entry.catalogTypeSlug || 'unknown-type'}:${entry.slug}:${entry.label}`)
      .join(', ')
    : '(none yet)';

  const firstImageUrl = readFirstProductImageUrl(product);
  const imageInlineData = firstImageUrl ? await fetchImageAsInlineData(firstImageUrl) : null;

  const prompt = [
    'You classify one active Thai merchant product into a customer-facing catalog type (ประเภท) and heading (หัวข้อ) for a Thai shopping app.',
    'Return JSON only.',
    'Do NOT use the raw product name as catalogType. catalogType is a broad shelf button. catalogHeading is the narrower group inside that type.',
    `Shop service type: ${normalizedService || 'unknown'}.`,
    `You MUST choose catalogType from this allowed list only: ${allowedTypeSummary}.`,
    'If nothing fits well, choose อื่นๆ and set both confidences below 80.',
    'Important Thai market taxonomy rules:',
    '- ผลไม้ is for fruit such as mango, dragon fruit, orange, banana, durian, apple.',
    '- ผักสด is for fresh vegetables and herbs.',
    '- เนื้อสัตว์ is for raw pork, chicken, beef, duck, and similar meat items.',
    '- อาหารทะเลสด is for fresh fish, shrimp, crab, squid, shellfish, and similar fresh seafood.',
    '- อาหารทะเลแปรรูป is for dried/processed seafood such as ปลาหมึกแห้ง, กุ้งแห้ง, ปลาแห้ง, ปลาแดดเดียว.',
    '- ยาและเวชภัณฑ์ is only for pharmacy/medical items when shop service type is ร้านขายยา.',
    'Prefer reusing an existing heading label/slug when the product clearly fits.',
    'Return confidence as integer 0-100 for both catalogType and catalogHeading.',
    'JSON schema only:',
    '{"catalogType":"allowed Thai broad type label","catalogTypeSlug":"stable type slug","catalogHeading":"Thai heading label","catalogHeadingSlug":"stable heading slug","catalogTypeConfidence":0-100,"catalogHeadingConfidence":0-100,"reuseExistingType":true/false,"reuseExistingHeading":true/false}',
    `Existing types: ${existingTypeSummary}.`,
    `Existing headings by type: ${existingHeadingSummary}.`,
    `Product name: ${String(product.name || '-').trim()}.`,
    `Description: ${String(product.description || '-').trim()}.`,
    `Raw AI product type (reference only, may be too narrow): ${String(product.aiProductType || product.productType || '-').trim()}.`,
  ].join(' ');

  const { analysis, model } = await runGeminiJsonPrompt({
    apiKey,
    prompt,
    imageInlineData,
    logContext: { productId, shopId, trigger: 'onProductCatalogClassify' },
  });

  let catalogType =
    String(analysis.catalogType || '').trim() ||
    resolveCatalogTypeFromProduct(product);
  if (!catalogTaxonomy.isKnownCatalogType(normalizedService, catalogType)) {
    catalogType = normalizedService === 'ร้านขายยา'
      ? catalogTaxonomy.pharmacyTypeLabel()
      : 'อื่นๆ';
  }
  if (!catalogType) {
    throw new Error('Gemini returned empty catalogType');
  }
  let catalogHeading = String(analysis.catalogHeading || '').trim();
  if (!catalogHeading || !catalogTaxonomy.isKnownCatalogHeading(normalizedService, catalogType, catalogHeading)) {
    catalogHeading = catalogTaxonomy.defaultHeadingForType(normalizedService, catalogType);
  }

  let catalogTypeSlug = normalizeCatalogHeadingSlug(
    analysis.catalogTypeSlug,
    catalogType,
  );
  if (analysis.reuseExistingType === true) {
    const matchedType = existingTypes.find(
      (entry) => entry.slug === catalogTypeSlug || entry.label === catalogType,
    );
    if (matchedType) {
      catalogTypeSlug = matchedType.slug;
    }
  }

  let catalogHeadingSlug = normalizeCatalogHeadingSlug(
    analysis.catalogHeadingSlug,
    catalogHeading,
  );

  if (analysis.reuseExistingHeading === true) {
    const matchedHeading = existingHeadings.find(
      (entry) => entry.slug === catalogHeadingSlug || entry.label === catalogHeading,
    );
    if (matchedHeading) {
      catalogHeadingSlug = matchedHeading.slug;
    }
  }

  return {
    catalogType,
    catalogTypeSlug,
    catalogHeading,
    catalogHeadingSlug,
    catalogTypeConfidence: catalogTaxonomy.normalizeConfidence(analysis.catalogTypeConfidence, 0),
    catalogHeadingConfidence: catalogTaxonomy.normalizeConfidence(analysis.catalogHeadingConfidence, 0),
    model,
  };
}

exports.onProductCatalogClassify = onDocumentWritten(
  {
    document: 'products/{productId}',
    region: DEFAULT_REGION,
    secrets: [GEMINI_API_KEY],
    timeoutSeconds: 90,
    memory: '512MiB',
  },
  async (event) => {
    const productId = event.params.productId;
    const before = event.data?.before?.exists ? event.data.before.data() : null;
    const after = event.data?.after?.exists ? event.data.after.data() : null;
    const skipReason = shouldSkipProductCatalogClassify({ before, after, productId });

    if (skipReason) {
      logger.info('onProductCatalogClassify skipped', { productId, skipReason });
      return null;
    }

    const shopId = String(after.ownerUid || after.ownerId || '').trim();
    if (!shopId) {
      logger.warn('onProductCatalogClassify missing ownerUid', { productId });
      return null;
    }

    const apiKey = String(GEMINI_API_KEY.value() || '').trim();
    if (!apiKey) {
      logger.error('onProductCatalogClassify missing GEMINI_API_KEY', { productId });
      return null;
    }

    let queueLease = null;
    let queueFinalStatus = 'completed';

    try {
      const inputHash = computeAiCatalogInputHash(after);
      const cachedBeforeAi = await loadCatalogAiCache(inputHash);
      const priorBeforeAi = cachedBeforeAi ? null : await findPriorClassifiedProduct(inputHash);
      const needsAi = !cachedBeforeAi && !priorBeforeAi;

      if (needsAi) {
        try {
          queueLease = await acquireAiProcessingSlot({
            uid: shopId,
            requestId: `catalog-${productId}`,
          });
        } catch (queueError) {
          logger.warn('onProductCatalogClassify queue rejected', {
            productId,
            message: queueError instanceof Error ? queueError.message : String(queueError),
          });
          return null;
        }
      }

      const classification = await resolveProductCatalogClassification({
        product: after,
        shopId,
        productId,
        apiKey,
      });

      const reviewEval = catalogTaxonomy.evaluateCatalogReviewRequired({
        serviceType: classification.serviceType || '',
        catalogType: classification.catalogType,
        catalogHeading: classification.catalogHeading,
        catalogTypeConfidence: classification.catalogTypeConfidence,
        catalogHeadingConfidence: classification.catalogHeadingConfidence,
        product: after,
        fromRule: classification.fromCache === 'keyword_rule',
      });

      const catalogUpdate = {
        catalogType: classification.catalogType,
        catalogTypeSlug: classification.catalogTypeSlug,
        catalogTypeSort: classification.catalogTypeSort,
        catalogHeading: classification.catalogHeading,
        catalogHeadingSlug: classification.catalogHeadingSlug,
        catalogHeadingSort: classification.catalogHeadingSort,
        catalogTypeConfidence: classification.catalogTypeConfidence,
        catalogHeadingConfidence: classification.catalogHeadingConfidence,
        catalogReviewStatus: reviewEval.required ? 'pending' : 'approved',
        catalogReviewReasons: reviewEval.reasons,
        catalogReviewReasonLabels: reviewEval.reasonLabels,
        aiCatalogInputHash: classification.aiCatalogInputHash,
        aiCatalogClassifierVersion: classification.aiCatalogClassifierVersion,
        aiCatalogClassifiedAt: FieldValue.serverTimestamp(),
      };

      if (!reviewEval.required) {
        catalogUpdate.catalogAdminLocked = false;
      }

      await db.collection('products').doc(productId).set(catalogUpdate, { merge: true });

      logger.info('onProductCatalogClassify completed', {
        productId,
        shopId,
        catalogType: classification.catalogType,
        catalogTypeSlug: classification.catalogTypeSlug,
        catalogHeading: classification.catalogHeading,
        catalogHeadingSlug: classification.catalogHeadingSlug,
        catalogReviewStatus: reviewEval.required ? 'pending' : 'approved',
        model: classification.model,
        fromCache: classification.fromCache,
      });
      return null;
    } catch (error) {
      queueFinalStatus = 'failed';
      logger.error('onProductCatalogClassify failed', {
        productId,
        shopId,
        message: error instanceof Error ? error.message : String(error),
      });
      return null;
    } finally {
      if (queueLease) {
        await releaseAiProcessingSlot(queueLease, queueFinalStatus);
      }
    }
  },
);

exports.analyzeProductWithAi = onCall(
  {
    region: DEFAULT_REGION,
    secrets: [GEMINI_API_KEY],
    timeoutSeconds: 90,
    memory: '512MiB',
  },
  async (request) => {
    if (!request.auth?.uid) {
      throw new HttpsError('unauthenticated', 'กรุณาเข้าสู่ระบบก่อนใช้งาน AI');
    }

    const imageBase64 = String(request.data?.imageBase64 || '').trim();
    const inputMimeType = String(request.data?.mimeType || '').trim().toLowerCase();
    const allowedMimeTypes = new Set(['image/jpeg', 'image/jpg', 'image/png', 'image/webp']);
    if (!imageBase64) {
      throw new HttpsError('invalid-argument', 'ไม่พบรูปภาพสินค้าที่ต้องการวิเคราะห์');
    }

    const normalizedMimeType = inputMimeType === 'image/jpg' ? 'image/jpeg' : inputMimeType;
    const mimeType = allowedMimeTypes.has(normalizedMimeType)
      ? normalizedMimeType
      : 'image/jpeg';
    const estimatedBytes = Math.floor((imageBase64.length * 3) / 4);
    if (estimatedBytes > 5 * 1024 * 1024) {
      throw new HttpsError('invalid-argument', 'รูปมีขนาดใหญ่เกินไป (สูงสุด 5MB)');
    }

    const apiKey = String(GEMINI_API_KEY.value() || '').trim();
    if (!apiKey) {
      throw new HttpsError('failed-precondition', 'ยังไม่ได้ตั้งค่า GEMINI_API_KEY');
    }

    const productName = String(request.data?.productName || '').trim();
    const description = String(request.data?.description || '').trim();
    const category = String(request.data?.category || '').trim();
    const unit = String(request.data?.unit || '').trim();
    const price = String(request.data?.price || '').trim();
    const weight = String(request.data?.weight || '').trim();
    const weightUnit = String(request.data?.weightUnit || '').trim();
    const analysisInputHash = computeProductAiAnalysisHash({
      productName,
      description,
      category,
      unit,
      price,
      weight,
      weightUnit,
      imageBase64,
    });
    const cachedAnalysis = await loadProductAiCache(analysisInputHash);
    if (cachedAnalysis) {
      await db.collection(PRODUCT_AI_CACHE_COLLECTION).doc(analysisInputHash).set({
        usageCount: FieldValue.increment(1),
        updatedAt: FieldValue.serverTimestamp(),
      }, { merge: true });
      return buildProductAiCallableResult(cachedAnalysis, {
        model: String(cachedAnalysis.model || 'cache').trim(),
        queuePosition: 0,
        estimatedWaitSeconds: 0,
        fromCache: true,
      });
    }

    const queueLease = await acquireAiProcessingSlot({
      uid: request.auth.uid,
      requestId: request.data?.requestId,
    });
    let queueFinalStatus = 'completed';

    try {
      const apiVersions = ['v1beta', 'v1'];
      const preferredModels = [
        'gemini-2.5-flash',
        'gemini-2.0-flash',
        'gemini-1.5-flash',
      ];

      const parseAnalysisFromParts = (partsForAnalysis) => {
        const textOutput = Array.isArray(partsForAnalysis)
          ? partsForAnalysis.map((part) => String(part?.text || '').trim()).filter(Boolean).join('\n')
          : '';
        if (!textOutput) return {};
        try {
          const jsonMatch = textOutput.match(/\{[\s\S]*\}/);
          if (jsonMatch) return JSON.parse(jsonMatch[0]);
        } catch (parseError) {
          logger.warn('analyzeProductWithAi JSON parse failed', {
            uid: request.auth.uid,
            message: parseError instanceof Error ? parseError.message : String(parseError),
            text: textOutput.slice(0, 800),
          });
        }
        return {};
      };

      const prompt = [
        'You are analyzing one product listing for a Thai merchant app. Return JSON only.',
        'Analyze the image and merchant-entered fields. Do not generate or edit any image.',
        'If the product name is missing or unclear from merchant fields, infer the most likely Thai product name from the image and return it as productName. Leave productName empty only if the product cannot be identified.',
        'Write description in Thai at about 2 natural mobile-app lines, useful for selling online. Avoid being too short.',
        'Main task 1: decide whether this product is legal to sell in Thailand for normal online commerce. Consider obvious prohibited or controlled goods such as illegal drugs, weapons, counterfeit goods, gambling items, protected wildlife, hazardous materials, prescription-only medicines, and other regulated goods. If uncertain, mark isLegalInThailand false and explain that manual review is required.',
        'Main task 2: identify what product type it is in Thai, such as fresh vegetable, fruit, prepared food, beverage, medicine/pharmacy item, cosmetic, electronics, clothing, household item, agricultural product, or general goods.',
        'Also fill existing merchant fields when possible.',
        'VAT rule: fresh unprocessed foods such as fresh vegetables, fruit, raw meat, raw seafood are exempt; processed, cooked, packaged, ready-to-eat, drinks, medicines/pharmacy items, and general goods are taxable.',
        'Nationwide shipping rule: dry, sealed, shelf-stable, non-fragile, legal products are usually suitable; fresh, frozen/chilled, leaking, very fragile, live, hazardous, prescription-controlled, or location-sensitive goods are usually not suitable.',
        'Parcel dimensions task: estimate outer package size in centimeters after typical merchant packing for nationwide courier shipping. Use realistic retail parcel sizes for the visible product and known weight when available. Return parcelLengthCm, parcelWidthCm, parcelHeightCm as positive numbers only. Length is usually the longest side.',
        'Sale unit task: choose the best Thai selling unit for this product in specifications. Prefer one of ชิ้น ถุง แพ็ค มัด ลูก กล่อง. Use ถุง for bagged produce, มัด for bundled vegetables/herbs, ลูก for whole fruit, แพ็ค for multi-pack, กล่อง for boxed goods.',
        'For every major judgment, also return confidence as an integer 0-100 where 100 means very certain.',
        'JSON schema only:',
        '{"productName":"likely Thai product name","productNameConfidence":0-100,"description":"Thai product description about 2 mobile lines","isLegalInThailand":true/false,"legalReason":"short Thai reason","legalConfidence":0-100,"productType":"specific Thai product type","productCategory":"ของสด or อาหารแปรรูป or สินค้าทั่วไป or ร้านขายยาและเวชภัณฑ์ or สินค้าเกษตร","productTypeConfidence":0-100,"taxStatus":"taxable or exempt","taxStatusLabel":"สินค้านี้เสียภาษี or สินค้านี้ยกเว้นภาษี","taxReason":"short Thai reason","taxConfidence":0-100,"isFreshProduct":true/false,"isProcessed":true/false,"canShipNationwide":true/false,"nationwideShippingReason":"short Thai reason","nationwideShippingConfidence":0-100,"parcelLengthCm":number,"parcelWidthCm":number,"parcelHeightCm":number,"parcelDimensionReason":"short Thai reason for estimated parcel size","parcelDimensionConfidence":0-100,"saleUnit":"ชิ้น or ถุง or แพ็ค or มัด or ลูก or กล่อง"}',
        `Known merchant-entered fields: productName=${productName || '-'}, description=${description || '-'}, category=${category || '-'}, unit=${unit || '-'}, price=${price || '-'}, weight=${weight || '-'}, weightUnit=${weightUnit || '-'}.`,
      ].join(' ');

      const discoveredModelNames = new Set();
      for (const apiVersion of apiVersions) {
        try {
          const listResp = await fetch(
            `https://generativelanguage.googleapis.com/${apiVersion}/models?key=${encodeURIComponent(apiKey)}`,
          );
          if (!listResp.ok) continue;
          const listPayload = await listResp.json();
          const models = Array.isArray(listPayload?.models) ? listPayload.models : [];
          for (const model of models) {
            const name = String(model?.name || '').trim();
            const shortName = name.startsWith('models/') ? name.slice('models/'.length) : name;
            const methods = Array.isArray(model?.supportedGenerationMethods)
              ? model.supportedGenerationMethods.map((value) => String(value || '').trim())
              : [];
            if (shortName && methods.includes('generateContent') && !/image|imagen/i.test(shortName)) {
              discoveredModelNames.add(shortName);
            }
          }
        } catch (listError) {
          logger.warn('analyzeProductWithAi listModels network error', {
            uid: request.auth.uid,
            apiVersion,
            message: listError instanceof Error ? listError.message : String(listError),
          });
        }
      }

      const modelCandidates = [...new Set([...preferredModels, ...discoveredModelNames])];
      let analysis = {};
      let selectedModel = null;
      let selectedApiVersion = null;
      let lastErrorStatus = null;
      let lastErrorBody = '';

      for (const modelName of modelCandidates) {
        for (const apiVersion of apiVersions) {
          const endpoint = `https://generativelanguage.googleapis.com/${apiVersion}/models/${modelName}:generateContent`;
          let response;
          try {
            response = await fetch(`${endpoint}?key=${encodeURIComponent(apiKey)}`, {
              method: 'POST',
              headers: { 'Content-Type': 'application/json' },
              body: JSON.stringify({
                contents: [
                  {
                    role: 'user',
                    parts: [
                      { text: prompt },
                      { inlineData: { mimeType, data: imageBase64 } },
                    ],
                  },
                ],
                generationConfig: {
                  temperature: 0.1,
                  responseMimeType: 'application/json',
                },
              }),
            });
          } catch (error) {
            logger.error('analyzeProductWithAi network error', {
              uid: request.auth.uid,
              model: modelName,
              apiVersion,
              message: error instanceof Error ? error.message : String(error),
            });
            throw new HttpsError('unavailable', 'ไม่สามารถเชื่อมต่อบริการ AI ได้ในขณะนี้');
          }

          if (!response.ok) {
            const errorBody = await response.text();
            const loweredErrorBody = errorBody.toLowerCase();
            logger.error('analyzeProductWithAi upstream error', {
              uid: request.auth.uid,
              model: modelName,
              apiVersion,
              status: response.status,
              body: errorBody.slice(0, 1000),
            });

            if (loweredErrorBody.includes('api_key_invalid') || loweredErrorBody.includes('api key not valid')) {
              throw new HttpsError('failed-precondition', 'GEMINI_API_KEY ไม่ถูกต้องหรือถูกจำกัดสิทธิ์ กรุณาตั้งค่า key ใหม่ใน Secret Manager');
            }
            if (loweredErrorBody.includes('permission_denied')) {
              throw new HttpsError('permission-denied', 'บัญชีหรือ API key ยังไม่ได้เปิดสิทธิ์ใช้งาน Generative Language API');
            }
            if (
              loweredErrorBody.includes('resource_exhausted') ||
              loweredErrorBody.includes('prepayment credits are depleted') ||
              loweredErrorBody.includes('credits are depleted') ||
              loweredErrorBody.includes('quota')
            ) {
              throw new HttpsError('resource-exhausted', 'เครดิต Gemini API หมด กรุณาเติมเครดิตหรือเปิด Billing ใน AI Studio แล้วลองใหม่อีกครั้ง');
            }

            lastErrorStatus = response.status;
            lastErrorBody = errorBody;
            const canTryNextModel =
              loweredErrorBody.includes('not found') ||
              loweredErrorBody.includes('unsupported') ||
              loweredErrorBody.includes('method not found') ||
              loweredErrorBody.includes('model') ||
              loweredErrorBody.includes('invalid json payload') ||
              loweredErrorBody.includes('unknown name') ||
              loweredErrorBody.includes('cannot find field') ||
              loweredErrorBody.includes('responsemimetype');
            if (canTryNextModel) continue;
            throw new HttpsError('internal', 'บริการ AI ตอบกลับผิดพลาด');
          }

          const payload = await response.json();
          const parts = payload?.candidates?.[0]?.content?.parts;
          analysis = parseAnalysisFromParts(parts);
          if (Object.keys(analysis).length > 0) {
            selectedModel = modelName;
            selectedApiVersion = apiVersion;
            break;
          }

          lastErrorStatus = 200;
          lastErrorBody = JSON.stringify(payload).slice(0, 1000);
        }
        if (selectedModel) break;
      }

      if (!selectedModel) {
        logger.error('analyzeProductWithAi no available model', {
          uid: request.auth.uid,
          lastErrorStatus,
          lastErrorBody: String(lastErrorBody || '').slice(0, 1000),
          discoveredModels: [...discoveredModelNames].slice(0, 20),
        });
        throw new HttpsError('unimplemented', 'โมเดล AI สำหรับวิเคราะห์สินค้ายังไม่พร้อมใช้งานในโปรเจกต์นี้');
      }

      let resultModel = `${selectedModel}@${selectedApiVersion || 'unknown'}`;
      if (!isGeminiProModel(selectedModel) && shouldEscalateAiAnalysisToPro(analysis)) {
        const escalated = await runGeminiProductAnalysis({
          uid: request.auth.uid,
          apiKey,
          imageBase64,
          mimeType,
          productName,
          description,
          category,
          unit,
          price,
          weight,
          weightUnit,
        });
        if (String(escalated.model || '').includes('escalatedFrom=')) {
          analysis = escalated.analysis;
          resultModel = escalated.model;
        }
      }

      const result = buildProductAiCallableResult(analysis, {
        model: resultModel,
        queuePosition: queueLease.position,
        estimatedWaitSeconds: queueLease.estimatedWaitSeconds,
      });
      await saveProductAiCache(
        analysisInputHash,
        result,
        result.model,
      );
      return result;
    } catch (error) {
      queueFinalStatus = 'failed';
      throw error;
    } finally {
      await releaseAiProcessingSlot(queueLease, queueFinalStatus);
    }
  },
);

function buildProductAiGeminiPrompt({
  productName,
  description,
  category,
  unit,
  price,
  weight,
  weightUnit,
}) {
  return [
    'You are analyzing one product listing for a Thai merchant app. Return JSON only.',
    'Analyze the image and merchant-entered fields. Do not generate or edit any image.',
    'If the product name is missing or unclear from merchant fields, infer the most likely Thai product name from the image and return it as productName. Leave productName empty only if the product cannot be identified.',
    'Write description in Thai at about 2 natural mobile-app lines, useful for selling online. Avoid being too short.',
    'Main task 1: decide whether this product is legal to sell in Thailand for normal online commerce. Consider obvious prohibited or controlled goods such as illegal drugs, weapons, counterfeit goods, gambling items, protected wildlife, hazardous materials, prescription-only medicines, and other regulated goods. If uncertain, mark isLegalInThailand false and explain that manual review is required.',
    'Main task 2: identify what product type it is in Thai, such as fresh vegetable, fruit, prepared food, beverage, medicine/pharmacy item, cosmetic, electronics, clothing, household item, agricultural product, or general goods.',
    'Also fill existing merchant fields when possible.',
    'VAT rule: fresh unprocessed foods such as fresh vegetables, fruit, raw meat, raw seafood are exempt; processed, cooked, packaged, ready-to-eat, drinks, medicines/pharmacy items, and general goods are taxable.',
    'Nationwide shipping rule: dry, sealed, shelf-stable, non-fragile, legal products are usually suitable; fresh, frozen/chilled, leaking, very fragile, live, hazardous, prescription-controlled, or location-sensitive goods are usually not suitable.',
    'Parcel dimensions task: estimate outer package size in centimeters after typical merchant packing for nationwide courier shipping. Use realistic retail parcel sizes for the visible product and known weight when available. Return parcelLengthCm, parcelWidthCm, parcelHeightCm as positive numbers only. Length is usually the longest side.',
    'Sale unit task: choose the best Thai selling unit for this product in specifications. Prefer one of ชิ้น ถุง แพ็ค มัด ลูก กล่อง. Use ถุง for bagged produce, มัด for bundled vegetables/herbs, ลูก for whole fruit, แพ็ค for multi-pack, กล่อง for boxed goods.',
    'For every major judgment, also return confidence as an integer 0-100 where 100 means very certain.',
    'JSON schema only:',
    '{"productName":"likely Thai product name","productNameConfidence":0-100,"description":"Thai product description about 2 mobile lines","isLegalInThailand":true/false,"legalReason":"short Thai reason","legalConfidence":0-100,"productType":"specific Thai product type","productCategory":"ของสด or อาหารแปรรูป or สินค้าทั่วไป or ร้านขายยาและเวชภัณฑ์ or สินค้าเกษตร","productTypeConfidence":0-100,"taxStatus":"taxable or exempt","taxStatusLabel":"สินค้านี้เสียภาษี or สินค้านี้ยกเว้นภาษี","taxReason":"short Thai reason","taxConfidence":0-100,"isFreshProduct":true/false,"isProcessed":true/false,"canShipNationwide":true/false,"nationwideShippingReason":"short Thai reason","nationwideShippingConfidence":0-100,"parcelLengthCm":number,"parcelWidthCm":number,"parcelHeightCm":number,"parcelDimensionReason":"short Thai reason for estimated parcel size","parcelDimensionConfidence":0-100,"saleUnit":"ชิ้น or ถุง or แพ็ค or มัด or ลูก or กล่อง"}',
    `Known merchant-entered fields: productName=${productName || '-'}, description=${description || '-'}, category=${category || '-'}, unit=${unit || '-'}, price=${price || '-'}, weight=${weight || '-'}, weightUnit=${weightUnit || '-'}.`,
  ].join(' ');
}

function parseProductAiAnalysisFromParts(partsForAnalysis) {
  const textOutput = Array.isArray(partsForAnalysis)
    ? partsForAnalysis.map((part) => String(part?.text || '').trim()).filter(Boolean).join('\n')
    : '';
  if (!textOutput) return {};
  try {
    const jsonMatch = textOutput.match(/\{[\s\S]*\}/);
    if (jsonMatch) return JSON.parse(jsonMatch[0]);
  } catch (parseError) {
    logger.warn('parseProductAiAnalysisFromParts JSON parse failed', {
      message: parseError instanceof Error ? parseError.message : String(parseError),
      text: textOutput.slice(0, 800),
    });
  }
  return {};
}

async function runGeminiProductAnalysis({
  uid,
  apiKey,
  imageBase64,
  mimeType,
  productName,
  description,
  category,
  unit,
  price,
  weight,
  weightUnit,
}) {
  const apiVersions = ['v1beta', 'v1'];
  const preferredModels = GEMINI_PREFERRED_MODELS;
  const prompt = buildProductAiGeminiPrompt({
    productName,
    description,
    category,
    unit,
    price,
    weight,
    weightUnit,
  });

  const discoveredModelNames = new Set();
  for (const apiVersion of apiVersions) {
    try {
      const listResp = await fetch(
        `https://generativelanguage.googleapis.com/${apiVersion}/models?key=${encodeURIComponent(apiKey)}`,
      );
      if (!listResp.ok) continue;
      const listPayload = await listResp.json();
      const models = Array.isArray(listPayload?.models) ? listPayload.models : [];
      for (const model of models) {
        const name = String(model?.name || '').trim();
        const shortName = name.startsWith('models/') ? name.slice('models/'.length) : name;
        const methods = Array.isArray(model?.supportedGenerationMethods)
          ? model.supportedGenerationMethods.map((value) => String(value || '').trim())
          : [];
        if (shortName && methods.includes('generateContent') && !/image|imagen/i.test(shortName)) {
          discoveredModelNames.add(shortName);
        }
      }
    } catch (listError) {
      logger.warn('runGeminiProductAnalysis listModels network error', {
        uid,
        apiVersion,
        message: listError instanceof Error ? listError.message : String(listError),
      });
    }
  }

  const { flashModels, proModels } = buildGeminiModelPasses(discoveredModelNames, preferredModels);
  let lastErrorStatus = null;
  let lastErrorBody = '';

  async function tryProductModelCandidates(modelCandidates) {
    let analysis = {};
    let selectedModel = null;
    let selectedApiVersion = null;
    for (const modelName of modelCandidates) {
      for (const apiVersion of apiVersions) {
      const endpoint = `https://generativelanguage.googleapis.com/${apiVersion}/models/${modelName}:generateContent`;
      let response;
      try {
        response = await fetch(`${endpoint}?key=${encodeURIComponent(apiKey)}`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({
            contents: [
              {
                role: 'user',
                parts: [
                  { text: prompt },
                  { inlineData: { mimeType, data: imageBase64 } },
                ],
              },
            ],
            generationConfig: {
              temperature: 0.1,
              responseMimeType: 'application/json',
            },
          }),
        });
      } catch (error) {
        logger.error('runGeminiProductAnalysis network error', {
          uid,
          model: modelName,
          apiVersion,
          message: error instanceof Error ? error.message : String(error),
        });
        throw new HttpsError('unavailable', 'ไม่สามารถเชื่อมต่อบริการ AI ได้ในขณะนี้');
      }

      if (!response.ok) {
        const errorBody = await response.text();
        const loweredErrorBody = errorBody.toLowerCase();
        logger.error('runGeminiProductAnalysis upstream error', {
          uid,
          model: modelName,
          apiVersion,
          status: response.status,
          body: errorBody.slice(0, 1000),
        });

        if (loweredErrorBody.includes('api_key_invalid') || loweredErrorBody.includes('api key not valid')) {
          throw new HttpsError('failed-precondition', 'GEMINI_API_KEY ไม่ถูกต้องหรือถูกจำกัดสิทธิ์ กรุณาตั้งค่า key ใหม่ใน Secret Manager');
        }
        if (loweredErrorBody.includes('permission_denied')) {
          throw new HttpsError('permission-denied', 'บัญชีหรือ API key ยังไม่ได้เปิดสิทธิ์ใช้งาน Generative Language API');
        }
        if (
          loweredErrorBody.includes('resource_exhausted') ||
          loweredErrorBody.includes('prepayment credits are depleted') ||
          loweredErrorBody.includes('credits are depleted') ||
          loweredErrorBody.includes('quota')
        ) {
          throw new HttpsError('resource-exhausted', 'เครดิต Gemini API หมด กรุณาเติมเครดิตหรือเปิด Billing ใน AI Studio แล้วลองใหม่อีกครั้ง');
        }

        lastErrorStatus = response.status;
        lastErrorBody = errorBody;
        const canTryNextModel =
          loweredErrorBody.includes('not found') ||
          loweredErrorBody.includes('unsupported') ||
          loweredErrorBody.includes('method not found') ||
          loweredErrorBody.includes('model') ||
          loweredErrorBody.includes('invalid json payload') ||
          loweredErrorBody.includes('unknown name') ||
          loweredErrorBody.includes('cannot find field') ||
          loweredErrorBody.includes('responsemimetype');
        if (canTryNextModel) continue;
        throw new HttpsError('internal', 'บริการ AI ตอบกลับผิดพลาด');
      }

      const payload = await response.json();
      const parts = payload?.candidates?.[0]?.content?.parts;
      analysis = parseProductAiAnalysisFromParts(parts);
      if (Object.keys(analysis).length > 0) {
        selectedModel = modelName;
        selectedApiVersion = apiVersion;
        break;
      }

      lastErrorStatus = 200;
      lastErrorBody = JSON.stringify(payload).slice(0, 1000);
    }
      if (selectedModel) break;
    }

    if (!selectedModel) {
      return null;
    }

    return {
      analysis,
      model: `${selectedModel}@${selectedApiVersion || 'unknown'}`,
    };
  }

  const flashResult = await tryProductModelCandidates(flashModels);
  if (flashResult) {
    if (!shouldEscalateAiAnalysisToPro(flashResult.analysis)) {
      return flashResult;
    }
    const proResult = await tryProductModelCandidates(proModels);
    if (proResult) {
      return {
        analysis: proResult.analysis,
        model: `${proResult.model} escalatedFrom=${flashResult.model}`,
      };
    }
    return flashResult;
  }

  {
    logger.error('runGeminiProductAnalysis no available model', {
      uid,
      lastErrorStatus,
      lastErrorBody: String(lastErrorBody || '').slice(0, 1000),
      discoveredModels: [...discoveredModelNames].slice(0, 20),
    });
    throw new HttpsError('unimplemented', 'โมเดล AI สำหรับวิเคราะห์สินค้ายังไม่พร้อมใช้งานในโปรเจกต์นี้');
  }
}

async function tryClaimFirstBulkAiReadyNotification(batchId) {
  const ref = db.collection('bulk_product_import_batches').doc(batchId);
  try {
    return await db.runTransaction(async (tx) => {
      const snap = await tx.get(ref);
      if (snap.exists && snap.get('firstReadyNotifiedAt')) {
        return false;
      }
      tx.set(ref, {
        firstReadyNotifiedAt: FieldValue.serverTimestamp(),
      }, { merge: true });
      return true;
    });
  } catch (error) {
    logger.warn('claim first bulk AI ready notification failed', {
      batchId,
      message: error instanceof Error ? error.message : String(error),
    });
    return false;
  }
}

async function notifyProductAiReady({ uid, draftId, jobId, productName, batchId }) {
  const notificationId = `product_ai_${jobId}`;
  const title = 'AI วิเคราะห์เสร็จแล้ว';
  const body = productName
    ? `พร้อมเติมข้อมูล: ${productName}`
    : 'พร้อมเติมข้อมูล';

  await db.collection('app_notifications').doc(notificationId).set({
    targetApp: 'van1',
    recipientUid: uid,
    title,
    body,
    read: false,
    createdAt: FieldValue.serverTimestamp(),
    action: 'product_ai_ready',
    draftId,
    jobId,
    ...(batchId ? { batchId } : {}),
    source: 'van1_product_ai',
    type: 'app_notification',
  }, { merge: true });

  const fcmToken = await resolveAnyRecipientFcmToken(uid);
  if (!fcmToken) {
    return;
  }

  try {
    await admin.messaging().send({
      notification: { title, body },
      data: {
        type: 'product_ai_ready',
        action: 'product_ai_ready',
        notificationId: String(notificationId),
        draftId: String(draftId || ''),
        jobId: String(jobId || ''),
        ...(batchId ? { batchId: String(batchId) } : {}),
        click_action: 'FLUTTER_NOTIFICATION_CLICK',
      },
      token: fcmToken,
    });
  } catch (error) {
    logger.warn('notifyProductAiReady FCM failed', {
      uid,
      draftId,
      jobId,
      message: error instanceof Error ? error.message : String(error),
    });
  }
}

async function processProductAiJob(jobId, jobData, apiKey) {
  const uid = String(jobData?.uid || '').trim();
  const draftId = String(jobData?.draftId || '').trim();
  const imageUrl = String(jobData?.imageUrl || '').trim();
  const jobType = String(jobData?.jobType || 'interactive').trim();
  if (!uid || !draftId || !imageUrl) {
    throw new Error('product_ai_jobs missing uid/draftId/imageUrl');
  }

  const productName = String(jobData?.productName || '').trim();
  const description = String(jobData?.description || '').trim();
  const category = String(jobData?.category || '').trim();
  const unit = String(jobData?.unit || '').trim();
  const price = String(jobData?.price || '').trim();
  const weight = String(jobData?.weight || '').trim();
  const weightUnit = String(jobData?.weightUnit || '').trim();

  const draftRef = db.collection('product_drafts').doc(uid).collection('items').doc(draftId);
  await draftRef.set({
    aiStatus: 'processing',
    aiRequestId: jobId,
    aiStartedAt: FieldValue.serverTimestamp(),
    updatedAt: FieldValue.serverTimestamp(),
  }, { merge: true });

  const inlineImage = await fetchImageAsInlineData(imageUrl);
  if (!inlineImage?.data) {
    throw new HttpsError('invalid-argument', 'ไม่สามารถโหลดรูปจาก Storage สำหรับ AI ได้');
  }

  const analysisInputHash = computeProductAiAnalysisHash({
    productName,
    description,
    category,
    unit,
    price,
    weight,
    weightUnit,
    imageUrl,
  });

  const cachedAnalysis = await loadProductAiCache(analysisInputHash);
  let result;
  if (cachedAnalysis) {
    await db.collection(PRODUCT_AI_CACHE_COLLECTION).doc(analysisInputHash).set({
      usageCount: FieldValue.increment(1),
      updatedAt: FieldValue.serverTimestamp(),
    }, { merge: true });
    result = buildProductAiCallableResult(cachedAnalysis, {
      model: String(cachedAnalysis.model || 'cache').trim(),
      queuePosition: 0,
      estimatedWaitSeconds: 0,
      fromCache: true,
    });
  } else {
    const gemini = await runGeminiProductAnalysis({
      uid,
      apiKey,
      imageBase64: inlineImage.data,
      mimeType: inlineImage.mimeType,
      productName,
      description,
      category,
      unit,
      price,
      weight,
      weightUnit,
    });
    result = buildProductAiCallableResult(gemini.analysis, {
      model: gemini.model,
      queuePosition: 1,
      estimatedWaitSeconds: 0,
    });
    await saveProductAiCache(analysisInputHash, result, result.model);
  }

  await draftRef.set({
    aiStatus: 'completed',
    aiRequestId: jobId,
    aiResult: result,
    imageUrl,
    thumbnailUrl: String(jobData?.thumbnailUrl || '').trim() || null,
    reviewStatus: result.requiresAdminReview ? 'required' : 'ready',
    aiCompletedAt: FieldValue.serverTimestamp(),
    updatedAt: FieldValue.serverTimestamp(),
  }, { merge: true });

  await db.collection('product_ai_jobs').doc(jobId).set({
    status: 'completed',
    aiResult: result,
    leaseOwner: null,
    leasedUntil: null,
    leaseExpiresAtMillis: null,
    completedAt: FieldValue.serverTimestamp(),
    updatedAt: FieldValue.serverTimestamp(),
  }, { merge: true });

  const batchId = String(jobData?.batchId || '').trim();
  if (batchId) {
    await db.collection('bulk_product_import_batches').doc(batchId).set({
      completedCount: FieldValue.increment(1),
      reviewRequiredCount: FieldValue.increment(result.requiresAdminReview ? 1 : 0),
      updatedAt: FieldValue.serverTimestamp(),
    }, { merge: true });
  }

  const shouldNotify = !batchId || await tryClaimFirstBulkAiReadyNotification(batchId);
  if (shouldNotify) {
    await notifyProductAiReady({
      uid,
      draftId,
      jobId,
      productName: result.productName || productName,
      batchId,
    });
  }

  return result;
}

async function markProductAiJobFailed(jobId, jobData, message) {
  const uid = String(jobData.uid || '').trim();
  const draftId = String(jobData.draftId || '').trim();
  const batchId = String(jobData.batchId || '').trim();
  await db.collection('product_ai_jobs').doc(jobId).set({
    status: 'failed',
    error: message.slice(0, 500),
    lastError: message.slice(0, 500),
    leaseOwner: null,
    leasedUntil: null,
    leaseExpiresAtMillis: null,
    attemptCount: FieldValue.increment(1),
    updatedAt: FieldValue.serverTimestamp(),
  }, { merge: true });

  if (uid && draftId) {
    await db.collection('product_drafts').doc(uid).collection('items').doc(draftId).set({
      aiStatus: 'failed',
      aiError: message.slice(0, 500),
      updatedAt: FieldValue.serverTimestamp(),
    }, { merge: true });
  }

  if (batchId) {
    await db.collection('bulk_product_import_batches').doc(batchId).set({
      failedCount: FieldValue.increment(1),
      updatedAt: FieldValue.serverTimestamp(),
    }, { merge: true });
  }
}

function productAiJobAnchorMillis(data, now = Date.now()) {
  const updatedAtMillis = data?.updatedAt && typeof data.updatedAt.toMillis === 'function'
    ? data.updatedAt.toMillis()
    : 0;
  const createdAtMillis = productAiJobCreatedAtMillis(data);
  return updatedAtMillis || createdAtMillis || now;
}

function isInteractiveProductAiJobStale(data, now = Date.now()) {
  const status = String(data?.status || '');
  if (status !== 'queued' && status !== 'processing') {
    return false;
  }
  if (status === 'processing') {
    const leasedUntil = Number(data.leasedUntil || data.leaseExpiresAtMillis || 0);
    if (leasedUntil > now) {
      return false;
    }
  }
  const anchor = productAiJobAnchorMillis(data, now);
  return (now - anchor) > PRODUCT_AI_INTERACTIVE_QUEUE_TTL_MS;
}

async function recoverStaleQueuedInteractiveJobs(now = Date.now()) {
  const snapshot = await db.collection('product_ai_jobs')
    .where('jobType', '==', 'interactive')
    .limit(50)
    .get();
  let recovered = 0;
  await Promise.all(snapshot.docs.map(async (doc) => {
    const data = doc.data() || {};
    if (!isInteractiveProductAiJobStale(data, now)) {
      return;
    }
    recovered += 1;
    await doc.ref.set({
      status: 'cancelled',
      leaseOwner: null,
      leasedUntil: null,
      leaseExpiresAtMillis: null,
      message: 'คิว interactive หมดอายุ',
      updatedAt: FieldValue.serverTimestamp(),
    }, { merge: true });
  }));
  return recovered;
}

async function hasInteractiveProductAiPending(now = Date.now()) {
  const snapshot = await db.collection('product_ai_jobs')
    .where('jobType', '==', 'interactive')
    .limit(40)
    .get();
  return snapshot.docs.some((doc) => {
    const data = doc.data() || {};
    const status = String(data.status || '');
    if (isInteractiveProductAiJobStale(data, now)) {
      return false;
    }
    if (status === 'queued') {
      return Number(data.nextRunAt || 0) <= now;
    }
    if (status === 'processing') {
      const leasedUntil = Number(data.leasedUntil || data.leaseExpiresAtMillis || 0);
      return leasedUntil > now;
    }
    return false;
  });
}

async function releaseDeferredBackgroundJobsIfInteractiveIdle(now = Date.now()) {
  const interactivePending = await hasInteractiveProductAiPending(now);
  if (interactivePending) {
    return 0;
  }
  const snapshot = await db.collection('product_ai_jobs')
    .where('jobType', '==', 'background')
    .limit(100)
    .get();
  let released = 0;
  await Promise.all(snapshot.docs.map(async (doc) => {
    const data = doc.data() || {};
    if (String(data.status || '') !== 'queued') return;
    const nextRunAt = Number(data.nextRunAt || 0);
    if (nextRunAt <= now) return;
    released += 1;
    await doc.ref.set({
      priority: PRODUCT_AI_PRIORITY_BULK,
      nextRunAt: now,
      message: 'พร้อมเข้าคิว AI bulk',
      updatedAt: FieldValue.serverTimestamp(),
    }, { merge: true });
  }));
  return released;
}

async function runBackgroundProductAiJobNow(jobId, jobData, apiKey, leaseOwner) {
  const jobRef = db.collection('product_ai_jobs').doc(jobId);
  const claimed = await claimQueuedProductAiJob({ ref: jobRef, id: jobId }, leaseOwner);
  if (!claimed) {
    return { status: 'queued' };
  }
  const outcome = await runClaimedProductAiJob(jobId, claimed, apiKey);
  return { status: outcome.ok ? 'completed' : 'failed' };
}

async function yieldBackgroundProcessingJobs(keepJobId = '') {
  const now = Date.now();
  const snapshot = await db.collection('product_ai_jobs')
    .where('status', '==', 'processing')
    .limit(50)
    .get();
  await Promise.all(snapshot.docs.map(async (doc) => {
    if (doc.id === keepJobId) return;
    const data = doc.data() || {};
    if (String(data.jobType || '') !== 'background') return;
    await doc.ref.set({
      status: 'queued',
      priority: PRODUCT_AI_PRIORITY_BULK - 10,
      nextRunAt: now + PRODUCT_AI_BACKGROUND_DEFER_MS,
      leaseOwner: null,
      leasedUntil: null,
      leaseExpiresAtMillis: null,
      message: 'รอให้วิเคราะห์สินค้าเดี่ยวเสร็จก่อน',
      updatedAt: FieldValue.serverTimestamp(),
    }, { merge: true });
  }));
}

async function deferQueuedBackgroundJobs(deferMs = PRODUCT_AI_BACKGROUND_DEFER_MS) {
  const now = Date.now();
  const snapshot = await db.collection('product_ai_jobs')
    .where('jobType', '==', 'background')
    .limit(100)
    .get();
  await Promise.all(snapshot.docs.map(async (doc) => {
    const data = doc.data() || {};
    if (String(data.status || '') !== 'queued') return;
    const existingNextRun = Number(data.nextRunAt || 0);
    await doc.ref.set({
      priority: PRODUCT_AI_PRIORITY_BULK - 10,
      nextRunAt: Math.max(existingNextRun, now + deferMs),
      message: 'รอให้วิเคราะห์สินค้าเดี่ยวเสร็จก่อน',
      updatedAt: FieldValue.serverTimestamp(),
    }, { merge: true });
  }));
}

async function recoverStaleProcessingProductAiJobs(keepJobId = '') {
  const now = Date.now();
  const snapshot = await db.collection('product_ai_jobs')
    .where('status', '==', 'processing')
    .limit(50)
    .get();
  await Promise.all(snapshot.docs.map(async (doc) => {
    if (doc.id === keepJobId) return;
    const data = doc.data() || {};
    const leasedUntil = Number(data.leasedUntil || data.leaseExpiresAtMillis || 0);
    const updatedAtMillis = data.updatedAt && typeof data.updatedAt.toMillis === 'function'
      ? data.updatedAt.toMillis()
      : 0;
    const leaseExpired = leasedUntil > 0 && leasedUntil <= now;
    const staleWithoutLease = leasedUntil <= 0 &&
      updatedAtMillis > 0 &&
      (now - updatedAtMillis) > 4 * 60 * 1000;
    if (!leaseExpired && !staleWithoutLease) return;
    const jobType = String(data.jobType || 'background');
    await doc.ref.set({
      status: 'queued',
      jobType,
      priority: jobType === 'interactive'
        ? PRODUCT_AI_PRIORITY_INTERACTIVE
        : PRODUCT_AI_PRIORITY_BULK - 10,
      nextRunAt: now,
      leaseOwner: null,
      leasedUntil: null,
      leaseExpiresAtMillis: null,
      message: 'กำลังเข้าคิว AI อีกครั้ง...',
      updatedAt: FieldValue.serverTimestamp(),
    }, { merge: true });
  }));
}

async function runInteractiveProductAiJobNow(jobId, jobPayload, apiKey, leaseOwner) {
  await yieldBackgroundProcessingJobs(jobId);

  const jobRef = db.collection('product_ai_jobs').doc(jobId);
  const claimed = await claimQueuedProductAiJob({ ref: jobRef, id: jobId }, leaseOwner);
  if (!claimed) {
    return { status: 'queued', aiResult: null, error: null };
  }
  const outcome = await runClaimedProductAiJob(jobId, claimed, apiKey);
  return {
    status: outcome.ok ? 'completed' : 'failed',
    aiResult: outcome.result || null,
    error: outcome.error || null,
  };
}

async function requeueProductAiJob(jobId, jobData, message) {
  const uid = String(jobData.uid || '').trim();
  const draftId = String(jobData.draftId || '').trim();
  const jobType = String(jobData.jobType || 'background');
  const priority = jobType === 'interactive'
    ? PRODUCT_AI_PRIORITY_INTERACTIVE
    : Number(jobData.priority || PRODUCT_AI_PRIORITY_BULK);
  await db.collection('product_ai_jobs').doc(jobId).set({
    status: 'queued',
    jobType,
    priority,
    nextRunAt: Date.now() + 15 * 1000,
    leaseExpiresAtMillis: null,
    leaseOwner: null,
    leasedUntil: null,
    attemptCount: FieldValue.increment(1),
    lastError: message.slice(0, 500),
    lastQueueMessage: message.slice(0, 500),
    updatedAt: FieldValue.serverTimestamp(),
  }, { merge: true });
  if (uid && draftId) {
    await db.collection('product_drafts').doc(uid).collection('items').doc(draftId).set({
      aiStatus: 'queued',
      aiQueueMessage: message.slice(0, 500),
      updatedAt: FieldValue.serverTimestamp(),
    }, { merge: true });
  }
}

exports.enqueueProductAiAnalysis = onCall(
  {
    region: DEFAULT_REGION,
    secrets: [GEMINI_API_KEY],
    timeoutSeconds: 300,
    memory: '512MiB',
  },
  async (request) => {
    if (!request.auth?.uid) {
      throw new HttpsError('unauthenticated', 'กรุณาเข้าสู่ระบบก่อนใช้งาน AI');
    }

    const imageUrl = String(request.data?.imageUrl || '').trim();
    const draftId = String(request.data?.draftId || '').trim();
    if (!imageUrl) {
      throw new HttpsError('invalid-argument', 'ไม่พบ URL รูปสินค้าที่อัปโหลดแล้ว');
    }
    if (!draftId) {
      throw new HttpsError('invalid-argument', 'ไม่พบ draftId');
    }

    const jobId = normalizeAiRequestId(request.data?.requestId);
    const uid = request.auth.uid;
    const jobRef = db.collection('product_ai_jobs').doc(jobId);
    const jobPayload = {
      uid,
      ownerUid: uid,
      draftId,
      imageUrl,
      thumbnailUrl: String(request.data?.thumbnailUrl || '').trim() || null,
      productName: String(request.data?.productName || '').trim(),
      description: String(request.data?.description || '').trim(),
      category: String(request.data?.category || '').trim(),
      unit: String(request.data?.unit || '').trim(),
      price: String(request.data?.price || '').trim(),
      weight: String(request.data?.weight || '').trim(),
      weightUnit: String(request.data?.weightUnit || '').trim(),
      jobType: 'interactive',
      priority: PRODUCT_AI_PRIORITY_INTERACTIVE,
      attemptCount: 0,
      nextRunAt: Date.now(),
      status: 'queued',
      queuePosition: 1,
      estimatedWaitSeconds: 0,
      message: 'กำลังรอคิว AI...',
      createdAt: FieldValue.serverTimestamp(),
      updatedAt: FieldValue.serverTimestamp(),
    };

    await jobRef.set(jobPayload, { merge: true });
    await db.collection('product_drafts').doc(uid).collection('items').doc(draftId).set({
      aiStatus: 'queued',
      aiRequestId: jobId,
      imageUrl,
      thumbnailUrl: String(request.data?.thumbnailUrl || '').trim() || null,
      aiQueuedAt: FieldValue.serverTimestamp(),
      queuePosition: 1,
      estimatedWaitSeconds: 0,
      updatedAt: FieldValue.serverTimestamp(),
    }, { merge: true });

    await Promise.all([
      recoverStaleProcessingProductAiJobs(jobId),
      supersedeOlderInteractiveJobs(uid, jobId),
    ]);

    const apiKey = String(GEMINI_API_KEY.value() || '').trim();
    if (!apiKey) {
      await markProductAiJobFailed(jobId, jobPayload, 'missing_gemini_api_key');
      throw new HttpsError('failed-precondition', 'ระบบ AI ยังไม่พร้อม กรุณาลองใหม่ภายหลัง');
    }

    const outcome = await runInteractiveProductAiJobNow(
      jobId,
      jobPayload,
      apiKey,
      'enqueueProductAiAnalysis',
    );
    return {
      jobId,
      status: outcome.status,
      aiResult: outcome.aiResult || null,
      error: outcome.error || null,
    };
  },
);

exports.enqueueBulkProductAiAnalysis = onCall(
  {
    region: DEFAULT_REGION,
    secrets: [GEMINI_API_KEY],
    timeoutSeconds: 120,
    memory: '512MiB',
  },
  async (request) => {
    if (!request.auth?.uid) {
      throw new HttpsError('unauthenticated', 'กรุณาเข้าสู่ระบบก่อนใช้งาน AI');
    }

    const uid = request.auth.uid;
    const rawItems = Array.isArray(request.data?.items) ? request.data.items : [];
    if (rawItems.length === 0) {
      throw new HttpsError('invalid-argument', 'ไม่พบรายการรูปสินค้าสำหรับ bulk AI');
    }
    const interactivePending = await hasInteractiveProductAiPending();
    const bulkDeferMs = interactivePending ? PRODUCT_AI_BACKGROUND_DEFER_MS : 0;
    if (rawItems.length > PRODUCT_AI_BULK_MAX_ITEMS) {
      throw new HttpsError('invalid-argument', `เพิ่มได้สูงสุด ${PRODUCT_AI_BULK_MAX_ITEMS} รูปต่อ batch`);
    }

    const batchId = normalizeAiRequestId(request.data?.batchId);
    const isRetry = request.data?.retry === true;
    const batchRef = db.collection('bulk_product_import_batches').doc(batchId);
    const now = FieldValue.serverTimestamp();
    const writer = db.bulkWriter();

    if (isRetry) {
      writer.set(batchRef, {
        status: 'queued',
        failedCount: FieldValue.increment(-rawItems.length),
        updatedAt: now,
      }, { merge: true });
    } else {
      writer.set(batchRef, {
        createdByUid: uid,
        ownerUid: uid,
        targetApp: 'van1',
        status: 'queued',
        totalCount: rawItems.length,
        completedCount: 0,
        failedCount: 0,
        reviewRequiredCount: 0,
        createdAt: now,
        updatedAt: now,
      }, { merge: true });
    }

    rawItems.forEach((rawItem, index) => {
      const item = rawItem || {};
      const imageUrl = String(item.imageUrl || '').trim();
      const draftId = String(item.draftId || '').trim();
      if (!imageUrl || !draftId) {
        return;
      }
      const jobId = normalizeAiRequestId(item.requestId || `${batchId}_${index}`);
      const thumbnailUrl = String(item.thumbnailUrl || '').trim();
      const bulkIndex = Number.isFinite(Number(item.bulkIndex)) ? Number(item.bulkIndex) : index;
      const jobRef = db.collection('product_ai_jobs').doc(jobId);
      const draftRef = db.collection('product_drafts').doc(uid).collection('items').doc(draftId);

      writer.set(jobRef, {
        uid,
        ownerUid: uid,
        draftId,
        imageUrl,
        thumbnailUrl: thumbnailUrl || null,
        batchId,
        bulkIndex,
        jobType: 'background',
        priority: isRetry ? PRODUCT_AI_PRIORITY_BULK_RETRY : PRODUCT_AI_PRIORITY_BULK,
        attemptCount: 0,
        nextRunAt: Date.now() + bulkDeferMs,
        productName: String(item.productName || '').trim(),
        description: String(item.description || '').trim(),
        category: String(item.category || '').trim(),
        unit: String(item.unit || '').trim(),
        price: String(item.price || '').trim(),
        weight: String(item.weight || '').trim(),
        weightUnit: String(item.weightUnit || '').trim(),
        status: 'queued',
        aiResult: null,
        error: null,
        lastError: null,
        leaseOwner: null,
        leasedUntil: null,
        leaseExpiresAtMillis: null,
        message: bulkDeferMs > 0
          ? 'รอให้วิเคราะห์สินค้าเดี่ยวเสร็จก่อน'
          : 'พร้อมเข้าคิว AI bulk',
        createdAt: now,
        updatedAt: now,
      }, { merge: true });

      writer.set(draftRef, {
        draftId,
        bulkBatchId: batchId,
        bulkIndex,
        imageUrl,
        thumbnailUrl: thumbnailUrl || null,
        aiStatus: 'queued',
        aiRequestId: jobId,
        queuePosition: bulkIndex + 1,
        estimatedWaitSeconds: Math.max(10, (bulkIndex + 1) * AI_QUEUE_AVERAGE_SECONDS),
        aiQueuedAt: now,
        aiError: null,
        updatedAt: now,
        expiresAtMillis: Date.now() + 48 * 60 * 60 * 1000,
      }, { merge: true });
    });

    await writer.close();

    await recoverStaleQueuedInteractiveJobs();
    await releaseDeferredBackgroundJobsIfInteractiveIdle();
    processQueuedProductAiJobsTick({ maxRounds: 3 }).catch((error) => {
      logger.warn('enqueueBulkProductAiAnalysis worker kick failed', {
        batchId,
        message: error instanceof Error ? error.message : String(error),
      });
    });

    return {
      batchId,
      status: 'queued',
      totalCount: rawItems.length,
    };
  },
);

exports.kickProductAiWorker = onCall(
  {
    region: DEFAULT_REGION,
    secrets: [GEMINI_API_KEY],
    timeoutSeconds: 540,
    memory: '512MiB',
  },
  async (request) => {
    if (!request.auth?.uid) {
      throw new HttpsError('unauthenticated', 'กรุณาเข้าสู่ระบบก่อนใช้งาน AI');
    }
    await recoverStaleQueuedInteractiveJobs();
    await recoverStaleProcessingProductAiJobs('');
    await releaseDeferredBackgroundJobsIfInteractiveIdle();
    return processQueuedProductAiJobsTick({ maxRounds: PRODUCT_AI_WORKER_KICK_MAX_ROUNDS });
  },
);

exports.onProductAiJobQueued = onDocumentCreated(
  {
    document: 'product_ai_jobs/{jobId}',
    region: DEFAULT_REGION,
    secrets: [GEMINI_API_KEY],
    timeoutSeconds: 300,
    memory: '512MiB',
  },
  async (event) => {
    const jobId = event.params.jobId;
    const jobData = event.data?.data() || {};
    if (String(jobData.status || '') !== 'queued') {
      return null;
    }
    const apiKey = String(GEMINI_API_KEY.value() || '').trim();
    if (!apiKey) {
      await markProductAiJobFailed(jobId, jobData, 'missing_gemini_api_key');
      return null;
    }

    const jobType = String(jobData.jobType || 'interactive');
    if (jobType === 'background') {
      if (await hasInteractiveProductAiPending()) {
        return null;
      }
      await runBackgroundProductAiJobNow(
        jobId,
        jobData,
        apiKey,
        'onProductAiJobQueued',
      );
      return null;
    }

    const outcome = await runInteractiveProductAiJobNow(
      jobId,
      jobData,
      apiKey,
      'onProductAiJobQueued',
    );
    if (outcome.status === 'queued') {
      return null;
    }
    return null;
  },
);

async function supersedeOlderInteractiveJobs(uid, keepJobId) {
  const snapshot = await db.collection('product_ai_jobs')
    .where('uid', '==', uid)
    .limit(50)
    .get();
  await Promise.all(snapshot.docs.map(async (doc) => {
    if (doc.id === keepJobId) return;
    const data = doc.data() || {};
    if (String(data.jobType || '') !== 'interactive') return;
    const status = String(data.status || '');
    if (status !== 'queued' && status !== 'processing') return;
    await doc.ref.set({
      status: 'cancelled',
      supersededBy: keepJobId,
      leaseOwner: null,
      leasedUntil: null,
      leaseExpiresAtMillis: null,
      message: 'ถูกแทนที่ด้วยคำขอวิเคราะห์ล่าสุด',
      updatedAt: FieldValue.serverTimestamp(),
    }, { merge: true });
  }));
}

async function claimQueuedProductAiJob(jobDoc, leaseOwner = 'processQueuedProductAiJobs') {
  const jobRef = jobDoc.ref;
  const leaseExpiresAtMillis = Date.now() + 3 * 60 * 1000;
  let claimed = null;
  await db.runTransaction(async (tx) => {
    const snap = await tx.get(jobRef);
    if (!snap.exists) return;
    const data = snap.data() || {};
    if (String(data.status || '') !== 'queued') return;
    const nextRunAt = Number(data.nextRunAt || 0);
    if (nextRunAt > Date.now()) return;
    claimed = data;
    tx.set(jobRef, {
      status: 'processing',
      leaseExpiresAtMillis,
      leaseOwner,
      leasedUntil: leaseExpiresAtMillis,
      startedAt: FieldValue.serverTimestamp(),
      aiStartedAt: FieldValue.serverTimestamp(),
      message: 'ถึงคิวแล้ว กำลังประมวลผล AI...',
      updatedAt: FieldValue.serverTimestamp(),
    }, { merge: true });
  });
  return claimed;
}

async function runClaimedProductAiJob(jobId, claimed, apiKey) {
  try {
    const result = await processProductAiJob(jobId, claimed, apiKey);
    return { ok: true, result, error: null };
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    logger.error('product AI job failed', { jobId, message });
    if (error?.code === 'deadline-exceeded' || error?.code === 'resource-exhausted') {
      await requeueProductAiJob(jobId, claimed, message);
      return { ok: false, result: null, error: message };
    }
    await markProductAiJobFailed(jobId, claimed, message);
    return { ok: false, result: null, error: message };
  }
}

async function processQueuedProductAiJobsRound() {
  const apiKey = String(GEMINI_API_KEY.value() || '').trim();
  if (!apiKey) {
    logger.error('processQueuedProductAiJobs missing GEMINI_API_KEY');
    return { processed: 0, reason: 'missing_gemini_api_key' };
  }

  const now = Date.now();
  const activeSnapshot = await db.collection('product_ai_jobs')
    .where('status', '==', 'processing')
    .limit(50)
    .get();
  const activeJobs = [];
  for (const doc of activeSnapshot.docs) {
    const data = doc.data() || {};
    const leasedUntil = Number(data.leasedUntil || data.leaseExpiresAtMillis || 0);
    const updatedAtMillis = data.updatedAt && typeof data.updatedAt.toMillis === 'function'
      ? data.updatedAt.toMillis()
      : 0;
    const leaseFresh = leasedUntil > now &&
      (updatedAtMillis === 0 || (now - updatedAtMillis) < 2 * 60 * 1000);
    if (leaseFresh) {
      activeJobs.push(data);
      continue;
    }
    await doc.ref.set({
      status: 'queued',
      jobType: String(data.jobType || 'background'),
      priority: Number(data.priority || 0),
      leaseExpiresAtMillis: null,
      leaseOwner: null,
      leasedUntil: null,
      nextRunAt: now,
      message: 'กำลังเข้าคิว AI อีกครั้ง...',
      updatedAt: FieldValue.serverTimestamp(),
    }, { merge: true });
  }
  const activeOwners = new Set(activeJobs.map((data) => String(data.uid || data.ownerUid || '').trim()).filter(Boolean));

  const [interactiveSnap, backgroundSnap, queuedSnap] = await Promise.all([
    db.collection('product_ai_jobs').where('jobType', '==', 'interactive').limit(40).get(),
    db.collection('product_ai_jobs').where('jobType', '==', 'background').limit(40).get(),
    db.collection('product_ai_jobs').where('status', '==', 'queued').limit(40).get(),
  ]);
  const queuedById = new Map();
  for (const snap of [interactiveSnap, backgroundSnap, queuedSnap]) {
    for (const doc of snap.docs) {
      queuedById.set(doc.id, { doc, data: doc.data() || {} });
    }
  }
  const queuedJobs = [...queuedById.values()]
    .filter((job) => String(job.data.status || '') === 'queued')
    .filter((job) => Number(job.data.nextRunAt || 0) <= now)
    .sort((left, right) => {
      const leftPriority = Number(left.data.priority || 0);
      const rightPriority = Number(right.data.priority || 0);
      if (leftPriority !== rightPriority) return rightPriority - leftPriority;
      const leftInteractive = String(left.data.jobType || '') === 'interactive' ? 1 : 0;
      const rightInteractive = String(right.data.jobType || '') === 'interactive' ? 1 : 0;
      if (leftInteractive !== rightInteractive) return rightInteractive - leftInteractive;
      const leftCreatedAt = productAiJobCreatedAtMillis(left.data);
      const rightCreatedAt = productAiJobCreatedAtMillis(right.data);
      if (leftCreatedAt !== rightCreatedAt) {
        return leftInteractive || rightInteractive
          ? rightCreatedAt - leftCreatedAt
          : leftCreatedAt - rightCreatedAt;
      }
      const leftIndex = Number(left.data.bulkIndex || 0);
      const rightIndex = Number(right.data.bulkIndex || 0);
      return leftIndex - rightIndex;
    });

  const interactivePending = await hasInteractiveProductAiPending(now);
  if (interactivePending) {
    await yieldBackgroundProcessingJobs('');
    activeJobs.splice(0, activeJobs.length, ...activeJobs.filter(
      (job) => String(job.jobType || '') !== 'background',
    ));
    activeOwners.clear();
    for (const ownerUid of activeJobs.map(
      (data) => String(data.uid || data.ownerUid || '').trim(),
    ).filter(Boolean)) {
      activeOwners.add(ownerUid);
    }
  }

  const eligibleQueuedJobs = interactivePending
    ? queuedJobs.filter((job) => String(job.data.jobType || '') === 'interactive')
    : queuedJobs;
  const slots = Math.max(0, PRODUCT_AI_WORKER_MAX_JOBS - activeJobs.length);
  if (slots <= 0 || eligibleQueuedJobs.length === 0) {
    return { processed: 0, reason: slots <= 0 ? 'no_slots' : 'no_eligible_jobs' };
  }

  let processed = 0;
  const ownersStartedThisTick = new Set();
  for (const queued of eligibleQueuedJobs) {
    if (processed >= slots) break;
    const ownerUid = String(queued.data.uid || queued.data.ownerUid || '').trim();
    const isInteractive = String(queued.data.jobType || '') === 'interactive';
    if (
      ownerUid &&
      !isInteractive &&
      PRODUCT_AI_WORKER_MAX_PER_OWNER <= 1 &&
      (activeOwners.has(ownerUid) || ownersStartedThisTick.has(ownerUid))
    ) {
      continue;
    }
    const claimed = await claimQueuedProductAiJob(queued.doc);
    if (!claimed) continue;
    if (ownerUid) ownersStartedThisTick.add(ownerUid);
    await runClaimedProductAiJob(queued.doc.id, claimed, apiKey);
    processed += 1;
  }

  return { processed, reason: 'ok' };
}

async function processQueuedProductAiJobsTick(options = {}) {
  const maxRounds = Math.max(1, Number(options.maxRounds || 1));
  await recoverStaleQueuedInteractiveJobs();
  await recoverStaleProcessingProductAiJobs('');
  await releaseDeferredBackgroundJobsIfInteractiveIdle();

  let totalProcessed = 0;
  let lastReason = 'ok';
  for (let round = 0; round < maxRounds; round += 1) {
    const result = await processQueuedProductAiJobsRound();
    totalProcessed += Number(result.processed || 0);
    lastReason = result.reason || lastReason;
    if (Number(result.processed || 0) <= 0) {
      break;
    }
  }
  return { processed: totalProcessed, reason: lastReason };
}

exports.processQueuedProductAiJobs = onSchedule(
  {
    schedule: 'every 1 minutes',
    region: DEFAULT_REGION,
    secrets: [GEMINI_API_KEY],
    timeoutSeconds: 540,
    memory: '512MiB',
  },
  async () => processQueuedProductAiJobsTick(),
);

exports.replaceImageBackgroundWhite = onCall(
  {
    region: DEFAULT_REGION,
    secrets: [GEMINI_API_KEY],
    timeoutSeconds: 120,
    memory: '1GiB',
  },
  async (request) => {
    if (!request.auth?.uid) {
      throw new HttpsError('unauthenticated', 'กรุณาเข้าสู่ระบบก่อนใช้งาน AI');
    }

    const imageBase64 = String(request.data?.imageBase64 || '').trim();
    const inputMimeType = String(request.data?.mimeType || '').trim().toLowerCase();
    const allowedMimeTypes = new Set(['image/jpeg', 'image/jpg', 'image/png', 'image/webp']);

    if (!imageBase64) {
      throw new HttpsError('invalid-argument', 'ไม่พบรูปภาพที่ต้องการประมวลผล');
    }

    const normalizedMimeType = inputMimeType === 'image/jpg' ? 'image/jpeg' : inputMimeType;
    const mimeType = allowedMimeTypes.has(normalizedMimeType)
      ? normalizedMimeType
      : 'image/jpeg';

    const estimatedBytes = Math.floor((imageBase64.length * 3) / 4);
    const maxBytes = 5 * 1024 * 1024;
    if (estimatedBytes > maxBytes) {
      throw new HttpsError('invalid-argument', 'รูปมีขนาดใหญ่เกินไป (สูงสุด 5MB)');
    }

    const apiKey = String(GEMINI_API_KEY.value() || '').trim();
    if (!apiKey) {
      throw new HttpsError('failed-precondition', 'ยังไม่ได้ตั้งค่า GEMINI_API_KEY');
    }

    const queueLease = await acquireAiProcessingSlot({
      uid: request.auth.uid,
      requestId: request.data?.requestId,
    });
    let queueFinalStatus = 'completed';

    try {
      const apiVersions = ['v1beta', 'v1'];
      const preferredModels = [
        'gemini-2.5-flash',
        'gemini-2.0-flash',
        'gemini-1.5-flash',
      ];

      const productName = String(request.data?.productName || '').trim();
      const category = String(request.data?.category || '').trim();
      const unit = String(request.data?.unit || '').trim();
      const price = String(request.data?.price || '').trim();
      const backgroundPath = String(request.data?.backgroundPath || AI_BACKGROUND_DEFAULT_PATH).trim();

      let backgroundAssets = [];
      try {
        backgroundAssets = await loadAiBackgroundAssets(backgroundPath);
      } catch (bgError) {
        logger.warn('replaceImageBackgroundWhite failed to load storage backgrounds', {
          uid: request.auth.uid,
          backgroundPath,
          message: bgError instanceof Error ? bgError.message : String(bgError),
        });
      }

      const parseAnalysisFromParts = (partsForAnalysis) => {
        const textOutput = Array.isArray(partsForAnalysis)
          ? partsForAnalysis.map((part) => String(part?.text || '').trim()).filter(Boolean).join('\n')
          : '';
        if (!textOutput) return {};

        try {
          const jsonMatch = textOutput.match(/\{[\s\S]*\}/);
          if (jsonMatch) return JSON.parse(jsonMatch[0]);
        } catch (parseError) {
          logger.warn('replaceImageBackgroundWhite analysis JSON parse failed', {
            uid: request.auth.uid,
            message: parseError instanceof Error ? parseError.message : String(parseError),
            text: textOutput.slice(0, 800),
          });
        }
        return {};
      };

      const backgroundListText = backgroundAssets.length > 0
        ? backgroundAssets.map((asset) => `${asset.index}. ${asset.source}`).join('\n')
        : 'No storage backgrounds are available.';

      const selectionPrompt = [
        'You are selecting a real existing background from Firebase Storage for one Thai merchant product image.',
        'Do NOT generate, edit, or return any image. Return TEXT JSON only.',
        'The first image is the merchant product after its original background has already been removed. The following numbered images are existing storage backgrounds in the same order as the list.',
        'Choose the single most suitable storage background for the product based on product type, color contrast, sale presentation, and visual cleanliness.',
        'If backgrounds are available, selectedBackgroundIndex MUST be one of the provided numbers. Do not choose white unless no storage background exists.',
        'Also analyze the product for Thai online selling fields.',
        'If the product name is missing or unclear from merchant fields, infer the most likely Thai product name from the product image and return it as productName. Leave productName empty only if the product cannot be identified.',
        'Write description in Thai at about 2 natural mobile-app lines, useful for selling online. Avoid being too short.',
        'Main task 1: decide whether this product is legal to sell in Thailand for normal online commerce. Consider obvious prohibited or controlled goods such as illegal drugs, weapons, counterfeit goods, gambling items, protected wildlife, hazardous materials, prescription-only medicines, and other regulated goods. If uncertain, mark isLegalInThailand false and explain that manual review is required.',
        'Main task 2: identify what product type it is in Thai, such as fresh vegetable, fruit, prepared food, beverage, medicine/pharmacy item, cosmetic, electronics, clothing, household item, agricultural product, or general goods.',
        'VAT rule: fresh unprocessed foods such as fresh vegetables, fruit, raw meat, raw seafood are exempt; processed, cooked, packaged, ready-to-eat, drinks, medicines/pharmacy items, and general goods are taxable.',
        'Nationwide shipping rule: dry, sealed, shelf-stable, non-fragile, legal products are usually suitable; fresh, frozen/chilled, leaking, very fragile, live, hazardous, prescription-controlled, or location-sensitive goods are usually not suitable.',
        'JSON schema only:',
        '{"productName":"likely Thai product name","description":"Thai product description about 2 mobile lines","isLegalInThailand":true/false,"legalReason":"short Thai reason","productType":"specific Thai product type","productCategory":"ของสด or อาหารแปรรูป or สินค้าทั่วไป or ร้านขายยาและเวชภัณฑ์ or สินค้าเกษตร","taxStatus":"taxable or exempt","taxStatusLabel":"สินค้านี้เสียภาษี or สินค้านี้ยกเว้นภาษี","taxReason":"short Thai reason","isFreshProduct":true/false,"isProcessed":true/false,"canShipNationwide":true/false,"nationwideShippingReason":"short Thai reason","selectedBackgroundIndex":1,"backgroundReason":"short Thai reason"}',
        `Known merchant-entered fields: productName=${productName || '-'}, category=${category || '-'}, unit=${unit || '-'}, price=${price || '-'}.`,
        `Storage background candidates:\n${backgroundListText}`,
        'If uncertain, choose the cleanest and highest-contrast storage background. If uncertain about legality, mark isLegalInThailand false and explain manual review in Thai. If uncertain about VAT, choose taxable and explain uncertainty briefly in Thai.',
      ].join(' ');

      const discoveredModelNames = new Set();
      for (const apiVersion of apiVersions) {
        try {
          const listResp = await fetch(
            `https://generativelanguage.googleapis.com/${apiVersion}/models?key=${encodeURIComponent(apiKey)}`,
          );
          if (!listResp.ok) continue;
          const listPayload = await listResp.json();
          const models = Array.isArray(listPayload?.models) ? listPayload.models : [];
          for (const model of models) {
            const name = String(model?.name || '').trim();
            const shortName = name.startsWith('models/') ? name.slice('models/'.length) : name;
            const methods = Array.isArray(model?.supportedGenerationMethods)
              ? model.supportedGenerationMethods.map((value) => String(value || '').trim())
              : [];
            if (shortName && methods.includes('generateContent')) {
              discoveredModelNames.add(shortName);
            }
          }
        } catch (listError) {
          logger.warn('replaceImageBackgroundWhite listModels network error', {
            uid: request.auth.uid,
            apiVersion,
            message: listError instanceof Error ? listError.message : String(listError),
          });
        }
      }

      const modelCandidates = [
        ...new Set([
          ...preferredModels,
          ...[...discoveredModelNames].filter((name) => !/image|imagen/i.test(name)),
        ]),
      ];

      let analysis = {};
      let selectedModel = null;
      let selectedApiVersion = null;
      let lastErrorStatus = null;
      let lastErrorBody = '';

      for (const modelName of modelCandidates) {
        for (const apiVersion of apiVersions) {
          const endpoint = `https://generativelanguage.googleapis.com/${apiVersion}/models/${modelName}:generateContent`;
          let response;
          try {
            response = await fetch(`${endpoint}?key=${encodeURIComponent(apiKey)}`, {
              method: 'POST',
              headers: { 'Content-Type': 'application/json' },
              body: JSON.stringify({
                contents: [
                  {
                    role: 'user',
                    parts: [
                      { text: selectionPrompt },
                      { inlineData: { mimeType, data: imageBase64 } },
                      ...backgroundAssets.flatMap((asset) => [
                        { text: `Storage background candidate ${asset.index}: ${asset.source}` },
                        { inlineData: { mimeType: asset.mimeType, data: asset.data } },
                      ]),
                    ],
                  },
                ],
                generationConfig: {
                  temperature: 0.1,
                  responseMimeType: 'application/json',
                },
              }),
            });
          } catch (error) {
            logger.error('replaceImageBackgroundWhite network error', {
              uid: request.auth.uid,
              model: modelName,
              apiVersion,
              message: error instanceof Error ? error.message : String(error),
            });
            throw new HttpsError('unavailable', 'ไม่สามารถเชื่อมต่อบริการ AI ได้ในขณะนี้');
          }

          if (!response.ok) {
            const errorBody = await response.text();
            const loweredErrorBody = errorBody.toLowerCase();
            logger.error('replaceImageBackgroundWhite upstream error', {
              uid: request.auth.uid,
              model: modelName,
              apiVersion,
              status: response.status,
              body: errorBody.slice(0, 1000),
            });

            if (loweredErrorBody.includes('api_key_invalid') || loweredErrorBody.includes('api key not valid')) {
              throw new HttpsError(
                'failed-precondition',
                'GEMINI_API_KEY ไม่ถูกต้องหรือถูกจำกัดสิทธิ์ กรุณาตั้งค่า key ใหม่ใน Secret Manager',
              );
            }

            if (loweredErrorBody.includes('permission_denied')) {
              throw new HttpsError(
                'permission-denied',
                'บัญชีหรือ API key ยังไม่ได้เปิดสิทธิ์ใช้งาน Generative Language API',
              );
            }

            if (
              loweredErrorBody.includes('resource_exhausted') ||
              loweredErrorBody.includes('prepayment credits are depleted') ||
              loweredErrorBody.includes('credits are depleted') ||
              loweredErrorBody.includes('quota')
            ) {
              throw new HttpsError(
                'resource-exhausted',
                'เครดิต Gemini API หมด กรุณาเติมเครดิตหรือเปิด Billing ใน AI Studio แล้วลองใหม่อีกครั้ง',
              );
            }

            lastErrorStatus = response.status;
            lastErrorBody = errorBody;
            const canTryNextModel =
              loweredErrorBody.includes('not found') ||
              loweredErrorBody.includes('unsupported') ||
              loweredErrorBody.includes('method not found') ||
              loweredErrorBody.includes('model') ||
              loweredErrorBody.includes('invalid json payload') ||
              loweredErrorBody.includes('unknown name') ||
              loweredErrorBody.includes('cannot find field') ||
              loweredErrorBody.includes('responsemimetype');
            if (canTryNextModel) continue;
            throw new HttpsError('internal', 'บริการ AI ตอบกลับผิดพลาด');
          }

          const payload = await response.json();
          const parts = payload?.candidates?.[0]?.content?.parts;
          analysis = parseAnalysisFromParts(parts);
          if (Object.keys(analysis).length > 0) {
            selectedModel = modelName;
            selectedApiVersion = apiVersion;
            break;
          }

          lastErrorStatus = 200;
          lastErrorBody = JSON.stringify(payload).slice(0, 1000);
        }
        if (selectedModel) break;
      }

      if (!selectedModel) {
        logger.error('replaceImageBackgroundWhite no available analysis model', {
          uid: request.auth.uid,
          lastErrorStatus,
          lastErrorBody: String(lastErrorBody || '').slice(0, 1000),
          discoveredModels: [...discoveredModelNames].slice(0, 20),
        });
        throw new HttpsError('unimplemented', 'โมเดล AI สำหรับประเมินพื้นหลังยังไม่พร้อมใช้งานในโปรเจกต์นี้');
      }

      const requestedBackgroundIndex = Number(analysis.selectedBackgroundIndex);
      const selectedBackground = backgroundAssets.find((asset) => asset.index === requestedBackgroundIndex) || backgroundAssets[0] || null;
      const outputBuffer = await composeProductCutoutOnBackground(Buffer.from(imageBase64, 'base64'), selectedBackground);

      return {
        imageBase64: outputBuffer.toString('base64'),
        mimeType: 'image/jpeg',
        productName: String(analysis.productName || '').trim(),
        description: String(analysis.description || '').trim(),
        isLegalInThailand: analysis.isLegalInThailand === true,
        legalReason: String(analysis.legalReason || '').trim(),
        productType: String(analysis.productType || '').trim(),
        taxStatus: String(analysis.taxStatus || '').trim(),
        taxStatusLabel: String(analysis.taxStatusLabel || '').trim(),
        taxReason: String(analysis.taxReason || '').trim(),
        productCategory: String(analysis.productCategory || '').trim(),
        isFreshProduct: analysis.isFreshProduct === true,
        isProcessed: analysis.isProcessed === true,
        canShipNationwide: analysis.canShipNationwide === true,
        nationwideShippingReason: String(analysis.nationwideShippingReason || '').trim(),
        backgroundDecision: selectedBackground ? 'use_storage_background' : 'use_white',
        backgroundReason: String(analysis.backgroundReason || '').trim(),
        backgroundSource: selectedBackground?.source || '',
        selectedBackgroundIndex: selectedBackground?.index || null,
        model: `${selectedModel}@${selectedApiVersion || 'unknown'}`,
        queuePosition: queueLease.position,
        estimatedWaitSeconds: queueLease.estimatedWaitSeconds,
      };
    } catch (error) {
      queueFinalStatus = 'failed';
      throw error;
    } finally {
      await releaseAiProcessingSlot(queueLease, queueFinalStatus);
    }
  },
);

exports.sendEmailOtp = onCall(
  {
    region: DEFAULT_REGION,
    secrets: [SMTP_HOST, SMTP_PORT, SMTP_USER, SMTP_PASS, SMTP_FROM],
  },
  async (request) => {
    const email = normalizeEmail(request.data?.email || request.auth?.token?.email);
    if (!email || !email.includes('@')) {
      throw new HttpsError('invalid-argument', 'รูปแบบอีเมลไม่ถูกต้อง');
    }

    if (request.auth?.uid) {
      const authUser = await admin.auth().getUser(request.auth.uid);
      if (normalizeEmail(authUser.email) !== email) {
        throw new HttpsError('permission-denied', 'อีเมลไม่ตรงกับบัญชีผู้ใช้');
      }
    }

    const docRef = db.collection('email_otps').doc(otpDocId(email));
    const existingDoc = await docRef.get();
    const now = Date.now();

    if (existingDoc.exists) {
      const data = existingDoc.data() || {};
      const lastSentAt = data.lastSentAt?.toMillis?.() || 0;
      if (now - lastSentAt < OTP_RESEND_INTERVAL_MS) {
        throw new HttpsError('resource-exhausted', 'กรุณารอก่อนขอรหัสใหม่');
      }
    }

    const otp = generateOtp();
    await docRef.set(
      {
        email,
        otpHash: hashOtp(email, otp),
        attempts: 0,
        lastSentAt: admin.firestore.Timestamp.fromMillis(now),
        expiresAt: admin.firestore.Timestamp.fromMillis(now + OTP_TTL_MS),
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      },
      { merge: true },
    );

    try {
      const transport = buildTransport();
      const from = readRequiredSecret(SMTP_FROM, 'SMTP_FROM');
      await transport.sendMail({
        from,
        to: email,
        subject: 'รหัส OTP สำหรับยืนยันอีเมล Van Market',
        text: `รหัส OTP ของคุณคือ ${otp} รหัสนี้จะหมดอายุใน 10 นาที`,
        html: `
          <div style="font-family: Arial, sans-serif; line-height: 1.6; color: #1f2937;">
            <h2 style="color: #ea580c;">ยืนยันอีเมล Van Market</h2>
            <p>รหัส OTP สำหรับยืนยันอีเมลของคุณคือ</p>
            <div style="font-size: 32px; font-weight: 700; letter-spacing: 8px; color: #9a3412; margin: 16px 0;">${otp}</div>
            <p>รหัสนี้จะหมดอายุใน 10 นาที</p>
          </div>
        `,
      });
    } catch (error) {
      if (error instanceof HttpsError) {
        throw error;
      }

      logger.error('sendEmailOtp failed', {
        uid: request.auth.uid,
        email,
        message: error instanceof Error ? error.message : String(error),
      });

      throw new HttpsError(
        'unavailable',
        'ระบบ Email OTP ยังส่งอีเมลไม่ได้ กรุณาตรวจสอบ SMTP และ deploy functions ใหม่',
      );
    }

    return { success: true, email, expiresInSeconds: OTP_TTL_MS / 1000 };
  },
);

exports.verifyEmailOtp = onCall(
  {
    region: DEFAULT_REGION,
  },
  async (request) => {
    const email = normalizeEmail(request.data?.email || request.auth?.token?.email);
    const otp = String(request.data?.otp || '').trim();
    const password = String(request.data?.password || '').trim();
    const mode = String(request.data?.mode || 'sign_in').trim().toLowerCase();
    const isResetPassword = mode === 'reset_password';

    if (!email || !email.includes('@')) {
      throw new HttpsError('invalid-argument', 'รูปแบบอีเมลไม่ถูกต้อง');
    }

    if (!/^\d{6}$/.test(otp)) {
      throw new HttpsError('invalid-argument', 'OTP ต้องเป็นตัวเลข 6 หลัก');
    }

    if (password && password.length < 6) {
      throw new HttpsError('invalid-argument', 'รหัสผ่านต้องมีอย่างน้อย 6 ตัวอักษร');
    }

    if (isResetPassword && !password) {
      throw new HttpsError('invalid-argument', 'กรุณากรอกรหัสผ่านใหม่');
    }

    const docRef = db.collection('email_otps').doc(otpDocId(email));
    const snapshot = await docRef.get();
    if (!snapshot.exists) {
      throw new HttpsError('not-found', 'ไม่พบรหัส OTP สำหรับอีเมลนี้');
    }

    const data = snapshot.data() || {};
    const expiresAt = data.expiresAt?.toMillis?.() || 0;
    const attempts = Number(data.attempts || 0);

    if (Date.now() > expiresAt) {
      await docRef.delete();
      throw new HttpsError('deadline-exceeded', 'OTP หมดอายุแล้ว');
    }

    if (attempts >= MAX_VERIFY_ATTEMPTS) {
      await docRef.delete();
      throw new HttpsError('permission-denied', 'กรอกรหัสผิดเกินจำนวนที่กำหนด');
    }

    if (data.otpHash !== hashOtp(email, otp)) {
      await docRef.set(
        {
          attempts: attempts + 1,
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        },
        { merge: true },
      );
      throw new HttpsError('permission-denied', 'รหัส OTP ไม่ถูกต้อง');
    }

    let userRecord;
    try {
      userRecord = await admin.auth().getUserByEmail(email);
    } catch (error) {
      if (error?.code !== 'auth/user-not-found') {
        throw error;
      }
    }

    if (userRecord) {
      const updatePayload = {};
      if (!userRecord.emailVerified) {
        updatePayload.emailVerified = true;
      }
      if (password && (isResetPassword || !userRecord.emailVerified)) {
        updatePayload.password = password;
      }
      if (Object.keys(updatePayload).length > 0) {
        await admin.auth().updateUser(userRecord.uid, updatePayload);
        userRecord = await admin.auth().getUser(userRecord.uid);
      }
    } else {
      if (isResetPassword) {
        throw new HttpsError('not-found', 'ไม่พบบัญชีผู้ใช้สำหรับอีเมลนี้');
      }
      if (!password) {
        throw new HttpsError('failed-precondition', 'กรุณากำหนดรหัสผ่านก่อนยืนยันอีเมล');
      }
      userRecord = await admin.auth().createUser({
        email,
        password,
        emailVerified: true,
      });
    }

    const customToken = await admin.auth().createCustomToken(userRecord.uid);
    await docRef.delete();
    return { success: true, customToken };
  },
);

// checkPreparingOrders ย้ายไป van2/functions/merchant_preparation_penalties.js
// (แจ้งเตือน + หักเครดิต/เงินประกันจริง) — deploy จาก van2 เท่านั้น

/**
 * ส่ง notification ผ่าน FCM
 */
async function sendNotification(fcmToken, title, body, orderId) {
  if (!fcmToken) {
    console.log('No FCM token provided');
    return;
  }

  const message = {
    notification: {
      title: title,
      body: body,
    },
    data: {
      orderId: orderId,
      type: 'order_warning',
      click_action: 'FLUTTER_NOTIFICATION_CLICK',
    },
    token: fcmToken,
  };

  try {
    await admin.messaging().send(message);
    console.log(`Notification sent for order ${orderId}`);
  } catch (error) {
    console.error('Error sending notification:', error);
  }
}

/**
 * Trigger เมื่อมีการอัพเดทสถานะออเดอร์
 */
exports.onOrderStatusUpdate = functions.region(DEFAULT_REGION).firestore
  .document('orders/{orderId}')
  .onUpdate(async (change, context) => {
    const before = change.before.data();
    const after = change.after.data();
    const orderId = context.params.orderId;

    // ถ้าสถานะเปลี่ยนเป็น 'ready' ให้แจ้งเตือนพนักงานขนส่ง
    if (before.status !== 'ready' && after.status === 'ready') {
      if (after.driverFCMToken) {
        await sendNotification(
          after.driverFCMToken,
          'มีออเดอร์พร้อมส่ง',
          `ร้าน ${after.shopAddress} เตรียมสินค้าเสร็จแล้ว รอให้ไปรับ`,
          orderId
        );
      }
    }

    // ถ้าสถานะเปลี่ยนเป็น 'delivering' ให้แจ้งเตือนลูกค้า
    if (before.status !== 'delivering' && after.status === 'delivering') {
      if (after.customerFCMToken) {
        await sendNotification(
          after.customerFCMToken,
          'ออเดอร์ของคุณกำลังจัดส่ง',
          `พนักงานขนส่งกำลังนำสินค้ามาส่ง ประมาณ ${after.estimatedDeliveryTime} นาที`,
          orderId
        );
      }
    }

    // ถ้าสถานะเปลี่ยนเป็น 'delivered' ให้แจ้งเตือนร้านและลูกค้า
    if (before.status !== 'delivered' && after.status === 'delivered') {
      const promises = [];

      if (after.shopFCMToken) {
        promises.push(
          sendNotification(
            after.shopFCMToken,
            'ส่งสินค้าสำเร็จ',
            `ออเดอร์ #${orderId.substring(0, 8)} ส่งถึงลูกค้าเรียบร้อยแล้ว`,
            orderId
          )
        );
      }

      if (after.customerFCMToken) {
        promises.push(
          sendNotification(
            after.customerFCMToken,
            'ได้รับสินค้าแล้ว',
            'ขอบคุณที่ใช้บริการ กรุณาให้คะแนนและรีวิว',
            orderId
          )
        );
      }

      await Promise.all(promises);
    }
  });

/**
 * คำนวณระยะทางและเวลาที่ใช้จัดส่ง (ตัวอย่าง)
 * ในการใช้งานจริงควรใช้ Google Maps Distance Matrix API
 */
exports.calculateDeliveryTime = functions.region(DEFAULT_REGION).https.onCall(async (data, context) => {
  const { shopLocation, customerLocation } = data;

  try {
    // สูตรคำนวณระยะทาง Haversine
    const distance = calculateDistance(
      shopLocation.latitude,
      shopLocation.longitude,
      customerLocation.latitude,
      customerLocation.longitude
    );

    // ประมาณการเวลา: ความเร็วเฉลี่ย 30 km/h
    const estimatedMinutes = Math.ceil((distance / 1000) * 2); // 2 นาที/กิโลเมตร

    return {
      distance: distance,
      estimatedDeliveryTime: estimatedMinutes,
    };
  } catch (error) {
    throw new functions.https.HttpsError('internal', error.message);
  }
});

/**
 * Callable Function: callUser
 * ใช้สำหรับโทรจริง (voice/video call)
 * รับข้อมูล caller/callee/callType, สร้าง Agora token/channel, ส่ง FCM payload type 'call'
 */
exports.callUser = functions
  .region(DEFAULT_REGION)
  .runWith({ secrets: [AGORA_APP_ID_SECRET, AGORA_APP_CERT_SECRET, AGORA_TTL_SECRET] })
  .https.onCall(async (data, context) => {
  // ข้อมูลที่รับมา
  const callerId = data.callerId;
  const callerName = data.callerName;
  const callerPhotoUrl = data.callerPhotoUrl || '';
  const calleeId = data.calleeId;
  const calleeFCMToken = data.calleeFCMToken;
  const callType = data.callType || 'voice'; // 'voice' หรือ 'video'

  // สร้าง channelId (เช่น ใช้ callerId+timestamp)
  const channelId = `call_${callerId}_${Date.now()}`;

  const agoraToken = await buildAgoraToken(channelId);

  // ส่ง FCM payload type 'call' ไปยัง callee
  const message = {
    data: {
      type: 'call',
      callerId: callerId || '',
      callerName: callerName || 'ผู้โทร',
      callerPhotoUrl: callerPhotoUrl || '',
      channelId,
      callType,
      token: agoraToken,
      isVideo: callType === 'video' ? 'true' : 'false',
      click_action: 'FLUTTER_NOTIFICATION_CLICK',
    },
    android: {
      priority: 'high',
      ttl: CALL_TTL_MS,
    },
    apns: {
      headers: {
        'apns-priority': '10',
      },
      payload: {
        aps: {
          sound: 'default',
          'content-available': 1,
          category: 'INCOMING_CALL',
        },
      },
    },
    token: calleeFCMToken,
  };

  try {
    await admin.messaging().send(message);
    return { success: true, channelId, token: agoraToken };
  } catch (error) {
    console.error('Error sending call notification:', error);
    return { success: false, error: error.message };
  }
});
/**
 * คำนวณระยะทางด้วย Haversine formula (meters)
 */
function calculateDistance(lat1, lon1, lat2, lon2) {
  const R = 6371e3; // Earth radius in meters
  const φ1 = lat1 * Math.PI / 180;
  const φ2 = lat2 * Math.PI / 180;
  const Δφ = (lat2 - lat1) * Math.PI / 180;
  const Δλ = (lon2 - lon1) * Math.PI / 180;

  const a = Math.sin(Δφ / 2) * Math.sin(Δφ / 2) +
            Math.cos(φ1) * Math.cos(φ2) *
            Math.sin(Δλ / 2) * Math.sin(Δλ / 2);
  const c = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));

  return R * c;
}

// เพิ่มฟังก์ชัน initiateCall สำหรับฟีเจอร์โทร
exports.initiateCall = functions
  .region(DEFAULT_REGION)
  .runWith({ secrets: [AGORA_APP_ID_SECRET, AGORA_APP_CERT_SECRET, AGORA_TTL_SECRET] })
  .https.onCall(async (data, context) => {
  const { calleeId, callerId, callerName, callerPhotoUrl, isVideo, callType, callerData } = data;
  if (!calleeId) {
    throw new functions.https.HttpsError('invalid-argument', 'calleeId is required');
  }
  if (!callerId && !callerData?.uid) {
    throw new functions.https.HttpsError('invalid-argument', 'callerId is required');
  }

  const resolvedCallerId = callerId || callerData?.uid;
  const resolvedCallType = callType || (isVideo ? 'video' : 'voice');
  const resolvedCallerName = callerName || callerData?.displayName || 'ผู้โทร';
  const resolvedCallerPhoto = callerPhotoUrl || callerData?.photoUrl || '';

  console.log('[initiateCall] incoming request', {
    calleeId,
    callerId: resolvedCallerId,
    callType: resolvedCallType,
  });

  let calleeProfile = await getOrCreateUserProfile(calleeId);
  if (!calleeProfile && resolvedCallerId) {
    console.log('[initiateCall] users doc missing, trying friends cache');
    calleeProfile = await getProfileFromFriendDoc(resolvedCallerId, calleeId);
  }
  if (!calleeProfile) {
    console.error('[initiateCall] callee not found', { calleeId, callerId: resolvedCallerId });
    throw new functions.https.HttpsError('not-found', 'Callee not found');
  }

  const fcmToken = await resolveCallRecipientFcmToken(calleeId);
  if (!fcmToken) {
    throw new functions.https.HttpsError('failed-precondition', 'Callee has no FCM token');
  }

  const { invite, created } = await resolveOrCreateActiveCallInvite({
    callerId: resolvedCallerId,
    calleeId,
    isVideo,
    callType: resolvedCallType,
    calleeProfile,
  });

  console.log('[initiateCall] agora config summary', {
    callerId: resolvedCallerId,
    calleeId,
    ...summarizeAgoraConfig(),
  });

  const { channelId, token, appId } = invite;

  const message = {
    data: {
      type: 'call',
      callerId: resolvedCallerId,
      callerName: resolvedCallerName,
      callerPhotoUrl: resolvedCallerPhoto,
      channelId,
      appId,
      callType: resolvedCallType,
      isVideo: isVideo ? 'true' : 'false',
      token,
      click_action: 'FLUTTER_NOTIFICATION_CLICK',
    },
    android: {
      priority: 'high',
      ttl: CALL_TTL_MS,
    },
    apns: {
      headers: {
        'apns-priority': '10',
      },
      payload: {
        aps: {
          sound: 'default',
          'content-available': 1,
          category: 'INCOMING_CALL',
        },
      },
    },
    token: fcmToken,
  };

  if (created) {
    try {
      await admin.messaging().send(message);
      console.log('[initiateCall] sent call notification');
    } catch (error) {
      await clearActiveCallInvite(resolvedCallerId, calleeId);
      console.error('[initiateCall] failed to send call notification', {
        calleeId,
        callerId: resolvedCallerId,
        code: error?.code,
        message: error?.message,
      });
      if (isUnregisteredFcmTokenError(error)) {
        await clearInvalidRecipientFcmToken(calleeId, fcmToken);
        throw new functions.https.HttpsError(
          'failed-precondition',
          'Callee notification token is no longer registered. Ask the callee to reopen the app and allow notifications.'
        );
      }
      throw new functions.https.HttpsError(
        'failed-precondition',
        `Call notification could not be sent: ${error?.message || 'unknown messaging error'}`
      );
    }
  } else {
    console.log('[initiateCall] reused active call invite', { channelId, callerId: resolvedCallerId, calleeId });
  }

  return {
    channelId,
    appId,
    token,
    calleeProfile: {
      displayName: calleeProfile.displayName || 'ผู้ใช้',
      photoUrl: calleeProfile.photoUrl || null,
      phoneNumber: calleeProfile.phoneNumber || null,
    },
  };
});

exports.cancelCallInvite = functions.region(DEFAULT_REGION).https.onCall(async (data, context) => {
  const channelId = data.channelId;
  const calleeId = data.calleeId;
  const callerId = data.callerId || '';

  if (!channelId || !calleeId) {
    throw new functions.https.HttpsError('invalid-argument', 'channelId and calleeId are required');
  }

  const fcmToken = await resolveCallRecipientFcmToken(calleeId);
  if (!fcmToken) {
    throw new functions.https.HttpsError('failed-precondition', 'Callee token unavailable');
  }

  const message = {
    data: {
      type: 'call_cancel',
      channelId,
      callerId,
    },
    android: {
      priority: 'high',
      ttl: CALL_TTL_MS,
    },
    apns: {
      headers: {
        'apns-priority': '10',
      },
      payload: {
        aps: {
          sound: 'default',
          'content-available': 1,
          category: 'INCOMING_CALL',
        },
      },
    },
    token: fcmToken,
  };

  await admin.messaging().send(message);
  await clearActiveCallInvite(callerId, calleeId);
  console.log('[cancelCallInvite] sent cancel signal', { channelId, calleeId });
  return { success: true };
});

function activeCallInviteRef(callerId, calleeId) {
  return db.collection(ACTIVE_CALL_INVITES_COLLECTION).doc(`${callerId}__${calleeId}`);
}

function maskSecret(secret, visible = 4) {
  if (!secret) return null;
  if (secret.length <= visible * 2) {
    return '*'.repeat(secret.length);
  }
  return `${secret.slice(0, visible)}***${secret.slice(-visible)}`;
}

function summarizeAgoraConfig() {
  const { appId, appCertificate, tokenTtl } = resolveAgoraConfig();
  return {
    appIdMasked: maskSecret(appId, 6),
    appIdLength: appId ? appId.length : 0,
    certificateLength: appCertificate ? appCertificate.length : 0,
    certificatePrefix: appCertificate ? appCertificate.slice(0, 6) : null,
    certificateSuffix: appCertificate ? appCertificate.slice(-6) : null,
    tokenTtl,
  };
}

function timestampToMillis(value) {
  if (!value) return null;
  if (typeof value.toMillis === 'function') {
    return value.toMillis();
  }
  if (typeof value._seconds === 'number') {
    return value._seconds * 1000;
  }
  return null;
}

async function resolveOrCreateActiveCallInvite({
  callerId,
  calleeId,
  isVideo,
  callType,
  calleeProfile,
}) {
  const inviteRef = activeCallInviteRef(callerId, calleeId);
  const sessionCollection = db.collection('call_sessions');
  const inviteExpiry = admin.firestore.Timestamp.fromMillis(Date.now() + CALL_TTL_MS);
  const { appId } = resolveAgoraConfig();
  const freshChannelId = `call_${calleeId}_${Date.now()}`;
  const freshToken = await buildAgoraToken(freshChannelId);
  let invite = null;
  let created = false;

  await db.runTransaction(async (transaction) => {
    const currentTime = Date.now();
    const inviteSnap = await transaction.get(inviteRef);

    if (inviteSnap.exists) {
      const existingInvite = inviteSnap.data() || {};
      const expiresAtMillis = timestampToMillis(existingInvite.expiresAt);
      const existingChannelId = existingInvite.channelId;

      if (existingChannelId && expiresAtMillis != null && expiresAtMillis > currentTime) {
        const sessionSnap = await transaction.get(sessionCollection.doc(existingChannelId));
        const sessionStatus = sessionSnap.exists ? sessionSnap.data()?.status : null;
        if (sessionStatus !== 'ended') {
          invite = existingInvite;
          return;
        }
      }

      transaction.delete(inviteRef);
    }

    console.log('[callInvite] created fresh invite', {
      callerId,
      calleeId,
      channelId: freshChannelId,
      isVideo,
      callType,
    });
    invite = {
      channelId: freshChannelId,
      token: freshToken,
      appId,
      callerId,
      calleeId,
      isVideo,
      callType,
      calleeProfile: {
        displayName: calleeProfile.displayName || 'ผู้ใช้',
        photoUrl: calleeProfile.photoUrl || null,
        phoneNumber: calleeProfile.phoneNumber || null,
      },
      createdAt: FieldValue.serverTimestamp(),
      expiresAt: inviteExpiry,
    };
    transaction.set(inviteRef, invite);
    created = true;
  });

  return { invite, created };
}

async function clearActiveCallInvite(callerId, calleeId) {
  if (!callerId || !calleeId) {
    return;
  }
  try {
    await activeCallInviteRef(callerId, calleeId).delete();
  } catch (error) {
    console.warn('[callInvite] failed to clear active invite', { callerId, calleeId, error });
  }
}

async function buildAgoraToken(channelId, uid = 0) {
  const { appId, appCertificate, tokenTtl } = resolveAgoraConfig();
  if (!appId || !appCertificate) {
    throw new functions.https.HttpsError(
      'failed-precondition',
      'Agora credentials are not configured. Set secrets AGORA_APP_ID and AGORA_APP_CERTIFICATE.'
    );
  }

  const privilegeExpiredTs = Math.floor(Date.now() / 1000) + tokenTtl;
  try {
    console.log('[agora] building token', {
      channelId,
      uid,
      privilegeExpiredTs,
      ...summarizeAgoraConfig(),
    });
    return RtcTokenBuilder.buildTokenWithUid(
      appId,
      appCertificate,
      channelId,
      uid,
      RtcRole.PUBLISHER,
      privilegeExpiredTs
    );
  } catch (error) {
    console.error('[agora] Failed to build token', { channelId, error });
    throw new functions.https.HttpsError(
      'failed-precondition',
      'Unable to create Agora token. Check AGORA_APP_ID and AGORA_APP_CERTIFICATE secrets.'
    );
  }
}

function resolveAgoraConfig() {
  const appId = readSecretOrEnv(AGORA_APP_ID_SECRET, 'AGORA_APP_ID');
  const appCertificate = readSecretOrEnv(AGORA_APP_CERT_SECRET, 'AGORA_APP_CERTIFICATE');
  const ttlRaw = readSecretOrEnv(
    AGORA_TTL_SECRET,
    'AGORA_APP_TTL_SECONDS',
    '3600'
  );
  let tokenTtl = parseInt(ttlRaw, 10);
  if (!Number.isFinite(tokenTtl) || tokenTtl <= 0) {
    tokenTtl = 3600;
  }
  return { appId, appCertificate, tokenTtl };
}

function readSecretOrEnv(secret, envName, fallback = '') {
  try {
    const value = secret.value();
    if (value) return String(value).trim();
  } catch (error) {
    console.warn('[secrets] Firebase secret unavailable, falling back to env', {
      envName,
      message: error?.message,
    });
  }
  return String(process.env[envName] || fallback).trim();
}

async function getOrCreateUserProfile(uid) {
  const userRef = db.collection('users').doc(uid);
  const existing = await userRef.get();
  if (existing.exists) {
    const data = existing.data();
    console.log('[initiateCall] found user doc', { uid, source: data?.sourceCollection || 'users' });
    return data;
  }

  for (const collection of PROFILE_COLLECTIONS) {
    const doc = await db.collection(collection).doc(uid).get();
    if (!doc.exists) continue;
    const normalized = buildProfileFromSource(doc.data(), collection);
    await userRef.set(
      {
        ...normalized,
        updatedAt: FieldValue.serverTimestamp(),
        createdAt: FieldValue.serverTimestamp(),
        sourceCollection: collection,
      },
      { merge: true }
    );
    console.log('[initiateCall] synced profile from source collection', { uid, collection });
    return normalized;
  }

  console.warn('[initiateCall] no profile found in known collections', { uid });
  return null;
}

function buildProfileFromSource(data = {}, fallbackCollection) {
  return {
    displayName: readDisplayName(data, 'ผู้ใช้ใหม่'),
    photoUrl: readPhotoUrl(data),
    serviceType: data.serviceType || fallbackCollection,
    isOfficial: !!data.isOfficialAccount,
    profileCompleted: !!data.isProfileCompleted,
    phoneNumber: normalizePhone(data.phone || data.phoneNumber || ''),
  };
}

function readDisplayName(data, fallback) {
  const candidates = [data.displayName, data.shopName, data.name];
  for (const candidate of candidates) {
    if (candidate && typeof candidate === 'string' && candidate.trim().length) {
      return candidate.trim();
    }
  }
  return fallback;
}

function readPhotoUrl(data) {
  const candidates = [
    data.shopImageUrl,
    data.imageUrl,
    data.logoUrl,
    data.profileImageUrl,
  ];
  for (const candidate of candidates) {
    if (candidate && typeof candidate === 'string' && candidate.trim().length) {
      return candidate.trim();
    }
  }
  return null;
}

function normalizePhone(raw = '') {
  let clean = raw.replace(/[^0-9+]/g, '');
  if (!clean) return '';
  if (clean.startsWith('00')) {
    clean = `+${clean.substring(2)}`;
  }
  if (clean.startsWith('0') && clean.length === 10) {
    return `+66${clean.substring(1)}`;
  }
  if (!clean.startsWith('+') && clean.length >= 9) {
    return `+${clean}`;
  }
  return clean;
}

async function getProfileFromFriendDoc(ownerId, friendId) {
  try {
    const doc = await db
      .collection('users')
      .doc(ownerId)
      .collection('friends')
      .doc(friendId)
      .get();
    if (!doc.exists) return null;
    const data = doc.data() || {};
    await db.collection('users').doc(friendId).set(
      {
        ...data,
        uid: friendId,
        updatedAt: FieldValue.serverTimestamp(),
        source: 'friends-cache',
      },
      { merge: true }
    );
    return data;
  } catch (error) {
    console.error('Error getting friend doc profile', error);
    return null;
  }
}

exports.computeRouteMetrics = onCall(
  {
    region: DEFAULT_REGION,
    secrets: [
      GOOGLE_ROUTES_API_KEY,
      REDIS_URL,
      REDIS_TOKEN,
    ],
  },
  async (request) => {
    const originLatitude = Number(request.data?.originLatitude);
    const originLongitude = Number(request.data?.originLongitude);
    const destinationLatitude = Number(request.data?.destinationLatitude);
    const destinationLongitude = Number(request.data?.destinationLongitude);

    if (
      !Number.isFinite(originLatitude) ||
      !Number.isFinite(originLongitude) ||
      !Number.isFinite(destinationLatitude) ||
      !Number.isFinite(destinationLongitude)
    ) {
      throw new HttpsError('invalid-argument', 'พิกัดต้นทาง/ปลายทางไม่ถูกต้อง');
    }

    const cacheKey = buildRouteCacheKey({
      originLatitude,
      originLongitude,
      destinationLatitude,
      destinationLongitude,
    });

    const cached = await readRouteCache(cacheKey);
    if (cached) {
      return { ...cached, source: 'cache' };
    }

    const apiKey = String(GOOGLE_ROUTES_API_KEY.value() || process.env.GOOGLE_ROUTES_API_KEY || '').trim();
    if (!apiKey) {
      throw new HttpsError('failed-precondition', 'ยังไม่ได้ตั้งค่า GOOGLE_ROUTES_API_KEY');
    }

    const body = {
      origin: {
        location: {
          latLng: {
            latitude: originLatitude,
            longitude: originLongitude,
          },
        },
      },
      destination: {
        location: {
          latLng: {
            latitude: destinationLatitude,
            longitude: destinationLongitude,
          },
        },
      },
      travelMode: 'TWO_WHEELER',
      languageCode: 'th-TH',
      units: 'METRIC',
    };

    let response;
    try {
      response = await fetch('https://routes.googleapis.com/directions/v2:computeRoutes', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'X-Goog-Api-Key': apiKey,
          'X-Goog-FieldMask': 'routes.distanceMeters,routes.duration',
        },
        body: JSON.stringify(body),
      });
    } catch (error) {
      logger.error('computeRouteMetrics network error', {
        message: error instanceof Error ? error.message : String(error),
      });
      throw new HttpsError('unavailable', 'เชื่อมต่อ Routes API ไม่สำเร็จ');
    }

    if (!response.ok) {
      let details = 'routes api request failed';
      try {
        details = await response.text();
      } catch (_) {}
      logger.error('computeRouteMetrics api error', {
        status: response.status,
        details,
      });
      throw new HttpsError('failed-precondition', `Routes API error: ${response.status}`);
    }

    let decoded;
    try {
      decoded = await response.json();
    } catch (_) {
      throw new HttpsError('internal', 'อ่านผลลัพธ์ Routes API ไม่สำเร็จ');
    }

    const firstRoute = decoded?.routes?.[0];
    const distanceMeters = Number(firstRoute?.distanceMeters);
    const durationSeconds = parseDurationSeconds(firstRoute?.duration);
    if (!Number.isFinite(distanceMeters) || !Number.isFinite(durationSeconds)) {
      throw new HttpsError('internal', 'ข้อมูลระยะทาง/เวลาไม่ครบจาก Routes API');
    }

    const payload = {
      distanceMeters,
      durationSeconds,
    };

    await writeRouteCache(cacheKey, payload);
    return { ...payload, source: 'routes-api' };
  },
);

function buildRouteCacheKey({
  originLatitude,
  originLongitude,
  destinationLatitude,
  destinationLongitude,
}) {
  const to4 = (v) => Number(v).toFixed(4);
  return `route:${to4(originLatitude)},${to4(originLongitude)}->${to4(destinationLatitude)},${to4(destinationLongitude)}`;
}

function parseDurationSeconds(durationText) {
  if (typeof durationText !== 'string' || !durationText.endsWith('s')) {
    return NaN;
  }
  return Number(durationText.slice(0, -1));
}

function redisTcpConfig() {
  const url = String(REDIS_URL.value() || process.env.REDIS_URL || '').trim();
  const token = String(REDIS_TOKEN.value() || process.env.REDIS_TOKEN || '').trim();
  if (!url) {
    return null;
  }
  return { url, token };
}

async function getRedisClient() {
  const cfg = redisTcpConfig();
  if (!cfg) {
    return null;
  }

  if (redisClient && redisClientReady) {
    return redisClient;
  }

  if (!redisClient) {
    const options = {
      lazyConnect: true,
      maxRetriesPerRequest: 1,
      enableReadyCheck: true,
    };
    if (cfg.token) {
      options.password = cfg.token;
    }

    redisClient = new Redis(cfg.url, options);
    redisClient.on('ready', () => {
      redisClientReady = true;
    });
    redisClient.on('error', (error) => {
      redisClientReady = false;
      logger.warn('redis tcp client error', {
        message: error instanceof Error ? error.message : String(error),
      });
    });
  }

  try {
    if (redisClient.status !== 'ready') {
      await redisClient.connect();
    }
    redisClientReady = true;
    return redisClient;
  } catch (error) {
    redisClientReady = false;
    logger.warn('redis tcp connect failed', {
      message: error instanceof Error ? error.message : String(error),
    });
    return null;
  }
}

function redisConfig() {
  const url = String(process.env.REDIS_REST_URL || '').trim();
  const token = String(process.env.REDIS_REST_TOKEN || '').trim();
  if (!url || !token) {
    return null;
  }
  return { url: url.replace(/\/$/, ''), token };
}

async function redisGet(key) {
  const tcpClient = await getRedisClient();
  if (tcpClient) {
    return tcpClient.get(key);
  }

  const cfg = redisConfig();
  if (!cfg) return null;
  const endpoint = `${cfg.url}/get/${encodeURIComponent(key)}`;
  const res = await fetch(endpoint, {
    method: 'GET',
    headers: {
      Authorization: `Bearer ${cfg.token}`,
    },
  });
  if (!res.ok) return null;
  const json = await res.json();
  return json?.result || null;
}

async function redisSetEx(key, ttlSec, value) {
  const tcpClient = await getRedisClient();
  if (tcpClient) {
    const result = await tcpClient.set(key, value, 'EX', ttlSec);
    return result === 'OK';
  }

  const cfg = redisConfig();
  if (!cfg) return false;
  const endpoint = `${cfg.url}/setex/${encodeURIComponent(key)}/${ttlSec}/${encodeURIComponent(value)}`;
  const res = await fetch(endpoint, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${cfg.token}`,
    },
  });
  return res.ok;
}

async function readRouteCache(key) {
  try {
    const redisValue = await redisGet(key);
    if (redisValue) {
      const parsed = JSON.parse(redisValue);
      if (Number.isFinite(parsed?.distanceMeters) && Number.isFinite(parsed?.durationSeconds)) {
        return {
          distanceMeters: Number(parsed.distanceMeters),
          durationSeconds: Number(parsed.durationSeconds),
        };
      }
    }
  } catch (error) {
    logger.warn('readRouteCache redis failed', {
      message: error instanceof Error ? error.message : String(error),
    });
  }

  try {
    const doc = await db.collection('routes_cache').doc(key).get();
    if (!doc.exists) return null;
    const data = doc.data() || {};
    const expiresAt = data.expiresAt?.toMillis?.() || 0;
    if (Date.now() > expiresAt) {
      await doc.ref.delete();
      return null;
    }
    if (!Number.isFinite(data.distanceMeters) || !Number.isFinite(data.durationSeconds)) {
      return null;
    }
    return {
      distanceMeters: Number(data.distanceMeters),
      durationSeconds: Number(data.durationSeconds),
    };
  } catch (error) {
    logger.warn('readRouteCache firestore failed', {
      message: error instanceof Error ? error.message : String(error),
    });
    return null;
  }
}

async function writeRouteCache(key, payload) {
  const serialized = JSON.stringify(payload);
  try {
    await redisSetEx(key, ROUTE_CACHE_TTL_SEC, serialized);
  } catch (error) {
    logger.warn('writeRouteCache redis failed', {
      message: error instanceof Error ? error.message : String(error),
    });
  }

  try {
    await db.collection('routes_cache').doc(key).set({
      ...payload,
      expiresAt: admin.firestore.Timestamp.fromMillis(Date.now() + ROUTE_CACHE_TTL_SEC * 1000),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
  } catch (error) {
    logger.warn('writeRouteCache firestore failed', {
      message: error instanceof Error ? error.message : String(error),
    });
  }
}

function normalizePhoneNumber(raw = '') {
  let clean = String(raw).trim().replace(/[^0-9+]/g, '');
  if (!clean) return '';
  if (clean.startsWith('00')) {
    clean = `+${clean.substring(2)}`;
  }
  if (clean.startsWith('0') && clean.length === 10) {
    return `+66${clean.substring(1)}`;
  }
  if (!clean.startsWith('+') && clean.length >= 9) {
    return `+${clean}`;
  }
  return clean;
}

function hashPhonePassword(phoneNumber, password) {
  return crypto
    .createHash('sha256')
    .update(`${normalizePhoneNumber(phoneNumber)}:${String(password || '')}`)
    .digest('hex');
}

exports.upsertPhonePasswordProfile = onCall(
  {
    region: DEFAULT_REGION,
  },
  async (request) => {
    if (!request.auth?.uid) {
      throw new HttpsError('unauthenticated', 'กรุณาเข้าสู่ระบบก่อน');
    }

    const phoneNumber = normalizePhoneNumber(request.data?.phoneNumber);
    const password = String(request.data?.password || '').trim();
    const authPhone = normalizePhoneNumber(request.auth.token?.phone_number || '');

    if (!phoneNumber || !phoneNumber.startsWith('+')) {
      throw new HttpsError('invalid-argument', 'เบอร์โทรศัพท์ไม่ถูกต้อง');
    }

    if (password.length < 4) {
      throw new HttpsError('invalid-argument', 'รหัสผ่านสั้นเกินไป');
    }

    if (!authPhone || authPhone !== phoneNumber) {
      throw new HttpsError('permission-denied', 'เบอร์โทรไม่ตรงกับบัญชีที่เข้าสู่ระบบ');
    }

    await db.collection('phone_login_profiles').doc(phoneNumber).set(
      {
        uid: request.auth.uid,
        phoneNumber,
        passwordHash: hashPhonePassword(phoneNumber, password),
        updatedAt: FieldValue.serverTimestamp(),
      },
      { merge: true },
    );

    return { success: true };
  },
);

exports.signInWithPhonePassword = onCall(
  {
    region: DEFAULT_REGION,
  },
  async (request) => {
    const phoneNumber = normalizePhoneNumber(request.data?.phoneNumber);
    const password = String(request.data?.password || '').trim();

    if (!phoneNumber || !phoneNumber.startsWith('+') || !password) {
      throw new HttpsError('invalid-argument', 'ข้อมูลเข้าสู่ระบบไม่ถูกต้อง');
    }

    const doc = await db.collection('phone_login_profiles').doc(phoneNumber).get();
    if (!doc.exists) {
      throw new HttpsError('permission-denied', 'ต้องยืนยัน OTP ครั้งแรกก่อน');
    }

    const data = doc.data() || {};
    if (!data.uid || !data.passwordHash) {
      throw new HttpsError('permission-denied', 'ไม่พบข้อมูลเข้าสู่ระบบ');
    }

    const expectedHash = hashPhonePassword(phoneNumber, password);
    if (expectedHash !== data.passwordHash) {
      throw new HttpsError('permission-denied', 'เบอร์โทรหรือรหัสผ่านไม่ถูกต้อง');
    }

    const customToken = await admin.auth().createCustomToken(String(data.uid));
    return { customToken };
  },
);

exports.verifyTopUpSlip = onCall(
  {
    region: DEFAULT_REGION,
    enforceAppCheck: true,
    secrets: [SLIPOK_API_KEY_SECRET],
  },
  async (request) => {
    if (!request.auth?.uid) {
      throw new HttpsError('unauthenticated', 'กรุณาเข้าสู่ระบบก่อนส่งสลิป');
    }

    const uid = request.auth.uid;
    const requestedUid = String(request.data?.uid || '').trim();
    const expectedAmount = parseNumber(request.data?.expectedAmount);
    const storagePath = String(request.data?.storagePath || '').trim();
    const storageBucket = String(request.data?.bucket || '').trim();
    const paymentGroupId = String(request.data?.paymentGroupId || '').trim();
    const fileName = String(request.data?.fileName || 'slip.jpg').trim() || 'slip.jpg';
    const contentType = String(request.data?.contentType || 'image/jpeg').trim() || 'image/jpeg';
    const sourceApp = String(request.data?.sourceApp || 'van1_merchant').trim() || 'van1_merchant';
    const topUpPurpose = String(request.data?.purpose || 'top_up').trim() || 'top_up';

    if (requestedUid && requestedUid !== uid) {
      throw new HttpsError('permission-denied', 'ไม่สามารถส่งสลิปแทนผู้ใช้อื่นได้');
    }
    if (!Number.isFinite(expectedAmount) || expectedAmount <= 0) {
      throw new HttpsError('invalid-argument', 'กรุณาระบุ expectedAmount ให้ถูกต้อง');
    }
    if (expectedAmount > TOP_UP_MAX_AMOUNT) {
      throw new HttpsError(
        'invalid-argument',
        `ยอดเติมสูงสุด ${TOP_UP_MAX_AMOUNT.toLocaleString('th-TH')} บาทต่อครั้ง`,
      );
    }
    if (!storagePath) {
      throw new HttpsError('invalid-argument', 'กรุณาระบุ storagePath');
    }
    if (!paymentGroupId) {
      throw new HttpsError('invalid-argument', 'กรุณาระบุ paymentGroupId');
    }
    const merchantSecurityDepositRequiredBaht = await getMerchantSecurityDepositRequiredBaht();
    if (
      topUpPurpose === 'security_deposit'
      && merchantSecurityDepositRequiredBaht > 0
      && expectedAmount < merchantSecurityDepositRequiredBaht
    ) {
      throw new HttpsError(
        'invalid-argument',
        `ค่าประกันเปิดร้านขั้นต่ำ ${merchantSecurityDepositRequiredBaht.toLocaleString('th-TH')} บาท`,
      );
    }
    if (storageBucket && !ALLOWED_TOPUP_STORAGE_BUCKETS.has(storageBucket)) {
      throw new HttpsError('invalid-argument', 'ไม่รองรับ bucket ที่ระบุ');
    }
    assertTopUpStoragePathForActor(uid, storagePath, sourceApp);

    await consumeTopUpDailyVerificationAttempt(uid);

    const topUpRef = db
      .collection(SHOP_TOPUP_SLIPS_COLLECTION)
      .doc(uid)
      .collection('items')
      .doc(paymentGroupId);
    await topUpRef.set({
      uid,
      expectedAmount,
      storagePath,
      bucket: storageBucket || null,
      paymentGroupId,
      fileName,
      contentType,
      sourceApp,
      purpose: topUpPurpose,
      status: 'checking',
      updatedAt: FieldValue.serverTimestamp(),
    }, { merge: true });

    const paymentCollectionSettings = await getPaymentCollectionSettings();
    const slipValidationSettings = paymentCollectionSettings;
    const bucket = storageBucket ? admin.storage().bucket(storageBucket) : admin.storage().bucket();
    const file = bucket.file(storagePath);
    const [exists] = await file.exists();
    if (!exists) {
      await topUpRef.set({
        status: 'not_found',
        message: 'ไม่พบไฟล์สลิปใน Firebase Storage',
        updatedAt: FieldValue.serverTimestamp(),
      }, { merge: true });
      throw new HttpsError('not-found', 'ไม่พบไฟล์สลิปใน Firebase Storage');
    }

    let verificationStatus = 'error';
    let verificationMessage = 'ส่งสลิปไปตรวจไม่สำเร็จ';
    let responseCode = 0;
    let providerPayload = null;
    let providerRawText = '';
    let verifiedSlipAmount = null;
    let verifiedTransRef = '';
    let receiverValidation = null;

    try {
      const [buffer] = await file.download();
      const apiKey = readRequiredConfiguredSecret(
        SLIPOK_API_KEY_SECRET,
        'SLIPOK_API_KEY',
        'ระบบตรวจสลิป Slip OK',
      );

      const formData = new FormData();
      formData.append('files', new Blob([buffer], { type: contentType }), fileName);
      formData.append('log', 'true');
      formData.append('amount', expectedAmount.toString());

      const slipResponse = await fetch(SLIPOK_ENDPOINT, {
        method: 'POST',
        headers: {
          'x-authorization': apiKey,
        },
        body: formData,
      });

      responseCode = slipResponse.status;
      providerRawText = await slipResponse.text();
      try {
        providerPayload = providerRawText ? JSON.parse(providerRawText) : null;
      } catch (_) {
        providerPayload = { raw: providerRawText };
      }

      const rawCode = Number(providerPayload?.code);
      const requestSucceeded = providerPayload?.success === true;
      const dataSucceeded = providerPayload?.data?.success === true;
      verifiedSlipAmount = parseNumber(providerPayload?.data?.amount);
      const hasValidAmount = Number.isFinite(verifiedSlipAmount) && verifiedSlipAmount > 0;
      receiverValidation = validateTopUpSlipReceiver(
        providerPayload,
        slipValidationSettings,
        slipValidationSettings.promptPayNationalIdOrTaxId,
      );
      const hasMatchingReceiver = receiverValidation.matched;
      const hasMatchingAmount = amountsMatch(verifiedSlipAmount, expectedAmount);
      const transRef = String(providerPayload?.data?.transRef || '').trim();
      verifiedTransRef = transRef;

      logger.info('verifyTopUpSlip evaluated slip', {
        paymentGroupId,
        uid,
        rawCode,
        requestSucceeded,
        dataSucceeded,
        hasValidAmount,
        hasMatchingAmount,
        hasMatchingReceiver,
        transRef,
        receiverValidation,
      });

      if (rawCode === 1012) {
        verificationStatus = 'failed';
        verificationMessage = buildSlipVerificationMessage(
          verificationStatus,
          providerPayload,
          'สลิปนี้ถูกใช้ตรวจสอบไปแล้ว',
        );
      } else if (
        slipResponse.ok &&
        requestSucceeded &&
        dataSucceeded &&
        hasValidAmount &&
        hasMatchingAmount &&
        hasMatchingReceiver &&
        transRef.length > 0
      ) {
        verificationStatus = 'verified';
        verificationMessage = 'ตรวจสอบสลิปสำเร็จ เติมเครดิตเรียบร้อย';
      } else if (slipResponse.ok && hasValidAmount && hasMatchingAmount && !hasMatchingReceiver) {
        verificationStatus = 'failed';
        providerPayload = {
          ...(providerPayload && typeof providerPayload === 'object' ? providerPayload : {}),
          code: Number(providerPayload?.code) || 1014,
          data: {
            ...(providerPayload?.data && typeof providerPayload.data === 'object' ? providerPayload.data : {}),
            receiverValidation,
            expectedRecipientDisplayName: slipValidationSettings.recipientDisplayName,
            expectedReceiverTargets: buildExpectedReceiverTargets(slipValidationSettings),
            message: providerPayload?.data?.message || 'บัญชีผู้รับในสลิปไม่ตรงกับบัญชีร้าน',
          },
          message: providerPayload?.message || 'บัญชีผู้รับในสลิปไม่ตรงกับบัญชีร้าน',
        };
        verificationMessage = buildSlipVerificationMessage(
          verificationStatus,
          providerPayload,
          'บัญชีผู้รับในสลิปไม่ตรงกับบัญชีร้าน',
        );
      } else if (
        slipResponse.ok &&
        hasValidAmount &&
        hasMatchingAmount &&
        hasMatchingReceiver &&
        transRef.length === 0
      ) {
        verificationStatus = 'failed';
        verificationMessage = 'ไม่พบเลขอ้างอิงธุรกรรมในสลิป กรุณาแนบสลิปใหม่';
      } else if (slipResponse.ok && hasValidAmount && hasMatchingAmount && !dataSucceeded) {
        verificationStatus = 'failed';
        verificationMessage = buildSlipVerificationMessage(
          verificationStatus,
          providerPayload,
          'สลิปไม่ผ่านการตรวจสอบจากธนาคาร',
        );
      } else {
        verificationStatus = 'failed';
        verificationMessage = buildSlipVerificationMessage(
          verificationStatus,
          providerPayload,
          `Slip OK responded with status ${slipResponse.status}`,
        );
      }
    } catch (error) {
      verificationStatus = 'error';
      providerPayload = {
        message: error instanceof Error ? error.message : String(error),
      };
      verificationMessage = buildSlipVerificationMessage(
        verificationStatus,
        providerPayload,
        'ส่งสลิปไปตรวจสอบไม่สำเร็จ',
      );
      logger.error('verifyTopUpSlip failed', {
        uid,
        paymentGroupId,
        storagePath,
        message: verificationMessage,
      });
    }

    const slipOkFeedbackId = await writeSlipOkFeedbackLog({
      feedbackId: paymentGroupId,
      customerUid: uid,
      paymentGroupId,
      storagePath,
      fileName,
      contentType,
      expectedAmount,
      verifiedAmount: verifiedSlipAmount,
      verificationStatus,
      verificationMessage,
      responseCode,
      providerPayload,
      providerRawText,
      transRef: verifiedTransRef || null,
      receiverValidation,
      sourceApp,
    });

    const creditedAmount = Number.isFinite(verifiedSlipAmount) ? verifiedSlipAmount : 0;
    const remainingAmount = Math.max(0, expectedAmount - creditedAmount);
    const overpaidAmount = Math.max(0, creditedAmount - expectedAmount);
    const baseTopUpUpdate = {
      status: verificationStatus,
      message: verificationMessage,
      expectedAmount,
      verifiedAmount: creditedAmount,
      remainingAmount,
      overpaidAmount,
      slipFeedbackId: slipOkFeedbackId,
      responseCode,
      provider: 'slipok',
      providerLabel: 'Slip OK',
      updatedAt: FieldValue.serverTimestamp(),
    };

    if (verificationStatus !== 'verified') {
      await topUpRef.set(baseTopUpUpdate, { merge: true });
      return {
        success: false,
        status: verificationStatus,
        message: verificationMessage,
        expectedAmount,
        verifiedAmount: creditedAmount,
        remainingAmount,
        overpaidAmount,
        slipFeedbackId: slipOkFeedbackId,
        paymentGroupId,
      };
    }

    const creditDocId = `slipok_topup_${slipOkFeedbackId}`;
    const creditRef = db.collection('credits').doc(creditDocId);
    const transRefForLock = String(verifiedTransRef || '').trim();

    if (!transRefForLock) {
      await topUpRef.set({
        ...baseTopUpUpdate,
        status: 'failed',
        message: 'ไม่พบเลขอ้างอิงธุรกรรมในสลิป กรุณาแนบสลิปใหม่',
      }, { merge: true });
      return {
        success: false,
        status: 'failed',
        message: 'ไม่พบเลขอ้างอิงธุรกรรมในสลิป กรุณาแนบสลิปใหม่',
        expectedAmount,
        verifiedAmount: creditedAmount,
        remainingAmount,
        overpaidAmount,
        slipFeedbackId: slipOkFeedbackId,
        paymentGroupId,
      };
    }

    let creditedNow = false;
    try {
      await db.runTransaction(async (tx) => {
        const transRefRef = db.collection(SLIP_TRANS_REF_COLLECTION).doc(transRefForLock);
        const transRefSnap = await tx.get(transRefRef);
        if (transRefSnap.exists) {
          const duplicateError = new Error('SLIP_TRANS_REF_DUPLICATE');
          duplicateError.code = 'SLIP_TRANS_REF_DUPLICATE';
          throw duplicateError;
        }

        const existing = await tx.get(creditRef);
        if (!existing.exists) {
          creditedNow = true;
          tx.set(creditRef, {
            uid,
            amount: creditedAmount,
            timestamp: FieldValue.serverTimestamp(),
            provider: 'slipok',
            providerLabel: 'Slip OK',
            status: 'verified',
            type: 'top_up',
            creditedByCloudFunction: true,
            slipFeedbackId: slipOkFeedbackId,
            paymentGroupId,
            storagePath,
            expectedAmount,
            verifiedAmount: creditedAmount,
            remainingAmount,
            overpaidAmount,
            sourceApp,
            transRef: transRefForLock,
            createdAt: FieldValue.serverTimestamp(),
            updatedAt: FieldValue.serverTimestamp(),
          }, { merge: true });
        }
        tx.set(transRefRef, {
          transRef: transRefForLock,
          uid,
          paymentGroupId,
          slipFeedbackId: slipOkFeedbackId,
          expectedAmount,
          verifiedAmount: creditedAmount,
          sourceApp,
          storagePath,
          createdAt: FieldValue.serverTimestamp(),
        });
        tx.set(topUpRef, {
          ...baseTopUpUpdate,
          status: 'verified',
          creditId: creditDocId,
          transRef: transRefForLock,
        }, { merge: true });
      });
    } catch (lockError) {
      if (lockError?.code === 'SLIP_TRANS_REF_DUPLICATE') {
        const duplicateMessage = 'สลิปนี้ถูกใช้ตรวจสอบไปแล้ว';
        await topUpRef.set({
          ...baseTopUpUpdate,
          status: 'failed',
          message: duplicateMessage,
          transRef: transRefForLock,
        }, { merge: true });
        return {
          success: false,
          status: 'failed',
          message: duplicateMessage,
          expectedAmount,
          verifiedAmount: creditedAmount,
          remainingAmount,
          overpaidAmount,
          slipFeedbackId: slipOkFeedbackId,
          paymentGroupId,
        };
      }
      throw lockError;
    }

    if (creditedNow && creditedAmount > 0) {
      const targetApp = resolveTopUpTargetApp(sourceApp);
      const isSecurityDeposit = topUpPurpose === 'security_deposit';
      await db.collection('app_notifications').add({
        targetApp,
        recipientUid: uid,
        title: isSecurityDeposit ? 'ชำระเงินประกันแล้ว' : 'เติมเครดิตสำเร็จ',
        body: `+${formatShortBaht(creditedAmount)} บาท เข้ากระเป๋าแล้ว`,
        action: isSecurityDeposit ? 'security_deposit_paid' : 'top_up_verified',
        sourceApp: 'cloud_function',
        read: false,
        isRead: false,
        createdAt: FieldValue.serverTimestamp(),
      });
    }

    merchantWallet.syncMerchantWallet(uid).catch((walletError) => {
      logger.error('syncMerchantWallet after verifyTopUpSlip failed', {
        uid,
        message: walletError instanceof Error ? walletError.message : String(walletError),
      });
    });

    let securityDepositPaid = false;
    if (
      topUpPurpose === 'security_deposit'
      && merchantSecurityDepositRequiredBaht > 0
      && creditedAmount >= merchantSecurityDepositRequiredBaht
    ) {
      await db.collection('users').doc(uid).set(
        {
          merchantSecurityDepositPaid: true,
          merchantSecurityDepositPaidAt: FieldValue.serverTimestamp(),
          merchantSecurityDepositAmount: creditedAmount,
        },
        { merge: true },
      );
      securityDepositPaid = true;
    }

    return {
      success: true,
      status: verificationStatus,
      message: verificationMessage,
      expectedAmount,
      verifiedAmount: creditedAmount,
      remainingAmount,
      overpaidAmount,
      slipFeedbackId: slipOkFeedbackId,
      securityDepositPaid,
      paymentGroupId,
      creditId: creditDocId,
    };
  },
);

// getMerchantWallet / sync triggers ย้ายไป van2/functions/merchant_wallet.js
// syncMerchantWallet ใน verifyTopUpSlip ทำงานแบบ async หลังตอบ success แล้ว
