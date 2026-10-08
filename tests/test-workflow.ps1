# UIAutomation types are loaded only for constants. No browser, native desktop,
# mouse, or real InvokePattern is initialized or used by these tests.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'chatgpt-bulk-delete.ps1')

$script:passed = 0
function Assert-True([bool]$Condition, [string]$Name) {
    if (-not $Condition) { throw "FAIL: $Name" }
    $script:passed++
    Write-Host "PASS: $Name"
}
function Assert-Throws([scriptblock]$Operation, [string]$Name, [string]$MessagePattern='') {
    $failure = $null
    try { & $Operation | Out-Null } catch { $failure = $_ }
    Assert-True ($null -ne $failure) $Name
    if ($MessagePattern) {
        Assert-True ($failure.Exception.Message -match $MessagePattern) "$Name (expected failure)"
    }
}

function New-FakeDialog([string]$Title, [int]$Identity=100, [bool]$Enabled=$true, [bool]$CancelEnabled=$true) {
    $button = [pscustomobject]@{
        Kind='Button'
        Current=[pscustomobject]@{Name='删除聊天'; IsEnabled=$Enabled}
    }
    $dialog = [pscustomobject]@{
        Kind='Dialog'
        Identity=[int[]]@(42, $Identity)
        TextNodes=@([pscustomobject]@{
            Current=[pscustomobject]@{Name=('这将永久删除“' + $Title + '”。此操作无法撤销。')}
        })
        Button=$button
        CancelButton=[pscustomobject]@{Kind='Button'; Current=[pscustomobject]@{Name='取消'; IsEnabled=$CancelEnabled}}
    }
    $dialog | Add-Member -MemberType ScriptMethod -Name GetRuntimeId -Value {
        return ,$this.Identity
    }
    $dialog | Add-Member -MemberType ScriptMethod -Name FindAll -Value {
        param($Scope, $Condition)
        return ,$this.TextNodes
    }
    return $dialog
}
function New-DialogStep([object[]]$Dialogs=@()) {
    [pscustomobject]@{Dialogs=@($Dialogs)}
}
function New-SidebarStep([object[]]$Inventory=@(), [bool]$Loading=$false) {
    [pscustomobject]@{Inventory=@($Inventory); Loading=$Loading}
}
function Reset-Workflow {
    $script:workflow = @{
        PageReads=0; SidebarReads=0; ForbiddenBackgroundReads=0
        ForegroundChecks=0; InvokeCount=0; AbortPageAfter=0; ForceRealDelay=$false
        CloseModalOnCancel=$false
        DialogSteps=@(); SidebarSteps=@(); CurrentDialogs=@()
        Events=[Collections.Generic.List[object]]::new()
        SleepSeconds=[Collections.Generic.List[int]]::new()
        SleepMilliseconds=[Collections.Generic.List[int]]::new()
    }
    $script:pendingOtherIds = @('anchor.1', 'anchor.2')
    $script:pendingRowCount = 3
    $script:WaitSeconds = 10
    $script:TimeoutSeconds = 10
    $script:VerifyDeletion = $false
}

