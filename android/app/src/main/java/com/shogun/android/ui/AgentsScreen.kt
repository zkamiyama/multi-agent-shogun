package com.shogun.android.ui

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Bundle
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowBack
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.Send
import androidx.compose.material.icons.filled.Speed
import androidx.core.content.ContextCompat
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalLifecycleOwner
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.viewmodel.compose.viewModel
import com.shogun.android.R
import com.shogun.android.viewmodel.AgentsViewModel
import com.shogun.android.viewmodel.PaneInfo

// ── Rate limit data classes ──────────────────────────────────────────────────
private data class WindowInfo(val percent: Float, val resetStr: String)
private data class ClaudeMaxInfo(
    val window5h: WindowInfo?,
    val window7d: WindowInfo?,
    val sonnet7d: Float?,
    val opus7d: Float?,
    val todayTokens: String?,
    val sessions: Int?,
    val messages: Int?
)
private data class CodexEntry(val ashigaru: Int, val percent: Float?) // null = unknown

private fun parseRateLimitResult(text: String): Pair<ClaudeMaxInfo, List<CodexEntry>> {
    val window5h = Regex("""5h window:\s+([\d.]+)%.*\(resets ([^)]+)\)""").find(text)?.let {
        WindowInfo(it.groupValues[1].toFloatOrNull() ?: 0f, it.groupValues[2])
    }
    val window7d = Regex("""7d window:\s+([\d.]+)%.*\(resets ([^)]+)\)""").find(text)?.let {
        WindowInfo(it.groupValues[1].toFloatOrNull() ?: 0f, it.groupValues[2])
    }
    val sonnet7d = Regex("""sonnet 7d:\s+([\d.]+)%""").find(text)?.groupValues?.get(1)?.toFloatOrNull()
    val opus7d   = Regex("""opus 7d:\s+([\d.]+)%""").find(text)?.groupValues?.get(1)?.toFloatOrNull()
    val todayTokens = Regex("""Today:\s+([\d,]+) tokens""").find(text)?.groupValues?.get(1)
    val sessions = Regex("""Sessions:\s+(\d+)""").find(text)?.groupValues?.get(1)?.toIntOrNull()
    val messages = Regex("""Messages:\s+(\d+)""").find(text)?.groupValues?.get(1)?.toIntOrNull()

    val claudeMax = ClaudeMaxInfo(window5h, window7d, sonnet7d, opus7d, todayTokens, sessions, messages)

    val codexEntries = mutableListOf<CodexEntry>()
    Regex("""(\d+):(\d+)%""").findAll(text).forEach { m ->
        val ash = m.groupValues[1].toIntOrNull() ?: return@forEach
        codexEntries.add(CodexEntry(ash, m.groupValues[2].toFloatOrNull()))
    }
    Regex("""(\d+):\?""").findAll(text).forEach { m ->
        val ash = m.groupValues[1].toIntOrNull() ?: return@forEach
        if (codexEntries.none { it.ashigaru == ash }) codexEntries.add(CodexEntry(ash, null))
    }
    codexEntries.sortBy { it.ashigaru }
    return Pair(claudeMax, codexEntries)
}

private fun rateLimitBarColor(percent: Float): Color = when {
    percent >= 80f -> Color(0xFFCC4444)
    percent >= 50f -> Color(0xFFC9A94E)
    else           -> Color(0xFF4CAF50)
}

