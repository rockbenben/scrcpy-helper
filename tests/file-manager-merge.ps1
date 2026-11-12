$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
$repo = Split-Path $PSScriptRoot
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'scrcpy-helper.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors.Message -join "`n") }
# Load definitions only, so regression checks cannot launch the app or contact a phone.
$ast.FindAll({ param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -match '^(Fm-|Assert-Fm|Merge-Fm|Move-Fm|Copy-Fm|Test-Fm|Get-Fm|Invoke-Fm)'
}, $true) | ForEach-Object { Invoke-Expression $_.Extent.Text }
function Check($Condition, $Message) { if (-not $Condition) { throw $Message } }
$root = Join-Path ([IO.Path]::GetTempPath()) ('fm-merge-test-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
$formFunction = $ast.Find({ param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Show-FileManager'
}, $true)
$assignment = $formFunction.Find({ param($node)
    $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$doDownload'
}, $true)
$body = $assignment.Right.Expression.ScriptBlock.GetScriptBlock().ToString()
$download = [scriptblock]::Create($body.Replace('New-Object System.Windows.Forms.FolderBrowserDialog', 'New-TestFolderDialog'))
$dlg = @{ Visible=$true; IsDisposed=$false }
$state = @{ Serial='fixture'; Path='/sdcard' }
$lblInfo = @{}; $progState = @{}
$beginProgress = {}; $endProgress = {}; $setDeviceLock = {}; $refresh = {}
$cGreen = [Drawing.Color]::Green; $cRed = [Drawing.Color]::Red
$fixture = @{ Prompts=0; Errors=0; Transfers=0; Late=$false }
$lv = @{ SelectedItems=@([pscustomobject]@{ Tag=@{ Name='album'; Path='/sdcard/album'; IsDir=$true; IsLink=$false; Size='0' } }) }
function New-TestFolderDialog {
    $dialog = [pscustomobject]@{ SelectedPath=$selected; Description=''; ShowNewFolderButton=$false }
    $dialog | Add-Member ScriptMethod ShowDialog { param($owner) return [Windows.Forms.DialogResult]::OK }
    $dialog | Add-Member ScriptMethod Dispose {}
    return $dialog
}
function Fm-ListDir {
    return @{ Ok=$true; Hidden=0; Items=@(
        @{ Name='late.txt'; Path='/sdcard/album/late.txt'; IsDir=$false; IsLink=$false },
        @{ Name='extra.txt'; Path='/sdcard/album/extra.txt'; IsDir=$false; IsLink=$false }
    ) }
}
function Fm-ConfirmOverwrite {
    $fixture.Prompts++
    if ($fixture.Prompts -eq 1) { return 'overwrite' }
    return 'skip'
}
function Show-ResultDialog { $fixture.Errors++; return 'ok' }
function Invoke-FmTask {
    param($Owner, $Work, $Inputs, $Functions)
    $Control = @{ Cancelled=$false }
    return (& $Work)
}
function Fm-Transfer {
    param($Argv, $dlg, $status, $tip, $prog, $WorkingDirectory)
    $fixture.Transfers++
    if ($fixture.Late) { [IO.File]::WriteAllText((Join-Path $selected 'album/late.txt'), 'local') }
    $stage = Join-Path $WorkingDirectory $Argv[-1]
    [void][IO.Directory]::CreateDirectory($stage)
    [IO.File]::WriteAllText((Join-Path $stage 'late.txt'), 'remote-late')
    [IO.File]::WriteAllText((Join-Path $stage 'extra.txt'), 'remote-extra')
    return @{ Ok=$true; Aborted=$false; Detail='' }
}
$selected = Join-Path $root 'skip-child'
[void][IO.Directory]::CreateDirectory((Join-Path $selected 'album'))
$fixture.Late = $true
& $download
Check ($fixture.Prompts -eq 2 -and $fixture.Errors -eq 0) 'Late conflict was not reconfirmed'
Check ([IO.File]::ReadAllText((Join-Path $selected 'album/late.txt')) -eq 'local') 'Skipped file changed'
Check ([IO.File]::ReadAllText((Join-Path $selected 'album/extra.txt')) -eq 'remote-extra') 'Nonconflicting sibling not saved'
Check (@(Get-ChildItem -LiteralPath $selected -Filter '__scrcpy_pull_*' -Force).Count -eq 0) 'Stage leaked'
$outside = Join-Path $root 'outside'
[void][IO.Directory]::CreateDirectory($outside)
[IO.File]::WriteAllText((Join-Path $outside 'sentinel.txt'), 'original')
$selected = Join-Path $root 'unrelated-link'
[void][IO.Directory]::CreateDirectory((Join-Path $selected 'album'))
[void](New-Item -ItemType Junction -Path (Join-Path $selected 'album/unrelated') -Target $outside)
$fixture.Prompts=0; $fixture.Errors=0; $fixture.Transfers=0; $fixture.Late=$false
& $download
Check ($fixture.Transfers -eq 1 -and $fixture.Errors -eq 0) 'Unrelated link blocked merge'
Check ([IO.File]::ReadAllText((Join-Path $selected 'album/extra.txt')) -eq 'remote-extra') 'Merge missing output'
Check ([IO.File]::ReadAllText((Join-Path $outside 'sentinel.txt')) -eq 'original' -and @(Get-ChildItem -LiteralPath $outside).Count -eq 1) 'Outside directory changed'
$selected = Join-Path $root 'matched-link'
[void][IO.Directory]::CreateDirectory((Join-Path $selected 'album'))
[void](New-Item -ItemType Junction -Path (Join-Path $selected 'album/extra.txt') -Target $outside)
$fixture.Errors=0; $fixture.Transfers=0
& $download
Check ($fixture.Transfers -eq 0 -and $fixture.Errors -eq 1) 'Link on write path was accepted'
# Skipping a whole conflicting subdirectory must leave its files intact while copying siblings.
$from = Join-Path $root 'skip-directory-source'
$to = Join-Path $root 'skip-directory-destination'
foreach ($path in @((Join-Path $from 'ignored'), (Join-Path $to 'ignored'))) { [void][IO.Directory]::CreateDirectory($path) }
[IO.File]::WriteAllText((Join-Path $from 'ignored/child.txt'), 'new')
[IO.File]::WriteAllText((Join-Path $to 'ignored/child.txt'), 'old')
[IO.File]::WriteAllText((Join-Path $from 'sibling.txt'), 'sibling')
$approved = @{}; $approved[[IO.Path]::GetFullPath($to)] = $true
$skipped = @{}; $skipped[[IO.Path]::GetFullPath((Join-Path $to 'ignored'))] = $true
Check (Move-FmPulledItem $from $to $approved $null $skipped) 'Skipped directory blocked sibling'
Check ([IO.File]::ReadAllText((Join-Path $to 'ignored/child.txt')) -eq 'old') 'Skipped subtree changed'
Check ([IO.File]::ReadAllText((Join-Path $to 'sibling.txt')) -eq 'sibling') 'Sibling missing after directory skip'
function Fm-ListDir {
    param($Owner, $Serial, $Path)
    $entries = if ($Path.EndsWith('/sub')) {
        @(@{ Name='leaf.txt'; Path=($Path+'/leaf.txt'); IsDir=$false; IsLink=$false })
    } else { @(@{ Name='sub'; Path=($Path+'/sub'); IsDir=$true; IsLink=$false }) }
    return @{ Ok=$true; Hidden=0; Items=$entries }
}
$manifest = @(Assert-FmRemoteTree $dlg 'fixture' '/sdcard/album')
Check ($manifest.Count -eq 2 -and $manifest -contains 'sub' -and $manifest -contains 'sub/leaf.txt') 'Nested remote manifest lost paths'
'PASS file manager merge regression on PowerShell ' + $PSVersionTable.PSVersion
