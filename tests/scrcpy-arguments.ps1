$ErrorActionPreference = 'Stop'
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
    (Join-Path (Split-Path $PSScriptRoot) 'scrcpy-helper.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors.Message -join [Environment]::NewLine) }
foreach ($name in @('Start-Scrcpy','Split-WindowsArguments','Fm-WinArg',
    'Get-HwDecArgs','Get-DisplayCompatibilityArgs','Get-VideoArgs','Get-AudioArgs','Get-WindowArgs','Get-RecordingArgs','Resolve-RecordingPath')) {
    $definition = $ast.Find({ param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name
    }, $true)
    . ([scriptblock]::Create($definition.Extent.Text))
}
function Check($Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}
function Assert-Arguments($Actual, $Expected, [string]$Label) {
    Check ($Actual.Count -eq $Expected.Count) "$Label had $($Actual.Count) arguments, expected $($Expected.Count)"
    for ($index = 0; $index -lt $Expected.Count; $index++) {
        Check ([string]::Equals($Actual[$index], $Expected[$index], [StringComparison]::Ordinal)) (
            "$Label argument $index expected [$($Expected[$index])], received [$($Actual[$index])]")
    }
}

$splitCases = @(
    @{ Text=''; Values=@() },
    @{ Text=('  --angle=90' + [char]9 + '--time-limit=300  '); Values=@('--angle=90','--time-limit=300') },
    @{ Text='--window-title="Living Room" --angle=90'; Values=@('--window-title=Living Room','--angle=90') },
    @{ Text='"a b"mid" c" C:\plain\'; Values=@('a bmid c','C:\plain\') },
    @{ Text='--window-title="He said ""hello"""'; Values=@('--window-title=He said "hello"') },
    @{ Text='--push-target="C:\Phone Files\\" ""'; Values=@('--push-target=C:\Phone Files\','') },
    @{ Text='--window-title="A\\\"B"'; Values=@('--window-title=A\"B') },
    @{ Text='--window-title="Still one value'; Values=@('--window-title=Still one value') }
)
foreach ($case in $splitCases) {
    Assert-Arguments @(Split-WindowsArguments $case.Text) $case.Values "Split [$($case.Text)]"
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('scrcpy-argv-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testRoot)
$argSpy = Join-Path $testRoot 'argument spy.ps1'
$hostExe = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
$stdout = Join-Path $testRoot 'stdout.txt'
$stderr = Join-Path $testRoot 'stderr.txt'
$fixture = @{}
$exe = 'fixture-scrcpy'
$form = @{}
function Get-FriendlyName { return 'Test phone' }
function Wait-ScrcpyWindow { param($Proc, $Title) $fixture.Title = $Title; return 'shown' }
function Start-Process {
    param($FilePath, [string]$ArgumentList, $WorkingDirectory, [switch]$PassThru, $WindowStyle)
    $process = $null
    try {
        Check ($FilePath -eq $exe) 'Raw argument test tried to launch an unexpected executable'
        $command = '-NoProfile -ExecutionPolicy Bypass -File ' + (Fm-WinArg $argSpy) + ' ' + $ArgumentList
        $launch = @{
            FilePath=$hostExe; ArgumentList=$command; WorkingDirectory=$testRoot; PassThru=$true
            WindowStyle='Hidden'; RedirectStandardOutput=$stdout; RedirectStandardError=$stderr
        }
        $process = Microsoft.PowerShell.Management\Start-Process @launch
        # Keep the process handle so Windows PowerShell can read ExitCode after it exits.
        $null = $process.Handle
        Check ($process.WaitForExit(15000)) 'Argument spy timed out'
        Check ($process.ExitCode -eq 0) "Argument spy exited with [$($process.ExitCode)]. $([IO.File]::ReadAllText($stderr))"
        $json = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String([IO.File]::ReadAllText($stdout).Trim()))
        $fixture.Actual = (ConvertFrom-Json -InputObject $json).Arguments
        return [pscustomobject]@{ HasExited=$false }
    } catch {
        $fixture.LaunchError = $_.Exception.Message
    } finally {
        if ($process) {
            if (-not $process.HasExited) { $process.Kill(); [void]$process.WaitForExit(2000) }
            $process.Dispose()
        }
    }
}
try {
    [IO.File]::WriteAllText($argSpy, @'
# Read OS arguments before interpreting PowerShell script parameters.
$argv = @([Environment]::GetCommandLineArgs() | Select-Object -Skip 6)
$json = ConvertTo-Json -InputObject @{ Arguments=$argv } -Compress
[Console]::WriteLine([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json)))
'@)
    $launchCases = @(
        @{
            Extra='--window-title="Living Room" --angle=90'; Title='Living Room'; Rec=$false; RecBg=$false
            Values=@('-s','test-device','--window-title=Living Room','--angle=90')
        },
        @{
            Extra='--window-title "房间 \"东\"" --record="C:\My Videos\clip.mp4" --push-target="C:\Phone Files\\" ""'
            Title='房间 "东"'; Rec=$true; RecBg=$false; BuiltInTitle='--window-title=Test phone · App'
            Values=@('-s','test-device','--window-title=Test phone · App','--window-title','房间 "东"',
                '--record=C:\My Videos\clip.mp4','--push-target=C:\Phone Files\','')
        },
        @{
            Extra='--record="C:\My Videos\bg.mp4" --no-window --no-playback'
            Title=$null; Rec=$true; RecBg=$true; BuiltInTitle=''
            Values=@('-s','test-device','--record=C:\My Videos\bg.mp4','--no-window','--no-playback','--window-title=Test-phone · 录制')
        }
    )
    foreach ($case in $launchCases) {
        $fixture.Clear()
        $settings = @{ extraArgs=$case.Extra; showConsole=$false }
        $scrcpyProcs = [Collections.ArrayList]::new()
        Start-Scrcpy @('-s','test-device','',$case.BuiltInTitle)
        Check (-not $fixture.LaunchError) "Argument spy failed: $($fixture.LaunchError)"
        Assert-Arguments $fixture.Actual $case.Values 'Child process'
        if ($null -ne $case.Title) { Check ($fixture.Title -ceq $case.Title) 'Startup used the wrong window title' }
        else { Check (-not $fixture.ContainsKey('Title')) 'Background playback unexpectedly waited for a window' }
        Check ($scrcpyProcs.Count -eq 1 -and $scrcpyProcs[0].Rec -eq $case.Rec -and $scrcpyProcs[0].RecBg -eq $case.RecBg) 'Process registration did not use the parsed options'
    }

    $settings = @{
        maxSize=0; maxFps=0; bitRate=0; videoCodec=''; crop=''; hwDec=''; ignoreEncoderConstraints=$false
        audioOn=$true; audioSource=''; audioCodec=''
        noControl=$false; stayAwake=$true; screenOff=$true
        fullscreen=$false; onTop=$true; borderless=$true
        recTimeLimit=120; recBackground=$false; recDir=''
    }
    Assert-Arguments @(Get-RecordingArgs -Serial 'usb-1' -Path 'C:\rec\a.mp4' -Wireless $false) @(
        '-s','usb-1','-r','C:\rec\a.mp4','-w','--turn-screen-off','--time-limit=120','--always-on-top','--window-borderless'
    ) 'Windowed USB recording arguments'
    Assert-Arguments @(Get-RecordingArgs -Serial '192.0.2.5:5555' -Path 'C:\rec\b.mp4' -Wireless $true) @(
        '-s','192.0.2.5:5555','-r','C:\rec\b.mp4','--keep-active','--turn-screen-off','--time-limit=120','--always-on-top','--window-borderless'
    ) 'Windowed wireless recording arguments'

    $settings.recBackground = $true
    Assert-Arguments @(Get-RecordingArgs -Serial 'usb-1' -Path 'C:\rec\c.mp4' -Wireless $false) @(
        '-s','usb-1','-r','C:\rec\c.mp4','-w','--turn-screen-off','--time-limit=120','--no-window','--no-playback'
    ) 'Background recording arguments'

    $settings.noControl = $true
    Assert-Arguments @(Get-RecordingArgs -Serial 'usb-1' -Path 'C:\rec\d.mp4' -Wireless $false) @(
        '-s','usb-1','-r','C:\rec\d.mp4','--no-control','--time-limit=120','--no-window','--no-playback'
    ) 'No-control recording arguments'

    $promptTarget = Resolve-RecordingPath 'mp4' '20261128-053000'
    Check ($promptTarget.Mode -ceq 'prompt') 'Empty recDir did not prompt'
    $missingDir = Join-Path $testRoot 'missing-folder'
    $settings.recDir = $missingDir
    $missingTarget = Resolve-RecordingPath 'mp4' '20261128-053000'
    Check ($missingTarget.Mode -ceq 'missing' -and $missingTarget.Dir -ceq $missingDir) 'Missing recDir did not report missing'

    $recOutDir = Join-Path $testRoot 'recordings'
    [void][IO.Directory]::CreateDirectory($recOutDir)
    $settings.recDir = "  $recOutDir  "
    $fixed1 = Resolve-RecordingPath 'mp4' '20261128-053000'
    $expected1 = Join-Path $recOutDir '录屏-20261128-053000.mp4'
    Check ($fixed1.Mode -ceq 'fixed' -and $fixed1.Path -ceq $expected1) 'Fixed recDir produced wrong file path'
    [IO.File]::WriteAllText($expected1, 'taken')
    $fixed2 = Resolve-RecordingPath 'mp4' '20261128-053000'
    $expected2 = Join-Path $recOutDir '录屏-20261128-053000-2.mp4'
    Check ($fixed2.Mode -ceq 'fixed' -and $fixed2.Path -ceq $expected2) 'Collision suffix was not appended for fixed recDir'
} finally {
    foreach ($file in [IO.Directory]::GetFiles($testRoot)) { [IO.File]::Delete($file) }
    foreach ($dir in [IO.Directory]::GetDirectories($testRoot)) { [IO.Directory]::Delete($dir, $true) }
    [IO.Directory]::Delete($testRoot)
}
'PASS scrcpy command-line argument regression on PowerShell ' + $PSVersionTable.PSVersion
