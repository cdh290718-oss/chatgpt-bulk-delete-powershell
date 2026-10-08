<#
Windows + Chrome + ChatGPT 中文界面。
默认仅检查。添加 -Execute 后按 TXT 列表自动删除。
#>
[CmdletBinding()]
param(
    [string]$ListPath = '',
    [switch]$Execute,
    [long]$WindowHandle = 0,
    [ValidateRange(10, 300)][int]$WaitSeconds = 10,
    [ValidateRange(10, 120)][int]$TimeoutSeconds = 60,
    [ValidateRange(4, 1000)][int]$MaxScrollRounds = 200,
    [switch]$LoadedOnly,
    [switch]$VerifyDeletion
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$script:scriptVersion = '1.4.1'
Import-Module (Join-Path $PSScriptRoot 'ChatDelete.Core.psm1') -Force

function Initialize-Desktop {
    Add-Type -AssemblyName UIAutomationClient
    Add-Type -AssemblyName UIAutomationTypes
    if (-not ('ChatDeleteDesktop' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class ChatDeleteDesktop {
    private delegate bool WindowVisitor(IntPtr window, IntPtr data);
    [DllImport("user32.dll")] private static extern bool EnumWindows(WindowVisitor visitor, IntPtr data);
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll")] private static extern bool IsWindow(IntPtr window);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr window);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr window, int command);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr window);
    [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr window);
    [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint from, uint to, bool attach);
    [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] private static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extra);
    public static void Wheel(int amount) { mouse_event(0x800, 0, 0, unchecked((uint)amount), UIntPtr.Zero); }
    public static IntPtr[] ChromeWindows() {
        var result = new System.Collections.Generic.List<IntPtr>();
        EnumWindows(delegate(IntPtr window, IntPtr data) {
            if (!IsWindowVisible(window)) return true;
            uint processId;
            GetWindowThreadProcessId(window, out processId);
            try {
                if (System.Diagnostics.Process.GetProcessById((int)processId).ProcessName == "chrome") result.Add(window);
            } catch { }
            return true;
        }, IntPtr.Zero);
        return result.ToArray();
    }
    public static bool IsOwnedWindow(IntPtr window, uint expectedProcessId) {
        if (!IsWindow(window)) return false;
        uint actualProcessId;
        GetWindowThreadProcessId(window, out actualProcessId);
        return actualProcessId == expectedProcessId;
    }
    public static bool Activate(IntPtr window) {
        if (IsIconic(window)) ShowWindow(window, 9);
        uint process;
        uint foregroundThread = GetWindowThreadProcessId(GetForegroundWindow(), out process);
        uint ownThread = GetCurrentThreadId();
        bool attached = foregroundThread != 0 && foregroundThread != ownThread && AttachThreadInput(ownThread, foregroundThread, true);
        try { BringWindowToTop(window); SetForegroundWindow(window); }
        finally { if (attached) AttachThreadInput(ownThread, foregroundThread, false); }
        return GetForegroundWindow() == window;
    }
}
'@
    }
    [ChatDeleteDesktop]::SetProcessDPIAware() | Out-Null
    $script:activator = New-Object -ComObject WScript.Shell
}

function New-PropertyCondition($Property, $Value) {
    [System.Windows.Automation.PropertyCondition]::new($Property, $Value)
}

function New-NamedCondition([string]$Name, $Type) {
    [System.Windows.Automation.AndCondition]::new(
        (New-PropertyCondition ([System.Windows.Automation.AutomationElement]::NameProperty) $Name),
        (New-PropertyCondition ([System.Windows.Automation.AutomationElement]::ControlTypeProperty) $Type))
}

function Find-Unique($Root, $Condition, [string]$Description) {
    $elements = $Root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $Condition)
    if ($elements.Count -ne 1) { throw "$Description：应找到 1 个，实际找到 $($elements.Count) 个。" }
    $elements[0]
}

