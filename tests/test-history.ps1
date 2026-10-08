# These tests use UIAutomation constants and fake documents only. They never
# initialize the desktop, connect Chrome, move the mouse, or click anything.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'chatgpt-bulk-delete.ps1')

$script:passed = 0
$script:expectedFailure = '历史记录加载失败，不能确认完整列表；未继续删除。请在网页重试并恢复后重新运行。'
function Assert-True([bool]$Condition, [string]$Name) {
    if (-not $Condition) { throw "FAIL: $Name" }
    $script:passed++
    Write-Host "PASS: $Name"
}
function Assert-HistoryFailure([scriptblock]$Operation, [string]$Name) {
    $failure = $null
    try { & $Operation | Out-Null } catch { $failure=$_ }
    Assert-True ($null -ne $failure) $Name
    Assert-True ($failure.Exception.Message -ceq $script:expectedFailure) "$Name (history failure reported)"
}

function New-FakeRow([string]$Title, [int]$Identity) {
    $row = [pscustomobject]@{
        Identity=[int[]]@(42, $Identity)
        Current=[pscustomobject]@{
            Name=$Title
            IsOffscreen=$false
            BoundingRectangle=[pscustomobject]@{X=0; Y=20; Width=250; Height=20; Bottom=40}
        }
    }
    $row | Add-Member -MemberType ScriptMethod -Name GetRuntimeId -Value { return ,$this.Identity }
    $row
}
function New-FakeDocument([string[]]$Names) {
    $document = [pscustomobject]@{Names=@($Names)}
    $document | Add-Member -MemberType ScriptMethod -Name FindAll -Value {
        param($Scope, $Condition)
        $script:history.DocumentReads++
        if ($Scope -ne [System.Windows.Automation.TreeScope]::Descendants -or
            $Condition.Property -ne [System.Windows.Automation.AutomationElement]::NameProperty) {
            throw 'Unexpected history query: must use descendant NameProperty.'
        }
        $matches = @($this.Names | Where-Object { $_ -ceq $Condition.Value } | ForEach-Object {
            [pscustomobject]@{Current=[pscustomobject]@{Name=$_}}
        })
        return ,$matches
    }
    $document
}
function Reset-History([string[]]$Names=@(), [int]$AppearAtContext=1) {
    $script:history = @{
        Names=@($Names); AppearAtContext=$AppearAtContext
        ContextReads=0; DocumentReads=0; RowReads=0; Scrolls=0
        Rows=@((New-FakeRow '保留甲' 1), (New-FakeRow '保留乙' 2))
        Events=[Collections.Generic.List[object]]::new()
    }
    $script:MaxScrollRounds = 8
    $script:TimeoutSeconds = 10
    $script:pendingOtherIds = @('42.1', '42.2')
    $script:pendingRowCount = 3
}

function Get-ChatContext {
    $script:history.ContextReads++
    $names = @()
    if ($script:history.ContextReads -ge $script:history.AppearAtContext) { $names=@($script:history.Names) }
    $document = New-FakeDocument $names
    $sidebar = [pscustomobject]@{
        Current=[pscustomobject]@{
            BoundingRectangle=[pscustomobject]@{X=0; Y=0; Width=300; Height=600; Bottom=600}
        }
    }
    $sidebar | Add-Member -MemberType ScriptMethod -Name FindAll -Value {
        param($Scope, $Condition)
        $script:history.RowReads++
        if ($Scope -ne [System.Windows.Automation.TreeScope]::Descendants -or
            $Condition.Property -ne [System.Windows.Automation.AutomationElement]::ControlTypeProperty -or
            $Condition.Value -ne [System.Windows.Automation.ControlType]::ListItem) {
            throw 'Unexpected sidebar row query.'
        }
        return ,$script:history.Rows
    }
    [pscustomobject]@{Root=$null; Document=$document; Sidebar=$sidebar; Address='https://chatgpt.com/'}
}
function New-PropertyCondition($Property, $Value) {
    [pscustomobject]@{Property=$Property; Value=$Value}
}
function Scroll-ChatSidebar($Snapshot) { $script:history.Scrolls++ }
function Start-Sleep([int]$Seconds=0, [int]$Milliseconds=0) { }
function Get-DeletionDialogSnapshot {
    [pscustomobject]@{Context=$null; Dialogs=@()}
}
function Write-RunEvent([string]$Status, [string]$Title, [string]$Detail='') {
    $script:history.Events.Add([pscustomobject]@{Status=$Status; Title=$Title; Detail=$Detail})
}

$messages = @(
    '无法加载历史记录',
    'Unable to load history',
    'Unable to load chat history',
    'Failed to load chat history'
)
foreach ($message in $messages) {
    Reset-History @($message)
    Assert-HistoryFailure { Assert-HistoryLoaded (New-FakeDocument @($message)) } "Recognize loading error: $message"
    Reset-History @($message)
    Assert-HistoryFailure { Get-SidebarSnapshot } "Block partial snapshot: $message"
    Assert-True ($script:history.RowReads -eq 0) "Check loading error before reading list rows: $message"
    Reset-History @($message)
    Assert-HistoryFailure { Scan-AllChatRows } "Loading error cannot become a stable scan bottom: $message"
    Assert-True ($script:history.RowReads -eq 0 -and $script:history.Scrolls -eq 0) "Stop scanning immediately on loading error: $message"
}

Reset-History
Assert-HistoryLoaded (New-FakeDocument @())
Assert-True ($script:history.DocumentReads -eq 4) 'A normal document checks every supported loading-error label'
$snapshot = Get-SidebarSnapshot
Assert-True ($snapshot.Inventory.Count -eq 2 -and -not $snapshot.Loading -and $script:history.RowReads -eq 1) 'Normal history remains readable'

Reset-History @('无法加载历史记录的原因', 'Unable to load history example', 'Failed to load chat history details')
$snapshot = Get-SidebarSnapshot
Assert-True ($snapshot.Inventory.Count -eq 2 -and $script:history.RowReads -eq 1) 'Similar conversation text cannot trigger an exact error-label match'

Reset-History
$snapshot = Scan-AllChatRows
Assert-True ($snapshot.Inventory.Count -eq 2 -and $script:history.RowReads -eq 5 -and $script:history.Scrolls -eq 4) 'A healthy stable bottom still completes full scanning'

Reset-History @('无法加载历史记录') 3
Assert-HistoryFailure { Scan-AllChatRows } 'A loading error appearing during scanning blocks completion'
Assert-True ($script:history.ContextReads -eq 3 -and $script:history.RowReads -eq 2 -and $script:history.Scrolls -eq 2) 'A later error is checked again before accepting partial rows'

$plan = [pscustomobject]@{Title='目标会话'; RuntimeId='42.999'}
Reset-History @('无法加载历史记录')
Assert-HistoryFailure { Wait-DeletionRemoval $plan } 'Post-deletion history failure cannot authorize verification'
Assert-True ($script:history.RowReads -eq 0 -and $script:history.Events.Count -eq 0) 'A failed history load cannot record DeletedAndVerified'

Reset-History
Wait-DeletionRemoval $plan
Assert-True ($script:history.RowReads -eq 3 -and
    @($script:history.Events | Where-Object { $_.Status -ceq 'DeletedAndVerified' }).Count -eq 1) 'Healthy history still permits three-round removal verification'

Write-Host "All $script:passed history-loading regression tests passed. No browser was operated."
