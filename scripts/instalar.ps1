<#
  Instalacion automatica - Practica del Parcial 3 (GNS3 + 4 bases de datos)

  Antes de ejecutarlo:
    - Ten instalados GNS3 2.2.x, la GNS3 VM y VirtualBox.
    - Abre GNS3 y espera a que "GNS3 VM" salga en verde (Servers Summary).
    - Deja en la misma carpeta que este script:
         Practica_Parcial3.gns3project
         Win-SQL.ova

  Ejecutar (PowerShell, en esta carpeta):
      powershell -ExecutionPolicy Bypass -File .\instalar.ps1

  Que hace:
    1. Revisa que GNS3 y la GNS3 VM esten listos y que VirtualBox pueda usar VT-x.
    2. Importa la VM "Win-SQL" (Windows Server + SQL Server) en VirtualBox.
    3. Importa el proyecto en GNS3 conservando donde corre cada nodo.
    4. Agrega el nodo SQLServer-1 (la VM Win-SQL) y lo conecta a R2 f0/0.
#>
param([string]$Proyecto = 'Practica_Parcial3')
$ErrorActionPreference = 'Stop'
$Aqui = Split-Path -Parent $MyInvocation.MyCommand.Path
$Raiz = Split-Path -Parent $Aqui
$ImagenIOS = 'c7200-adventerprisek9-mz.124-24.T5.image'
function Buscar([string]$nombre) {
  # Busca un archivo junto al script, en la carpeta de arriba, en gns3\ o en descargas\
  foreach ($d in @($Aqui, $Raiz, (Join-Path $Raiz 'gns3'), (Join-Path $Raiz 'descargas'), (Join-Path $Aqui 'descargas'))) {
    $f = Join-Path $d $nombre; if (Test-Path $f) { return $f } }
  return $null
}
function Paso($t) { Write-Host "`n>> $t" -ForegroundColor Cyan }
function Bien($t) { Write-Host "   OK  $t" -ForegroundColor Green }
function Mal($t)  { Write-Host "   ERROR  $t" -ForegroundColor Red; exit 1 }
function Aviso($t){ Write-Host "   AVISO  $t" -ForegroundColor Yellow }

