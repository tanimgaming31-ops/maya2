#!/usr/bin/env bash
# Maya native layer (stage 1): read message notifications + quick reply.
# Runs inside GitHub Actions after "npx cap add android". Safe to re-run.
set -euo pipefail

APP_DIR=android/app/src/main/java/com/tanim/maya
MANIFEST=android/app/src/main/AndroidManifest.xml
mkdir -p "$APP_DIR"
find android/app/src/main/java -name MainActivity.java -delete

# ---------------------------------------------------------------- MainActivity
cat > "$APP_DIR/MainActivity.java" <<'EOF'
package com.tanim.maya;

import android.content.Intent;
import android.os.Bundle;
import com.getcapacitor.BridgeActivity;

public class MainActivity extends BridgeActivity {
    @Override
    public void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        MayaBridge.attach(this, getBridge().getWebView());
        MayaBridge.setNudge(getIntent());
    }

    @Override
    protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        MayaBridge.setNudge(intent);
    }
}
EOF

# ------------------------------------------------------------------ MayaBridge
cat > "$APP_DIR/MayaBridge.java" <<'EOF'
package com.tanim.maya;

import android.app.Activity;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.net.Uri;
import android.provider.Settings;
import android.text.TextUtils;
import android.webkit.JavascriptInterface;
import android.webkit.WebView;
import org.json.JSONArray;
import org.json.JSONObject;

/** Small, fixed set of native functions the Maya web app may call. */
public class MayaBridge {
    private static WebView web;
    private static Context ctx;
    private static Activity act;
    private static volatile String nudge = "";

    static void attach(Activity activity, WebView webView) {
        ctx = activity.getApplicationContext();
        act = activity;
        web = webView;
        webView.addJavascriptInterface(new MayaBridge(), "MayaBridge");
    }

    static void setNudge(Intent i) {
        try {
            if (i == null) return;
            String n = i.getStringExtra("maya_nudge");
            if (n != null && n.length() > 0) {
                nudge = n;
                i.removeExtra("maya_nudge");
            }
        } catch (Exception e) {
            // ignore
        }
    }

    /** Called by the notification service when a new chat message arrives. */
    static void emit(JSONObject o) {
        final WebView w = web;
        if (w == null) return;
        final String js = "window.__mayaMsg&&window.__mayaMsg(" + o.toString() + ")";
        w.post(new Runnable() {
            @Override
            public void run() {
                w.evaluateJavascript(js, null);
            }
        });
    }

    private static boolean accessEnabled() {
        try {
            String flat = Settings.Secure.getString(ctx.getContentResolver(), "enabled_notification_listeners");
            if (TextUtils.isEmpty(flat)) return false;
            String me = ctx.getPackageName();
            for (String s : flat.split(":")) {
                ComponentName cn = ComponentName.unflattenFromString(s);
                if (cn != null && me.equals(cn.getPackageName())) return true;
            }
        } catch (Exception e) {
            // ignore
        }
        return false;
    }

    @JavascriptInterface
    public String status() {
        try {
            JSONObject o = new JSONObject();
            o.put("notificationAccess", accessEnabled());
            o.put("connected", MayaNotificationService.connected);
            return o.toString();
        } catch (Exception e) {
            return "{}";
        }
    }

    @JavascriptInterface
    public String getMessages(int limit, String app) {
        try {
            JSONArray arr = new JSONArray();
            for (MayaNotificationService.Msg m : MayaNotificationService.recent(limit, app)) {
                arr.put(m.toJson());
            }
            JSONObject o = new JSONObject();
            o.put("messages", arr);
            return o.toString();
        } catch (Exception e) {
            return "{\"messages\":[]}";
        }
    }

    /** Returns "" on success, otherwise a short error text. */
    @JavascriptInterface
    public String reply(String id, String text) {
        if (id == null || text == null || text.trim().isEmpty()) return "id and text are required";
        String err = MayaNotificationService.sendReply(ctx, id, text.trim());
        return err == null ? "" : err;
    }

    @JavascriptInterface
    public void clearMessages() {
        MayaNotificationService.clear();
    }