function Read-BrowserAddress($Root) {
    $address = $Root.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
        (New-PropertyCondition ([System.Windows.Automation.AutomationElement]::AutomationIdProperty) 'view_1012'))
    if ($null -eq $address) { throw '未找到 Chrome 地址栏。' }
    ([System.Windows.Automation.ValuePattern]$address.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)).Current.Value
}

function Connect-ChatWindow {
    $candidates = @()
    foreach ($handle in @([ChatDeleteDesktop]::ChromeWindows())) {
        if ($WindowHandle -ne 0 -and $handle.ToInt64() -ne $WindowHandle) { continue }
        try {
            $root = [System.Windows.Automation.AutomationElement]::FromHandle($handle)
            $address = Read-BrowserAddress $root
            if (Test-ChatGptLocation $address) {
                $candidates += [pscustomobject]@{ ProcessId=$root.Current.ProcessId; Handle=$handle; Address=$address; Caption=$root.Current.Name }
            }
        } catch { continue }
    }
    if ($candidates.Count -eq 0) { throw '请在 Chrome 中打开并登录 chatgpt.com，展开聊天侧边栏后再运行。' }
    if ($candidates.Count -gt 1) {
        $details = ($candidates | ForEach-Object { "$($_.Handle.ToInt64()) / $($_.Caption)" }) -join '; '
        throw "找到多个 ChatGPT 窗口，请关闭多余窗口，或用 -WindowHandle 指定一个。$details"
    }
    $script:browser = $candidates[0]
    Write-Host "已连接 Chrome：$($browser.Caption)；窗口 $($browser.Handle.ToInt64())"
}

function Assert-Unlocked {
    $foreground = [ChatDeleteDesktop]::GetForegroundWindow()
    $foregroundProcessId = [uint32]0
    [ChatDeleteDesktop]::GetWindowThreadProcessId($foreground, [ref]$foregroundProcessId) | Out-Null
    if ($foregroundProcessId -ne 0) {
        $process = Get-Process -Id $foregroundProcessId -ErrorAction SilentlyContinue
        if ($null -ne $process -and $process.ProcessName -in @('LockApp', 'LogonUI')) {
            throw 'Windows 已锁屏。请解锁后重新运行；脚本不能在锁屏状态下操作浏览器。'
        }
    }
}

function Activate-ChatWindow {
    Assert-Unlocked
    $process = Get-Process -Id $browser.ProcessId -ErrorAction Stop
    if ($process.ProcessName -cne 'chrome' -or -not [ChatDeleteDesktop]::IsOwnedWindow($browser.Handle, [uint32]$browser.ProcessId)) { throw 'Chrome 窗口已变化，停止操作。' }
    if ([ChatDeleteDesktop]::IsIconic($browser.Handle)) { [ChatDeleteDesktop]::ShowWindow($browser.Handle, 9) | Out-Null }
    $activator.AppActivate($browser.ProcessId) | Out-Null
    [ChatDeleteDesktop]::Activate($browser.Handle) | Out-Null
    Start-Sleep -Milliseconds 150
    Assert-Foreground
}

function Assert-Foreground {
    Assert-Unlocked
    if ([ChatDeleteDesktop]::GetForegroundWindow() -ne $browser.Handle) { throw 'Chrome 失去前台焦点，停止操作。运行期间请勿操作这个窗口。' }
}

function Get-ChatPageContext {
    $process = Get-Process -Id $browser.ProcessId -ErrorAction Stop
    if ($process.ProcessName -cne 'chrome' -or -not [ChatDeleteDesktop]::IsOwnedWindow($browser.Handle, [uint32]$browser.ProcessId)) { throw 'Chrome 窗口已变化。' }
    $root = [System.Windows.Automation.AutomationElement]::FromHandle($browser.Handle)
    $address = Read-BrowserAddress $root
    if (-not (Test-ChatGptLocation $address)) { throw '当前标签页已离开 chatgpt.com，停止操作。' }
    $document = Find-Unique $root (New-PropertyCondition ([System.Windows.Automation.AutomationElement]::AutomationIdProperty) 'RootWebArea') '网页'
    [pscustomobject]@{ Root=$root; Document=$document; Address=$address }
}

