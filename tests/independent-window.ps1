$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
    (Join-Path (Split-Path $PSScriptRoot) 'scrcpy-helper.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors.Message -join "`n") }
foreach ($name in @(
    'Show-NewDisplay','Show-AppPicker','Show-ManageApps','Test-AppInFavorites','Add-AppFavorite','Get-NewDisplayArgs','Get-DisplayCompatibilityArgs','Get-HwDecArgs',
    'Get-VideoArgs','Get-ControlArgs','New-Lbl','New-Combo','New-Chk','New-Caption','New-Txt'
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
$cWhite = [Drawing.Color]::White
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
    param($Title)
    if ($Title -eq '独立窗口') { $fixture.Pickers++ }
    $dialog = [pscustomobject]@{
        Title=$Title; AcceptButton=$null; CancelButton=$null
        Cursor=[Windows.Forms.Cursors]::Default; DialogResult=[Windows.Forms.DialogResult]::Cancel
        Controls=[Collections.ArrayList]::new()
    }
    $dialog | Add-Member ScriptMethod ShowDialog {
        param($Owner)
        if ($fixture.ToggleFixed) {
            $fixed = $this.Controls | Where-Object { $_ -is [Windows.Forms.CheckBox] }
            $fixed.Checked = -not $fixed.Checked
        }
        if ($fixture.DialogActions -and $fixture.DialogActions.ContainsKey($this.Title)) {
            & $fixture.DialogActions[$this.Title] $this
        } else { & $this.AcceptButton.Action }
        return $this.DialogResult
    }
    $dialog | Add-Member ScriptMethod Close {}
    if ($Title -eq '独立窗口') { $fixture.Picker = $dialog }
    return $dialog
}
function New-PrimaryBtn {
    param($Text)
    $button = [pscustomobject]@{ Text=$Text; Action=$null; Enabled=$true; Location=$null; DialogResult=$null }
    $button | Add-Member ScriptMethod Add_Click { param($Action) $this.Action = $Action }
    return $button
}
function New-LinkBtn($Text) { New-PrimaryBtn $Text }
function New-SecondaryBtn($Text) { New-PrimaryBtn $Text }
function New-EscCancel {}
function Get-FriendlyName { return 'Test phone' }
function Get-DeviceDisplay { return @{ W=1080; H=2340; Dpi=420 } }
function Get-FitWindowArgs { throw 'Independent windows should let scrcpy choose the initial window size' }
function Save-Settings { $fixture.Saves++ }
function Show-ResultDialog {
    param($Owner, $Title, $Heading, $Body)
    $fixture.Message = $Body
    $fixture.Heading = $Heading
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
foreach ($preset in @(
    @{ Mode='portrait'; Display='1080x2340/420' },
    @{ Mode='landscape'; Display='1920x1080/240' }
)) {
    foreach ($fixed in @($false,$true)) {
        $settings = @{ ndMode=$preset.Mode; ndFixed=(-not $fixed); ndNoDecor=$false; ndAudio='auto'; audioOn=$true }
        $fixture = @{ Scans=0; Pickers=0; Starts=0; Saves=0; Picker=$null; ToggleFixed=$true }
        try {
            & $click
            Check ($fixture.Starts -eq 1 -and $fixture.Saves -eq 1) 'Independent window preset did not launch and save'
            Check ($fixture.Options -ccontains "--new-display=$($preset.Display)") 'Independent window preset lost its dimensions or DPI'
            Check (($fixture.Options -contains '--flex-display') -eq (-not $fixed)) 'Independent window did not honor the checkbox'
            Check (-not ($fixture.Options -match '^--window-(width|height)=')) 'Independent window forced the initial desktop window size'
            Check ($settings.ndFixed -eq $fixed) 'Independent window did not save the checkbox state'
        } finally {
            foreach ($control in $fixture.Picker.Controls) {
                if ($control -is [Windows.Forms.Control]) { $control.Dispose() }
            }
        }
    }
}
function Invoke-UiCommand {
    param($Owner, $Exe, $Options, $StatusText)
    Check (($Options -join '|') -eq '-s|test-device|--list-apps') 'App picker did not list apps from the selected device'
    return @{ Stdout=" - Test app com.example.second`n - Another app com.example.third"; Stderr='' }
}
function Test-CommandSuccess { return $true }
function Show-InputDialog { return $fixture.Inputs.Dequeue() }

$settings = @{ ndMode='settings'; ndFixed=$true; ndNoDecor=$false; ndAudio='auto'; audioOn=$true }
$fixture = @{
    Scans=0; Pickers=0; Starts=0; Saves=0
    DialogActions=@{
        '独立窗口' = {
            param($window)
            $appsCombo = @($window.Controls | Where-Object { $_ -is [Windows.Forms.ComboBox] })[0]
            Check ($appsCombo.Items.Count -eq 1) 'App actions were mixed into the app selection'
            $more = $window.Controls | Where-Object { $_.Text -ceq '更多应用' }
            & $more.Action
            Check ($appsCombo.SelectedItem.Target -ceq '+com.example.app') 'Cancel changed the selected app'
            & $more.Action
            Check ($fixture.Starts -eq 0 -and $fixture.Saves -eq 1) 'Adding a favorite launched an app or failed to save'
            Check ($appsCombo.SelectedItem.Target -ceq '+com.example.app') 'Adding a favorite changed the selected app'
            Check ($appsCombo.Items.Target -ccontains '+com.example.third') 'The newly added favorite did not appear in the app dropdown'
            & $more.Action
            Check ($fixture.Starts -eq 0 -and $fixture.Saves -eq 1) 'Selecting an app launched or saved it prematurely'
            Check ($appsCombo.SelectedItem.Target -ceq '+com.example.second') 'Selecting an installed app lost its package'
            Check ($appsCombo.GetItemText($appsCombo.SelectedItem) -ceq 'Test app (com.example.second)') 'Same-name apps were not distinguished in the dropdown'
            & $window.AcceptButton.Action
        }
        '更多应用' = {
            param($picker)
            $fixture.Visits++
            if ($fixture.Visits -eq 1) { return }
            $search = $picker.Controls | Where-Object { $_ -is [Windows.Forms.TextBox] }
            $favorite = $picker.Controls | Where-Object { $_.Text -cin @('加入常用','已在常用') }
            $search.Text = '['
            Check (-not $picker.AcceptButton.Enabled -and -not $favorite.Enabled) 'An unmatched search allowed selection or saving'
            if ($fixture.Visits -eq 2) {
                $search.Text = 'com.example.third'
                Check $favorite.Enabled 'A new app could not be added from More apps'
                & $favorite.Action
                Check ($picker.DialogResult -eq [Windows.Forms.DialogResult]::Cancel -and $search.Text -ceq 'com.example.third') 'Adding a favorite closed the picker or reset the search'
                Check ($favorite.Text -ceq '已在常用' -and -not $favorite.Enabled) 'A saved favorite remained actionable'
                & $favorite.Action
                Check ($fixture.Saves -eq 1 -and $fixture.Starts -eq 0) 'Adding twice wrote a duplicate or launched scrcpy'
                return
            }
            $search.Text = 'com.example.third'
            Check ($favorite.Text -ceq '已在常用' -and -not $favorite.Enabled -and $picker.AcceptButton.Enabled) 'A saved app could not still be selected on reopening'
            $search.Text = 'com.example.second'
            Check ($picker.AcceptButton.Enabled) 'Package-name search did not find the matching app'
            & $picker.AcceptButton.Action
        }
    }
    Visits=0
}
try {
    & $click
    Check ($fixture.Starts -eq 1 -and $fixture.Options -contains '--start-app=+com.example.second') 'The chosen installed app did not launch'
} finally {
    foreach ($control in $fixture.Picker.Controls) {
        if ($control -is [Windows.Forms.Control]) { $control.Dispose() }
    }
}

$script:customApps.Clear()
$script:customApps['Keys'] = 'com.example.saved'
$fixture = @{
    Scans=0; Pickers=0; Starts=0; Saves=0
    Inputs=[Collections.Queue]::new()
    DialogActions=@{
        '独立窗口' = {
            param($window)
            $appsCombo = @($window.Controls | Where-Object { $_ -is [Windows.Forms.ComboBox] })[0]
            $appsCombo.SelectedIndex = 1
            $manage = $window.Controls | Where-Object { $_.Text -ceq '管理常用' }
            & $manage.Action
            Check ($appsCombo.SelectedItem.Target -ceq '+com.example.saved') 'Managing favorites changed the selected app'
            Check ($appsCombo.Items.Count -eq 3) 'Saved favorites did not refresh in the dropdown'
            $manual = $window.Controls | Where-Object { $_.Text -ceq '手动输入' }
            $fixture.Inputs.Enqueue('example')
            & $manual.Action
            Check ($appsCombo.SelectedItem.Target -ceq '+?example') 'Manual search was not staged for launch'
            Check ($fixture.Starts -eq 0) 'An app action unexpectedly launched scrcpy'
        }
        '管理常用' = {
            param($manager)
            $fromPhone = $manager.Controls | Where-Object { $_.Text -ceq '从手机添加' }
            $manualAdd = $manager.Controls | Where-Object { $_.Text -ceq '手动添加' }
            $remove = $manager.Controls | Where-Object { $_.Text -ceq '移除常用' }
            Check (-not $remove.Enabled) 'Remove was enabled without a selection'
            & $fromPhone.Action
            Check ($script:customApps['Test app (com.example.second)'] -ceq 'com.example.second') 'Adding a same-name favorite overwrote or lost an app'
            & $fromPhone.Action
            Check ($fixture.Saves -eq 1) 'A duplicate package was saved'
            $fixture.Inputs.Enqueue('Keys')
            $fixture.Inputs.Enqueue('com.example.other')
            & $manualAdd.Action
            Check ($script:customApps['Keys'] -ceq 'com.example.saved' -and $fixture.Saves -eq 1) 'Manual add overwrote an existing favorite'
            $fixture.Inputs.Enqueue('Values')
            $fixture.Inputs.Enqueue('com.example.manual')
            & $manualAdd.Action
            Check ($script:customApps['Values'] -ceq 'com.example.manual' -and $remove.Enabled) 'Manual favorite was not saved and selected'
            & $fromPhone.Action
            Check ($fixture.Saves -eq 2) 'A favorite named Values bypassed package deduplication'
            & $remove.Action
            Check (-not $script:customApps.Contains('Values') -and $fixture.Saves -eq 3) 'Removing an app did not update favorites'
        }
        '从手机添加' = {
            param($picker)
            $search = $picker.Controls | Where-Object { $_ -is [Windows.Forms.TextBox] }
            $search.Text = 'com.example.second'
            if ($fixture.Saves -eq 0) {
                Check ($picker.AcceptButton.Text -ceq '加入常用' -and $picker.AcceptButton.Enabled) 'Favorite picker did not identify the effect of confirming'
                & $picker.AcceptButton.Action
            } else {
                Check ($picker.AcceptButton.Text -ceq '已在常用' -and -not $picker.AcceptButton.Enabled) 'Favorite picker allowed a duplicate package'
            }
        }
    }
}
try {
    & $click
    Check ($fixture.Starts -eq 0) 'Leaving app selection launched scrcpy'
} finally {
    foreach ($control in $fixture.Picker.Controls) {
        if ($control -is [Windows.Forms.Control]) { $control.Dispose() }
    }
}
'PASS independent window regression on PowerShell ' + $PSVersionTable.PSVersion
