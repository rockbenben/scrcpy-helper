$ErrorActionPreference = 'Stop'
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
    (Join-Path (Split-Path $PSScriptRoot) 'scrcpy-helper.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors.Message -join [Environment]::NewLine) }
foreach ($name in @('Resume-CameraSession','Read-CamZoom','Start-CamProc','Start-Scrcpy',
        'Test-SettingsZoom','Split-WindowsArguments','Fm-WinArg','Remove-CamSession','Format-Zoom')) {
    $definition = $ast.Find({ param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name
    }, $true)
    . ([scriptblock]::Create($definition.Extent.Text))
}

function Check($Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('scrcpy-camera-' + [guid]::NewGuid().ToString('N'))
$stdout = Join-Path $testRoot 'stdout.log'
$stderr = Join-Path $testRoot 'stderr.log'
$culture = [Threading.Thread]::CurrentThread.CurrentCulture
$launches = [Collections.Generic.List[string]]::new()
$scrcpyProcs = [Collections.ArrayList]::new()
$script:camSessions = [Collections.ArrayList]::new()
$script:closeState = @{ InProgress=$false }
$script:deviceScanState = @{ Closing=$false }
$script:showTempHint = {}
$settings = @{ extraArgs=''; showConsole=$false }
$snapshot = @{ Success=$true; Devices=@('test-phone') }
$saved = @{}
$exe = 'fixture-scrcpy'

function Get-FriendlyName { return '' }
function Get-NulStdin { return 'NUL' }
function Release-ExitedProcess { param($Process) }
function Test-ProcessExited { param($Process) return $Process.HasExited }
function Set-CamZoom { param($Serial, $Facing, $Zoom) $saved.Zoom = $Zoom }
function Save-Settings { $saved.Written = $true }
function Start-Process {
    param($FilePath, [string]$ArgumentList, $WorkingDirectory, [switch]$PassThru, $WindowStyle,
        $RedirectStandardError, $RedirectStandardOutput, $RedirectStandardInput)
    $launches.Add($ArgumentList)
    # The real launch truncates the same log, so subsequent reconnects cannot read the previous value from disk.
    [IO.File]::WriteAllText($RedirectStandardOutput, '')
    return [pscustomobject]@{ HasExited=$true }
}
function Assert-Reconnect($Session, [string]$Zoom, [string]$Label) {
    $before = $launches.Count
    Resume-CameraSession $Session $snapshot
    Check ($launches.Count -eq ($before + 1)) "$Label did not launch scrcpy exactly once"
    $actual = @(Split-WindowsArguments $launches[$before])
    $zoomArgs = @($actual | Where-Object { $_ -eq '--camera-zoom' -or $_ -like '--camera-zoom=*' })
    Check ($zoomArgs[-1] -ceq "--camera-zoom=$Zoom") (
        "$Label expected --camera-zoom=$Zoom, received [$($actual -join ' ')]")
    Check (@($actual | Where-Object { $_ -eq '--camera-size=1920x1080' }).Count -eq 1) "$Label lost the capture size"
    Check (@($actual | Where-Object { $_ -eq '--no-audio' }).Count -eq 1) "$Label lost the audio setting"
}

try {
    [void][IO.Directory]::CreateDirectory($testRoot)
    [Threading.Thread]::CurrentThread.CurrentCulture = [cultureinfo]::GetCultureInfo('de-DE')
    $session = [pscustomobject]@{
        Serial='test-phone'; Facing='back'; Stopped=$false; Proc=$null; OutFile=$stdout; ErrFile=$stderr
        LastZoom=$null; StartedAt=[datetime]::MinValue
        Args=@('-s','test-phone','--video-source=camera','--camera-size=1920x1080','--camera-zoom=1.2','--no-audio')
    }
    [void]$script:camSessions.Add($session)

    Assert-Reconnect $session '1.2' 'Missing log on first reconnect'
    [IO.File]::WriteAllLines($stdout, [string[]]@(
        '[server] INFO: Set camera zoom: 1.2'
        '[server] INFO: Set camera zoom: 3.1640973'
        '[server] INFO: Set camera zoom: 2.5.1'
        '[server] INFO: Set camera zoom: 4.9broken'
        '[server] INFO: Set camera zoom: 0'
        '[server] INFO: Set camera zoom: -4'
        '[server] INFO: Set camera zoom: Infinity'
        'INFO: Device disconnected'
    ))
    Assert-Reconnect $session '3.1640973' 'Latest valid zoom'
    Assert-Reconnect $session '3.1640973' 'Empty log after reconnect'
    [IO.File]::WriteAllText($stdout, '[server] INFO: Set camera zoom: NaN')
    Assert-Reconnect $session '3.1640973' 'Invalid log after reconnect'

    $settings.extraArgs = '--camera-zoom 5 --window-title="Living Room"'
    [IO.File]::WriteAllText($stdout, '[server] INFO: Set camera zoom: 1.0')
    Assert-Reconnect $session '1.0' 'Return to 1x with a custom initial zoom'
    $actual = @(Split-WindowsArguments $launches[$launches.Count - 1])
    Check ($actual -ccontains '--window-title=Living Room') 'Reconnect lost an unrelated custom option'

    $settings.extraArgs = '--window-title "--camera-zoom=literal"'
    Assert-Reconnect $session '1.0' 'Custom title resembling a zoom option'
    $actual = @(Split-WindowsArguments $launches[$launches.Count - 1])
    Check ($actual[([array]::IndexOf($actual, '--window-title') + 1)] -ceq '--camera-zoom=literal') 'Reconnect changed the custom title value'

    $settings.extraArgs = ''
    $session.Args = @($session.Args | Where-Object { $_ -notlike '--camera-zoom=*' })
    $session.LastZoom = $null
    [IO.File]::WriteAllText($stdout, '[server] INFO: Set camera zoom: 0.65')
    Assert-Reconnect $session '0.65' 'Zoom below 1x after starting at default zoom'

    [IO.File]::WriteAllText($stdout, '[server] INFO: Set camera zoom: 2.78231')
    Remove-CamSession $session
    Check ($saved.Written -and $saved.Zoom -ceq '2.8') 'Session cleanup changed the remembered zoom precision'
} finally {
    [Threading.Thread]::CurrentThread.CurrentCulture = $culture
    [IO.File]::Delete($stdout)
    if ([IO.Directory]::Exists($testRoot)) { [IO.Directory]::Delete($testRoot) }
}

Write-Host 'Camera reconnect zoom regression passed.'
