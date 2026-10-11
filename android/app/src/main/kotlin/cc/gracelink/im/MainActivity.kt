package cc.gracelink.im

import android.Manifest
import android.app.NotificationManager
import android.app.PictureInPictureParams
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.content.Context
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.provider.Settings
import android.util.Log
import android.util.Rational
import android.view.WindowManager
import com.ryanheise.audioservice.AudioServiceActivity
import com.ryanheise.audioservice.AudioServicePlugin
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.plugin.common.MethodChannel

// 继承的是 audio_service 的 AudioServiceActivity（它是 FlutterActivity 的子类，
// 只是多一句 provideFlutterEngine：复用插件那个**共享引擎**）。
//
// 为什么必须换：灵听的媒体通知（通知栏上的封面/歌名/播放控制）跑在 audio_service
// 的共享引擎里，如果 Activity 另起一个引擎，两边就是两个 Dart 世界 ——
// 点通知回到 App 会看到「界面以为没在播、通知栏却在播」的分裂状态。
// 换成它之后，通知、锁屏、耳机键、界面操作的是同一个播放器。
//
// 通话那套（画中画、前台服务、锁屏窗口）与它互不干涉，都在下面。
class MainActivity : AudioServiceActivity() {

    /** 画中画通道（通话小窗，见 lib/core/platform/call_pip.dart） */
    private var pipChannel: MethodChannel? = null

    /**
     * 被**来电通知**（全屏通知）拉起来时，**在 Flutter 引擎起来之前**就把
     * 「盖住锁屏」的窗口开关打开。
     *
     * 这一步不能交给 Dart：引擎启动要好几秒，而系统是在 Activity 起来的**当下**
     * 判断「这个 Activity 愿不愿意盖锁屏」—— 不声明的话它会退回成一条横幅，
     * 那几秒里用户看到的还是锁屏（真机上就是这么表现的）。
     */
    override fun onCreate(savedInstanceState: Bundle?) {
        // ⚠️ 必须在 super.onCreate **之前**看这一眼：那之后共享引擎一定已经建好了
        // （`AudioServiceActivity.provideFlutterEngine` 会顺手把它热出来）。
        val engineWasAlreadyRunning =
            FlutterEngineCache.getInstance().contains(AudioServicePlugin.getFlutterEngineId())

        super.onCreate(savedInstanceState)
        if (isLaunchedFromCallNotification(intent)) setCallScreenMode(true)
        // App 本来就在后台活着、点通知把界面新建起来那一下：见这个方法自己的注释
        if (engineWasAlreadyRunning) deliverNotificationTap(intent)
    }

    /**
     * 「App 在后台活着 + 点通知把 Activity 新建起来」时，把 payload 补交给 Dart。
     *
     * 怎么做：**手动走一遍 [onNewIntent]**。插件（`flutter_local_notifications`）在
     * `onAttachedToActivity` 里把自己注册成了 Activity 的 `OnNewIntentListener`，
     * 而超级类（FlutterActivity）收到 onNewIntent 时会把它转给插件，插件内部就叫
     * `didReceiveNotificationResponse` 把 payload 发给 Dart —— 也就是「App 已经在
     * 前台」那条能正常工作的路。所以这里不需要碰插件的内部 API，只要再发一次那个
     * 事件；上面那两个监听器在 `super.onCreate` 里已经挂好了。
     *
     * 为什么得补（真机 2026-10-08 查出来的）：Activity **新建**时插件走的是
     * `onAttachedToActivity`，那份代码**只处理 `SELECT_FOREGROUND_NOTIFICATION_ACTION`**
     * ——引擎已经热着（推送到达时 audio_service 暖机把它带起来了）再点通知，
     * payload 根本不会交给 Dart：界面起来了，却停在原地。
     * 这就是「离线推送点通知后白屏 / 没跳到对应页面」的第二半（第一半是 main.dart 里那句
     * `await SystemChrome.setPreferredOrientations` 在无界面引擎里永远不返回，
     * 卡死到 runApp 之前）。
     *
     * **只在引擎本来就在跑时补**：冷启动那条路走的是
     * `getNotificationAppLaunchDetails()`（Dart 侧已经处理），这里再补一刀会跳两次。
     */
    private fun deliverNotificationTap(intent: Intent?) {
        if (intent == null || intent.action != SELECT_NOTIFICATION_ACTION) return
        try {
            onNewIntent(intent)
        } catch (error: Exception) {
            // 补不上也不能把这次启动弄崩：用户看到的是没跳页，不是闪退
            Log.w(TAG, "点通知的 payload 没补交给 Dart", error)
        }
    }