    @JavascriptInterface
    public void openNotificationAccess() {
        try {
            Intent i = new Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS);
            i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            ctx.startActivity(i);
        } catch (Exception e) {
            // ignore
        }
    }

    /** Phone controls (torch, volume, brightness, media keys, SMS). Returns a JSON string. */
    @JavascriptInterface
    public String control(String action, String argsJson) {
        try {
            JSONObject a = new JSONObject(argsJson == null ? "{}" : argsJson);
            return MayaControls.run(ctx, act, action, a);
        } catch (Exception e) {
            return "{\"status\":\"error\",\"message\":\"bad request\"}";
        }
    }

    @JavascriptInterface
    public String capabilities() {
        try {
            JSONObject o = new JSONObject();
            o.put("sms", ctx.checkSelfPermission(android.Manifest.permission.SEND_SMS) == android.content.pm.PackageManager.PERMISSION_GRANTED);
            o.put("writeSettings", Settings.System.canWrite(ctx));
            return o.toString();
        } catch (Exception e) {
            return "{}";
        }
    }

    /** Returns "morning", "night" or "" and clears it. */
    @JavascriptInterface
    public String takeNudge() {
        String n = nudge;
        nudge = "";
        return n;
    }

    @JavascriptInterface
    public void requestSms() {
        MayaControls.requestSmsPermission(act);
    }

    @JavascriptInterface
    public void openWriteSettings() {
        MayaControls.openWriteSettings(ctx);
    }

    @JavascriptInterface
    public void openAppInfo() {
        try {
            Intent i = new Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:" + ctx.getPackageName()));
            i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            ctx.startActivity(i);
        } catch (Exception e) {
            // ignore
        }
    }
}
EOF

# ---------------------------------------------------- MayaNotificationService
cat > "$APP_DIR/MayaNotificationService.java" <<'EOF'
package com.tanim.maya;

import android.app.Notification;
import android.app.PendingIntent;
import android.app.RemoteInput;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.os.Bundle;
import android.os.Parcelable;
import android.service.notification.NotificationListenerService;
import android.service.notification.StatusBarNotification;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.LinkedList;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import org.json.JSONObject;

/**
 * Keeps the last chat notifications in RAM only (never written to disk, never uploaded),
 * and can send a quick reply through the notification's own "Reply" action.
 */
public class MayaNotificationService extends NotificationListenerService {
    static volatile boolean connected = false;

    static final Map<String, String> APPS = new LinkedHashMap<String, String>();
    static {
        APPS.put("com.whatsapp", "WhatsApp");
        APPS.put("com.whatsapp.w4b", "WhatsApp Business");
        APPS.put("com.facebook.orca", "Messenger");
        APPS.put("com.facebook.mlite", "Messenger Lite");
        APPS.put("com.facebook.katana", "Facebook");
        APPS.put("com.facebook.lite", "Facebook Lite");
        APPS.put("com.imo.android.imoim", "IMO");
        APPS.put("com.imo.android.imous", "IMO");
        APPS.put("org.telegram.messenger", "Telegram");
        APPS.put("com.instagram.android", "Instagram");
        APPS.put("com.google.android.apps.messaging", "Messages");
        APPS.put("com.samsung.android.messaging", "Messages");
        APPS.put("com.android.mms", "Messages");
    }

    static class Msg {
        String id;
        String key;
        String app;
        String sender;
        String text;
        long time;
        Notification.Action action;

        JSONObject toJson() {
            JSONObject o = new JSONObject();
            try {
                o.put("id", id);
                o.put("app", app);
                o.put("sender", sender);
                o.put("text", text);
                o.put("time", time);
                o.put("canReply", action != null);
            } catch (Exception e) {
                // ignore
            }
            return o;
        }
    }

    private static final LinkedList<Msg> store = new LinkedList<Msg>();
    private static int seq = 0;

    static synchronized List<Msg> recent(int limit, String app) {
        List<Msg> out = new ArrayList<Msg>();
        String f = app == null ? "" : app.trim().toLowerCase(Locale.ROOT);
        for (int i = store.size() - 1; i >= 0 && out.size() < Math.max(1, limit); i--) {
            Msg m = store.get(i);
            if (f.length() == 0 || m.app.toLowerCase(Locale.ROOT).contains(f)) out.add(m);
        }
        return out;
    }

    static synchronized void clear() {
        store.clear();
    }

