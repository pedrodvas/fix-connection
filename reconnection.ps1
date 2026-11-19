# ================= CONFIGURAÇÕES =================
$TargetSSID = ""
$MaxFalhas = 3             # Limiar de quedas consecutivas para reset
$IntervaloNormalMs = 400   # Intervalo padrão entre checagens
$TimeoutPingMs = 80       # Timeout ágil para não prender a thread

# Alvos neutros que nunca dão block
$DNS1 = "1.1.1.1"          # Cloudflare
$DNS2 = "8.8.8.8"          # Google
# =================================================

# Detecção automática do SSID atual
if ([string]::IsNullOrWhiteSpace($TargetSSID)) {
    Write-Host "Detectando rede Wi-Fi..." -ForegroundColor Cyan
    $wlanStatus = netsh wlan show interfaces
    $ssidMatch = ($wlanStatus | Select-String '^\s*SSID\s*:\s*(.+)$')
    if ($ssidMatch) {
        $TargetSSID = $ssidMatch.Matches[0].Groups[1].Value.Trim()
        Write-Host "Rede conectada: '$TargetSSID'" -ForegroundColor Green
    } else {
        Write-Host "Nenhuma rede Wi-Fi encontrada." -ForegroundColor Red
        Exit
    }
}

# Identifica o roteador da kitnet dinamicamente
$GatewayIP = (Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty NextHop -First 1)
Write-Host "Gateway local identificado: $GatewayIP" -ForegroundColor Cyan

$FalhasSeguidas = 0
Write-Host "Monitoramento neutro ativo [Gateway Local + DNS Anycast]..." -ForegroundColor Green

while ($true) {
    $redeOk = $false
    $ping = New-Object System.Net.NetworkInformation.Ping

    try {
        # 1. Checagem externa principal
        $replyExt = $ping.Send($DNS1, $TimeoutPingMs)
        if ($replyExt.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) {
            $redeOk = $true
        } else {
            # Contingência externa
            $replyExt2 = $ping.Send($DNS2, $TimeoutPingMs)
            if ($replyExt2.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) {
                $redeOk = $true
            }
        }

        # 2. Se a externa falhou, checa se o próprio roteador local ainda responde
        if (-not $redeOk -and $GatewayIP) {
            $replyGw = $ping.Send($GatewayIP, 200)
            if ($replyGw.Status -ne [System.Net.NetworkInformation.IPStatus]::Success) {
                Write-Host " [ROTEADOR TRAVADO] Gateway $GatewayIP não responde no ar!" -ForegroundColor DarkYellow
            }
        }
    } catch {
        $redeOk = $false
    } finally {
        $ping.Dispose()
    }

    if ($redeOk) {
        if ($FalhasSeguidas -gt 0) {
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Conexão recuperou antes do reset." -ForegroundColor Green
        }
        $FalhasSeguidas = 0
        Start-Sleep -Milliseconds $IntervaloNormalMs
    } else {
        $FalhasSeguidas++
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Falha de conectividade detectada ($FalhasSeguidas/$MaxFalhas)" -ForegroundColor Yellow

        if ($FalhasSeguidas -ge $MaxFalhas) {
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Queda total confirmada (~1,5s). Resetando Wi-Fi..." -ForegroundColor Red

            # Reset rápido da associação Wi-Fi (Nível 2)
            netsh wlan disconnect | Out-Null
            Start-Sleep -Milliseconds 300
            netsh wlan connect name="$TargetSSID" | Out-Null

            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Reassociação enviada. Aguardando IP e rotas..." -ForegroundColor Green
            $FalhasSeguidas = 0
            
            # Pausa para o DHCP e o roteador negociarem a nova sessão
            Start-Sleep -Seconds 3
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Retomando monitoramento." -ForegroundColor Cyan
        } else {
            Start-Sleep -Milliseconds 150
        }
    }
}