private fun formatResetTime(resetStr: String): String {
    val locale = java.util.Locale.getDefault()
    val now = java.time.LocalDateTime.now()
    return try {
        if (resetStr.contains('T')) {
            val ldt = java.time.LocalDateTime.parse(resetStr.take(16))
            val dow = ldt.dayOfWeek.getDisplayName(java.time.format.TextStyle.SHORT, locale)
            val timeStr = "${ldt.monthValue}/${ldt.dayOfMonth}($dow) %02d:%02d".format(ldt.hour, ldt.minute)
            if (ldt.isBefore(now)) {
                "$timeStr にリセット済み"
            } else {
                "$timeStr にリセット"
            }
        } else {
            val ld = java.time.LocalDate.parse(resetStr)
            val today = java.time.LocalDate.now()
            val dow = ld.dayOfWeek.getDisplayName(java.time.format.TextStyle.SHORT, locale)
            val dateStr = "${ld.monthValue}/${ld.dayOfMonth}($dow)"
            if (ld.isBefore(today)) {
                "$dateStr にリセット済み"
            } else {
                val dow = ld.dayOfWeek.getDisplayName(java.time.format.TextStyle.SHORT, locale)
                "${ld.monthValue}/${ld.dayOfMonth}($dow) にリセット"
            }
        }
    } catch (_: Exception) {
        resetStr
    }
}

