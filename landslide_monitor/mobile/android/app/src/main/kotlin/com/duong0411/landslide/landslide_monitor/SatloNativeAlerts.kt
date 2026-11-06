package com.duong0411.landslide.landslide_monitor

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.graphics.Color
import android.media.AudioAttributes
import android.media.RingtoneManager
import android.os.Build
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import org.json.JSONObject

/**
 * Thông báo heads-up kiểu Facebook (banner riêng), không dùng thanh FGS.
 * Dart chỉ cần ghi key [PREF_KEY] vào Flutter SharedPreferences.
 */
object SatloNativeAlerts {
    private const val TAG = "SatloNativeAlerts"
    private const val PREFS_NAME = "FlutterSharedPreferences"
    private const val PREF_KEY = "flutter.satlo_push_alert"
    private const val CHANNEL_ID = "satlo_facebook_v1"
    private const val CHANNEL_NAME = "Thông báo cảnh báo"
    private var notifId = 7100

    fun install(app: Context) {
        ensureChannel(app)
        val prefs = app.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        prefs.registerOnSharedPreferenceChangeListener { p, key ->
            if (key == PREF_KEY) {
                val raw = p.getString(PREF_KEY, null) ?: return@registerOnSharedPreferenceChangeListener
                showFromJson(app, raw)
            }
        }
        // Nếu còn payload treo từ lần trước
        prefs.getString(PREF_KEY, null)?.let { showFromJson(app, it) }
        Log.i(TAG, "installed listener on $PREF_KEY")
    }

    /** Gọi trực tiếp từ nơi khác nếu cần. */
    fun show(app: Context, title: String, body: String, type: String = "ALERT") {
        ensureChannel(app)
        val launch = app.packageManager.getLaunchIntentForPackage(app.packageName)
            ?: Intent(app, MainActivity::class.java)
        launch.flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
        val piFlags = PendingIntent.FLAG_UPDATE_CURRENT or
            if (Build.VERSION.SDK_INT >= 23) PendingIntent.FLAG_IMMUTABLE else 0
        val pi = PendingIntent.getActivity(app, notifId, launch, piFlags)

        val sound = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION)
        val builder = NotificationCompat.Builder(app, CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body).setBigContentTitle(title))
            .setPriority(NotificationCompat.PRIORITY_MAX)
            .setCategory(NotificationCompat.CATEGORY_ALARM)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setAutoCancel(true)
            .setOnlyAlertOnce(false)
            .setSound(sound)
            .setVibrate(longArrayOf(0, 400, 180, 400, 180, 400))
            .setLights(Color.parseColor("#EE4D2D"), 800, 400)
            .setContentIntent(pi)
            .setDefaults(NotificationCompat.DEFAULT_ALL)

        if (type.equals("SAT_LO", ignoreCase = true)) {
            builder.setFullScreenIntent(pi, true)
        }

        try {
            NotificationManagerCompat.from(app).notify(notifId++, builder.build())
            Log.i(TAG, "posted facebook-style alert: $title")
        } catch (e: SecurityException) {
            Log.e(TAG, "POST_NOTIFICATIONS denied", e)
        }
    }

    private fun showFromJson(app: Context, raw: String) {
        try {
            val j = JSONObject(raw)
            val title = j.optString("title", "⚠️ Cảnh báo SATLO")
            val body = j.optString("body", "Gateway đang báo động.")
            val type = j.optString("type", "ALERT")
            if (title.isBlank() && body.isBlank()) return
            show(app, title, body, type)
        } catch (e: Exception) {
            Log.e(TAG, "bad json: $raw", e)
        }
    }

    private fun ensureChannel(app: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val mgr = app.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (mgr.getNotificationChannel(CHANNEL_ID) != null) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            CHANNEL_NAME,
            NotificationManager.IMPORTANCE_HIGH,
        ).apply {
            description = "Cảnh báo lũ/sạt lở — hiện banner như Facebook khi tắt app"
            enableVibration(true)
            vibrationPattern = longArrayOf(0, 400, 180, 400, 180, 400)
            enableLights(true)
            lightColor = Color.parseColor("#EE4D2D")
            setShowBadge(true)
            val sound = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION)
            val attrs = AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_NOTIFICATION)
                .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                .build()
            setSound(sound, attrs)
            lockscreenVisibility = android.app.Notification.VISIBILITY_PUBLIC
        }
        mgr.createNotificationChannel(channel)
    }
}
