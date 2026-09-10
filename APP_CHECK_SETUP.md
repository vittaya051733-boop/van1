# Firebase App Check Troubleshooting

เมื่อเปิดแอปแล้วเจอ log ลักษณะนี้

```
[firebase_app_check/unknown] com.google.firebase.FirebaseException: Error returned from API. code: 403 body: App attestation failed.
```

แปลว่า backend ของ Firebase ปฏิเสธ token เพราะอุปกรณ์ยังไม่ได้รับสิทธิ์ App Check ตามประเภท provider ที่เลือก (Play Integrity/Debug ฯลฯ)

## ขั้นตอนสำหรับเครื่องทดสอบ/Debug

1. **Debug build** – ใช้ `AndroidDebugProvider` พร้อมรหัสคงที่ใน `lib/utils/feature_flags.dart` (`kVan1AppCheckDebugToken`) ไม่เปลี่ยนทุกครั้งที่รัน
2. **ลงทะเบียน Debug Token ครั้งเดียว** – Firebase Console → Build → App Check → แอป Android `van.merchant` → Debug tokens → Add → วางรหัสจาก log ตอนเปิดแอป (`App Check debug token (register once...)`)
3. **รอ 1-2 นาที** แล้วปิด/เปิดแอปใหม่ (ดูว่า log `Could not get App Check token...` หายไป และ Firebase API ไม่ตอบ 403)

> หากต้องการปิด App Check ชั่วคราว ให้ไปที่ App Check → Enforcement แล้วสลับเป็น “Off” สำหรับแอปนั้น ๆ (ไม่แนะนำใน production).

## ขั้นตอนสำหรับ iOS Release (TestFlight / App Store)

แอป van1 merchant iOS: `com.vantalad.merchant` · Firebase app `1:802503541368:ios:60fa52f30ee44789f6a38d`

1. **โค้ด (ทำแล้วใน repo)**  
   - Release ใช้ `AppleAppAttestWithDeviceCheckFallbackProvider`  
   - `ios/Runner/Runner.entitlements` มี `com.apple.developer.devicecheck.appattest-environment = production`

2. **Apple Developer**  
   - App ID `com.vantalad.merchant` → เปิด capability **App Attest** (Xcode automatic signing มัก sync ให้เมื่อ build)

3. **Firebase Console → Build → App Check → แอป iOS (van.merchant / com.vantalad.merchant)**  
   - ลงทะเบียน **App Attest**  
   - ลงทะเบียน **DeviceCheck** (fallback — SDK ใช้คู่กัน)  
   - Debug build: ลง **Debug token** เดียวกับ Android (`kVan1AppCheckDebugToken`)

4. **Enforcement**  
   - Cloud Functions ที่เกี่ยวกับ wallet (`verifyTopUpSlip`, `getWithdrawableBalance`, `requestManualWithdraw`, `getMerchantWallet`) ใช้ `enforceAppCheck: true` อยู่แล้ว  
   - ตรวจว่า App Check enforcement สำหรับ **Cloud Functions** ไม่ใช่ Off

5. **Build ใหม่** แล้วติดตั้ง TestFlight — attestation ผูกกับ bundle + team + build จ distribution

> TestFlight ใช้ App Attest **production** ไม่ใช้ debug token

## ขั้นตอนสำหรับ Release (Play Integrity)

1. ใน Firebase Console → App Check → เลือกแอป Android → เปิดใช้งาน **Play Integrity**.
2. ตรวจสอบว่า **SHA-256** fingerprint ของ keystore ที่ใช้ build release ถูกเพิ่มใน **Firebase console + Google Cloud console** (Project Settings → App → SHA certificate fingerprints).
3. สร้าง build release ด้วย keystore เดียวกัน แล้วติดตั้งลงเครื่องจริงที่มี Play Store (อุปกรณ์ต้อง sign-in Play Services).
4. หากยังเจอ 403 อีก ให้เปิด Logs ใน Google Cloud → Logging → `firebaseappcheck.googleapis.com` เพื่อตรวจสอบรายละเอียด attestation.

## Phone Auth (OTP) — `app-not-authorized`

ถ้า logcat มีข้อความเหล่านี้:

```
Invalid app info in play_integrity_token
No Recaptcha Enterprise siteKey configured
App attestation failed (403)
```

**SHA ถูกต้องแล้ว** แต่ OTP ยังล้มเพราะ:

1. **Play Integrity** — APK sideload / emulator ไม่ผ่าน (ปกติ)
2. **reCAPTCHA Enterprise** — ยังไม่เปิด API / ยังไม่ provision ใน Firebase Auth
3. **App Check debug token** — ยังไม่ลง allow list

### แก้ใน Firebase / Google Cloud (ทำครั้งเดียว)

1. **เปิด reCAPTCHA Enterprise API**  
   Google Cloud Console → APIs → ค้นหา `reCAPTCHA Enterprise API` → Enable  
   (project: `van-merchant`)

2. **Firebase Console → Authentication → Settings**  
   เปิดหน้านี้เพื่อให้ Firebase สร้าง reCAPTCHA key อัตโนมัติ (รอ 1–2 นาที)

3. **App Check debug token** (สำหรับ emulator/debug build)  
   Firebase Console → Build → App Check → แอป `van.merchant` (Android) → Debug tokens → Add  
   ใช้รหัสคงที่จาก log: `d1a5b8e3-7f2c-4a6d-9e1b-3c4d5e6f7a82` (หรือค่าใน `kVan1AppCheckDebugToken`)

### ทด OTP บน emulator (debug build)

1. Firebase Console → Authentication → Sign-in method → Phone → **Phone numbers for testing**  
   เพิ่มเบอร์ + OTP ที่ต้องการทด (เช่น `+817091345342` / `123456`)
2. รัน **debug build** (`appVerificationDisabledForTesting` เปิดอัตโนมัติใน `kDebugMode`)
3. ใช้เฉพาะเบอร์ที่ลงใน "Phone numbers for testing" — เบอร์จริงจะยังไม่ส่ง SMS

### Production (เบอร์จริง / sideload release)

- ต้องมี reCAPTCHA Enterprise (ข้อ 1–2 ด้านบน) **หรือ** แจก APK ผ่าน Google Play (Internal testing) เพื่อให้ Play Integrity รู้จักแอป

## สรุป

- Dev/QA → ใช้ Debug provider + ลง token **ครั้งเดียว** (รหัส pin ในโค้ด) — Android + iOS
- Android production → Play Integrity + SHA ทุกตัว (debug, release, CI)
- iOS production → App Attest (+ DeviceCheck fallback) + entitlements + ลงทะเบียน provider ใน Firebase Console
- ไม่ต้องอัปเดต token ทุกครั้งที่รัน — เปลี่ยนเมื่อ rotate keystore หรือเปลี่ยน `--dart-define=VAN1_APP_CHECK_DEBUG_TOKEN`
