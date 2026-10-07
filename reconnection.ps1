# ================= CONFIGURAÇÕES =================
$TargetSSID = ""
$MaxFalhas = 4            
$IntervaloNormalMs = 500  
$TimeoutPingMs = 400      

$ValveRelayIP = "155.133.227.36"
$ValvePingCount = 6
$ValvePingIntervalMs = 200
# =================================================

if ([string]::IsNullOrWhiteSpace($TargetSSID)) {
    Write-Host "Detectando rede Wi-Fi atual..." -ForegroundColor Cyan
    $wlanStatus = netsh wlan show interfaces
    $ssidMatch = ($wlanStatus | Select-String '^\s*SSID\s*:\s*(.+)$')
    if ($ssidMatch) {
        $TargetSSID = $ssidMatch.Matches[0].Groups[1].Value.Trim()
        Write-Host "Rede detectada: '$TargetSSID'" -ForegroundColor Green
    } else {
        Write-Host "Nenhuma rede Wi-Fi conectada. Defina `$TargetSSID." -ForegroundColor Red
        Exit
    }
}

$FalhasSeguidas = 0
Write-Host "Monitoramento ativo com descarte de travamento..." -ForegroundColor Cyan

while ($true) {
    $sucesso = $false
    $tempoInicio = [System.Diagnostics.Stopwatch]::StartNew()

    try {
        # Recria o objeto para liberar sockets presos no kernel caso haja interrupção brusca
        $ping = New-Object System.Net.NetworkInformation.Ping
        $reply = $ping.Send("1.1.1.1", $TimeoutPingMs)
        
        if ($reply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) {
            $sucesso = $true
        } else {
            # Se falhou 1.1.1.1, tenta 8.8.8.8
            $reply2 = $ping.Send("8.8.8.8", $TimeoutPingMs)
            if ($reply2.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) {
                $sucesso = $true
            }
        }
        $ping.Dispose()
    } catch {
        $sucesso = $false
    }

    $tempoInicio.Stop()

    # Se a execução demorou muito mais do que o timeout (kernel travou esperando rota),
    # contamos como falha mesmo que não tenha estourado exceção explícita
    if ($tempoInicio.ElapsedMilliseconds -gt ($TimeoutPingMs * 2.5)) {
        $sucesso = $false
    }

    if ($sucesso) {
        if ($FalhasSeguidas -gt 0) {
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Conexão reestabelecida antes do reset." -ForegroundColor Green
        }
        $FalhasSeguidas = 0
        Start-Sleep -Milliseconds $IntervaloNormalMs
    } else {
        $FalhasSeguidas++
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Falha detectada ($FalhasSeguidas/$MaxFalhas) - Latência: $($tempoInicio.ElapsedMilliseconds)ms" -ForegroundColor Yellow

        if ($FalhasSeguidas -ge $MaxFalhas) {
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Queda confirmada. Reconectando a '$TargetSSID'..." -ForegroundColor Red

            netsh wlan disconnect | Out-Null
            Start-Sleep -Milliseconds 400
            netsh wlan connect name="$TargetSSID" | Out-Null

            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Reassociação enviada. Aguardando link e IP..." -ForegroundColor Green
            $FalhasSeguidas = 0
            Start-Sleep -Seconds 4

            # Warm-up Valve
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Aquecendo rota Valve SP ($ValveRelayIP)..." -ForegroundColor Magenta
            $pValve = New-Object System.Net.NetworkInformation.Ping
            for ($i = 1; $i -le $ValvePingCount; $i++) {
                try {
                    $valveReply = $pValve.Send($ValveRelayIP, 2000)
                    if ($valveReply.Status -eq "Success") {
                        Write-Host " -> Valve SP [OK]: $($valveReply.RoundtripTime)ms" -ForegroundColor Green
                    } else {
                        Write-Host " -> Valve SP: $($valveReply.Status)" -ForegroundColor DarkGray
                    }
                } catch {
                    Write-Host " -> Valve SP: falha de socket" -ForegroundColor DarkGray
                }
                Start-Sleep -Milliseconds $ValvePingIntervalMs
            }
            $pValve.Dispose()

            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Concluído. Retomando monitoramento." -ForegroundColor Cyan
        } else {
            Start-Sleep -Milliseconds 150
        }
    }
}