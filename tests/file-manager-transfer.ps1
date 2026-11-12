. (Join-Path $PSScriptRoot 'file-manager-test-support.ps1')
$download = [scriptblock]::Create((Get-FileManagerAction 'doDownload').Replace('New-Object System.Windows.Forms.FolderBrowserDialog', 'New-TestFolderDialog'))
$upload = [scriptblock]::Create((Get-FileManagerAction 'doUpload'))
$dlg = @{ Visible=$true; IsDisposed=$false }
$state = @{ Serial='fixture'; Path='/sdcard' }
$lblInfo = @{}; $progState = @{}
$beginProgress = {}; $endProgress = {}; $setDeviceLock = {}; $refresh = {}
$cGreen = [Drawing.Color]::Green; $cRed = [Drawing.Color]::Red
$fixture = @{}
function Reset-Fixture([string]$Name) {
    $fixture.Clear()
    $fixture.Prompts=0; $fixture.Errors=0; $fixture.Transfers=0; $fixture.Checks=0
    $fixture.Choices=@('overwrite'); $fixture.Remote=@{}; $fixture.Closed=$false
    $dlg.Visible=$true; $dlg.IsDisposed=$false
    $path = Join-Path $root $Name
    [void][IO.Directory]::CreateDirectory($path)
    return $path
}
function New-TestFolderDialog {
    $dialog = [pscustomobject]@{ SelectedPath=$selected; Description=''; ShowNewFolderButton=$false }
    $dialog | Add-Member ScriptMethod ShowDialog { param($owner) return [Windows.Forms.DialogResult]::OK }
    $dialog | Add-Member ScriptMethod Dispose {}
    return $dialog
}
function Show-ResultDialog {
    Check (-not $dlg.IsDisposed) 'Result popup attempted after close'
    $fixture.Errors++
    return 'ok'
}
function Fm-ConfirmOverwrite {
    param($Owner, $Action, $Names, $Where)
    Check (-not $dlg.IsDisposed) 'Confirmation attempted after close'
    $index = [Math]::Min($fixture.Prompts, ($fixture.Choices.Count - 1))
    $fixture.Prompts++
    $fixture.LastNames = @($Names)
    return $fixture.Choices[$index]
}
function Invoke-FmTask {
    param($Owner, $Work, $Inputs, $Functions)
    $shouldClose = ($fixture.ClosePhase -eq 'snapshot' -and $Inputs.ContainsKey('Paths')) -or
                   ($fixture.ClosePhase -eq 'conflicts' -and $Inputs.From -and -not $Inputs.ContainsKey('To')) -or
                   ($fixture.ClosePhase -eq 'copy' -and $Inputs.ContainsKey('To'))
    if ($Owner -and $shouldClose -and -not $fixture.Closed) {
        $fixture.Closed=$true; $dlg.IsDisposed=$true; $dlg.Visible=$false
        return [pscustomobject]@{ Ok=$false; Cancelled=$true }
    }
    # Injecting after the last confirmation verifies the writer's independent protection.
    if ($fixture.RaceOnCommit -and $Inputs.ContainsKey('To') -and $Inputs.To.EndsWith('b.txt')) {
        [IO.File]::WriteAllText($Inputs.To, 'race-original')
    }
    $Control = @{ Cancelled=$false }
    return (& $Work)
}
function Fm-Transfer {
    param($Argv, $dlg, $status, $tip, $prog, $WorkingDirectory)
    $fixture.Transfers++
    if ($Argv[2] -eq 'push') { return @{ Ok=$true; Aborted=$false; Detail='' } }
    if ($fixture.InjectLate -and $fixture.Transfers -eq 1) {
        [IO.File]::WriteAllText((Join-Path $physical 'b.txt'), 'late-original')
    }
    [IO.File]::WriteAllText((Join-Path $WorkingDirectory $Argv[-1]), 'new-' + [IO.Path]::GetFileName($Argv[-2]))
    if ($fixture.ClosePhase -eq 'transfer') {
        $fixture.Closed=$true; $dlg.IsDisposed=$true; $dlg.Visible=$false
        return @{ Ok=$false; Aborted=$true; Detail='' }
    }
    return @{ Ok=$true; Aborted=$false; Detail='' }
}
$files = @(
    [pscustomobject]@{ Tag=@{ Name='a.txt'; Path='/sdcard/a.txt'; IsDir=$false; IsLink=$false; Size='8' } },
    [pscustomobject]@{ Tag=@{ Name='b.txt'; Path='/sdcard/b.txt'; IsDir=$false; IsLink=$false; Size='8' } }
)
foreach ($case in @('new', 'overwrite', 'skip', 'cancel', 'late-yes', 'late-skip', 'late-cancel', 'race', 'linked-root')) {
    $physical = Reset-Fixture $case
    $selected = $physical
    if ($case -eq 'linked-root') {
        $selected = Join-Path $root 'chosen-link'
        [void](New-Item -ItemType Junction -Path $selected -Target $physical)
    }
    if ($case -notin @('new', 'race', 'linked-root')) { [IO.File]::WriteAllText((Join-Path $physical 'a.txt'), 'old-a') }
    $fixture.InjectLate = $case.StartsWith('late-')
    $fixture.RaceOnCommit = ($case -eq 'race')
    if ($case -eq 'skip') { $fixture.Choices=@('skip') }
    if ($case -eq 'cancel') { $fixture.Choices=@('cancel') }
    if ($case -eq 'late-skip') { $fixture.Choices=@('overwrite', 'skip') }
    if ($case -eq 'late-cancel') { $fixture.Choices=@('overwrite', 'cancel') }
    $lv = @{ SelectedItems=$files }
    & $download
    $a = Join-Path $physical 'a.txt'; $b = Join-Path $physical 'b.txt'
    if ($case -eq 'cancel') {
        Check ($fixture.Transfers -eq 0 -and [IO.File]::ReadAllText($a) -eq 'old-a') 'Cancel changed an existing file'
    } elseif ($case -eq 'skip') {
        Check ($fixture.Transfers -eq 1 -and [IO.File]::ReadAllText($a) -eq 'old-a' -and [IO.File]::ReadAllText($b) -eq 'new-b.txt') 'Skip prevented other downloads'
    } elseif ($case -in @('late-skip', 'late-cancel')) {
        Check ($fixture.Prompts -eq 2 -and [IO.File]::ReadAllText($a) -eq 'new-a.txt' -and [IO.File]::ReadAllText($b) -eq 'late-original') 'Late target inherited unrelated authorization'
    } elseif ($case -eq 'race') {
        Check ($fixture.Errors -eq 1 -and [IO.File]::ReadAllText($b) -eq 'race-original') 'Writer overwrote an unapproved target'
    } else {
        Check ($fixture.Errors -eq 0 -and [IO.File]::ReadAllText($a) -eq 'new-a.txt' -and [IO.File]::ReadAllText($b) -eq 'new-b.txt') "Download failed: $case"
    }
    if ($fixture.InjectLate) {
        Check ($fixture.Prompts -eq 2 -and $fixture.LastNames.Count -eq 1 -and [IO.Path]::GetFileName($fixture.LastNames[0]) -eq 'b.txt') 'Reconfirmation did not name the new target'
    }
    Check (@(Get-ChildItem -LiteralPath $physical -Filter '__scrcpy_pull_*' -Force).Count -eq 0) 'Download left staging files'
    "PASS download $case"
}
foreach ($phase in @('snapshot', 'transfer', 'conflicts', 'copy')) {
    $physical = Reset-Fixture ('close-' + $phase)
    $selected=$physical; $fixture.ClosePhase=$phase; $lv=@{ SelectedItems=$files }
    & $download
    $expected = if ($phase -eq 'snapshot') { 0 } else { 1 }
    Check ($fixture.Closed -and $fixture.Transfers -eq $expected -and $fixture.Errors -eq 0) "Close did not stop $phase"
    Check (@(Get-ChildItem -LiteralPath $physical -Force).Count -eq 0) 'Close committed data or leaked staging files'
    "PASS download close during $phase"
}
function Fm-ExistingIndexes {
    param($Owner, $Serial, $Path, $Names)
    $fixture.Checks++
    if ($fixture.CloseAt -eq $fixture.Checks) {
        $fixture.Closed=$true; $dlg.IsDisposed=$true; $dlg.Visible=$false
        return @{ Ok=$false; Indexes=@() }
    }
    $indexes = @()
    for ($index=0; $index -lt $Names.Count; $index++) {
        if ($fixture.Remote.ContainsKey((Fm-ChildPath $Path $Names[$index]))) { $indexes += $index }
    }
    return @{ Ok=$true; Indexes=$indexes }
}
function Fm-Shell {
    param($Serial, $Command, $Owner)
    $match = [regex]::Match($Command, "if \[ -L '([^']+)' \]")
    Check $match.Success 'Upload did not test for a link first'
    $path = $match.Groups[1].Value
    if ($fixture.Remote.ContainsKey($path)) { return @($fixture.Remote[$path], '') }
    return @('FM_NEW', '')
}
$local = Join-Path $root 'upload.txt'; [IO.File]::WriteAllText($local, 'fixture')
$folder = Join-Path $root 'upload-folder'; [void][IO.Directory]::CreateDirectory($folder)
[IO.File]::WriteAllText((Join-Path $folder 'child.txt'), 'fixture')
foreach ($case in @('new-file', 'overwrite-file', 'skip-file', 'cancel-file', 'new-folder', 'merge-folder', 'link-file', 'nested-link', 'close-first-check', 'close-second-check')) {
    $null = Reset-Fixture ('upload-' + $case)
    $path = $local
    if ($case -in @('new-folder', 'merge-folder', 'nested-link')) { $path=$folder }
    $remote = Fm-ChildPath '/sdcard' ([IO.Path]::GetFileName($path))
    if ($case -in @('overwrite-file', 'skip-file', 'cancel-file')) { $fixture.Remote[$remote]='FM_FILE' }
    if ($case -in @('merge-folder', 'nested-link')) { $fixture.Remote[$remote]='FM_DIR' }
    if ($case -eq 'link-file') { $fixture.Remote[$remote]='FM_LINK' }
    if ($case -eq 'nested-link') { $fixture.Remote[(Fm-ChildPath $remote 'child.txt')]='FM_LINK' }
    if ($case -eq 'skip-file') { $fixture.Choices=@('skip') }
    if ($case -eq 'cancel-file') { $fixture.Choices=@('cancel') }
    if ($case -eq 'close-first-check') { $fixture.CloseAt=1 }
    if ($case -eq 'close-second-check') { $fixture.CloseAt=2 }
    & $upload @($path)
    $expected = if ($case -in @('new-file', 'overwrite-file', 'new-folder', 'merge-folder')) { 1 } else { 0 }
    Check ($fixture.Transfers -eq $expected) "Unexpected upload transfer: $case"
    if ($case.StartsWith('close-')) { Check ($fixture.Errors -eq 0 -and $fixture.Closed) 'Upload close showed a result popup' }
    "PASS upload $case"
}
'PASS file manager transfer regressions on PowerShell ' + $PSVersionTable.PSVersion
