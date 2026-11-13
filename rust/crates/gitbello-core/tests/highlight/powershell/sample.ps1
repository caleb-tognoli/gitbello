<#
.SYNOPSIS
#>
# Line comment
param(
    [Parameter(Mandatory = $true)]
    [string]$Path,
    [int[]]$Sizes = @(1, 2, 0x10)
)

function Get-Inventory {
    [CmdletBinding()]
    param([string]$Name = 'bag')
    $items = Get-ChildItem -Path $Path -Filter "*.txt" -Recurse
    foreach ($item in $items) {
        if ($item.Length -gt 1kb -and -not $item.PSIsContainer) {
            Write-Host "Found $($item.Name) in $env:TEMP `n done"
        } elseif ($null -eq $item) {
            continue
        }
    }
    $label = 'it''s literal'
    $here = @"
    Hello $Name, $(Get-Date)
"@
    return [System.IO.Path]::Combine($Path, $Name) <# inline #>
}

Get-Inventory -Name "box" | Out-Null
$global:count += 1; $? ; $_
