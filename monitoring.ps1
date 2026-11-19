# ================= CONFIGURATION =================
$IntervalSeconds = 0.3
$MaxZeroConsecutive = 3
$CooldownSeconds = 4
# =================================================

# Get active network adapter
$adapter = Get-NetAdapter | Where-Object Status -eq 'Up' | Select-Object -First 1

if (-not $adapter) {
    Write-Host "No active network adapter found." -ForegroundColor Red
    Exit
}

$isWifi = ($adapter.InterfaceType -eq 71)

# Detect connected SSID if on Wi-Fi
$TargetSSID = ""
if ($isWifi) {
    $wlanOutput = netsh wlan show interfaces
    foreach ($line in $wlanOutput) {
        if ($line -match '^\s*SSID\s*:\s*(.+)$') {
            $TargetSSID = $Matches[1].Trim()
            break
        }
    }
}

$triggerSeconds = $IntervalSeconds * $MaxZeroConsecutive

Write-Host "Monitoring interface: $($adapter.Name) ($($adapter.InterfaceDescription))" -ForegroundColor Cyan
Write-Host "Media: $(if ($isWifi) { "Wi-Fi ($TargetSSID)" } else { "Ethernet" })" -ForegroundColor Cyan
Write-Host "Auto-reset trigger: ${triggerSeconds}s with zero packets" -ForegroundColor Cyan

$prevStats = Get-NetAdapterStatistics -Name $adapter.Name
$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
$zeroCount = 0

while ($true) {
    Start-Sleep -Seconds $IntervalSeconds

    $currStats = Get-NetAdapterStatistics -Name $adapter.Name
    $elapsedMs = $stopwatch.ElapsedMilliseconds
    $stopwatch.Restart()

    if ($elapsedMs -eq 0) { continue }

    $rxBytes = $currStats.ReceivedBytes - $prevStats.ReceivedBytes
    $txBytes = $currStats.SentBytes - $prevStats.SentBytes
    $rxPkts  = $currStats.ReceivedUnicastPackets - $prevStats.ReceivedUnicastPackets
    $txPkts  = $currStats.SentUnicastPackets - $prevStats.SentUnicastPackets

    $prevStats = $currStats

    $secondsReal = $elapsedMs / 1000.0
    $downMbps = [math]::Round((($rxBytes * 8) / (1024 * 1024)) / $secondsReal, 2)
    $upMbps   = [math]::Round((($txBytes * 8)   / (1024 * 1024)) / $secondsReal, 2)
    $rxPPS    = [math]::Round($rxPkts / $secondsReal, 0)
    $txPPS    = [math]::Round($txPkts / $secondsReal, 0)

    $now = Get-Date -Format 'HH:mm:ss'

    Clear-Host
    Write-Host "[$now] --- TRAFFIC STATS (LAST${IntervalSeconds}s) ---" -ForegroundColor Yellow
    Write-Host " Download: $downMbps Mbps ($rxPPS pkts/s)" -ForegroundColor Green
    Write-Host " Upload:   $upMbps Mbps ($txPPS pkts/s)" -ForegroundColor Cyan
    Write-Host "----------------------------------------------------"

    # Detect packet stall
    if ((($rxPPS + $txPPS) -lt 0.05) -or ($rxPPS -eq 0) -or ($txPPS -eq 0)) {
        $zeroCount++
        Write-Host " [WARNING] Zero throughput (RX and TX stalled)! ($zeroCount/$MaxZeroConsecutive)" -ForegroundColor Red

        if ($zeroCount -ge $MaxZeroConsecutive) {
            Write-Host "`n[$now] NETWORK STALL CONFIRMED. RESETTING CONNECTION..." -ForegroundColor Magenta

            if ($isWifi -and $TargetSSID) {
                netsh wlan disconnect | Out-Null
                Start-Sleep -Milliseconds 300
                netsh wlan connect name="$TargetSSID" | Out-Null
                Write-Host " -> Reassociated Wi-Fi to '$TargetSSID'" -ForegroundColor Green
            } else {
                Restart-NetAdapter -Name $adapter.Name -Confirm:$false
                Write-Host " -> Restarted network adapter" -ForegroundColor Green
            }

            Write-Host " -> Waiting $CooldownSeconds seconds for DHCP and IP assignment..." -ForegroundColor Yellow
            Start-Sleep -Seconds $CooldownSeconds

            $prevStats = Get-NetAdapterStatistics -Name $adapter.Name
            $stopwatch.Restart()
            $zeroCount = 0
            Write-Host " -> Connection restored. Resuming telemetry." -ForegroundColor Cyan
            Start-Sleep -Seconds 1
            continue
        }
    } else {
        $zeroCount = 0
    }

    # Top active connections by process
    Write-Host "`nProcesses with active TCP connections:" -ForegroundColor DarkYellow
    try {
        $conns = Get-NetTCPConnection -State Established -ErrorAction SilentlyContinue
        if ($conns) {
            $grouped = $conns | Group-Object OwningProcess | Sort-Object Count -Descending | Select-Object -First 5
            foreach ($item in $grouped) {
                $proc = Get-Process -Id $item.Name -ErrorAction SilentlyContinue
                $procName = if ($proc) { $proc.ProcessName } else { "PID $($item.Name)" }
                Write-Host "  -> $procName : $($item.Count) active sockets" -ForegroundColor Gray
            }
        }
    } catch {}
}