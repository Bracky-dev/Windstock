package com.windstock.launcher

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL

/**
 * The leaderboard, as the trainer playing on this phone sees it. A port of
 * WindstockProfile.swift.
 *
 * Only in Windstock Online mode, and with no sign-in of its own: the launcher
 * asks the Windstock server through its tunnel (GET /windstock/standing on the
 * tunnel's plain loopback port). The tunnel marks the request with this
 * phone's device id, and the server answers for whoever last logged in to the
 * game from this phone. The board only holds what the Windstock server
 * reported from its own saves, so the server on this phone never feeds it.
 *
 * iOS also writes the standing into the game for the tweak's Leaderboard tab;
 * the Android agent has no such tab yet, so that half is not ported.
 */
object WindstockProfile {
    // The website runs on the Windstock VPS, behind Caddy's HTTPS.
    const val DEFAULT_SITE = "https://windstock.org"
    private const val EVERY_MS = 15_000L

    private val _trainer = MutableStateFlow<String?>(null)
    val trainer: StateFlow<String?> = _trainer
    private val _rank = MutableStateFlow<Int?>(null)
    val rank: StateFlow<Int?> = _rank
    private val _boardSize = MutableStateFlow(0)
    val boardSize: StateFlow<Int> = _boardSize
    /** Why there is no standing ("Log in to the game first."). */
    private val _note = MutableStateFlow<String?>(null)
    val note: StateFlow<String?> = _note

    /** This trainer's invite link and how far their friends got (Play › Invite friends). */
    data class Invite(
        val url: String,
        val invited: Int,       // signed up with the link
        val counted: Int,       // reached `level` and paid out
        val coins: Int,         // PokeCoins per counted friend
        val level: Int,
        val masterBallAt: Int,
    )
    /** null for a trainer without a website profile (name logins have no invite). */
    private val _invite = MutableStateFlow<Invite?>(null)
    val invite: StateFlow<Invite?> = _invite

    private var loop: Job? = null
    private val prefs get() = Launcher.prefs.value

    val siteURL: String
        get() {
            val typed = prefs.profileSiteURL.trim()
            // The VPS's bare IP (saved by the 2026-09-30 launchers) is the same site: use its name.
            if (typed.isEmpty() || typed.contains("2.29.24.78")) return DEFAULT_SITE
            return (if (typed.contains("://")) typed else "http://$typed").trimEnd('/')
        }

    /** Whether this phone can have a leaderboard at all. */
    val isAvailable get() = prefs.serverMode == ServerMode.ONLINE

    fun start() {
        if (loop?.isActive == true) return
        loop = Launcher.scope.launch {
            while (isActive) {
                refresh()
                delay(EVERY_MS)
            }
        }
    }

    fun refresh() {
        if (!isAvailable) { clear(null); return }
        val url = "http://127.0.0.1:${prefs.serverPlainPort}/windstock/standing"
        Launcher.scope.launch {
            val (status, body) = get(url) ?: return@launch     // tunnel not up yet: keep the last one
            if (!isAvailable) { clear(null); return@launch }
            if (status != 200 || !body.optBoolean("ok")) {
                clear(if (status == 404) "This server has no leaderboard."
                      else body.optString("error").ifEmpty { "No leaderboard right now." })
                return@launch
            }
            _trainer.value = body.optString("username").ifEmpty { null }
            _rank.value = if (body.has("rank") && !body.isNull("rank")) body.optInt("rank") else null
            _boardSize.value = body.optInt("total", 0)
            _note.value = null
            _invite.value = body.optJSONObject("referral")?.let { ref ->
                val code = ref.optString("code")
                if (code.isEmpty()) null
                else Invite(
                    url = "$siteURL/register.html?ref=" + java.net.URLEncoder.encode(code, "UTF-8"),
                    invited = ref.optInt("invited"),
                    counted = ref.optInt("counted"),
                    coins = ref.optInt("coinsPerFriend", 500),
                    level = ref.optInt("level", 5),
                    masterBallAt = ref.optInt("masterBallAt", 5),
                )
            }
        }
    }

    private fun clear(note: String?) {
        _trainer.value = null
        _rank.value = null
        _boardSize.value = 0
        _invite.value = null
        _note.value = note
    }

    private suspend fun get(url: String): Pair<Int, JSONObject>? = withContext(Dispatchers.IO) {
        try {
            val c = URL(url).openConnection() as HttpURLConnection
            c.connectTimeout = 10000
            c.readTimeout = 10000
            val status = c.responseCode
            val text = (if (status >= 400) c.errorStream else c.inputStream)?.use { it.readBytes().decodeToString() } ?: ""
            c.disconnect()
            status to (try { JSONObject(text) } catch (_: Exception) { JSONObject() })
        } catch (_: Exception) {
            null
        }
    }
}
