# Runs a command on a few cores that other busy processes keep loaded, to see
# what gitbello does on a slow, busy machine.
#
#   powershell -File tools/cpu_burn.ps1 -Cores 2 -Burners 3 -Exe <exe> -Arguments "<args>"
#
# The command (and the git processes it starts) run on the first `-Cores`
# cores alongside `-Burners` busy loops at normal priority. Without a command,
# the burners run until Enter is pressed (start the app on those cores
# yourself, for example with `start /affinity 3`).
param(
    [int]$Cores = 2,
    [int]$Burners = 3,
    [string]$Exe = '',
    [string]$Arguments = ''
)

$mask = [IntPtr]([int64][math]::Pow(2, $Cores) - 1)
$burn = @()
for ($i = 0; $i -lt $Burners; $i++) {
    $p = Start-Process -FilePath python -ArgumentList '-c', '"while True: pass"' -PassThru -WindowStyle Hidden
    $p.ProcessorAffinity = $mask
    $burn += $p
}
try {
    if ($Exe) {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $Exe
        $psi.Arguments = $Arguments
        $psi.UseShellExecute = $false
        $p = [System.Diagnostics.Process]::Start($psi)
        $p.ProcessorAffinity = $mask
        $p.WaitForExit()
        exit $p.ExitCode
    } else {
        Write-Host "Burning $Burners loops on $Cores cores (mask $mask). Press Enter to stop."
        [void][Console]::ReadLine()
    }
} finally {
    foreach ($p in $burn) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
}