@Composable
fun AgentsScreen(
    viewModel: AgentsViewModel = viewModel()
) {
    val context = LocalContext.current
    val panes by viewModel.panes.collectAsState()
    val errorMessage by viewModel.errorMessage.collectAsState()
    val rateLimitLoading by viewModel.rateLimitLoading.collectAsState()
    val rateLimitResult by viewModel.rateLimitResult.collectAsState()

    var selectedPaneIndex by remember { mutableStateOf<Int?>(null) }
    var showRateLimitDialog by remember { mutableStateOf(false) }

    // Derive selected pane from live data so it auto-updates
    val selectedPane = selectedPaneIndex?.let { idx -> panes.find { it.index == idx } }

    LaunchedEffect(Unit) {
        val prefs = context.getSharedPreferences("shogun_prefs", android.content.Context.MODE_PRIVATE)
        val host = prefs.getString("ssh_host", "192.168.1.1") ?: "192.168.1.1"
        val port = prefs.getString("ssh_port", "22")?.toIntOrNull() ?: 22
        val user = prefs.getString("ssh_user", "") ?: ""
        val keyPath = prefs.getString("ssh_key_path", "") ?: ""
        val password = prefs.getString("ssh_password", "") ?: ""
        viewModel.connect(host, port, user, keyPath, password)
    }

    // Pause refresh when app is in background
    val lifecycleOwner = LocalLifecycleOwner.current
    DisposableEffect(lifecycleOwner) {
        val observer = LifecycleEventObserver { _, event ->
            when (event) {
                Lifecycle.Event.ON_RESUME -> viewModel.resumeRefresh()
                Lifecycle.Event.ON_PAUSE -> viewModel.pauseRefresh()
                else -> {}
            }
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose { lifecycleOwner.lifecycle.removeObserver(observer) }
    }

    if (selectedPane != null) {
        // Full screen pane detail — always reads from live panes list
        PaneFullScreen(
            pane = selectedPane,
            onBack = { selectedPaneIndex = null },
            onSendCommand = { cmd ->
                viewModel.sendCommandToPane(selectedPane.index, cmd)
            },
            onRefresh = { viewModel.refreshAllPanes() }
        )
    } else {
        // Grid view
        Box(
            modifier = Modifier
                .fillMaxSize()
                .background(Color(0xFF1A1A1A))
        ) {
            Image(
                painter = painterResource(R.drawable.bg_agents),
                contentDescription = null,
                contentScale = ContentScale.Crop,
                alpha = 0.55f,
                modifier = Modifier.fillMaxSize()
            )
            Column(modifier = Modifier.fillMaxSize()) {
                if (errorMessage != null) {
                    Text(
                        text = "エラー: $errorMessage",
                        color = MaterialTheme.colorScheme.error,
                        modifier = Modifier.padding(8.dp)
                    )
                }

                LazyVerticalGrid(
                    columns = GridCells.Fixed(2),
                    modifier = Modifier.fillMaxSize(),
                    contentPadding = PaddingValues(start = 8.dp, end = 8.dp, top = 8.dp, bottom = 72.dp),
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                    verticalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                    items(panes) { pane ->
                        PaneCard(
                            pane = pane,
                            onClick = { selectedPaneIndex = pane.index }
                        )
                    }
                }
            }

            // Rate limit check button (bottom-right)
            FloatingActionButton(
                onClick = {
                    showRateLimitDialog = true
                    viewModel.execRateLimitCheck()
                },
                modifier = Modifier
                    .align(Alignment.BottomEnd)
                    .padding(16.dp)
                    .size(48.dp),
                containerColor = Color(0xFF2D2D2D),
                contentColor = Color(0xFFC9A94E)
            ) {
                Icon(
                    imageVector = Icons.Default.Speed,
                    contentDescription = "使用量",
                    modifier = Modifier.size(24.dp)
                )
            }
        }

        // Rate limit dialog
        if (showRateLimitDialog) {
            AlertDialog(
                onDismissRequest = {
                    showRateLimitDialog = false
                    viewModel.clearRateLimitResult()
                },
                title = {
                    Text("Claude レートリミット", color = Color(0xFFC9A94E))
                },
                text = {
                    if (rateLimitLoading) {
                        Box(
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(vertical = 16.dp),
                            contentAlignment = Alignment.Center
                        ) {
                            CircularProgressIndicator(color = Color(0xFFC9A94E))
                        }
                    } else {
                        RateLimitContent(rawText = rateLimitResult ?: "")
                    }
                },
                confirmButton = {
                    TextButton(onClick = {
                        showRateLimitDialog = false
                        viewModel.clearRateLimitResult()
                    }) {
                        Text("閉じる", color = Color(0xFFC9A94E))
                    }
                },
                containerColor = Color(0xFF2D2D2D),
                titleContentColor = Color(0xFFC9A94E),
                textContentColor = Color(0xFFE8DCC8)
            )
        }
    }
}

@Composable
fun PaneCard(
    pane: PaneInfo,
    onClick: () -> Unit
) {
    Card(
        modifier = Modifier
            .fillMaxWidth()
            .height(160.dp)
            .clickable(onClick = onClick),
        colors = CardDefaults.cardColors(containerColor = Color(0x802D2D2D))
    ) {
        Column(modifier = Modifier.padding(8.dp)) {
            Text(
                text = pane.agentId.ifBlank { "pane${pane.index}" },
                color = Color(0xFFC9A94E),
                fontSize = 12.sp,
                fontFamily = FontFamily.Monospace
            )
            Spacer(modifier = Modifier.height(4.dp))
            Text(
                text = parseAnsiColors(pane.content),
                color = Color(0xFFE8DCC8),
                fontSize = 10.sp,
                fontFamily = FontFamily.Monospace,
                maxLines = 10,
                overflow = TextOverflow.Ellipsis
            )
        }
    }
}

@Composable
fun PaneFullScreen(
    pane: PaneInfo,
    onBack: () -> Unit,
    onSendCommand: (String) -> Unit,
    onRefresh: () -> Unit
) {
    val context = LocalContext.current
    var commandTextValue by remember { mutableStateOf(TextFieldValue("")) }
    var isListening by remember { mutableStateOf(false) }
    val speechRecognizer = remember { SpeechRecognizer.createSpeechRecognizer(context) }
    val listState = rememberLazyListState()
    val lines = remember(pane.content) { pane.content.lines() }

    DisposableEffect(Unit) {
        onDispose { speechRecognizer.destroy() }
    }

    val permissionLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission()
    ) { granted ->
        if (granted) {
            startContinuousListening(speechRecognizer, { isListening }) { result ->
                val newText = if (commandTextValue.text.isEmpty()) result else "${commandTextValue.text} $result"
                commandTextValue = TextFieldValue(text = newText, selection = TextRange(newText.length))
            }
            isListening = true
        }
    }

    // Auto-scroll to bottom
    LaunchedEffect(lines.size) {
        if (lines.isNotEmpty()) {
            listState.scrollToItem(lines.size - 1)
        }
    }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(Color(0xFF1A1A1A))
    ) {
        Image(
            painter = painterResource(R.drawable.bg_agents),
            contentDescription = null,
            contentScale = ContentScale.Crop,
            alpha = 0.55f,
            modifier = Modifier.fillMaxSize()
        )
    Column(
        modifier = Modifier.fillMaxSize()
    ) {
        // Top bar with agent name and back button
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .background(Color(0x802D2D2D))
                .padding(horizontal = 8.dp, vertical = 4.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            IconButton(onClick = onBack) {
                Icon(
                    imageVector = Icons.Default.ArrowBack,
                    contentDescription = "戻る",
                    tint = Color(0xFFC9A94E)
                )
            }
            Text(
                text = pane.agentId.ifBlank { "pane${pane.index}" },
                color = Color(0xFFC9A94E),
                fontSize = 16.sp,
                fontFamily = FontFamily.Monospace,
                modifier = Modifier.weight(1f)
            )
        }

        // Full screen pane content
        Box(
            modifier = Modifier
                .weight(1f)
                .fillMaxWidth()
                .horizontalScroll(rememberScrollState())
        ) {
        LazyColumn(
            state = listState,
            modifier = Modifier
                .fillMaxHeight()
                .padding(horizontal = 8.dp, vertical = 4.dp)
        ) {
            items(lines) { line ->
                Text(
                    text = parseAnsiColors(line),
                    color = Color(0xFFE8DCC8),
                    fontFamily = FontFamily.Monospace,
                    fontSize = 13.sp,
                    softWrap = false
                )
            }
        }
        } // Box (horizontal scroll)

        // Special keys bar
        SpecialKeysRow(onSendKey = { onSendCommand(it) })

        // Command input at bottom
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(8.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            OutlinedTextField(
                value = commandTextValue,
                onValueChange = { commandTextValue = it },
                modifier = Modifier.weight(1f),
                placeholder = { Text("コマンドを入力") },
                singleLine = true
            )
            Spacer(modifier = Modifier.width(4.dp))
            // Voice input button
            IconButton(
                onClick = {
                    if (ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO)
                        == PackageManager.PERMISSION_GRANTED
                    ) {
                        if (isListening) {
                            speechRecognizer.cancel()
                            isListening = false
                        } else {
                            startContinuousListening(speechRecognizer, { isListening }) { result ->
                                val newText = if (commandTextValue.text.isEmpty()) result else "${commandTextValue.text} $result"
                                commandTextValue = TextFieldValue(text = newText, selection = TextRange(newText.length))
                            }
                            isListening = true
                        }
                    } else {
                        permissionLauncher.launch(Manifest.permission.RECORD_AUDIO)
                    }
                }
            ) {
                Icon(
                    imageVector = Icons.Default.Mic,
                    contentDescription = "音声入力",
                    tint = if (isListening) Color(0xFFCC3333) else Color(0xFFC9A94E)
                )
            }
            Spacer(modifier = Modifier.width(4.dp))
            IconButton(
                onClick = {
                    if (commandTextValue.text.isNotBlank()) {
                        onSendCommand(commandTextValue.text)
                        commandTextValue = TextFieldValue("")
                    }
                },
                enabled = commandTextValue.text.isNotBlank() && !isListening
            ) {
                Icon(
                    imageVector = Icons.Default.Send,
                    contentDescription = "送信",
                    tint = if (commandTextValue.text.isNotBlank() && !isListening) Color(0xFFC9A94E) else Color(0xFF666666)
                )
            }
        }
    } // Column
    } // Box
}

