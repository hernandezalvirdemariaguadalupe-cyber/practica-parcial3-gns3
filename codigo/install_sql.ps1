# Instala SQL Server 2022 Express en la VM Win-SQL y lo deja listo para conexiones remotas.
# Se ejecuta DENTRO de la VM como Administrator.
$ErrorActionPreference = 'Stop'
$log = 'C:\sqlsetup\install.log'
New-Item -ItemType Directory -Force C:\sqlsetup | Out-Null
function Log($m) { "$(Get-Date -Format s) $m" | Tee-Object -FilePath $log -Append }
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$sa = 'Practica123!'

Log 'Descargando instalador de SQL Server 2022 Express'
Invoke-WebRequest 'https://go.microsoft.com/fwlink/p/?linkid=2216019' -OutFile C:\sqlsetup\SQL2022-SSEI-Expr.exe -UseBasicParsing

Log 'Descargando medios (Core)'
Start-Process C:\sqlsetup\SQL2022-SSEI-Expr.exe -ArgumentList '/ACTION=Download','/MEDIAPATH=C:\sqlsetup\media','/MEDIATYPE=Core','/QUIET' -Wait
$pkg = Get-ChildItem C:\sqlsetup\media -Filter 'SQLEXPR*.exe' | Select-Object -First 1
if (-not $pkg) { throw 'No se descargo el paquete SQLEXPR' }

Log "Extrayendo $($pkg.Name)"
Start-Process $pkg.FullName -ArgumentList '/q','/x:C:\sqlsetup\extract' -Wait

Log 'Instalando motor (instancia SQLEXPRESS)'
$p = Start-Process C:\sqlsetup\extract\setup.exe -ArgumentList @(
  '/Q', '/IACCEPTSQLSERVERLICENSETERMS', '/ACTION=Install', '/FEATURES=SQLENGINE',
  '/INSTANCENAME=SQLEXPRESS', '/SECURITYMODE=SQL', "/SAPWD=`"$sa`"",
  '/SQLSYSADMINACCOUNTS="BUILTIN\Administrators"', '/TCPENABLED=1', '/UPDATEENABLED=0'
) -Wait -PassThru
Log "setup.exe salio con codigo $($p.ExitCode)"

Log 'Fijando puerto TCP 1433'
$inst = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL').SQLEXPRESS
$tcp = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$inst\MSSQLServer\SuperSocketNetLib\Tcp"
Set-ItemProperty $tcp -Name Enabled -Value 1
Set-ItemProperty "$tcp\IPAll" -Name TcpDynamicPorts -Value ''
Set-ItemProperty "$tcp\IPAll" -Name TcpPort -Value '1433'
Restart-Service 'MSSQL$SQLEXPRESS' -Force

Log 'Abriendo firewall (1433 y ping)'
New-NetFirewallRule -DisplayName 'SQL Server 1433' -Direction Inbound -Protocol TCP -LocalPort 1433 -Action Allow | Out-Null
New-NetFirewallRule -DisplayName 'Ping ICMPv4' -Direction Inbound -Protocol ICMPv4 -IcmpType 8 -Action Allow | Out-Null

Log 'Creando base de datos practica'
Start-Sleep 10
$cn = New-Object System.Data.SqlClient.SqlConnection "Server=127.0.0.1,1433;User Id=sa;Password=$sa;TrustServerCertificate=True"
$cn.Open()
$cmd = $cn.CreateCommand()
$cmd.CommandText = "IF DB_ID('practica') IS NULL CREATE DATABASE practica; SELECT @@VERSION"
Log ($cmd.ExecuteScalar())
$cn.Close()
Log 'LISTO'
