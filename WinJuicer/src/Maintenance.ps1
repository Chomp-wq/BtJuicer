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

function Invoke-JuicerCleanup {
    $results = @()
    foreach ($t in (Get-JuicerCleanupTargets)) {
        $stopped = @()
        foreach ($s in @($t.Services)) {
            if (-not $s) { continue }
            $svc = Get-Service -Name $s -ErrorAction SilentlyContinue
            if ($svc -and $svc.Status -eq 'Running') {
                try { Stop-Service -Name $s -Force -ErrorAction Stop; $stopped += $s } catch { Write-JuicerLog "No se pudo detener ${s}: $_" }
            }
        }
        $r = Clear-JuicerFolder -Path $t.Path -OlderThanHours $t.Hours
        foreach ($s in $stopped) { Start-Service -Name $s -ErrorAction SilentlyContinue }
        $results += @{ Name = $t.Name; Freed = $r.Freed; Skipped = $r.Skipped }
    }

    # Windows 10 1809 and later; looked up rather than called by name so older
    # builds just skip it.
    $doCache = Get-Command 'Delete-DeliveryOptimizationCache' -ErrorAction SilentlyContinue
    if ($doCache) {
        try {
            & $doCache -Force -ErrorAction Stop
            $results += @{ Name = 'Caché de Optimización de distribución'; Freed = -1; Skipped = 0 }
        } catch {
            Write-JuicerLog "No se pudo vaciar la caché de Optimización de distribución: $_"
        }
    }
    Write-JuicerLog ('Limpieza: ' + (($results | ForEach-Object { '{0} {1}' -f $_.Name, $_.Freed }) -join '; '))
    $results
}

# SSDs get a retrim and hard disks a defrag: Optimize-Volume picks the right
# one per drive, the same as Windows' weekly task.
function Invoke-JuicerDriveOptimize {
    $results = @()
    $volumes = @(Get-Volume -ErrorAction SilentlyContinue | Where-Object { $_.DriveType -eq 'Fixed' -and $_.DriveLetter -and $_.FileSystem -in 'NTFS', 'ReFS' })
    foreach ($v in $volumes) {
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
