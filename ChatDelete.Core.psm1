Set-StrictMode -Version 2.0

function Read-DeletionList {
    param([Parameter(Mandatory=$true)][string]$Path)
    $resolved = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).ProviderPath
    $bytes = [IO.File]::ReadAllBytes($resolved)
    $text = [Text.UTF8Encoding]::new($false, $true).GetString($bytes).TrimStart([char]0xFEFF)
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $titles = [Collections.Generic.List[string]]::new()
    $duplicates = [Collections.Generic.List[string]]::new()
    foreach ($line in ($text -split '\r\n|\n|\r')) {
        $title = $line.Trim()
        if ($title.Length -eq 0) { continue }
        if ($title -match '[\x00-\x1F\x7F]') { throw '标题中不能包含控制字符。' }
        if ($seen.Add($title)) { $titles.Add($title) } else { $duplicates.Add($title) }
    }
    if ($titles.Count -eq 0) { throw '列表为空。请在 TXT 文件中填写会话完整标题，每行一个。' }
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $hash = ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
    [pscustomobject]@{ Path=$resolved; Titles=$titles.ToArray(); Duplicates=$duplicates.ToArray(); Sha256=$hash }
}

function Get-DeletionPlan {
    param([string[]]$Titles, [object[]]$Inventory)
    foreach ($title in $Titles) {
        $matches = @($Inventory | Where-Object { [string]$_.Title -ceq $title })
        $status = if ($matches.Count -eq 1) { 'Ready' } elseif ($matches.Count -gt 1) { 'Ambiguous' } else { 'NotFound' }
        [pscustomobject]@{
            Title=$title; Status=$status; MatchCount=$matches.Count
            RuntimeId=if ($matches.Count -eq 1) { $matches[0].RuntimeId } else { $null }
        }
    }
}

function Test-ChatGptLocation {
    param([string]$Address)
    if ([string]::IsNullOrWhiteSpace($Address)) { return $false }
    $candidate = $Address.Trim()
    if ($candidate -notmatch '^[a-zA-Z][a-zA-Z0-9+.-]*://') { $candidate = 'https://' + $candidate }
    $uri = $null
    if (-not [Uri]::TryCreate($candidate, [UriKind]::Absolute, [ref]$uri)) { return $false }
    return ($uri.Scheme -ceq 'https' -and $uri.Host -ieq 'chatgpt.com' -and $uri.Port -eq 443 -and $uri.UserInfo.Length -eq 0)
}

function Test-DeletionConfirmation {
    param([string]$Title, [string[]]$Texts)
    if ([string]::IsNullOrWhiteSpace($Title)) { return $false }
    $expected = '这将永久删除“' + $Title + '”。此操作无法撤销。'
    return ($Texts -ccontains $expected)
}

Export-ModuleMember -Function Read-DeletionList, Get-DeletionPlan, Test-ChatGptLocation, Test-DeletionConfirmation