function Get-ChatContext {
    $page = Get-ChatPageContext
    $sidebar = Find-Unique $page.Document (New-NamedCondition '聊天记录' ([System.Windows.Automation.ControlType]::Group)) '聊天记录侧边栏'
    [pscustomobject]@{ Root=$page.Root; Document=$page.Document; Sidebar=$sidebar; Address=$page.Address }
}

function Get-DeletionDialogSnapshot {
    # Chrome 在模态框打开时隐藏背景控件，此处不能要求侧边栏存在。
    $page = Get-ChatPageContext
    $dialogs = @($page.Document.FindAll([System.Windows.Automation.TreeScope]::Descendants,
        (New-NamedCondition '删除聊天？' ([System.Windows.Automation.ControlType]::Window))))
    [pscustomobject]@{ Context=$page; Dialogs=$dialogs }
}

function Clear-WhitelistedPendingDialog([string[]]$Titles) {
    $dialogs = (Get-DeletionDialogSnapshot).Dialogs
    if ($dialogs.Count -eq 0) { return }
    if ($dialogs.Count -ne 1) { throw '存在多个删除确认框，未继续操作。' }
    $dialog = $dialogs[0]
    $texts = @($dialog.FindAll([System.Windows.Automation.TreeScope]::Descendants,
        (New-PropertyCondition ([System.Windows.Automation.AutomationElement]::ControlTypeProperty) ([System.Windows.Automation.ControlType]::Text))) | ForEach-Object { $_.Current.Name })
    $matches = @($Titles | Where-Object { Test-DeletionConfirmation $_ $texts })
    if ($matches.Count -ne 1) { throw '已有不属于当前清单的删除确认框。请先手动关闭后再运行。' }
    $cancel = Find-Unique $dialog (New-NamedCondition '取消' ([System.Windows.Automation.ControlType]::Button)) '取消按钮'
    if (-not $cancel.Current.IsEnabled) { throw '删除确认框的取消按钮不可用。' }
    Assert-Foreground
    Invoke-UiElement $cancel
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        Start-Sleep -Milliseconds 250
        $page = Get-ChatPageContext
        $remaining = $page.Document.FindAll([System.Windows.Automation.TreeScope]::Descendants,
            (New-NamedCondition '删除聊天？' ([System.Windows.Automation.ControlType]::Window)))
        $sidebars = $page.Document.FindAll([System.Windows.Automation.TreeScope]::Descendants,
            (New-NamedCondition '聊天记录' ([System.Windows.Automation.ControlType]::Group)))
        if ($remaining.Count -eq 0 -and $sidebars.Count -eq 1) {
            Write-RunEvent 'PendingDialogCancelled' $matches[0]
            return
        }
    } while ([DateTime]::UtcNow -lt $deadline)
    throw '遗留的删除确认框未能关闭，未继续操作。'
}

function Invoke-UiElement($Element) {
    ([System.Windows.Automation.InvokePattern]$Element.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)).Invoke()
}

function Assert-HistoryLoaded($Document) {
    foreach ($name in @('无法加载历史记录', 'Unable to load history', 'Unable to load chat history', 'Failed to load chat history')) {
        $errors = $Document.FindAll([System.Windows.Automation.TreeScope]::Descendants,
            (New-PropertyCondition ([System.Windows.Automation.AutomationElement]::NameProperty) $name))
        if ($errors.Count -gt 0) { throw '历史记录加载失败，不能确认完整列表；未继续删除。请在网页重试并恢复后重新运行。' }
    }
}

