# ================= CONFIGURAÇÕES =================
# Deixe em branco ("") para detectar automaticamente o SSID atual
$TargetSSID = ""
$MaxFalhas = 4            # Falhas seguidas antes de reconectar
$IntervaloNormalMs = 500  # Intervalo de monitoramento padrão (ms)
$TimeoutPingMs = 350      # Timeout do ping de checagem (ms)

# Configurações do Warm-up Valve (GRU / SP)
$ValveRelayIP = "155.133.227.36"  # Relay oficial Valve SP (ou gru.valve.net)
$ValvePingCount = 8               # Quantidade de pings para reabrir a rota
$ValvePingIntervalMs = 200        # Intervalo entre os pings de warm-up (ms)
# =================================================

# Detecção automática do SSID atual
if ([string]::IsNullOrWhiteSpace($TargetSSID)) {
    Write-Host "Detectando rede Wi-Fi atual..." -ForegroundColor Cyan
    $wlanStatus = netsh wlan show interfaces
    $ssidMatch = ($wlanStatus | Select-String '^\s*SSID\s*:\s*(.+)$')
    if ($ssidMatch) {
        $TargetSSID = $ssidMatch.Matches[0].Groups[1].Value.Trim()
        Write-Host "Rede detectada: '$TargetSSID'" -ForegroundColor Green
    } else {
        Write-Host "Nenhuma rede Wi-Fi conectada no momento. Defina `$TargetSSID manualmente." -ForegroundColor Red
        Exit
    }
}

$ping = New-Object System.Net.NetworkInformation.Ping
$FalhasSeguidas = 0

Write-Host "Iniciando monitoramento de conectividade (Nível 2 + Valve SDR Warmup)..." -ForegroundColor Cyan

while ($true) {
    $sucesso = $false

    try {
        # Monitoramento leve no Cloudflare
        $reply = $ping.Send("1.1.1.1", $TimeoutPingMs)
        if ($reply.Status -eq "Success") {
            $sucesso = $true
        } else {
            # Double-check no Google
            $reply2 = $ping.Send("8.8.8.8", $TimeoutPingMs)
            if ($reply2.Status -eq "Success") {
                $sucesso = $true
            }
        }
    } catch {
        $sucesso = $false
    }

    if ($sucesso) {
        $FalhasSeguidas = 0
        Start-Sleep -Milliseconds $IntervaloNormalMs
    } else {
        $FalhasSeguidas++
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Falha detectada ($FalhasSeguidas/$MaxFalhas)" -ForegroundColor Yellow

        if ($FalhasSeguidas -ge $MaxFalhas) {
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Queda confirmada. Reconectando a '$TargetSSID'..." -ForegroundColor Red

            # Nível 2: Desassocia e reassocia ao rádio Wi-Fi
            netsh wlan disconnect | Out-Null
            Start-Sleep -Milliseconds 400
            netsh wlan connect name="$TargetSSID" | Out-Null

            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Reassociação enviada. Aguardando link e IP..." -ForegroundColor Green
            $FalhasSeguidas = 0

            # Pausa para handshake WPA e DHCP do roteador
            Start-Sleep -Seconds 4

            # --- AQUECIMENTO DA ROTA VALVE (SÃO PAULO) ---
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Reabrindo sessão NAT com Valve SP ($ValveRelayIP)..." -ForegroundColor Magenta
            
            for ($i = 1; $i -le $ValvePingCount; $i++) {
                try {
                    $valveReply = $ping.Send($ValveRelayIP, 600)
                    if ($valveReply.Status -eq "Success") {
                        Write-Host " -> Valve SP [OK]: $($valveReply.RoundtripTime)ms" -ForegroundColor Green
                    } else {
                        Write-Host " -> Valve SP: sem resposta ($($valveReply.Status))" -ForegroundColor DarkGray
                    }
                } catch {
                    Write-Host " -> Valve SP: erro de envio" -ForegroundColor DarkGray
                }
                Start-Sleep -Milliseconds $ValvePingIntervalMs
            }

            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Rota restabelecida. Monitoramento retomado." -ForegroundColor Cyan
        } else {
            Start-Sleep -Milliseconds 150
        }
    }
}