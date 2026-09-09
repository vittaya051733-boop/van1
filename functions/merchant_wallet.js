const MERCHANT_WALLETS_COLLECTION = 'merchant_wallets';
const MERCHANT_SECURITY_DEPOSIT_AMOUNT = 1000;
const SETTLEMENT_DOC_PATH = 'platform_config/settlement';

function readMerchantWithdrawMode(data) {
  const raw = String(data?.merchantWithdrawMode || '').trim().toLowerCase();
  return raw === 'omise' ? 'omise' : 'credits';
}

async function loadMerchantWithdrawMode() {
  try {
    const snap = await db.doc(SETTLEMENT_DOC_PATH).get();
    return readMerchantWithdrawMode(snap.data());
  } catch (_) {
    return 'credits';
  }
}

let db;
let FieldValue;
let HttpsError;
let onCall;
let onDocumentWritten;
let logger;
let DEFAULT_REGION;

function init(deps) {
  db = deps.db;
  FieldValue = deps.FieldValue;
  HttpsError = deps.HttpsError;
  onCall = deps.onCall;
  onDocumentWritten = deps.onDocumentWritten;
  logger = deps.logger;
  DEFAULT_REGION = deps.DEFAULT_REGION;
}

function readMoney(value) {
  if (typeof value === 'number' && Number.isFinite(value)) {
    return value;
  }
  if (typeof value === 'string') {
    const parsed = Number.parseFloat(value.trim());
    return Number.isFinite(parsed) ? parsed : 0;
  }
  return 0;
}

function isContractCancelled(contractData, userData) {
  const contract = contractData && typeof contractData === 'object' ? contractData : {};
  const user = userData && typeof userData === 'object' ? userData : {};

  if (user.contractCancelledAt != null) {
    return true;
  }
  if (String(user.contractStatus || '').trim().toLowerCase() === 'cancelled') {
    return true;
  }

  const contractStatus = String(contract.status || '').trim().toLowerCase();
  if (contractStatus === 'cancelled' || contractStatus === 'terminated') {
    return true;
  }
  if (contract.cancelledAt != null || contract.contractCancelledAt != null) {
    return true;
  }
  return false;
}

function resolveSecurityDepositAmount(userData) {
  const user = userData && typeof userData === 'object' ? userData : {};
  const explicit = readMoney(user.merchantSecurityDepositAmount);
  if (explicit > 0) {
    return explicit;
  }
  if (user.merchantSecurityDepositPaid === true) {
    return MERCHANT_SECURITY_DEPOSIT_AMOUNT;
  }
  return 0;
}

function buildWalletFields(
  totalCredit,
  contractData,
  userData,
  walletData = {},
  merchantWithdrawMode = 'credits',
) {
  const isCancelled = isContractCancelled(contractData, userData);
  const omiseWithdrawable = readMoney(walletData.omiseWithdrawableCredit);
  const omiseLocked = readMoney(walletData.omiseLockedCredit);
  const omisePending = readMoney(walletData.omisePendingCredit);
  const securityDepositAmount = resolveSecurityDepositAmount(userData);
  const omiseFields = {
    omiseWithdrawableCredit: omiseWithdrawable,
    omiseLockedCredit: omiseLocked,
    omisePendingCredit: omisePending,
    merchantWithdrawMode,
  };

  if (merchantWithdrawMode === 'credits') {
    const withdrawableCredit = Math.max(0, totalCredit);
    return {
      totalCredit,
      withdrawableCredit,
      lockedCredit: 0,
      canWithdraw: withdrawableCredit > 0,
      isContractCancelled: isCancelled,
      contractStatus: isCancelled ? 'cancelled' : 'active',
      securityDepositAmount,
      securityDepositPaid: userData?.merchantSecurityDepositPaid === true,
      ...omiseFields,
    };
  }

  if (isCancelled) {
    const withdrawableCredit = totalCredit + omiseWithdrawable;
    return {
      totalCredit,
      withdrawableCredit,
      lockedCredit: omiseLocked,
      canWithdraw: withdrawableCredit > 0,
      isContractCancelled: true,
      contractStatus: 'cancelled',
      securityDepositAmount,
      securityDepositPaid: userData?.merchantSecurityDepositPaid === true,
      ...omiseFields,
    };
  }

  return {
    totalCredit,
    withdrawableCredit: omiseWithdrawable,
    lockedCredit: totalCredit + omiseLocked,
    canWithdraw: omiseWithdrawable > 0,
    isContractCancelled: false,
    contractStatus: 'active',
    securityDepositAmount,
    securityDepositPaid: userData?.merchantSecurityDepositPaid === true,
    ...omiseFields,
  };
}