function Get-SidebarSnapshot {
    $context = Get-ChatContext
    Assert-HistoryLoaded $context.Document
    $rows = $context.Sidebar.FindAll([System.Windows.Automation.TreeScope]::Descendants,
        (New-PropertyCondition ([System.Windows.Automation.AutomationElement]::ControlTypeProperty) ([System.Windows.Automation.ControlType]::ListItem)))
    $inventory = @()
    $loading = $false
    foreach ($row in $rows) {
        $name = $row.Current.Name
        if ($name -in @('正在加载聊天', '正在加载聊天…', 'Loading chats', 'Loading chats...')) { $loading=$true; continue }
        if ([string]::IsNullOrWhiteSpace($name)) { continue }
        $inventory += [pscustomobject]@{ Title=$name; RuntimeId=($row.GetRuntimeId() -join '.'); Element=$row }
    }
    [pscustomobject]@{ Context=$context; Inventory=$inventory; Loading=$loading }
}

function Scroll-ChatSidebar($Snapshot) {
    Assert-Foreground
    $bounds = $Snapshot.Context.Sidebar.Current.BoundingRectangle
    if ($bounds.Width -le 0 -or $bounds.Height -le 0) { throw '侧边栏不可见。' }
    $point = [System.Windows.Point]::new($bounds.X + $bounds.Width * 0.45, $bounds.Y + $bounds.Height * 0.70)
    [ChatDeleteDesktop]::SetCursorPos([int]$point.X, [int]$point.Y) | Out-Null
    $hit = [System.Windows.Automation.AutomationElement]::FromPoint($point)
    $sidebarId = $Snapshot.Context.Sidebar.GetRuntimeId() -join '.'
    $inside = $false
    for ($depth=0; $null -ne $hit -and $depth -lt 30; $depth++) {
        if (($hit.GetRuntimeId() -join '.') -ceq $sidebarId) { $inside=$true; break }
        $hit = [System.Windows.Automation.TreeWalker]::RawViewWalker.GetParent($hit)
    }
    if (-not $inside) { throw '侧边栏被弹窗或其他窗口遮挡。请关闭弹窗后重新运行。' }
    Assert-Foreground
    [ChatDeleteDesktop]::Wheel(-2400)
}

function Scan-AllChatRows {
    $previousIds = @{}
    $lastSignature = ''
    $stableRounds = 0
    for ($round=1; $round -le $MaxScrollRounds; $round++) {
        $snapshot = Get-SidebarSnapshot
        $currentIds = @{}
        foreach ($item in $snapshot.Inventory) { $currentIds[$item.RuntimeId]=$true }
        foreach ($oldId in $previousIds.Keys) {
            if (-not $currentIds.ContainsKey($oldId)) { throw '扫描时聊天列表发生替换或虚拟化，无法可靠检查同名会话。停止扫描。' }
        }
        $previousIds = $currentIds
        $signature = (@($snapshot.Inventory | ForEach-Object { $_.RuntimeId }) -join '|')
        $lastVisible = ($snapshot.Inventory.Count -eq 0 -and -not $snapshot.Loading)
        if ($snapshot.Inventory.Count -gt 0) {
            $last = $snapshot.Inventory[-1].Element.Current.BoundingRectangle
            $view = $snapshot.Context.Sidebar.Current.BoundingRectangle
            $lastVisible = ($last.Height -gt 0 -and $last.Y -ge $view.Y -and $last.Bottom -le $view.Bottom -and -not $snapshot.Inventory[-1].Element.Current.IsOffscreen)
        }
        if ($signature -ceq $lastSignature -and -not $snapshot.Loading -and $lastVisible) { $stableRounds++ }
        else { $stableRounds=0 }
        $lastSignature=$signature
        Write-Host "扫描 $round/$MaxScrollRounds：已加载 $($snapshot.Inventory.Count) 个列表项，底部稳定 $stableRounds/4。"
        if ($stableRounds -ge 4) { return $snapshot }
        Scroll-ChatSidebar $snapshot
        Start-Sleep -Milliseconds 1400
    }
    throw '扫描未能确认列表底部。未执行任何删除。可增加 -MaxScrollRounds，或检查网络及侧边栏状态。'
}

