<#
.SYNOPSIS
    Zelador: painel de análise e manutenção do Windows.

.DESCRIPTION
    Interface WPF em Windows PowerShell 5.1, sem instalar nada. Abra pelo zelador.cmd.
    O trabalho pesado (medir pastas, winget, Defender) roda em runspaces para a janela não travar.
#>
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    Start-Process powershell -ArgumentList "-STA -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`""
    return
}

try {
    $Raiz = $PSScriptRoot
    . "$Raiz\src\coleta.ps1"
    . "$Raiz\src\acoes.ps1"
    $IsAdmin = Test-ZAdmin

    $Cor = @{ Ok = '#3FB950'; Warn = '#E3A33B'; Bad = '#F2555A'; Accent = '#5B8CFF'; Muted = '#8A93A3'
              FundoOk = '#1A3A24'; FundoWarn = '#3D2F14'; FundoBad = '#45191C'; FundoAccent = '#1E2A47' }
    $Conversor = New-Object Windows.Media.BrushConverter
    function Pincel($hex) { $Conversor.ConvertFromString($hex) }

    $texto = Get-Content "$Raiz\src\janela.xaml" -Raw -Encoding UTF8
    $janela = [Windows.Markup.XamlReader]::Parse($texto)
    $ui = @{}
    foreach ($m in [regex]::Matches($texto, 'x:Name="(\w+)"')) {
        $el = $janela.FindName($m.Groups[1].Value)
        if ($el) { $ui[$m.Groups[1].Value] = $el }
    }

    function Format-Tam($b) {
        if ($b -ge 1GB) { '{0:N1} GB' -f ($b / 1GB) } elseif ($b -ge 1MB) { '{0:N0} MB' -f ($b / 1MB) } elseif ($b -gt 0) { '{0:N0} KB' -f ($b / 1KB) } else { '0' }
    }
    function Confirmar($msg) { [Windows.MessageBox]::Show($janela, $msg, 'Zelador', 'YesNo', 'Question') -eq 'Yes' }
    function Avisar($msg) { [Windows.MessageBox]::Show($janela, $msg, 'Zelador', 'OK', 'Information') | Out-Null }

    # Erro em qualquer clique vira uma mensagem, em vez de derrubar o app.
    $janela.Dispatcher.Add_UnhandledException({
        param($s, $e)
        $e.Handled = $true
        [Windows.MessageBox]::Show($janela, $e.Exception.Message, 'Zelador', 'OK', 'Error') | Out-Null
    })

    # ------------------------------------------------------------ Tarefas em segundo plano
    $script:Tarefas = New-Object System.Collections.ArrayList
    $script:FilaPastas = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
    $script:FilaLog = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'

    # Roda $Trabalho num runspace com coleta.ps1/acoes.ps1 carregados; $AoTerminar recebe (resultados, erro, contexto) na thread da janela.
    function Start-Tarefa([scriptblock]$Trabalho, [scriptblock]$AoTerminar, [hashtable]$Vars = @{}, $Fila = $null, $Ctx = $null) {
        $rs = [runspacefactory]::CreateRunspace()
        $rs.Open()
        foreach ($k in $Vars.Keys) { $rs.SessionStateProxy.SetVariable($k, $Vars[$k]) }
        $rs.SessionStateProxy.SetVariable('Fila', $Fila)
        $ps = [powershell]::Create()
        $ps.Runspace = $rs
        [void]$ps.AddScript(". `"$Raiz\src\coleta.ps1`"; . `"$Raiz\src\acoes.ps1`"`n" + $Trabalho.ToString())
        [void]$script:Tarefas.Add(@{ PS = $ps; H = $ps.BeginInvoke(); Fim = $AoTerminar; Ctx = $Ctx })
        Update-Status
    }

    function Update-Status {
        $n = $script:Tarefas.Count
        $ui.txtStatus.Text = if ($n) { "Trabalhando… ($n)" } else { "Atualizado às $(Get-Date -Format 'HH:mm')" }
        if (-not $n) { $ui.btnAnalisar.IsEnabled = $true }
    }

    $timerTarefas = New-Object Windows.Threading.DispatcherTimer
    $timerTarefas.Interval = [TimeSpan]::FromMilliseconds(150)
    $timerTarefas.Add_Tick({
        $s = $null; $ultimo = $null
        while ($script:FilaPastas.TryDequeue([ref]$s)) { $ultimo = $s }
        if ($ultimo) { $ui.txtPastasStatus.Text = "Medindo $ultimo" }
        foreach ($t in @($script:Tarefas)) {
            if (-not $t.H.IsCompleted) { continue }
            $script:Tarefas.Remove($t)
            $res = @(); $erro = $null
            try { $res = @($t.PS.EndInvoke($t.H)) } catch { $erro = $_.Exception.InnerException; if (-not $erro) { $erro = $_.Exception } }
            $t.PS.Runspace.Dispose(); $t.PS.Dispose()
            try { if ($t.Fim) { & $t.Fim $res $erro $t.Ctx } } finally { Update-Status }
        }
        $linhas = New-Object System.Text.StringBuilder
        $s = $null
        while ($script:FilaLog.TryDequeue([ref]$s)) { [void]$linhas.AppendLine($s) }
        if ($linhas.Length) { $ui.txtAtuLog.AppendText($linhas.ToString()); $ui.txtAtuLog.ScrollToEnd() }
    })
    $timerTarefas.Start()

    # ------------------------------------------------------------ Navegação
    $Paginas = [ordered]@{
        Painel         = 'Painel', 'Visão geral da máquina'
        Armazenamento  = 'Armazenamento', 'Para onde foi o espaço do disco'
        Seguranca      = 'Segurança', 'Antivírus, firewall e sinais suspeitos'
        Inicializacao  = 'Inicialização', 'O que abre junto com o Windows'
        Debloat        = 'Debloat', 'Ajustes de privacidade e desempenho'
        Atualizacoes   = 'Atualizações', 'Apps desatualizados pelo winget'
        Bateria        = 'Bateria', 'Saúde da bateria do notebook'
        Registro       = 'Registro de ações', 'Histórico de mudanças, com desfazer'
    }
    function Show-Pagina($nome) {
        foreach ($p in $Paginas.Keys) { $ui["pg$p"].Visibility = if ($p -eq $nome) { 'Visible' } else { 'Collapsed' } }
        $ui.txtTitulo.Text = $Paginas[$nome][0]
        $ui.txtSubtitulo.Text = $Paginas[$nome][1]
        if (-not $ui["nav$nome"].IsChecked) { $ui["nav$nome"].IsChecked = $true }
    }
    foreach ($p in $Paginas.Keys) { $ui["nav$p"].Add_Checked({ param($s) Show-Pagina ($s.Name -replace '^nav', '') }) }

    # ------------------------------------------------------------ Painel
    $script:Estado = @{}
    $script:HistCpu = New-Object System.Collections.Generic.List[double]
    $script:HistRam = New-Object System.Collections.Generic.List[double]

    function Set-Grafico($canvas, $linha, $preench, $valores) {
        $w = $canvas.ActualWidth; $h = $canvas.ActualHeight
        if ($w -le 0 -or $valores.Count -lt 2) { return }
        $pts = New-Object Windows.Media.PointCollection
        $ini = 60 - $valores.Count
        for ($i = 0; $i -lt $valores.Count; $i++) { $pts.Add([Windows.Point]::new($w * ($ini + $i) / 59, $h - 2 - ($valores[$i] / 100) * ($h - 4))) }
        $linha.Points = $pts
        $area = $pts.Clone()
        $area.Add([Windows.Point]::new($w, $h)); $area.Add([Windows.Point]::new($w * $ini / 59, $h))
        $preench.Points = $area
    }

    function Set-Arco($nota, $hex) {
        $r = 43.5; $c = 48
        $ang = [math]::Min(359.9, 360 * $nota / 100) * [math]::PI / 180
        $fig = New-Object Windows.Media.PathFigure
        $fig.StartPoint = [Windows.Point]::new($c, $c - $r)
        $fim = [Windows.Point]::new($c + $r * [math]::Sin($ang), $c - $r * [math]::Cos($ang))
        $fig.Segments.Add((New-Object Windows.Media.ArcSegment($fim, [Windows.Size]::new($r, $r), 0, ($ang -gt [math]::PI), 'Clockwise', $true)))
        $geo = New-Object Windows.Media.PathGeometry
        $geo.Figures.Add($fig)
        $ui.arcoSaude.Data = $geo
        $ui.arcoSaude.Stroke = Pincel $hex
    }

    $timerVivo = New-Object Windows.Threading.DispatcherTimer
    $timerVivo.Interval = [TimeSpan]::FromSeconds(1)
    $timerVivo.Add_Tick({
        $cpu = [Zelador.Nativo]::Cpu(); $ram = [Zelador.Nativo]::Ram()
        foreach ($par in @(@($script:HistCpu, $cpu), @($script:HistRam, $ram[0]))) { $par[0].Add($par[1]); if ($par[0].Count -gt 60) { $par[0].RemoveAt(0) } }
        $ui.txtCpu.Text = '{0:N0}%' -f $cpu
        $ui.txtRam.Text = '{0:N0}%' -f $ram[0]
        $ui.txtRamSub.Text = '{0:N1} de {1:N1} GB em uso' -f $ram[2], $ram[1]
        Set-Grafico $ui.cvCpu $ui.lnCpu $ui.fillCpu $script:HistCpu
        Set-Grafico $ui.cvRam $ui.lnRam $ui.fillRam $script:HistRam
    })
    [void][Zelador.Nativo]::Cpu()
    $timerVivo.Start()

    function Show-Sistema {
        $s = $script:Estado.Sistema
        $ligado = (Get-Date) - $s.Boot
        $ui.txtCpuNome.Text = $s.Cpu
        $ui.lstInfo.ItemsSource = @(
            [pscustomobject]@{ Rotulo = 'Windows'; Valor = $s.Windows }
            [pscustomobject]@{ Rotulo = 'Computador'; Valor = "$env:COMPUTERNAME$(if ($s.Modelo -notmatch 'System Product Name|To be filled|Default string') { " · $($s.Modelo)" })" }
            [pscustomobject]@{ Rotulo = 'Placa de vídeo'; Valor = $s.Gpu }
            [pscustomobject]@{ Rotulo = 'Memória'; Valor = "$($s.RamGB) GB" }
            [pscustomobject]@{ Rotulo = 'Placa-mãe'; Valor = $s.PlacaMae }
            [pscustomobject]@{ Rotulo = 'Windows instalado em'; Valor = $s.Instalado.ToString('dd/MM/yyyy') }
            [pscustomobject]@{ Rotulo = 'Ligado há'; Valor = '{0} d {1} h {2} min' -f $ligado.Days, $ligado.Hours, $ligado.Minutes }
        )
    }

    function Show-Discos {
        $ui.lstDiscos.ItemsSource = @(foreach ($d in $script:Estado.Discos) {
            $c = if ($d.UsoPct -ge 90) { $Cor.Bad } elseif ($d.UsoPct -ge 85) { $Cor.Warn } else { $Cor.Accent }
            [pscustomobject]@{
                Titulo = "$($d.Letra):  $($d.Rotulo)".Trim(); Modelo = $d.Modelo; UsoPct = $d.UsoPct; Cor = $c
                LivreTxt = '{0:N1} GB livres' -f $d.LivreGB; TotalTxt = "de $($d.TotalGB) GB"
                Saude = if ($d.Saudavel) { 'Saudável' } else { 'Com problema' }
                CorSaude = if ($d.Saudavel) { $Cor.Ok } else { $Cor.Bad }; FundoSaude = if ($d.Saudavel) { $Cor.FundoOk } else { $Cor.FundoBad }
            }
        })
        $atalhos = @(foreach ($d in $script:Estado.Discos) { [pscustomobject]@{ Nome = "$($d.Letra):"; Icone = [char]0xEDA2; Tag = "pasta|$($d.Letra):\" } })
        $atalhos += [pscustomobject]@{ Nome = 'Minha pasta'; Icone = [char]0xE77B; Tag = "pasta|$env:USERPROFILE" }
        $atalhos += [pscustomobject]@{ Nome = 'AppData\Local'; Icone = [char]0xE8B7; Tag = "pasta|$env:LOCALAPPDATA" }
        $atalhos += [pscustomobject]@{ Nome = 'Arquivos de Programas'; Icone = [char]0xE8B7; Tag = "pasta|$env:ProgramFiles" }
        $ui.lstAtalhos.ItemsSource = $atalhos
    }

    # Nota de saúde: começa em 100 e cada problema tira pontos.
    function Update-Alertas {
        $alertas = New-Object System.Collections.ArrayList
        function A($nivel, $texto, $pagina, $peso) {
            [void]$alertas.Add([pscustomobject]@{ Texto = $texto; Cor = $Cor[$nivel]; Tag = "pagina|$pagina"; Peso = $peso })
        }
        foreach ($d in @($script:Estado.Discos)) {
            if (-not $d) { continue }
            $livre = 100 - $d.UsoPct
            if ($livre -lt 10) { A Bad "Disco $($d.Letra): quase cheio ($($d.LivreGB) GB livres)" 'Armazenamento' 20 }
            elseif ($livre -lt 15) { A Warn "Disco $($d.Letra): com pouco espaço ($($d.LivreGB) GB livres)" 'Armazenamento' 10 }
            if (-not $d.Saudavel) { A Bad "Disco $($d.Letra): o Windows reporta problema de saúde" 'Painel' 25 }
        }
        $s = $script:Estado.Seg
        if ($s) {
            if (-not $s.Defender) { A Warn 'Microsoft Defender indisponível (outro antivírus?)' 'Seguranca' 5 }
            elseif (-not $s.TempoReal) { A Bad 'Proteção em tempo real do Defender desligada' 'Seguranca' 25 }
            if ($s.Assinaturas -and ((Get-Date) - $s.Assinaturas).Days -gt 3) { A Warn 'Assinaturas do Defender desatualizadas' 'Seguranca' 10 }
            if ($s.Defender -and -not $s.Completa) { A Warn 'Nunca foi feita uma varredura completa' 'Seguranca' 5 }
            foreach ($f in $s.Firewall) { if (-not $f.Ativo) { A Bad "Firewall desligado no perfil $($f.Nome)" 'Seguranca' 15 } }
            if (-not $s.Uac) { A Bad 'Controle de Conta de Usuário (UAC) desligado' 'Seguranca' 15 }
            if ($s.Ameacas.Count) { A Bad "$($s.Ameacas.Count) ameaça(s) no histórico do Defender" 'Seguranca' 15 }
            foreach ($x in $s.Anomalias) { A Bad $x 'Seguranca' 15 }
        }
        foreach ($i in @($script:Estado.Inicio | Where-Object { $_ -and $_.Ativo -and $_.Assinante -eq 'Sem assinatura' })) { A Warn "Programa sem assinatura abre com o Windows: $($i.Nome)" 'Inicializacao' 5 }
        foreach ($c in @($script:Estado.Caches | Where-Object { $_ -and $_.Modo -and $_.Bytes -ge 5GB })) { A Warn "$($c.Nome) ocupa $(Format-Tam $c.Bytes)" 'Armazenamento' 3 }
        $drive = @($script:Estado.Caches | Where-Object { $_ -and $_.Id -eq 'drive' -and $_.Bytes -ge 5GB })
        if ($drive) { A Warn "Cache do Google Drive ocupa $(Format-Tam $drive[0].Bytes) no disco" 'Armazenamento' 3 }
        $n = @($script:Estado.Atu).Count
        if ($n) { A Warn "$n app(s) com atualização disponível" 'Atualizacoes' ([math]::Min(10, $n)) }
        $b = $script:Estado.Bateria
        if ($b -and $b.SaudePct -and $b.SaudePct -lt 70) { A Warn "Bateria com $($b.SaudePct)% da capacidade original" 'Bateria' 5 }
        $pend = @(Get-ZTweaks | Where-Object { -not $_.Ativo -and (-not $_.Admin -or $IsAdmin) }).Count
        if ($pend) { A Accent "$pend ajuste(s) de debloat disponíveis" 'Debloat' 0 }

        $lista = @($alertas | Sort-Object Peso -Descending)
        $nota = [math]::Max(0, 100 - ($lista | Measure-Object Peso -Sum).Sum)
        $hex = if ($nota -ge 85) { $Cor.Ok } elseif ($nota -ge 60) { $Cor.Warn } else { $Cor.Bad }
        $ui.txtNota.Text = "$nota"
        Set-Arco $nota $hex
        $ui.txtNotaRotulo.Text = if ($script:Tarefas.Count) { 'Analisando…' } elseif ($nota -ge 95) { 'Tudo em ordem' } elseif ($nota -ge 80) { 'Bom, com detalhes' } elseif ($nota -ge 60) { 'Pede atenção' } else { 'Precisa de cuidado' }
        $graves = @($lista | Where-Object Peso -gt 0).Count
        $ui.txtNotaDetalhe.Text = if ($graves) { "$graves ponto(s) de atenção" } else { 'Nada importante para resolver' }
        $ui.lstAlertas.ItemsSource = $lista
        $ui.txtSemAlertas.Visibility = if ($lista.Count) { 'Collapsed' } else { 'Visible' }
        $ui.txtSemAlertas.Text = if ($script:Tarefas.Count) { 'Analisando…' } else { 'Nenhum ponto de atenção.' }
    }

    # ------------------------------------------------------------ Armazenamento
    $script:CachePastas = @{}
    $script:PastaAtual = $null

    function Show-Caches {
        $lista = @($script:Estado.Caches | Where-Object { $_ } | Sort-Object Bytes -Descending)
        $max = [math]::Max(1.0, ($lista | Measure-Object Bytes -Maximum).Maximum)
        $ui.lstCaches.ItemsSource = @(foreach ($c in $lista) {
            [pscustomobject]@{
                Nome = $c.Nome; Desc = $c.Desc; TamTxt = Format-Tam $c.Bytes; Pct = [math]::Max(1.0, $c.Bytes / $max * 100)
                Cor = if ($c.Bytes -ge 5GB) { $Cor.Warn } else { $Cor.Accent }
                Pode = [bool]$c.Modo -and $c.Bytes -gt 0 -and (-not $c.Admin -or $IsAdmin)
                VisAdmin = if ($c.Admin) { 'Visible' } else { 'Collapsed' }
                TagAbrir = "abrir|$($c.Caminho)"; TagLimpar = "limpar|$($c.Id)"
            }
        })
        $limpavel = ($lista | Where-Object Modo | Measure-Object Bytes -Sum).Sum
        $ui.txtCachesTotal.Text = "$(Format-Tam $limpavel) limpáveis"
        $ui.txtCachesStatus.Visibility = 'Collapsed'
    }

    function Open-Pasta($caminho) {
        $script:PastaAtual = $caminho
        $ui.txtCaminho.Text = $caminho
        $ui.btnVoltar.IsEnabled = [bool](Split-Path $caminho -Parent)
        $ui.btnAbrirPasta.IsEnabled = $true
        if ($script:CachePastas.ContainsKey($caminho)) { Show-Pastas $script:CachePastas[$caminho]; return }
        $ui.lstPastas.ItemsSource = $null
        $ui.txtPastasStatus.Text = 'Medindo… pastas grandes como C:\ podem levar alguns minutos.'
        Start-Tarefa { Get-ZPastas $Caminho $Fila } {
            param($r, $erro, $ctx)
            $script:CachePastas[$ctx] = @($r)
            if ($script:PastaAtual -eq $ctx) { Show-Pastas @($r) }
        } @{ Caminho = $caminho } $script:FilaPastas $caminho
    }

    function Show-Pastas($itens) {
        $itens = @($itens | Where-Object { $_ })
        $max = [math]::Max(1.0, ($itens | Measure-Object Bytes -Maximum).Maximum)
        $total = ($itens | Measure-Object Bytes -Sum).Sum
        $ui.lstPastas.ItemsSource = @(foreach ($p in $itens | Select-Object -First 60) {
            [pscustomobject]@{
                Nome = $p.Nome; TamTxt = Format-Tam $p.Bytes; Pct = $p.Bytes / $max * 100
                ModTxt = if ($p.Mod) { $p.Mod.ToString('dd/MM/yyyy') } else { '' }
                Icone = if ($p.Pasta) { [char]0xE8B7 } else { [char]0xE7C3 }
                Tag = if ($p.Pasta) { "pasta|$($p.Caminho)" } else { "abrir|$($p.Caminho)" }
            }
        })
        $ui.txtPastasStatus.Text = "Total: $(Format-Tam $total) em $(@($itens | Where-Object Pasta).Count) pasta(s)$(if ($itens.Count -gt 60) { ' · mostrando as 60 maiores' })"
    }

    $ui.btnVoltar.Add_Click({ $pai = Split-Path $script:PastaAtual -Parent; if ($pai) { Open-Pasta $pai } })
    $ui.btnAbrirPasta.Add_Click({ Start-Process explorer.exe "`"$script:PastaAtual`"" })

    # ------------------------------------------------------------ Segurança
    function Show-Seguranca {
        $s = $script:Estado.Seg
        function Card($titulo, $valor, $nivel, $icone) {
            [pscustomobject]@{ Titulo = $titulo; Valor = $valor; Cor = $Cor[$nivel]; Fundo = $Cor["Fundo$nivel"]; Icone = [char]$icone }
        }
        $dias = if ($s.Assinaturas) { ((Get-Date) - $s.Assinaturas).Days } else { $null }
        $fwOff = @($s.Firewall | Where-Object { -not $_.Ativo } | ForEach-Object Nome)
        $ui.lstSeg.ItemsSource = @(
            if ($s.Defender) {
                Card 'Proteção em tempo real' $(if ($s.TempoReal) { 'Ativa' } else { 'Desligada' }) $(if ($s.TempoReal) { 'Ok' } else { 'Bad' }) 0xEA18
                Card 'Assinaturas de vírus' $(if ($dias -eq 0) { 'Atualizadas hoje' } else { "Há $dias dia(s)" }) $(if ($dias -gt 3) { 'Warn' } else { 'Ok' }) 0xE895
                Card 'Varredura completa' $(if ($s.Completa) { $s.Completa.ToString('dd/MM/yyyy') } else { 'Nunca feita' }) $(if ($s.Completa) { 'Ok' } else { 'Warn' }) 0xE721
            } else { Card 'Microsoft Defender' 'Indisponível' 'Warn' 0xEA18 }
            Card 'Firewall' $(if ($fwOff.Count) { "Desligado: $($fwOff -join ', ')" } else { 'Ativo em todos os perfis' }) $(if ($fwOff.Count) { 'Bad' } else { 'Ok' }) 0xE774
            Card 'Controle de conta (UAC)' $(if ($s.Uac) { 'Ativo' } else { 'Desligado' }) $(if ($s.Uac) { 'Ok' } else { 'Bad' }) 0xE7EF
            Card 'Histórico de ameaças' $(if ($s.Ameacas.Count) { "$($s.Ameacas.Count) detectada(s)" } else { 'Vazio' }) $(if ($s.Ameacas.Count) { 'Bad' } else { 'Ok' }) 0xE7BA
        )
        $ui.txtVarredura.Text = "Última rápida: $(if ($s.Rapida) { $s.Rapida.ToString('dd/MM/yyyy HH:mm') } else { 'nunca' })  ·  Proteção contra adulteração: $(if ($s.Adulteracao) { 'ativa' } else { 'desligada' })"
        $ui.txtAnomalias.Text = if ($s.Anomalias.Count -or $s.Ameacas.Count) { (@($s.Anomalias) + @($s.Ameacas)) -join "`n" } else { '✔ Nada suspeito encontrado.' }
        $ui.txtAnomalias.Foreground = Pincel $(if ($s.Anomalias.Count -or $s.Ameacas.Count) { $Cor.Bad } else { $Cor.Ok })
        $ui.txtHosts.Text = if ($s.Hosts.Count) { $s.Hosts -join "`n" } else { '(vazio)' }
        $ui.txtSemAssinatura.Text = if ($s.SemAssinatura.Count) { $s.SemAssinatura -join "`n" } else { '(nenhum)' }
        $ui.txtSegStatus.Visibility = 'Collapsed'
    }

    $MpCmd = "$env:ProgramFiles\Windows Defender\MpCmdRun.exe"
    function Start-Defender($argumentos, $descricao) {
        $ui.txtVarredura.Text = "$descricao em andamento… (pode fechar esta página, avisamos quando terminar)"
        Start-Tarefa { & $MpCmd $Argumentos.Split(' ') 2>&1 | Out-String } {
            param($r, $erro, $ctx)
            if ($erro) { Avisar "$ctx falhou: $($erro.Message)" } else { Avisar "$ctx concluída.`n`n$($r -join '' | Select-Object -First 1)".Trim() }
            Start-Tarefa { Get-ZSeguranca } { param($r) $script:Estado.Seg = $r[0]; Show-Seguranca; Update-Alertas }
        } @{ MpCmd = $MpCmd; Argumentos = $argumentos } $null $descricao
    }
    $ui.btnScanRapido.Add_Click({ Start-Defender '-Scan -ScanType 1' 'Varredura rápida' })
    $ui.btnScanCompleto.Add_Click({ if (Confirmar 'A varredura completa pode levar horas e deixar o PC mais lento enquanto roda. Começar?') { Start-Defender '-Scan -ScanType 2' 'Varredura completa' } })
    $ui.btnAssinaturas.Add_Click({ Start-Defender '-SignatureUpdate' 'Atualização de assinaturas' })
    $ui.btnAbrirSeguranca.Add_Click({ Start-Process 'windowsdefender:' })

    # ------------------------------------------------------------ Inicialização e serviços
    function Show-Inicializacao {
        $script:ItensInicio = @($script:Estado.Inicio | Where-Object { $_ })
        $i = 0
        $ui.lstInicio.ItemsSource = @(foreach ($it in $script:ItensInicio) {
            $pode = -not $it.Admin -or $IsAdmin
            [pscustomobject]@{
                Nome = $it.Nome; Comando = $it.Comando; Origem = $it.Origem; Ativo = $it.Ativo; Assinante = $it.Assinante
                CorAss = if ($it.Assinante -match 'Sem assinatura|não encontrado') { $Cor.Bad } else { $Cor.Muted }
                Pode = $pode; Dica = if ($pode) { $null } else { 'Precisa de administrador' }; Tag = "inicio|$i"
            }
            $i++
        })
        $ativos = @($script:ItensInicio | Where-Object Ativo).Count
        $ui.txtInicioStatus.Text = "$ativos de $($script:ItensInicio.Count) ativos"
        $ui.lstServicos.ItemsSource = @(foreach ($s in @($script:Estado.Servicos | Where-Object { $_ })) {
            [pscustomobject]@{
                Exibicao = $s.Exibicao; Nome = $s.Nome; Auto = $s.Auto; Assinante = $s.Assinante
                Estado = if ($s.Rodando) { 'Rodando' } else { 'Parado' }; CorEstado = if ($s.Rodando) { $Cor.Ok } else { $Cor.Muted }
                Pode = $IsAdmin; Dica = if ($IsAdmin) { $null } else { 'Precisa de administrador' }; Tag = "servico|$($s.Nome)"
            }
        })
        if (-not $IsAdmin) { $ui.txtServicosSub.Text += '  Mudar serviços precisa de administrador.' }
    }

    # ------------------------------------------------------------ Debloat
    function Show-Tweaks {
        $ui.lstTweaks.ItemsSource = @(foreach ($t in Get-ZTweaks) {
            $pode = -not $t.Admin -or $IsAdmin
            [pscustomobject]@{ Nome = $t.Nome; Desc = $t.Desc; Ativo = $t.Ativo; Pode = $pode; Tag = "tweak|$($t.Id)"
                               VisAdmin = if ($t.Admin) { 'Visible' } else { 'Collapsed' }; Dica = if ($pode) { $null } else { 'Precisa de administrador' } }
        })
    }
    function Show-Apps {
        $apps = @($script:Estado.Apps | Where-Object { $_ })
        $ui.lstApps.ItemsSource = @(foreach ($a in $apps) { [pscustomobject]@{ Nome = $a.Nome; Pacote = $a.Pacote; Tag = "app|$($a.Pacote)" } })
        $ui.txtAppsStatus.Text = if ($apps.Count) { "$($apps.Count) encontrado(s)" } else { 'Nenhum app da lista está instalado.' }
    }
    function Start-Apps { Start-Tarefa { Get-ZAppsBloat } { param($r) $script:Estado.Apps = $r; Show-Apps } }

    # ------------------------------------------------------------ Atualizações
    function Show-Atualizacoes {
        $lista = @($script:Estado.Atu | Where-Object { $_ })
        $ui.lstAtu.ItemsSource = @(foreach ($a in $lista) { $a | Add-Member -NotePropertyName Tag -NotePropertyValue "atu|$($a.Id)" -Force -PassThru })
        $ui.btnAtualizar.IsEnabled = $ui.btnTodosAtu.IsEnabled = [bool]$lista.Count
    }
    function Start-Atualizacoes {
        $ui.txtAtuStatus.Text = 'Consultando o winget…'
        $ui.btnVerificarAtu.IsEnabled = $false
        Start-Tarefa { Get-ZAtualizacoes } {
            param($r, $erro)
            $ui.btnVerificarAtu.IsEnabled = $true
            if ($erro) { $ui.txtAtuStatus.Text = "Erro: $($erro.Message)"; return }
            $script:Estado.Atu = @($r | ForEach-Object { $_ | Add-Member -NotePropertyName Sel -NotePropertyValue $false -PassThru })
            $n = @($script:Estado.Atu).Count
            $ui.txtAtuStatus.Text = if ($n) { "$n app(s) com versão nova" } else { 'Tudo atualizado. ✔' }
            Show-Atualizacoes; Update-Alertas
        }
    }
    $ui.btnVerificarAtu.Add_Click({ Start-Atualizacoes })
    $ui.btnTodosAtu.Add_Click({
        $todos = -not (@($script:Estado.Atu | Where-Object { -not $_.Sel }).Count -eq 0)
        foreach ($a in $script:Estado.Atu) { $a.Sel = $todos }
        $ui.btnTodosAtu.Content = if ($todos) { 'Desmarcar todos' } else { 'Marcar todos' }
        Show-Atualizacoes
    })
    $ui.btnAtualizar.Add_Click({
        $ids = @($script:Estado.Atu | Where-Object Sel | ForEach-Object Id)
        if (-not $ids.Count) { Avisar 'Marque pelo menos um app.'; return }
        $ui.btnAtualizar.IsEnabled = $false
        $ui.txtAtuLog.Clear()
        Start-Tarefa {
            foreach ($id in $Ids) {
                $Fila.Enqueue("━━ $id")
                winget upgrade --id $id -e --silent --accept-source-agreements --accept-package-agreements --disable-interactivity 2>&1 | ForEach-Object {
                    $l = ("$_" -split "`r")[-1].Trim()
                    if ($l -and $l -notmatch '^[\-\\|/\s█▒░]+$' -and $l -notmatch '^[\d.,]+ [KMG]B / ') { $Fila.Enqueue("   $l") }
                }
                $ok = $LASTEXITCODE -eq 0
                $Fila.Enqueue($(if ($ok) { '   ✔ concluído' } else { "   ✖ falhou (código $LASTEXITCODE)" }))
                [pscustomobject]@{ Id = $id; Ok = $ok }
            }
        } {
            param($r)
            $ok = @($r | Where-Object Ok | ForEach-Object Id); $falha = @($r | Where-Object { -not $_.Ok } | ForEach-Object Id)
            Add-ZRegistro "Atualizados pelo winget: $($ok -join ', ')$(if ($falha.Count) { " · falharam: $($falha -join ', ')" })" @()
            Show-Registro
            Start-Atualizacoes
        } @{ Ids = $ids } $script:FilaLog
    })

    # ------------------------------------------------------------ Bateria
    function Show-Bateria {
        $b = $script:Estado.Bateria
        if (-not $b) { $ui.txtBatSem.Text = 'Nenhuma bateria encontrada'; $ui.pnlBatSem.Visibility = 'Visible'; $ui.pnlBat.Visibility = 'Collapsed'; return }
        $ui.pnlBatSem.Visibility = 'Collapsed'; $ui.pnlBat.Visibility = 'Visible'
        $ui.txtBatSaude.Text = "$($b.SaudePct)%"
        $ui.barBatSaude.Value = $b.SaudePct
        $ui.barBatSaude.Foreground = Pincel $(if ($b.SaudePct -ge 80) { $Cor.Ok } elseif ($b.SaudePct -ge 60) { $Cor.Warn } else { $Cor.Bad })
        $ui.txtBatCap.Text = "$($b.AtualWh) Wh"
        $ui.txtBatCapSub.Text = "de $($b.ProjetadaWh) Wh de fábrica"
        $ui.txtBatCiclos.Text = if ($b.Ciclos) { "$($b.Ciclos)" } else { '—' }
        $ui.txtBatCarga.Text = "$($b.CargaPct)%"
        $ui.txtBatCargaSub.Text = if ($b.NaTomada) { 'Na tomada' } elseif ($b.AutonomiaMin) { 'Cerca de {0} h {1} min restantes' -f [math]::Floor($b.AutonomiaMin / 60), ($b.AutonomiaMin % 60) } else { 'Na bateria' }
        $ui.txtBatInfo.Text = "$($b.Nome) · $($b.Quimica)"
    }
    $ui.btnBatRelatorio.Add_Click({
        $html = Join-Path $env:TEMP 'zelador-bateria.html'
        powercfg /batteryreport /output $html | Out-Null
        Start-Process $html
    })

    # ------------------------------------------------------------ Registro de ações
    function Show-Registro {
        $lista = @(Read-ZRegistro)
        $ui.lstRegistro.ItemsSource = @(foreach ($e in $lista) {
            $temDesfazer = @($e.Desfazer).Count -gt 0
            [pscustomobject]@{
                Data = $e.Data; Texto = "$($e.Descricao)$(if ($e.Desfeito) { '  (desfeito)' })"; Tag = "desfazer|$($e.Id)"
                Pode = $temDesfazer -and -not $e.Desfeito; VisDesfazer = if ($temDesfazer) { 'Visible' } else { 'Collapsed' }
                Opacidade = if ($e.Desfeito) { 0.5 } else { 1 }
            }
        })
        $ui.txtRegistroVazio.Visibility = if ($lista.Count) { 'Collapsed' } else { 'Visible' }
    }
    $ui.btnPastaDados.Add_Click({ $d = Split-Path $ZArquivoRegistro; New-Item -ItemType Directory -Force $d | Out-Null; Start-Process explorer.exe "`"$d`"" })

    # ------------------------------------------------------------ Botões dentro das listas
    # Todo botão de lista tem Tag "acao|argumento"; um único handler na janela trata todos.
    function Invoke-AcaoLista($acao, $arg, $botao) {
        switch ($acao) {
            'pagina' { Show-Pagina $arg }
            'abrir' {
                if (Test-Path -LiteralPath $arg -PathType Leaf) { Start-Process explorer.exe "/select,`"$arg`"" } else { Start-Process explorer.exe "`"$arg`"" }
            }
            'pasta' { Open-Pasta $arg }
            'limpar' {
                $c = $script:Estado.Caches | Where-Object Id -eq $arg
                if (-not (Confirmar "Limpar $($c.Nome) ($(Format-Tam $c.Bytes))?`n`nIsso não dá para desfazer.")) { return }
                $botao.IsEnabled = $false
                Start-Tarefa { Clear-ZCache $Id } {
                    param($r, $erro)
                    if ($erro) { Avisar "Falhou: $($erro.Message)"; return }
                    Add-ZRegistro "Limpeza: $($r[0].Nome) ($(Format-Tam $r[0].Liberado) liberados)" @()
                    Show-Registro
                    $ui.txtCachesTotal.Text = "$(Format-Tam $r[0].Liberado) liberados agora"
                    Start-Tarefa { @(Get-ZCaches) } { param($r) $script:Estado.Caches = $r; Show-Caches; Update-Alertas }
                    Start-Tarefa { @(Get-ZDiscos) } { param($r) $script:Estado.Discos = $r; Show-Discos; Update-Alertas }
                } @{ Id = $arg }
            }
            'inicio' {
                $item = $script:ItensInicio[[int]$arg]
                try { Set-ZInicio $item ([bool]$botao.IsChecked); $item.Ativo = [bool]$botao.IsChecked }
                catch { $botao.IsChecked = -not $botao.IsChecked; throw }
                Show-Registro
            }
            'servico' {
                try { Set-ZServicoAuto $arg ([bool]$botao.IsChecked) } catch { $botao.IsChecked = -not $botao.IsChecked; throw }
                Show-Registro
            }
            'tweak' {
                try { Set-ZTweak $arg ([bool]$botao.IsChecked) } catch { $botao.IsChecked = -not $botao.IsChecked; throw }
                Show-Tweaks; Show-Registro; Update-Alertas
            }
            'app' {
                $nome = $ZBloat[$arg]
                if (-not (Confirmar "Remover $nome?`n`nDá para reinstalar depois pela Microsoft Store.")) { return }
                $botao.IsEnabled = $false
                Start-Tarefa { Get-AppxPackage $Pacote | Remove-AppxPackage } {
                    param($r, $erro, $ctx)
                    if ($erro) { Avisar "Não deu para remover: $($erro.Message)" } else { Add-ZRegistro "App removido: $ctx" @(); Show-Registro }
                    Start-Apps
                } @{ Pacote = $arg } $null $nome
            }
            'atu' { ($script:Estado.Atu | Where-Object Id -eq $arg).Sel = [bool]$botao.IsChecked }
            'desfazer' {
                Undo-ZRegistro $arg
                Show-Registro; Show-Tweaks; Update-Alertas
                Start-Tarefa { @(Get-ZInicializacao) } { param($r) $script:Estado.Inicio = $r; Show-Inicializacao }
            }
        }
    }
    $janela.AddHandler([Windows.Controls.Primitives.ButtonBase]::ClickEvent, [Windows.RoutedEventHandler]{
        param($s, $e)
        if ("$($e.OriginalSource.Tag)" -match '^(\w+)\|(.*)$') { Invoke-AcaoLista $Matches[1] $Matches[2] $e.OriginalSource }
    })

    # ------------------------------------------------------------ Análise completa
    function Start-Analise {
        $ui.btnAnalisar.IsEnabled = $false
        $script:Estado = @{}
        $script:CachePastas = @{}
        Start-Tarefa { [pscustomobject]@{ Sistema = Get-ZSistema; Discos = @(Get-ZDiscos) } } {
            param($r)
            $script:Estado.Sistema = $r[0].Sistema; $script:Estado.Discos = @($r[0].Discos)
            Show-Sistema; Show-Discos; Update-Alertas
        }
        Start-Tarefa { Get-ZSeguranca } { param($r) $script:Estado.Seg = $r[0]; Show-Seguranca; Update-Alertas }
        Start-Tarefa { [pscustomobject]@{ Inicio = @(Get-ZInicializacao); Servicos = @(Get-ZServicos) } } {
            param($r)
            $script:Estado.Inicio = $r[0].Inicio; $script:Estado.Servicos = $r[0].Servicos
            Show-Inicializacao; Update-Alertas
        }
        Start-Tarefa { Get-ZCaches } { param($r) $script:Estado.Caches = $r; Show-Caches; Update-Alertas }
        Start-Tarefa { Get-ZBateria } { param($r) $script:Estado.Bateria = $r[0]; Show-Bateria; Update-Alertas }
        Start-Apps
        Start-Atualizacoes
        Show-Tweaks
        Show-Registro
    }
    $ui.btnAnalisar.Add_Click({ Start-Analise })

    # ------------------------------------------------------------ Admin
    $ui.txtMaquina.Text = $env:COMPUTERNAME
    if ($IsAdmin) {
        $ui.txtAdmin.Text = 'Administrador'; $ui.icoAdmin.Foreground = Pincel $Cor.Ok
        $ui.txtAdminSub.Text = 'Todas as ações liberadas.'; $ui.btnAdmin.Visibility = 'Collapsed'
    } else {
        $ui.txtAdmin.Text = 'Usuário comum'; $ui.icoAdmin.Foreground = Pincel $Cor.Warn
        $ui.txtAdminSub.Text = 'Algumas ações (serviços, ajustes do sistema) precisam de admin.'
    }
    $ui.btnAdmin.Add_Click({
        try { Start-Process powershell -Verb RunAs -ArgumentList "-STA -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`"" } catch { return }
        $janela.Close()
    })

    $janela.Add_Closed({ $timerVivo.Stop(); $timerTarefas.Stop() })
    Show-Pagina 'Painel'
    Start-Analise
    [void]$janela.ShowDialog()
}
catch {
    [Windows.MessageBox]::Show("O Zelador não conseguiu abrir:`n`n$($_.Exception.Message)`n`n$($_.InvocationInfo.PositionMessage)", 'Zelador', 'OK', 'Error') | Out-Null
}