# These overrides isolate the production workflow from the desktop. A dialog
# removes access to the background sidebar, as Chrome does for this modal.
function Get-ChatPageContext {
    $script:workflow.PageReads++
    if ($script:workflow.AbortPageAfter -gt 0 -and
        $script:workflow.PageReads -gt $script:workflow.AbortPageAfter) {
        throw 'TEST_STOP_POLL'
    }
    if ($script:workflow.DialogSteps.Count -eq 0) { throw 'Missing mock dialog sequence.' }
    $index = [Math]::Min($script:workflow.PageReads - 1, $script:workflow.DialogSteps.Count - 1)
    if ($script:workflow.CloseModalOnCancel) {
        $script:workflow.CurrentDialogs = @()
    } else {
        $script:workflow.CurrentDialogs = @($script:workflow.DialogSteps[$index].Dialogs)
    }
    $document = [pscustomobject]@{Dialogs=@($script:workflow.CurrentDialogs)}
    $document | Add-Member -MemberType ScriptMethod -Name FindAll -Value {
        param($Scope, $Condition)
        if ($Condition.Name -ceq '聊天记录') {
            if ($this.Dialogs.Count -eq 0) { return ,@([pscustomobject]@{Kind='Sidebar'}) }
            return ,@()
        }
        return ,$this.Dialogs
    }
    [pscustomobject]@{Root=$null; Document=$document; Address='https://chatgpt.com/'}
}
function Get-ChatContext {
    $script:workflow.ForbiddenBackgroundReads++
    throw 'TEST_BACKGROUND_BLOCKED'
}
function Get-SidebarSnapshot {
    if ($script:workflow.CurrentDialogs.Count -gt 0) {
        $script:workflow.ForbiddenBackgroundReads++
        throw 'TEST_BACKGROUND_BLOCKED'
    }
    $script:workflow.SidebarReads++
    if ($script:workflow.SidebarSteps.Count -eq 0) { throw 'Missing mock sidebar sequence.' }
    $index = [Math]::Min($script:workflow.SidebarReads - 1, $script:workflow.SidebarSteps.Count - 1)
    $script:workflow.SidebarSteps[$index]
}
function New-PropertyCondition($Property, $Value) {
    [pscustomobject]@{Property=$Property; Value=$Value}
}
function New-NamedCondition([string]$Name, $Type) {
    [pscustomobject]@{Name=$Name; Type=$Type}
}
function Find-Unique($Root, $Condition, [string]$Description) {
    if ($Root.Kind -cne 'Dialog' -or $Condition.Name -notin @('删除聊天','取消')) {
        throw "Unexpected Find-Unique: $Description"
    }
    if ($Condition.Name -ceq '取消') { return $Root.CancelButton }
    $Root.Button
}
function Assert-Foreground {
    $script:workflow.ForegroundChecks++
}
function Invoke-UiElement($Element) {
    if ($Element.Kind -cne 'Button') { throw 'Unexpected invoked element.' }
    $script:workflow.InvokeCount++
    if ($Element.Current.Name -ceq '取消') { $script:workflow.CloseModalOnCancel=$true }
}
function Write-RunEvent([string]$Status, [string]$Title, [string]$Detail='') {
    $script:workflow.Events.Add([pscustomobject]@{
        Status=$Status; Title=$Title; Detail=$Detail
        PageReads=$script:workflow.PageReads; SidebarReads=$script:workflow.SidebarReads
    })
}
function Start-Sleep([int]$Seconds=0, [int]$Milliseconds=0) {
    if ($script:workflow.ForceRealDelay -and $Milliseconds -gt 0) { [Threading.Thread]::Sleep($Milliseconds) }
    if ($Seconds -gt 0) { $script:workflow.SleepSeconds.Add($Seconds) }
    if ($Milliseconds -gt 0) { $script:workflow.SleepMilliseconds.Add($Milliseconds) }
}

$plan = [pscustomobject]@{Title='测试目标会话'; RuntimeId='target.1'}
$dialog = New-FakeDialog $plan.Title
$anchors = @(
    [pscustomobject]@{Title='保留甲'; RuntimeId='anchor.1'},
    [pscustomobject]@{Title='保留乙'; RuntimeId='anchor.2'}
)

Reset-Workflow
$script:workflow.DialogSteps = @(New-DialogStep @($dialog))
$snapshot = Get-DeletionDialogSnapshot
Assert-True ($snapshot.Dialogs.Count -eq 1 -and $snapshot.Dialogs[0] -eq $dialog) 'Read deletion modal without requesting its inaccessible background'
Assert-True ($script:workflow.ForbiddenBackgroundReads -eq 0 -and $script:workflow.SidebarReads -eq 0) 'Modal snapshot never reads sidebar'

Reset-Workflow
$script:workflow.DialogSteps = @((New-DialogStep @($dialog)), (New-DialogStep))
Clear-WhitelistedPendingDialog @($plan.Title)
Assert-True ($script:workflow.InvokeCount -eq 1 -and $script:workflow.PageReads -eq 2) 'A whitelisted pending modal is cancelled before the sidebar scan'
Assert-True (@($script:workflow.Events | Where-Object { $_.Status -ceq 'PendingDialogCancelled' -and $_.Title -ceq $plan.Title }).Count -eq 1) 'Cancelled modal is logged with the exact title'