    /** Returns null on success, otherwise an error message. */
    static synchronized String sendReply(Context ctx, String id, String text) {
        Msg target = null;
        for (Msg m : store) {
            if (m.id.equals(id)) target = m;
        }
        if (target == null) return "Message not found (it may have expired).";
        if (target.action == null) return "This app does not allow quick replies from notifications.";
        try {
            RemoteInput[] inputs = target.action.getRemoteInputs();
            Intent intent = new Intent();
            Bundle results = new Bundle();
            for (RemoteInput r : inputs) {
                results.putCharSequence(r.getResultKey(), text);
            }
            RemoteInput.addResultsToIntent(inputs, intent, results);
            target.action.actionIntent.send(ctx, 0, intent);
            return null;
        } catch (PendingIntent.CanceledException e) {
            return "The notification was dismissed, so replying is no longer possible.";
        } catch (Exception e) {
            return "Reply failed: " + e.getMessage();
        }
    }

    private static boolean sensitive(String s) {
        String l = s.toLowerCase(Locale.ROOT);
        return l.contains("otp") || l.contains("verification code") || l.contains("one-time")
                || l.contains("password") || l.contains("passcode") || l.contains("security code")
                || l.contains("\u09aa\u09be\u09b8\u0993\u09af\u09bc\u09be\u09b0\u09cd\u09a1")
                || l.contains("\u0993\u099f\u09bf\u09aa\u09bf");
    }

    @Override
    public void onListenerConnected() {
        connected = true;
    }

    @Override
    public void onListenerDisconnected() {
        connected = false;
        try {
            requestRebind(new ComponentName(this, MayaNotificationService.class));
        } catch (Exception e) {
            // ignore
        }
    }

    @Override
    public void onNotificationPosted(StatusBarNotification sbn) {
        try {
            handle(sbn);
        } catch (Exception e) {
            // never crash the listener
        }
    }

    private void handle(StatusBarNotification sbn) {
        String pkg = sbn.getPackageName();
        String app = APPS.get(pkg);
        if (app == null) return;
        Notification n = sbn.getNotification();
        if (n == null || n.extras == null) return;
        if ((n.flags & Notification.FLAG_GROUP_SUMMARY) != 0) return;
        if ((n.flags & Notification.FLAG_ONGOING_EVENT) != 0) return;

        Bundle ex = n.extras;
        CharSequence title = ex.getCharSequence(Notification.EXTRA_TITLE);
        CharSequence text = ex.getCharSequence(Notification.EXTRA_TEXT);
        String sender = title == null ? "" : title.toString();
        String body = text == null ? "" : text.toString();

        Parcelable[] msgs = ex.getParcelableArray(Notification.EXTRA_MESSAGES);
        if (msgs != null && msgs.length > 0 && msgs[msgs.length - 1] instanceof Bundle) {
            Bundle last = (Bundle) msgs[msgs.length - 1];
            CharSequence t = last.getCharSequence("text");
            if (t != null && t.length() > 0) body = t.toString();
            CharSequence s = last.getCharSequence("sender");
            if (s != null && s.length() > 0 && !sender.contains(s.toString())) {
                sender = sender.length() == 0 ? s.toString() : sender + " (" + s + ")";
            }
        }
        if (body.trim().length() == 0) return;
        if (sensitive(body) || sensitive(sender)) return;

        Notification.Action reply = null;
        if (n.actions != null) {
            for (Notification.Action a : n.actions) {
                if (a.getRemoteInputs() != null && a.getRemoteInputs().length > 0) {
                    reply = a;
                    break;
                }
            }
        }
        if (reply == null) {
            try {
                for (Notification.Action a : new Notification.WearableExtender(n).getActions()) {
                    if (a.getRemoteInputs() != null && a.getRemoteInputs().length > 0) {
                        reply = a;
                        break;
                    }
                }
            } catch (Exception e) {
                // ignore
            }
        }

        Msg m = new Msg();
        m.key = sbn.getKey();
        m.app = app;
        m.sender = sender;
        m.text = body.length() > 600 ? body.substring(0, 600) : body;
        m.time = sbn.getPostTime();
        m.action = reply;

        synchronized (MayaNotificationService.class) {
            for (int i = store.size() - 1; i >= 0; i--) {
                Msg o = store.get(i);
                if (o.key != null && o.key.equals(m.key) && o.text.equals(m.text)) {
                    store.remove(i);
                }
            }
            m.id = "n" + (++seq);
            store.add(m);
            while (store.size() > 40) store.removeFirst();
        }
        MayaBridge.emit(m.toJson());
    }
}
EOF

