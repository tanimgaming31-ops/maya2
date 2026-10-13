# Maya — ফোন-ওনলি গাইড

## ১. ফ্রি Gemini key নেওয়া
1. Chrome-এ `aistudio.google.com/apikey` খোলো, Google account দিয়ে লগইন করো।
2. **Create API key** চাপো, key কপি করো।
3. Maya অ্যাপে ⚙️ Settings → key বসাও → **Save key** → **Test key**। "Key works ✓" দেখলে ঠিক আছে।

## ২. GitHub Pages-এ ফ্রি হোস্ট (শুধু ফোনে)
1. `github.com`-এ account খোলো (Chrome → ⋮ → **Desktop site** অন করলে সহজ)।
2. **New repository** → নাম `maya` → **Public** → Create।
3. **Add file → Upload files** চাপো। এই ৫টা ফাইল সিলেক্ট করে আপলোড করো:
   `index.html`, `manifest.webmanifest`, `sw.js`, `icon-192.png`, `icon-512.png` → **Commit changes**।
4. **Settings → Pages → Source: Deploy from a branch → main / (root) → Save**।
5. ১–২ মিনিট পর লিংক পাবে: `https://তোমার-নাম.github.io/maya/`

## ৩. PWA ইনস্টল
Chrome-এ লিংক খোলো → ⋮ → **Install app** (বা **Add to Home screen**)। হোম স্ক্রিনে Maya আইকন আসবে।

## ৪. প্রথমবার ব্যবহার
- 🎤 চাপলে কল শুরু, আবার চাপলে কল শেষ। মাইক পারমিশন চাইলে **Allow**।
- নিচে টাইপ করেও কথা বলা যায়। Live voice না চললে অটো fallback voice-এ চলে যায়।
- 🧠 Memory স্ক্রিনে দেখা, এডিট, ডিলিট, এক্সপোর্ট করা যায়।

## Phase 1-এর সীমা (সৎ কথা)
Chrome থেকে অন্য অ্যাপ খুলতে **তোমার একটা ট্যাপ লাগে**। Maya বললে স্ক্রিনে জ্বলজ্বলে বাটন আসবে, সেটা ট্যাপ করলে অ্যাপ/ডায়ালার/ম্যাপ খুলবে। Settings পেজ, ক্যামেরা অ্যাপ সরাসরি খোলা অনেক ফোনে Chrome থেকে হয় না। অ্যালার্ম ও টাইমার অ্যাপ খোলা থাকলেই বাজে। এসবের পাকা সমাধান Phase 2।

## APK বানিয়ে ডাউনলোড ও যেকোনো ফোনে ইনস্টল (ফোন-ওনলি, ফ্রি)
এই ধাপগুলো উপরের GitHub repo-তেই করবে। একই repo থেকে লিংকও থাকবে, APK-ও পাবে।

1. repo-তে আরও ৩টা ফাইল আপলোড করো: `package.json`, `capacitor.config.json`, `build-apk.yml`।
2. repo-তে `build-apk.yml` খুলে ✏️ (Edit) চাপো। উপরের ফাইলনেম ঘরের শুরুতে `.github/workflows/` লিখে দাও, যাতে নাম হয় `.github/workflows/build-apk.yml`। তারপর **Commit changes**।
3. repo-র **Actions** ট্যাবে যাও। **Build Maya APK** সিলেক্ট করে **Run workflow** চাপো।
4. ৫–১০ মিনিট অপেক্ষা করো। সবুজ ✓ এলে হয়ে গেছে।
5. repo-র মূল পেজে ডানে বা নিচে **Releases** দেখবে। সেখানে `Maya.apk` ট্যাপ করলে ডাউনলোড হবে।
6. ফাইলটা খুলে ইনস্টল করো। ফোন "Install unknown apps" চাইলে Chrome-কে অনুমতি দাও।
7. এই APK ফাইল WhatsApp, Bluetooth বা Drive দিয়ে যেকোনো Android ফোনে পাঠিয়ে ইনস্টল করা যায়।

### APK-র সীমা
- এটা এখন Debug APK: Play Store-এর জন্য নয়, তবে যেকোনো ফোনে ইনস্টল হয়।
- ভেতরে একই Maya ওয়েব অ্যাপ চলে। Live voice (Gemini Live) ঠিকমতো চলবে। Android WebView-তে ব্রাউজারের SpeechRecognition নেই, তাই fallback voice আর wake word এই APK-তে কাজ করবে না।
- ব্রাইটনেস, টর্চ, মিডিয়া কন্ট্রোল, নোটিফিকেশন পড়া, সরাসরি SMS/WhatsApp সেন্ড, ব্যাকগ্রাউন্ড wake word: এগুলোর জন্য আলাদা নেটিভ প্লাগিন লাগে। সেটা পরের ধাপ।
- বিল্ড ফেইল করলে Actions-এ লাল ✗ রান খুলে শেষের এরর লেখাটা কপি করে আমাকে দিও।
