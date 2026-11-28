$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms

$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
    (Join-Path (Split-Path $PSScriptRoot) 'scrcpy-helper.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors.Message -join "`n") }
$layoutMainBody = $ast.Find({
    param($node)
    $node -is [Management.Automation.Language.AssignmentStatementAst] -and
    $node.Left.Extent.Text -eq '$layoutMainBody'
}, $true).Right.Expression.ScriptBlock.GetScriptBlock()
$onResize = $ast.Find({
    param($node)
    $node -is [Management.Automation.Language.InvokeMemberExpressionAst] -and
    $node.Expression.Extent.Text -eq '$form' -and $node.Member.Value -eq 'Add_Resize'
}, $true).Arguments[0].ScriptBlock.GetScriptBlock()
$restoreFromTray = $ast.Find({
    param($node)
    $node -is [Management.Automation.Language.AssignmentStatementAst] -and
    $node.Left.Extent.Text -eq '$restoreFromTray'
}, $true).Right.Expression.ScriptBlock.GetScriptBlock()

$settings = @{ minToTray=$false }
$script:dpiScale = 1.0
$script:mainLayoutPending = $false
$script:trayHintShown = $true
$tray = [Windows.Forms.NotifyIcon]::new()
$form = [Windows.Forms.Form]::new()
try {
    $form.FormBorderStyle = 'FixedSingle'
    $form.MaximizeBox = $false
    $form.ClientSize = [Drawing.Size]::new(540, 428)
    $pnlDevCard = [Windows.Forms.Panel]::new()
    $pnlDevTop = [Windows.Forms.Panel]::new()
    $pnlDevTop.Height = 62
    $pnlGuide = [Windows.Forms.Panel]::new()
    $pnlGuide.Height = 36; $pnlGuide.Visible = $false
    $pnlSession = [Windows.Forms.Panel]::new()
    $pnlSession.Height = 34
    $pnlDevCard.Controls.AddRange(@($pnlDevTop, $pnlGuide, $pnlSession))
    $pnlFooter = [Windows.Forms.Panel]::new()
    $pnlFooter.Height = 34
    $btnCastHero = [Windows.Forms.Button]::new()
    $btnWirelessHero = [Windows.Forms.Button]::new()
    $btnCapAudio = [Windows.Forms.Button]::new()
    $btnCapScreenOff = [Windows.Forms.Button]::new()
    $btnCapOnTop = [Windows.Forms.Button]::new()
    $btnCapRes = [Windows.Forms.Button]::new()
    $btnFiles = [Windows.Forms.Button]::new()
    $btnCamera = [Windows.Forms.Button]::new()
    $btnRecord = [Windows.Forms.Button]::new()
    $btnNd = [Windows.Forms.Button]::new()
    $form.Controls.AddRange(@($pnlDevCard, $pnlFooter, $btnCastHero, $btnWirelessHero,
        $btnCapAudio, $btnCapScreenOff, $btnCapOnTop, $btnCapRes, $btnFiles, $btnCamera, $btnRecord, $btnNd))
    $form.Add_Resize($onResize)
    $form.Show()
    & $layoutMainBody
    $normalWidth = $form.ClientSize.Width
    $expandedHeight = $form.ClientSize.Height
    $restoreBounds = $form.RestoreBounds

    $form.WindowState = 'Minimized'
    [Windows.Forms.Application]::DoEvents()
    & $layoutMainBody
    if ($form.RestoreBounds.Size -ne $restoreBounds.Size) {
        throw "Refreshing an active session while minimized changed the restore size to $($form.RestoreBounds.Size)"
    }
    # A session can exit or be stopped while the main window is minimized.
    $pnlSession.Visible = $false
    & $layoutMainBody
    $form.WindowState = 'Normal'
    [Windows.Forms.Application]::DoEvents()
    if ($form.ClientSize.Width -ne $normalWidth -or $form.ClientSize.Height -ne ($expandedHeight - $pnlSession.Height)) {
        throw "Restore did not keep the full width and apply the collapsed layout: $($form.ClientSize)"
    }

    $settings.minToTray = $true
    $form.WindowState = 'Minimized'
    [Windows.Forms.Application]::DoEvents()
    if ($form.Visible) { throw 'The form did not hide after minimizing to the tray' }
    $pnlSession.Visible = $true
    & $layoutMainBody
    & $restoreFromTray
    [Windows.Forms.Application]::DoEvents()
    if (-not $form.Visible -or $form.ClientSize -ne [Drawing.Size]::new($normalWidth, $expandedHeight)) {
        throw "Tray restore did not apply the expanded layout: $($form.ClientSize)"
    }
} finally {
    $form.Dispose()
    $tray.Dispose()
}

'PASS main window restore regression on PowerShell ' + $PSVersionTable.PSVersion
