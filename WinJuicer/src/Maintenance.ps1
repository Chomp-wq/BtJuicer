# One-off maintenance. Unlike tweaks these are not reversible, so they only
# remove what Windows regenerates or never needs again. Shader caches and
# Prefetch are left alone on purpose: emptying them makes the next game session
# stutter and the next boot slower.

# Walks a folder without ever following a junction or symlink, so a link left in
# a temp folder can never lead the cleanup somewhere else.
function Get-JuicerTreeItems {
    param([string]$Path)
    $files = New-Object System.Collections.ArrayList
    $dirs = New-Object System.Collections.ArrayList
    $stack = New-Object System.Collections.Stack
    $stack.Push($Path)
    while ($stack.Count -gt 0) {
        $d = $stack.Pop()
        foreach ($e in (Get-ChildItem -LiteralPath $d -Force -ErrorAction SilentlyContinue)) {
            if ($e.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
            if ($e.PSIsContainer) { [void]$dirs.Add($e); $stack.Push($e.FullName) } else { [void]$files.Add($e) }
        }
    }
    @{ Files = $files; Dirs = $dirs }
}

# A misconfigured %TEMP% pointing at C:\ or the profile must never turn a
# cleanup into a wipe.
function Test-JuicerCleanupPath {
    param([string]$Path)
    if (-not $Path) { return $false }
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    if ($full.Length -le 3 -or $full.Split([char[]]'\/', [StringSplitOptions]::RemoveEmptyEntries).Count -lt 2) { return $false }
    foreach ($v in $env:SystemRoot, $env:USERPROFILE, $env:ProgramData, $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:LOCALAPPDATA, $env:APPDATA) {
        if ($v -and $full -eq [IO.Path]::GetFullPath($v).TrimEnd('\', '/')) { return $false }
    }
    $true
}

function Clear-JuicerFolder {
    param([Parameter(Mandatory)][string]$Path, [int]$OlderThanHours = 24)
    $r = @{ Freed = [int64]0; Skipped = 0 }
    if (-not (Test-Path -LiteralPath $Path)) { return $r }
    if (-not (Test-JuicerCleanupPath $Path)) { throw "Me niego a vaciar «$Path»: no parece una carpeta de temporales." }
    $cutoff = (Get-Date).AddHours(-$OlderThanHours)
    $tree = Get-JuicerTreeItems $Path
    foreach ($f in $tree.Files) {
        if ($f.LastWriteTime -gt $cutoff) { $r.Skipped++; continue }
        try {
            $len = $f.Length
            Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop
            $r.Freed += $len
        } catch {
            $r.Skipped++
        }
    }
    # Deepest first, and only once empty.
    foreach ($d in ($tree.Dirs | Sort-Object { $_.FullName.Length } -Descending)) {
        if (-not (Get-ChildItem -LiteralPath $d.FullName -Force -ErrorAction SilentlyContinue)) {
            Remove-Item -LiteralPath $d.FullName -Force -ErrorAction SilentlyContinue
        }
    }
    $r
}

# Whether Windows is waiting for a restart to finish installing updates. The downloaded update
# files are what that install still needs, so they are left alone until then.
function Test-JuicerRebootPending {
    foreach ($k in 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
        'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') {
        try { if (Test-JuicerRegKey $k) { return $true } } catch { Write-Verbose "Sin ${k}: $_" }
    }
    $false
}

# What Clear-JuicerFolder would free, without deleting anything: the same walk (never through
# a link), the same age rule and the same path guard. A folder the guard refuses is reported
# as refused, not counted.
function Measure-JuicerFolder {
    param([Parameter(Mandatory)][string]$Path, [int]$OlderThanHours = 24)
    $r = @{ Bytes = [int64]0; Files = 0; Skipped = 0; Refused = $false }
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return $r }
    if (-not (Test-JuicerCleanupPath $Path)) { $r.Refused = $true; return $r }
    $cutoff = (Get-Date).AddHours(-$OlderThanHours)
    foreach ($f in (Get-JuicerTreeItems $Path).Files) {
        if ($f.LastWriteTime -gt $cutoff) { $r.Skipped++; continue }
        $r.Bytes += [int64]$f.Length
        $r.Files++
    }
    $r
}

function Get-JuicerCleanupTargets {
    $wer = Join-Path $env:ProgramData 'Microsoft\Windows\WER'
    @(
        @{ Name = 'Temporales de tu usuario'; Path = $env:TEMP; Hours = 24 }
        @{ Name = 'Temporales de Windows'; Path = (Join-Path $env:SystemRoot 'Temp'); Hours = 24 }
        @{ Name = 'Informes de errores enviados'; Path = (Join-Path $wer 'ReportArchive'); Hours = 0 }
        @{ Name = 'Informes de errores pendientes'; Path = (Join-Path $wer 'ReportQueue'); Hours = 0 }
        @{ Name = 'Volcados de aplicaciones'; Path = (Join-Path $env:LOCALAPPDATA 'CrashDumps'); Hours = 0 }
        @{ Name = 'Descargas de Windows Update'; Path = (Join-Path $env:SystemRoot 'SoftwareDistribution\Download'); Hours = 0; Services = @('wuauserv', 'bits') }
    )
}

# What a cleanup would free, per target and in total, before doing it. Targets: replaceable
# for the tests. A target with Services (the update downloads) is left out while a restart
# is pending, and says why.
function Get-JuicerCleanupPreview {
    # DeliveryCache: whether the real cleanup will empty the Delivery Optimization cache (it does
    # when the cmdlet exists, Windows 10 1809 and later). Windows owns that folder and the cleanup
    # calls its cmdlet instead of deleting files, so the preview says so rather than guess a size.
    param([object[]]$Targets = @(Get-JuicerCleanupTargets), [bool]$RebootPending = (Test-JuicerRebootPending), [bool]$DeliveryCache = [bool](Get-Command 'Delete-DeliveryOptimizationCache' -ErrorAction SilentlyContinue))
    $items = @(foreach ($t in $Targets) {
            $skip = ''
            $m = @{ Bytes = [int64]0; Files = 0; Skipped = 0; Refused = $false }
            if (@($t.Services | Where-Object { $_ }).Count -gt 0 -and $RebootPending) {
                $skip = 'hay un reinicio pendiente de Windows Update: no se toca hasta reiniciar'
            } else {
                try { $m = Measure-JuicerFolder -Path $t.Path -OlderThanHours $t.Hours } catch { Write-JuicerLog "No se pudo medir $($t.Path): $_" }
                if ($m.Refused) { $skip = 'no parece una carpeta de temporales: no se toca' }
            }
            @{ Name = $t.Name; Path = $t.Path; Bytes = $m.Bytes; Skipped = $m.Skipped; Note = $skip }
        })
    if ($DeliveryCache) {
        $items += @{ Name = 'Caché de Optimización de distribución'; Path = ''; Bytes = [int64]0; Skipped = 0; Note = ''; Unmeasured = 'Windows la vacía; tamaño no medido' }
    }
    @{ Items = $items; Total = [int64](($items | ForEach-Object { $_.Bytes } | Measure-Object -Sum).Sum) }
}

# The lines of the question before cleaning, for the window and the console alike.
function Format-JuicerCleanupPreview {
    param([hashtable]$Preview)
    $lines = foreach ($i in $Preview.Items) {
        if ($i.Note) { '· {0}: sin tocar ({1})' -f $i.Name, $i.Note }
        elseif ($i.Unmeasured) { '· {0}: {1}' -f $i.Name, $i.Unmeasured }
        else { '· {0}: {1}' -f $i.Name, (Format-JuicerBytes $i.Bytes) }
    }
    $unmeasured = if (@($Preview.Items | Where-Object { $_.Unmeasured }).Count -gt 0) { ' (sin contar lo no medido)' } else { '' }
    @($lines) + ('Total: {0}{1}. Lo reciente o en uso no se toca, y la caché de shaders tampoco.' -f (Format-JuicerBytes $Preview.Total), $unmeasured)
}

function Invoke-JuicerCleanup {
    $results = @()
    $reboot = Test-JuicerRebootPending
    foreach ($t in (Get-JuicerCleanupTargets)) {
        # The update downloads wait for the restart Windows is asking for.
        if ($reboot -and @($t.Services | Where-Object { $_ }).Count -gt 0) {
            $results += @{ Name = $t.Name; Freed = [int64]0; Skipped = 0; Note = 'sin tocar: hay un reinicio pendiente' }
            continue
        }
        $stopped = @()
        foreach ($s in @($t.Services)) {
            if (-not $s) { continue }
            $svc = Get-Service -Name $s -ErrorAction SilentlyContinue
            if ($svc -and $svc.Status -eq 'Running') {
                try { Stop-Service -Name $s -Force -ErrorAction Stop; $stopped += $s } catch { Write-JuicerLog "No se pudo detener ${s}: $_" }
            }
        }
        $r = Clear-JuicerFolder -Path $t.Path -OlderThanHours $t.Hours
        foreach ($s in $stopped) { try { Start-Service -Name $s -ErrorAction Stop } catch { Write-JuicerLog "No se pudo volver a arrancar ${s}: $_" } }
        $results += @{ Name = $t.Name; Freed = $r.Freed; Skipped = $r.Skipped; Note = '' }
    }

    # Windows 10 1809 and later; looked up rather than called by name so older
    # builds just skip it.
    $doCache = Get-Command 'Delete-DeliveryOptimizationCache' -ErrorAction SilentlyContinue
    if ($doCache) {
        try {
            & $doCache -Force -ErrorAction Stop
            $results += @{ Name = 'Caché de Optimización de distribución'; Freed = -1; Skipped = 0; Note = '' }
        } catch {
            Write-JuicerLog "No se pudo vaciar la caché de Optimización de distribución: $_"
        }
    }
    Write-JuicerLog ('Limpieza: ' + (($results | ForEach-Object { '{0} {1}' -f $_.Name, $_.Freed }) -join '; '))
    $results
}

# SSDs get a retrim and hard disks a defrag: Optimize-Volume picks the right
# one per drive, the same as Windows' weekly task.
function Get-JuicerOptimizeVolumes {
    @(Get-Volume -ErrorAction SilentlyContinue | Where-Object { $_.DriveType -eq 'Fixed' -and $_.DriveLetter -and $_.FileSystem -in 'NTFS', 'ReFS' })
}

# The question to ask before optimizing: a hard disk gets a full defrag, which
# can take hours; empty when there is none (SSD retrims are quick).
function Get-JuicerOptimizeWarning {
    $hdd = @(foreach ($v in (Get-JuicerOptimizeVolumes)) {
            $m = Get-JuicerDriveMedia "$($v.DriveLetter):"
            if ($m -and $m.Media -eq 'HDD') { "$($v.DriveLetter):" }
        })
    if ($hdd.Count -eq 0) { return '' }
    "Se va a desfragmentar $($hdd -join ', '), que es un disco duro: puede tardar horas en un disco duro. Puedes seguir usando el PC, pero irá más lento. Los SSD sólo se reoptimizan (TRIM), en segundos."
}

function Invoke-JuicerDriveOptimize {
    $results = @()
    foreach ($v in (Get-JuicerOptimizeVolumes)) {
        $media = Get-JuicerDriveMedia "$($v.DriveLetter):"
        try {
            Optimize-Volume -DriveLetter $v.DriveLetter -ErrorAction Stop
            $results += @{ Drive = "$($v.DriveLetter):"; Media = $(if ($media) { $media.Media } else { '' }); Ok = $true; Message = '' }
        } catch {
            $results += @{ Drive = "$($v.DriveLetter):"; Media = $(if ($media) { $media.Media } else { '' }); Ok = $false; Message = "$_" }
        }
    }
    $results
}

# DISM and SFC print their own progress: straight to the screen, so it is not
# swallowed as the function's output.
function Invoke-JuicerComponentCleanup {
    & dism.exe /Online /Cleanup-Image /StartComponentCleanup | Out-Host
    @{ Dism = $LASTEXITCODE }
}

function Invoke-JuicerSystemRepair {
    & dism.exe /Online /Cleanup-Image /RestoreHealth | Out-Host
    $dism = $LASTEXITCODE
    & sfc.exe /scannow | Out-Host
    @{ Dism = $dism; Sfc = $LASTEXITCODE }
}
