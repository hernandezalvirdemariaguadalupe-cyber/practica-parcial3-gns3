<#
  Verificacion automatica - Practica del Parcial 3 (GNS3 + 4 bases de datos)

  Que hace:
    Se conecta al GNS3 que tienes abierto, busca el proyecto "Practica_Parcial3"
    y corre todas las pruebas de la topologia y de las bases de datos.
    Al final muestra un resumen PASA / FALLA y guarda:
      - resultados\*.txt   la salida completa de cada prueba
      - capturas\*.png     una "captura" de cada prueba y una imagen de la topologia

  Como se usa (PowerShell, en la carpeta de este archivo):
      1. Abre GNS3, abre el proyecto Practica_Parcial3 y presiona Start (play verde).
      2. Espera unos 3 minutos a que arranquen los routers y Windows.
      3. Ejecuta:
           powershell -ExecutionPolicy Bypass -File .\verificar.ps1
         Opcional:  -SinReplicacion   (no toca los registros de las bases)
#>
param(
  [string]$Proyecto = 'Practica_Parcial3',
  [switch]$SinReplicacion
)
$ErrorActionPreference = 'Stop'
$Aqui = Split-Path -Parent $MyInvocation.MyCommand.Path
$DirRes = Join-Path $Aqui 'resultados'; $DirCap = Join-Path $Aqui 'capturas'
New-Item -ItemType Directory -Force $DirRes, $DirCap | Out-Null
Add-Type -AssemblyName System.Drawing

