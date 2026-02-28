package com.shogun.android.ssh

import android.content.Context
import android.net.Uri
import com.jcraft.jsch.ChannelSftp
import com.jcraft.jsch.ChannelShell
import com.jcraft.jsch.JSch
import com.jcraft.jsch.Session
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.ByteArrayOutputStream
import java.io.OutputStream
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.Properties

class SshManager private constructor() {

    companion object {
        @Volatile private var INSTANCE: SshManager? = null
        fun getInstance(): SshManager = INSTANCE ?: synchronized(this) {
            INSTANCE ?: SshManager().also { INSTANCE = it }
        }
    }

    private var session: Session? = null
    private var shellChannel: ChannelShell? = null
    @Volatile private var shellOutputStream: OutputStream? = null
    private var readerThread: Thread? = null

    // Stored for reconnect
    private var lastHost = ""
    private var lastPort = 22
    private var lastUser = ""
    private var lastKeyPath = ""
    private var lastPassword = ""

    var outputCallback: ((String) -> Unit)? = null
    var disconnectCallback: (() -> Unit)? = null

    suspend fun connect(
        host: String,
        port: Int,
        user: String,
        privateKeyPath: String,
        password: String = "",
        onOutput: ((String) -> Unit)? = null,
        onDisconnect: (() -> Unit)? = null
    ): Result<Unit> = withContext(Dispatchers.IO) {
        if (onOutput != null) outputCallback = onOutput
        if (onDisconnect != null) disconnectCallback = onDisconnect

        if (isConnected()) return@withContext Result.success(Unit)

        lastHost = host
        lastPort = port
        lastUser = user
        lastKeyPath = privateKeyPath
        lastPassword = password
        connectInternal()
    }

    private fun connectInternal(): Result<Unit> {
        return try {
            val trimmedPassword = lastPassword.trim()
            val jsch = JSch()
            if (lastKeyPath.isNotBlank()) {
                jsch.addIdentity(lastKeyPath)
            }
            val newSession = jsch.getSession(lastUser, lastHost, lastPort)
            val config = Properties()
            config["StrictHostKeyChecking"] = "no"
            config["MaxAuthTries"] = "2"
            if (lastKeyPath.isNotBlank()) {
                config["PreferredAuthentications"] = "publickey"
            } else {
                config["PreferredAuthentications"] = "keyboard-interactive,password"
            }
            newSession.setConfig(config)
            if (lastKeyPath.isBlank() && trimmedPassword.isNotEmpty()) {
                newSession.setPassword(trimmedPassword)
            }
            var passwordAttempted = false
            val userInfo = object : com.jcraft.jsch.UserInfo {
                override fun getPassword(): String = trimmedPassword
                override fun promptPassword(message: String): Boolean {
                    if (passwordAttempted) return false
                    passwordAttempted = true
                    return true
                }
                override fun promptPassphrase(message: String): Boolean = true
                override fun getPassphrase(): String = ""
                override fun promptYesNo(message: String): Boolean = true
                override fun showMessage(message: String) {}
            }
            newSession.userInfo = userInfo
            newSession.connect(10000)
            session = newSession
            openShell()
            Result.success(Unit)
        } catch (e: Exception) {
            Result.failure(Exception("SSH接続失敗 (pw=${lastPassword.trim().length}文字): ${e.message}", e))
        }
    }

    private fun openShell() {
        val s = session ?: return
        val channel = s.openChannel("shell") as ChannelShell
        channel.setPty(false)
        channel.connect(5000)
        shellChannel = channel
        shellOutputStream = channel.outputStream

        readerThread?.interrupt()
        readerThread = Thread {
            val inputStream = channel.inputStream
            val buffer = ByteArray(4096)
            try {
                while (!Thread.currentThread().isInterrupted) {
                    val n = inputStream.read(buffer)
                    if (n == -1) {
                        disconnectCallback?.invoke()
                        break
                    }
                    if (n > 0) {
                        outputCallback?.invoke(String(buffer, 0, n, Charsets.UTF_8))
                    }
                }
            } catch (_: InterruptedException) {
                Thread.currentThread().interrupt()
            } catch (_: Exception) {
                disconnectCallback?.invoke()
            }
        }.apply { isDaemon = true; start() }
    }

    fun sendCommand(cmd: String) {
        try {
            shellOutputStream?.let {
                it.write((cmd + "\n").toByteArray(Charsets.UTF_8))
                it.flush()
            }
        } catch (_: Exception) {
            // Disconnect detected by reader thread
        }
    }

    fun isConnected(): Boolean = session?.isConnected == true

    suspend fun execCommand(cmd: String): Result<String> = withContext(Dispatchers.IO) {
        val s = session
        if (s == null || !s.isConnected) {
            return@withContext Result.failure(IllegalStateException("SSH not connected"))
        }
        try {
            val channel = s.openChannel("exec")
            val execChannel = channel as com.jcraft.jsch.ChannelExec
            execChannel.setCommand(cmd)
            val outputStream = ByteArrayOutputStream()
            execChannel.outputStream = outputStream
            execChannel.connect(5000)
            while (!execChannel.isClosed) {
                Thread.sleep(100)
            }
            execChannel.disconnect()
            Result.success(outputStream.toString("UTF-8"))
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    suspend fun reconnect(maxAttempts: Int = 3, delayMs: Long = 5000): Result<Unit> =
        withContext(Dispatchers.IO) {
            var lastError: Exception? = null
            for (attempt in 0 until maxAttempts) {
                cleanupChannels()
                val result = if (session?.isConnected == true) {
                    try {
                        openShell()
                        Result.success(Unit)
                    } catch (e: Exception) {
                        Result.failure(e)
                    }
                } else {
                    session?.disconnect()
                    session = null
                    connectInternal()
                }
                if (result.isSuccess) return@withContext Result.success(Unit)
                lastError = result.exceptionOrNull() as? Exception
                if (attempt < maxAttempts - 1) Thread.sleep(delayMs)
            }
            Result.failure(lastError ?: Exception("再接続失敗（${maxAttempts}回試行）"))
        }

    private fun cleanupChannels() {
        readerThread?.interrupt()
        shellChannel?.disconnect()
        shellChannel = null
        shellOutputStream = null
    }

    suspend fun uploadScreenshot(context: Context, imageUri: Uri): Result<String> =
        withContext(Dispatchers.IO) {
            val s = session
            if (s == null || !s.isConnected) {
                return@withContext Result.failure(IllegalStateException("SSH not connected"))
            }
            try {
                val timestamp = SimpleDateFormat("yyyyMMdd_HHmmss", Locale.getDefault()).format(Date())
                val fileName = "screenshot_$timestamp.png"
                val remoteDir = "/mnt/c/tools/multi-agent-shogun/queue/screenshots"
                val remotePath = "$remoteDir/$fileName"

                val channelSftp = s.openChannel("sftp") as ChannelSftp
                channelSftp.connect(5000)
                try {
                    try { channelSftp.mkdir(remoteDir) } catch (_: Exception) { /* already exists */ }
                    context.contentResolver.openInputStream(imageUri)?.use { inputStream ->
                        channelSftp.put(inputStream, remotePath)
                    } ?: return@withContext Result.failure(Exception("Cannot open image URI"))
                    Result.success(fileName)
                } finally {
                    channelSftp.disconnect()
                }
            } catch (e: Exception) {
                Result.failure(e)
            }
        }

    fun disconnect() {
        cleanupChannels()
        session?.disconnect()
        session = null
    }
}
