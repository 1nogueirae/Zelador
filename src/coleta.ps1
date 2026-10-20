# Coleta de dados (somente leitura).
# Carregado pela janela e também pelos runspaces que fazem o trabalho pesado em segundo plano.

if (-not ('Zelador.Nativo' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;

namespace Zelador {
    public static class Nativo {
        // Soma o tamanho de uma pasta sem seguir junções/links e ignorando o que não dá para ler.
        public static long TamanhoPasta(string caminho) {
            long total = 0;
            var pilha = new Stack<string>();
            pilha.Push(caminho);
            while (pilha.Count > 0) {
                string atual = pilha.Pop();
                try {
                    foreach (var f in new DirectoryInfo(atual).EnumerateFileSystemInfos()) {
                        try {
                            if ((f.Attributes & FileAttributes.ReparsePoint) != 0) continue;
                            if ((f.Attributes & FileAttributes.Directory) != 0) pilha.Push(f.FullName);
                            else total += ((FileInfo)f).Length;
                        } catch { }
                    }
                } catch { }
            }
            return total;
        }

        [StructLayout(LayoutKind.Sequential)]
        struct FT { public uint Lo; public uint Hi; public ulong V { get { return ((ulong)Hi << 32) | Lo; } } }

        [DllImport("kernel32.dll")]
        static extern bool GetSystemTimes(out FT idle, out FT kernel, out FT user);

        static ulong ultimoOcioso, ultimoTotal;

        // Uso de CPU desde a chamada anterior, em %.
        public static double Cpu() {
            FT i, k, u;
            if (!GetSystemTimes(out i, out k, out u)) return 0;
            ulong ocioso = i.V, total = k.V + u.V;
            ulong dOcioso = ocioso - ultimoOcioso, dTotal = total - ultimoTotal;
            ultimoOcioso = ocioso; ultimoTotal = total;
            return dTotal == 0 ? 0 : Math.Round((1.0 - (double)dOcioso / dTotal) * 100, 1);
        }

        [StructLayout(LayoutKind.Sequential)]
        class MEM {
            public uint dwLength = 64; public uint dwMemoryLoad;
            public ulong ullTotalPhys, ullAvailPhys, ullTotalPageFile, ullAvailPageFile, ullTotalVirtual, ullAvailVirtual, ullAvailExtendedVirtual;
        }

        [DllImport("kernel32.dll")]
        static extern bool GlobalMemoryStatusEx([In, Out] MEM m);

        // [uso %, total GB, usado GB]
        public static double[] Ram() {
            var m = new MEM();
            GlobalMemoryStatusEx(m);
            return new double[] { m.dwMemoryLoad, m.ullTotalPhys / 1073741824.0, (m.ullTotalPhys - m.ullAvailPhys) / 1073741824.0 };
        }
    }
}
'@
}

function Test-ZAdmin { ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }

function Get-ZReg($Chave, $Nome) { (Get-ItemProperty -LiteralPath $Chave -Name $Nome -ErrorAction SilentlyContinue).$Nome }

# Caminho do .exe numa linha de comando: "C:\a b\x.exe" -arg  ou  C:\x.exe -arg
function Get-ZExe($Cmd) {
    if ($Cmd -match '^\s*"([^"]+)"') { return $Matches[1] }
    if ($Cmd -match '^\s*(.+?\.exe)') { return $Matches[1] }
    $Cmd
}

function Get-ZAssinante($Exe) {
    $Exe = [Environment]::ExpandEnvironmentVariables("$Exe")
    if (-not $Exe -or -not (Test-Path -LiteralPath $Exe)) { return 'Arquivo não encontrado' }
    $s = Get-AuthenticodeSignature -LiteralPath $Exe -ErrorAction SilentlyContinue
    if ($s.Status -ne 'Valid') { return 'Sem assinatura' }
    $s.SignerCertificate.Subject -replace '^CN="?([^,"]+)"?.*', '$1'
}

function Get-ZSistema {
    $os = Get-CimInstance Win32_OperatingSystem
    $cs = Get-CimInstance Win32_ComputerSystem
    $bb = Get-CimInstance Win32_BaseBoard
    $ver = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    [pscustomobject]@{
        Windows   = "$($os.Caption -replace '^Microsoft ', '') $($ver.DisplayVersion) (build $($os.BuildNumber))"
        Instalado = $os.InstallDate
        Boot      = $os.LastBootUpTime
        Cpu       = (Get-CimInstance Win32_Processor | Select-Object -First 1).Name.Trim()
        Gpu       = (Get-CimInstance Win32_VideoController | ForEach-Object Name) -join ', '
        RamGB     = [math]::Round($cs.TotalPhysicalMemory / 1GB)
        PlacaMae  = "$($bb.Manufacturer) $($bb.Product)".Trim()
        Modelo    = "$($cs.Manufacturer) $($cs.Model)".Trim()
    }
}

function Get-ZDiscos {
    $fisicos = @{}
    foreach ($p in Get-PhysicalDisk) { $fisicos["$($p.DeviceId)"] = $p }
    foreach ($v in Get-Volume | Where-Object { $_.DriveLetter -and $_.DriveType -eq 'Fixed' -and $_.Size -gt 0 } | Sort-Object DriveLetter) {
        $num = (Get-Partition -DriveLetter $v.DriveLetter -ErrorAction SilentlyContinue | Select-Object -First 1).DiskNumber
        $p = $fisicos["$num"]
        [pscustomobject]@{
            Letra   = "$($v.DriveLetter)"
            Rotulo  = $v.FileSystemLabel
            TotalGB = [math]::Round($v.Size / 1GB)
            LivreGB = [math]::Round($v.SizeRemaining / 1GB, 1)
            UsoPct  = [math]::Round(($v.Size - $v.SizeRemaining) / $v.Size * 100)
            Modelo  = if ($p) { "$($p.FriendlyName) · $($p.MediaType) $($p.BusType)" } else { '' }
            Saudavel = (-not $p) -or "$($p.HealthStatus)" -eq 'Healthy'
        }
    }
}

# Caches e sobras conhecidos. Modo: como limpar ('Conteudo', 'Npm', 'Lixeira') ou $null se for só informativo.
function Get-ZDefCaches {
    $L = $env:LOCALAPPDATA; $U = $env:USERPROFILE
    function D($Id, $Nome, $Caminho, $Modo, $Admin, $Desc) { [pscustomobject]@{ Id = $Id; Nome = $Nome; Caminho = $Caminho; Modo = $Modo; Admin = $Admin; Desc = $Desc } }
    D 'lixeira'   'Lixeira'                      'C:\$Recycle.Bin'                        'Lixeira'  $false 'Arquivos apagados que ainda ocupam espaço.'
    D 'temp'      'Temporários do usuário'       $env:TEMP                                'Conteudo' $false 'Arquivos temporários de programas. O que estiver em uso fica.'
    D 'wintemp'   'Temporários do Windows'       "$env:windir\Temp"                       'Conteudo' $true  'Temporários do sistema.'
    D 'wu'        'Downloads do Windows Update'  "$env:windir\SoftwareDistribution\Download" 'Conteudo' $true 'Instaladores de atualizações já aplicadas.'
    D 'npm'       'Cache do npm'                 "$L\npm-cache"                           'Npm'      $false 'Baixado de novo quando necessário.'
    D 'pip'       'Cache do pip'                 "$L\pip\cache"                           'Conteudo' $false 'Baixado de novo quando necessário.'
    D 'yarn'      'Cache do Yarn'                "$L\Yarn\Cache"                          'Conteudo' $false 'Baixado de novo quando necessário.'
    D 'gradle'    'Cache do Gradle'              "$U\.gradle\caches"                      'Conteudo' $false 'Baixado de novo quando necessário.'
    D 'nuget'     'Pacotes NuGet'                "$U\.nuget\packages"                     'Conteudo' $false 'Baixado de novo quando necessário.'
    D 'dx'        'Shaders da NVIDIA'            "$L\NVIDIA\DXCache"                      'Conteudo' $false 'Se recria sozinho; o 1º jogo depois pode carregar um pouco mais devagar.'
    D 'd3d'       'Shaders do DirectX'           "$L\D3DSCache"                           'Conteudo' $false 'Se recria sozinho.'
    D 'dumps'     'Dumps de travamento'          "$L\CrashDumps"                          'Conteudo' $false 'Arquivos gerados quando programas travam.'
    D 'drive'     'Cache do Google Drive'        "$L\Google\DriveFS"                      $null      $false 'Ocupa espaço de verdade. Limpe pelo app: Drive > Preferências > Arquivos off-line.'
    D 'docker'    'Discos do Docker'             "$L\Docker\wsl"                          $null      $false 'Rode "docker system prune" e compacte o disco virtual.'
    D 'android'   'Android SDK'                  "$L\Android\Sdk"                         $null      $false 'Gerencie pelo Android Studio.'
    D 'avd'       'Emuladores Android'           "$U\.android\avd"                        $null      $false 'Gerencie pelo Android Studio.'
    D 'downloads' 'Downloads'                    "$U\Downloads"                           $null      $false 'Sua pasta de downloads.'
}

function Get-ZCaches {
    foreach ($c in Get-ZDefCaches) {
        if (-not (Test-Path -LiteralPath $c.Caminho)) { continue }
        $c | Add-Member -NotePropertyName Bytes -NotePropertyValue ([Zelador.Nativo]::TamanhoPasta($c.Caminho)) -PassThru
    }
}

function Get-ZPastas($Raiz, $Fila) {
    $itens = foreach ($d in Get-ChildItem -LiteralPath $Raiz -Directory -Force -ErrorAction SilentlyContinue) {
        if ($d.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
        if ($Fila) { $Fila.Enqueue($d.FullName) }
        [pscustomobject]@{ Nome = $d.Name; Caminho = $d.FullName; Bytes = [Zelador.Nativo]::TamanhoPasta($d.FullName); Mod = $d.LastWriteTime; Pasta = $true }
    }
    $soltos = (Get-ChildItem -LiteralPath $Raiz -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
    if ($soltos) { $itens = @($itens) + [pscustomobject]@{ Nome = '(arquivos soltos nesta pasta)'; Caminho = $Raiz; Bytes = [long]$soltos; Mod = $null; Pasta = $false } }
    @($itens) | Sort-Object Bytes -Descending
}

function Get-ZSeguranca {
    $mp = Get-MpComputerStatus -ErrorAction SilentlyContinue
    $fw = @(Get-NetFirewallProfile -ErrorAction SilentlyContinue | ForEach-Object { [pscustomobject]@{ Nome = "$($_.Name)"; Ativo = "$($_.Enabled)" -eq 'True' } })
    $px = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue

    $anomalias = New-Object System.Collections.ArrayList
    $w = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    if ($w.Shell -ne 'explorer.exe') { [void]$anomalias.Add("Winlogon Shell alterado: $($w.Shell)") }
    if ($w.Userinit -notmatch '^C:\\Windows\\system32\\userinit\.exe,?$') { [void]$anomalias.Add("Winlogon Userinit alterado: $($w.Userinit)") }
    Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options' -ErrorAction SilentlyContinue | ForEach-Object {
        $d = (Get-ItemProperty $_.PSPath).Debugger
        if ($d) { [void]$anomalias.Add("Programa interceptado (IFEO): $($_.PSChildName) => $d") }
    }
    Get-Process | Where-Object { $_.Path -match '\\AppData\\Local\\Temp\\|\\Users\\Public\\' } | ForEach-Object { [void]$anomalias.Add("Processo rodando de local incomum: $($_.Path)") }
    if ($px.ProxyEnable -eq 1 -or $px.AutoConfigURL) { [void]$anomalias.Add("Proxy configurado: $($px.ProxyServer)$($px.AutoConfigURL)") }

    [pscustomobject]@{
        Defender    = [bool]$mp
        TempoReal   = [bool]$mp.RealTimeProtectionEnabled
        Adulteracao = [bool]$mp.IsTamperProtected
        Assinaturas = $mp.AntivirusSignatureLastUpdated
        Rapida      = $mp.QuickScanEndTime
        Completa    = $mp.FullScanEndTime
        Ameacas     = @(Get-MpThreatDetection -ErrorAction SilentlyContinue | ForEach-Object { "$($_.InitialDetectionTime): $($_.Resources -join '; ')" })
        Firewall    = $fw
        Uac         = (Get-ZReg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' EnableLUA) -ne 0
        Hosts       = @(Get-Content "$env:windir\System32\drivers\etc\hosts" -ErrorAction SilentlyContinue | Where-Object { $_ -notmatch '^\s*#' -and $_.Trim() } | ForEach-Object { $_.Trim() })
        Anomalias   = @($anomalias)
        SemAssinatura = @(Get-Process | Where-Object Path | Select-Object -ExpandProperty Path -Unique | Where-Object { (Get-AuthenticodeSignature -LiteralPath $_).Status -ne 'Valid' })
    }
}

function Get-ZInicializacao {
    $apr = 'Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved'
    function Item($Nome, $Comando, $Exe, $Origem, $Aprov, $Admin) {
        $b = Get-ZReg $Aprov $Nome
        [pscustomobject]@{ Nome = $Nome; Comando = $Comando; Origem = $Origem; Aprov = $Aprov; Admin = $Admin
                           Ativo = -not ($b -and ($b[0] % 2)); Assinante = Get-ZAssinante $Exe }
    }
    $fontes = @(
        @('Registro do usuário', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run', "HKCU:\$apr\Run", $false),
        @('Registro da máquina', 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run', "HKLM:\$apr\Run", $true),
        @('Registro (32 bits)', 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run', "HKLM:\$apr\Run32", $true)
    )
    foreach ($f in $fontes) {
        $itens = Get-ItemProperty -LiteralPath $f[1] -ErrorAction SilentlyContinue
        if (-not $itens) { continue }
        foreach ($p in $itens.PSObject.Properties | Where-Object Name -notlike 'PS*') { Item $p.Name "$($p.Value)" (Get-ZExe "$($p.Value)") $f[0] $f[2] $f[3] }
    }
    $atalhos = New-Object -ComObject WScript.Shell
    $pastas = @(
        @('Pasta Inicializar', "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup", "HKCU:\$apr\StartupFolder", $false),
        @('Pasta Inicializar (todos)', "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\Startup", "HKLM:\$apr\StartupFolder", $true)
    )
    foreach ($f in $pastas) {
        foreach ($a in Get-ChildItem -LiteralPath $f[1] -File -Force -ErrorAction SilentlyContinue | Where-Object Name -ne 'desktop.ini') {
            $alvo = if ($a.Extension -eq '.lnk') { $atalhos.CreateShortcut($a.FullName).TargetPath } else { $a.FullName }
            Item $a.Name $alvo $alvo $f[0] $f[2] $f[3]
        }
    }
}

function Get-ZServicos {
    Get-CimInstance Win32_Service | Where-Object { $_.PathName -and $_.PathName -notmatch '\\Windows\\(System32|SysWOW64)\\svchost' -and $_.StartMode -in 'Auto', 'Manual' } | ForEach-Object {
        $sig = Get-ZAssinante (Get-ZExe $_.PathName)
        if ($sig -match 'Microsoft') { return }
        [pscustomobject]@{ Nome = $_.Name; Exibicao = $_.DisplayName; Rodando = $_.State -eq 'Running'; Auto = $_.StartMode -eq 'Auto'; Assinante = $sig }
    } | Sort-Object @{ e = { -not $_.Auto } }, Exibicao
}

# Lê a tabela do "winget upgrade". As colunas têm largura fixa, definida pela posição dos títulos.
function Get-ZAtualizacoes {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) { throw 'winget não encontrado. Instale o "Instalador de Aplicativo" pela Microsoft Store.' }
    $linhas = @(winget upgrade --accept-source-agreements --include-unknown --disable-interactivity 2>$null | ForEach-Object { ("$_" -split "`r")[-1] })
    $i = 0
    while ($i -lt $linhas.Count -and $linhas[$i] -notmatch '(Name|Nome)\s+ID\s') { $i++ }
    if ($i -ge $linhas.Count) { return }
    $cols = @([regex]::Matches($linhas[$i], '\S+') | ForEach-Object Index)
    for ($j = $i + 1; $j -lt $linhas.Count; $j++) {
        $l = $linhas[$j]
        if ($l -match '^-+$' -or -not $l.Trim()) { continue }
        if ($l -match '^\d+ \S.*\.\s*$' -or $l.Length -le $cols[2]) { break }
        $campo = {
            param($k)
            $ini = $cols[$k]; $fim = if ($k + 1 -lt $cols.Count) { [math]::Min($cols[$k + 1], $l.Length) } else { $l.Length }
            if ($ini -ge $l.Length) { '' } else { $l.Substring($ini, $fim - $ini).Trim() }
        }
        [pscustomobject]@{ Nome = (& $campo 0); Id = (& $campo 1); Versao = (& $campo 2); Disponivel = (& $campo 3) }
    }
}

function Get-ZBateria {
    $b = Get-CimInstance Win32_Battery | Select-Object -First 1
    if (-not $b) { return }
    $xml = Join-Path $env:TEMP 'zelador-bateria.xml'
    powercfg /batteryreport /xml /output $xml | Out-Null
    $bat = @(([xml](Get-Content $xml -Raw)).BatteryReport.Batteries.Battery)[0]
    $proj = [double]$bat.DesignCapacity; $atual = [double]$bat.FullChargeCapacity
    [pscustomobject]@{
        Nome        = "$($bat.Manufacturer) $($bat.Id)".Trim()
        Quimica     = $bat.Chemistry
        ProjetadaWh = [math]::Round($proj / 1000, 1)
        AtualWh     = [math]::Round($atual / 1000, 1)
        SaudePct    = if ($proj) { [math]::Min(100, [math]::Round($atual / $proj * 100)) } else { $null }
        Ciclos      = $bat.CycleCount
        CargaPct    = $b.EstimatedChargeRemaining
        NaTomada    = $b.BatteryStatus -eq 2
        AutonomiaMin = if ($b.EstimatedRunTime -and $b.EstimatedRunTime -lt 71582788) { $b.EstimatedRunTime } else { $null }
    }
}

# Apps pré-instalados que costumam sair no debloat. Os do Xbox ficam de fora de propósito (Minecraft, Game Pass).
$ZBloat = [ordered]@{
    'Microsoft.BingNews' = 'Notícias'; 'Microsoft.BingWeather' = 'Clima'; 'Microsoft.BingSearch' = 'Bing Search'
    'Microsoft.GetHelp' = 'Obter Ajuda'; 'Microsoft.Getstarted' = 'Dicas'; 'Microsoft.YourPhone' = 'Vincular ao Celular'
    'Microsoft.MicrosoftSolitaireCollection' = 'Paciência'; 'Clipchamp.Clipchamp' = 'Clipchamp'; 'Microsoft.PowerAutomateDesktop' = 'Power Automate'
    'Microsoft.Todos' = 'Microsoft To Do'; 'Microsoft.People' = 'Pessoas'; 'Microsoft.WindowsFeedbackHub' = 'Hub de Comentários'
    'MSTeams' = 'Microsoft Teams'; 'Microsoft.OutlookForWindows' = 'Outlook (novo)'; 'Microsoft.MicrosoftOfficeHub' = 'Microsoft 365'
    'Microsoft.Copilot' = 'Copilot'; 'Microsoft.ZuneVideo' = 'Filmes e TV'; 'Microsoft.WindowsMaps' = 'Mapas'; 'Microsoft.549981C3F5F10' = 'Cortana'
}

function Get-ZAppsBloat {
    $instalados = @(Get-AppxPackage | ForEach-Object Name)
    foreach ($k in $ZBloat.Keys) { if ($instalados -contains $k) { [pscustomobject]@{ Pacote = $k; Nome = $ZBloat[$k] } } }
}