# ---------------------------------------------------------------- MayaControls
cat > "$APP_DIR/MayaControls.java" <<'EOF'
package com.tanim.maya;

import android.Manifest;
import android.app.Activity;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.hardware.camera2.CameraCharacteristics;
import android.hardware.camera2.CameraManager;
import android.media.AudioManager;
import android.net.Uri;
import android.os.Build;
import android.os.SystemClock;
import android.provider.AlarmClock;
import android.provider.MediaStore;
import java.util.Locale;
import android.provider.Settings;
import android.telephony.SmsManager;
import android.view.KeyEvent;
import java.util.ArrayList;
import org.json.JSONObject;

/** Fixed list of safe phone controls. Anything not listed here is refused. */
public class MayaControls {
    private static long lastSms = 0;
    private static long hourStart = 0;
    private static int smsThisHour = 0;

    static String res(String status, String message) {
        try {
            JSONObject o = new JSONObject();
            o.put("status", status);
            o.put("message", message);
            return o.toString();
        } catch (Exception e) {
            return "{\"status\":\"error\"}";
        }
    }

    static String run(Context ctx, Activity act, String action, JSONObject a) {
        try {
            switch (action) {
                case "FLASHLIGHT_ON": return torch(ctx, true);
                case "FLASHLIGHT_OFF": return torch(ctx, false);
                case "MEDIA_PLAY": return media(ctx, KeyEvent.KEYCODE_MEDIA_PLAY);
                case "MEDIA_PAUSE": return media(ctx, KeyEvent.KEYCODE_MEDIA_PAUSE);
                case "MEDIA_NEXT": return media(ctx, KeyEvent.KEYCODE_MEDIA_NEXT);
                case "MEDIA_PREVIOUS": return media(ctx, KeyEvent.KEYCODE_MEDIA_PREVIOUS);
                case "CHANGE_MEDIA_VOLUME": return volume(ctx, a.optInt("level", -1), a.optString("direction", ""));
                case "CHANGE_BRIGHTNESS": return brightness(ctx, a.optInt("level", -1), a.optString("direction", ""));
                case "SEND_SMS": return sms(ctx, act, a.optString("phone", ""), a.optString("message", ""));
                case "OPEN_URL": return openUrl(ctx, a);
                case "OPEN_APP": return openApp(ctx, a);
                case "OPEN_CAMERA": return startSimple(ctx, new Intent(MediaStore.ACTION_IMAGE_CAPTURE), "Camera opened.");
                case "OPEN_GALLERY": return startSimple(ctx, Intent.makeMainSelectorActivity(Intent.ACTION_MAIN, Intent.CATEGORY_APP_GALLERY), "Gallery opened.");
                case "CREATE_ALARM": return alarm(ctx, a.optInt("hour", -1), a.optInt("minute", -1), a.optString("label", "Maya alarm"));
                case "START_TIMER": return timer(ctx, a.optInt("seconds", 0), a.optString("label", "Maya timer"));
                case "NUDGE_SET": return MayaNudge.set(ctx, act, a);
                default: return res("error", "Unknown action.");
            }
        } catch (Exception e) {
            return res("error", "Failed: " + e.getMessage());
        }
    }

    private static String torch(Context ctx, boolean on) throws Exception {
        CameraManager cm = (CameraManager) ctx.getSystemService(Context.CAMERA_SERVICE);
        String id = null;
        for (String c : cm.getCameraIdList()) {
            CameraCharacteristics ch = cm.getCameraCharacteristics(c);
            Boolean flash = ch.get(CameraCharacteristics.FLASH_INFO_AVAILABLE);
            Integer facing = ch.get(CameraCharacteristics.LENS_FACING);
            if (flash != null && flash.booleanValue() && facing != null && facing.intValue() == CameraCharacteristics.LENS_FACING_BACK) {
                id = c;
                break;
            }
        }
        if (id == null) return res("error", "No flashlight found on this phone.");
        cm.setTorchMode(id, on);
        return res("ok", on ? "Flashlight is on." : "Flashlight is off.");
    }

