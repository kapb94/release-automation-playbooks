<#
.SYNOPSIS
    Gestor de Despliegues y Auto-Update por Tags de Release (Stable y RC) para WorkerFE.

.DESCRIPTION
    Autodetecta el nombre del Servicio de Windows que apunta a FE.exe (o permite
    registrarlo con -Action install-service), consulta el Release Tag e ID de despliegue,
    suscribe el servidor a un canal ('stable' o 'rc'), configura una Tarea Programada
    de Windows para auto-actualizacion silenciosa, actualiza manualmente o hace rollback.

.EXAMPLE
    .\Manage-WorkerFE.ps1 -Action status
    .\Manage-WorkerFE.ps1 -Action install-service -ServiceName "WorkerFE"
    .\Manage-WorkerFE.ps1 -Action register-autoupdate -Channel stable -IntervalMinutes 15
    .\Manage-WorkerFE.ps1 -Action register-autoupdate -Channel rc -IntervalMinutes 10
    .\Manage-WorkerFE.ps1 -Action set-channel -Channel rc
    .\Manage-WorkerFE.ps1 -Action update -Channel rc
    .\Manage-WorkerFE.ps1 -Action rollback
#>
param(
    [Parameter(Mandatory = $false)]
    [ValidateSet("status", "update", "auto-update", "register-autoupdate", "unregister-autoupdate", "set-channel", "install-service", "history", "rollback")]
    [string]$Action = "status",

    [Parameter(Mandatory = $false)]
    [ValidateSet("stable", "rc", "")]
    [string]$Channel = "",

    [Parameter(Mandatory = $false)]
    [int]$IntervalMinutes = 15,

    [Parameter(Mandatory = $false)]
    [string]$Tag = "latest",

    [Parameter(Mandatory = $false)]
    [switch]$IncludeRC,

    [Parameter(Mandatory = $false)]
    [string]$ServiceName = "",

    [Parameter(Mandatory = $false)]
    [string]$InstallPath = $PSScriptRoot,

    [Parameter(Mandatory = $false)]
    [string]$BackupRoot = "C:\Backups\WorkerFE",

    [Parameter(Mandatory = $false)]
    [string]$GitHubRepo = "kapb94/FE-GSM",

    [Parameter(Mandatory = $false)]
    [string]$GitHubToken = $env:GITHUB_TOKEN,

    [Parameter(Mandatory = $false)]
    [string]$LocalZipPath = ""
)

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Normalizar InstallPath sin barra final
$InstallPath = $InstallPath.TrimEnd('\', '/')

function Get-GitHubHeaders {
    $token = $GitHubToken
    if ([string]::IsNullOrWhiteSpace($token)) {
        $token = [Environment]::GetEnvironmentVariable("GITHUB_TOKEN", "Machine")
    }
    if ([string]::IsNullOrWhiteSpace($token)) {
        $token = [Environment]::GetEnvironmentVariable("GITHUB_TOKEN", "User")
    }
    $headers = @{
        "User-Agent" = "WorkerFE-Deployment-Manager"
        "Accept"     = "application/vnd.github+json"
    }
    if (-not [string]::IsNullOrWhiteSpace($token)) {
        $headers["Authorization"] = "Bearer $token"
    }
    return $headers
}

function Get-AutoUpdateSettings {
    $cfgPath = Join-Path $InstallPath "autoupdate-settings.json"
    if (Test-Path $cfgPath) {
        try {
            return Get-Content $cfgPath -Raw | ConvertFrom-Json
        } catch {}
    }
    return [PSCustomObject]@{
        subscribedChannel = "stable"
        intervalMinutes   = 15
        serviceName       = ""
        updatedAt         = "Por defecto (no configurado)"
    }
}

function Resolve-ServiceName {
    # 1. Si el usuario paso explicitamente -ServiceName, usar ese
    if (-not [string]::IsNullOrWhiteSpace($ServiceName)) {
        return $ServiceName
    }

    # 2. Si ya esta guardado en autoupdate-settings.json y existe en Windows, usar ese
    $saved = Get-AutoUpdateSettings
    if (-not [string]::IsNullOrWhiteSpace($saved.serviceName)) {
        if (Get-Service -Name $saved.serviceName -ErrorAction SilentlyContinue) {
            return $saved.serviceName
        }
    }

    # 3. Buscar en Win32_Service algun servicio cuyo PathName apunte exactamente al FE.exe de este $InstallPath
    $expectedExe = (Join-Path $InstallPath "FE.exe").ToLower()
    try {
        $allServices = Get-CimInstance Win32_Service -ErrorAction SilentlyContinue
        if ($allServices) {
            $exactMatch = $allServices | Where-Object {
                $_.PathName -and $_.PathName.ToLower().Contains($expectedExe)
            } | Select-Object -First 1

            if ($exactMatch) {
                return $exactMatch.Name
            }

            # 4. Si solo hay un servicio en toda la maquina que ejecute FE.exe, usar ese
            $anyFeMatch = @($allServices | Where-Object {
                $_.PathName -and ($_.PathName -match '(?i)\\FE\.exe(\s|"|$)')
            })
            if ($anyFeMatch.Count -eq 1) {
                return $anyFeMatch[0].Name
            }
        }
    } catch {}

    # 5. Probar nombres comunes si existen como servicio en Windows
    foreach ($candidate in @("WorkerFE", "WorkerInfile", "FE", "ServicioFE", "GoSocketFE")) {
        if (Get-Service -Name $candidate -ErrorAction SilentlyContinue) {
            return $candidate
        }
    }

    # Fallback si aun no esta instalado como servicio
    if (-not [string]::IsNullOrWhiteSpace($saved.serviceName)) {
        return $saved.serviceName
    }
    return "WorkerFE"
}

$ResolvedServiceName = Resolve-ServiceName
$TaskName = "WorkerFE_AutoUpdate_$ResolvedServiceName"

function Save-AutoUpdateSettings([string]$TargetChannel, [int]$Interval, [string]$SvcName) {
    New-Item -ItemType Directory -Force -Path $InstallPath | Out-Null
    $cfgPath = Join-Path $InstallPath "autoupdate-settings.json"
    $settings = [ordered]@{
        subscribedChannel = $TargetChannel
        intervalMinutes   = $Interval
        serviceName       = $SvcName
        updatedAt         = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    }
    $settings | ConvertTo-Json -Depth 4 | Set-Content -Path $cfgPath -Encoding UTF8
}

function Get-EffectiveChannel {
    if (-not [string]::IsNullOrWhiteSpace($Channel)) {
        return $Channel.ToLower()
    }
    if ($IncludeRC.IsPresent) {
        return "rc"
    }
    $settings = Get-AutoUpdateSettings
    if (-not [string]::IsNullOrWhiteSpace($settings.subscribedChannel)) {
        return $settings.subscribedChannel.ToLower()
    }
    return "stable"
}

function Get-LocalReleaseInfo {
    $manifestPath = Join-Path $InstallPath "release-manifest.json"
    if (Test-Path $manifestPath) {
        try {
            $m = Get-Content $manifestPath -Raw | ConvertFrom-Json
            if (-not $m.PSObject.Properties["channel"] -or [string]::IsNullOrWhiteSpace($m.channel)) {
                $ch = if ($m.releaseTag -match "-") { "rc" } else { "stable" }
                $m | Add-Member -NotePropertyName "channel" -NotePropertyValue $ch -Force
            }
            return $m
        } catch {}
    }

    $exePath = Join-Path $InstallPath "FE.exe"
    if (Test-Path $exePath) {
        $verInfo = (Get-Item $exePath).VersionInfo
        $prodVer = $verInfo.ProductVersion
        $tagPart = if ($prodVer -match "^([^\+]+)") { $Matches[1] } else { $prodVer }
        $shaPart = if ($prodVer -match "\+(.+)$") { $Matches[1] } else { "unknown" }
        if ($tagPart -notmatch "^v") { $tagPart = "v$tagPart" }
        $ch = if ($tagPart -match "-") { "rc" } else { "stable" }

        return [PSCustomObject]@{
            releaseTag       = $tagPart
            channel          = $ch
            deploymentId     = "EXE-$tagPart-$shaPart"
            commitSha        = $shaPart
            publishedAtUtc   = (Get-Item $exePath).LastWriteTimeUtc.ToString("yyyy-MM-ddTHH:mm:ssZ")
            installedAtLocal = (Get-Item $exePath).LastWriteTime.ToString("yyyy-MM-dd HH:mm:ss")
        }
    }

    return [PSCustomObject]@{
        releaseTag       = "NO-INSTALADO"
        channel          = "N/A"
        deploymentId     = "N/A"
        commitSha        = "N/A"
        publishedAtUtc   = "N/A"
        installedAtLocal = "N/A"
    }
}

function Get-RemoteReleaseInfo([string]$TargetTag, [string]$TargetChannel) {
    $headers = Get-GitHubHeaders
    try {
        if ($TargetTag -eq "latest") {
            if ($TargetChannel -eq "rc") {
                # En canal RC busca el ultimo release publicado (sea RC/prerelease o stable)
                $listUrl = "https://api.github.com/repos/$GitHubRepo/releases?per_page=10"
                $releases = Invoke-RestMethod -Uri $listUrl -Headers $headers -Method Get
                return ($releases | Select-Object -First 1)
            } else {
                # En canal Stable consulta /releases/latest que ignora todos los pre-releases (-rc)
                $latestUrl = "https://api.github.com/repos/$GitHubRepo/releases/latest"
                return Invoke-RestMethod -Uri $latestUrl -Headers $headers -Method Get
            }
        } else {
            $tagUrl = "https://api.github.com/repos/$GitHubRepo/releases/tags/$TargetTag"
            return Invoke-RestMethod -Uri $tagUrl -Headers $headers -Method Get
        }
    } catch {
        return $null
    }
}

function Show-Status {
    $local = Get-LocalReleaseInfo
    $effectiveChannel = Get-EffectiveChannel
    $autoSettings = Get-AutoUpdateSettings
    $svc = Get-Service -Name $ResolvedServiceName -ErrorAction SilentlyContinue
    if ($svc) {
        $wmiSvc = Get-CimInstance Win32_Service -Filter "Name='$ResolvedServiceName'" -ErrorAction SilentlyContinue
        $svcPathInfo = if ($wmiSvc -and $wmiSvc.PathName) { " -> $($wmiSvc.PathName)" } else { "" }
        $svcState = "$($svc.Status) (Nombre: $ResolvedServiceName$svcPathInfo)"
    } else {
        $svcState = "No registrado como servicio de Windows (Ejecute -Action install-service para crearlo)"
    }

    $localChannelLabel = if ($local.channel -eq "rc") { "RC (Pre-release / Pruebas)" } elseif ($local.channel -eq "stable") { "Stable (Produccion)" } else { $local.channel }

    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    $taskState = if ($task) { "Activa ($($task.State)) - Cada $($autoSettings.intervalMinutes) min" } else { "No registrada" }

    Write-Host "=======================================================" -ForegroundColor Cyan
    Write-Host " ESTADO DEL SERVICIO Y DESPLIEGUE: $ResolvedServiceName" -ForegroundColor Cyan
    Write-Host "=======================================================" -ForegroundColor Cyan
    Write-Host (" Estado Windows Service : {0}" -f $svcState)
    Write-Host (" Ruta Instalacion       : {0}" -f $InstallPath)
    Write-Host (" Release Tag Instalado  : {0}" -f $local.releaseTag) -ForegroundColor Yellow
    Write-Host (" Canal del Binario      : {0}" -f $localChannelLabel)
    Write-Host (" ID de Despliegue       : {0}" -f $local.deploymentId) -ForegroundColor Yellow
    Write-Host (" Commit SHA             : {0}" -f $local.commitSha)
    Write-Host (" Fecha Instalacion      : {0}" -f $local.installedAtLocal)
    Write-Host "-------------------------------------------------------"
    Write-Host (" Canal Suscrito         : {0}" -f $effectiveChannel.ToUpper()) -ForegroundColor Cyan
    Write-Host (" Tarea Auto-Update      : {0}" -f $taskState)
    Write-Host "-------------------------------------------------------"

    $remote = Get-RemoteReleaseInfo -TargetTag "latest" -TargetChannel $effectiveChannel

    if ($null -eq $remote) {
        Write-Host (" Ultimo Release GitHub  : No se pudo consultar [Canal: {0}] ($GitHubRepo)" -f $effectiveChannel) -ForegroundColor DarkYellow
    } else {
        $remoteType = if ($remote.prerelease) { "RC / Pre-release" } else { "Stable" }
        Write-Host (" Ultimo Release GitHub  : {0} [{1}] ({2})" -f $remote.tag_name, $remoteType, $remote.published_at) -ForegroundColor Cyan
        if ($local.releaseTag -eq $remote.tag_name) {
            Write-Host (" ESTADO DE VERSION      : [OK] AL DIA EN CANAL {0} ({1})" -f $effectiveChannel.ToUpper(), $local.releaseTag) -ForegroundColor Green
        } else {
            Write-Host (" ESTADO DE VERSION      : [!] NUEVA VERSION EN CANAL {0} ({1} -> {2})" -f $effectiveChannel.ToUpper(), $local.releaseTag, $remote.tag_name) -ForegroundColor Magenta
            Write-Host (" Para actualizar ejecute: .\Manage-WorkerFE.ps1 -Action update -Channel {0}" -f $effectiveChannel)
        }
    }
    Write-Host "=======================================================" -ForegroundColor Cyan
}

function Show-History {
    $historyFile = Join-Path $InstallPath "deployments-history.log"
    if (Test-Path $historyFile) {
        Write-Host "=== HISTORIAL DE DESPLIEGUES ($historyFile) ===" -ForegroundColor Cyan
        Get-Content $historyFile | Select-Object -Last 25
    } else {
        Write-Host "Aun no existe historial de despliegues en $historyFile" -ForegroundColor Yellow
    }
}

function Install-PackageFromZip([string]$ZipFile, [string]$TargetReleaseLabel) {
    $prevInfo = Get-LocalReleaseInfo
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"

    # 1. Extraer ZIP temporalmente para validar
    $tempExtract = Join-Path ([System.IO.Path]::GetTempPath()) "WorkerFE_Stage_$timestamp"
    New-Item -ItemType Directory -Force -Path $tempExtract | Out-Null
    Expand-Archive -Path $ZipFile -DestinationPath $tempExtract -Force

    # 2. Crear Backup de la version actual
    New-Item -ItemType Directory -Force -Path $BackupRoot | Out-Null
    $backupZip = Join-Path $BackupRoot ("WorkerFE_{0}_{1}.zip" -f $prevInfo.releaseTag, $timestamp)
    if (Test-Path (Join-Path $InstallPath "FE.dll")) {
        Write-Host "[1/4] Creando respaldo de la version actual ($($prevInfo.releaseTag)) en $backupZip..." -ForegroundColor Cyan
        $itemsToBackup = Get-ChildItem -Path $InstallPath -Exclude "XMLs", "C:", "logs"
        if ($itemsToBackup) {
            Compress-Archive -Path $itemsToBackup.FullName -DestinationPath $backupZip -Force
        }
    } else {
        Write-Host "[1/4] Instalacion limpia detectada en $InstallPath (sin version previa que respaldar)..." -ForegroundColor DarkGray
    }

    # 3. Detener el servicio de Windows (si existe)
    $svc = Get-Service -Name $ResolvedServiceName -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -ne 'Stopped') {
        Write-Host "[2/4] Deteniendo servicio de Windows '$ResolvedServiceName'..." -ForegroundColor Cyan
        Stop-Service -Name $ResolvedServiceName -Force
        $svc.WaitForStatus('Stopped', '00:00:30')
    } else {
        Write-Host "[2/4] Servicio '$ResolvedServiceName' no esta en ejecucion o aun no ha sido registrado, continuando..." -ForegroundColor DarkGray
    }

    # 4. Copiar archivos nuevos protegiendo config.json, autoupdate-settings.json y Manage-WorkerFE.ps1 en ejecucion
    Write-Host "[3/4] Actualizando binarios en $InstallPath (protegiendo config.json)..." -ForegroundColor Cyan
    New-Item -ItemType Directory -Force -Path $InstallPath | Out-Null
    Get-ChildItem -Path $tempExtract -Exclude "config.json", "appsettings.Production.json", "deployments-history.log", "autoupdate-settings.json" | ForEach-Object {
        try {
            Copy-Item -Path $_.FullName -Destination $InstallPath -Recurse -Force
        } catch {
            if ($_.Name -ne "Manage-WorkerFE.ps1") { throw $_ }
        }
    }

    # Actualizar fecha local de instalacion en release-manifest.json
    $manifestPath = Join-Path $InstallPath "release-manifest.json"
    if (Test-Path $manifestPath) {
        $manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
        $manifest.installedAtLocal = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        $manifest | ConvertTo-Json -Depth 4 | Set-Content -Path $manifestPath -Encoding UTF8
    }

    # Registrar en historial de despliegues
    $newInfo = Get-LocalReleaseInfo
    $historyFile = Join-Path $InstallPath "deployments-history.log"
    $logLine = "[{0}] DEPLOY | Servicio: {1} | Canal: {2} | De: {3} ({4}) -> A: {5} ({6}) | Commit: {7} | Usuario: {8}" -f `
        (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $ResolvedServiceName, $newInfo.channel, $prevInfo.releaseTag, $prevInfo.deploymentId, `
        $newInfo.releaseTag, $newInfo.deploymentId, $newInfo.commitSha, $env:USERNAME
    Add-Content -Path $historyFile -Value $logLine -Encoding UTF8

    # 5. Iniciar el servicio nuevamente (si existe)
    if ($svc) {
        Write-Host "[4/4] Iniciando servicio de Windows '$ResolvedServiceName'..." -ForegroundColor Cyan
        Start-Service -Name $ResolvedServiceName
        $svc.WaitForStatus('Running', '00:00:30')
    } else {
        Write-Host "[4/4] Binarios listos. Si desea registrar e iniciar el servicio de Windows ejecute: .\Manage-WorkerFE.ps1 -Action install-service" -ForegroundColor Yellow
    }

    Remove-Item -Path $tempExtract -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "Despliegue completado exitosamente: $($newInfo.releaseTag) [$($newInfo.channel)] (ID: $($newInfo.deploymentId))" -ForegroundColor Green
}

