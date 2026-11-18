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
    $fixture.Confirmations=[Collections.ArrayList]::new()
    $fixture.Writes=[Collections.ArrayList]::new()
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
    [void]$fixture.Confirmations.Add(@($Names))
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
    if ($Argv[2] -eq 'push') {
        Check ($Argv[-1] -ceq ($fixture.Stage + '/')) 'ADB push must only write to this transfer staging directory'
        if ($fixture.UploadLate) { $fixture.Remote[$fixture.UploadLate]='FM_FILE' }
        if ($fixture.CloseDuringPush) {
            $fixture.Closed=$true; $dlg.IsDisposed=$true; $dlg.Visible=$false
            return @{ Ok=$false; Aborted=$true; Detail='' }
        }
        return @{ Ok=$true; Aborted=$false; Detail='' }
    }
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
function Fm-Shell {
    param($Serial, $Command, $Owner)
    $fixture.Checks++
    if ($fixture.CloseAt -eq $fixture.Checks) {
        $fixture.Closed=$true; $dlg.IsDisposed=$true; $dlg.Visible=$false
        return @()
    }
    if ($Command -match "^mkdir '(/sdcard/\.scrcpy-upload-[0-9a-f]{32})' && echo FM_OK$") {
        $fixture.Stage = $Matches[1]
        return 'FM_OK'
    }
    $path = Get-FixtureUploadPath $Command
    if ($fixture.Remote[$path] -eq 'FM_LINK') { return 'FM_FAIL' }
    if ($Command -match ' \|\| mkdir ') {
        Check ($null -eq $fixture.Remote[$path] -or $fixture.Remote[$path] -eq 'FM_DIR') 'Commit tried to replace a file with a directory'
        $fixture.Remote[$path] = 'FM_DIR'
        return 'FM_OK'
    }
    if ($fixture.Remote.ContainsKey($path)) { return $fixture.Remote[$path] }
    return 'FM_NEW'
}
function Get-FixtureUploadPath([string]$Command) {
    $match = [regex]::Match($Command, "if \[ -L \./'([^']+)' \]")
    Check $match.Success 'Upload did not test for a link first'
    $parents = @([regex]::Matches($Command, "&& cd \./'([^']+)'") | ForEach-Object { $_.Groups[1].Value })
    return '/sdcard/' + (($parents + $match.Groups[1].Value) -join '/')
}
function Fm-ShellLong {
    param($Serial, $Command, $Owner, $Status, $Tip)
    $path = Get-FixtureUploadPath $Command
    $staged = $fixture.Stage + $path.Substring('/sdcard'.Length)
    Check ($Command.Contains((Fm-ShQuote $staged))) 'Commit did not use the staged file for this path'
    if ($fixture.Remote[$path] -eq 'FM_FILE' -and $Command -notmatch 'mv -f ') {
        return @{ Code=0; Output='FM_FILE'; Aborted=$false }
    }
    Check ($Command.Contains('set -C;') -and $Command.Contains('cat ')) 'New file creation must refuse existing names'
    [void]$fixture.Writes.Add($path)
    $fixture.Remote[$path] = 'FM_FILE'
    return @{ Code=0; Output='FM_OK'; Aborted=$false }
}
function Invoke-FmShell {
    param($Owner, $Serial, $Command)
    Check ($null -eq $Owner -and $Command -ceq ('rm -rf ' + (Fm-ShQuote $fixture.Stage))) 'Cleanup must target only the owned staging directory'
    $fixture.Stage=$null
    return @{ Ok=$true }
}
$local = Join-Path $root 'upload.txt'; [IO.File]::WriteAllText($local, 'fixture')
$folder = Join-Path $root 'upload-folder'; [void][IO.Directory]::CreateDirectory($folder)
[void][IO.Directory]::CreateDirectory((Join-Path $folder 'nested'))
foreach ($name in @('nested/child.txt', 'new.txt', 'late.txt')) {
    [IO.File]::WriteAllText((Join-Path $folder $name), 'fixture')
}
foreach ($case in @('new-file', 'overwrite-file', 'skip-file', 'cancel-file', 'new-folder', 'merge-folder', 'merge-skip', 'merge-late-skip', 'merge-late-yes', 'link-file', 'nested-link', 'close-first-check', 'close-second-check', 'close-during-push')) {
    $null = Reset-Fixture ('upload-' + $case)
    $path = if ($case -match 'folder|^merge-|nested-link|close-second-check') { $folder } else { $local }
    $remote = Fm-ChildPath '/sdcard' ([IO.Path]::GetFileName($path))
    $conflict = "$remote/nested/child.txt"
    $late = "$remote/late.txt"
    if ($case -in @('overwrite-file', 'skip-file', 'cancel-file')) { $fixture.Remote[$remote]='FM_FILE' }
    if ($case -match '^merge-|nested-link|close-second-check') {
        $fixture.Remote[$remote]='FM_DIR'
        $fixture.Remote["$remote/nested"]='FM_DIR'
    }
    if ($case -match '^merge-') { $fixture.Remote[$conflict]='FM_FILE' }
    if ($case -eq 'link-file') { $fixture.Remote[$remote]='FM_LINK' }
    if ($case -eq 'nested-link') { $fixture.Remote[$conflict]='FM_LINK' }
    if ($case -in @('skip-file','merge-skip')) { $fixture.Choices=@('skip') }
    if ($case -eq 'cancel-file') { $fixture.Choices=@('cancel') }
    if ($case -match '^merge-late-') {
        $fixture.UploadLate=$late
        $fixture.Choices=@('overwrite', $(if ($case -eq 'merge-late-skip') { 'skip' } else { 'overwrite' }))
    }
    if ($case -eq 'close-first-check') { $fixture.CloseAt=1 }
    if ($case -eq 'close-second-check') { $fixture.CloseAt=2 }
    if ($case -eq 'close-during-push') { $fixture.CloseDuringPush=$true }
    & $upload @($path)
    $expected = if ($case -match '^merge-|^new-|overwrite-file|close-during-push') { 1 } else { 0 }
    Check ($fixture.Transfers -eq $expected) "Unexpected upload transfer: $case"
    Check (-not $fixture.Stage) 'Upload leaked its staging directory'
    if ($case.StartsWith('close-')) {
        Check ($fixture.Errors -eq 0 -and $fixture.Closed -and $fixture.Writes.Count -eq 0) 'Upload continued or showed a result popup after close'
    }
    if ($case -match '^merge-') {
        Check ($fixture.Errors -eq 0 -and $fixture.Confirmations[0].Count -eq 1 -and $fixture.Confirmations[0][0] -ceq 'upload-folder/nested/child.txt') 'Initial authorization must name the conflicting child only'
        Check ($fixture.Writes -contains "$remote/new.txt") 'Upload lost the nonconflicting sibling'
        Check (($fixture.Writes -contains $conflict) -eq ($case -ne 'merge-skip')) 'Upload did not honor the initial decision'
        if ($case -match '^merge-late-') {
            Check ($fixture.Prompts -eq 2 -and $fixture.Confirmations[1].Count -eq 1 -and $fixture.Confirmations[1][0] -ceq 'upload-folder/late.txt') 'Late child inherited authorization for a sibling'
            Check (($fixture.Writes -contains $late) -eq ($case -eq 'merge-late-yes')) 'Upload did not honor the late decision'
        }
    }
    "PASS upload $case"
}
'PASS file manager transfer regressions on PowerShell ' + $PSVersionTable.PSVersion