    private static String media(Context ctx, int code) throws Exception {
        AudioManager am = (AudioManager) ctx.getSystemService(Context.AUDIO_SERVICE);
        long t = SystemClock.uptimeMillis();
        am.dispatchMediaKeyEvent(new KeyEvent(t, t, KeyEvent.ACTION_DOWN, code, 0));
        am.dispatchMediaKeyEvent(new KeyEvent(t, t, KeyEvent.ACTION_UP, code, 0));
        Thread.sleep(600);
        boolean active = am.isMusicActive();
        if (code == KeyEvent.KEYCODE_MEDIA_PLAY) {
            return active ? res("ok", "Music is playing.") : res("sent", "Play key sent, but no music started. A music app may need to be open.");
        }
        if (code == KeyEvent.KEYCODE_MEDIA_PAUSE) {
            return !active ? res("ok", "Music is paused.") : res("sent", "Pause key sent, but music still seems to be playing.");
        }
        return res("sent", "Key sent to the music player. Cannot verify the track changed.");
    }

    private static String volume(Context ctx, int level, String dir) {
        AudioManager am = (AudioManager) ctx.getSystemService(Context.AUDIO_SERVICE);
        int max = am.getStreamMaxVolume(AudioManager.STREAM_MUSIC);
        int cur = am.getStreamVolume(AudioManager.STREAM_MUSIC);
        int target;
        if (level >= 0) {
            target = Math.round(Math.min(100, level) * max / 100f);
        } else {
            int step = Math.max(1, Math.round(max * 0.15f));
            target = "up".equals(dir) ? cur + step : cur - step;
        }
        target = Math.max(0, Math.min(max, target));
        am.setStreamVolume(AudioManager.STREAM_MUSIC, target, 0);
        int pct = Math.round(target * 100f / max);
        return res("ok", "Media volume is now about " + pct + " percent.");
    }

    private static String startSimple(Context ctx, Intent i, String ok) {
        try {
            i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            ctx.startActivity(i);
            return res("opened", ok);
        } catch (Exception e) {
            return res("error", "Could not open it: " + e.getMessage());
        }
    }

    private static String openUrl(Context ctx, JSONObject a) {
        String url = a.optString("url", "");
        String pkg = a.optString("pkg", "");
        String act = a.optString("intentAction", "");
        try {
            Intent i;
            if (act.length() > 0) {
                if (!act.startsWith("android.settings.")) return res("error", "That settings page is not allowed.");
                i = new Intent(act);
            } else {
                String l = url.toLowerCase(Locale.ROOT);
                if (!(l.startsWith("https://") || l.startsWith("http://") || l.startsWith("tel:") || l.startsWith("sms:") || l.startsWith("geo:"))) {
                    return res("error", "That link type is not allowed.");
                }
                i = new Intent(Intent.ACTION_VIEW, Uri.parse(url));
            }
            i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            if (act.length() == 0 && pkg.length() > 0) {
                try {
                    Intent withPkg = new Intent(i);
                    withPkg.setPackage(pkg);
                    ctx.startActivity(withPkg);
                    return res("opened", "Opened.");
                } catch (Exception e) {
                    // that app is not installed: let any app open the link
                }
            }
            ctx.startActivity(i);
            return res("opened", "Opened.");
        } catch (Exception e) {
            return res("error", "Could not open it: " + e.getMessage());
        }
    }

    private static String openApp(Context ctx, JSONObject a) {
        String pkg = a.optString("pkg", "");
        try {
            if (pkg.length() > 0) {
                Intent i = ctx.getPackageManager().getLaunchIntentForPackage(pkg);
                if (i != null) {
                    i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
                    ctx.startActivity(i);
                    return res("opened", "App opened.");
                }
            }
            if (a.optString("url", "").length() > 0) {
                String r = openUrl(ctx, a);
                return r.contains("\"opened\"") ? res("opened", "That app is not installed, so its website opened instead.") : r;
            }
            return res("error", "That app is not installed.");
        } catch (Exception e) {
            return res("error", "Could not open the app: " + e.getMessage());
        }
    }

