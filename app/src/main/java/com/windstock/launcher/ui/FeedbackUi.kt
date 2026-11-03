package com.windstock.launcher.ui

import android.content.Intent
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.windstock.launcher.ProblemReport
import com.windstock.launcher.WSLog
import com.windstock.launcher.WindstockNews
import com.windstock.launcher.WindstockProfile
import kotlinx.coroutines.launch
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/** Play › What's new: the newest two items from the website, the rest a tap away. */
@Composable
fun NewsSection() {
    val items by WindstockNews.items.collectAsState()
    val seenAt by WindstockNews.seenAt.collectAsState()
    var all by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) { WindstockNews.refresh() }
    if (items.isEmpty()) return
    val unread = items.count { it.at > seenAt }
    Section("What's new") {
        items.take(2).forEach { NewsRow(it, it.at > seenAt, 3) }
        if (items.size > 2 || unread > 0) {
            TextButton(onClick = { if (items.size > 2) all = true else WindstockNews.markSeen() },
                modifier = Modifier.padding(horizontal = 8.dp)) {
                Text(if (items.size > 2) "All news" else "Got it")
            }
        }
    }
    if (all) {
        AlertDialog(
            onDismissRequest = { all = false; WindstockNews.markSeen() },
            confirmButton = { TextButton(onClick = { all = false; WindstockNews.markSeen() }) { Text("Done") } },
            title = { Text("What's new") },
            text = {
                Column(Modifier.verticalScroll(rememberScrollState())) {
                    items.forEach { NewsRow(it, it.at > seenAt, null, inset = false) }
                }
            },
        )
    }
}

/**
 * Play › Invite friends: the trainer's own invite link from the website, shared
 * from the launcher (InviteCard in PlayView.swift). Windstock only, once the
 * server knows who plays here and that trainer has a website profile.
 */
@Composable
fun InviteSection() {
    val invite by WindstockProfile.invite.collectAsState()
    val inv = invite ?: return
    val context = LocalContext.current
    Section("Invite friends") {
        Note("Bring a friend to Windstock. When they reach level ${inv.level}, you get ${inv.coins} " +
            "PokéCoins, and your ${ordinal(inv.masterBallAt)} friend also brings a Master Ball.")
        Button(
            onClick = {
                val send = Intent(Intent.ACTION_SEND).apply {
                    type = "text/plain"
                    putExtra(Intent.EXTRA_SUBJECT, "Play Windstock with me")
                    putExtra(Intent.EXTRA_TEXT, "Catch 'em like it's 2016 -- join me on Windstock: ${inv.url}")
                }
                context.startActivity(Intent.createChooser(send, "Share my invite"))
            },
            colors = ButtonDefaults.buttonColors(containerColor = WSColors.accent),
            modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp),
        ) { Text("Share my invite") }
        if (inv.invited > 0) Note("${inv.invited} joined with your link, ${inv.counted} reached level ${inv.level}.")
    }
}

private fun ordinal(n: Int): String = n.toString() + when {
    n % 100 in 11..13 -> "th"
    n % 10 == 1 -> "st"
    n % 10 == 2 -> "nd"
    n % 10 == 3 -> "rd"
    else -> "th"
}

@Composable
private fun NewsRow(item: WindstockNews.Item, isNew: Boolean, lines: Int?, inset: Boolean = true) {
    Column(Modifier.fillMaxWidth().padding(horizontal = if (inset) 16.dp else 0.dp, vertical = 8.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(item.title, style = MaterialTheme.typography.bodyLarge, fontWeight = FontWeight.SemiBold,
                modifier = Modifier.weight(1f, fill = false))
            if (isNew) {
                Spacer(Modifier.width(6.dp))
                Surface(shape = RoundedCornerShape(50), color = WSColors.accent.copy(alpha = 0.2f)) {
                    Text("NEW", fontSize = 10.sp, fontWeight = FontWeight.Bold, color = WSColors.accent,
                        modifier = Modifier.padding(horizontal = 6.dp, vertical = 2.dp))
                }
            }
            Spacer(Modifier.weight(1f))
            Text(SimpleDateFormat("d MMM", Locale.getDefault()).format(Date(item.at)),
                style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        Text(item.body, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
            maxLines = lines ?: Int.MAX_VALUE)
    }
}

/** "Report a problem": what went wrong, and the redacted log, to the Windstock website. */
@Composable
fun ReportProblemDialog(prefill: String = "", onDismiss: () -> Unit) {
    var what by remember { mutableStateOf(prefill) }
    var contact by remember { mutableStateOf("") }
    var includeLogs by remember { mutableStateOf(true) }
    var sending by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var sentId by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()

    AlertDialog(
        onDismissRequest = { if (!sending) onDismiss() },
        title = { Text(if (sentId != null) "Sent. Thanks!" else "Report a problem") },
        text = {
            Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                if (sentId != null) {
                    Text("Report $sentId. If you left a way to reach you, you'll hear back there.")
                } else {
                    OutlinedTextField(what, { what = it }, label = { Text("What went wrong?") },
                        placeholder = { Text("What you were doing, and what happened instead") },
                        modifier = Modifier.fillMaxWidth().heightIn(min = 120.dp))
                    OutlinedTextField(contact, { contact = it }, label = { Text("Discord name or email (optional)") },
                        singleLine = true, modifier = Modifier.fillMaxWidth())
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text("Include the log", Modifier.weight(1f))
                        Switch(includeLogs, { includeLogs = it })
                    }
                    Text("The log shows what the launcher and the game were doing. Your location in it is rounded to about 10 km first, and passwords are never in it.",
                        style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    error?.let { Text(it, color = WSColors.bad, style = MaterialTheme.typography.bodySmall) }
                }
            }
        },
        confirmButton = {
            if (sentId != null) TextButton(onClick = onDismiss) { Text("Done") }
            else if (sending) CircularProgressIndicator(Modifier.padding(8.dp))
            else TextButton(enabled = what.trim().length >= 3, onClick = {
                sending = true
                error = null
                scope.launch {
                    try {
                        val id = ProblemReport.send(what.trim(), contact.trim(), includeLogs)
                        WSLog("launcher", "problem report $id sent")
                        sentId = id
                    } catch (e: ProblemReport.Failed) {
                        error = e.message
                    } finally {
                        sending = false
                    }
                }
            }) { Text("Send") }
        },
        dismissButton = { if (sentId == null && !sending) TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}
