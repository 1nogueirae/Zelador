<#
.SYNOPSIS
    Zelador: análise e manutenção leve do Windows, sem instalar nada.

.DESCRIPTION
    Por padrão só lê o sistema e gera um relatório (nada é alterado).
    Com -Acoes abre um menu de ações opcionais, e cada uma pede confirmação.

.EXAMPLE
    .\zelador.ps1
    .\zelador.ps1 -Profundo -Html relatorio.html
    .\zelador.ps1 -Acoes
#>
[CmdletBinding()]
param(
    [switch]$Acoes,      # abre o menu de ações depois da análise
    [switch]$Profundo,   # inclui a busca de arquivos > 1 GB no C: (demora)
    [string]$Html        # salva o relatório em HTML neste caminho
)

$ErrorActionPreference = 'SilentlyContinue'
$IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$Resultados = New-Object System.Collections.Generic.List[object]

function Add-R($Categoria, $Item, $Status, $Detalhe) {
    $Resultados.Add([pscustomobject]@{ Categoria = $Categoria; Item = $Item; Status = $Status; Detalhe = "$Detalhe" })
}

function Get-TamanhoGB($Caminho) {
    $s = (Get-ChildItem -LiteralPath $Caminho -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
    [math]::Round($s / 1GB, 2)
}

function Get-Reg($Chave, $Nome) { (Get-ItemProperty -Path $Chave -Name $Nome -ErrorAction SilentlyContinue).$Nome }

function Set-Reg($Chave, $Nome, $Valor) {
    if (-not (Test-Path $Chave)) { New-Item $Chave -Force | Out-Null }
    Set-ItemProperty -Path $Chave -Name $Nome -Value $Valor -Type DWord
}

function Get-Assinante($Exe) {
    if (-not $Exe -or -not (Test-Path -LiteralPath $Exe)) { return '?' }
    $s = Get-AuthenticodeSignature -LiteralPath $Exe
    if ($s.Status -ne 'Valid') { return "SEM ASSINATURA ($($s.Status))" }
    $s.SignerCertificate.Subject -replace '^CN="?([^,"]+)"?.*', '$1'
}

# Extrai o caminho do .exe de uma linha de comando ("C:\x y\a.exe" -arg  ou  C:\a.exe -arg)
function Get-ExeDeComando($Cmd) {
    if ($Cmd -match '^\s*"([^"]+)"') { return $Matches[1] }
    if ($Cmd -match '^\s*(.+?\.exe)') { return $Matches[1] }
    $Cmd
}

# ---------------------------------------------------------------- Sistema
function Test-Sistema {
    $os = Get-CimInstance Win32_OperatingSystem
    $cpu = (Get-CimInstance Win32_Processor | Select-Object -First 1).Name
    $gpu = (Get-CimInstance Win32_VideoController | ForEach-Object { "$($_.Name) (driver $($_.DriverVersion))" }) -join '; '
    Add-R 'Sistema' 'Windows' 'Info' "$($os.Caption) build $($os.BuildNumber), instalado em $($os.InstallDate.ToString('dd/MM/yyyy'))"
    Add-R 'Sistema' 'Hardware' 'Info' "$cpu | $([math]::Round($os.TotalVisibleMemorySize/1MB,1)) GB RAM | $gpu"
    $dias = ((Get-Date) - $os.LastBootUpTime).Days
    Add-R 'Sistema' 'Tempo ligado' $(if ($dias -ge 7) { 'Atenção' } else { 'OK' }) "$dias dia(s) desde o último boot"
}

# ---------------------------------------------------------------- Discos
function Test-Discos {
    foreach ($v in Get-Volume | Where-Object { $_.DriveLetter -and $_.DriveType -eq 'Fixed' -and $_.Size }) {
        $livre = [math]::Round($v.SizeRemaining / 1GB, 1)
        $pct = [math]::Round($v.SizeRemaining / $v.Size * 100)
        $st = if ($pct -lt 15) { 'Atenção' } else { 'OK' }
        Add-R 'Discos' "$($v.DriveLetter): $($v.FileSystemLabel)" $st "$livre GB livres de $([math]::Round($v.Size/1GB)) GB ($pct%)"
    }
    foreach ($d in Get-PhysicalDisk) {
        $st = if ($d.HealthStatus -eq 'Healthy') { 'OK' } else { 'Atenção' }
        Add-R 'Discos' $d.FriendlyName $st "$($d.MediaType) $($d.BusType), saúde: $($d.HealthStatus)"
    }
    $trim = fsutil behavior query DisableDeleteNotify 2>$null | Select-String 'NTFS'
    if ($trim -and $trim -notmatch '= 0') { Add-R 'Discos' 'TRIM' 'Atenção' 'TRIM desativado para NTFS' }
}

# ---------------------------------------------------------------- Espaço
function Test-Espaco {
    $L = $env:LOCALAPPDATA; $U = $env:USERPROFILE
    # Caches conhecidos: caminho, descrição. Só aparecem se existirem e passarem de 0,5 GB.
    $caches = @(
        @("$L\Google\DriveFS",          'Cache do Google Drive. Fica no disco de verdade; limpe em Drive > Preferências > Arquivos off-line'),
        @("$L\npm-cache",               'Cache do npm (limpável)'),
        @("$U\.gradle",                 'Cache do Gradle (limpável)'),
        @("$L\pip\cache",               'Cache do pip (limpável)'),
        @("$L\Yarn\Cache",              'Cache do Yarn (limpável)'),
        @("$L\pnpm",                    'Store do pnpm'),
        @("$U\.nuget\packages",         'Pacotes NuGet'),
        @("$L\NVIDIA\DXCache",          'Cache de shaders NVIDIA (limpável, se recria)'),
        @("$L\D3DSCache",               'Cache de shaders DirectX (limpável, se recria)'),
        @("$L\CrashDumps",              'Dumps de travamento (limpável)'),
        @("$env:TEMP",                  'Temporários do usuário (limpável)'),
        @("$L\Docker\wsl",              'Discos virtuais do Docker (docker system prune + compactar)'),
        @("$L\Packages\CanonicalGroupLimited*", 'Distros WSL'),
        @("$L\Android\Sdk",             'Android SDK'),
        @("$U\.android\avd",            'Emuladores Android'),
        @('C:\Windows\SoftwareDistribution\Download', 'Downloads do Windows Update'),
        @('C:\$Recycle.Bin',            'Lixeira')
    )
    foreach ($c in $caches) {
        foreach ($p in (Resolve-Path $c[0] -ErrorAction SilentlyContinue).Path) {
            $gb = Get-TamanhoGB $p
            if ($gb -ge 0.5) { Add-R 'Espaço' $p $(if ($gb -ge 5) { 'Atenção' } else { 'Info' }) "$gb GB - $($c[1])" }
        }
    }
    if (Test-Path C:\Windows.old) { Add-R 'Espaço' 'C:\Windows.old' 'Atenção' "$(Get-TamanhoGB 'C:\Windows.old') GB - instalação anterior (Limpeza de Disco remove)" }

    # Maiores pastas nos lugares onde o espaço costuma sumir
    $raizes = @($L, $env:APPDATA, $U, $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData)
    Write-Host '  medindo pastas (pode levar alguns minutos)...' -ForegroundColor DarkGray
    $pastas = foreach ($r in $raizes) {
        Get-ChildItem -LiteralPath $r -Directory -Force -ErrorAction SilentlyContinue |
            Where-Object { -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -and $_.FullName -notin $raizes -and $_.FullName -ne "$U\AppData" } |
            ForEach-Object { [pscustomobject]@{ Path = $_.FullName; GB = (Get-TamanhoGB $_.FullName); Mod = $_.LastWriteTime } }
    }
    foreach ($p in $pastas | Sort-Object GB -Descending | Select-Object -First 15) {
        Add-R 'Maiores pastas' $p.Path 'Info' "$($p.GB) GB (modificada em $($p.Mod.ToString('dd/MM/yyyy')))"
    }

    $dl = Join-Path $U 'Downloads'
    if (Test-Path $dl) {
        $gb = Get-TamanhoGB $dl
        $velhos = @(Get-ChildItem $dl -File -Force | Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-90) }).Count
        Add-R 'Espaço' 'Downloads' $(if ($gb -ge 5) { 'Atenção' } else { 'Info' }) "$gb GB, $velhos arquivo(s) com mais de 90 dias"
    }

    if ($Profundo) {
        Write-Host '  procurando arquivos > 1 GB no C: (demora)...' -ForegroundColor DarkGray
        Get-ChildItem C:\ -Recurse -File -Force -ErrorAction SilentlyContinue -Attributes !ReparsePoint |
            Where-Object { $_.Length -gt 1GB -and $_.FullName -notlike 'C:\Windows\*' } |
            Sort-Object Length -Descending | Select-Object -First 25 |
            ForEach-Object { Add-R 'Arquivos > 1 GB' $_.FullName 'Info' "$([math]::Round($_.Length/1GB,2)) GB, último acesso $($_.LastAccessTime.ToString('dd/MM/yyyy'))" }
    }
}