    private static String alarm(Context ctx, int hour, int minute, String label) {
        if (hour < 0 || hour > 23 || minute < 0 || minute > 59) return res("error", "Invalid alarm time.");
        try {
            Intent i = new Intent(AlarmClock.ACTION_SET_ALARM);
            i.putExtra(AlarmClock.EXTRA_HOUR, hour);
            i.putExtra(AlarmClock.EXTRA_MINUTES, minute);
            i.putExtra(AlarmClock.EXTRA_MESSAGE, label);
            i.putExtra(AlarmClock.EXTRA_SKIP_UI, true);
            i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            ctx.startActivity(i);
            return res("sent", "The alarm was handed to the phone's Clock app.");
        } catch (Exception e) {
            return res("error", "No Clock app could take the alarm: " + e.getMessage());
        }
    }

    private static String timer(Context ctx, int seconds, String label) {
        if (seconds < 1 || seconds > 86400) return res("error", "Invalid timer length.");
        try {
            Intent i = new Intent(AlarmClock.ACTION_SET_TIMER);
            i.putExtra(AlarmClock.EXTRA_LENGTH, seconds);
            i.putExtra(AlarmClock.EXTRA_MESSAGE, label);
            i.putExtra(AlarmClock.EXTRA_SKIP_UI, true);
            i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            ctx.startActivity(i);
            return res("sent", "The timer was handed to the phone's Clock app.");
        } catch (Exception e) {
            return res("error", "No Clock app could take the timer: " + e.getMessage());
        }
    }

    static void openWriteSettings(Context ctx) {
        try {
            Intent i = new Intent(Settings.ACTION_MANAGE_WRITE_SETTINGS, Uri.parse("package:" + ctx.getPackageName()));
            i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            ctx.startActivity(i);
        } catch (Exception e) {
            // ignore
        }
    }

    private static String brightness(Context ctx, int level, String dir) {
        if (!Settings.System.canWrite(ctx)) {
            openWriteSettings(ctx);
            return res("needs_permission", "Maya needs permission to change brightness. The settings page just opened: switch Maya on, come back, then ask again.");
        }
        int cur = Settings.System.getInt(ctx.getContentResolver(), Settings.System.SCREEN_BRIGHTNESS, 128);
        int target;
        if (level >= 0) {
            target = Math.round(Math.min(100, level) * 255 / 100f);
        } else {
            target = "up".equals(dir) ? cur + 38 : cur - 38;
        }
        target = Math.max(8, Math.min(255, target));
        Settings.System.putInt(ctx.getContentResolver(), Settings.System.SCREEN_BRIGHTNESS_MODE, Settings.System.SCREEN_BRIGHTNESS_MODE_MANUAL);
        Settings.System.putInt(ctx.getContentResolver(), Settings.System.SCREEN_BRIGHTNESS, target);
        return res("ok", "Brightness is now about " + Math.round(target * 100f / 255) + " percent.");
    }

    static void requestSmsPermission(final Activity act) {
        if (act == null) return;
        act.runOnUiThread(new Runnable() {
            @Override
            public void run() {
                act.requestPermissions(new String[] { Manifest.permission.SEND_SMS }, 7701);
            }
        });
    }

    private static String sms(Context ctx, Activity act, String phone, String text) {
        if (phone.length() == 0 || text.length() == 0) return res("error", "A phone number and a message are required.");
        if (ctx.checkSelfPermission(Manifest.permission.SEND_SMS) != PackageManager.PERMISSION_GRANTED) {
            requestSmsPermission(act);
            return res("needs_permission", "SMS permission is needed. Android is asking now: allow it, then ask Maya again.");
        }
        long now = System.currentTimeMillis();
        if (now - hourStart > 3600000L) {
            hourStart = now;
            smsThisHour = 0;
        }
        if (smsThisHour >= 20) return res("error", "Too many texts this hour. Maya stopped to be safe.");
        if (now - lastSms < 8000L) return res("error", "Please wait a few seconds before sending another text.");
        SmsManager sm = Build.VERSION.SDK_INT >= 31 ? ctx.getSystemService(SmsManager.class) : SmsManager.getDefault();
        ArrayList<String> parts = sm.divideMessage(text);
        if (parts.size() > 1) {
            sm.sendMultipartTextMessage(phone, null, parts, null, null);
        } else {
            sm.sendTextMessage(phone, null, text, null, null);
        }
        lastSms = now;
        smsThisHour++;
        return res("sent", "The text was handed to the phone's SMS system. Delivery cannot be verified.");
    }
}
EOF

