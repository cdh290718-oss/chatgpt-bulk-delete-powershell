$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'ChatDelete.Core.psm1') -Force
$script:passed=0
function Assert-True([bool]$Condition, [string]$Name) {
    if (-not $Condition) { throw "FAIL: $Name" }
    $script:passed++
    Write-Host "PASS: $Name"
}
function Assert-Throws([scriptblock]$Operation, [string]$Name) {
    $threw=$false
    try { & $Operation | Out-Null } catch { $threw=$true }
    Assert-True $threw $Name
}

$fixtureRoot = Join-Path $PSScriptRoot 'fixtures'
[IO.Directory]::CreateDirectory($fixtureRoot) | Out-Null
$utf8 = [Text.UTF8Encoding]::new($false)
$inputPath = Join-Path $fixtureRoot 'input.txt'
[IO.File]::WriteAllText($inputPath, [char]0xFEFF + " 标题甲 `r`n`r`n标题甲`n标题  乙`nA`na`n#合法标题`n", $utf8)
$list = Read-DeletionList $inputPath
Assert-True ($list.Titles.Count -eq 5) 'UTF8 BOM, blank lines, exact deduplication'
Assert-True ($list.Titles[0] -ceq '标题甲') 'Trim only leading and trailing whitespace'
Assert-True ($list.Titles[1] -ceq '标题  乙') 'Preserve internal spaces'
Assert-True ($list.Titles[2] -ceq 'A' -and $list.Titles[3] -ceq 'a') 'Preserve case distinctions'
Assert-True ($list.Titles[4] -ceq '#合法标题') 'Do not treat literal titles as comments'
Assert-True ($list.Duplicates.Count -eq 1) 'Report duplicate inputs'
Assert-True ($list.Sha256 -match '^[0-9a-f]{64}$') 'Record input fingerprint'

$emptyPath = Join-Path $fixtureRoot 'empty.txt'
[IO.File]::WriteAllText($emptyPath, " `r`n`r`n", $utf8)
Assert-Throws { Read-DeletionList $emptyPath } 'Empty input cannot start a browser task'
$invalidPath = Join-Path $fixtureRoot 'invalid-utf8.txt'
[IO.File]::WriteAllBytes($invalidPath, [byte[]]@(0xC0,0xC0))
Assert-Throws { Read-DeletionList $invalidPath } 'Reject invalid UTF8 instead of changing a title'
$controlPath = Join-Path $fixtureRoot 'control.txt'
[IO.File]::WriteAllText($controlPath, "标题`0甲", $utf8)
Assert-Throws { Read-DeletionList $controlPath } 'Reject hidden control characters'

$inventory = @(
    [pscustomobject]@{Title='目标';RuntimeId='1'},
    [pscustomobject]@{Title='目标的副本';RuntimeId='2'},
    [pscustomobject]@{Title='重名';RuntimeId='3'},
    [pscustomobject]@{Title='重名';RuntimeId='4'},
    [pscustomobject]@{Title='a';RuntimeId='5'},
    [pscustomobject]@{Title='标题  乙';RuntimeId='6'}
)
$plan = @(Get-DeletionPlan @('目标','重名','缺失','A','标题 乙') $inventory)
Assert-True ($plan[0].Status -eq 'Ready' -and $plan[0].RuntimeId -ceq '1') 'Bind only the full matching title'
Assert-True ($plan[1].Status -eq 'Ambiguous' -and $null -eq $plan[1].RuntimeId) 'Duplicate conversations are ineligible'
Assert-True ($plan[2].Status -eq 'NotFound') 'Missing titles never select a substitute'
Assert-True ($plan[3].Status -eq 'NotFound') 'Matching is case sensitive'
Assert-True ($plan[4].Status -eq 'NotFound') 'Matching preserves internal spaces'
$emptyPlan = @(Get-DeletionPlan @('目标') @())
Assert-True ($emptyPlan[0].Status -eq 'NotFound') 'Empty inventory remains a missing result'

Assert-True (Test-DeletionConfirmation '目标' @('这将永久删除“目标”。此操作无法撤销。')) 'Exact dialog title accepted'
Assert-True (-not (Test-DeletionConfirmation '目标' @('这将永久删除“目标的副本”。此操作无法撤销。'))) 'Near-match dialog rejected'
Assert-True (-not (Test-DeletionConfirmation '目标' @('这将永久删除“其他”。此操作无法撤销。','目标'))) 'Unrelated text cannot authorize a different dialog'
Assert-True (-not (Test-DeletionConfirmation '' @('这将永久删除“”。此操作无法撤销。'))) 'Empty confirmation title rejected'

Assert-True (Test-ChatGptLocation 'chatgpt.com/g/g-p-example/c/example') 'Chrome display address accepted'
Assert-True (Test-ChatGptLocation 'https://chatgpt.com/') 'Deletion redirect to home accepted'
Assert-True (-not (Test-ChatGptLocation 'https://chatgpt.com.evil.test/')) 'Suffix impersonation rejected'
Assert-True (-not (Test-ChatGptLocation 'https://chatgpt.com@evil.test/')) 'URL user-info impersonation rejected'
Assert-True (-not (Test-ChatGptLocation 'http://chatgpt.com/')) 'Unencrypted location rejected'
Assert-True (-not (Test-ChatGptLocation 'https://chatgpt.com:8443/')) 'Unexpected port rejected'
Assert-True (-not (Test-ChatGptLocation 'file:///chatgpt.com')) 'Local file location rejected'

Write-Host "All $script:passed tests passed."