# ---------------------------------------------------------------- Segurança
function Test-Seguranca {
    $mp = Get-MpComputerStatus
    if ($mp) {
        Add-R 'Segurança' 'Defender tempo real' $(if ($mp.RealTimeProtectionEnabled) { 'OK' } else { 'Atenção' }) "Ativo: $($mp.RealTimeProtectionEnabled), proteção contra adulteração: $($mp.IsTamperProtected)"
        $idade = ((Get-Date) - $mp.AntivirusSignatureLastUpdated).Days
        Add-R 'Segurança' 'Defender assinaturas' $(if ($idade -gt 3) { 'Atenção' } else { 'OK' }) "Atualizadas há $idade dia(s)"
        if ($mp.FullScanEndTime) { Add-R 'Segurança' 'Varredura completa' 'OK' "Última em $($mp.FullScanEndTime)" }
        else { Add-R 'Segurança' 'Varredura completa' 'Atenção' 'Nunca foi feita (Segurança do Windows > Proteção contra vírus > Opções de verificação)' }
        $ameacas = @(Get-MpThreatDetection)
        if ($ameacas.Count) { foreach ($a in $ameacas) { Add-R 'Segurança' 'Ameaça detectada' 'Atenção' "$($a.InitialDetectionTime): $($a.Resources -join '; ')" } }
        else { Add-R 'Segurança' 'Histórico de ameaças' 'OK' 'Vazio' }
    } else {
        $av = (Get-CimInstance -Namespace root/SecurityCenter2 -ClassName AntiVirusProduct | ForEach-Object displayName) -join ', '
        Add-R 'Segurança' 'Antivírus' 'Info' "Defender indisponível; registrados: $av"
    }
    foreach ($f in Get-NetFirewallProfile) { Add-R 'Segurança' "Firewall $($f.Name)" $(if ($f.Enabled) { 'OK' } else { 'Atenção' }) "Ativo: $($f.Enabled)" }
    $uac = Get-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' EnableLUA
    Add-R 'Segurança' 'UAC' $(if ($uac -eq 0) { 'Atenção' } else { 'OK' }) $(if ($uac -eq 0) { 'Desativado' } else { 'Ativo' })

    $hosts = @(Get-Content "$env:windir\System32\drivers\etc\hosts" | Where-Object { $_ -notmatch '^\s*#' -and $_.Trim() })
    if ($hosts.Count) { Add-R 'Segurança' 'Arquivo hosts' $(if ($hosts.Count -gt 10) { 'Atenção' } else { 'Info' }) "$($hosts.Count) linha(s): $(($hosts | Select-Object -First 5) -join ' | ')" }
    $px = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    if ($px.ProxyEnable -eq 1 -or $px.AutoConfigURL) { Add-R 'Segurança' 'Proxy' 'Atenção' "Proxy: $($px.ProxyServer) $($px.AutoConfigURL)" }

    $w = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    if ($w.Shell -ne 'explorer.exe' -or $w.Userinit -notmatch '^C:\\Windows\\system32\\userinit\.exe,?$') { Add-R 'Segurança' 'Winlogon' 'Atenção' "Shell=$($w.Shell) Userinit=$($w.Userinit)" }
    Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options' | ForEach-Object {
        $d = (Get-ItemProperty $_.PSPath).Debugger
        if ($d) { Add-R 'Segurança' "IFEO $($_.PSChildName)" 'Atenção' "Debugger => $d" }
    }

    $estranhos = Get-Process | Where-Object { $_.Path -match '\\AppData\\Local\\Temp\\|\\Users\\Public\\' }
    foreach ($p in $estranhos) { Add-R 'Segurança' "Processo $($p.Name)" 'Atenção' "Rodando de local incomum: $($p.Path)" }
    foreach ($p in Get-Process | Where-Object Path | Select-Object -ExpandProperty Path -Unique) {
        if ((Get-AuthenticodeSignature -LiteralPath $p).Status -ne 'Valid') { Add-R 'Segurança' 'Processo sem assinatura' 'Info' $p }
    }
}