function Write-RunEvent([string]$Status, [string]$Title, [string]$Detail='') {
    $event = [pscustomobject]@{ RunId=$runId; Time=[DateTimeOffset]::Now.ToString('o'); Status=$Status; Title=$Title; Detail=$Detail }
    $line = $event | ConvertTo-Json -Compress
    [IO.File]::AppendAllText((Join-Path $runDirectory 'events.jsonl'), $line + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
}

function Write-JsonFile([string]$Path, $Value) {
    [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))
}

function Get-BoundTargetRow($PlanItem) {
    $context = Get-ChatContext
    $row = Find-Unique $context.Sidebar (New-NamedCondition $PlanItem.Title ([System.Windows.Automation.ControlType]::ListItem)) "会话 $($PlanItem.Title)"
    if (($row.GetRuntimeId() -join '.') -cne $PlanItem.RuntimeId) { throw '该会话的界面身份已变化，请重新检查列表。' }
    [pscustomobject]@{ Context=$context; Row=$row }
}

function Open-TargetDeletionDialog($PlanItem) {
    $before = Get-SidebarSnapshot
    $script:pendingRowCount = $before.Inventory.Count
    $script:pendingOtherIds = @($before.Inventory | Where-Object { $_.RuntimeId -cne $PlanItem.RuntimeId } | ForEach-Object { $_.RuntimeId })
    $bound = Get-BoundTargetRow $PlanItem
    $existingDialogs = $bound.Context.Document.FindAll([System.Windows.Automation.TreeScope]::Descendants,
        (New-PropertyCondition ([System.Windows.Automation.AutomationElement]::ControlTypeProperty) ([System.Windows.Automation.ControlType]::Window)))
    if ($existingDialogs.Count -gt 0) { throw '网页有未关闭的对话框，停止操作。' }
    $button = Find-Unique $bound.Row (New-NamedCondition '聊天操作' ([System.Windows.Automation.ControlType]::Button)) '会话操作按钮'
    Assert-Foreground
    ([System.Windows.Automation.ExpandCollapsePattern]$button.GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern)).Expand()
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $menu = $null
    do {
        Start-Sleep -Milliseconds 250
        $bound = Get-BoundTargetRow $PlanItem
        $button = Find-Unique $bound.Row (New-NamedCondition '聊天操作' ([System.Windows.Automation.ControlType]::Button)) '会话操作按钮'
        $state = ([System.Windows.Automation.ExpandCollapsePattern]$button.GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern)).Current.ExpandCollapseState
        $menus = $bound.Context.Document.FindAll([System.Windows.Automation.TreeScope]::Descendants,
            (New-NamedCondition '聊天操作' ([System.Windows.Automation.ControlType]::Menu)))
        if ($state -eq [System.Windows.Automation.ExpandCollapseState]::Expanded -and $menus.Count -eq 1) { $menu=$menus[0]; break }
    } while ([DateTime]::UtcNow -lt $deadline)
    if ($null -eq $menu) { throw '未能打开目标会话的操作菜单。' }
    $delete = Find-Unique $menu (New-NamedCondition '删除' ([System.Windows.Automation.ControlType]::MenuItem)) '删除菜单项'
    # 最后一次核对背景行须在打开模态框之前完成。
    Get-BoundTargetRow $PlanItem | Out-Null
    Assert-Foreground
    Invoke-UiElement $delete
    Write-RunEvent 'DeletionMenuInvoked' $PlanItem.Title
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        Start-Sleep -Milliseconds 250
        $dialogs = (Get-DeletionDialogSnapshot).Dialogs
        if ($dialogs.Count -eq 1) {
            Write-RunEvent 'DialogOpened' $PlanItem.Title
            return $dialogs[0]
        }
        if ($dialogs.Count -gt 1) { throw '存在多个删除确认框。' }
    } while ([DateTime]::UtcNow -lt $deadline)
    throw '删除确认框未出现。'
}

