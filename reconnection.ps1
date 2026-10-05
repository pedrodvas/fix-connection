# ================= CONFIGURAÇÕES =================
# Deixe em branco ("") para detectar automaticamente a rede conectada ao iniciar,
# ou defina manualmente ex: $TargetSSID = "MinhaRede_5G"
$TargetSSID = ""
$MaxFalhas = 4          # Quantidade de falhas seguidas antes de reconectar
$IntervaloNormalMs = 500 # Intervalo entre pings normais (ms)
$TimeoutPingMs = 350    # Tempo limite de resposta de cada ping (ms)
# =================================================

# Detecção automática do SSID atual caso não tenha sido informado
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

Write-Host "Iniciando monitoramento de conectividade (Nível 2 - Wi-Fi Assoc)..." -ForegroundColor Cyan

while ($true) {
    $sucesso = $false

    try {
        # Testa 1.1.1.1 (Cloudflare) com timeout curto
        $reply = $ping.Send("1.1.1.1", $TimeoutPingMs)
        if ($reply.Status -eq "Success") {
            $sucesso = $true
        } else {
            # Se falhar, faz um double-check imediato em 8.8.8.8 (Google)
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

            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Reassociação enviada. Aguardando estabilização..." -ForegroundColor Green
            $FalhasSeguidas = 0

            # Pausa para handshake WPA e atribuição de IP sem disparar novo reset
            Start-Sleep -Seconds 4
        } else {
            # Pausa curta entre tentativas de confirmação de queda
            Start-Sleep -Milliseconds 150
        }
    }
}