for P in SEND_SMS WRITE_SETTINGS; do
  if ! grep -q "android.permission.$P" "$MANIFEST"; then
    sed -i "s#<application#<uses-permission android:name=\"android.permission.$P\" />\n    <application#" "$MANIFEST"
  fi
done

# ------------------------------------------------------------------ MayaNudge
cat > "$APP_DIR/MayaNudge.java" <<'EOF'
package com.tanim.maya;

import android.app.Activity;
import android.app.AlarmManager;
import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.PackageManager;
import android.os.Build;
import java.util.Calendar;
import java.util.Map;
import org.json.JSONObject;

/** Daily "Maya reaches out" notifications (morning / night). Tapping one opens Maya. */
public class MayaNudge extends BroadcastReceiver {
    private static final String CHANNEL = "maya_nudges";
    private static final String PREFS = "maya_nudges";

    private static SharedPreferences prefs(Context ctx) {
        return ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
    }

    @Override
    public void onReceive(Context ctx, Intent intent) {
        try {
            if (Intent.ACTION_BOOT_COMPLETED.equals(intent.getAction())) {
                rearmAll(ctx);
                return;
            }
            String id = intent.getStringExtra("id");
            if (id == null) return;
            String data = prefs(ctx).getString("n." + id, null);
            if (data == null) return;
            String[] p = data.split("\\|", 3);
            int h = Integer.parseInt(p[0]);
            int m = Integer.parseInt(p[1]);
            String text = p.length > 2 ? p[2] : "Maya is waiting to talk";
            post(ctx, id, text);
            arm(ctx, id, h, m);
        } catch (Exception e) {
            // never crash a receiver
        }
    }

    private static void rearmAll(Context ctx) {
        for (Map.Entry<String, ?> e : prefs(ctx).getAll().entrySet()) {
            try {
                if (!e.getKey().startsWith("n.")) continue;
                String id = e.getKey().substring(2);
                String[] p = String.valueOf(e.getValue()).split("\\|", 3);
                arm(ctx, id, Integer.parseInt(p[0]), Integer.parseInt(p[1]));
            } catch (Exception ex) {
                // skip a bad entry
            }
        }
    }

    private static PendingIntent pending(Context ctx, String id) {
        Intent i = new Intent(ctx, MayaNudge.class);
        i.putExtra("id", id);
        return PendingIntent.getBroadcast(ctx, id.hashCode(), i, PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
    }

    private static void arm(Context ctx, String id, int hour, int minute) {
        Calendar c = Calendar.getInstance();
        c.set(Calendar.HOUR_OF_DAY, hour);
        c.set(Calendar.MINUTE, minute);
        c.set(Calendar.SECOND, 0);
        c.set(Calendar.MILLISECOND, 0);
        if (c.getTimeInMillis() <= System.currentTimeMillis() + 1000L) c.add(Calendar.DAY_OF_YEAR, 1);
        AlarmManager am = (AlarmManager) ctx.getSystemService(Context.ALARM_SERVICE);
        if (am == null) return;
        if (Build.VERSION.SDK_INT >= 23) {
            am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, c.getTimeInMillis(), pending(ctx, id));
        } else {
            am.set(AlarmManager.RTC_WAKEUP, c.getTimeInMillis(), pending(ctx, id));
        }
    }

    private static void cancel(Context ctx, String id) {
        AlarmManager am = (AlarmManager) ctx.getSystemService(Context.ALARM_SERVICE);
        if (am != null) am.cancel(pending(ctx, id));
    }