function Confirm-Deletion($PlanItem, $Dialog) {
    $dialogs = (Get-DeletionDialogSnapshot).Dialogs
    if ($dialogs.Count -ne 1) { throw '删除确认框不唯一或已关闭，未确认删除。' }
    if (($dialogs[0].GetRuntimeId() -join '.') -cne ($Dialog.GetRuntimeId() -join '.')) { throw '删除确认框已变化，未确认删除。' }
    $Dialog = $dialogs[0]
    $texts = @($Dialog.FindAll([System.Windows.Automation.TreeScope]::Descendants,
        (New-PropertyCondition ([System.Windows.Automation.AutomationElement]::ControlTypeProperty) ([System.Windows.Automation.ControlType]::Text))) | ForEach-Object { $_.Current.Name })
    if (-not (Test-DeletionConfirmation $PlanItem.Title $texts)) { throw '确认框中的完整标题不匹配，未确认删除。' }
    $button = Find-Unique $Dialog (New-NamedCondition '删除聊天' ([System.Windows.Automation.ControlType]::Button)) '删除聊天按钮'
    if (-not $button.Current.IsEnabled) { throw '删除按钮不可用。' }
    Write-RunEvent 'Prepared' $PlanItem.Title $PlanItem.RuntimeId
    Assert-Foreground
    try {
        Invoke-UiElement $button
        Write-RunEvent 'ConfirmationSubmitted' $PlanItem.Title
    } finally {
        # 即使提交后日志写入失败，也执行用户要求的等待；不会重复点击确认。
        Start-Sleep -Seconds $WaitSeconds
    }
    if ($VerifyDeletion) {
        Wait-DeletionRemoval $PlanItem
        return 'DeletedAndVerified'
    }
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $pendingLogged = $false
    do {
        $remainingDialogs = (Get-DeletionDialogSnapshot).Dialogs
        if ($remainingDialogs.Count -gt 1) { throw '提交后出现多个删除确认框，停止后续操作。' }
        if ($remainingDialogs.Count -eq 0) {
            Write-RunEvent 'SubmittedWithoutVerification' $PlanItem.Title '确认框已关闭；按用户要求不核验列表中是否已移除。'
            return 'SubmittedWithoutVerification'
        }
        if (-not $pendingLogged) {
            Write-RunEvent 'ConfirmationStillOpen' $PlanItem.Title '等待 10 秒后确认框仍在；等待页面请求结束，不核验侧边栏。'
            $pendingLogged = $true
        }
        Start-Sleep -Milliseconds 500
    } while ([DateTime]::UtcNow -lt $deadline)
    $remainingDialogs = (Get-DeletionDialogSnapshot).Dialogs
    if ($remainingDialogs.Count -eq 0) {
        Write-RunEvent 'SubmittedWithoutVerification' $PlanItem.Title '确认框已关闭；按用户要求不核验列表中是否已移除。'
        return 'SubmittedWithoutVerification'
    }
    if ($remainingDialogs.Count -ne 1) { throw '提交后出现多个删除确认框，停止后续操作。' }
    $cancel = Find-Unique $remainingDialogs[0] (New-NamedCondition '取消' ([System.Windows.Automation.ControlType]::Button)) '取消按钮'
    if (-not $cancel.Current.IsEnabled) {
        throw '删除请求持续未完成，确认框及取消按钮仍被禁用；已停止后续操作，请等待网页响应。'
    }
    Clear-WhitelistedPendingDialog @($PlanItem.Title)
    Write-RunEvent 'SubmissionUnconfirmed' $PlanItem.Title '确认框超时后已取消；该会话可能尚未删除，请下次重新扫描。'
    return 'SubmissionUnconfirmed'
}