Reset-Workflow
$script:workflow.DialogSteps = @(New-DialogStep @($dialog))
Assert-Throws { Clear-WhitelistedPendingDialog @('其他聊天') } 'A modal outside the input list is left alone' '不属于当前清单'
Assert-True ($script:workflow.InvokeCount -eq 0) 'Unlisted modal cannot be cancelled by the bulk script'

Reset-Workflow
$script:workflow.DialogSteps = @(New-DialogStep @((New-FakeDialog $plan.Title 100 $true $false)))
Assert-Throws { Clear-WhitelistedPendingDialog @($plan.Title) } 'Disabled cancel button stops safely' '取消按钮不可用'
Assert-True ($script:workflow.InvokeCount -eq 0) 'Disabled cancel button is not invoked'

Reset-Workflow
$script:VerifyDeletion = $true
$script:workflow.DialogSteps = @(
    (New-DialogStep @($dialog)), (New-DialogStep @($dialog)),
    (New-DialogStep), (New-DialogStep), (New-DialogStep)
)
$script:workflow.SidebarSteps = @(New-SidebarStep $anchors)
$verifiedOutcome = Confirm-Deletion $plan $dialog
Assert-True ($verifiedOutcome -ceq 'DeletedAndVerified') 'Optional verification mode reports a verified result'
Assert-True ($script:workflow.InvokeCount -eq 1) 'Correct confirmation submits exactly once despite inaccessible background'
Assert-True ($script:workflow.ForbiddenBackgroundReads -eq 0) 'Confirmation and pending modal verification avoid background controls'
Assert-True ($script:workflow.SleepSeconds.Count -eq 1 -and $script:workflow.SleepSeconds[0] -eq 10) 'Submit preserves requested ten second wait'
$verified = @($script:workflow.Events | Where-Object { $_.Status -ceq 'DeletedAndVerified' })
Assert-True ($verified.Count -eq 1 -and $verified[0].SidebarReads -eq 3 -and $verified[0].PageReads -eq 5) 'Only three consecutive complete post-modal snapshots authorize success'
Assert-True (@($script:workflow.Events | Where-Object { $_.Status -ceq 'ConfirmationSubmitted' }).Count -eq 1) 'Submission is logged once'

Reset-Workflow
$script:workflow.DialogSteps = @((New-DialogStep @($dialog)), (New-DialogStep))
$outcome = Confirm-Deletion $plan $dialog
Assert-True ($outcome -ceq 'SubmittedWithoutVerification') 'Default mode reports only submission when the modal closes'
Assert-True ($script:workflow.InvokeCount -eq 1 -and $script:workflow.SidebarReads -eq 0) 'Default mode submits once without reading the sidebar'
Assert-True ($script:workflow.SleepSeconds.Count -eq 1 -and $script:workflow.SleepSeconds[0] -eq 10) 'Default mode still waits ten seconds'
Assert-True (@($script:workflow.Events | Where-Object { $_.Status -ceq 'DeletedAndVerified' }).Count -eq 0) 'Unverified submission cannot claim deletion was verified'

Reset-Workflow
$script:workflow.DialogSteps = @(
    (New-DialogStep @($dialog)), (New-DialogStep @($dialog)),
    (New-DialogStep @($dialog)), (New-DialogStep)
)
$outcome = Confirm-Deletion $plan $dialog
Assert-True ($outcome -ceq 'SubmittedWithoutVerification') 'A slow modal may close after the initial ten-second wait'
Assert-True ($script:workflow.InvokeCount -eq 1 -and $script:workflow.SidebarReads -eq 0) 'Slow submission waits without cancelling or reading the sidebar'
Assert-True (@($script:workflow.Events | Where-Object { $_.Status -ceq 'ConfirmationStillOpen' }).Count -eq 1) 'Slow modal is logged once'

Reset-Workflow
$script:workflow.DialogSteps = @(New-DialogStep @($dialog))
$script:workflow.ForceRealDelay = $true
$outcome = Confirm-Deletion $plan $dialog
Assert-True ($outcome -ceq 'SubmissionUnconfirmed') 'An enabled modal still open at timeout is reported as unconfirmed'
Assert-True ($script:workflow.InvokeCount -eq 2 -and $script:workflow.SidebarReads -eq 0) 'Timed-out modal is cancelled without a second delete or sidebar verification'
Assert-True (@($script:workflow.Events | Where-Object { $_.Status -ceq 'PendingDialogCancelled' }).Count -eq 1) 'Timed-out modal cancellation is logged'

