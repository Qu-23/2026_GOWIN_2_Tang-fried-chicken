# bt_spp_connect.ps1 -- Inspect SPP service; -Probe opens a real passive socket.
#
# Why: Windows keeps a paired Bluetooth SPP device in "Unknown" state until
# something actually opens the RFCOMM channel.  Until then the BTHENUM virtual
# COM port (e.g. COM15) cannot be opened by pyserial / System.IO.Ports --
# you get "port does not exist" even though the port is listed.
#
# Merely finding a service does not prove a live link or wake a COM port.
# -Probe makes a real RFCOMM connection and reads without transmitting notes.
# Do not run -Probe while bridge.py or a phone owns the Bluetooth channel.
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\bt_spp_connect.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\bt_spp_connect.ps1 -Probe
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\bt_spp_connect.ps1 -Mac 11:22:33:44:55:66
#
# PURE ASCII -- PowerShell 5.1 reads a BOM-less UTF-8 file as ANSI.

param(
    [string]$Mac = "4A:18:14:B1:49:43",
    [switch]$Probe
)

$ErrorActionPreference = "Continue"

Add-Type -AssemblyName System.Runtime.WindowsRuntime | Out-Null

$asTaskGeneric = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
    $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and
    $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
})[0]

# Unwrap AggregateException -> the real Windows error, so we can print an HRESULT
# that actually means something (0x800710DF = ERROR_DEVICE_NOT_CONNECTED).
# NOTE: we must NOT `throw` inside the catch -- PowerShell wraps it in an
# ErrorRecord and the HRESULT is lost.  Stash it in $script:LastErr instead.
$script:LastErr = $null

function Await($op, $resultType) {
    $task = $asTaskGeneric.MakeGenericMethod($resultType).Invoke($null, @($op))
    try {
        if (-not $task.Wait(20000)) { $script:LastErr = New-Object Exception "timeout after 20s"; return $null }
    } catch {
        $e = $_.Exception
        while ($e.InnerException) { $e = $e.InnerException }
        $script:LastErr = $e
        return $null
    }
    $script:LastErr = $null
    return $task.Result
}

# ConnectAsync returns a COM-projected IAsyncAction. Its uncast .Status can be
# null in PowerShell; use the non-generic AsTask overload and wait on the Task.
function AwaitAction($op, $timeoutMs = 20000) {
    try {
        $method = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
            $_.Name -eq 'AsTask' -and -not $_.IsGenericMethod -and
            $_.GetParameters().Count -eq 1 -and
            $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncAction'
        })[0]
        if ($null -eq $method) { throw 'IAsyncAction AsTask overload not available' }
        $task = $method.Invoke($null, @($op))
        if (-not $task.Wait($timeoutMs)) { throw "timeout after $timeoutMs ms" }
    } catch {
        $e = $_.Exception
        while ($e.InnerException) { $e = $e.InnerException }
        $script:LastErr = $e
        return $false
    }
    $script:LastErr = $null
    return $true
}

function Show-Err($where) {
    $e = $script:LastErr
    if ($null -eq $e) { Write-Output ("  ERROR at {0}: (no exception captured)" -f $where); return }
    $hr = try { ('0x{0:X8}' -f $e.HResult) } catch { 'n/a' }
    Write-Output ("  ERROR at {0}: hr={1} type={2}" -f $where, $hr, $e.GetType().Name)
    Write-Output ("  message: {0}" -f $e.Message)
    if ($hr -eq '0x800710DF') {
        Write-Output "  HR=0x800710DF means ERROR_DEVICE_NOT_CONNECTED."
        Write-Output "  Usual causes, in order of likelihood:"
        Write-Output "   1. The phone is still connected to JDY-31.  JDY-31 is a SINGLE-connection"
        Write-Output "      slave -- only one host at a time.  Turn the phone's Bluetooth OFF"
        Write-Output "      (or close the serial app on it), then run this script again."
        Write-Output "   2. The board is not powered, so the module is off."
        Write-Output "   3. The module is out of range / already talking to another host."
    }
    if ($hr -eq '0x80070490') {
        Write-Output "  HR=0x80070490 means ELEMENT_NOT_FOUND -- the MAC is not paired on this PC."
    }
    if ($hr -eq '0x8007001F') {
        Write-Output "  HR=0x8007001F means a device attached to the system is not functioning --"
        Write-Output "  the Bluetooth adapter itself is unhappy; toggle it in Windows settings."
    }
}

