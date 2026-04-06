# ============================================================
#  MioTTS One-Click Launcher
#  Already installed/running processes are automatically skipped
# ============================================================

# ==============================
# Configuration
# ==============================
$OLLAMA_PORT     = 11434
$OLLAMA_MODEL    = "hf.co/Aratako/MioTTS-GGUF:MioTTS-1.2B-BF16.gguf"
$MIOTTS_API_PORT = 8001
$GRADIO_PORT     = 7860
$LLM_BASE_URL    = "http://localhost:$OLLAMA_PORT/v1"

# ==============================
# Internal
# ==============================
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$LogFile   = Join-Path $ScriptDir "start_miotts.log"

# Processes we started (script-scoped so Register-EngineEvent can reach them)
$script:spawnedProcesses = [System.Collections.Generic.List[System.Diagnostics.Process]]::new()

# Clear log at startup
"" | Set-Content $LogFile -Encoding UTF8

# ==============================
# Helper functions
# ==============================
function Write-Log($level, $msg) {
    $line = "{0} [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $level, $msg
    Add-Content $LogFile $line -Encoding UTF8
}

function Write-Step($msg) {
    Write-Host ""
    Write-Host ">>> $msg" -ForegroundColor Cyan
    Write-Log "INFO" ">>> $msg"
}

function Write-Ok($msg) {
    Write-Host "[OK]   $msg" -ForegroundColor Green
    Write-Log "OK" $msg
}

function Write-Skip($msg) {
    Write-Host "[SKIP] $msg" -ForegroundColor Yellow
    Write-Log "SKIP" $msg
}

function Write-Fail($msg) {
    Write-Host "[ERR]  $msg" -ForegroundColor Red
    Write-Log "ERR" $msg
}

function Write-Warn($msg) {
    Write-Host "    $msg" -ForegroundColor Yellow
    Write-Log "WARN" $msg
}

function Test-PortOpen($port) {
    $result = $false
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $tcp.Connect('127.0.0.1', $port)
        $tcp.Close()
        $result = $true
    } catch {
        $result = $false
    }
    return $result
}

function Wait-ForPort($port, $timeoutSec = 60) {
    Write-Host "    Waiting " -NoNewline
    $ok = $false
    for ($i = 0; $i -lt $timeoutSec; $i++) {
        if (Test-PortOpen $port) {
            Write-Host " done"
            $ok = $true
            break
        }
        Start-Sleep -Seconds 1
        Write-Host "." -NoNewline
    }
    if (-not $ok) {
        Write-Host " timeout"
        Write-Log "WARN" "Wait-ForPort timed out after ${timeoutSec}s on port $port"
    }
    return $ok
}

# Kill all processes we spawned (including their child process trees)
function Stop-AllServers {
    if ($script:spawnedProcesses.Count -eq 0) { return }
    Write-Host ""
    Write-Host "Shutting down servers..." -ForegroundColor Yellow
    Write-Log "INFO" "Shutting down spawned servers."
    foreach ($proc in $script:spawnedProcesses) {
        if ($null -ne $proc -and -not $proc.HasExited) {
            Write-Log "INFO" "Killing process tree: PID=$($proc.Id) Name=$($proc.ProcessName)"
            taskkill /T /F /PID $proc.Id 2>&1 | Out-Null
        }
    }
    Write-Log "INFO" "All servers stopped."
    Write-Host "All servers stopped." -ForegroundColor Yellow
}

# Register cleanup for window-close / engine exit
Register-EngineEvent -SourceIdentifier PowerShell.Exiting -SupportEvent -Action {
    foreach ($proc in $script:spawnedProcesses) {
        if ($null -ne $proc -and -not $proc.HasExited) {
            taskkill /T /F /PID $proc.Id 2>&1 | Out-Null
        }
    }
}

# ==============================
# Main
# ==============================
Write-Log "INFO" "===== MioTTS launcher started ====="
Write-Log "INFO" "ScriptDir=$ScriptDir"
Write-Log "INFO" "Config: OLLAMA_PORT=$OLLAMA_PORT MIOTTS_API_PORT=$MIOTTS_API_PORT GRADIO_PORT=$GRADIO_PORT"
Write-Log "INFO" "Config: OLLAMA_MODEL=$OLLAMA_MODEL"

Write-Host ""
Write-Host "============================================" -ForegroundColor Magenta
Write-Host "        MioTTS One-Click Launcher" -ForegroundColor Magenta
Write-Host "============================================" -ForegroundColor Magenta

