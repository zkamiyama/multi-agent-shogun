package com.shogun.android.viewmodel

import android.app.Application
import android.content.Context
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.shogun.android.ssh.SshManager
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

data class PaneInfo(
    val index: Int,
    val agentId: String,
    val content: String
)

class AgentsViewModel(application: Application) : AndroidViewModel(application) {

    private val sshManager = SshManager.getInstance()

    private val _panes = MutableStateFlow<List<PaneInfo>>(emptyList())
    val panes: StateFlow<List<PaneInfo>> = _panes

    private val _isConnected = MutableStateFlow(false)
    val isConnected: StateFlow<Boolean> = _isConnected

    private val _errorMessage = MutableStateFlow<String?>(null)
    val errorMessage: StateFlow<String?> = _errorMessage

    private val _rateLimitResult = MutableStateFlow<String?>(null)
    val rateLimitResult: StateFlow<String?> = _rateLimitResult

    private val _rateLimitLoading = MutableStateFlow(false)
    val rateLimitLoading: StateFlow<Boolean> = _rateLimitLoading

    private var refreshJob: Job? = null
    @Volatile private var paused = false
    @Volatile private var isRefreshing = false

    fun pauseRefresh() { paused = true }
    fun resumeRefresh() {
        paused = false
        viewModelScope.launch { refreshAllPanesInternal() }
    }

    fun connect(host: String, port: Int, user: String, keyPath: String, password: String = "") {
        viewModelScope.launch {
            val result = sshManager.connect(host, port, user, keyPath, password)
            if (result.isSuccess) {
                _isConnected.value = true
                startAutoRefresh()
            } else {
                _errorMessage.value = "接続失敗: ${result.exceptionOrNull()?.message}"
            }
        }
    }

    private fun startAutoRefresh() {
        refreshJob?.cancel()
        refreshJob = viewModelScope.launch {
            while (isActive) {
                if (!paused && !isRefreshing) {
                    refreshAllPanesInternal()
                }
                delay(5000)
            }
        }
    }

    fun refreshAllPanes() {
        viewModelScope.launch { refreshAllPanesInternal() }
    }

    private suspend fun refreshAllPanesInternal() {
        if (isRefreshing) return
        isRefreshing = true
        try {
            val prefs = getApplication<Application>().getSharedPreferences("shogun_prefs", Context.MODE_PRIVATE)
            val agentsSession = prefs.getString("agents_session", "multiagent") ?: "multiagent"
            // Batch all pane queries into a single SSH command
            val batchCmd = buildString {
                append("for i in 0 1 2 3 4 5 6 7; do ")
                append("echo \"===ID\$i===\"; ")
                append("/usr/bin/tmux display-message -t $agentsSession:0.\$i -p '#{@agent_id}' 2>/dev/null || echo \"pane\$i\"; ")
                append("echo \"===CONTENT\$i===\"; ")
                append("/usr/bin/tmux capture-pane -t $agentsSession:0.\$i -p -S -50 2>/dev/null; ")
                append("done")
            }
            val result = sshManager.execCommand(batchCmd)
            if (result.isSuccess) {
                val output = result.getOrDefault("")
                val newPanes = parseBatchOutput(output)
                _panes.value = newPanes
                _errorMessage.value = null
            }
        } finally {
            isRefreshing = false
        }
    }

    private fun parseBatchOutput(output: String): List<PaneInfo> {
        val panes = mutableListOf<PaneInfo>()
        for (i in 0..7) {
            val idMarker = "===ID$i==="
            val contentMarker = "===CONTENT$i==="
            val nextIdMarker = "===ID${i + 1}==="

            val idStart = output.indexOf(idMarker)
            val contentStart = output.indexOf(contentMarker)
            if (idStart == -1 || contentStart == -1) {
                panes.add(PaneInfo(index = i, agentId = "pane$i", content = ""))
                continue
            }

            val agentId = output.substring(idStart + idMarker.length, contentStart).trim()
            val contentEnd = if (i < 7) {
                val next = output.indexOf(nextIdMarker)
                if (next != -1) next else output.length
            } else {
                output.length
            }
            val content = output.substring(contentStart + contentMarker.length, contentEnd).trim()
            panes.add(PaneInfo(index = i, agentId = agentId, content = content))
        }
        return panes
    }

    fun sendCommandToPane(paneIndex: Int, text: String) {
        viewModelScope.launch {
            if (!sshManager.isConnected()) {
                _errorMessage.value = "SSH未接続"
                return@launch
            }
            val prefs = getApplication<Application>().getSharedPreferences("shogun_prefs", Context.MODE_PRIVATE)
            val agentsSession = prefs.getString("agents_session", "multiagent") ?: "multiagent"
            val escaped = text.replace("'", "'\\''")
            // Send text and Enter SEPARATELY with 0.3s gap (Claude Code requirement)
            sshManager.execCommand("/usr/bin/tmux send-keys -t $agentsSession:0.$paneIndex '$escaped'")
            delay(300)
            sshManager.execCommand("/usr/bin/tmux send-keys -t $agentsSession:0.$paneIndex Enter")
            delay(1000)
            refreshAllPanes()
        }
    }

    fun execRateLimitCheck() {
        viewModelScope.launch {
            _rateLimitLoading.value = true
            _rateLimitResult.value = null
            val prefs = getApplication<Application>().getSharedPreferences("shogun_prefs", Context.MODE_PRIVATE)
            val projectPath = prefs.getString("project_path", "") ?: ""
            if (projectPath.isBlank()) {
                _rateLimitLoading.value = false
                _rateLimitResult.value = "設定画面でプロジェクトパスを設定してください"
                return@launch
            }
            val result = sshManager.execCommand("bash $projectPath/scripts/ratelimit_check.sh")
            _rateLimitLoading.value = false
            _rateLimitResult.value = result.getOrElse { "取得失敗: ${it.message}" }
        }
    }

    fun clearRateLimitResult() {
        _rateLimitResult.value = null
    }

    override fun onCleared() {
        super.onCleared()
        refreshJob?.cancel()
        sshManager.disconnect()
    }
}
