# Execute only the task-registration block against in-memory Task Scheduler
# doubles. This verifies action/account/bounds and foreign-task preservation
# without registering anything on the developer's machine.
$ErrorActionPreference = "Stop"
$RepoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot "../../.."))
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot "install/install.ps1"), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
$block = $ast.Find({ param($node)
    $node -is [Management.Automation.Language.IfStatementAst] -and
    $node.Extent.Text.StartsWith('if ($ManageServices)') -and
    $node.Extent.Text.Contains('New-ScheduledTaskAction')
}, $true)
if (-not $block) { throw "Missing maintenance registration" }
$register = [scriptblock]::Create($block.Extent.Text)
$script:Seen = $null
$script:Existing = $null
function Get-ScheduledTask { param($TaskName, $ErrorAction) return $script:Existing }
function New-ScheduledTaskAction { param($Execute, $Argument) return @{Execute=$Execute; Arguments=$Argument} }
function New-ScheduledTaskTrigger { param([switch]$Once, $At, $RepetitionInterval) return @{Interval=$RepetitionInterval} }
function New-ScheduledTaskPrincipal { param($UserId, $LogonType, $RunLevel) return @{UserId=$UserId; LogonType=$LogonType; RunLevel=$RunLevel} }
function New-ScheduledTaskSettingsSet {
    param($MultipleInstances, $ExecutionTimeLimit, [switch]$AllowStartIfOnBatteries, [switch]$DontStopIfGoingOnBatteries)
    return @{MultipleInstances=$MultipleInstances; ExecutionTimeLimit=$ExecutionTimeLimit}
}
function Register-ScheduledTask {
    param($TaskName, $Description, $Action, $Trigger, $Principal, $Settings, [switch]$Force)
    $script:Seen = @{Name=$TaskName; Description=$Description; Action=$Action; Trigger=$Trigger; Principal=$Principal; Settings=$Settings}
}
$InstalledExe = 'C:\ProgramData\hikari\versions\current\hikari.exe'
$ConfigPath = 'C:\ProgramData\hikari\config\config.json'
$AgentAccount = 'LocalSystem'
$ManageServices = $false
& $register
if ($script:Seen) { throw 'ServiceMode skip registered a task' }
$ManageServices = $true
& $register
$job = $script:Seen
if ($job.Name -ne 'hikari-maintenance' -or $job.Action.Execute -ne $InstalledExe -or
    $job.Action.Arguments -ne "update maintain --config `"$ConfigPath`"") { throw 'Unexpected privileged action' }
if ($job.Principal.UserId -ne 'SYSTEM' -or $job.Principal.LogonType -ne 'ServiceAccount') { throw 'Wrong job account' }
if ($job.Trigger.Interval.TotalMinutes -ne 5 -or $job.Settings.ExecutionTimeLimit.TotalMinutes -ne 15 -or
    $job.Settings.MultipleInstances -ne 'IgnoreNew') { throw 'Unbounded maintenance job' }
$script:Existing = [pscustomobject]@{Description='hikari-owned maintenance'; Actions=@([pscustomobject]$job.Action)}
& $register # Owned task repair is idempotent.
$script:Existing.Actions[0].Arguments = 'something operator-owned'
$script:Seen = $null
$rejected = $false
try { & $register } catch { $rejected = $true }
if (-not $rejected -or $script:Seen) { throw 'Foreign task was overwritten' }
Write-Output 'Windows maintenance task registration contract passed (no real task created).'