Set-Location $ScriptDir

# ---- Step 1: Prerequisites ----
Write-Step "Step 1: Checking prerequisites"

if (-not (Get-Command uv -ErrorAction SilentlyContinue)) {
    Write-Warn "uv not found. Installing automatically..."
    irm https://astral.sh/uv/install.ps1 | iex
    $uvInstallPath = "$env:USERPROFILE\.local\bin"
    if (Test-Path $uvInstallPath) {
        $env:PATH = "$uvInstallPath;$env:PATH"
    }
    if (-not (Get-Command uv -ErrorAction SilentlyContinue)) {
        Write-Fail "uv installation failed. Please install manually:"
        Write-Host "         https://docs.astral.sh/uv/getting-started/installation/" -ForegroundColor Red
        Read-Host "Press Enter to exit"
        exit 1
    }
    Write-Ok "uv installed successfully."
} else {
    Write-Ok "uv found."
}

if (-not (Get-Command ollama -ErrorAction SilentlyContinue)) {
    Write-Warn "ollama not found. Installing automatically..."
    $ollamaInstaller = "$env:TEMP\OllamaSetup.exe"
    Write-Warn "WARNING: OllamaSetup.exe is a large file. Download and install may take a very long time. Please be patient."
    Write-Host "    Downloading OllamaSetup.exe..." -ForegroundColor White
    Write-Log "INFO" "Downloading OllamaSetup.exe to $ollamaInstaller"
    Invoke-WebRequest -Uri "https://ollama.com/download/OllamaSetup.exe" -OutFile $ollamaInstaller -UseBasicParsing
    Write-Log "INFO" "Download complete. Launching installer."
    Write-Host "    Launching installer. Please follow the GUI to complete installation." -ForegroundColor White
    $installerProcess = Start-Process $ollamaInstaller -PassThru
    Write-Host "    Waiting for installation to finish (watching for 'ollama app.exe')..." -ForegroundColor White
    while (-not $installerProcess.HasExited) {
        $ollamaApp = Get-Process -Name "ollama app" -ErrorAction SilentlyContinue
        if ($ollamaApp) {
            Stop-Process -InputObject $ollamaApp -Force
            Write-Log "INFO" "ollama app.exe detected and stopped. Installation complete."
            Write-Host "    ollama app.exe detected and stopped. Installation complete." -ForegroundColor White
            break
        }
        Start-Sleep -Seconds 1
        Write-Host "." -NoNewline
    }
    Write-Host ""
    Remove-Item $ollamaInstaller -ErrorAction SilentlyContinue
    $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH", "Machine") + ";" +
                [System.Environment]::GetEnvironmentVariable("PATH", "User")
    if (-not (Get-Command ollama -ErrorAction SilentlyContinue)) {
        Write-Fail "ollama installation failed. Please install manually:"
        Write-Host "         https://ollama.com/download/windows" -ForegroundColor Red
        Read-Host "Press Enter to exit"
        exit 1
    }
    Write-Ok "ollama installed successfully."
} else {
    Write-Ok "ollama found."
}

# ---- Step 2: Install dependencies ----
Write-Step "Step 2: Python dependencies"

$venvPath = Join-Path $ScriptDir ".venv"
if (Test-Path $venvPath) {
    Write-Skip ".venv already exists, skipping uv sync"
} else {
    Write-Host "    Running uv sync..." -ForegroundColor White
    Write-Log "INFO" "Running uv sync"
    uv sync 2>&1 | Tee-Object -FilePath $LogFile -Append
    if ($LASTEXITCODE -ne 0) {
        Write-Fail "uv sync failed (exit code $LASTEXITCODE)."
        Read-Host "Press Enter to exit"
        exit 1
    }
    Write-Ok "Dependencies installed."
}

# ---- Step 3: Start Ollama server ----
Write-Step "Step 3: Ollama server"

if (Test-PortOpen $OLLAMA_PORT) {
    Write-Skip "Ollama already running on port $OLLAMA_PORT"
} else {
    Write-Host "    Starting Ollama server..." -ForegroundColor White
    Write-Log "INFO" "Launching: ollama serve"
    $proc = Start-Process powershell -ArgumentList "-NoExit", "-Command", "ollama serve" -WindowStyle Normal -PassThru
    $script:spawnedProcesses.Add($proc)
    $started = Wait-ForPort $OLLAMA_PORT 60
    if (-not $started) {
        Write-Fail "Ollama server timed out on port $OLLAMA_PORT."
        Stop-AllServers
        Read-Host "Press Enter to exit"
        exit 1
    }
    Write-Ok "Ollama server started (PID=$($proc.Id))."
}