    /** 已经开着 App 时被全屏通知叫回来（singleTop → 走这里而不是 onCreate） */
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        if (isLaunchedFromCallNotification(intent)) setCallScreenMode(true)
    }

    /** 这次启动是不是「来电通知被点了 / 全屏通知把界面拉起来了」 */
    private fun isLaunchedFromCallNotification(intent: Intent?): Boolean =
        intent != null &&
            intent.action == SELECT_NOTIFICATION_ACTION &&
            intent.getIntExtra(EXTRA_NOTIFICATION_ID, -1) == CALL_NOTIFICATION_ID

    /**
     * 开 / 关「盖在锁屏之上 + 亮屏」。
     *
     * `setShowWhenLocked` / `setTurnScreenOn` 是 8.1 起的新 API（更早的版本用
     * 窗口 flag，这里一并留着，免得老机器上锁屏来电只剩声音）。
     */
    private fun setCallScreenMode(enabled: Boolean) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(enabled)
            setTurnScreenOn(enabled)
        } else {
            @Suppress("DEPRECATION")
            if (enabled) {
                window.addFlags(
                    WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                        WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON
                )
            } else {
                window.clearFlags(
                    WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                        WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON
                )
            }
        }
        Log.i(TAG, "通话窗口：锁屏显示 = $enabled")
    }

    /** 权限通道那些状态（见 lib/core/platform/app_permissions.dart） */
    private var pendingPermissionResult: MethodChannel.Result? = null
    private var pendingPermissionNames: List<String> = emptyList()

    /** 小窗比例：语音 1:1、视频 3:4（微信那种竖的小长方形，比 9:16 明显小一圈） */
    private var pipAspectRatio = Rational(1, 1)

    /** 小窗的名字（系统展开那一栏里的标题；空着就不设） */
    private var pipTitle = ""

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // 「去设置」：安卓从第二次拒绝麦克风/摄像头权限起就不弹系统授权框了，
        // 只能在设置里手动打开 —— url_launcher 打不开应用详情页，所以自己开一个通道。
        // 见 lib/core/platform/app_settings.dart
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, APP_SETTINGS_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "openAppSettings" -> {
                        startActivity(
                            Intent(
                                Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                                Uri.parse("package:$packageName")
                            )
                        )
                        result.success(null)
                    }
                    // 「消息提醒」那条提示条点进去：本应用的通知设置页
                    // （比应用详情页少翻一层；旧系统没有这个页面时退回去）
                    "openNotificationSettings" -> {
                        val intent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                                .putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
                        } else {
                            Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
                                .setData(Uri.parse("package:$packageName"))
                        }
                        try {
                            startActivity(intent)
                        } catch (error: Exception) {
                            Log.w(TAG, "打不开通知设置页，退回应用详情页", error)
                            startActivity(
                                Intent(
                                    Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                                    Uri.parse("package:$packageName")
                                )
                            )
                        }
                        result.success(null)
                    }
                    // 通知权限开着吗（消息提醒那条红提示条用它；只查不请求）
                    "notificationPermission" -> result.success(hasNotificationPermission())
                    // 电池优化是否已忽略本应用（false = 系统可能在后台冻结我们，
                    // WS 一断就收不到消息）
                    "isIgnoringBatteryOptimizations" -> {
                        val power = getSystemService(Context.POWER_SERVICE) as PowerManager
                        result.success(power.isIgnoringBatteryOptimizations(packageName))
                    }
                    // 申请「忽略电池优化」：系统会弹一个确认框（用户同意就完事）；
                    // 弹不出来（部分 ROM / 已拒绝）就打开电池优化列表页，让用户自己选。
                    "requestIgnoreBatteryOptimizations" -> {
                        val power = getSystemService(Context.POWER_SERVICE) as PowerManager
                        if (power.isIgnoringBatteryOptimizations(packageName)) {
                            result.success(true)
                            return@setMethodCallHandler
                        }
                        val direct = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS)
                            .setData(Uri.parse("package:$packageName"))
                        try {
                            startActivity(direct)
                            result.success(true)
                        } catch (error: Exception) {
                            Log.w(TAG, "直接申请不了，打开电池优化列表页", error)
                            try {
                                startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
                                result.success(true)
                            } catch (fallbackError: Exception) {
                                Log.w(TAG, "电池优化页也打不开，退回应用详情页", fallbackError)
                                startActivity(
                                    Intent(
                                        Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                                        Uri.parse("package:$packageName")
                                    )
                                )
                                result.success(false)
                            }
                        }
                    }
                    // 全屏通知（来电响铃时直接用整屏弹出来电界面）允许了吗。
                    // 安卓 14 起系统**只给「通话类应用」自动授权**，其它应用一律是关的，
                    // 关着时系统会把来电降级成横幅 + 响铃（不是错误，只是没那么醒目）。
                    // 14 以下恒为 true（那时不需要用户授权）。
                    "fullScreenIntentAllowed" -> result.success(canUseFullScreenIntent())
                    // 跳到本应用的全屏通知设置页（和上面那条一样，14 以下什么都不用做）
                    "openFullScreenIntentSettings" -> {
                        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                            result.success(false)
                            return@setMethodCallHandler
                        }
                        try {
                            startActivity(
                                Intent(
                                    Settings.ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT,
                                    Uri.parse("package:$packageName")
                                )
                            )
                            result.success(true)
                        } catch (error: Exception) {
                            // 有的 ROM 没有这个页面：退回应用详情页，让用户自己找
                            Log.w(TAG, "全屏通知设置页打不开，退回应用详情页", error)
                            startActivity(
                                Intent(
                                    Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                                    Uri.parse("package:$packageName")
                                )
                            )
                            result.success(false)
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        // 运行时权限（S8.x）：摄像头 / 麦克风 / 通知。
        //
        // 为什么自己写一条通道而不是引 permission_handler：这个仓库已经有三条
        // 自己写的通道（设置页、版本号、通话服务），而我们要的就三样东西，
        // 一个插件（连同它的 Android 配置）不如这三十行划算。
        //
        // 见 lib/core/platform/app_permissions.dart（Dart 那一侧）
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, PERMISSIONS_CHANNEL)
            .setMethodCallHandler { call, result ->
                val names = call.argument<List<String>>("names").orEmpty()
                when (call.method) {
                    // 只查，不弹任何框
                    "check" -> result.success(permissionStates(names, justAsked = false))
                    // 查一遍，缺的弹系统框；结果等 onRequestPermissionsResult
                    "request" -> requestAppPermissions(names, result)
                    else -> result.notImplemented()
                }
            }

        // 本机版本号（S7.2 检查更新要用）：见 lib/core/platform/app_version.dart。
        // 为什么不用 package_info_plus：它要 win32 ^5.5.3，而 file_picker 那条
        // 依赖链要 win32 ^6.3.0，pub 直接解不开；一个版本号不值得动文件选择器。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, APP_INFO_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "version" -> {
                        val info = packageManager.getPackageInfo(packageName, 0)
                        val code = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                            info.longVersionCode
                        } else {
                            @Suppress("DEPRECATION") info.versionCode.toLong()
                        }
                        result.success(
                            mapOf(
                                "name" to (info.versionName ?: ""),
                                "code" to code,
                            )
                        )
                    }
                    else -> result.notImplemented()
                }
            }

        // 通话期间的前台服务（S6.5）：见 CallForegroundService.kt 与
        // lib/core/platform/call_keep_alive.dart
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CALL_SERVICE_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> {
                        startCallService(
                            video = call.argument<Boolean>("video") ?: false,
                            title = call.argument<String>("title").orEmpty(),
                            text = call.argument<String>("text").orEmpty(),
                        )
                        result.success(null)
                    }
                    // 屏幕共享（S6.7）：同一个前台服务再多带一个 mediaProjection 类型位。
                    // Android 14 要求取投影之前已经有带该类型的服务在跑（见 REFACTOR_PLAN S6.7）。
                    "screenSharing" -> {
                        startService(
                            Intent(this, CallForegroundService::class.java).apply {
                                action = CallForegroundService.ACTION_SHARING
                                putExtra(
                                    CallForegroundService.EXTRA_SHARING,
                                    call.argument<Boolean>("enabled") ?: false,
                                )
                                putExtra(
                                    CallForegroundService.EXTRA_TEXT,
                                    call.argument<String>("text").orEmpty(),
                                )
                            }
                        )
                        result.success(null)
                    }
                    "stop" -> {
                        startService(
                            Intent(this, CallForegroundService::class.java).apply {
                                action = CallForegroundService.ACTION_STOP
                            }
                        )
                        result.success(null)
                    }
                    "isRunning" -> result.success(CallForegroundService.running)
                    // 当前前台服务带哪些类型位（屏幕共享那一步要等到真的带上
                    // mediaProjection 才去取投影，见 CallForegroundService.types）
                    "foregroundTypes" -> result.success(CallForegroundService.types)
                    // 起服务失败的原因（诊断面板要展示的那句话）
                    "lastError" -> result.success(CallForegroundService.lastError)
                    // 只查不请求：权限框会把 App 顶到后台，而那时候起 mic 类型的
                    // 前台服务会被系统拒掉（真机实测），所以通话路径里绝不能触发它
                    "notificationPermission" -> result.success(hasNotificationPermission())
                    // 只在用户明示的入口调（设置页 / 自检面板）
                    "requestNotificationPermission" -> {
                        requestNotificationPermission()
                        result.success(hasNotificationPermission())
                    }
                    else -> result.notImplemented()
                }
            }

        // 通话小窗（画中画）—— 按用户要求：
        // * **只有**点通话页那颗「缩成小窗」才进（`enter`）；
        // * 回到桌面 / 切到别的应用**不进小窗**：只靠前台服务 + 常驻通知
        //   （`setParams` 里刻意不开 `setAutoEnterEnabled`）；
        // * 小窗里**没有任何按钮**（PiP 里触摸被系统接管，点一下是"展开/菜单"）；
        // * 通话结束时把窗口收掉（`exit`），别留一个「小窗里是聊天列表」的怪状态。
        // 见 lib/core/platform/call_pip.dart
        val pip = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, PIP_CHANNEL)
        pip.setMethodCallHandler { call, result ->
            when (call.method) {
                "supported" -> result.success(pipSupported())
                // 把比例/标题交给系统（**不开**自动缩窗）
                "setParams" -> {
                    pipAspectRatio = if (call.argument<Boolean>("video") == true) {
                        Rational(3, 4)
                    } else {
                        Rational(1, 1)
                    }
                    pipTitle = call.argument<String>("title").orEmpty()
                    result.success(applyPipParams())
                }
                "isInPip" -> result.success(isInPictureInPictureMode)
                // 通话页那颗「缩成小窗」：点一下立刻进，不用按 Home
                "enter" -> result.success(enterPipNow())
                // 通话结束：把任务放回后台 = 收掉小窗（通话通知还在，点它就能回来）
                "exit" -> {
                    if (isInPictureInPictureMode) moveTaskToBack(true)
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
        pipChannel = pip

        // 通话界面能不能盖在锁屏之上（S8.1n）——见 lib/core/platform/call_window.dart。
        //
        // 为什么要有这条通道：离线叫醒的来电靠**全屏通知**把 Activity 拉起来，
        // 但「系统愿意启动界面」不等于「界面能盖住锁屏」—— 后者得 Activity 自己声明
        // （上面的 setCallScreenMode），否则用户看到的还是锁屏。通话开始/结束时由
        // 控制器开关它；被来电通知拉起来那一下在 onCreate 里已经先开好了。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CALL_WINDOW_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "setCallScreenMode" -> {
                        setCallScreenMode(call.argument<Boolean>("enabled") == true)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /**
     * 我们自己的权限请求回来了（摄像头 / 麦克风 / 通知）。
     *
     * **先调 super**：插件（mobile_scanner 等）也在等同一批回调，不转交的话
     * 它们那边的请求会永远挂着（扫一扫就会卡在「正在启动相机」）。
     */
    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != REQUEST_APP_PERMISSIONS) return
        val result = pendingPermissionResult ?: return
        val names = pendingPermissionNames
        pendingPermissionResult = null
        pendingPermissionNames = emptyList()
        result.success(permissionStates(names, justAsked = true))
    }

    /** Dart 要的那几个权限名 → 安卓的权限名（`null` = 这个系统上不需要它） */
    private fun permissionOf(name: String): String? = when (name) {
        "camera" -> Manifest.permission.CAMERA
        "microphone" -> Manifest.permission.RECORD_AUDIO
        // 通知是安卓 13 起才要用户授权，更早的系统上它一直是允许的
        "notifications" -> if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            Manifest.permission.POST_NOTIFICATIONS
        } else {
            null
        }
        else -> null
    }

    private fun hasPermission(permission: String): Boolean =
        checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED

    /**
     * 每个权限现在的状态：`granted` / `denied` / `permanentlyDenied` / `unsupported`。
     *
     * `permanentlyDenied` 的判据是「没授权 + 系统不再愿意弹框」：安卓从第二次
     * 拒绝起 `shouldShowRequestPermissionRationale` 就恒为 false，这时只有去设置页
     * 手动打开这一条路 —— Dart 那边据此决定要不要给「去授权」那颗钮。
     */
    private fun permissionStates(names: List<String>, justAsked: Boolean): Map<String, String> {
        val states = HashMap<String, String>()
        for (name in names) {
            val permission = permissionOf(name)
            states[name] = when {
                permission == null -> "unsupported"
                hasPermission(permission) -> "granted"
                justAsked -> if (shouldShowRequestPermissionRationale(permission)) {
                    "denied"
                } else {
                    "permanentlyDenied"
                }
                else -> "denied"
            }
        }
        return states
    }

    /**
     * 申请权限：已经有的不重复问；缺的交给系统弹框，结果在 [onRequestPermissionsResult]。
     *
     * 同一时刻只允许一个请求在飞（`requestPermissions` 的结果只带 requestCode，
     * 分不出是谁）—— 撞上就回一个 `busy` 错误，Dart 那边当「还没授权」处理。
     */
    private fun requestAppPermissions(names: List<String>, result: MethodChannel.Result) {
        val missing = names.filter { name ->
            val permission = permissionOf(name)
            permission != null && !hasPermission(permission)
        }
        if (missing.isEmpty()) {
            result.success(permissionStates(names, justAsked = false))
            return
        }
        if (pendingPermissionResult != null) {
            result.error("busy", "另一个权限请求还没结束", null)
            return
        }
        pendingPermissionResult = result
        pendingPermissionNames = names
        requestPermissions(
            missing.mapNotNull { permissionOf(it) }.toTypedArray(),
            REQUEST_APP_PERMISSIONS,
        )
    }

    /** 进 / 出小窗要通知 Dart：界面据此切成「只有内容、没有按钮」的样子 */
    override fun onPictureInPictureModeChanged(
        isInPictureInPictureMode: Boolean,
        newConfig: Configuration,
    ) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        pipChannel?.invokeMethod("modeChanged", isInPictureInPictureMode)
    }

    /** 立刻进小窗（用户点按钮，不是离开应用自动进）；进不去只回 false，不影响通话 */
    private fun enterPipNow(): Boolean {
        if (!pipSupported()) return false
        return try {
            enterPictureInPictureMode(buildPipParams())
        } catch (error: Exception) {
            Log.w("GraceLink", "进画中画失败", error)
            false
        }
    }

    /** 这个系统/机型到底有没有画中画（部分 ROM 会关掉它） */
    private fun pipSupported(): Boolean =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE)

    private fun buildPipParams(): PictureInPictureParams {
        val builder = PictureInPictureParams.Builder().setAspectRatio(pipAspectRatio)
        if (pipTitle.isNotEmpty()) {
            builder.setTitle(pipTitle)
        }
        // **不开** setAutoEnterEnabled：按用户要求，回到桌面/切走不进小窗，
        // 只靠前台服务 + 常驻通知；要缩窗就点通话页那颗按钮（`enter`）。
        return builder.build()
    }

    /** 把当前参数交给系统（12+ 的「离开就自动进小窗」就是靠这一步注册的） */
    private fun applyPipParams(): Boolean {
        if (!pipSupported()) return false
        return try {
            setPictureInPictureParams(buildPipParams())
            true
        } catch (error: Exception) {
            // 比例不合规 / ROM 抽风：小窗是体验，绝不能影响通话本身
            false
        }
    }

    /** 前台服务必须由**前台**的 UI 触发（Android 14+ 对 mic/camera 类型的硬要求） */
    private fun startCallService(video: Boolean, title: String, text: String) {
        val intent = Intent(this, CallForegroundService::class.java).apply {
            action = CallForegroundService.ACTION_START
            putExtra(CallForegroundService.EXTRA_VIDEO, video)
            putExtra(CallForegroundService.EXTRA_TITLE, title)
            putExtra(CallForegroundService.EXTRA_TEXT, text)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(intent)
        } else {
            startService(intent)
        }
    }

    /**
     * 安卓 13 起通知要用户授权。**拒绝不影响服务运行**（前台服务照跑，只是通知
     * 不显示），所以这里只负责告知状态，不动系统框。
     */
    private fun hasNotificationPermission(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return true
        return checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
    }

    /**
     * 能不能用「全屏通知」（来电时直接亮屏弹来电界面）。
     *
     * 安卓 14 起 `canUseFullScreenIntent()` 只对**通话类应用**自动放行，
     * 其它应用默认是 false —— 所以查不出来 / 版本太低时我们**偏向 true**：
     * 拿不到结论就不该在设置里给用户一条「没开」的提示（那是误报）。
     */
    private fun canUseFullScreenIntent(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE) return true
        return try {
            val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            manager.canUseFullScreenIntent()
        } catch (error: Exception) {
            Log.w(TAG, "查不到全屏通知权限，当作已允许", error)
            true
        }
    }

    /**
     * 主动申请通知权限。
     *
     * ⚠️ **不要在任何「即将起前台服务」的时刻调它**：系统权限框会把本 App 顶到
     * 后台，而 Android 14 不允许从后台启动 mic/camera 类型的前台服务
     * （`validateForegroundServiceType`），结果是保活当场失败。通话路径只用
     * [hasNotificationPermission] 查询，申请留给设置页/自检面板这类用户明示入口。
     */
    private fun requestNotificationPermission() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return
        if (hasNotificationPermission()) return
        requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), REQUEST_NOTIFICATIONS)
    }

    companion object {
        private const val TAG = "GracelinkIM"
        private const val APP_SETTINGS_CHANNEL = "gracelinkim/app_settings"
        private const val APP_INFO_CHANNEL = "gracelinkim/app_info"
        private const val CALL_SERVICE_CHANNEL = "gracelinkim/call_service"
        private const val PIP_CHANNEL = "gracelinkim/pip"
        private const val CALL_WINDOW_CHANNEL = "gracelinkim/call_window"
        private const val PERMISSIONS_CHANNEL = "gracelinkim/permissions"
        private const val REQUEST_NOTIFICATIONS = 20260919

        /** 我们自己的权限请求（摄像头 / 麦克风 / 通知）用的 requestCode */
        private const val REQUEST_APP_PERMISSIONS = 20260927

        /** `flutter_local_notifications` 点通知时给启动 Intent 打的动作名 */
        private const val SELECT_NOTIFICATION_ACTION = "SELECT_NOTIFICATION"

        /** 那个插件放通知 id 用的 extras key */
        private const val EXTRA_NOTIFICATION_ID = "notificationId"

        /**
         * 来电通知的 id（必须与 `LocalMessageNotificationPresenter.callNotificationId` 一致）。
         *
         * 全屏通知点开/自动拉起时就是靠它认出「这次启动是来电报的」，
         * 从而在 Flutter 引擎起来之前就把锁屏开关打开。
         */
        private const val CALL_NOTIFICATION_ID = 0x0CA11
    }
}