async function sumCredits(uid) {
  const snapshot = await db.collection('credits').where('uid', '==', uid).get();
  let total = 0;
  for (const doc of snapshot.docs) {
    total += readMoney(doc.data()?.amount);
  }
  return total;
}

async function loadContractAndUser(uid) {
  const [userDoc, contractDoc] = await Promise.all([
    db.collection('users').doc(uid).get(),
    db.collection('contracts').doc(uid).get(),
  ]);
  return {
    userData: userDoc.exists ? userDoc.data() || {} : {},
    contractData: contractDoc.exists ? contractDoc.data() || {} : {},
  };
}

function walletDocToResponse(uid, data) {
  return {
    uid,
    totalCredit: readMoney(data?.totalCredit),
    withdrawableCredit: readMoney(data?.withdrawableCredit),
    lockedCredit: readMoney(data?.lockedCredit),
    canWithdraw: data?.canWithdraw === true,
    isContractCancelled: data?.isContractCancelled === true,
    contractStatus: String(data?.contractStatus || 'active'),
    securityDepositAmount: readMoney(data?.securityDepositAmount),
    securityDepositPaid: data?.securityDepositPaid === true,
    omiseWithdrawableCredit: readMoney(data?.omiseWithdrawableCredit),
    omiseLockedCredit: readMoney(data?.omiseLockedCredit),
    omisePendingCredit: readMoney(data?.omisePendingCredit),
    updatedAt: data?.updatedAt || null,
  };
}

async function syncMerchantWallet(uid) {
  const trimmedUid = String(uid || '').trim();
  if (!trimmedUid) {
    throw new Error('merchant uid is required');
  }

  const [totalCredit, profile, walletDoc, merchantWithdrawMode] = await Promise.all([
    sumCredits(trimmedUid),
    loadContractAndUser(trimmedUid),
    db.collection(MERCHANT_WALLETS_COLLECTION).doc(trimmedUid).get(),
    loadMerchantWithdrawMode(),
  ]);

  const walletFields = buildWalletFields(
    totalCredit,
    profile.contractData,
    profile.userData,
    walletDoc.exists ? walletDoc.data() || {} : {},
    merchantWithdrawMode,
  );

  const walletRef = db.collection(MERCHANT_WALLETS_COLLECTION).doc(trimmedUid);
  const payload = {
    uid: trimmedUid,
    ...walletFields,
    syncedBy: 'cloud_function',
    updatedAt: FieldValue.serverTimestamp(),
  };

  await walletRef.set(payload, { merge: true });
  return walletFields;
}

async function isPrivilegedAdminAuth(auth) {
  if (!auth?.uid) {
    return false;
  }
  if (auth.token?.admin === true) {
    return true;
  }
  const email = String(auth.token?.email || '').trim().toLowerCase();
  if (!email) {
    return false;
  }
  const adminDoc = await db.collection('admins').doc(email).get();
  if (!adminDoc.exists) {
    return false;
  }
  return adminDoc.data()?.active !== false;
}

async function assertPrivilegedAdmin(request) {
  if (!(await isPrivilegedAdminAuth(request.auth))) {
    throw new HttpsError('permission-denied', 'ต้องเป็นแอดมินเท่านั้น');
  }
}