    private static void post(Context ctx, String id, String text) {
        NotificationManager nm = (NotificationManager) ctx.getSystemService(Context.NOTIFICATION_SERVICE);
        if (nm == null) return;
        if (Build.VERSION.SDK_INT >= 26) {
            nm.createNotificationChannel(new NotificationChannel(CHANNEL, "Maya reaches out", NotificationManager.IMPORTANCE_DEFAULT));
        }
        Intent launch = ctx.getPackageManager().getLaunchIntentForPackage(ctx.getPackageName());
        if (launch == null) return;
        launch.putExtra("maya_nudge", id);
        launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_CLEAR_TOP);
        PendingIntent pi = PendingIntent.getActivity(ctx, id.hashCode(), launch, PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
        Notification.Builder b = Build.VERSION.SDK_INT >= 26 ? new Notification.Builder(ctx, CHANNEL) : new Notification.Builder(ctx);
        b.setContentTitle("Maya");
        b.setContentText(text);
        b.setSmallIcon(ctx.getApplicationInfo().icon);
        b.setContentIntent(pi);
        b.setAutoCancel(true);
        nm.notify(id.hashCode(), b.build());
    }

    static String set(Context ctx, final Activity act, JSONObject a) {
        String id = a.optString("id", "");
        if (!id.equals("morning") && !id.equals("night")) return MayaControls.res("error", "Unknown nudge.");
        if (!a.optBoolean("on", false)) {
            prefs(ctx).edit().remove("n." + id).apply();
            cancel(ctx, id);
            return MayaControls.res("ok", "Turned off.");
        }
        int h = a.optInt("hour", -1);
        int m = a.optInt("minute", -1);
        if (h < 0 || h > 23 || m < 0 || m > 59) return MayaControls.res("error", "Invalid time.");
        String text = a.optString("text", "Maya is waiting to talk").replace("|", " ");
        prefs(ctx).edit().putString("n." + id, h + "|" + m + "|" + text).apply();
        if (Build.VERSION.SDK_INT >= 33 && act != null
                && ctx.checkSelfPermission("android.permission.POST_NOTIFICATIONS") != PackageManager.PERMISSION_GRANTED) {
            act.runOnUiThread(new Runnable() {
                @Override
                public void run() {
                    act.requestPermissions(new String[] { "android.permission.POST_NOTIFICATIONS" }, 7702);
                }
            });
        }
        arm(ctx, id, h, m);
        return MayaControls.res("ok", "Scheduled.");
    }
}
EOF

for P in android.permission.POST_NOTIFICATIONS android.permission.RECEIVE_BOOT_COMPLETED com.android.alarm.permission.SET_ALARM; do
  if ! grep -q "name=\"$P\"" "$MANIFEST"; then
    sed -i "s#<application#<uses-permission android:name=\"$P\" />\n    <application#" "$MANIFEST"
  fi
done
if ! grep -q "<queries>" "$MANIFEST"; then
  sed -i 's#<application#<queries>\n        <intent>\n            <action android:name="android.intent.action.MAIN" />\n            <category android:name="android.intent.category.LAUNCHER" />\n        </intent>\n    </queries>\n    <application#' "$MANIFEST"
fi
if ! grep -q "com.tanim.maya.MayaNudge" "$MANIFEST"; then
  sed -i 's#</application>#        <receiver android:name="com.tanim.maya.MayaNudge" android:exported="false">\n            <intent-filter>\n                <action android:name="android.intent.action.BOOT_COMPLETED" />\n            </intent-filter>\n        </receiver>\n    </application>#' "$MANIFEST"
fi

# ------------------------------------------------- manifest: listener service
if ! grep -q MayaNotificationService "$MANIFEST"; then
  sed -i 's#</application>#        <service android:name="com.tanim.maya.MayaNotificationService" android:exported="true" android:label="Maya" android:permission="android.permission.BIND_NOTIFICATION_LISTENER_SERVICE">\n            <intent-filter>\n                <action android:name="android.service.notification.NotificationListenerService" />\n            </intent-filter>\n        </service>\n    </application>#' "$MANIFEST"
fi

# ----------------------------------- stable signing key (so updates install over)
if [ -f maya-debug.keystore ] && ! grep -q maya-debug.keystore android/app/build.gradle; then
  sed -i '0,/^android {/s##android {\n    signingConfigs {\n        debug {\n            storeFile file("../../maya-debug.keystore")\n            storePassword "android"\n            keyAlias "androiddebugkey"\n            keyPassword "android"\n        }\n    }#' android/app/build.gradle
fi

echo "== native setup done =="
grep -n "MayaNotificationService" "$MANIFEST" || true
grep -n "maya-debug.keystore" android/app/build.gradle || true
