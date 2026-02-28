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
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.viewmodel.compose.viewModel
import com.shogun.android.R
import com.shogun.android.viewmodel.AgentsViewModel
import com.shogun.android.viewmodel.PaneInfo

@Composable
fun AgentsScreen(
    viewModel: AgentsViewModel = viewModel()
) {
    val context = LocalContext.current
    val panes by viewModel.panes.collectAsState()
    val errorMessage by viewModel.errorMessage.collectAsState()
    val rateLimitLoading by viewModel.rateLimitLoading.collectAsState()
    val rateLimitResult by viewModel.rateLimitResult.collectAsState()

    var selectedPane by remember { mutableStateOf<PaneInfo?>(null) }
    var showRateLimitDialog by remember { mutableStateOf(false) }

    LaunchedEffect(Unit) {
        val prefs = context.getSharedPreferences("shogun_prefs", android.content.Context.MODE_PRIVATE)
        val host = prefs.getString("ssh_host", "192.168.0.1") ?: "192.168.0.1"
        val port = prefs.getString("ssh_port", "22")?.toIntOrNull() ?: 22
        val user = prefs.getString("ssh_user", "yohei") ?: "yohei"
        val keyPath = prefs.getString("ssh_key_path", "") ?: ""
        val password = prefs.getString("ssh_password", "") ?: ""
        viewModel.connect(host, port, user, keyPath, password)
    }

    if (selectedPane != null) {
        // Full screen pane detail
        PaneFullScreen(
            pane = selectedPane!!,
            onBack = { selectedPane = null },
            onSendCommand = { cmd ->
                viewModel.sendCommandToPane(selectedPane!!.index, cmd)
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
                            onClick = { selectedPane = pane }
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
                        Column(
                            modifier = Modifier
                                .fillMaxWidth()
                                .verticalScroll(rememberScrollState())
                        ) {
                            Text(
                                text = rateLimitResult ?: "",
                                fontFamily = FontFamily.Monospace,
                                fontSize = 11.sp,
                                color = Color(0xFFE8DCC8)
                            )
                        }
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
        colors = CardDefaults.cardColors(containerColor = Color(0xFF2D2D2D))
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
    var commandText by remember { mutableStateOf("") }
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
            startContinuousListening(speechRecognizer) { result ->
                commandText = if (commandText.isEmpty()) result else "$commandText $result"
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
                .background(Color(0xFF2D2D2D))
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
        LazyColumn(
            state = listState,
            modifier = Modifier
                .weight(1f)
                .fillMaxWidth()
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
                value = commandText,
                onValueChange = { commandText = it },
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
                            speechRecognizer.stopListening()
                            isListening = false
                        } else {
                            startContinuousListening(speechRecognizer) { result ->
                                commandText = if (commandText.isEmpty()) result else "$commandText $result"
                                isListening = false
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
                    if (commandText.isNotBlank()) {
                        onSendCommand(commandText)
                        commandText = ""
                    }
                },
                enabled = commandText.isNotBlank() && !isListening
            ) {
                Icon(
                    imageVector = Icons.Default.Send,
                    contentDescription = "送信",
                    tint = if (commandText.isNotBlank() && !isListening) Color(0xFFC9A94E) else Color(0xFF666666)
                )
            }
        }
    } // Column
    } // Box
}
