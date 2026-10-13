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

import android.os.Bundle;
import com.getcapacitor.BridgeActivity;

public class MainActivity extends BridgeActivity {
    @Override
    public void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        MayaBridge.attach(this, getBridge().getWebView());
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

    static void attach(Activity activity, WebView webView) {
        ctx = activity.getApplicationContext();
        web = webView;
        webView.addJavascriptInterface(new MayaBridge(), "MayaBridge");
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