// ── Rate Limit UI ─────────────────────────────────────────────────────────────
@Composable
private fun RateLimitContent(rawText: String) {
    val (claudeMax, codexEntries) = remember(rawText) { parseRateLimitResult(rawText) }
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .verticalScroll(rememberScrollState()),
        verticalArrangement = Arrangement.spacedBy(6.dp)
    ) {
        // ── Claude Max section ──
        Text("Claude Max", color = Color(0xFFC9A94E), fontSize = 13.sp, fontFamily = FontFamily.Monospace)
        Box(modifier = Modifier.fillMaxWidth().height(1.dp).background(Color(0xFF555555)))

        claudeMax.window5h?.let { w ->
            val color = rateLimitBarColor(w.percent)
            Text("5時間枠", color = Color(0xFFE8DCC8), fontSize = 12.sp)
            LinearProgressIndicator(
                progress = { w.percent / 100f },
                modifier = Modifier.fillMaxWidth(),
                color = color,
                trackColor = Color(0xFF444444)
            )
            Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                Text("${w.percent}%", color = color, fontSize = 11.sp)
                Text(formatResetTime(w.resetStr), color = Color(0xFF888888), fontSize = 11.sp)
            }
        }

        claudeMax.window7d?.let { w ->
            val color = rateLimitBarColor(w.percent)
            Text("7日枠", color = Color(0xFFE8DCC8), fontSize = 12.sp)
            LinearProgressIndicator(
                progress = { w.percent / 100f },
                modifier = Modifier.fillMaxWidth(),
                color = color,
                trackColor = Color(0xFF444444)
            )
            Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                Text("${w.percent}%", color = color, fontSize = 11.sp)
                Text(formatResetTime(w.resetStr), color = Color(0xFF888888), fontSize = 11.sp)
            }
            if (claudeMax.sonnet7d != null || claudeMax.opus7d != null) {
                Row(horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                    claudeMax.sonnet7d?.let { Text("Sonnet: ${it}%", color = Color(0xFF888888), fontSize = 11.sp) }
                    claudeMax.opus7d?.let   { Text("Opus: ${it}%",   color = Color(0xFF888888), fontSize = 11.sp) }
                }
            }
        }

        claudeMax.todayTokens?.let { tokens ->
            Text("本日トークン", color = Color(0xFFE8DCC8), fontSize = 12.sp)
            Text(tokens, color = Color(0xFFC9A94E), fontSize = 15.sp, fontFamily = FontFamily.Monospace)
        }

        if (claudeMax.sessions != null || claudeMax.messages != null) {
            Row(horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                claudeMax.sessions?.let { Text("セッション: $it", color = Color(0xFF888888), fontSize = 11.sp) }
                claudeMax.messages?.let { Text("メッセージ: $it", color = Color(0xFF888888), fontSize = 11.sp) }
            }
        }

        // ── Codex section (only if data present) ──
        if (codexEntries.isNotEmpty()) {
            Spacer(modifier = Modifier.height(4.dp))
            Text("Codex コンテキスト残量", color = Color(0xFFC9A94E), fontSize = 13.sp, fontFamily = FontFamily.Monospace)
            Box(modifier = Modifier.fillMaxWidth().height(1.dp).background(Color(0xFF555555)))
            codexEntries.forEach { entry ->
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                    Text(
                        "ash${entry.ashigaru}",
                        color = Color(0xFFE8DCC8),
                        fontSize = 11.sp,
                        fontFamily = FontFamily.Monospace,
                        modifier = Modifier.width(40.dp)
                    )
                    if (entry.percent != null) {
                        val color = rateLimitBarColor(entry.percent)
                        LinearProgressIndicator(
                            progress = { entry.percent / 100f },
                            modifier = Modifier.weight(1f),
                            color = color,
                            trackColor = Color(0xFF444444)
                        )
                        Text("${entry.percent.toInt()}%", color = color, fontSize = 11.sp)
                    } else {
                        LinearProgressIndicator(
                            progress = { 0f },
                            modifier = Modifier.weight(1f),
                            color = Color(0xFF555555),
                            trackColor = Color(0xFF444444)
                        )
                        Text("---", color = Color(0xFF888888), fontSize = 11.sp)
                    }
                }
            }
        }
    }
}
