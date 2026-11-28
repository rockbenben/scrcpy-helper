. (Join-Path $PSScriptRoot 'file-manager-test-support.ps1')

foreach ($name in @('fmListTemplate', 'fmListTemplateLegacy')) {
    $assignment = $ast.Find({ param($node)
        $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq ('$' + $name)
    }, $true)
    . ([scriptblock]::Create($assignment.Extent.Text))
}
foreach ($name in @('refresh','enter','goUp','selectedFolder','openSelected')) {
    Set-Variable -Name $name -Value ([scriptblock]::Create((Get-FileManagerAction $name)))
}
$fileManager = $ast.Find({ param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Show-FileManager'
}, $true)
$goButton = $fileManager.Find({ param($node)
    $node -is [Management.Automation.Language.InvokeMemberExpressionAst] -and
    $node.Member.Value -eq 'Add_Click' -and $node.Expression.VariablePath.UserPath -eq 'btnGo'
}, $true).Arguments[0].ScriptBlock.GetScriptBlock()
$pathEnter = $fileManager.Find({ param($node)
    $node -is [Management.Automation.Language.InvokeMemberExpressionAst] -and
    $node.Member.Value -eq 'Add_KeyDown' -and $node.Expression.VariablePath.UserPath -eq 'txtPath'
}, $true).Arguments[0].ScriptBlock.GetScriptBlock()

$dlg = @{ Visible=$true; IsDisposed=$false }
$state = @{ Path='/sdcard'; Serial='fixture' }
$txtPath = @{}; $lblInfo = @{}; $updateButtons = {}
$lv = [pscustomobject]@{ Items=[Collections.ArrayList]::new(); SelectedItems=@(); IsDisposed=$false }
$lv | Add-Member ScriptMethod BeginUpdate {}
$lv | Add-Member ScriptMethod EndUpdate {}
$lv | Add-Member ScriptMethod Focus { return $true }
$boldFont = [Drawing.SystemFonts]::DefaultFont
$cMuted = [Drawing.Color]::Gray
$cRed = [Drawing.Color]::Red
$requests = [Collections.ArrayList]::new()
$rootLines = @(
    'V2', "D`twork`t-`t-", "D`twork `t-`t-", "F`tdevice offline notes.txt`t-`t-",
    "D`tdevice not found`t-`t-", "F`tadb: error notes.txt`t-`t-",
    'S 0 1700000000', 'S 0 1700000000', 'S 42 1700000000',
    'S 0 1700000000', 'S 81 1700000010', 'FM_DONE'
)
function Invoke-MainFlow { param($Body, $Owner, $Flag) & $Body }
function Invoke-FmShell {
    param($Owner, $Serial, $Command)
    Check ([object]::ReferenceEquals($Owner,$dlg) -and $Serial -ceq 'fixture') 'Directory read changed owner or device'
    $target = [regex]::Match($Command, "^cd '([^']*)' 2>/dev/null")
    Check $target.Success 'Shell command did not receive a quoted directory path'
    $path = $target.Groups[1].Value
    $isV2 = $Command.Contains("printf 'V2\n'")
    [void]$requests.Add(@{ Path=$path; IsV2=$isV2 })
    switch -CaseSensitive ($path) {
        '/sdcard' { return @{ Ok=$true; Lines=$rootLines; Err='adb daemon started' } }
        '/sdcard/work ' {
            if ($isV2) {
                # A missing stat entry must fall back to legacy using exactly the same directory.
                return @{ Ok=$true; Lines=@('V2',"D`tnested`t-`t-", 'FM_DONE') }
            }
            return @{ Ok=$true; Lines=@("D`tnested`t-`t1700000000", "F`tdevice offline.txt`t7`t1700000000", 'FM_DONE') }
        }
        '/sdcard/work /nested' { return @{ Ok=$true; Lines=@('V2','FM_DONE') } }
        '/sdcard/work' {
            return @{ Ok=$true; Lines=@('V2',"F`tplain.txt`t-`t-", 'S 10 1700000000', 'FM_DONE') }
        }
        '/offline' { return @{ Ok=$false; Lines=$rootLines; Err='adb: error: device offline' } }
        '/truncated' { return @{ Ok=$true; Lines=@('V2',"F`tpartial.txt`t-`t-"); Err='FM_DONE' } }
        '/denied' { return @{ Ok=$true; Lines=@("ERR`tcannot-enter`t-`t-", 'FM_DONE') } }
        '/diagnostic' { return @{ Ok=$true; Lines=@('adb: error: no devices/emulators found') } }
        default { throw "Unexpected directory [$path]" }
    }
}

