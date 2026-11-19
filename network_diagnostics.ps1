# ================= CONFIGURACAO =================
$LogFile = ".\diagnostico_quedas.txt"
$IntervaloMs = 400
# ================================================

# Detecta Gateway local automaticamente
$GatewayIP = (Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty NextHop -First 1)

if (-not $GatewayIP) {
    Write-Host "Nao foi possivel identificar o Gateway local." -ForegroundColor Red
    Exit
}

Write-Host "Iniciando telemetria da rede..." -ForegroundColor Cyan
Write-Host "Gateway Local: $GatewayIP | Alvo WAN: 1.1.1.1 | Log: $LogFile" -ForegroundColor Cyan
Write-Host "Deixe rodando enquanto joga. Quando o Discord/jogo travar, olhe a saida abaixo:`n" -ForegroundColor Yellow

$ping = New-Object System.Net.NetworkInformation.Ping

while ($true) {
    $timestamp = Get-Date -Format 'HH:mm:ss.fff'
    $gwOk = $false; $gwRtt = 0
    $wanOk = $false; $wanRtt = 0
    $udpOk = $true
    
    # 1. Teste de Gateway Local (Wi-Fi / Roteador)
    try {
        $repGw = $ping.Send($GatewayIP, 250)
        if ($repGw.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) {
            $gwOk = $true
            $gwRtt = $repGw.RoundtripTime
        }
    } catch {}

    # 2. Teste WAN (1.1.1.1)
    try {
        $repWan = $ping.Send("1.1.1.1", 300)
        if ($repWan.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) {
            $wanOk = $true
            $wanRtt = $repWan.RoundtripTime
        }
    } catch {}

    # 3. Teste de Socket UDP (Abertura de porta e envio)
    try {
        $udpClient = New-Object System.Net.Sockets.UdpClient
        $udpClient.Client.SendTimeout = 250
        $udpClient.Connect("1.1.1.1", 53)
        $dummy = [byte[]](0..12)
        [void]$udpClient.Send($dummy, $dummy.Length)
        $udpClient.Close()
    } catch {
        $udpOk = $false
    }

    # Analise de Anomalias
    $anomalia = $false
    $diagnostico = ""

    if (-not $gwOk) {
        $anomalia = $true
        $diagnostico = "[HIPOTESE 2 e 3: CANAL WI-FI OU CPU DO ROTEADOR] O roteador local parou de responder totalmente."
    } elseif ($gwRtt -gt 100) {
        $anomalia = $true
        $diagnostico = "[HIPOTESE 2: BUFFERBLOAT / AIRTIME] Gateway com latencia anormal ($($gwRtt)ms). Vizinho saturando trafego no radio."
    } elseif (-not $wanOk) {
        $anomalia = $true
        $diagnostico = "[HIPOTESE 1: TABELA NAT OU FIBRA] Roteador responde rapido ($($gwRtt)ms), mas conexao externa caiu."
    } elseif (-not $udpOk) {
        $anomalia = $true
        $diagnostico = "[HIPOTESE 1: EXAUSTAO DE PORTAS UDP/NAT] Ping ICMP responde, mas criacao de novo socket UDP foi recusada."
    }

    if ($anomalia) {
        $logLinha = "[$timestamp] $diagnostico | GW: $($gwRtt)ms | WAN: $($wanRtt)ms | UDP: $udpOk"
        Write-Host $logLinha -ForegroundColor Red
        Add-Content -Path $LogFile -Value $logLinha
    } else {
        # Feedback visual de status em linha unica
        Write-Host -NoNewline "`r[$timestamp] Status Normal | GW: $($gwRtt)ms | WAN: $($wanRtt)ms  "
    }

    Start-Sleep -Milliseconds $IntervaloMs
}