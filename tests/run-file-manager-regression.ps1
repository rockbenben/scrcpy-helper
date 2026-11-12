$ErrorActionPreference = 'Stop'
# Separate script scopes keep UI/ADB doubles from leaking between regression groups.
foreach ($script in @('file-manager-merge.ps1', 'file-manager-transfer.ps1', 'file-manager-cancellation.ps1', 'file-manager-cancellation-negative.ps1')) {
    & (Join-Path $PSScriptRoot $script)
}
'PASS all file manager regressions on PowerShell ' + $PSVersionTable.PSVersion