& $refresh
$offlineName = $lv.Items | Where-Object { $_.Tag.Name -ceq 'device offline notes.txt' }
$errorName = $lv.Items | Where-Object { $_.Tag.Name -ceq 'adb: error notes.txt' }
Check ($lv.Items.Count -eq 5 -and $offlineName.Tag.Size -eq '42' -and $errorName.Tag.Time -eq '1700000010') 'A valid V2 listing was rejected or metadata shifted'
Check (@($lv.Items | Where-Object { $_.Tag.Name -ceq 'device not found' -and $_.Tag.IsDir }).Count -eq 1) 'A directory name was interpreted as an ADB error'

$lv.SelectedItems = @($lv.Items | Where-Object { $_.Tag.Name -ceq 'work ' })
& $openSelected
Check ($state.Path -ceq '/sdcard/work ' -and $txtPath.Text -ceq '/sdcard/work ') 'List navigation trimmed the directory name'
Check ($requests.Count -eq 3 -and $requests[1].IsV2 -and -not $requests[2].IsV2 -and
    $requests[1].Path -ceq '/sdcard/work ' -and $requests[2].Path -ceq '/sdcard/work ') 'Directory fallback lost the exact path'
Check (@($lv.Items | Where-Object { $_.Tag.Name -ceq 'device offline.txt' -and $_.Tag.Size -eq '7' }).Count -eq 1) 'Legacy listing rejected a valid filename'

$lv.SelectedItems = @($lv.Items | Where-Object { $_.Tag.Name -ceq 'nested' })
& $openSelected
Check ($state.Path -ceq '/sdcard/work /nested' -and $requests[-1].Path -ceq $state.Path) 'Joining a child path trimmed its parent'
& $goUp
& $goButton
$keyEvent = @{ KeyCode=[Windows.Forms.Keys]::Enter; SuppressKeyPress=$false }
& $pathEnter $txtPath $keyEvent
Check ($keyEvent.SuppressKeyPress -and $state.Path -ceq '/sdcard/work ' -and $txtPath.Text -ceq $state.Path) 'Parent navigation or resubmitting the displayed path lost the space'
Check ((Fm-ChildPath $state.Path 'file.txt') -ceq '/sdcard/work /file.txt') 'A file operation would target the similarly named directory'

$txtPath.Text = '  /sdcard//./work  '
& $goButton
Check ($state.Path -ceq '/sdcard/work' -and $lv.Items[0].Tag.Name -ceq 'plain.txt') 'Ordinary typed navigation or the distinct sibling path broke'
foreach ($path in @('/offline','/truncated','/denied','/diagnostic')) {
    $result = Fm-ListDir $dlg 'fixture' $path
    Check (-not $result.Ok -and $result.Items.Count -eq 0 -and -not $result.NeedLegacy) "Failed or incomplete directory read appeared successful: $path"
}

function Get-FriendlyName {
    param($serial, [switch]$CachedOnly)
    Check $CachedOnly 'Rebuilding the device list triggered an extra device query'
    return $serial
}
$windowState = New-FmWindowState @('first', 'selected') 'selected' 'first'
Check ($windowState.Serial -ceq 'selected' -and $windowState.Path -ceq '/sdcard') 'The file window lost the device selected in the main window'
$combo = [Windows.Forms.ComboBox]::new()
try {
    $changes = [Collections.ArrayList]::new()
    $combo.Add_SelectedIndexChanged({ [void]$changes.Add([bool]$windowState.Rebuilding) })
    Update-FmDeviceList $windowState $combo @('first', 'selected')
    Check ($combo.SelectedIndex -eq 1 -and $changes.Count -gt 0 -and $changes -notcontains $false) 'Rebuilding the device list did not preserve the selected device or guard events'
    $combo.SelectedIndex = 0
    Check ((-not (Set-FmSelectedDevice $windowState $combo $lblInfo $true)) -and $windowState.Serial -ceq 'selected' -and
        $combo.SelectedIndex -eq 1 -and $changes[-1] -and -not $windowState.Rebuilding) 'Switching during a transfer changed the active device'
    $combo.SelectedIndex = 0
    Check ((Set-FmSelectedDevice $windowState $combo $lblInfo $false) -and $windowState.Serial -ceq 'first') 'An idle window could not switch devices'
    Update-FmDeviceList $windowState $combo @('other')
    Check ($windowState.Serial -ceq 'other' -and $combo.SelectedIndex -eq 0) 'A missing device did not fall back to the first available device'
    Update-FmDeviceList $windowState $combo @()
    $fileList = @{ SelectedItems=@(); AllowDrop=$true }
    $upload = @{}; $download = @{}; $delete = @{}; $rename = @{}; $up = @{}
    Update-FmButtons $windowState $fileList @($upload) $download $delete $rename $up
    Check (-not $windowState.Serial -and $combo.SelectedIndex -eq -1 -and -not $fileList.AllowDrop -and
        -not ($upload.Enabled -or $download.Enabled -or $delete.Enabled -or $rename.Enabled -or $up.Enabled)) 'Losing the last device left file operations enabled'
} finally { $combo.Dispose() }
'PASS file manager directory regression on PowerShell ' + $PSVersionTable.PSVersion