function registerHandlers() {
  const getMerchantWallet = onCall(
    { region: DEFAULT_REGION },
    async (request) => {
      if (!request.auth?.uid) {
        throw new HttpsError('unauthenticated', 'กรุณาเข้าสู่ระบบ');
      }

      const requestedUid = String(request.data?.merchantUid || request.data?.uid || '').trim();
      const targetUid = requestedUid || request.auth.uid;
      const callerIsAdmin = await isPrivilegedAdminAuth(request.auth);

      if (targetUid !== request.auth.uid && !callerIsAdmin) {
        throw new HttpsError('permission-denied', 'ไม่สามารถดูกระเป๋าเงินของผู้อื่นได้');
      }

      await syncMerchantWallet(targetUid);
      const walletDoc = await db.collection(MERCHANT_WALLETS_COLLECTION).doc(targetUid).get();
      return walletDocToResponse(targetUid, walletDoc.data() || {});
    },
  );

  const adminCancelMerchantContract = onCall(
    { region: DEFAULT_REGION },
    async (request) => {
      await assertPrivilegedAdmin(request);

      const merchantUid = String(request.data?.merchantUid || '').trim();
      const reason = String(request.data?.reason || '').trim();

      if (!merchantUid) {
        throw new HttpsError('invalid-argument', 'กรุณาระบุ merchantUid');
      }

      const contractRef = db.collection('contracts').doc(merchantUid);
      const userRef = db.collection('users').doc(merchantUid);
      const now = FieldValue.serverTimestamp();
      const adminUid = request.auth.uid;

      await db.runTransaction(async (tx) => {
        const [contractDoc, userDoc] = await Promise.all([
          tx.get(contractRef),
          tx.get(userRef),
        ]);

        const contractData = contractDoc.exists ? contractDoc.data() || {} : {};
        if (isContractCancelled(contractData, userDoc.exists ? userDoc.data() || {} : {})) {
          return;
        }

        tx.set(
          contractRef,
          {
            status: 'cancelled',
            cancelledAt: now,
            contractCancelledAt: now,
            cancelledByAdminUid: adminUid,
            cancellationReason: reason || null,
            updatedAt: now,
          },
          { merge: true },
        );

        tx.set(
          userRef,
          {
            contractStatus: 'cancelled',
            contractCancelledAt: now,
            contractCancelledByAdminUid: adminUid,
            contractCancellationReason: reason || null,
            updatedAt: now,
          },
          { merge: true },
        );
      });

      const walletFields = await syncMerchantWallet(merchantUid);

      await db.collection('app_notifications').add({
        targetApp: 'van1',
        recipientUid: merchantUid,
        title: 'ยกเลิกสัญญาร้านแล้ว',
        body: reason
          ? 'แอดมินยกเลิกสัญญาร้านแล้ว — คุณสามารถถอนเครดิตได้ตามเงื่อนไข'
          : 'แอดมินยกเลิกสัญญาร้านแล้ว — คุณสามารถถอนเครดิตได้ตามเงื่อนไข',
        action: 'merchant_contract_cancelled',
        sourceApp: 'van4_admin',
        senderId: adminUid,
        read: false,
        isRead: false,
        createdAt: FieldValue.serverTimestamp(),
      });

      return {
        success: true,
        merchantUid,
        reason,
        wallet: walletFields,
      };
    },
  );

  const syncMerchantWalletOnCreditWrite = onDocumentWritten(
    {
      document: 'credits/{creditId}',
      region: DEFAULT_REGION,
    },
    async (event) => {
      const afterUid = String(event.data?.after?.data()?.uid || '').trim();
      const beforeUid = String(event.data?.before?.data()?.uid || '').trim();
      const uid = afterUid || beforeUid;
      if (!uid) {
        return;
      }
      try {
        await syncMerchantWallet(uid);
      } catch (error) {
        logger.error('syncMerchantWalletOnCreditWrite failed', {
          uid,
          creditId: event.params?.creditId,
          message: error instanceof Error ? error.message : String(error),
        });
      }
    },
  );

  const syncMerchantWalletOnContractWrite = onDocumentWritten(
    {
      document: 'contracts/{userId}',
      region: DEFAULT_REGION,
    },
    async (event) => {
      const uid = String(event.params?.userId || '').trim();
      if (!uid) {
        return;
      }
      try {
        await syncMerchantWallet(uid);
      } catch (error) {
        logger.error('syncMerchantWalletOnContractWrite failed', {
          uid,
          message: error instanceof Error ? error.message : String(error),
        });
      }
    },
  );

  return {
    getMerchantWallet,
    adminCancelMerchantContract,
    syncMerchantWalletOnCreditWrite,
    syncMerchantWalletOnContractWrite,
  };
}

module.exports = {
  init,
  syncMerchantWallet,
  registerHandlers,
  MERCHANT_WALLETS_COLLECTION,
};