# ------------------------------------------------------------ conexion a GNS3
$ini = Join-Path $env:APPDATA 'GNS3\2.2\gns3_server.ini'
$Puerto = 3080; $Hdr = @{}
if (Test-Path $ini) {
  $txt = Get-Content $ini
  $m = $txt | Select-String '^port\s*=\s*(\d+)'; if ($m) { $Puerto = [int]$m.Matches[0].Groups[1].Value }
  if ($txt | Select-String '^auth\s*=\s*True') {
    $uu = (($txt | Select-String '^user\s*=') -split '=', 2)[1].Trim()
    $pp = (($txt | Select-String '^password\s*=') -split '=', 2)[1].Trim()
    $Hdr = @{ Authorization = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${uu}:${pp}")) }
  }
}
$Base = "http://127.0.0.1:$Puerto/v2"
function Api($metodo, $ruta, $cuerpo) {
  $req = @{ Uri = "$Base$ruta"; Method = $metodo; Headers = $Hdr; TimeoutSec = 600 }
  if ($null -ne $cuerpo) { $req.Body = [Text.Encoding]::UTF8.GetBytes(($cuerpo | ConvertTo-Json -Depth 8)); $req.ContentType = 'application/json' }
  Invoke-RestMethod @req
}

Paso 'Revisando GNS3'
try { $ver = Api GET '/version' $null } catch { Mal "No encuentro GNS3 en el puerto $Puerto. Abre GNS3 y vuelve a ejecutar este script." }
Bien "GNS3 $($ver.version)"
if (-not $ver.version.StartsWith('2.2')) { Aviso 'El proyecto se hizo con GNS3 2.2.61; con otra version podria no abrir.' }
$vm = $null; foreach ($c in (Api GET '/computes' $null)) { if ($c.compute_id -eq 'vm') { $vm = $c } }
if (-not $vm -or -not $vm.connected) { Mal 'La GNS3 VM no esta conectada. En GNS3: Edit > Preferences > GNS3 VM > Enable, y espera a que salga en verde.' }
Bien "GNS3 VM conectada ($($vm.host))"

Paso 'Revisando VirtualBox'
$vbm = 'C:\Program Files\Oracle\VirtualBox\VBoxManage.exe'
if (-not (Test-Path $vbm)) { Mal 'No encuentro VirtualBox. Instalalo desde virtualbox.org.' }
Bien 'VirtualBox instalado'
if ((Get-CimInstance Win32_ComputerSystem).HypervisorPresent) {
  Aviso 'El hipervisor de Windows (Hyper-V / VBS) esta activo. VirtualBox puede ir lento o fallar.'
  Aviso 'Para apagarlo (Terminal como Administrador) y despues reiniciar:'
  Write-Host '      bcdedit /set hypervisorlaunchtype off'
  Write-Host '      reg add "HKLM\SYSTEM\CurrentControlSet\Control\DeviceGuard" /v EnableVirtualizationBasedSecurity /t REG_DWORD /d 0 /f'
  Write-Host '      (y desactiva Seguridad de Windows > Seguridad del dispositivo > Integridad de memoria)'
}

Paso 'VM de Windows con SQL Server (Win-SQL)'
$vms = & $vbm list vms
if ($vms -match '"Win-SQL"') { Bien 'La VM Win-SQL ya existe en VirtualBox' }
else {
  $ova = Buscar 'Win-SQL.ova'
  if (-not $ova) {
    # Si llego en pedazos (Win-SQL.ova.001, .002, ...), se unen aqui mismo
    $p1 = Buscar 'Win-SQL.ova.001'
    if (-not $p1) { Mal 'No encuentro Win-SQL.ova ni sus pedazos (Win-SQL.ova.001, .002...). Ponlos en esta misma carpeta.' }
    $dirP = Split-Path -Parent $p1; $ova = Join-Path $dirP 'Win-SQL.ova'
    $partes = Get-ChildItem $dirP -Filter 'Win-SQL.ova.0*' | Where-Object { $_.Name -match '\.\d{3}$' } | Sort-Object Name
    Write-Host "   Uniendo $($partes.Count) pedazos de Win-SQL.ova (unos minutos)..."
    $outS = [IO.File]::Create("$ova.tmp"); $bufU = New-Object byte[] (64MB)
    try { foreach ($pt in $partes) { $inS = [IO.File]::OpenRead($pt.FullName); try { while (($r = $inS.Read($bufU, 0, $bufU.Length)) -gt 0) { $outS.Write($bufU, 0, $r) } } finally { $inS.Close() } } }
    finally { $outS.Close() }
    $sha = Join-Path $dirP 'Win-SQL.ova.sha256'
    if (Test-Path $sha) {
      $esperado = ((Get-Content $sha -TotalCount 1) -split '\s+')[0].ToLower()
      Write-Host '   Comprobando que el archivo unido quedo identico...'
      if ((Get-FileHash "$ova.tmp" -Algorithm SHA256).Hash.ToLower() -ne $esperado) { Mal 'El archivo unido no coincide. Falta un pedazo o alguno se descargo mal; vuelve a descargarlos.' }
    }
    Move-Item "$ova.tmp" $ova -Force; Bien 'Pedazos unidos en Win-SQL.ova'
  }
  Write-Host '   Importando Win-SQL.ova en VirtualBox (puede tardar 10-20 minutos)...'
  & $vbm import $ova --vsys 0 --vmname 'Win-SQL'
  if ($LASTEXITCODE -ne 0) { Mal 'Fallo la importacion del .ova' }
  Bien 'Win-SQL importada'
}

Paso "Proyecto $Proyecto en GNS3"
$PR = $null; foreach ($x in (Api GET '/projects' $null)) { if ($x.name -eq $Proyecto) { $PR = $x } }
if ($PR) { Bien "El proyecto ya existe ($($PR.path))" }
else {
  $arch = Buscar "$Proyecto.gns3project"
  if (-not $arch) { Mal "No encuentro $Proyecto.gns3project" }

  # Imagen del router Cisco c7200: si el proyecto no la trae, debe estar en GNS3 o en descargas\.
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $zip = [IO.Compression.ZipFile]::OpenRead($arch)
  $traeImagen = [bool]($zip.Entries | Where-Object { $_.FullName -eq "images/dynamips/$ImagenIOS" }); $zip.Dispose()
  if ($traeImagen) { Bien 'El proyecto incluye la imagen del router c7200' }
  else {
    $dirImg = Join-Path $env:USERPROFILE 'GNS3\images'
    if (Test-Path $ini) { $m = Get-Content $ini | Select-String '^images_path\s*=\s*(.+)$'; if ($m) { $dirImg = $m.Matches[0].Groups[1].Value.Trim() } }
    $dirIOS = Join-Path $dirImg 'IOS'; $destino = Join-Path $dirIOS $ImagenIOS
    if (Test-Path $destino) { Bien "GNS3 ya tiene la imagen $ImagenIOS" }
    else {
      $origen = Buscar $ImagenIOS
      if (-not $origen) { Mal "Falta la imagen del router Cisco: $ImagenIOS. Pidela a tu profesor o companeros y ponla en la carpeta descargas\ (no se publica por licencia de Cisco)." }
      New-Item -ItemType Directory -Force $dirIOS | Out-Null; Copy-Item $origen $destino -Force
      Bien "Imagen $ImagenIOS copiada a $dirIOS"
    }
  }
  Write-Host '   Importando el proyecto en GNS3 (tarda unos minutos)...'
  $nuevoId = [guid]::NewGuid().ToString()
  $r = Invoke-RestMethod -Uri "$Base/projects/$nuevoId/import?name=$Proyecto&keep_compute_ids=yes" -Method Post -Headers $Hdr `
       -InFile $arch -ContentType 'application/octet-stream' -TimeoutSec 3600
  $PR = $r; Bien "Proyecto importado en $($r.path)"
}
if ($PR.status -ne 'opened') { $PR = Api POST "/projects/$($PR.project_id)/open" @{} ; Bien 'Proyecto abierto' }
$P = $PR.project_id

Paso 'Nodo SQLServer-1 (Win-SQL) conectado a R2'
$tid = $null; foreach ($t in (Api GET '/templates' $null)) { if ($t.name -eq 'Win-SQL' -and $t.template_type -eq 'virtualbox') { $tid = $t.template_id } }
if (-not $tid) {
  $t = Api POST '/templates' @{ name = 'Win-SQL'; template_type = 'virtualbox'; compute_id = 'local'; vmname = 'Win-SQL'
         adapters = 1; use_any_adapter = $true; ram = 3072; linked_clone = $false; headless = $false
         on_close = 'shutdown_signal'; console_type = 'none'; category = 'guest'; symbol = ':/symbols/computer.svg' }
  $tid = $t.template_id; Bien 'Plantilla Win-SQL creada'
} else { Bien 'Plantilla Win-SQL ya existe' }
$NOD = @{}; foreach ($x in (Api GET "/projects/$P/nodes" $null)) { $NOD[$x.name] = $x }
if ($NOD.ContainsKey('SQLServer-1')) { Bien 'SQLServer-1 ya estaba en el proyecto' }
else {
  if (-not $NOD.ContainsKey('R2')) { Mal 'No encuentro el router R2 en el proyecto.' }
  $sq = Api POST "/projects/$P/templates/$tid" @{ x = -520; y = 220 }
  $null = Api PUT "/projects/$P/nodes/$($sq.node_id)" @{ name = 'SQLServer-1' }
  $null = Api POST "/projects/$P/links" @{ nodes = @(@{ node_id = $NOD['R2'].node_id; adapter_number = 0; port_number = 0 },
                                                     @{ node_id = $sq.node_id; adapter_number = 0; port_number = 0 }) }
  Bien 'SQLServer-1 agregado y conectado a R2 FastEthernet0/0'
}

$nodos = @(Api GET "/projects/$P/nodes" $null)
Write-Host "`n=========================================================" -ForegroundColor Yellow
Write-Host " Listo: $Proyecto tiene $($nodos.Count) nodos." -ForegroundColor Yellow
Write-Host ' Siguiente:' -ForegroundColor Yellow
Write-Host '   1. En GNS3: File > Open project > Practica_Parcial3 (si no se abrio solo).'
Write-Host '   2. Presiona Start (boton play verde) y espera unos 3 minutos.'
Write-Host '   3. Ejecuta las pruebas:'
Write-Host '        powershell -ExecutionPolicy Bypass -File .\verificar.ps1'
Write-Host "=========================================================" -ForegroundColor Yellow