function Wait-DeletionRemoval($PlanItem) {
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $verifiedRounds = 0
    $lastState = [pscustomobject]@{ DialogCount=-1; TargetTitleCount=-1; TargetIdentityCount=-1; LoadedRows=-1; MinimumRows=[Math]::Max(0, $pendingRowCount - 2); MissingOriginalRowIds=-1; Loading=$true }
    do {
        $dialogs = (Get-DeletionDialogSnapshot).Dialogs
        if ($dialogs.Count -gt 1) { throw '提交后出现多个删除确认框，停止核验。' }
        if ($dialogs.Count -gt 0) {
            $verifiedRounds=0
            $lastState.DialogCount=$dialogs.Count
            Start-Sleep -Milliseconds 500
            continue
        }
        $snapshot = Get-SidebarSnapshot
        $remaining = @($snapshot.Inventory | Where-Object { $_.Title -ceq $PlanItem.Title })
        $sameIdentity = @($snapshot.Inventory | Where-Object { $_.RuntimeId -ceq $PlanItem.RuntimeId })
        $currentIds = @{}
        foreach ($row in $snapshot.Inventory) { $currentIds[$row.RuntimeId]=$true }
        $missingOriginalRowIds = 0
        foreach ($anchor in $pendingOtherIds) {
            if (-not $currentIds.ContainsKey($anchor)) { $missingOriginalRowIds++ }
        }
        $enoughRows = ($snapshot.Inventory.Count -ge $lastState.MinimumRows)
        $lastState = [pscustomobject]@{ DialogCount=0; TargetTitleCount=$remaining.Count; TargetIdentityCount=$sameIdentity.Count; LoadedRows=$snapshot.Inventory.Count; MinimumRows=$lastState.MinimumRows; MissingOriginalRowIds=$missingOriginalRowIds; Loading=$snapshot.Loading }
        # 其他行在界面刷新后可能换 RuntimeId；只要求列表仍完整、目标已消失。
        if ($remaining.Count -eq 0 -and $sameIdentity.Count -eq 0 -and $enoughRows -and -not $snapshot.Loading) { $verifiedRounds++ }
        else { $verifiedRounds=0 }
        if ($verifiedRounds -ge 3) {
            Write-RunEvent 'DeletedAndVerified' $PlanItem.Title ($lastState | ConvertTo-Json -Compress)
            return
        }
        Start-Sleep -Milliseconds 500
    } while ([DateTime]::UtcNow -lt $deadline)
    Write-RunEvent 'VerificationTimedOut' $PlanItem.Title ($lastState | ConvertTo-Json -Compress)
    if ($lastState.DialogCount -eq 1) { Clear-WhitelistedPendingDialog @($PlanItem.Title) }
    throw '已提交删除，但未核验移除。已记录最后一次核验状态；请检查当前会话状态，勿盲目重试。'
}

# 点引用只加载函数，供回归测试和只读界面诊断使用。
if ($MyInvocation.InvocationName -eq '.') { return }
if ([string]::IsNullOrWhiteSpace($ListPath)) { $ListPath = Join-Path $PSScriptRoot 'titles.txt' }