[Windows.Devices.Bluetooth.BluetoothDevice, Windows.Devices.Bluetooth, ContentType = WindowsRuntime] | Out-Null
[Windows.Devices.Bluetooth.Rfcomm.RfcommDeviceService, Windows.Devices.Bluetooth, ContentType = WindowsRuntime] | Out-Null
[Windows.Devices.Enumeration.DeviceInformation, Windows.Devices.Enumeration, ContentType = WindowsRuntime] | Out-Null
[Windows.Networking.Sockets.StreamSocket, Windows.Networking.Sockets, ContentType = WindowsRuntime] | Out-Null
[Windows.Storage.Streams.DataWriter, Windows.Storage.Streams, ContentType = WindowsRuntime] | Out-Null
[Windows.Storage.Streams.DataReader, Windows.Storage.Streams, ContentType = WindowsRuntime] | Out-Null
[Windows.Storage.Streams.IInputStream, Windows.Storage.Streams, ContentType = WindowsRuntime] | Out-Null

$macUlong = [UInt64]::Parse(($Mac -replace '[:-]', ''), 'HexNumber')

Write-Output "MAC       : $Mac  (0x$($macUlong.ToString('X')))"
Write-Output "Step 1 -- BluetoothDevice.FromBluetoothAddressAsync"
$dev = Await ([Windows.Devices.Bluetooth.BluetoothDevice]::FromBluetoothAddressAsync($macUlong)) ([Windows.Devices.Bluetooth.BluetoothDevice])
if ($null -eq $dev) {
    Show-Err "step1 FromBluetoothAddressAsync"
    exit 2
}
Write-Output "  name    : $($dev.Name)"
Write-Output "  id      : $($dev.DeviceId)"
Write-Output "  status  : $($dev.ConnectionStatus)"

Write-Output "Step 2 -- RfcommDeviceService.GetDeviceSelectorForBluetoothDeviceAndServiceId"
# NOTE: this Windows SDK has no GetDeviceSelectorFromBluetoothDevice(); the
# available selectors are GetDeviceSelectorForBluetoothDevice[AndServiceId].
$sppId = [Windows.Devices.Bluetooth.Rfcomm.RfcommServiceId]::SerialPort
$sel = [Windows.Devices.Bluetooth.Rfcomm.RfcommDeviceService]::GetDeviceSelectorForBluetoothDeviceAndServiceId($dev, $sppId)
$found = Await ([Windows.Devices.Enumeration.DeviceInformation]::FindAllAsync($sel)) ([Windows.Devices.Enumeration.DeviceInformationCollection])
if ($null -eq $found) {
    Show-Err "step2 FindAllAsync"
    exit 3
}
Write-Output "  services found: $($found.Count)"
foreach ($s in $found) { Write-Output "    - $($s.Name)  [$($s.Id)]" }

if ($null -eq $found -or $found.Count -eq 0) {
    Write-Output "  RESULT: no SPP service exposed."
    Write-Output "  The JDY-31 is probably unpowered, or the paired entry is not the SPP channel."
    exit 3
}

Write-Output "Step 3 -- RfcommDeviceService.FromIdAsync (service discovery only)"
$svc = Await ([Windows.Devices.Bluetooth.Rfcomm.RfcommDeviceService]::FromIdAsync($found[0].Id)) ([Windows.Devices.Bluetooth.Rfcomm.RfcommDeviceService])
if ($null -eq $svc) {
    Show-Err "step3 FromIdAsync"
    exit 4
}
Write-Output "  service : $($svc.ConnectionServiceName)"
Write-Output "  status  : $($dev.ConnectionStatus)"
Write-Output "  Service found. A live Bluetooth connection has not been verified."

if ($Probe) {
    Write-Output "Step 4 -- connect real socket and passively read board bytes"
    $sock = New-Object Windows.Networking.Sockets.StreamSocket
    $sock.Control.KeepAlive = $false
    $ok = AwaitAction ($sock.ConnectAsync($svc.ConnectionHostName, $svc.ConnectionServiceName))
    if (-not $ok) {
        Show-Err "step4 socket connect"
        exit 5
    }
    Write-Output "  connected: $($sock.Information.RemoteAddress) : $($sock.Information.RemotePort)"

    $r = [Windows.Storage.Streams.DataReader]::new([Windows.Storage.Streams.IInputStream]$sock.InputStream)
    $r.InputStreamOptions = [Windows.Storage.Streams.InputStreamOptions]::Partial
    $n = Await ($r.LoadAsync(64)) ([UInt32])
    if ($null -eq $n) {
        Write-Output "  recv    : timeout / none"
    } else {
        Write-Output "  recv    : $n bytes"
        if ($n -gt 0) {
            $buf = New-Object byte[] $n
            $r.ReadBytes($buf)
            Write-Output ("  hex     : " + (($buf | ForEach-Object { $_.ToString('X2') }) -join ' '))
        }
    }
    $sock.Dispose()
}

$svc.Dispose()
Write-Output "DONE"