# ---------------------------------------------------------------- Inicialização e serviços
function Test-Inicializacao {
    # StartupApproved: o 1º byte par = ativo, ímpar = desativado pelo Gerenciador de Tarefas
    $fontes = @(
        @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Run', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'),
        @('HKLM:\Software\Microsoft\Windows\CurrentVersion\Run', 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'),
        @('HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run', 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run32')
    )
    foreach ($f in $fontes) {
        $itens = Get-ItemProperty $f[0]; if (-not $itens) { continue }
        $aprov = Get-ItemProperty $f[1]
        foreach ($p in $itens.PSObject.Properties | Where-Object Name -notlike 'PS*') {
            $b = $aprov.($p.Name)
            if ($b -and ($b[0] % 2)) { continue }
            $sig = Get-Assinante (Get-ExeDeComando $p.Value)
            Add-R 'Inicialização' $p.Name $(if ($sig -like 'SEM*') { 'Atenção' } else { 'Info' }) "$sig :: $($p.Value)"
        }
    }
    $aprovPasta = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder'
    Get-ChildItem "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup", "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\Startup" -File -Force |
        Where-Object Name -ne 'desktop.ini' | ForEach-Object {
            $b = $aprovPasta.($_.Name)
            if (-not ($b -and ($b[0] % 2))) { Add-R 'Inicialização' $_.Name 'Info' "Pasta Inicializar: $($_.FullName)" }
        }

    Get-ScheduledTask | Where-Object { $_.TaskPath -notlike '\Microsoft\*' -and $_.State -ne 'Disabled' } | ForEach-Object {
        $acao = ($_.Actions | ForEach-Object { "$($_.Execute) $($_.Arguments)".Trim() }) -join ' | '
        if ($acao) { Add-R 'Tarefas agendadas' "$($_.TaskPath)$($_.TaskName)" 'Info' $acao }
    }

    Get-CimInstance Win32_Service | Where-Object { $_.StartMode -eq 'Auto' -and $_.PathName -notmatch '\\Windows\\(System32|SysWOW64)\\svchost' } | ForEach-Object {
        $sig = Get-Assinante (Get-ExeDeComando $_.PathName)
        if ($sig -notmatch 'Microsoft') { Add-R 'Serviços de terceiros' $_.Name $(if ($sig -like 'SEM*') { 'Atenção' } else { 'Info' }) "[$($_.State)] $sig :: $($_.DisplayName)" }
    }
}

# ---------------------------------------------------------------- Otimizações
function Test-Otimizacoes {
    $cdm = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
    $anuncios = 'SilentInstalledAppsEnabled', 'SystemPaneSuggestionsEnabled', 'SubscribedContent-338388Enabled', 'SubscribedContent-338389Enabled', 'SubscribedContent-353694Enabled'
    $ligados = @($anuncios | Where-Object { (Get-Reg $cdm $_) -ne 0 })
    Add-R 'Otimizações' 'Anúncios e sugestões' $(if ($ligados.Count) { 'Atenção' } else { 'OK' }) $(if ($ligados.Count) { "Ligados: $($ligados -join ', ')" } else { 'Desligados' })

    $dvr = (Get-Reg 'HKCU:\System\GameConfigStore' GameDVR_Enabled) -ne 0 -or (Get-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' AppCaptureEnabled) -eq 1
    Add-R 'Otimizações' 'Gravação em 2º plano (Game DVR)' $(if ($dvr) { 'Atenção' } else { 'OK' }) $(if ($dvr) { 'Ligada (pesa um pouco nos jogos)' } else { 'Desligada' })

    $bing = (Get-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' BingSearchEnabled) -ne 0
    Add-R 'Otimizações' 'Bing na busca do Iniciar' $(if ($bing) { 'Atenção' } else { 'OK' }) $(if ($bing) { 'Ligado' } else { 'Desligado' })

    $fast = (Get-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' HiberbootEnabled) -eq 1
    Add-R 'Otimizações' 'Inicialização rápida' $(if ($fast) { 'Info' } else { 'OK' }) $(if ($fast) { 'Ligada (pode causar problemas com drivers e dual boot)' } else { 'Desligada' })

    $plano = (powercfg /getactivescheme) -replace '^.*\((.+)\)\s*$', '$1'
    Add-R 'Otimizações' 'Plano de energia' 'Info' $plano

    $diag = Get-Service DiagTrack
    if ($diag) { Add-R 'Otimizações' 'Telemetria (DiagTrack)' $(if ($diag.StartType -ne 'Disabled') { 'Atenção' } else { 'OK' }) "$($diag.Status)/$($diag.StartType)" }

    $bloat = 'Microsoft.BingSearch', 'Microsoft.BingNews', 'Microsoft.BingWeather', 'Microsoft.GetHelp', 'Microsoft.Getstarted', 'Microsoft.YourPhone',
             'Microsoft.MicrosoftSolitaireCollection', 'Clipchamp.Clipchamp', 'Microsoft.PowerAutomateDesktop', 'Microsoft.Todos', 'Microsoft.People',
             'Microsoft.WindowsFeedbackHub', 'MicrosoftTeams', 'MSTeams', 'Microsoft.OutlookForWindows', 'Microsoft.MicrosoftOfficeHub', 'Microsoft.Copilot'
    foreach ($a in Get-AppxPackage | Where-Object Name -in $bloat) { Add-R 'Otimizações' "App: $($a.Name)" 'Info' 'App pré-instalado que costuma ser removido no debloat' }
}

# ---------------------------------------------------------------- Atualizações
function Test-Atualizacoes {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) { Add-R 'Atualizações' 'winget' 'Atenção' 'winget não encontrado (instale o "Instalador de Aplicativo" pela Microsoft Store)'; return }
    $linhas = @(winget upgrade --accept-source-agreements --include-unknown 2>$null | Where-Object { $_ -match '\S' -and $_ -notmatch '^[\s\-\\|/]+$' })
    # A tabela tem colunas de largura fixa: o nome vai até a coluna "ID". Rodapés ("3 upgrades available.") terminam em ponto.
    $i = 0; while ($i -lt $linhas.Count -and $linhas[$i] -notmatch '(Name|Nome)\s+ID\s') { $i++ }
    $pacotes = @()
    if ($i -lt $linhas.Count) {
        $colId = $linhas[$i].IndexOf(' ID ') + 1
        $pacotes = @($linhas[($i + 1)..($linhas.Count - 1)] | Where-Object { $_ -notmatch '^-+$' -and $_ -notmatch '\.\s*$' -and $_.Length -gt $colId })
    }
    if ($pacotes.Count) { foreach ($p in $pacotes) { Add-R 'Atualizações' $p.Substring(0, $colId).Trim() 'Atenção' ($p.Substring($colId) -replace '\s+', ' ') } }
    else { Add-R 'Atualizações' 'winget' 'OK' 'Tudo atualizado' }
}

# ---------------------------------------------------------------- Ações
function Limpar-Pastas($Caminhos) {
    foreach ($c in $Caminhos) {
        if (-not (Test-Path $c)) { continue }
        $antes = Get-TamanhoGB $c
        Get-ChildItem -LiteralPath $c -Force | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host ("  {0}: {1} GB -> {2} GB" -f $c, $antes, (Get-TamanhoGB $c))
    }
}

$ListaAcoes = @(
    @{ Nome = 'Limpar caches (npm, Gradle, pip, Yarn, shaders, dumps, temporários)'; Admin = $false; Script = {
        if (Get-Command npm -ErrorAction SilentlyContinue) { npm cache clean --force 2>&1 | Out-Null }
        Limpar-Pastas @("$env:LOCALAPPDATA\npm-cache", "$env:USERPROFILE\.gradle\caches", "$env:LOCALAPPDATA\pip\cache", "$env:LOCALAPPDATA\Yarn\Cache",
                        "$env:LOCALAPPDATA\NVIDIA\DXCache", "$env:LOCALAPPDATA\D3DSCache", "$env:LOCALAPPDATA\CrashDumps", $env:TEMP) } },
    @{ Nome = 'Desligar anúncios e sugestões no Iniciar'; Admin = $false; Script = {
        $cdm = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
        'SilentInstalledAppsEnabled', 'SystemPaneSuggestionsEnabled', 'SoftLandingEnabled', 'PreInstalledAppsEnabled', 'OemPreInstalledAppsEnabled', 'SubscribedContentEnabled',
        'SubscribedContent-338388Enabled', 'SubscribedContent-338389Enabled', 'SubscribedContent-338393Enabled', 'SubscribedContent-353694Enabled', 'SubscribedContent-353696Enabled', 'SubscribedContent-310093Enabled' |
            ForEach-Object { Set-Reg $cdm $_ 0 }
        Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' Start_IrisRecommendations 0
        Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\UserProfileEngagement' ScoobeSystemSettingEnabled 0 } },
    @{ Nome = 'Desligar gravação em 2º plano do Game Bar (mantém os apps do Xbox)'; Admin = $false; Script = {
        Set-Reg 'HKCU:\System\GameConfigStore' GameDVR_Enabled 0
        Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' AppCaptureEnabled 0
        Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' HistoricalCaptureEnabled 0
        Set-Reg 'HKCU:\Software\Microsoft\GameBar' UseNexusForGameBarEnabled 0
        if ($IsAdmin) { Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR' AllowGameDVR 0 } } },
    @{ Nome = 'Desligar Bing na busca do Iniciar'; Admin = $false; Script = {
        Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' BingSearchEnabled 0
        if ($IsAdmin) { Set-Reg 'HKCU:\Software\Policies\Microsoft\Windows\Explorer' DisableSearchBoxSuggestions 1 } } },
    @{ Nome = 'Desligar inicialização rápida'; Admin = $true; Script = {
        Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' HiberbootEnabled 0 } },
    @{ Nome = 'Atualizar todos os apps (winget upgrade --all)'; Admin = $false; Script = {
        winget upgrade --all --silent --accept-source-agreements --accept-package-agreements --include-unknown } }
)

function Show-MenuAcoes {
    Write-Host "`n=== Ações (nada roda sem confirmação) ===" -ForegroundColor Cyan
    if (-not $IsAdmin) { Write-Host 'Não está como administrador: ações marcadas com [admin] vão ser puladas.' -ForegroundColor Yellow }
    for ($i = 0; $i -lt $ListaAcoes.Count; $i++) {
        $tag = if ($ListaAcoes[$i].Admin) { ' [admin]' } else { '' }
        Write-Host ("  {0}. {1}{2}" -f ($i + 1), $ListaAcoes[$i].Nome, $tag)
    }
    $esc = Read-Host "`nNúmeros separados por vírgula (Enter para sair)"
    foreach ($n in $esc -split '[,\s]+' | Where-Object { $_ -match '^\d+$' }) {
        $a = $ListaAcoes[[int]$n - 1]; if (-not $a) { continue }
        if ($a.Admin -and -not $IsAdmin) { Write-Host "Pulado (precisa de admin): $($a.Nome)" -ForegroundColor Yellow; continue }
        if ((Read-Host "Executar '$($a.Nome)'? (s/N)") -notmatch '^s') { continue }
        & $a.Script
        Write-Host "Feito: $($a.Nome)" -ForegroundColor Green
    }
}

# ---------------------------------------------------------------- Execução
$etapas = [ordered]@{ 'Sistema' = { Test-Sistema }; 'Discos' = { Test-Discos }; 'Espaço' = { Test-Espaco }; 'Segurança' = { Test-Seguranca }
                      'Inicialização e serviços' = { Test-Inicializacao }; 'Otimizações' = { Test-Otimizacoes }; 'Atualizações' = { Test-Atualizacoes } }
Write-Host "Zelador - análise do Windows $(if ($IsAdmin) { '(admin)' } else { '(usuário comum; alguns itens precisam de admin)' })" -ForegroundColor Cyan
foreach ($e in $etapas.GetEnumerator()) { Write-Host "> $($e.Key)"; & $e.Value }

$cores = @{ 'OK' = 'Green'; 'Atenção' = 'Yellow'; 'Info' = 'Gray' }
foreach ($g in $Resultados | Group-Object Categoria) {
    Write-Host "`n== $($g.Name) ==" -ForegroundColor Cyan
    foreach ($r in $g.Group) { Write-Host ("[{0,-7}] {1}: {2}" -f $r.Status, $r.Item, $r.Detalhe) -ForegroundColor $cores[$r.Status] }
}
$n = @($Resultados | Where-Object Status -eq 'Atenção').Count
Write-Host "`n$n item(ns) pedem atenção." -ForegroundColor $(if ($n) { 'Yellow' } else { 'Green' })

if ($Html) {
    $css = '<style>body{font-family:Segoe UI,sans-serif;margin:24px}table{border-collapse:collapse;width:100%}td,th{border:1px solid #ccc;padding:4px 8px;text-align:left;vertical-align:top}th{background:#eee}tr.Atencao{background:#fff4ce}tr.OK{background:#e7f6e7}</style>'
    $enc = { param($t) [System.Net.WebUtility]::HtmlEncode("$t") }
    $linhas = foreach ($r in $Resultados) {
        $cls = @{ 'OK' = 'OK'; 'Atenção' = 'Atencao' }[$r.Status]
        "<tr class='$cls'><td>$(& $enc $r.Categoria)</td><td>$(& $enc $r.Item)</td><td>$(& $enc $r.Status)</td><td>$(& $enc $r.Detalhe)</td></tr>"
    }
    $titulo = "Zelador - $env:COMPUTERNAME - $(Get-Date -Format 'dd/MM/yyyy HH:mm')"
    "<!doctype html><html><head><meta charset='utf-8'><title>Zelador</title>$css</head><body><h1>$titulo</h1><table><tr><th>Categoria</th><th>Item</th><th>Status</th><th>Detalhe</th></tr>$($linhas -join '')</table></body></html>" | Out-File $Html -Encoding utf8
    Write-Host "Relatório salvo em $((Resolve-Path $Html).Path)"
}

if ($Acoes) { Show-MenuAcoes }
