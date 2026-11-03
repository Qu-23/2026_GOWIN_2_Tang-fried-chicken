# Stop only relays whose absolute script paths belong to this project/demo.
# No port guessing, system service restart, or other Python process termination.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$roots = @($root, (Join-Path $root 'demo'))
if ((Split-Path -Leaf $root) -eq 'demo') { $roots += Split-Path -Parent $root }
$scripts = @($roots | ForEach-Object {
    [IO.Path]::GetFullPath((Join-Path $_ 'tools/bridge.py')).Replace('/', '\')
})
$stopped = 0
Get-CimInstance Win32_Process | Where-Object { $_.Name -in @('python.exe', 'pythonw.exe') } | ForEach-Object {
    $process = $_
    $command = ([string]$process.CommandLine).Replace('/', '\')
    foreach ($script in $scripts) {
        $pattern = '(?i)(?:^|[\s"])' + [regex]::Escape($script) + '(?=[\s"]|$)'
        if ($command -match $pattern) {
            Stop-Process -Id $process.ProcessId -ErrorAction Stop
            Write-Output "Stopped project relay PID $($process.ProcessId)."
            $stopped++
            break
        }
    }
}
if (-not $stopped) { Write-Output 'No project relay is running.' }
Write-Output 'No relay was started. The next connection starts only when you run start_app/start_bluetooth.cmd.'
