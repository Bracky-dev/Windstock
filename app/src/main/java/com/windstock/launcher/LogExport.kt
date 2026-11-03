package com.windstock.launcher

import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.core.content.FileProvider
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * The launcher log, made safe to send to whoever is running the test. A port
 * of LogExport.swift: the server logs positions to about a metre, raw request
 * dumps carry them as fixed64 integers, and tile lines give z17 tile numbers;
 * all of that is rounded or removed before anything leaves the phone.
 */
object LogExport {
    /** A share intent for a redacted copy, or null when there is no log yet. */
    fun shareIntent(context: Context): Intent? {
        val source = File(Paths.logsDir, "launcher.log")
        val raw = try { source.readText() } catch (_: Exception) { return null }
        if (raw.isBlank()) return null
        val header = """
            Windstock ${BuildConfig.VERSION_NAME} (Android)
            ${Build.MANUFACTURER} ${Build.MODEL}, Android ${Build.VERSION.RELEASE} (API ${Build.VERSION.SDK_INT})
            Exported ${SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ssXXX", Locale.US).format(Date())}
            Locations in this file are rounded to about 10 km.
            ----------------------------------------------------------------

        """.trimIndent() + "\n"
        val dir = File(context.cacheDir, "exports").apply { mkdirs() }
        val out = File(dir, "windstock-log-${BuildConfig.VERSION_CODE}.txt")
        out.writeText(header + redact(raw))
        val uri = FileProvider.getUriForFile(context, "${context.packageName}.files", out)
        return Intent.createChooser(
            Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_STREAM, uri)
                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION),
            "Send the log")
    }

    fun redact(text: String): String {
        var s = text
        // "lat,lng" pairs, however they are spaced: round to one decimal.
        s = Regex("""(-?\d{1,3}\.\d{2,})(\s*,\s*)(-?\d{1,3}\.\d{2,})""").replace(s) { m ->
            round1(m.groupValues[1]) + m.groupValues[2] + round1(m.groupValues[3])
        }
        // Raw envelope dumps: the fixed64 IS the double, bit for bit.
        s = Regex("""fixed64=\d+""").replace(s, "fixed64=<redacted>")
        s = Regex("""double~-?\d+\.\d+""").replace(s, "double~<redacted>")
        // Map-tile requests: z17 tile numbers locate you to a few hundred metres.
        s = Regex("""x \d+-\d+ y \d+-\d+""").replace(s, "x <redacted> y <redacted>")
        return s
    }

    private fun round1(v: String) = v.toDoubleOrNull()?.let { String.format(Locale.US, "%.1f", it) } ?: v
}