# ------------------------------------------------------------ conexion a GNS3
$ini = Join-Path $env:APPDATA 'GNS3\2.2\gns3_server.ini'
$Puerto = 3080; $Hdr = @{}
if (Test-Path $ini) {
  $txt = Get-Content $ini
  $m = $txt | Select-String '^port\s*=\s*(\d+)'; if ($m) { $Puerto = [int]$m.Matches[0].Groups[1].Value }
  $auth = $txt | Select-String '^auth\s*=\s*True'
  if ($auth) {
    $uu = (($txt | Select-String '^user\s*=') -split '=', 2)[1].Trim()
    $pp = (($txt | Select-String '^password\s*=') -split '=', 2)[1].Trim()
    $Hdr = @{ Authorization = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${uu}:${pp}")) }
  }
}
$Base = "http://127.0.0.1:$Puerto/v2"
function Api($ruta) { Invoke-RestMethod -Uri "$Base$ruta" -Headers $Hdr -TimeoutSec 30 }

try { $proys = Api '/projects' } catch { Write-Host "No pude conectarme a GNS3 en el puerto $Puerto. Abre GNS3 primero." -ForegroundColor Red; exit 1 }
$PR = $null; foreach ($x in $proys) { if ($x.name -eq $Proyecto) { $PR = $x } }
if (-not $PR) { Write-Host "No encontre el proyecto '$Proyecto'. Importalo y abrelo en GNS3." -ForegroundColor Red; exit 1 }
if ($PR.status -ne 'opened') { Write-Host "El proyecto '$Proyecto' esta cerrado. Abrelo en GNS3 y presiona Start." -ForegroundColor Red; exit 1 }
$PID_ = $PR.project_id
$NODOS = @{}; $todos = Api "/projects/$PID_/nodes"; foreach ($x in $todos) { $NODOS[$x.name] = $x }

# ---------------------------------------------------------- consola (telnet)
function Limpiar([string]$s) {
  $s = $s -replace '\x1b\[[\?0-9;]*[a-zA-Z]', '' -replace '\x1b\][^\x07]*\x07', ''
  $s = $s -replace "`r", '' -replace '[^\x09\x0A\x20-\x7E\xA0-\xFF]', ''
  return $s
}
function Consola([string]$nodo, [string[]]$comandos, [string]$fin, [int]$timeout = 30) {
  # Envia comandos a la consola telnet del nodo y lee hasta ver $fin (regex) o hasta $timeout s.
  $n = $NODOS[$nodo]
  $hostC = $n.console_host; if ($hostC -in @('0.0.0.0', '::', '', $null)) { $hostC = '127.0.0.1' }
  $c = New-Object Net.Sockets.TcpClient($hostC, [int]$n.console)
  $st = $c.GetStream(); $buf = New-Object byte[] 65536
  $leer = { param($seg, $patron)
    $o = ''; $limite = (Get-Date).AddSeconds($seg)
    while ((Get-Date) -lt $limite) {
      if ($st.DataAvailable) {
        $r = $st.Read($buf, 0, $buf.Length)
        $o += [Text.Encoding]::GetEncoding(28591).GetString(($buf[0..($r - 1)] | Where-Object { $_ -lt 240 }))
        if ($patron -and ((Limpiar $o) -match $patron)) { Start-Sleep -Milliseconds 300; break }
      } else { Start-Sleep -Milliseconds 150 }
    }
    $o }
  $null = & $leer 1 $null
  $b = [Text.Encoding]::ASCII.GetBytes("`r"); $st.Write($b, 0, $b.Length); $null = & $leer 2 $null
  $salida = ''
  for ($i = 0; $i -lt $comandos.Count; $i++) {
    $b = [Text.Encoding]::ASCII.GetBytes($comandos[$i] + "`r"); $st.Write($b, 0, $b.Length)
    $ultimo = ($i -eq $comandos.Count - 1)
    $salida += & $leer $(if ($ultimo) { $timeout } else { 3 }) $(if ($ultimo) { $fin } else { $null })
  }
  $c.Close()
  return (Limpiar $salida)
}
function Ios([string]$router, [string[]]$comandos, [int]$timeout = 20) {
  $hn = $router
  return Consola $router (@('terminal length 0') + $comandos + @('')) "(?m)^$([regex]::Escape($hn))[>#]\s*$" $timeout
}
function Bash([string]$nodo, [string]$comando, [int]$timeout = 60) {
  # El eco del comando muestra __FI""N__ y la salida real muestra __FIN__: asi no se confunden.
  return Consola $nodo @("$comando; echo __FI`"`"N__") '(?m)^__FIN__\s*$' $timeout
}

# --------------------------------------------------------------- capturas PNG
function Captura([string]$archivo, [string]$titulo, [string]$texto) {
  $lineas = ($texto -replace "`t", '    ') -split "`n" | Where-Object { $_ -notmatch '^__FIN__$' }
  if ($lineas.Count -gt 70) { $lineas = $lineas[0..69] + @('...') }
  $fuente = New-Object Drawing.Font('Consolas', 11); $fTit = New-Object Drawing.Font('Segoe UI', 11, [Drawing.FontStyle]::Bold)
  $anchoCar = 8.4; $altoLin = 18
  $maxLen = ($lineas | Measure-Object -Property Length -Maximum).Maximum; if (-not $maxLen) { $maxLen = 40 }
  $w = [int][math]::Min(1600, [math]::Max(720, $maxLen * $anchoCar + 40)); $h = [int]($lineas.Count * $altoLin + 70)
  $bmp = New-Object Drawing.Bitmap($w, $h); $g = [Drawing.Graphics]::FromImage($bmp)
  $g.TextRenderingHint = [Drawing.Text.TextRenderingHint]::ClearTypeGridFit
  $g.Clear([Drawing.Color]::FromArgb(30, 30, 30))
  $g.FillRectangle((New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(45, 45, 48))), 0, 0, $w, 34)
  foreach ($k in 0..2) { $col = @([Drawing.Color]::FromArgb(255, 95, 86), [Drawing.Color]::FromArgb(255, 189, 46), [Drawing.Color]::FromArgb(39, 201, 63))[$k]
    $g.FillEllipse((New-Object Drawing.SolidBrush($col)), 12 + $k * 20, 11, 12, 12) }
  $g.DrawString($titulo, $fTit, [Drawing.Brushes]::Gainsboro, 80, 8)
  $verde = New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(106, 216, 120))
  $rojo = New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(255, 110, 110))
  $normal = New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(212, 212, 212))
  $y = 46
  foreach ($l in $lineas) {
    $br = $normal
    if ($l -match 'FALLA|0 received|100% packet loss|Success rate is 0|timed out|Incomplete') { $br = $rojo }
    elseif ($l -match '^OK |FULL|64 bytes from|Success rate is [1-9]|!!!|PUERTO OK|-> \d+ registros|PASA') { $br = $verde }
    $g.DrawString($l, $fuente, $br, 14, $y); $y += $altoLin
  }
  $ruta = Join-Path $DirCap $archivo; $bmp.Save($ruta, [Drawing.Imaging.ImageFormat]::Png); $g.Dispose(); $bmp.Dispose()
}
$IPS = @{ 'Usuario' = '192.168.10.10'; 'R1-Central' = '192.168.10.1'; 'SQLServer-1' = '192.168.20.10'; 'MariaDB-2' = '192.168.30.10'
          'MongoDB-3' = '192.168.40.10'; 'Postgres-4' = '192.168.50.10'; 'R2' = '.20.1 / .30.1'; 'R3' = '.40.1 / .50.1' }
function Topologia([string]$archivo) {
  $links = Api "/projects/$PID_/links"
  $xs = $todos | ForEach-Object { $_.x }; $ys = $todos | ForEach-Object { $_.y }
  $minX = ($xs | Measure-Object -Minimum).Minimum - 120; $minY = ($ys | Measure-Object -Minimum).Minimum - 90
  $w = [int](($xs | Measure-Object -Maximum).Maximum - $minX + 220); $h = [int](($ys | Measure-Object -Maximum).Maximum - $minY + 170)
  $bmp = New-Object Drawing.Bitmap($w, $h); $g = [Drawing.Graphics]::FromImage($bmp)
  $g.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias; $g.Clear([Drawing.Color]::White)
  $f = New-Object Drawing.Font('Segoe UI', 10, [Drawing.FontStyle]::Bold); $fs = New-Object Drawing.Font('Segoe UI', 8)
  $g.DrawString("Topologia - $Proyecto", (New-Object Drawing.Font('Segoe UI', 14, [Drawing.FontStyle]::Bold)), [Drawing.Brushes]::Black, 10, 8)
  $centro = @{}; foreach ($n in $todos) { $centro[$n.node_id] = @(($n.x - $minX + ($n.width / 2)), ($n.y - $minY + ($n.height / 2))) }
  $pen = New-Object Drawing.Pen([Drawing.Color]::FromArgb(90, 90, 90), 2)
  foreach ($l in $links) { $a = $centro[$l.nodes[0].node_id]; $b = $centro[$l.nodes[1].node_id]; $g.DrawLine($pen, [float]$a[0], [float]$a[1], [float]$b[0], [float]$b[1]) }
  foreach ($n in $todos) {
    $c = $centro[$n.node_id]
    $col = switch ($n.node_type) { 'dynamips' { [Drawing.Color]::FromArgb(52, 120, 200) } 'docker' { [Drawing.Color]::FromArgb(40, 150, 110) }
                                   'virtualbox' { [Drawing.Color]::FromArgb(190, 110, 40) } default { [Drawing.Color]::FromArgb(130, 130, 130) } }
    if ($n.status -ne 'started') { $col = [Drawing.Color]::FromArgb(200, 60, 60) }
    $g.FillEllipse((New-Object Drawing.SolidBrush($col)), [float]($c[0] - 24), [float]($c[1] - 24), 48, 48)
    $sz = $g.MeasureString($n.name, $f); $g.DrawString($n.name, $f, [Drawing.Brushes]::Black, [float]($c[0] - $sz.Width / 2), [float]($c[1] + 27))
    $tipo = "$($n.node_type) / $($n.status)"; if ($IPS[$n.name]) { $tipo = "$($IPS[$n.name])  -  $tipo" }; $sz2 = $g.MeasureString($tipo, $fs); $g.DrawString($tipo, $fs, [Drawing.Brushes]::DimGray, [float]($c[0] - $sz2.Width / 2), [float]($c[1] + 44))
  }
  $bmp.Save((Join-Path $DirCap $archivo), [Drawing.Imaging.ImageFormat]::Png); $g.Dispose(); $bmp.Dispose()
}

# -------------------------------------------------------------------- pruebas
$RES = New-Object System.Collections.ArrayList
function Prueba([string]$id, [string]$nombre, [scriptblock]$cuerpo) {
  Write-Host "`n[$id] $nombre ..." -ForegroundColor Cyan
  $texto = ''; $ok = $false
  try { $r = & $cuerpo; $texto = $r.Texto; $ok = $r.Ok } catch { $texto += "`nERROR: $($_.Exception.Message)"; $ok = $false }
  $estado = if ($ok) { 'PASA' } else { 'FALLA' }
  Write-Host "     $estado" -ForegroundColor $(if ($ok) { 'Green' } else { 'Red' })
  $limpio = ($texto -split "`n" | ForEach-Object { $_ -replace '; echo __FI""N__', '' } | Where-Object { $_ -notmatch '^__FIN__\s*$' }) -join "`n"
  Set-Content -Path (Join-Path $DirRes "$id`_$($nombre -replace '[^\w]+','_').txt") -Value $limpio -Encoding UTF8
  Captura "$id.png" "[$id] $nombre  -  $estado" $limpio
  [void]$RES.Add([pscustomobject]@{ Id = $id; Prueba = $nombre; Resultado = $estado })
}

$BASES = [ordered]@{ 'SQL Server' = '192.168.20.10'; 'MariaDB' = '192.168.30.10'; 'MongoDB' = '192.168.40.10'; 'PostgreSQL' = '192.168.50.10' }

Prueba '01' 'Nodos encendidos' {
  $t = "Nodo            Tipo             Estado`n------------------------------------------`n"; $ok = $true
  foreach ($k in ($NODOS.Keys | Sort-Object)) { $n = $NODOS[$k]; if ($n.node_type -eq 'nat') { continue }
    $t += ('{0,-15} {1,-16} {2}' -f $k, $n.node_type, $n.status) + "`n"; if ($n.status -ne 'started') { $ok = $false } }
  @{ Texto = $t; Ok = $ok } }

Prueba '02' 'OSPF en R1-Central (vecinos y rutas)' {
  $o = Ios 'R1-Central' @('show ip ospf neighbor', 'show ip route ospf')
  $vec = ([regex]::Matches($o, 'FULL')).Count; $redes = 0
  foreach ($r in '192.168.20.0', '192.168.30.0', '192.168.40.0', '192.168.50.0') { if ($o -match "O\s+$([regex]::Escape($r))") { $redes++ } }
  @{ Texto = $o + "`n`n>> Vecinos FULL: $vec de 2   |   Redes de bases aprendidas: $redes de 4"; Ok = ($vec -ge 2 -and $redes -eq 4) } }

Prueba '03' 'OSPF en Nube-1, Nube-2, R2 y R3' {
  $t = ''; $ok = $true
  foreach ($r in @(@('Nube-1', 2), @('Nube-2', 2), @('R2', 1), @('R3', 1))) {
    $o = Ios $r[0] @('show ip ospf neighbor'); $v = ([regex]::Matches($o, 'FULL')).Count
    $t += "===== $($r[0]) (esperados: $($r[1])) =====`n$o`n"; if ($v -lt $r[1]) { $ok = $false } }
  @{ Texto = $t; Ok = $ok } }

Prueba '04' 'Ping desde Usuario a las 4 bases' {
  $t = ''; $ok = $true
  foreach ($k in $BASES.Keys) { $o = Bash 'Usuario' "/gns3/bin/busybox ping -c 3 $($BASES[$k])" 30
    $t += "===== $k ($($BASES[$k])) =====`n$o`n"; if ($o -notmatch '[1-3] packets received') { $ok = $false } }
  @{ Texto = $t; Ok = $ok } }

Prueba '05' 'Traceroute: camino que siguen los paquetes' {
  $t = ''
  # -I = traceroute por ICMP (Windows responde ICMP; el traceroute UDP lo bloquea su firewall)
  # Se usa MariaDB para el lado de Nube-1/R2: Windows Server (SQL Server) no responde a traceroute
  # por su firewall, aunque si responde a ping (prueba 04) y a conexiones (prueba 06).
  $o1 = Bash 'Usuario' '/gns3/bin/busybox traceroute -I -n -w 2 -q 1 -m 8 192.168.30.10' 60
  $o2 = Bash 'Usuario' '/gns3/bin/busybox traceroute -I -n -w 2 -q 1 -m 8 192.168.50.10' 60
  $t = "Hacia MariaDB (debe pasar por R1-Central -> Nube-1 -> R2):`n$o1`n`nHacia PostgreSQL (debe pasar por R1-Central -> Nube-2 -> R3):`n$o2"
  $salto = { param($o, $ip) $o -match "(?m)^\s*\d+\s+$([regex]::Escape($ip))\s" }
  @{ Texto = $t; Ok = ((& $salto $o1 '10.0.1.2') -and (& $salto $o1 '10.0.3.2') -and (& $salto $o1 '192.168.30.10') -and
                       (& $salto $o2 '10.0.2.2') -and (& $salto $o2 '10.0.4.2') -and (& $salto $o2 '192.168.50.10')) } }

Prueba '06' 'Login real a las 4 bases (probar_bases.py)' {
  $chk = Bash 'Usuario' 'python3 -c "import pymssql, pymysql, pymongo, psycopg2" 2>&1 | tail -1' 30
  $pre = ''
  if ($chk -match 'No module') { $pre = Bash 'Usuario' 'pip install --user -q pymssql pymysql pymongo psycopg2-binary 2>&1 | grep -v notice' 300; $pre = "(Se instalaron los drivers de Python)`n" }
  $o = Bash 'Usuario' 'python3 /root/probar_bases.py' 90
  @{ Texto = $pre + $o; Ok = (([regex]::Matches($o, '(?m)^OK ')).Count -eq 4) } }

if (-not $SinReplicacion) {
  Prueba '07' 'Insertar 1 registro en cada base (practica.py demo)' {
    $null = Bash 'Usuario' 'cd /root && python3 practica.py limpiar' 90
    $o = Bash 'Usuario' 'cd /root && python3 practica.py demo' 120
    @{ Texto = $o; Ok = (([regex]::Matches($o, '-> 1 registros')).Count -eq 4) } }

  Prueba '08' 'Replicacion en anillo 1->2->3->4->1' {
    $o = Bash 'Usuario' 'cd /root && python3 practica.py replicar' 120
    @{ Texto = $o; Ok = (([regex]::Matches($o, '-> 4 registros')).Count -eq 4) } }

  Prueba '09' 'Registros en cada base despues de replicar' {
    $o = Bash 'Usuario' 'cd /root && python3 practica.py mostrar' 120
    @{ Texto = $o; Ok = (([regex]::Matches($o, ': 4 registros')).Count -eq 4) } }
}

Topologia 'topologia.png'

# -------------------------------------------------------------------- resumen
$tablaRes = ($RES | Format-Table -AutoSize | Out-String).Trim()
$pasan = @($RES | Where-Object { $_.Resultado -eq 'PASA' }).Count
$resumen = "Proyecto: $Proyecto   |   Fecha: $(Get-Date -Format 'yyyy-MM-dd HH:mm')`n`n$tablaRes`n`nPASAN: $pasan de $($RES.Count)"
Captura '00_resumen.png' 'Resumen de la verificacion' $resumen
Set-Content -Path (Join-Path $DirRes '00_resumen.txt') -Value $resumen -Encoding UTF8
Write-Host "`n================ RESUMEN ================" -ForegroundColor Yellow
Write-Host $resumen
Write-Host "Capturas en: $DirCap" -ForegroundColor Yellow
if ($pasan -ne $RES.Count) { exit 2 }