Reset-Workflow
$disabledAfterSubmit = New-FakeDialog $plan.Title 100 $true $false
$script:workflow.DialogSteps = @(New-DialogStep @($disabledAfterSubmit))
$script:workflow.ForceRealDelay = $true
Assert-Throws { Confirm-Deletion $plan $disabledAfterSubmit } 'Disabled cancel after request timeout stops safely' '取消按钮仍被禁用'
Assert-True ($script:workflow.InvokeCount -eq 1 -and $script:workflow.SidebarReads -eq 0) 'Disabled cancel is never invoked and does not authorize another deletion'

Reset-Workflow
$wrongTitle = New-FakeDialog ($plan.Title + '的副本')
$script:workflow.DialogSteps = @(New-DialogStep @($wrongTitle))
Assert-Throws { Confirm-Deletion $plan $dialog } 'Reject similar but different full confirmation title'
Assert-True ($script:workflow.InvokeCount -eq 0 -and $script:workflow.SleepSeconds.Count -eq 0) 'Title mismatch cannot click or begin submission wait'

Reset-Workflow
$anotherDialog = New-FakeDialog $plan.Title 101
$script:workflow.DialogSteps = @(New-DialogStep @($dialog, $anotherDialog))
Assert-Throws { Confirm-Deletion $plan $dialog } 'Reject multiple deletion dialogs'
Assert-True ($script:workflow.InvokeCount -eq 0) 'Multiple dialogs cannot submit'

Reset-Workflow
$script:workflow.DialogSteps = @(New-DialogStep @($anotherDialog))
Assert-Throws { Confirm-Deletion $plan $dialog } 'Reject a replacement modal with the same full title'
Assert-True ($script:workflow.InvokeCount -eq 0) 'Changed modal identity cannot submit'

Reset-Workflow
$disabled = New-FakeDialog $plan.Title 100 $false
$script:workflow.DialogSteps = @(New-DialogStep @($disabled))
Assert-Throws { Confirm-Deletion $plan $disabled } 'Reject disabled confirmation button'
Assert-True ($script:workflow.InvokeCount -eq 0) 'Disabled button cannot submit'

Reset-Workflow
$script:workflow.DialogSteps = @(
    (New-DialogStep @($dialog)), (New-DialogStep), (New-DialogStep), (New-DialogStep)
)
$script:workflow.SidebarSteps = @(New-SidebarStep $anchors)
Wait-DeletionRemoval $plan
Assert-True ($script:workflow.ForbiddenBackgroundReads -eq 0 -and $script:workflow.SidebarReads -eq 3) 'Removal waits for modal dismissal before reading three sidebar snapshots'
Assert-True ($script:workflow.InvokeCount -eq 0) 'Removal verification cannot resubmit confirmation'

Reset-Workflow
$script:workflow.DialogSteps = @(New-DialogStep)
$changedAnchors = @(
    [pscustomobject]@{Title='保留甲'; RuntimeId='new.1'},
    [pscustomobject]@{Title='保留乙'; RuntimeId='new.2'}
)
$script:workflow.SidebarSteps = @(New-SidebarStep $changedAnchors)
Wait-DeletionRemoval $plan
$changedVerification = @($script:workflow.Events | Where-Object { $_.Status -ceq 'DeletedAndVerified' })
Assert-True ($changedVerification.Count -eq 1 -and $changedVerification[0].SidebarReads -eq 3) 'Other rows may get new UI identities after the target is removed'
Assert-True ($changedVerification[0].Detail -match '"MissingOriginalRowIds":2') 'Verification log records changed row identities for diagnosis'

Reset-Workflow
$script:pendingRowCount = 4
$script:pendingOtherIds = @('anchor.1','anchor.2','anchor.3')
$script:workflow.DialogSteps = @(New-DialogStep)
$script:workflow.SidebarSteps = @(New-SidebarStep $anchors)
Wait-DeletionRemoval $plan
Assert-True (@($script:workflow.Events | Where-Object { $_.Status -ceq 'DeletedAndVerified' }).Count -eq 1) 'One additional sidebar row may disappear while the target is removed'

