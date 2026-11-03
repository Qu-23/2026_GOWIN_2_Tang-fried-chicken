# HTTP starts independently of Bluetooth. Never probe/open-close all COMs.
# PS5.1-compatible ASCII source. Run from any working directory.
param(
    [string]$Port = "",
    [string]$Bluetooth = "",
    [int]$HttpPort = 8080,
    [switch]$Mock,
    [string]$HostIP = "",
    [switch]$NoOpen,
    [string]$Python = ""
)
$ErrorActionPreference = "Stop"
$env:PYTHONUTF8 = '1'
$root = Split-Path -Parent $PSScriptRoot
if (-not $Mock -and ($Bluetooth -or -not $Port)) {
    . (Join-Path $PSScriptRoot 'bluetooth_status.ps1')
    $radioState = Get-BluetoothRadioState
    Write-Output "[start_app] Computer Bluetooth radio: $radioState"
    if ($radioState -in @('Off', 'Disabled', 'NotFound')) {
        Write-Output '[start_app] Enable computer Bluetooth first, then run this CMD again. No relay was started.'
        exit 2
    }
}
if (-not $Python) {
    $Python = "C:/Users/34135/AppData/Local/Programs/Python/Python312/python.exe"
    if (-not (Test-Path -LiteralPath $Python)) { $Python = "python" }
}
$bridgeArgs = @("-u", "$root/tools/bridge.py", "--port", "$HttpPort")
if ($Mock) { $bridgeArgs += "--mock" }
elseif ($Bluetooth) { $bridgeArgs += @("--serial", "BT:$Bluetooth") }
elseif ($Port) { $bridgeArgs += @("--serial", $Port) }
else { $bridgeArgs += "--auto" }
if ($HostIP) { $bridgeArgs += @("--host-ip", $HostIP) }
if ($NoOpen) { $bridgeArgs += "--no-open" }
Write-Output "[start_app] Starting phone HTTP/WebSocket app; serial can connect later."
Write-Output "[start_app] For PC Bluetooth relay: disconnect the phone serial app first."
Write-Output "[start_app] A silent COM is not a failed COM; not all firmware sends heartbeats."
Write-Output "[start_app] One relay only. Use stop_app.cmd to release it. Logs: tools/logs/bridge.log"
& $Python @bridgeArgs
exit $LASTEXITCODE
