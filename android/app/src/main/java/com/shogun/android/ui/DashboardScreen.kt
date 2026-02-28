package com.shogun.android.ui

import android.widget.TextView
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.lifecycle.viewmodel.compose.viewModel
import com.google.accompanist.swiperefresh.SwipeRefresh
import com.google.accompanist.swiperefresh.rememberSwipeRefreshState
import com.shogun.android.R
import com.shogun.android.viewmodel.DashboardViewModel
import io.noties.markwon.Markwon
import io.noties.markwon.ext.tables.TablePlugin

@Composable
fun DashboardScreen(
    viewModel: DashboardViewModel = viewModel()
) {
    val context = LocalContext.current
    val markdownContent by viewModel.markdownContent.collectAsState()
    val isLoading by viewModel.isLoading.collectAsState()
    val errorMessage by viewModel.errorMessage.collectAsState()

    val markwon = remember {
        Markwon.builder(context)
            .usePlugin(TablePlugin.create(context))
            .build()
    }

    LaunchedEffect(Unit) {
        val prefs = context.getSharedPreferences("shogun_prefs", android.content.Context.MODE_PRIVATE)
        val host = prefs.getString("ssh_host", "192.168.1.1") ?: "192.168.1.1"
        val port = prefs.getString("ssh_port", "22")?.toIntOrNull() ?: 22
        val user = prefs.getString("ssh_user", "") ?: ""
        val keyPath = prefs.getString("ssh_key_path", "") ?: ""
        val password = prefs.getString("ssh_password", "") ?: ""
        viewModel.connect(host, port, user, keyPath, password)
    }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(Color(0xFF1A1A1A))
    ) {
        Image(
            painter = painterResource(R.drawable.bg_castle),
            contentDescription = null,
            contentScale = ContentScale.Crop,
            alpha = 0.55f,
            modifier = Modifier.fillMaxSize()
        )
        SwipeRefresh(
            state = rememberSwipeRefreshState(isLoading),
            onRefresh = { viewModel.loadDashboard() }
        ) {
            Column(
                modifier = Modifier
                    .fillMaxSize()
                    .padding(16.dp)
                    .verticalScroll(rememberScrollState())
            ) {
            if (errorMessage != null) {
                Text(
                    text = "エラー: $errorMessage",
                    color = MaterialTheme.colorScheme.error
                )
            } else if (markdownContent.isBlank() && !isLoading) {
                Box(
                    modifier = Modifier.fillMaxSize(),
                    contentAlignment = Alignment.Center
                ) {
                    Text("プルダウンで更新")
                }
            } else {
                AndroidView(
                    factory = { ctx ->
                        TextView(ctx).apply {
                            textSize = 14f
                            setTextColor(android.graphics.Color.parseColor("#E8DCC8"))  // Zouge
                            setLinkTextColor(android.graphics.Color.parseColor("#D4B96A"))  // LinkGold
                        }
                    },
                    update = { textView ->
                        markwon.setMarkdown(textView, markdownContent)
                    },
                    modifier = Modifier.fillMaxWidth()
                )
            }
            } // Column
        } // SwipeRefresh
    } // Box
}
