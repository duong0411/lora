package com.duong0411.landslide.landslide_monitor

import android.app.Application

/** Giữ listener native — bắn thông báo kiểu Facebook khi Dart ghi SharedPreferences. */
class SatloApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        SatloNativeAlerts.install(this)
    }
}
