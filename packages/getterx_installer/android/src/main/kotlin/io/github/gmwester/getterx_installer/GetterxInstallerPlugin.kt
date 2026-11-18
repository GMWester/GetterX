package io.github.gmwester.getterx_installer

import android.annotation.SuppressLint
import android.app.Activity
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ApplicationInfo
import android.content.pm.PackageInfo
import android.content.pm.PackageInstaller
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.security.MessageDigest
import java.util.concurrent.Executors

/**
 * Installs APKs with the PackageInstaller session API and answers questions
 * about installed apps.
 *
 * Silent updates: on Android 12+ an update is installed without a
 * confirmation tap when GetterX installed the app before (it is the
 * "installer of record") and the app targets a recent SDK. Otherwise Android
 * shows its normal confirmation; from the background that cannot be shown, so
 * the result is "pending_user" and the app asks the user via a notification.
 */
class GetterxInstallerPlugin : FlutterPlugin, MethodChannel.MethodCallHandler, ActivityAware {
    private lateinit var channel: MethodChannel
    private lateinit var context: Context
    private var activity: Activity? = null
    private val io = Executors.newSingleThreadExecutor()

    companion object {
        private const val ACTION = "io.github.gmwester.getterx.INSTALL_STATUS"
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "getterx/installer")
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) { activity = binding.activity }
    override fun onDetachedFromActivityForConfigChanges() { activity = null }
    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) { activity = binding.activity }
    override fun onDetachedFromActivity() { activity = null }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "canInstall" -> result.success(
                    Build.VERSION.SDK_INT < 26 || context.packageManager.canRequestPackageInstalls()
                )
                "openInstallPermissionSettings" -> {
                    val i = Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:${context.packageName}"))
                    start(i)
                    result.success(null)
                }
                "install" -> install(call.argument<String>("path")!!, result)
                "apkInfo" -> background(result) { apkInfo(call.argument<String>("path")!!) }
                "installedInfo" -> background(result) { installedInfo(call.argument<String>("packageName")!!) }
                "installedApps" -> background(result) { installedApps(call.argument<Boolean>("includeSystem") ?: false) }
                "launch" -> {
                    val i = context.packageManager.getLaunchIntentForPackage(call.argument<String>("packageName")!!)
                    if (i != null) start(i)
                    result.success(i != null)
                }
                "appInfo" -> {
                    start(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:" + call.argument<String>("packageName"))))
                    result.success(null)
                }
                "uninstall" -> {
                    @Suppress("DEPRECATION")
                    start(Intent(Intent.ACTION_UNINSTALL_PACKAGE, Uri.parse("package:" + call.argument<String>("packageName"))))
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            result.error("error", e.message ?: e.toString(), null)
        }
    }

    private fun start(i: Intent) {
        val a = activity
        if (a != null) a.startActivity(i) else context.startActivity(i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    }

    private fun background(result: MethodChannel.Result, work: () -> Any?) {
        io.execute {
            val r = try { Result.success(work()) } catch (e: Exception) { Result.failure(e) }
            android.os.Handler(android.os.Looper.getMainLooper()).post {
                r.fold({ result.success(it) }, { result.error("error", it.message ?: it.toString(), null) })
            }
        }
    }

    // ---------------------------------------------------------------- install

    @SuppressLint("UnspecifiedRegisterReceiverFlag")
    private fun install(path: String, result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT >= 26 && !context.packageManager.canRequestPackageInstalls()) {
            result.success(mapOf("status" to "no_permission", "message" to "Allow GetterX to install apps in Android settings."))
            return
        }
        val apk = File(path)
        val installer = context.packageManager.packageInstaller
        val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL)
        if (Build.VERSION.SDK_INT >= 31) {
            params.setRequireUserAction(PackageInstaller.SessionParams.USER_ACTION_NOT_REQUIRED)
        }
        if (Build.VERSION.SDK_INT >= 26) params.setInstallReason(PackageManager.INSTALL_REASON_USER)
        params.setSize(apk.length())

        val sessionId = installer.createSession(params)
        var done = false
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(c: Context, intent: Intent) {
                if (intent.getIntExtra(PackageInstaller.EXTRA_SESSION_ID, -1) != sessionId) return
                val status = intent.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE)
                val message = intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE) ?: ""
                if (status == PackageInstaller.STATUS_PENDING_USER_ACTION) {
                    @Suppress("DEPRECATION")
                    val confirm = if (Build.VERSION.SDK_INT >= 33)
                        intent.getParcelableExtra(Intent.EXTRA_INTENT, Intent::class.java)
                    else intent.getParcelableExtra(Intent.EXTRA_INTENT)
                    val a = activity
                    if (a != null && confirm != null) {
                        a.startActivity(confirm) // a second broadcast reports the final result
                        return
                    }
                    finish(mapOf("status" to "pending_user", "message" to "Needs your confirmation"))
                    try { installer.abandonSession(sessionId) } catch (_: Exception) {}
                    return
                }
                val ok = status == PackageInstaller.STATUS_SUCCESS
                finish(mapOf(
                    "status" to if (ok) "success" else if (status == PackageInstaller.STATUS_FAILURE_ABORTED) "aborted" else "failure",
                    "code" to status,
                    "message" to message,
                ))
            }

            fun finish(r: Map<String, Any?>) {
                if (done) return
                done = true
                try { context.unregisterReceiver(this) } catch (_: Exception) {}
                result.success(r)
            }
        }
        val filter = IntentFilter(ACTION)
        if (Build.VERSION.SDK_INT >= 33) {
            context.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            context.registerReceiver(receiver, filter)
        }

        io.execute {
            try {
                installer.openSession(sessionId).use { session ->
                    session.openWrite("base.apk", 0, apk.length()).use { out ->
                        apk.inputStream().use { it.copyTo(out) }
                        session.fsync(out)
                    }
                    val intent = Intent(ACTION).setPackage(context.packageName)
                    val flags = PendingIntent.FLAG_UPDATE_CURRENT or
                        (if (Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE else 0)
                    val pending = PendingIntent.getBroadcast(context, sessionId, intent, flags)
                    session.commit(pending.intentSender)
                }
            } catch (e: Exception) {
                android.os.Handler(android.os.Looper.getMainLooper()).post {
                    receiver.finish(mapOf("status" to "failure", "message" to (e.message ?: e.toString())))
                }
                try { installer.abandonSession(sessionId) } catch (_: Exception) {}
            }
        }
    }

    // ---------------------------------------------------------------- info

    private fun signatures(info: PackageInfo?): List<String> {
        if (info == null) return emptyList()
        val sigs = if (Build.VERSION.SDK_INT >= 28) {
            val si = info.signingInfo ?: return emptyList()
            if (si.hasMultipleSigners()) si.apkContentsSigners else si.signingCertificateHistory
        } else {
            @Suppress("DEPRECATION") info.signatures
        } ?: return emptyList()
        return sigs.map { s ->
            MessageDigest.getInstance("SHA-256").digest(s.toByteArray()).joinToString("") { "%02x".format(it) }
        }
    }

    private fun sigFlag(): Int =
        if (Build.VERSION.SDK_INT >= 28) PackageManager.GET_SIGNING_CERTIFICATES
        else @Suppress("DEPRECATION") PackageManager.GET_SIGNATURES

    private fun versionCode(p: PackageInfo): Long =
        if (Build.VERSION.SDK_INT >= 28) p.longVersionCode else @Suppress("DEPRECATION") p.versionCode.toLong()

    private fun apkInfo(path: String): Map<String, Any?>? {
        val pm = context.packageManager
        val p = pm.getPackageArchiveInfo(path, sigFlag()) ?: return null
        p.applicationInfo?.let { it.sourceDir = path; it.publicSourceDir = path }
        return mapOf(
            "packageName" to p.packageName,
            "versionName" to p.versionName,
            "versionCode" to versionCode(p),
            "label" to p.applicationInfo?.loadLabel(pm)?.toString(),
            "signatures" to signatures(p),
        )
    }

    private fun installedInfo(packageName: String): Map<String, Any?>? {
        val pm = context.packageManager
        val p = try { pm.getPackageInfo(packageName, sigFlag()) } catch (_: PackageManager.NameNotFoundException) { return null }
        val installer = try {
            if (Build.VERSION.SDK_INT >= 30) pm.getInstallSourceInfo(packageName).installingPackageName
            else @Suppress("DEPRECATION") pm.getInstallerPackageName(packageName)
        } catch (_: Exception) { null }
        return mapOf(
            "packageName" to p.packageName,
            "versionName" to p.versionName,
            "versionCode" to versionCode(p),
            "label" to p.applicationInfo?.loadLabel(pm)?.toString(),
            "signatures" to signatures(p),
            "installer" to installer,
            "installedByUs" to (installer == context.packageName),
            "targetSdk" to p.applicationInfo?.targetSdkVersion,
        )
    }

    private fun installedApps(includeSystem: Boolean): List<Map<String, Any?>> {
        val pm = context.packageManager
        @Suppress("DEPRECATION")
        val list = if (Build.VERSION.SDK_INT >= 33) pm.getInstalledPackages(PackageManager.PackageInfoFlags.of(0))
        else pm.getInstalledPackages(0)
        return list.filter { p ->
            val ai = p.applicationInfo ?: return@filter false
            includeSystem || (ai.flags and ApplicationInfo.FLAG_SYSTEM) == 0
        }.map { p ->
            mapOf(
                "packageName" to p.packageName,
                "versionName" to p.versionName,
                "versionCode" to versionCode(p),
                "label" to p.applicationInfo?.loadLabel(pm)?.toString(),
                "system" to (((p.applicationInfo?.flags ?: 0) and ApplicationInfo.FLAG_SYSTEM) != 0),
            )
        }.sortedBy { (it["label"] as String?)?.lowercase() ?: "" }
    }
}
