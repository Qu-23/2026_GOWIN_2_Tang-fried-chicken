# Computer-side evidence only: safe with the board powered off.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'bluetooth_status.ps1')
$radio = Get-BluetoothRadioState
$relays = @(Get-CimInstance Win32_Process | Where-Object {
    $_.Name -in @('python.exe', 'pythonw.exe') -and $_.CommandLine -match '(?i)[\\/]tools[\\/]bridge\.py(?:["\s]|$)'
} | Select-Object ProcessId, CommandLine)
$report = [ordered]@{
    time = (Get-Date).ToString('o')
    remoteConnectionAttempted = $false
    bluetoothRadio = $radio
    bluetoothDevices = @(Get-PnpDevice -Class Bluetooth -ErrorAction SilentlyContinue |
        Select-Object Status, FriendlyName, InstanceId)
    serialPorts = @(Get-CimInstance Win32_SerialPort | Select-Object DeviceID, Name, PNPDeviceID)
    relayProcesses = $relays
    httpListeners = @(Get-NetTCPConnection -LocalPort 8080 -State Listen -ErrorAction SilentlyContinue |
        Select-Object LocalAddress, LocalPort, OwningProcess)
}
$logDir = Join-Path $PSScriptRoot 'logs'
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
$path = Join-Path $logDir ('bluetooth_diagnostic_' + (Get-Date -Format 'yyyyMMdd_HHmmss') + '.json')
$report | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $path -Encoding UTF8
Write-Output "Computer Bluetooth: $radio"
Write-Output "Relay processes: $($relays.Count)"
Write-Output "Saved: $path"
Write-Output 'No Bluetooth connection, note, or service restart was attempted. The board can remain powered off.'
