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

    fun pauseRefresh() { paused = true }
    fun resumeRefresh() {
        paused = false
        refreshAllPanes()
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
                if (!paused) refreshAllPanes()
                delay(5000)
            }
        }
    }

    fun refreshAllPanes() {
        viewModelScope.launch {
            val prefs = getApplication<Application>().getSharedPreferences("shogun_prefs", Context.MODE_PRIVATE)
            val agentsSession = prefs.getString("agents_session", "multiagent") ?: "multiagent"
            val newPanes = mutableListOf<PaneInfo>()
            for (i in 0..7) {
                val agentIdResult = sshManager.execCommand(
                    "/usr/bin/tmux display-message -t $agentsSession:0.$i -p '#{@agent_id}' 2>/dev/null || echo 'pane$i'"
                )
                val contentResult = sshManager.execCommand(
                    "/usr/bin/tmux capture-pane -t $agentsSession:0.$i -p -e -S -500 2>/dev/null"
                )
                val agentId = agentIdResult.getOrDefault("pane$i").trim()
                val content = contentResult.getOrDefault("").trim()
                newPanes.add(PaneInfo(index = i, agentId = agentId, content = content))
            }
            _panes.value = newPanes
            _errorMessage.value = null
        }
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
