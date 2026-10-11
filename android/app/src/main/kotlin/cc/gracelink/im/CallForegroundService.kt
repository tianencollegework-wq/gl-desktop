package cc.gracelink.im

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder

/**
 * 通话期间的前台服务（S6.5）。
 *
 * 为什么需要它：Flutter 页面切到后台之后，进程随时可能被系统冻结 —— WebRTC 的媒体
 * 与 WS 信令就断在那儿，对方听到的是「打一半没了」。安卓的解法只有一个：通话期间
 * 挂一个**带常驻通知的前台服务**（用户可见、系统不冻结）。
 *
 * 为什么自己写而不是用插件：这个需求的难点不是代码量，而是**时机与合规**（必须真的
 * 在用麦克风时才起、必须由前台 UI 触发、每条结束路径都要停干净），而这些恰恰要由
 * 我们控制；通用保活插件还会把 dataSync 类型、后台启动限制一并引进来。见 REFACTOR_PLAN 的 S6.5。
 *
 * 三条 Android 规矩（写在这里省得以后再查）：
 * 1. **API 29+ 必须带 `foregroundServiceType`**，而且类型要与真实用途一致
 *    （语音通话 → microphone；视频通话再 | camera）；
 * 2. **Android 14+ 不允许从后台启动 mic/camera 类型的前台服务** —— 所以只在
 *    「已经拿到媒体、App 还开着」时启动（`CallController._openMedia`）；
 * 3. 通知在 API 26+ 必须挂在渠道上（这里的渠道是 LOW：不响、不震、不打扰）。
 *
 * ⚠️ 服务必须**停得干净**：漏掉一条结束路径就会留下「麦克风正在使用」的常驻通知
 * （用户会当成病毒）。对应的单测在 `test/call/call_controller_test.dart`。
 */
class CallForegroundService : Service() {

