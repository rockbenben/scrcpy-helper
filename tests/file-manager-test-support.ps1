$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
$repo = Split-Path $PSScriptRoot
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'scrcpy-helper.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors.Message -join "`n") }
# Loading definitions through the parser avoids the application's startup and device operations.
$ast.FindAll({ param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -match '^(Fm-|(?:Assert|Merge|Move|Copy|Test|Get|Invoke|Select|New|Update|Start|Complete|Set)-Fm)'
}, $true) | ForEach-Object { Invoke-Expression $_.Extent.Text }
function Check($Condition, $Message) {
    if (-not $Condition) { throw $Message }
}
function Get-FileManagerAction([string]$Name) {
    $formFunction = $ast.Find({ param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Show-FileManager'
    }, $true)
    $assignment = $formFunction.Find({ param($node)
        $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq ('$' + $Name)
    }, $true)
    return $assignment.Right.Expression.ScriptBlock.GetScriptBlock().ToString()
}
function Get-TestFolderPicker {
    $definition = $ast.Find({ param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Select-FmDownloadFolder'
    }, $true)
    return [scriptblock]::Create($definition.Extent.Text.Replace('New-Object System.Windows.Forms.FolderBrowserDialog', 'New-TestFolderDialog'))
}
$root = Join-Path ([IO.Path]::GetTempPath()) ('fm-regression-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
