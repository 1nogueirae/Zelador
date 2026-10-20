# Ações que alteram o sistema. Toda mudança de registro ou serviço devolve o estado anterior,
# que vai para o registro de ações e permite desfazer depois.

$ZArquivoRegistro = Join-Path $env:LOCALAPPDATA 'Zelador\registro.json'

function Read-ZRegistro {
    if (-not (Test-Path $ZArquivoRegistro)) { return @() }
    $texto = Get-Content $ZArquivoRegistro -Raw -Encoding UTF8
    if (-not "$texto".Trim()) { return @() }
    $lista = ConvertFrom-Json $texto
    @($lista)
}

function Save-ZRegistro($Lista) {
    New-Item -ItemType Directory -Force (Split-Path $ZArquivoRegistro) | Out-Null
    ConvertTo-Json -InputObject @($Lista) -Depth 6 | Set-Content $ZArquivoRegistro -Encoding UTF8
}

function Add-ZRegistro($Descricao, $Desfazer) {
    $novo = [pscustomobject]@{ Id = [guid]::NewGuid().ToString(); Data = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); Descricao = $Descricao; Desfazer = @($Desfazer); Desfeito = $false }
    Save-ZRegistro (@($novo) + @(Read-ZRegistro) | Select-Object -First 300)
}

# Grava um valor ($null apaga) e devolve como estava antes.
function Set-ZReg($Chave, $Nome, $Valor, $Tipo = 'DWord') {
    $k = Get-Item -LiteralPath $Chave -ErrorAction SilentlyContinue
    $antes = [pscustomobject]@{ T = 'Reg'; Chave = $Chave; Nome = $Nome; Existia = $false; Valor = $null; Tipo = $null }
    if ($k -and ($k.GetValueNames() -contains $Nome)) { $antes.Existia = $true; $antes.Valor = $k.GetValue($Nome); $antes.Tipo = "$($k.GetValueKind($Nome))" }
    if ($null -eq $Valor) { Remove-ItemProperty -LiteralPath $Chave -Name $Nome -ErrorAction SilentlyContinue }
    else {
        if (-not $k) { New-Item -Path $Chave -Force | Out-Null }
        New-ItemProperty -LiteralPath $Chave -Name $Nome -Value $Valor -PropertyType $Tipo -Force | Out-Null
    }
    $antes
}

function Set-ZServico($Nome, $Tipo) {
    $antes = "$((Get-Service $Nome).StartType)"
    Set-Service -Name $Nome -StartupType $Tipo
    [pscustomobject]@{ T = 'Servico'; Nome = $Nome; Valor = $antes }
}

function Undo-ZRegistro($Id) {
    $lista = @(Read-ZRegistro)
    $e = $lista | Where-Object Id -eq $Id
    $recs = @($e.Desfazer)
    [array]::Reverse($recs)
    foreach ($r in $recs) {
        if ($r.T -eq 'Servico') { Set-Service -Name $r.Nome -StartupType $r.Valor; continue }
        if (-not $r.Existia) { Remove-ItemProperty -LiteralPath $r.Chave -Name $r.Nome -ErrorAction SilentlyContinue; continue }
        $v = switch ($r.Tipo) { 'Binary' { [byte[]]@($r.Valor) } 'MultiString' { [string[]]@($r.Valor) } default { $r.Valor } }
        if (-not (Test-Path -LiteralPath $r.Chave)) { New-Item -Path $r.Chave -Force | Out-Null }
        New-ItemProperty -LiteralPath $r.Chave -Name $r.Nome -Value $v -PropertyType $r.Tipo -Force | Out-Null
    }
    $e.Desfeito = $true
    Save-ZRegistro $lista
}

