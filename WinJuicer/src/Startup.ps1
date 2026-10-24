# Programs that start with Windows. Disabling goes through StartupApproved, the
# same switch Task Manager flips: nothing is deleted, the entry stays where the
# program put it, and Task Manager shows the same state Win Juicer does.

$script:StartupApprovedBase = 'Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved'

function Get-JuicerStartupSources {
    @(
        @{ Key = 'hkcu-run'; Source = 'Registro (usuario)'; Path = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Run'; Approved = "HKCU\$script:StartupApprovedBase\Run" }
        @{ Key = 'hklm-run'; Source = 'Registro (equipo)'; Path = 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'; Approved = "HKLM\$script:StartupApprovedBase\Run" }
        @{ Key = 'hklm-run32'; Source = 'Registro (equipo, 32 bits)'; Path = 'HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'; Approved = "HKLM\$script:StartupApprovedBase\Run32" }
    )
}

# Task Manager's format: 12 bytes, the first odd when disabled, then the
# FILETIME of when it was disabled.
function New-JuicerApprovedBytes {
    param([bool]$Enabled)
    $bytes = New-Object byte[] 12
    if ($Enabled) {
        $bytes[0] = 2
    } else {
        $bytes[0] = 3
        [Array]::Copy([BitConverter]::GetBytes((Get-Date).ToFileTimeUtc()), 0, $bytes, 4, 8)
    }
    , $bytes
}

function Test-JuicerApprovedEnabled {
    param($Reg)
    if ($null -eq $Reg -or $Reg.Kind -ne 'Binary' -or $Reg.Value.Count -eq 0) { return $true }
    ($Reg.Value[0] -band 1) -eq 0
}

function Get-JuicerShortcutTarget {
    param([string]$Path)
    if ($Path -notlike '*.lnk' -or -not (Test-JuicerWindows)) { return $Path }
    try {
        $s = (New-Object -ComObject WScript.Shell).CreateShortcut($Path)
        return (($s.TargetPath + ' ' + $s.Arguments).Trim())
    } catch {
        return $Path
    }
}

function Get-JuicerStartupItems {
    param([switch]$NoTasks)
    $items = New-Object System.Collections.ArrayList

    foreach ($src in (Get-JuicerStartupSources)) {
        foreach ($name in (Get-JuicerRegValueNames $src.Path)) {
            if ($name -eq '') { continue }
            $cmd = Read-JuicerReg $src.Path $name
            [void]$items.Add(@{
                    Id = "$($src.Key):$name"; Name = $name; Source = $src.Source; Kind = 'Registro'
                    Command = [string]$cmd.Value; ApprovedPath = $src.Approved; ApprovedName = $name
                    Enabled = (Test-JuicerApprovedEnabled (Read-JuicerReg $src.Approved $name))
                })
        }
    }

    if (Test-JuicerWindows) {
        $folders = @(
            @{ Key = 'carpeta-usuario'; Source = 'Carpeta Inicio (usuario)'; Dir = [Environment]::GetFolderPath('Startup'); Approved = "HKCU\$script:StartupApprovedBase\StartupFolder" }
            @{ Key = 'carpeta-comun'; Source = 'Carpeta Inicio (todos)'; Dir = [Environment]::GetFolderPath('CommonStartup'); Approved = "HKLM\$script:StartupApprovedBase\StartupFolder" }
        )
        foreach ($f in $folders) {
            if (-not $f.Dir -or -not (Test-Path -LiteralPath $f.Dir)) { continue }
            foreach ($file in (Get-ChildItem -LiteralPath $f.Dir -File -Force -ErrorAction SilentlyContinue)) {
                if ($file.Name -eq 'desktop.ini') { continue }
                [void]$items.Add(@{
                        Id = "$($f.Key):$($file.Name)"; Name = [IO.Path]::GetFileNameWithoutExtension($file.Name); Source = $f.Source; Kind = 'Carpeta'
                        Command = (Get-JuicerShortcutTarget $file.FullName); ApprovedPath = $f.Approved; ApprovedName = $file.Name
                        Enabled = (Test-JuicerApprovedEnabled (Read-JuicerReg $f.Approved $file.Name))
                    })
            }
        }

        if (-not $NoTasks) {
            # Updaters and launchers like to hide here instead of in Run.
            $tasks = @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object {
                    $_.TaskPath -notlike '\Microsoft\*' -and
                    @($_.Triggers | Where-Object { $_.CimClass.CimClassName -in 'MSFT_TaskLogonTrigger', 'MSFT_TaskBootTrigger' }).Count -gt 0
                })
            foreach ($t in $tasks) {
                $a = @($t.Actions)[0]
                $cmd = if ($a -and $a.Execute) { ($a.Execute + ' ' + $a.Arguments).Trim() } else { '' }
                [void]$items.Add(@{
                        Id = "tarea:$($t.TaskPath)$($t.TaskName)"; Name = $t.TaskName; Source = 'Tarea programada'; Kind = 'Tarea'
                        Command = $cmd; TaskPath = $t.TaskPath; TaskName = $t.TaskName; Enabled = ($t.State -ne 'Disabled')
                    })
            }
        }
    }
    $items.ToArray()
}

function New-JuicerStartupTweak {
    param([Parameter(Mandatory)][hashtable]$Item, [Parameter(Mandatory)][bool]$Enable)
    $verb = if ($Enable) { 'inicio-on' } else { 'inicio-off' }
    $title = if ($Enable) { "Inicio: activar $($Item.Name)" } else { "Inicio: desactivar $($Item.Name)" }
    if ($Item.Kind -eq 'Tarea') {
        $action = @{ Type = 'Task'; Path = $Item.TaskPath; Name = $Item.TaskName; Enabled = $Enable }
    } else {
        $action = @{
            Type = 'Registry'; Path = $Item.ApprovedPath; Name = $Item.ApprovedName; Kind = 'Binary'
            Value = (New-JuicerApprovedBytes $Enable)
            Label = '{0} al iniciar Windows: {1}' -f $Item.Name, $(if ($Enable) { 'sí' } else { 'no' })
        }
        if ($Enable) { $action.Ok = { param($c) Test-JuicerApprovedEnabled $c } }
        else { $action.Ok = { param($c) -not (Test-JuicerApprovedEnabled $c) } }
    }
    @{
        Id = "${verb}:$($Item.Id)"; Title = $title; Category = 'Inicio'; Level = 1; Impact = 'Medio'; Reboot = 'Sesion'
        What = $title; Gain = ''; Cost = ''; Actions = @($action)
    }
}

# Turning an entry back to how it was undoes Win Juicer's own change instead of
# stacking a second one on top, so the journal only ever holds what is
# different from the original.
function Set-JuicerStartupItem {
    param([Parameter(Mandatory)][hashtable]$Item, [Parameter(Mandatory)][bool]$Enable)
    $opposite = if ($Enable) { "inicio-off:$($Item.Id)" } else { "inicio-on:$($Item.Id)" }
    if (Get-JuicerJournalEntry (Read-JuicerJournal) $opposite) { return (Undo-JuicerTweak $opposite) }
    Invoke-JuicerTweak (New-JuicerStartupTweak $Item $Enable)
}