    /** 这一通的现状：共享屏幕时要重新 startForeground（类型多一位、文案换一句）。 */
    private var video = false
    private var title = ""
    private var text = ""
    private var sharing = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> {
                video = intent.getBooleanExtra(EXTRA_VIDEO, false)
                title = intent.getStringExtra(EXTRA_TITLE).orEmpty()
                text = intent.getStringExtra(EXTRA_TEXT).orEmpty()
                sharing = false
                startAsForeground()
            }
            // 屏幕共享（S6.7）：**同一个服务**再多带一个类型位，不是第二个服务
            ACTION_SHARING -> {
                sharing = intent.getBooleanExtra(EXTRA_SHARING, false)
                val notice = intent.getStringExtra(EXTRA_TEXT).orEmpty()
                if (notice.isNotEmpty()) text = notice
                startAsForeground()
            }
            ACTION_STOP -> stopAsForeground()
            else -> {
                // 没有动作的启动（比如系统重启服务）不该留下一个空通知
                stopSelf()
            }
        }
        // 进程被杀不用系统重启：通话早就断了，重启只会给用户留个假通知
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        running = false
        types = 0
        super.onDestroy()
    }

    private fun startAsForeground() {
        createChannelIfNeeded()
        val notification = buildNotification(title, text)
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                // 类型位可以重复 startForeground 更新：共享屏幕就是在这里多一位
                // （Android 14 要求：取 MediaProjection 之前必须有带该类型的服务在跑）
                startForeground(NOTIFICATION_ID, notification, serviceType())
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
            lastError = ""
            // 类型位**必须能读回**：Dart 侧要等到它真的包含 mediaProjection 才敢
            // 去 `getDisplayMedia`（`startForeground` 是异步的，见 [types] 的说明）
            types = serviceType()
            running = true
        } catch (error: Exception) {
            // ⚠️ 2026-09-19 真机踩出来的坑（三星 S23 Ultra / Android 14）：
            // startForeground **会抛**！典型是 while-in-use 校验
            // （`validateForegroundServiceType`：mic 类型的前台服务不允许从后台起，
            // 比如「通知权限框把 App 顶到后台」的那一瞬间）。
            // 不接住的话整个应用进程当场死掉（用户看到的就是「打了个电话闪退」）。
            // 这里只记原因并退出服务 —— 通话本身照旧，保活失败不该拖垮 App。
            lastError = error.message ?: error.toString()
            running = false
            types = 0
            stopSelf()
        }
    }

    private fun stopAsForeground() {
        try {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } catch (error: Exception) {
            lastError = error.message ?: error.toString()
        }
        running = false
        types = 0
        stopSelf()
    }

    /**
     * 与真实用途一致的类型位（语音只有麦克风，视频再加摄像头，共享屏幕再加投影）。
     *
     * 一个前台服务可以同时带多个类型 —— 所以共享屏幕**不需要**第二个服务、
     * 也不会多出第二条通知（用户要的就是这种“安静”的实现）。
     */
    private fun serviceType(): Int {
        var type = ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
        if (video) type = type or ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA
        if (sharing) type = type or ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION
        return type
    }

    private fun buildNotification(title: String, text: String): Notification {
        // 点通知回到 App（MainActivity 已经是 singleTop，不会叠出一个新的）
        val tapIntent = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        @Suppress("DEPRECATION")
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            Notification.Builder(this)
        }
        return builder
            .setSmallIcon(R.drawable.ic_call_notify)
            .setContentTitle(title)
            .setContentText(text)
            .setContentIntent(tapIntent)
            // 通话没结束就一直在（用户划掉之后服务照跑，Android 14 也是这样）
            .setOngoing(true)
            .setShowWhen(false)
            .setCategory(Notification.CATEGORY_CALL)
            .build()
    }

    private fun createChannelIfNeeded() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        // 清掉历史上用过的渠道 id（通知渠道**一旦创建，重要性/声音就改不了**，
        // 所以那边只能靠换 id 拿到新设置，旧的就没人用了）：
        //   * `gracelinkim_call` —— 第一版与 Dart 那边的来电渠道撞了同一个 id，
        //     被这个服务先创成 LOW + 静音，来电通知于是永远没有横幅/声音/全屏；
        //   * `gracelinkim_call_incoming` —— 第二版（重要性已经对了），但铃声是默认
        //     通知提示音；来电已换到 `gracelinkim_call_ring`（系统来电铃声）。
        LEGACY_CHANNEL_IDS.forEach(manager::deleteNotificationChannel)
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            getString(R.string.call_service_channel_name),
            // 这条只是「通话正在跑」的常驻通知：低优先级 + 静音才是对的（不响不弹）
            NotificationManager.IMPORTANCE_LOW,
        )
        channel.description = getString(R.string.call_service_channel_description)
        channel.setShowBadge(false)
        channel.enableVibration(false)
        channel.setSound(null, null)
        manager.createNotificationChannel(channel)
    }

    companion object {
        const val ACTION_START = "cc.gracelink.im.call.START"
        const val ACTION_STOP = "cc.gracelink.im.call.STOP"
        const val ACTION_SHARING = "cc.gracelink.im.call.SHARING"
        const val EXTRA_VIDEO = "video"
        const val EXTRA_TITLE = "title"
        const val EXTRA_TEXT = "text"
        const val EXTRA_SHARING = "sharing"

        /**
         * 前台服务的常驻通知渠道。
         *
         * **必须与 Dart 那边的来电渠道分开**（见 `LocalMessageNotificationPresenter.callChannelId`）：
         * 渠道的重要性由**第一次创建它的那次**决定，之后谁都改不了。过去两边共用
         * `gracelinkim_call`，而这个服务先把它创成了 LOW + 静音 —— 来电通知于是永远
         * 没有声音、没有横幅、全屏也不生效。
         */
        private const val CHANNEL_ID = "gracelinkim_call_service"

        /** 旧版用过、现在只剩清理的渠道 id（见 [createChannelIfNeeded]） */
        private val LEGACY_CHANNEL_IDS = listOf(
            "gracelinkim_call",           // 第一版：与来电通知撞 id，被创成低优先级静音
            "gracelinkim_call_incoming", // 第二版：重要性对了，但铃声是通知提示音
        )

        private const val NOTIFICATION_ID = 20260919

        /**
         * 服务是不是在跑。
         *
         * 由 [MainActivity] 那条通道读给 Dart 侧看（「前台服务：运行中」那一行），
         * 这样真机上「到底起没起」不用靠感觉猜。与 [onDestroy] / [ACTION_STOP] 同步维护；
         * 进程被杀时这个值随进程一起消失（那时服务也确实没了）。
         */
        @Volatile
        var running: Boolean = false
            private set

        /**
         * 上一次起服务失败的原因（成功时清空）。
         *
         * 由 Dart 侧在「读回一直不是运行中」时读走，写进通话诊断面板 ——
         * 否则真机上只能看到「保活没起来」，看不到为什么。
         */
        @Volatile
        var lastError: String = ""
            private set

        /**
         * 当前前台服务声明的类型位（[ServiceInfo] 的位或；没在跑时是 0）。
         *
         * 为什么要读回它：屏幕共享的顺序是「① 拿到投屏同意 → ② 把服务类型升上
         * `mediaProjection` → ③ 取屏幕流」，而 ② 走的是 **异步的** `startService`
         * ——Dart 侧拿到回执时服务往往还没重新 `startForeground`。于是第 ③ 步会在
         * 「还没有 mediaProjection 类型的前台服务」的状态下取投影，Android 14 直接
         * 抛 SecurityException（真机症状：**第一次点共享屏幕必失败，再点一次就好**，
         * 因为第一次那笔类型升级这时已经落地了）。
         *
         * 所以 Dart 侧在 ②③ 之间要读回这个值、确认真的带上了投影位再往下走。
         */
        @Volatile
        var types: Int = 0
            private set
    }
}
