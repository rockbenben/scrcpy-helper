$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
    (Join-Path (Split-Path $PSScriptRoot) 'scrcpy-helper.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors.Message -join "`n") }
foreach ($name in @(
    'Show-NewDisplay','Get-NewDisplayArgs','Get-DisplayCompatibilityArgs','Get-HwDecArgs',
    'Get-VideoArgs','Get-ControlArgs','New-Lbl','New-Combo','New-Chk','New-Caption'
)) {
    $definition = $ast.Find({ param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name
    }, $true)
    . ([scriptblock]::Create($definition.Extent.Text))
}
$click = $ast.Find({ param($node)
    $node -is [Management.Automation.Language.InvokeMemberExpressionAst] -and
    $node.Member.Value -eq 'Add_Click' -and $node.Expression.VariablePath.UserPath -eq 'btnNd'
}, $true).Arguments[0].ScriptBlock.GetScriptBlock()

function Check($Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}
$apps = [ordered]@{ 'Test app' = 'com.example.app' }
$script:customApps = [ordered]@{}
$cMuted = [Drawing.Color]::Gray
$form = @{}
$btnNd = @{}
$fixture = @{}

function Invoke-MainFlow {
    param([scriptblock]$Body, $Source, [switch]$WithDevices)
    if ($WithDevices) { $fixture.Scans++; & $Body @('test-device') }
    else { & $Body }
}
function Resolve-TargetForFeature {
    param($Owner, $MinVersion, $Title, $Devices)
    Check ($MinVersion -eq 11 -and $Devices[0] -eq 'test-device') 'Independent window lost device selection'
    return $Devices[0]
}
function New-Dialog {
    $fixture.Pickers++
    $dialog = [pscustomobject]@{
        AcceptButton=$null; DialogResult=[Windows.Forms.DialogResult]::Cancel
        Controls=[Collections.ArrayList]::new()
    }
    $dialog | Add-Member ScriptMethod ShowDialog {
        param($Owner)
        & $this.AcceptButton.Action
        return $this.DialogResult
    }
    $dialog | Add-Member ScriptMethod Close {}
    $fixture.Picker = $dialog
    return $dialog
}
function New-PrimaryBtn {
    $button = [pscustomobject]@{ Action=$null }
    $button | Add-Member ScriptMethod Add_Click { param($Action) $this.Action = $Action }
    return $button
}
function New-EscCancel {}
function Get-FriendlyName { return 'Test phone' }
function Save-Settings { $fixture.Saves++ }
function Show-ResultDialog {
    param($Owner, $Title, $Heading, $Body)
    $fixture.Message = $Body
    return 'ok'
}
function Start-Scrcpy {
    param([string[]]$Options, [string]$AudioMode)
    $fixture.Starts++
    $fixture.Options = $Options
    $fixture.AudioMode = $AudioMode
}

foreach ($ignoreLimits in @($false,$true)) {
    foreach ($noControl in @($false,$true)) {
        $settings = @{
            ignoreEncoderConstraints=$ignoreLimits; noControl=$noControl; hwDec='disabled'
            ndSize='1280x720'; ndDpi='240'; ndMode='settings'; ndFixed=$false; ndNoDecor=$true
            ndAudio='on'; audioOn=$false; screenOff=$true; stayAwake=$true
        }
        $fixture = @{ Scans=0; Pickers=0; Starts=0; Saves=0; Message=$null; Picker=$null }
        try {
            & $click
            $normalVideo = @(Get-VideoArgs)
            Check (($normalVideo -contains '--ignore-video-encoder-constraints') -eq $ignoreLimits) 'Normal mirroring lost its encoder setting'
            Check ($normalVideo -contains '--hwdec=disabled') 'Normal mirroring lost its decoder setting'
            if ($noControl) {
                Check ($fixture.Scans -eq 0 -and $fixture.Pickers -eq 0 -and $fixture.Starts -eq 0 -and $fixture.Saves -eq 0) 'Read-only mode allowed independent-window work'
                Check ($fixture.Message -like '*开启「只投屏，不允许控制手机」时，独立窗口不可用。*') 'Read-only mode did not explain why independent windows are unavailable'
                Check ($settings.noControl -and (@(Get-ControlArgs -Wireless:$true) -join ' ') -eq '--no-control') 'Ordinary read-only mirroring became controllable'
            } else {
                Check ($fixture.Scans -eq 1 -and $fixture.Pickers -eq 1 -and $fixture.Starts -eq 1) 'Independent window did not launch'
                $expected = @('-s','test-device','--hwdec=disabled')
                if ($ignoreLimits) { $expected += '--ignore-video-encoder-constraints' }
                $expected += @('--new-display=1280x720/240','--flex-display','--no-vd-system-decorations',
                    '--window-title=Test phone · Test app','--start-app=+com.example.app')
                Check (($fixture.Options -join '|') -ceq ($expected -join '|')) 'Independent window launched with incorrect arguments'
                Check ($fixture.AudioMode -eq 'on') 'Independent window lost the selected audio mode'
            }
        } finally {
            foreach ($control in $fixture.Picker.Controls) {
                if ($control -is [Windows.Forms.Control]) { $control.Dispose() }
            }
        }
    }
}
'PASS independent window regression on PowerShell ' + $PSVersionTable.PSVersion