# ---------------------------------------------------------------- Ajustes (debloat)
# Cada item: K/N = chave/valor do registro, On = valor otimizado, Off = padrão do Windows ($null = apagar), T = tipo.
# Ou S = serviço, com On/Off sendo o tipo de inicialização.
$cdm = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
$ZTweaks = @(
    @{ Id = 'anuncios'; Nome = 'Desligar anúncios e sugestões'; Admin = $false
       Desc = 'Apps instalados sem pedir, dicas e recomendações no Iniciar, ID de anúncio.'
       Itens = @(
           @{ K = $cdm; N = 'SilentInstalledAppsEnabled'; On = 0; Off = 1 }, @{ K = $cdm; N = 'SystemPaneSuggestionsEnabled'; On = 0; Off = 1 },
           @{ K = $cdm; N = 'SoftLandingEnabled'; On = 0; Off = 1 }, @{ K = $cdm; N = 'SubscribedContent-338388Enabled'; On = 0; Off = 1 },
           @{ K = $cdm; N = 'SubscribedContent-338389Enabled'; On = 0; Off = 1 }, @{ K = $cdm; N = 'SubscribedContent-353694Enabled'; On = 0; Off = 1 },
           @{ K = $cdm; N = 'SubscribedContent-353696Enabled'; On = 0; Off = 1 },
           @{ K = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; N = 'Start_IrisRecommendations'; On = 0; Off = $null },
           @{ K = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo'; N = 'Enabled'; On = 0; Off = 1 }) },
    @{ Id = 'gamedvr'; Nome = 'Desligar gravação em segundo plano do Game Bar'; Admin = $false
       Desc = 'Para de gravar os jogos o tempo todo. Os apps do Xbox continuam instalados.'
       Itens = @(
           @{ K = 'HKCU:\System\GameConfigStore'; N = 'GameDVR_Enabled'; On = 0; Off = 1 },
           @{ K = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR'; N = 'AppCaptureEnabled'; On = 0; Off = $null },
           @{ K = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR'; N = 'HistoricalCaptureEnabled'; On = 0; Off = $null },
           @{ K = 'HKCU:\Software\Microsoft\GameBar'; N = 'UseNexusForGameBarEnabled'; On = 0; Off = $null }) },
    @{ Id = 'bing'; Nome = 'Tirar o Bing da busca do Iniciar'; Admin = $false
       Desc = 'A busca do Iniciar procura só no PC.'
       Itens = @(
           @{ K = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search'; N = 'BingSearchEnabled'; On = 0; Off = $null },
           @{ K = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search'; N = 'CortanaConsent'; On = 0; Off = $null }) },
    @{ Id = 'buscaweb'; Nome = 'Bloquear sugestões da web na busca'; Admin = $true
       Desc = 'Reforço por política: o Windows não volta a ligar a busca na web.'
       Itens = @(@{ K = 'HKCU:\Software\Policies\Microsoft\Windows\Explorer'; N = 'DisableSearchBoxSuggestions'; On = 1; Off = $null }) },
    @{ Id = 'extensoes'; Nome = 'Mostrar extensões de arquivos'; Admin = $false
       Desc = 'Mostra ".exe", ".pdf" etc. Ajuda a perceber arquivos disfarçados. Vale depois de reabrir o Explorer.'
       Itens = @(@{ K = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; N = 'HideFileExt'; On = 0; Off = 1 }) },
    @{ Id = 'mouse'; Nome = 'Desligar aceleração do mouse'; Admin = $false
       Desc = 'Movimento 1:1, melhor para jogos. Vale depois de sair e entrar na conta.'
       Itens = @(
           @{ K = 'HKCU:\Control Panel\Mouse'; N = 'MouseSpeed'; On = '0'; Off = '1'; T = 'String' },
           @{ K = 'HKCU:\Control Panel\Mouse'; N = 'MouseThreshold1'; On = '0'; Off = '6'; T = 'String' },
           @{ K = 'HKCU:\Control Panel\Mouse'; N = 'MouseThreshold2'; On = '0'; Off = '10'; T = 'String' }) },
    @{ Id = 'fastboot'; Nome = 'Desligar inicialização rápida'; Admin = $true
       Desc = 'O PC desliga de verdade. Evita problemas com drivers; o boot fica um pouco mais lento.'
       Itens = @(@{ K = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power'; N = 'HiberbootEnabled'; On = 0; Off = 1 }) },
    @{ Id = 'telemetria'; Nome = 'Reduzir telemetria'; Admin = $true
       Desc = 'Desliga o serviço de rastreamento (DiagTrack) e pede o nível mínimo de dados.'
       Itens = @(
           @{ S = 'DiagTrack'; On = 'Disabled'; Off = 'Automatic' },
           @{ S = 'dmwappushservice'; On = 'Disabled'; Off = 'Manual' },
           @{ K = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection'; N = 'AllowTelemetry'; On = 0; Off = $null }) },
    @{ Id = 'recall'; Nome = 'Desligar o Recall'; Admin = $true
       Desc = 'Impede o Windows de tirar capturas da tela para a busca por IA.'
       Itens = @(
           @{ K = 'HKCU:\Software\Policies\Microsoft\Windows\WindowsAI'; N = 'DisableAIDataAnalysis'; On = 1; Off = $null },
           @{ K = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI'; N = 'DisableAIDataAnalysis'; On = 1; Off = $null }) }
)

function Test-ZTweak($t) {
    foreach ($i in $t.Itens) {
        if ($i.S) {
            $s = Get-Service $i.S -ErrorAction SilentlyContinue
            if ($s -and "$($s.StartType)" -ne $i.On) { return $false }
            continue
        }
        if ("$(Get-ZReg $i.K $i.N)" -ne "$($i.On)") { return $false }
    }
    $true
}

function Get-ZTweaks { foreach ($t in $ZTweaks) { [pscustomobject]@{ Id = $t.Id; Nome = $t.Nome; Desc = $t.Desc; Admin = $t.Admin; Ativo = Test-ZTweak $t } } }

function Set-ZTweak($Id, [bool]$Ligar) {
    $t = $ZTweaks | Where-Object { $_.Id -eq $Id }
    $desfazer = foreach ($i in $t.Itens) {
        $alvo = if ($Ligar) { $i.On } else { $i.Off }
        if ($i.S) { if (Get-Service $i.S -ErrorAction SilentlyContinue) { Set-ZServico $i.S $alvo } }
        else { Set-ZReg $i.K $i.N $alvo $(if ($i.T) { $i.T } else { 'DWord' }) }
    }
    Add-ZRegistro "$(if ($Ligar) { 'Aplicado' } else { 'Revertido' }): $($t.Nome)" @($desfazer)
}

# ---------------------------------------------------------------- Inicialização e serviços
# StartupApproved: 1º byte par = ativo, ímpar = desativado (o mesmo que o Gerenciador de Tarefas usa).
function Set-ZInicio($Item, [bool]$Ativo) {
    $bytes = if ($Ativo) { [byte[]](2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0) } else { [byte[]](@(3, 0, 0, 0) + [BitConverter]::GetBytes([DateTime]::Now.ToFileTime())) }
    $r = Set-ZReg $Item.Aprov $Item.Nome $bytes 'Binary'
    Add-ZRegistro "$(if ($Ativo) { 'Ativado' } else { 'Desativado' }) na inicialização: $($Item.Nome)" @($r)
}

function Set-ZServicoAuto($Nome, [bool]$Auto) {
    $r = Set-ZServico $Nome $(if ($Auto) { 'Automatic' } else { 'Manual' })
    Add-ZRegistro "Serviço $($Nome): $(if ($Auto) { 'Automático' } else { 'Manual' })" @($r)
}

# ---------------------------------------------------------------- Limpeza (roda em segundo plano; devolve bytes liberados)
function Clear-ZCache($Id) {
    $c = Get-ZDefCaches | Where-Object Id -eq $Id
    $antes = [Zelador.Nativo]::TamanhoPasta($c.Caminho)
    switch ($c.Modo) {
        'Lixeira' { Clear-RecycleBin -Force -ErrorAction SilentlyContinue }
        'Npm' {
            if (Get-Command npm -ErrorAction SilentlyContinue) { npm cache clean --force 2>&1 | Out-Null }
            Get-ChildItem -LiteralPath $c.Caminho -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        }
        'Conteudo' { Get-ChildItem -LiteralPath $c.Caminho -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue }
    }
    [pscustomobject]@{ Nome = $c.Nome; Liberado = [math]::Max(0, $antes - [Zelador.Nativo]::TamanhoPasta($c.Caminho)) }
}