$runDirectory = $null
$runId = [Guid]::NewGuid().ToString('N')
$results = [Collections.Generic.List[object]]::new()
$exitCode = 0
try {
    if ($Execute -and $LoadedOnly) { throw '-LoadedOnly 仅用于检查，不能与 -Execute 一起使用。' }
    $inputList = Read-DeletionList $ListPath
    $runDirectory = Join-Path (Join-Path $PSScriptRoot 'runs') $runId
    [IO.Directory]::CreateDirectory($runDirectory) | Out-Null
    Write-Host "读取 $($inputList.Titles.Count) 个标题；忽略 $($inputList.Duplicates.Count) 个重复输入。"
    Write-Host $(if ($Execute -and $VerifyDeletion) { '模式：自动删除并核验。运行期间请保持屏幕解锁，不要操作此 Chrome 窗口。' } elseif ($Execute) { '模式：自动提交删除，等待后继续；不核验删除结果。运行期间请保持屏幕解锁，不要操作此 Chrome 窗口。' } else { '模式：仅检查，不打开删除菜单，不删除任何会话。' })
    Initialize-Desktop
    Connect-ChatWindow
    Assert-Unlocked
    $manifest = [pscustomobject]@{ RunId=$runId; ScriptVersion=$scriptVersion; ListPath=$inputList.Path; ListSha256=$inputList.Sha256; Titles=$inputList.Titles; Execute=[bool]$Execute; LoadedOnly=[bool]$LoadedOnly; VerifyDeletion=[bool]$VerifyDeletion; WaitSeconds=$WaitSeconds; BrowserWindow=$browser.Handle.ToInt64(); StartAddress=$browser.Address }
    Write-JsonFile (Join-Path $runDirectory 'manifest.json') $manifest
    if ($LoadedOnly) { $snapshot=Get-SidebarSnapshot }
    else {
        Activate-ChatWindow
        if ($Execute) { Clear-WhitelistedPendingDialog $inputList.Titles }
        $snapshot=Scan-AllChatRows
    }
    $plan = @(Get-DeletionPlan $inputList.Titles $snapshot.Inventory)
    $storedPlan = @($plan | Select-Object Title, Status, MatchCount, RuntimeId)
    Write-JsonFile (Join-Path $runDirectory 'plan.json') $storedPlan
    $plan | Select-Object Title, Status, MatchCount | Format-Table -AutoSize | Out-Host
    if ($LoadedOnly) { Write-Host '只检查当前已加载的侧边栏条目，不能据此确认完整历史记录。' }
    if (-not $Execute) {
        Write-Host '检查完成。确认列表后，添加 -Execute 或使用 run-delete.cmd 执行。'
        if (@($plan | Where-Object { $_.Status -ne 'Ready' }).Count -gt 0) { $exitCode=2 }
    } else {
        if (@($plan | Where-Object { $_.Status -eq 'Ambiguous' }).Count -gt 0) { throw '存在同名会话，整批未开始删除。请先重命名，确保标题唯一。' }
        foreach ($item in $plan) {
            if ($item.Status -eq 'NotFound') {
                $results.Add([pscustomobject]@{ Title=$item.Title; Status='NotFound' })
                Write-RunEvent 'NotFound' $item.Title '完整侧边栏扫描中未找到；不操作其他会话。'
                $exitCode=2
                continue
            }
            Write-Host "正在删除：$($item.Title)"
            try {
                Activate-ChatWindow
                $dialog = Open-TargetDeletionDialog $item
                $outcome = Confirm-Deletion $item $dialog
                $results.Add([pscustomobject]@{ Title=$item.Title; Status=$outcome })
                if ($outcome -ceq 'DeletedAndVerified') { Write-Host "已删除并核验：$($item.Title)" }
                elseif ($outcome -ceq 'SubmissionUnconfirmed') { Write-Host "确认框未关闭，已取消并跳过：$($item.Title)" -ForegroundColor Yellow; $exitCode=2 }
                else { Write-Host "已提交，未核验删除：$($item.Title)" }
            } catch {
                $results.Add([pscustomobject]@{ Title=$item.Title; Status='Stopped'; Reason=$_.Exception.Message })
                Write-RunEvent 'Stopped' $item.Title $_.Exception.Message
                throw
            }
        }
        $verifiedCount = @($results | Where-Object { $_.Status -eq 'DeletedAndVerified' }).Count
        $submittedCount = @($results | Where-Object { $_.Status -eq 'SubmittedWithoutVerification' }).Count
        $unconfirmedCount = @($results | Where-Object { $_.Status -eq 'SubmissionUnconfirmed' }).Count
        $notFoundCount = @($results | Where-Object { $_.Status -eq 'NotFound' }).Count
        Write-Host "完成：已提交但未核验 $submittedCount 个，删除并核验 $verifiedCount 个，提交结果未确认 $unconfirmedCount 个，未找到 $notFoundCount 个。"
    }
} catch {
    $exitCode=1
    Write-Host "停止：$($_.Exception.Message)" -ForegroundColor Red
    if ($null -ne $runDirectory) {
        try { Write-RunEvent 'RunStopped' '' $_.Exception.Message } catch { Write-Host '日志写入失败。' -ForegroundColor Red }
    }
} finally {
    if ($null -ne $runDirectory) {
        try { Write-JsonFile (Join-Path $runDirectory 'results.json') @($results.ToArray()) } catch { $exitCode=1 }
        Write-Host "本次记录：$runDirectory"
    }
}
exit $exitCode
