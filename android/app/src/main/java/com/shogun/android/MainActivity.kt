package com.shogun.android

import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.media.MediaPlayer
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.lifecycle.lifecycleScope
import com.shogun.android.ssh.SshManager
import kotlinx.coroutines.launch
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Home
import androidx.compose.material.icons.filled.List
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Star
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.navigation.NavGraph.Companion.findStartDestination
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.currentBackStackEntryAsState
import androidx.navigation.compose.rememberNavController
import com.shogun.android.ui.AgentsScreen
import com.shogun.android.ui.DashboardScreen
import com.shogun.android.ui.SettingsScreen
import com.shogun.android.ui.ShogunScreen
import com.shogun.android.ui.theme.ShogunTheme

sealed class Screen(val route: String, val label: String, val icon: ImageVector) {
    object Shogun : Screen("shogun", "将軍", Icons.Default.Star)
    object Agents : Screen("agents", "エージェント", Icons.Default.List)
    object Dashboard : Screen("dashboard", "ダッシュボード", Icons.Default.Home)
    object Settings : Screen("settings", "設定", Icons.Default.Settings)
}

val bottomNavItems = listOf(
    Screen.Shogun,
    Screen.Agents,
    Screen.Dashboard,
    Screen.Settings
)

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent {
            ShogunTheme {
                ShogunApp()
            }
        }
        handleShareIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleShareIntent(intent)
    }

    private fun handleShareIntent(intent: Intent) {
        val imageUris: List<Uri> = when (intent.action) {
            Intent.ACTION_SEND -> {
                val uri = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
                } else {
                    @Suppress("DEPRECATION")
                    intent.getParcelableExtra(Intent.EXTRA_STREAM)
                }
                listOfNotNull(uri)
            }
            Intent.ACTION_SEND_MULTIPLE -> {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java)
                } else {
                    @Suppress("DEPRECATION")
                    intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM)
                } ?: emptyList()
            }
            else -> return
        }
        if (imageUris.isEmpty()) return

        val sshManager = SshManager.getInstance()
        if (!sshManager.isConnected()) {
            Toast.makeText(this, "❌ SSH未接続。先にアプリを開いて接続してください", Toast.LENGTH_LONG).show()
            return
        }

        val prefs = getSharedPreferences("shogun_prefs", Context.MODE_PRIVATE)
        val projectPath = prefs.getString("project_path", "") ?: ""
        if (projectPath.isBlank()) {
            Toast.makeText(this, "❌ 設定画面でプロジェクトパスを設定してください", Toast.LENGTH_LONG).show()
            return
        }
        val total = imageUris.size
        Toast.makeText(this, "転送中... (${total}枚)", Toast.LENGTH_SHORT).show()
        lifecycleScope.launch {
            var success = 0
            var failed = 0
            for (uri in imageUris) {
                sshManager.uploadScreenshot(this@MainActivity, uri, projectPath).fold(
                    onSuccess = { success++ },
                    onFailure = { failed++ }
                )
            }
            val msg = if (failed == 0) "✅ ${success}枚 転送完了" else "✅ ${success}枚 完了 / ❌ ${failed}枚 失敗"
            Toast.makeText(this@MainActivity, msg, Toast.LENGTH_LONG).show()
        }
    }
}

@Composable
fun ShogunApp() {
    val context = LocalContext.current
    val navController = rememberNavController()
    val navBackStackEntry by navController.currentBackStackEntryAsState()
    val currentRoute = navBackStackEntry?.destination?.route

    // BGM — 3-track cycling: OFF → shogun → shogun_reiwa → shogun_ashigirls → OFF
    val bgmTracks = remember { listOf(R.raw.shogun, R.raw.shogun_reiwa, R.raw.shogun_ashigirls) }
    var bgmTrackIndex by remember { mutableIntStateOf(-1) } // -1 = OFF
    val audioManager = remember { context.getSystemService(Context.AUDIO_SERVICE) as AudioManager }
    var mediaPlayer by remember { mutableStateOf<MediaPlayer?>(null) }

    // AudioFocus: duck BGM during voice input instead of stopping
    val focusRequest = remember {
        AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_GAME)
                    .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                    .build()
            )
            .setOnAudioFocusChangeListener { focusChange ->
                when (focusChange) {
                    AudioManager.AUDIOFOCUS_LOSS -> {
                        mediaPlayer?.release()
                        mediaPlayer = null
                        bgmTrackIndex = -1
                    }
                }
            }
            .build()
    }

    DisposableEffect(Unit) {
        onDispose {
            audioManager.abandonAudioFocusRequest(focusRequest)
            mediaPlayer?.release()
        }
    }

    Scaffold(
        modifier = Modifier.fillMaxSize(),
        bottomBar = {
            NavigationBar(
                containerColor = Color(0xFF1A1A1A),
                contentColor = Color(0xFFC9A94E),
            ) {
                bottomNavItems.forEach { screen ->
                    NavigationBarItem(
                        icon = { Icon(screen.icon, contentDescription = screen.label) },
                        label = { Text(screen.label) },
                        selected = currentRoute == screen.route,
                        colors = NavigationBarItemDefaults.colors(
                            selectedIconColor = Color(0xFFC9A94E),
                            selectedTextColor = Color(0xFFC9A94E),
                            unselectedIconColor = Color(0xFF666666),
                            unselectedTextColor = Color(0xFF666666),
                            indicatorColor = Color(0xFF2D2D2D),
                        ),
                        onClick = {
                            navController.navigate(screen.route) {
                                popUpTo(navController.graph.findStartDestination().id) {
                                    saveState = true
                                }
                                launchSingleTop = true
                                restoreState = true
                            }
                        }
                    )
                }
            }
        }
    ) { innerPadding ->
        NavHost(
            navController = navController,
            startDestination = Screen.Shogun.route,
            modifier = Modifier.padding(innerPadding)
        ) {
            composable(Screen.Shogun.route) {
                ShogunScreen(
                    mediaPlayer = mediaPlayer,
                    bgmTrackIndex = bgmTrackIndex,
                    onBgmToggle = {
                        // Cycle: -1(OFF) → 0 → 1 → 2 → -1(OFF)
                        val nextIndex = if (bgmTrackIndex >= 2) -1 else bgmTrackIndex + 1
                        // Always release old player — next track starts from beginning
                        mediaPlayer?.release()
                        mediaPlayer = null
                        if (nextIndex == -1) {
                            audioManager.abandonAudioFocusRequest(focusRequest)
                        } else {
                            audioManager.requestAudioFocus(focusRequest)
                            mediaPlayer = MediaPlayer.create(context, bgmTracks[nextIndex])?.apply {
                                isLooping = true
                                setVolume(1.0f, 1.0f)
                                start()
                            }
                        }
                        bgmTrackIndex = nextIndex
                    }
                )
            }
            composable(Screen.Agents.route) { AgentsScreen() }
            composable(Screen.Dashboard.route) { DashboardScreen() }
            composable(Screen.Settings.route) { SettingsScreen() }
        }
    }
}