function Invoke-RemoteUpdate([object]$ReleaseObj) {
    $asset = $ReleaseObj.assets | Where-Object { $_.name -like "*.zip" } | Select-Object -First 1
    if ($null -eq $asset) {
        throw "El Release $($ReleaseObj.tag_name) no contiene un paquete .zip adjunto."
    }

    $tempZip = Join-Path ([System.IO.Path]::GetTempPath()) $asset.name
    $headers = Get-GitHubHeaders
    $headers["Accept"] = "application/octet-stream"

    Write-Host "Descargando paquete $($asset.name) del Release $($ReleaseObj.tag_name)..." -ForegroundColor Cyan
    Invoke-WebRequest -Uri $asset.url -Headers $headers -OutFile $tempZip

    Install-PackageFromZip -ZipFile $tempZip -TargetReleaseLabel $ReleaseObj.tag_name
    Remove-Item -Path $tempZip -Force -ErrorAction SilentlyContinue
}

switch ($Action) {
    "status" {
        Show-Status
    }
    "history" {
        Show-History
    }
    "install-service" {
        $exePath = Join-Path $InstallPath "FE.exe"
        if (-not (Test-Path $exePath)) {
            throw "No se encontro $exePath. Ejecute primero: .\Manage-WorkerFE.ps1 -Action update -Channel rc"
        }
        $existingSvc = Get-Service -Name $ResolvedServiceName -ErrorAction SilentlyContinue
        if ($existingSvc) {
            Write-Host "El servicio '$ResolvedServiceName' ya existe (Estado: $($existingSvc.Status))." -ForegroundColor Yellow
        } else {
            Write-Host "Registrando servicio de Windows '$ResolvedServiceName' apuntando a $exePath..." -ForegroundColor Cyan
            New-Service -Name $ResolvedServiceName -BinaryPathName "`"$exePath`"" -DisplayName "Worker Facturacion Electronica ($ResolvedServiceName)" -StartupType Automatic | Out-Null
            Write-Host "Servicio '$ResolvedServiceName' creado exitosamente." -ForegroundColor Green
        }
        $currentSettings = Get-AutoUpdateSettings
        Save-AutoUpdateSettings -TargetChannel $currentSettings.subscribedChannel -Interval $currentSettings.intervalMinutes -SvcName $ResolvedServiceName
        Show-Status
    }
    "set-channel" {
        $targetChannel = if ([string]::IsNullOrWhiteSpace($Channel)) { "stable" } else { $Channel.ToLower() }
        $currentSettings = Get-AutoUpdateSettings
        Save-AutoUpdateSettings -TargetChannel $targetChannel -Interval $currentSettings.intervalMinutes -SvcName $ResolvedServiceName
        Write-Host "Canal suscrito actualizado a: $($targetChannel.ToUpper())" -ForegroundColor Green
        Show-Status
    }
    "register-autoupdate" {
        $targetChannel = Get-EffectiveChannel
        Save-AutoUpdateSettings -TargetChannel $targetChannel -Interval $IntervalMinutes -SvcName $ResolvedServiceName

        $scriptPath = Join-Path $InstallPath "Manage-WorkerFE.ps1"
        if (-not (Test-Path $scriptPath)) {
            Copy-Item -Path $PSCommandPath -Destination $scriptPath -Force
        }

        $argString = "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`" -Action auto-update -ServiceName `"$ResolvedServiceName`" -InstallPath `"$InstallPath`""
        $taskAction = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $argString
        $taskTrigger = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes)
        $taskPrincipal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
        $taskSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable

        Register-ScheduledTask -TaskName $TaskName -Action $taskAction -Trigger $taskTrigger -Principal $taskPrincipal -Settings $taskSettings -Force | Out-Null
        Write-Host "Tarea programada '$TaskName' registrada con exito." -ForegroundColor Green
        Write-Host "  Servicio       : $ResolvedServiceName" -ForegroundColor Yellow
        Write-Host "  Canal vigilado : $($targetChannel.ToUpper())" -ForegroundColor Yellow
        Write-Host "  Intervalo      : Cada $IntervalMinutes minutos" -ForegroundColor Yellow
        Show-Status
    }
    "unregister-autoupdate" {
        if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
            Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
            Write-Host "Tarea programada '$TaskName' eliminada con exito." -ForegroundColor Yellow
        } else {
            Write-Host "No existe la tarea programada '$TaskName'." -ForegroundColor DarkYellow
        }
    }
    "auto-update" {
        $targetChannel = Get-EffectiveChannel
        $local = Get-LocalReleaseInfo
        $remote = Get-RemoteReleaseInfo -TargetTag "latest" -TargetChannel $targetChannel

        if ($null -eq $remote) {
            Write-Host "[AUTO-UPDATE] No se pudo consultar GitHub Releases para el canal '$targetChannel'." -ForegroundColor DarkYellow
            break
        }

        if ($local.releaseTag -eq $remote.tag_name) {
            Write-Host "[AUTO-UPDATE] Sin cambios. El servidor ya tiene instalado $($local.releaseTag) (Canal: $targetChannel)." -ForegroundColor Green
            break
        }

        Write-Host "[AUTO-UPDATE] Nueva version detectada en canal '$targetChannel': $($local.releaseTag) -> $($remote.tag_name). Actualizando..." -ForegroundColor Cyan
        Invoke-RemoteUpdate -ReleaseObj $remote
    }
    "update" {
        if (-not [string]::IsNullOrWhiteSpace($LocalZipPath)) {
            if (-not (Test-Path $LocalZipPath)) {
                throw "No se encontro el archivo ZIP local: $LocalZipPath"
            }
            Install-PackageFromZip -ZipFile $LocalZipPath -TargetReleaseLabel $Tag
            Show-Status
            break
        }

        $targetChannel = Get-EffectiveChannel
        Write-Host "Consultando Release '$Tag' (Canal: $targetChannel) en GitHub ($GitHubRepo)..." -ForegroundColor Cyan
        $release = Get-RemoteReleaseInfo -TargetTag $Tag -TargetChannel $targetChannel
        if ($null -eq $release) {
            throw "No se pudo encontrar el Release '$Tag' en $GitHubRepo. Verifique que el Release exista o configure GITHUB_TOKEN si el repositorio es privado."
        }

        Invoke-RemoteUpdate -ReleaseObj $release
        Show-Status
    }
    "rollback" {
        if (-not (Test-Path $BackupRoot)) {
            throw "No existe el directorio de respaldos: $BackupRoot"
        }
        $latestBackup = Get-ChildItem -Path $BackupRoot -Filter "WorkerFE_*.zip" | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($null -eq $latestBackup) {
            throw "No se encontraron respaldos en $BackupRoot"
        }
        Write-Host "Restaurando desde respaldo: $($latestBackup.FullName)..." -ForegroundColor Yellow
        Install-PackageFromZip -ZipFile $latestBackup.FullName -TargetReleaseLabel "ROLLBACK"
        Show-Status
    }
}
