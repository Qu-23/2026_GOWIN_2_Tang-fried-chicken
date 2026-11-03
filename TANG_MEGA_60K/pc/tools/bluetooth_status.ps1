# Read only the local Windows radio state. Never opens a remote connection.
function Get-BluetoothRadioState {
    try {
        Add-Type -AssemblyName System.Runtime.WindowsRuntime | Out-Null
        [Windows.Devices.Radios.Radio, Windows.System.Devices, ContentType = WindowsRuntime] | Out-Null
        $resultType = [System.Collections.Generic.IReadOnlyList[Windows.Devices.Radios.Radio]]
        $method = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
            $_.Name -eq 'AsTask' -and $_.IsGenericMethod -and $_.GetParameters().Count -eq 1 -and
            $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
        })[0]
        $task = $method.MakeGenericMethod($resultType).Invoke($null, @([Windows.Devices.Radios.Radio]::GetRadiosAsync()))
        if (-not $task.Wait(3000)) { return 'Unknown' }
        $radios = @($task.Result | Where-Object { $_.Kind.ToString() -eq 'Bluetooth' })
        if (-not $radios.Count) { return 'NotFound' }
        if (@($radios | Where-Object { $_.State.ToString() -eq 'On' }).Count) { return 'On' }
        return $radios[0].State.ToString()
    } catch { return 'Unknown' }
}
