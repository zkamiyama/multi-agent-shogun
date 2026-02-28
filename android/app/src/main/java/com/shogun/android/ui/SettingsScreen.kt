package com.shogun.android.ui

import android.content.Context
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp

@Composable
fun SettingsScreen() {
    val context = LocalContext.current
    val prefs = context.getSharedPreferences("shogun_prefs", Context.MODE_PRIVATE)

    var host by remember { mutableStateOf(prefs.getString("ssh_host", "100.112.199.62") ?: "100.112.199.62") }
    var port by remember { mutableStateOf(prefs.getString("ssh_port", "22") ?: "22") }
    var user by remember { mutableStateOf(prefs.getString("ssh_user", "yohei") ?: "yohei") }
    var keyPath by remember { mutableStateOf(prefs.getString("ssh_key_path", "") ?: "") }
    var password by remember { mutableStateOf(prefs.getString("ssh_password", "") ?: "") }
    var shogunSession by remember { mutableStateOf(prefs.getString("shogun_session", "shogun") ?: "shogun") }
    var agentsSession by remember { mutableStateOf(prefs.getString("agents_session", "multiagent") ?: "multiagent") }

    var saved by remember { mutableStateOf(false) }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(Color(0xFF1A1A1A))
            .padding(16.dp)
            .verticalScroll(rememberScrollState()),
        verticalArrangement = Arrangement.spacedBy(12.dp)
    ) {
        Text("SSH設定", style = MaterialTheme.typography.titleLarge, color = Color(0xFFC9A94E))

        OutlinedTextField(
            value = host,
            onValueChange = { host = it },
            label = { Text("SSHホスト") },
            modifier = Modifier.fillMaxWidth(),
            singleLine = true
        )

        OutlinedTextField(
            value = port,
            onValueChange = { port = it },
            label = { Text("SSHポート") },
            modifier = Modifier.fillMaxWidth(),
            singleLine = true,
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number)
        )

        OutlinedTextField(
            value = user,
            onValueChange = { user = it },
            label = { Text("SSHユーザー") },
            modifier = Modifier.fillMaxWidth(),
            singleLine = true
        )

        OutlinedTextField(
            value = keyPath,
            onValueChange = { keyPath = it },
            label = { Text("SSH秘密鍵パス") },
            modifier = Modifier.fillMaxWidth(),
            singleLine = true
        )

        OutlinedTextField(
            value = password,
            onValueChange = { password = it },
            label = { Text("SSHパスワード（鍵なし時に使用）") },
            modifier = Modifier.fillMaxWidth(),
            singleLine = true,
            visualTransformation = PasswordVisualTransformation()
        )

        Divider()

        Text("セッション設定", style = MaterialTheme.typography.titleMedium, color = Color(0xFFC9A94E))

        OutlinedTextField(
            value = shogunSession,
            onValueChange = { shogunSession = it },
            label = { Text("将軍セッション名") },
            modifier = Modifier.fillMaxWidth(),
            singleLine = true
        )

        OutlinedTextField(
            value = agentsSession,
            onValueChange = { agentsSession = it },
            label = { Text("エージェントセッション名") },
            modifier = Modifier.fillMaxWidth(),
            singleLine = true
        )

        Button(
            onClick = {
                prefs.edit()
                    .putString("ssh_host", host)
                    .putString("ssh_port", port)
                    .putString("ssh_user", user)
                    .putString("ssh_key_path", keyPath)
                    .putString("ssh_password", password)
                    .putString("shogun_session", shogunSession)
                    .putString("agents_session", agentsSession)
                    .apply()
                saved = true
            },
            modifier = Modifier.fillMaxWidth(),
            colors = ButtonDefaults.buttonColors(
                containerColor = Color(0xFFB33B24),
                contentColor = Color.White
            ),
            shape = RoundedCornerShape(4.dp)
        ) {
            Text("保存")
        }

        if (saved) {
            Text(
                text = "設定を保存しました",
                color = MaterialTheme.colorScheme.primary
            )
        }
    }
}
