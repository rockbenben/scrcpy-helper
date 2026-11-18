$ErrorActionPreference = 'Stop'
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
    (Join-Path (Split-Path $PSScriptRoot) 'scrcpy-helper.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors.Message -join "`n") }
$assignment = $ast.Find({ param($node)
    $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$defaults'
}, $true)
. ([scriptblock]::Create($assignment.Extent.Text))
foreach ($name in @('Load-Settings','Save-Settings','Format-Json','Convert-SettingsValue','Test-SettingsZoom','Get-CamZoom')) {
    $definition = $ast.Find({ param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name
    }, $true)
    $code = $definition.Extent.Text
    if ($name -eq 'Save-Settings') {
        # A failed test should report the write error without opening a modal alert.
        $handler = $definition.Body.EndBlock.Statements[-1].CatchClauses[0].Body
        $code = $code.Replace($handler.Extent.Text, '{ throw }')
    }
    . ([scriptblock]::Create($code))
}
function Check($Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}
function Reset-SettingsState {
    $script:settings = [ordered]@{}
    foreach ($key in $defaults.Keys) { $script:settings[$key] = $defaults[$key] }
    $script:customApps = [ordered]@{}
    $script:knownDevices = [ordered]@{}
    $script:deviceNames = [ordered]@{}
    $script:camResByDevice = [ordered]@{}
    $script:autoConnectExclude = [Collections.Generic.List[string]]::new()
    $script:preserveUnreadableSettings = $false
}
function Check-ValidSettings {
    Check ($settings.maxSize -eq 720 -and $settings.bitRate -eq 8 -and $settings.recFormat -ceq 'mkv') 'A valid scalar setting was lost'
    Check ($settings.ndSize -ceq '' -and $settings.ndDpi -ceq '420' -and $settings.winX -eq -120) 'A valid custom display or window setting was lost'
    Check ($settings.audioOn -eq $false -and $settings.fullscreen -eq $true) 'Boolean values changed during load'
    Check ($settings.maxFps -eq $defaults.maxFps -and $settings.recTimeLimit -eq $defaults.recTimeLimit) 'Bad numeric field did not fall back'
    Check ($settings.noControl -eq $defaults.noControl -and $settings.stayAwake -eq $defaults.stayAwake) 'Bad boolean field did not fall back'
    Check ($settings.extraArgs -ceq $defaults.extraArgs -and $settings.camZoom -ceq $defaults.camZoom) 'Bad string field did not fall back'
    Check ($settings.camResMax -is [string] -and $settings.camResMax -ceq '1280') 'Legacy numeric camera size was not restored'
    Check (($script:knownDevices.Keys -join '|') -ceq '192.0.2.7:5555|adb-example._adb-tls-connect._tcp') 'Known devices were lost, reordered, or converted from an invalid value'
    Check ($script:knownDevices['192.0.2.7:5555'] -ceq '客厅手机' -and
        $script:knownDevices['adb-example._adb-tls-connect._tcp'] -ceq $dateAlias) 'A saved device nickname changed'
    Check ($script:customApps.Count -eq 1 -and $script:customApps['Keys'] -ceq 'com.example.app') 'Custom app entries did not survive'
    Check ($script:deviceNames.Count -eq 1 -and $script:deviceNames['usb-a'] -ceq '备用手机') 'Device labels did not survive'
    Check (($script:autoConnectExclude -join '|') -ceq '192.0.2.7:5555|192.0.2.8:5555') 'The exclusion list was lost or accepted invalid entries'
    Check ($script:camResByDevice.Count -eq 3 -and $script:camResByDevice['usb-a|back'] -ceq '1920x1080' -and
        $script:camResByDevice['usb-a|front'] -ceq '0' -and (Get-CamZoom 'usb-a' 'back') -eq 2.5) 'Valid camera memory was lost or invalid memory was restored'
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('scrcpy-settings-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testRoot)
$cfgPath = Join-Path $testRoot 'settings.json'
try {
    Reset-SettingsState
    $dateAlias = '2026-01-01T00:00:00Z'
    if (-not (Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) {
        $dateAlias = [string](ConvertFrom-Json '{"label":"2026-01-01T00:00:00Z"}').label
    }
    $mixed = @'
{
  "maxSize": 720,
  "maxFps": "broken",
  "bitRate": "8",
  "recTimeLimit": 1.5,
  "recFormat": "mkv",
  "audioOn": "false",
  "fullscreen": true,
  "noControl": "broken",
  "stayAwake": [false],
  "extraArgs": {"bad": true},
  "ndSize": "",
  "ndDpi": "420",
  "winX": -120,
  "camResMax": 1280,
  "camZoom": "broken",
  "knownDevices": {
    "192.0.2.7:5555": "客厅手机",
    "192.0.2.9:5555": ["wrong type"],
    "adb-example._adb-tls-connect._tcp": "2026-01-01T00:00:00Z"
  },
  "customApps": {"broken": 1, "Keys": "com.example.app"},
  "deviceNames": {"broken": false, "usb-a": "备用手机"},
  "autoConnectExclude": ["192.0.2.7:5555", ["bad"], 42, null, "192.0.2.8:5555"],
  "camResByDevice": {
    "usb-a|back": "1920x1080", "usb-a|back|zoom": "2.5", "usb-a|front": "0",
    "usb-a|front|zoom": "Infinity", "usb-b|back|zoom": "broken", "usb-b|front": "bad"
  }
}
'@
    [IO.File]::WriteAllText($cfgPath, $mixed)
    Load-Settings
    Check-ValidSettings
    Check (([IO.File]::ReadAllText($cfgPath)) -ceq $mixed) 'Load unexpectedly rewrote the configuration'
    Save-Settings
    Reset-SettingsState
    Load-Settings
    Check-ValidSettings
    Check (@(Get-ChildItem -LiteralPath $testRoot -Filter '*.bak').Count -eq 0) 'A recoverable field caused a whole-file backup'

    Reset-SettingsState
    [IO.File]::WriteAllText($cfgPath, '{"maxFps":2147483648,"knownDevices":["wrong shape"],"deviceNames":{"usb-a":"Still here"},"autoConnectExclude":"192.0.2.1:5555"}')
    Load-Settings
    Check ($settings.maxFps -eq $defaults.maxFps -and $script:knownDevices.Count -eq 0) 'Overflow or malformed device map was restored'
    Check ($script:deviceNames['usb-a'] -ceq 'Still here' -and $script:autoConnectExclude[0] -ceq '192.0.2.1:5555') 'Bad map shape prevented other memories from loading'

    foreach ($raw in @('{"knownDevices":{"192.0.2.7:5555":"Original phone"}', '[{"maxSize":720}]')) {
        Reset-SettingsState
        [IO.File]::WriteAllText($cfgPath, $raw, [Text.UTF8Encoding]::new($true))
        $original = [Convert]::ToBase64String([IO.File]::ReadAllBytes($cfgPath))
        Load-Settings
        Check ($settings.maxSize -eq $defaults.maxSize) 'Non-object or unreadable file was loaded'
        Save-Settings
        $backups = @(Get-ChildItem -LiteralPath $testRoot -Filter 'settings.json.unreadable-*.bak')
        Check (@($backups | Where-Object { [Convert]::ToBase64String([IO.File]::ReadAllBytes($_.FullName)) -ceq $original }).Count -eq 1) 'Saving did not preserve the unreadable file byte for byte'
        Save-Settings
        Check (@(Get-ChildItem -LiteralPath $testRoot -Filter '*.bak').Count -eq $backups.Count) 'Normal save repeated recovery backup'
    }
} finally {
    foreach ($file in [IO.Directory]::GetFiles($testRoot)) { [IO.File]::Delete($file) }
    [IO.Directory]::Delete($testRoot)
}
'PASS settings load and save regression on PowerShell ' + $PSVersionTable.PSVersion