# ---- Step 4: Pull model if needed ----
Write-Step "Step 4: Ollama model"

$modelShortName = ($OLLAMA_MODEL -split ":")[-1] -replace "\.gguf$", ""
$modelList = (ollama list 2>&1) | Out-String
if ($modelList -match [regex]::Escape($modelShortName)) {
    Write-Skip "Model '$modelShortName' already downloaded."
} else {
    Write-Host "    Downloading model: $OLLAMA_MODEL" -ForegroundColor White
    Write-Warn "(First run may take a while...)"
    Write-Log "INFO" "Running: ollama pull $OLLAMA_MODEL"
    ollama pull $OLLAMA_MODEL 2>&1 | Tee-Object -FilePath $LogFile -Append
    if ($LASTEXITCODE -ne 0) {
        Write-Fail "ollama pull failed (exit code $LASTEXITCODE). Check model name: $OLLAMA_MODEL"
        Stop-AllServers
        Read-Host "Press Enter to exit"
        exit 1
    }
    Write-Ok "Model downloaded."
}

# ---- Step 5: Start MioTTS API server ----
Write-Step "Step 5: MioTTS API server"

if (Test-PortOpen $MIOTTS_API_PORT) {
    Write-Skip "MioTTS API already running on port $MIOTTS_API_PORT"
} else {
    Write-Host "    Starting MioTTS API server..." -ForegroundColor White
    $apiCmd = "cd '$ScriptDir'; uv run python run_server.py --llm-base-url $LLM_BASE_URL --max-text-length 2000 --max-reference-mb 100"
    Write-Log "INFO" "Launching MioTTS API: $apiCmd"
    $proc = Start-Process powershell -ArgumentList "-NoExit", "-Command", $apiCmd -WindowStyle Normal -PassThru
    $script:spawnedProcesses.Add($proc)
    $started = Wait-ForPort $MIOTTS_API_PORT 600
    if (-not $started) {
        Write-Fail "MioTTS API server timed out on port $MIOTTS_API_PORT."
        Stop-AllServers
        Read-Host "Press Enter to exit"
        exit 1
    }
    Write-Ok "MioTTS API server started (PID=$($proc.Id))."
}

# ---- Step 6: Start WebUI ----
Write-Step "Step 6: WebUI (Gradio)"

if (Test-PortOpen $GRADIO_PORT) {
    Write-Skip "WebUI already running on port $GRADIO_PORT"
} else {
    Write-Host "    Starting WebUI..." -ForegroundColor White
    $gradioCmd = "cd '$ScriptDir'; uv run python run_gradio.py"
    Write-Log "INFO" "Launching WebUI: $gradioCmd"
    $proc = Start-Process powershell -ArgumentList "-NoExit", "-Command", $gradioCmd -WindowStyle Normal -PassThru
    $script:spawnedProcesses.Add($proc)
    $started = Wait-ForPort $GRADIO_PORT 120
    if (-not $started) {
        Write-Warn "Port check timed out, but WebUI may still be starting."
    }
    Start-Sleep -Seconds 1
    Write-Ok "WebUI started (PID=$($proc.Id))."
}

# ---- Done ----
Write-Log "INFO" "===== All steps complete ====="

Write-Host ""
Write-Host "============================================" -ForegroundColor Green
Write-Host "         MioTTS is ready!" -ForegroundColor Green
Write-Host "============================================" -ForegroundColor Green
Write-Host "  API Server : http://localhost:$MIOTTS_API_PORT" -ForegroundColor Cyan
Write-Host "  WebUI      : http://localhost:$GRADIO_PORT" -ForegroundColor Cyan
Write-Host "  Log file   : $LogFile" -ForegroundColor DarkGray
Write-Host ""

Write-Host "Opening browser..." -ForegroundColor White
Start-Process "http://localhost:$GRADIO_PORT"

Write-Host ""
Write-Host "Press any key to shut down all servers and exit..." -ForegroundColor DarkGray
try {
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
} finally {
    Stop-AllServers
    Write-Log "INFO" "===== MioTTS launcher exited ====="
}
