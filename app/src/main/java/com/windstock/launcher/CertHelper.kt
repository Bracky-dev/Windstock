package com.windstock.launcher

import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.provider.Settings
import android.security.KeyChain
import java.io.File
import java.security.KeyStore
import java.security.cert.CertificateFactory
import java.security.cert.X509Certificate

/**
 * The server's CA, which the game has to trust before it will log in.
 *
 * The 0.35 client targets API 23, so it trusts user-installed CAs -- but since
 * Android 11 no app may install one for the user. What we can do: save the
 * certificate where the Settings installer can pick it up, open Settings, and
 * afterwards CHECK the user CA store, which iOS never let the launcher do.
 */
object CertHelper {
    private const val EXPORT_NAME = "windstock-ca.crt"

    private fun ourCa(): X509Certificate? = try {
        Paths.caCertificate.inputStream().use {
            CertificateFactory.getInstance("X.509").generateCertificate(it) as X509Certificate
        }
    } catch (_: Exception) {
        null
    }

    val isAvailable get() = Paths.caCertificate.exists()

    /** True when the user CA store holds our CA. */
    fun isTrusted(): Boolean {
        val ca = ourCa() ?: return false
        return try {
            val store = KeyStore.getInstance("AndroidCAStore").apply { load(null) }
            store.aliases().asSequence().any { alias ->
                alias.startsWith("user:") && (store.getCertificate(alias) as? X509Certificate)?.let {
                    it.encoded.contentEquals(ca.encoded)
                } == true
            }
        } catch (_: Exception) {
            false
        }
    }

    /** Copies ca.crt into Downloads. Returns a human description of where, or null. */
    fun exportToDownloads(context: Context): String? {
        val src = Paths.caCertificate
        if (!src.exists()) return null
        return try {
            if (Build.VERSION.SDK_INT >= 29) {
                val resolver = context.contentResolver
                // Replace an older copy rather than piling up "(1)" duplicates.
                resolver.delete(MediaStore.Downloads.EXTERNAL_CONTENT_URI,
                    "${MediaStore.Downloads.DISPLAY_NAME}=?", arrayOf(EXPORT_NAME))
                val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, ContentValues().apply {
                    put(MediaStore.Downloads.DISPLAY_NAME, EXPORT_NAME)
                    put(MediaStore.Downloads.MIME_TYPE, "application/x-x509-ca-cert")
                }) ?: return null
                resolver.openOutputStream(uri)?.use { out -> src.inputStream().use { it.copyTo(out) } }
            } else {
                @Suppress("DEPRECATION")
                val dir = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)
                src.copyTo(File(dir, EXPORT_NAME), overwrite = true)
            }
            "Downloads/$EXPORT_NAME"
        } catch (e: Exception) {
            WSLog("cert", "could not save the certificate: ${e.message}")
            null
        }
    }

    /**
     * Before Android 11 the system installer still takes a CA straight from an
     * app; from 11 on it only explains that you must use Settings, so go there.
     */
    fun installIntent(): Intent {
        if (Build.VERSION.SDK_INT < 30) {
            val bytes = try { Paths.caCertificate.readBytes() } catch (_: Exception) { null }
            if (bytes != null) {
                return KeyChain.createInstallIntent()
                    .putExtra(KeyChain.EXTRA_CERTIFICATE, bytes)
                    .putExtra(KeyChain.EXTRA_NAME, "Windstock")
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
        }
        return Intent(Settings.ACTION_SECURITY_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
    }
}
