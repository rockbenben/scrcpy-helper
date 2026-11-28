$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
    (Join-Path (Split-Path $PSScriptRoot) 'scrcpy-helper.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors.Message -join "`n") }
foreach ($name in @(
    'Show-NewDisplay','Show-AppPicker','Read-PhoneAppList','Get-AppFavorites','Move-AppFavorite','Add-AppFavorite','Get-NewDisplayArgs','Get-DisplayCompatibilityArgs','Get-HwDecArgs',
    'Get-VideoArgs','Get-ControlArgs','New-Lbl','New-Combo','New-Chk','New-Caption','New-Txt',
    'Invoke-UiCommand','Invoke-ShortCommand'
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
$script:hiddenBuiltInApps = @{}
$script:appFavoriteOrder = [Collections.Generic.List[string]]::new()
$script:phoneAppListCache = @{}
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
function Wait-UiTask {
    param($Owner, $StatusText, $Inputs, $Work)
    $Control = @{ Cancelled=$false; Process=$null }
    & $Work
}
# Exercise the real command helper with a local child so its timeout validation cannot be bypassed by the app-list mock.
$child = (Get-Process -Id $PID).Path
$command = Invoke-UiCommand $null $child @('-NoProfile','-NonInteractive','-Command', '[Console]::WriteLine("app-list-probe")') -TimeoutMs 60000
Check ($command.Started -and $command.ExitCode -eq 0 -and $command.Stdout.Trim() -ceq 'app-list-probe') 'The app list timeout was rejected before the command started'

function Invoke-UiCommand {
    param($Owner, $Exe, $Options, $StatusText, $TimeoutMs)
    Check (($Options -join '|') -eq '-s|test-device|--list-apps') 'App picker did not list apps from the selected device'
    Check ($TimeoutMs -eq 60000) 'Phone app discovery did not use its own timeout'
    $fixture.PhoneQueries++
    if ($fixture.FailedList) { return @{ Started=$true; TimedOut=$true; Error='Timed out' } }
    return @{ Started=$true; Stdout=" - Test app com.example.second`n - Another app com.example.third"; Stderr='' }
}
function Test-CommandSuccess($Result) { return ($Result.Started -and -not $Result.TimedOut) }
function Get-CommandDetail($Result) { return $Result.Error }
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
            Check ($fixture.Starts -eq 0 -and $fixture.Saves -eq 2) 'Selecting an app launched it or did not save the order'
            Check ($fixture.PhoneQueries -eq 1) 'Reopening More apps did not reuse the device list'
            Check (($appsCombo.Items.Target -join '|') -ceq '+com.example.third|+com.example.app|+com.example.second') 'The dropdown did not show the same favorite order as the picker'
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
            $search.Text = ''
            $filter = $picker.Controls | Where-Object { $_ -is [Windows.Forms.CheckBox] }
            $list = $picker.Controls | Where-Object { $_ -is [Windows.Forms.ListBox] }
            $filter.Checked = $true
            Check ($list.Items[0] -like '*com.example.app') 'Favorites did not start in the default order'
            $data = [Windows.Forms.DataObject]::new()
            $data.SetData('ScrcpyHelper.AppFavorite', $false, 'custom:Another app')
            $point = $list.PointToScreen([Drawing.Point]::new(6, 6))
            $eventArgs = [Windows.Forms.DragEventArgs]::new($data, 0, $point.X, $point.Y, [Windows.Forms.DragDropEffects]::Move, [Windows.Forms.DragDropEffects]::None)
            $enter = $list.GetType().GetMethod('OnDragEnter', [Reflection.BindingFlags]'Instance,NonPublic')
            [void]$enter.Invoke($list, @($eventArgs))
            Check ($eventArgs.Effect -eq [Windows.Forms.DragDropEffects]::Move) 'Favorites did not accept a drag over an app row'
            $drop = $list.GetType().GetMethod('OnDragDrop', [Reflection.BindingFlags]'Instance,NonPublic')
            [void]$drop.Invoke($list, @($eventArgs))
            Check ($list.Items[0] -like '*com.example.third' -and ($script:appFavoriteOrder -join '|') -ceq 'custom:Another app|builtin:com.example.app') 'Dragging did not reorder and save favorites'
            $filter.Checked = $false
            $search.Text = 'com.example.second'
            Check ($picker.AcceptButton.Enabled) 'Package-name search did not find the matching app'
            & $picker.AcceptButton.Action
        }
    }
    Visits=0; PhoneQueries=0
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
$script:appFavoriteOrder.Clear()
$script:phoneAppListCache.Clear()
$script:customApps['Keys'] = 'com.example.saved'
$script:customApps['To remove'] = 'com.example.fourth'
$fixture = @{
    Scans=0; Pickers=0; Starts=0; Saves=0; FailedList=$false; BuiltInAction=''; PhoneQueries=0
    Inputs=[Collections.Queue]::new()
    DialogActions=@{
        '独立窗口' = {
            param($window)
            $appsCombo = @($window.Controls | Where-Object { $_ -is [Windows.Forms.ComboBox] })[0]
            $appsCombo.SelectedIndex = 1
            Check (-not ($window.Controls | Where-Object { $_.Text -ceq '管理常用' })) 'Independent window retained the separate favorites dialog'
            $more = $window.Controls | Where-Object { $_.Text -ceq '更多应用' }
            & $more.Action
            Check ($appsCombo.SelectedItem.Target -ceq '+com.example.saved') 'Managing favorites changed the selected app'
            Check ($appsCombo.Items.Target -cnotcontains '+com.example.fourth') 'The removed favorite stayed in the dropdown'
            $script:phoneAppListCache.Clear()
            $fixture.FailedList = $true
            & $more.Action
            Check ($fixture.PhoneQueries -eq 4) 'The app picker did not retry both fresh and cached requests'
            $fixture.FailedList = $false
            $fixture.BuiltInAction = 'remove'
            & $more.Action
            Check ($appsCombo.Items.Target -cnotcontains '+com.example.app') 'Removing a built-in app did not refresh the dropdown'
            $fixture.BuiltInAction = 'restore'
            & $more.Action
            Check ($appsCombo.Items.Target -ccontains '+com.example.app') 'Restoring a built-in app did not refresh the dropdown'
            Check ($appsCombo.SelectedItem.Target -ceq '+com.example.saved' -and $fixture.Saves -eq 7) 'Editing built-in favorites changed the selected app or did not save twice'
            $fixture.BuiltInAction = 'empty'
            & $more.Action
            Check ($appsCombo.Items.Count -eq 0 -and -not $window.AcceptButton.Enabled) 'An empty favorites list still offered to launch an app'
            $manual = $window.Controls | Where-Object { $_.Text -ceq '手动输入' }
            $fixture.Inputs.Enqueue('example')
            & $manual.Action
            Check ($appsCombo.SelectedItem.Target -ceq '+?example' -and $window.AcceptButton.Enabled) 'Manual search was not staged for launch'
            Check ($fixture.Starts -eq 0) 'An app action unexpectedly launched scrcpy'
        }
        '更多应用' = {
            param($picker)
            $filter = $picker.Controls | Where-Object { $_ -is [Windows.Forms.CheckBox] }
            $search = $picker.Controls | Where-Object { $_ -is [Windows.Forms.TextBox] }
            $list = $picker.Controls | Where-Object { $_ -is [Windows.Forms.ListBox] }
            $remove = $picker.Controls | Where-Object { $_.Text -ceq '移除常用' }
            $manualAdd = $picker.Controls | Where-Object { $_.Text -ceq '手动添加' }
            Check ($filter.Text -ceq '只看常用') 'More apps did not offer a favorites filter'
            if ($fixture.FailedList) {
                Check (-not $filter.Checked -and $list.Items.Count -eq 2) 'Query failure changed the default app filter or hid available apps'
                Check ($picker.Controls.Text -ccontains '读取手机应用列表超时。') 'The timeout was not reported within More apps'
                $refresh = $picker.Controls | Where-Object { $_.Text -ceq '刷新应用列表' }
                $search.Text = 'com.example.second'
                $filter.Checked = $true
                $fixture.FailedList = $false
                & $refresh.Action
                Check ($filter.Checked -and $list.Items.Count -eq 0 -and $search.Text -ceq 'com.example.second') 'Retry changed the filter or search text'
                $filter.Checked = $false
                Check ($list.Items.Count -eq 1) 'Retry did not restore matching phone apps'
                $fixture.FailedList = $true
                & $refresh.Action
                Check ($list.Items.Count -eq 1 -and $picker.Controls.Text -ccontains '读取手机应用列表超时。') 'A failed refresh discarded the last good device list'
                return
            }
            if ($fixture.BuiltInAction -eq 'empty') {
                $search.Text = 'com.example.app'
                & $remove.Action
                $search.Text = 'com.example.saved'
                & $remove.Action
                return
            }
            if ($fixture.BuiltInAction) {
                $search.Text = 'com.example.app'
                $filter.Checked = $true
                if ($fixture.BuiltInAction -eq 'remove') {
                    Check ($list.Items.Count -eq 1 -and $remove.Enabled) 'Built-in favorites were not removable'
                    & $remove.Action
                    Check ($list.Items.Count -eq 0 -and $script:hiddenBuiltInApps.ContainsKey('com.example.app')) 'Built-in favorite remained in the favorites filter'
                } else {
                    Check ($list.Items.Count -eq 0) 'Reopening resurfaced a hidden built-in favorite'
                }
                $filter.Checked = $false
                $addBack = $picker.Controls | Where-Object { $_.Text -ceq '加入常用' }
                Check ($list.Items.Count -eq 1 -and $addBack.Enabled) 'A removed built-in app was not searchable in the full list'
                if ($fixture.BuiltInAction -eq 'restore') {
                    & $addBack.Action
                    $filter.Checked = $true
                    Check ($list.Items.Count -eq 1 -and $remove.Enabled -and -not $script:hiddenBuiltInApps.ContainsKey('com.example.app')) 'Built-in favorite was not restored'
                    Check ($script:customApps.psbase.Count -eq 1) 'Restoring a built-in favorite created a duplicate custom item'
                }
                return
            }
            Check (-not $filter.Checked) 'More apps did not initially show installed apps'
            $search.Text = 'com.example.second'
            $filter.Checked = $true
            Check ($list.Items.Count -eq 0 -and -not $remove.Enabled) 'Favorites filter included an unsaved app'
            $filter.Checked = $false
            Check ($list.Items.Count -eq 1) 'Disabling the filter did not restore installed search results'
            $favorite = $picker.Controls | Where-Object { $_.Text -ceq '加入常用' }
            & $favorite.Action
            Check ($script:customApps['Test app (com.example.second)'] -ceq 'com.example.second') 'A same-name favorite overwrote or lost an app'
            $filter.Checked = $true
            Check ($list.Items.Count -eq 1 -and $remove.Enabled -and $search.Text -ceq 'com.example.second') 'The saved app did not appear under the same search in favorites'
            & $remove.Action
            Check ($list.Items.Count -eq 0 -and -not $remove.Enabled -and $fixture.Saves -eq 2) 'Removing a favorite did not refresh the list'
            $filter.Checked = $false
            Check ($list.Items.Count -eq 1 -and $picker.AcceptButton.Enabled -and $favorite.Enabled) 'Removing a favorite hid the installed app'
            $filter.Checked = $true
            $search.Text = 'com.example.app'
            Check ($list.Items.Count -eq 1 -and $remove.Enabled -and -not $favorite.Enabled) 'A built-in favorite was not recognized as removable'
            $search.Text = ''
            $fixture.Inputs.Enqueue('Keys')
            $fixture.Inputs.Enqueue('com.example.other')
            & $manualAdd.Action
            Check ($script:customApps['Keys'] -ceq 'com.example.saved' -and $fixture.Saves -eq 2) 'Manual add overwrote an existing favorite'
            $fixture.Inputs.Enqueue('Values')
            $fixture.Inputs.Enqueue('com.example.manual')
            & $manualAdd.Action
            Check ($script:customApps['Values'] -ceq 'com.example.manual' -and $remove.Enabled) 'Manual favorite was not saved and selected'
            $fixture.Inputs.Enqueue('Other name')
            $fixture.Inputs.Enqueue('com.example.saved')
            & $manualAdd.Action
            Check ($fixture.Saves -eq 3 -and $fixture.Heading -ceq '这个应用已在常用列表中') 'A favorite named Values bypassed package deduplication'
            & $remove.Action
            Check (-not $script:customApps.Contains('Values') -and $fixture.Saves -eq 4 -and -not $remove.Enabled) 'Removal did not clear the selection or update favorites'
            $search.Text = 'com.example.fourth'
            Check ($remove.Enabled) 'A saved app missing from the phone list could not be removed'
            & $remove.Action
            Check ($fixture.Saves -eq 5 -and $list.Items.Count -eq 0) 'Removal did not update the existing favorite'
            Check ($fixture.Starts -eq 0) 'A favorites operation launched the installed app'
        }
    }
}
try {
    & $click
    Check ($fixture.Starts -eq 0) 'Leaving the independent window launched scrcpy'
} finally {
    foreach ($control in $fixture.Picker.Controls) {
        if ($control -is [Windows.Forms.Control]) { $control.Dispose() }
    }
}
'PASS independent window regression on PowerShell ' + $PSVersionTable.PSVersion