Reset-Workflow
$script:workflow.DialogSteps = @(New-DialogStep)
$script:workflow.SidebarSteps = @(New-SidebarStep @($anchors + [pscustomobject]@{Title=$plan.Title; RuntimeId=$plan.RuntimeId}))
$script:TimeoutSeconds = 10
$script:workflow.ForceRealDelay = $true
Assert-Throws { Wait-DeletionRemoval $plan } 'A target that remains visible times out without retrying deletion' '已提交删除，但未核验移除'
$timedOut = @($script:workflow.Events | Where-Object { $_.Status -ceq 'VerificationTimedOut' })
Assert-True ($timedOut.Count -eq 1 -and $timedOut[0].Detail -match '"TargetTitleCount":1') 'Timeout log identifies the condition that failed'
Assert-True ($script:workflow.InvokeCount -eq 0) 'A verification timeout never submits another deletion'

Reset-Workflow
$script:TimeoutSeconds = 10
$script:workflow.ForceRealDelay = $true
$script:workflow.DialogSteps = @(New-DialogStep @($dialog))
Assert-Throws { Wait-DeletionRemoval $plan } 'A modal left open after submission is cancelled before stopping' '已提交删除，但未核验移除'
Assert-True (@($script:workflow.Events | Where-Object { $_.Status -ceq 'VerificationTimedOut' }).Count -eq 1) 'Stalled modal is recorded as a timeout'
Assert-True (@($script:workflow.Events | Where-Object { $_.Status -ceq 'PendingDialogCancelled' }).Count -eq 1 -and $script:workflow.InvokeCount -eq 1) 'Only Cancel is invoked for the stalled modal'
Assert-True ($script:workflow.ForbiddenBackgroundReads -eq 0) 'Stalled modal is cleared before any sidebar read'

Reset-Workflow
$script:workflow.DialogSteps = @(New-DialogStep)
$script:workflow.SidebarSteps = @(New-SidebarStep @())
$script:workflow.AbortPageAfter = 5
Assert-Throws { Wait-DeletionRemoval $plan } 'Missing retained row prevents false deletion success' 'TEST_STOP_POLL'
Assert-True (@($script:workflow.Events | Where-Object { $_.Status -ceq 'DeletedAndVerified' }).Count -eq 0) 'Incomplete sidebar is never reported as verified'

foreach ($case in @('TargetTitle', 'TargetIdentity', 'Loading')) {
    Reset-Workflow
    $script:workflow.DialogSteps = @(New-DialogStep)
    $inventory = @($anchors)
    $loading = $false
    if ($case -ceq 'TargetTitle') {
        $inventory += [pscustomobject]@{Title=$plan.Title; RuntimeId='replacement.1'}
    } elseif ($case -ceq 'TargetIdentity') {
        $inventory += [pscustomobject]@{Title='改名目标'; RuntimeId=$plan.RuntimeId}
    } else { $loading=$true }
    $script:workflow.SidebarSteps = @(New-SidebarStep $inventory $loading)
    $script:workflow.AbortPageAfter = 4
    Assert-Throws { Wait-DeletionRemoval $plan } "$case prevents premature success" 'TEST_STOP_POLL'
    Assert-True (@($script:workflow.Events | Where-Object { $_.Status -ceq 'DeletedAndVerified' }).Count -eq 0) "$case is never reported as removed"
}

Reset-Workflow
$script:workflow.DialogSteps = @(New-DialogStep)
$script:workflow.SidebarSteps = @(
    (New-SidebarStep $anchors), (New-SidebarStep $anchors),
    (New-SidebarStep $anchors $true),
    (New-SidebarStep $anchors), (New-SidebarStep $anchors), (New-SidebarStep $anchors)
)
Wait-DeletionRemoval $plan
$verified = @($script:workflow.Events | Where-Object { $_.Status -ceq 'DeletedAndVerified' })
Assert-True ($verified.Count -eq 1 -and $verified[0].SidebarReads -eq 6) 'Unstable sidebar resets the three consecutive verification rounds'

Write-Host "All $script:passed workflow regression tests passed. No browser was operated."
