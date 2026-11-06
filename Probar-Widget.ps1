# Autoprueba del Optimizador PC. Uso: powershell -NoProfile -ExecutionPolicy Bypass -File Probar-Widget.ps1
$ErrorActionPreference = 'Stop'
$file = Join-Path $PSScriptRoot 'OptimizadorPC.ps1'

# Un BOM duplicado hace que PowerShell lea la primera línea como comando y el programa no arranque
$b = [IO.File]::ReadAllBytes($file)
if ($b[3] -eq 0xEF -and $b[4] -eq 0xBB -and $b[5] -eq 0xBF) { throw 'BOM duplicado en OptimizadorPC.ps1' }

$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($file, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw "Errores de sintaxis: $($errors[0].Message)" }

foreach ($name in 'Format-Rate', 'Get-NetBytes') {
    $fn = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true)
    . ([scriptblock]::Create($fn.Extent.Text))
}

$sep = (Get-Culture).NumberFormat.NumberDecimalSeparator
foreach ($c in @(@(0, '0 KB/s'), @(2048, '2 KB/s'), @(1MB, "1${sep}0 MB/s"), @(2.5MB, "2${sep}5 MB/s"))) {
    $got = Format-Rate $c[0]
    if ($got -ne $c[1]) { throw "Format-Rate $($c[0]): esperaba '$($c[1])', salió '$got'" }
}

$net = Get-NetBytes
if ($net.Rx -lt 0 -or $net.Tx -lt 0 -or $null -eq $net.Time) { throw 'Get-NetBytes devolvió datos inválidos' }

'OK'
