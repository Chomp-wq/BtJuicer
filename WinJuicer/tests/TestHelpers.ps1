# Shared by the test files: a fresh module, a throwaway journal, and an
# in-memory machine with a fake powercfg and bcdedit behind it.

function Initialize-JuicerTest {
    $env:WINJUICER_HOME = Join-Path ([IO.Path]::GetTempPath()) ('wjtest-' + [guid]::NewGuid().ToString('N'))
    Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'WinJuicer.psm1') -Force
}

# A tiny model of the machine powercfg and bcdedit talk to. Returned so tests
# can look at it; the responder closes over it.
function New-FakeMachine {
    $fake = @{
        Active = '381b4222-f694-41f0-9685-ff5bb260df2e'
        Plans  = [System.Collections.ArrayList]@('381b4222-f694-41f0-9685-ff5bb260df2e', '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c')
        Bcd    = @{}
        Hibernate = $false
        HibernateType = 'full'
    }
    $run = {
        param($File, $Arguments)
        $a = @($Arguments)
        $out = ''
        $code = 0
        if ($File -eq 'powercfg.exe') {
            switch ($a[0]) {
                '/getactivescheme' { $out = "GUID del plan de energía: $($fake.Active)  (Equilibrado)" }
                '/list' { $out = (@($fake.Plans) | ForEach-Object { "GUID del plan de energía: $_  (Plan)" }) -join "`n" }
                '/duplicatescheme' {
                    if ($fake.Plans -contains $a[1]) { [void]$fake.Plans.Add($a[2]); $out = "GUID del plan de energía: $($a[2])" } else { $code = 1 }
                }
                '/setactive' { if ($fake.Plans -contains $a[1]) { $fake.Active = $a[1] } else { $code = 1; $out = 'No existe' } }
                '/delete' { if ($fake.Active -eq $a[1]) { $code = 1 } else { $fake.Plans.Remove($a[1]) } }
                '/hibernate' {
                    if ($a[1] -eq 'on') { $fake.Hibernate = $true }
                    elseif ($a[1] -eq 'off') { $fake.Hibernate = $false }
                    elseif ($a[1] -eq '/type') { $fake.HibernateType = $a[2] }
                    $key = $fake.State.Keys['hklm\system\currentcontrolset\control\power']
                    $key.Values['hibernateenabled'] = @{ Name = 'HibernateEnabled'; Kind = 'DWord'; Value = [uint32]([int]$fake.Hibernate) }
                }
            }
        } elseif ($File -eq 'bcdedit.exe') {
            switch ($a[0]) {
                '/enum' {
                    $lines = @('Cargador de arranque de Windows', '-------------------------------', 'identificador           {current}', 'path                    \Windows\system32\winload.efi')
                    foreach ($k in $fake.Bcd.Keys) { $lines += ('{0,-24}{1}' -f $k, $fake.Bcd[$k]) }
                    $out = $lines -join "`r`n"
                }
                '/set' { $fake.Bcd[$a[2]] = $a[3] }
                '/deletevalue' { $fake.Bcd.Remove($a[2]) }
            }
        } else {
            $code = 1
        }
        [pscustomobject]@{ Code = $code; Output = $out }
    }.GetNewClosure()

    $backend = New-JuicerMemoryBackend -Run $run
    $fake.State = $backend.State
    Use-JuicerBackend $backend
    Write-JuicerReg 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion' 'CurrentBuildNumber' 'String' '26100'
    Write-JuicerReg 'HKLM\SYSTEM\CurrentControlSet\Control\Power' 'HibernateEnabled' 'DWord' 0
    @{ Backend = $backend; Fake = $fake }
}

# Everything the in-memory machine holds, in a stable order, so two states can
# be compared as strings.
function Get-MachineSnapshot {
    param([hashtable]$Machine)
    $s = $Machine.Backend.State
    $lines = New-Object System.Collections.ArrayList
    foreach ($k in ($s.Keys.Keys | Sort-Object)) {
        [void]$lines.Add("K $k")
        $vals = $s.Keys[$k].Values
        foreach ($n in ($vals.Keys | Sort-Object)) {
            $v = $vals[$n]
            [void]$lines.Add(('V {0}|{1}|{2}|{3}' -f $k, $v.Name, $v.Kind, (@($v.Value) -join ',')))
        }
    }
    foreach ($n in ($s.Services.Keys | Sort-Object)) { [void]$lines.Add(('S {0}|{1}|{2}' -f $n, $s.Services[$n].Start, $s.Services[$n].Running)) }
    foreach ($n in ($s.Spi.Keys | Sort-Object)) { [void]$lines.Add(('P {0}|{1}' -f $n, $s.Spi[$n])) }
    foreach ($n in ($s.Defender | Sort-Object)) { [void]$lines.Add("D $n") }
    foreach ($n in ($s.Tasks.Keys | Sort-Object)) { [void]$lines.Add(('T {0}|{1}' -f $n, $s.Tasks[$n].Enabled)) }
    $f = $Machine.Fake
    [void]$lines.Add("F active=$($f.Active) plans=$((@($f.Plans) | Sort-Object) -join ',') hib=$($f.Hibernate)/$($f.HibernateType)")
    foreach ($k in ($f.Bcd.Keys | Sort-Object)) { [void]$lines.Add("B $k=$($f.Bcd[$k])") }
    $lines -join "`n"
}
