
param(
    [parameter(Mandatory=$false)]
    [String] $AzureCredentialName = "Use *Default Automation Credential* Asset",
    [parameter(Mandatory=$false)]
    [String] $AzureSubscriptionName = "Use *Default Azure Subscription* Variable Value",
    [parameter(Mandatory=$false)]
    [bool]$Simulate = $false
)

$VERSION = "1.0.0"

# ---------------------------------------------------------------------------
# Function: CheckScheduleEntry
# Checks whether the current UTC time falls within a given time range string.
# ---------------------------------------------------------------------------
function CheckScheduleEntry ([string]$TimeRange)
{
    # Initialize variables
    $rangeStart, $rangeEnd, $parsedDay = $null
    $currentTime = (Get-Date).ToUniversalTime()
    $midnight = $currentTime.AddDays(1).Date

    try
    {
        # Parse as time range if contains '->'
        if($TimeRange -like "*->*")
        {
            $timeRangeComponents = $TimeRange -split "->" | foreach { $_.Trim() }
            if($timeRangeComponents.Count -eq 2)
            {
                $rangeStart = Get-Date $timeRangeComponents[0]
                $rangeEnd   = Get-Date $timeRangeComponents[1]

                # Handle ranges that cross midnight
                if($rangeStart -gt $rangeEnd)
                {
                    # If current time is between start of range and midnight tonight,
                    # push rangeEnd to tomorrow
                    if($currentTime -ge $rangeStart -and $currentTime -lt $midnight)
                    {
                        $rangeEnd = $rangeEnd.AddDays(1)
                    }
                    # Otherwise, interpret start time as yesterday
                    else
                    {
                        $rangeStart = $rangeStart.AddDays(-1)
                    }
                }
            }
            else
            {
                Write-Output "`tWARNING: Invalid time range format. Expects valid .Net DateTime values separated by '->'."
            }
        }
        # Otherwise attempt to parse as a full day entry, e.g. 'Monday' or 'December 25'
        else
        {
            # If specified as day of week, check if today
            if([System.DayOfWeek].GetEnumValues() -contains $TimeRange)
            {
                if($TimeRange -eq (Get-Date).DayOfWeek)
                {
                    $parsedDay = Get-Date "00:00"
                }
                else
                {
                    # Skip — detected day of week that isn't today
                }
            }
            # Otherwise attempt to parse as a specific date, e.g. 'December 25'
            else
            {
                $parsedDay = Get-Date $TimeRange
            }
        }

        if($parsedDay -ne $null)
        {
            $rangeStart = $parsedDay
            $rangeEnd   = $parsedDay.AddHours(23).AddMinutes(59).AddSeconds(59)
        }
    }
    catch
    {
        # Record any errors and return false by default
        Write-Output "`tWARNING: Exception encountered while parsing time range. Details: $($_.Exception.Message)"
        return $false
    }

    # Check if current time falls within range
    if($currentTime -ge $rangeStart -and $currentTime -le $rangeEnd)
    {
        return $true
    }
    else
    {
        return $false
    }

} # End function CheckScheduleEntry


# ---------------------------------------------------------------------------
# Function: AssertVirtualMachinePowerState
# Routes to the correct power state handler based on VM type (ARM only here).
# ---------------------------------------------------------------------------
function AssertVirtualMachinePowerState
{
    param(
        [Object]$VirtualMachine,
        [string]$DesiredState,
        [Object[]]$ResourceManagerVMList,
        #[Object[]]$ClassicVMList,  # Classic VMs not used
        [bool]$Simulate
    )

    # Only handling ARM deployments
    if($VirtualMachine.ResourceType -eq "Microsoft.Compute/virtualMachines")
    {
        $resourceManagerVM = $ResourceManagerVMList | where Name -eq $VirtualMachine.Name
        AssertResourceManagerVirtualMachinePowerState `
            -VirtualMachine $resourceManagerVM `
            -DesiredState $DesiredState `
            -Simulate $Simulate
    }
    else
    {
        Write-Output "VM type not recognized: [$($VirtualMachine.ResourceType)]. Skipping."
    }
}


# ---------------------------------------------------------------------------
# Function: AssertResourceManagerVirtualMachinePowerState
# Gets current power state of an ARM VM and starts/stops it as needed.
# ---------------------------------------------------------------------------
function AssertResourceManagerVirtualMachinePowerState
{
    param(
        [Object]$VirtualMachine,
        [string]$DesiredState,
        [bool]$Simulate
    )

    # Get VM with current status
    $resourceManagerVM = Get-AzVM `
        -ResourceGroupName $VirtualMachine.ResourceGroupName `
        -Name $VirtualMachine.Name `
        -Status
    $currentStatus = $resourceManagerVM.Statuses | where Code -like "PowerState*"
    $currentStatus = $currentStatus.Code -replace "PowerState/", ""

    # If should be started and isn't, start VM
    if($DesiredState -eq "Started" -and $currentStatus -notmatch "running")
    {
        if($Simulate)
        {
            Write-Output "[$($VirtualMachine.Name)]: SIMULATION -- Would have started VM. (No action taken)"
        }
        else
        {
            Write-Output "[$($VirtualMachine.Name)]: Starting VM"
            $resourceManagerVM | Start-AzVM
        }
    }
    # If should be stopped and isn't, stop VM
    elseif($DesiredState -eq "StoppedDeallocated" -and $currentStatus -ne "deallocated")
    {
        if($Simulate)
        {
            Write-Output "[$($VirtualMachine.Name)]: SIMULATION -- Would have stopped VM. (No action taken)"
        }
        else
        {
            Write-Output "[$($VirtualMachine.Name)]: Stopping VM"
            $resourceManagerVM | Stop-AzVM -Force
        }
    }
    # Otherwise, current power state is already correct
    else
    {
        Write-Output "[$($VirtualMachine.Name)]: Current power state [$currentStatus] is correct."
    }
}


# ---------------------------------------------------------------------------
# MAIN RUNBOOK CONTENT
# ---------------------------------------------------------------------------
try
{
    $currentTime = (Get-Date).ToUniversalTime()
    Write-Output "Runbook started. Version: $VERSION"

    if($Simulate)
    {
        Write-Output "*** Running in SIMULATE mode. No power actions will be taken. ***"
    }

    Write-Output "Current UTC/GMT time [$($currentTime.ToString("dddd, yyyy MMM dd HH:mm:ss"))] Machine time: $((Get-Date).ToString("dddd, yyyy MMM dd HH:mm:ss"))"

    # Connect using System Managed Identity (modern approach — no stored credentials needed)
    # $AzureSubscriptionName = Get-AutomationVariable -Name 'Default Azure Subscription'
    Connect-AzAccount -Identity

    $subscriptionId = Get-AutomationVariable -Name 'Default Azure Subscription ID'
    Select-AzSubscription -Subscription $subscriptionId

    # Get a list of all virtual machines in the subscription
    $resourceManagerVMList = @(Get-AzResource | where { $_.ResourceType -like "Microsoft.*/virtualMachines" })

    # Get resource groups that are tagged for automatic shutdown
    $taggedResourceGroups = @(Get-AzResourceGroup | where { $_.Tags.Count -gt 0 -and $_.Tags.Name -contains "AutoShutdownSchedule" })
    $taggedResourceGroupNames = @($taggedResourceGroups | select -ExpandProperty ResourceGroupName)
    Write-Output "Found [$($taggedResourceGroups.Count)] schedule-tagged resource groups in subscription."

    # For each VM, determine:
    #   - Is it directly tagged for shutdown or a member of a tagged resource group?
    #   - Is the current time within the tagged schedule?
    # Then assert its correct power state based on the assigned schedule (if present).
    Write-Output "Processing [$($resourceManagerVMList.Count)] virtual machines found in subscription."

    foreach($vm in $resourceManagerVMList)
    {
        $schedule = $null

        # Check for direct tag on the VM
        if($vm.ResourceType -eq "Microsoft.Compute/virtualMachines" -and $vm.Tags -and $vm.Tags.Keys)
        {
            $arraytags = $vm.Tags
            foreach($tag in $arraytags.Keys)
            {
                if ($tag -eq "AutoShutdownSchedule")
                {
                    $schedule = $arraytags[$tag]
                }
            }
            Write-Output "[$($vm.Name)]: Found direct VM schedule tag with value: $schedule"
        }
        # Check if the VM's resource group has the tag (inherited schedule)
        elseif($taggedResourceGroupNames -contains $vm.ResourceGroupName)
        {
            # VM belongs to a tagged resource group — use the group tag
            $parentGroup = $taggedResourceGroups | where ResourceGroupName -eq $vm.ResourceGroupName
            $schedule    = ($parentGroup.Tags | where Name -eq "AutoShutdownSchedule")["Value"]
            Write-Output "[$($vm.Name)]: Found parent resource group schedule tag with value: $schedule"
        }
        else
        {
            # No direct or inherited tag — skip this VM
            Write-Output "[$($vm.Name)]: Not tagged for shutdown directly or via membership in a tagged resource group. Skipping."
            continue
        }

        # Validate that a schedule was retrieved
        if($schedule -eq $null)
        {
            Write-Output "[$($vm.Name)]: Failed to get tagged schedule for virtual machine. Skipping."
            continue
        }

        # Parse the tag value — expects comma-separated time ranges
        $timeRangeList = @($schedule -split "," | foreach { $_.Trim() })

        # Check each range against current time
        $scheduleMatched  = $false
        $matchedSchedule  = $null
        foreach($entry in $timeRangeList)
        {
            if((CheckScheduleEntry -TimeRange $entry) -eq $true)
            {
                $scheduleMatched = $true
                $matchedSchedule = $entry
                break
            }
        }

        # Enforce desired power state based on result
        if($scheduleMatched)
        {
            # Schedule matched — shut down the VM if running
            Write-Output "[$($vm.Name)]: Current time [$currentTime] falls within the scheduled shutdown window [$matchedSchedule]. Ensuring VM is stopped."
            AssertVirtualMachinePowerState `
                -VirtualMachine $vm `
                -DesiredState "StoppedDeallocated" `
                -ResourceManagerVMList $resourceManagerVMList `
                -Simulate $Simulate
        }
        else
        {
            # Schedule not matched — start VM if stopped
            Write-Output "[$($vm.Name)]: Current time falls outside of all scheduled shutdown ranges. Ensuring VM is started."
            AssertVirtualMachinePowerState `
                -VirtualMachine $vm `
                -DesiredState "Started" `
                -ResourceManagerVMList $resourceManagerVMList `
                -Simulate $Simulate
        }
    }

    Write-Output "Finished processing virtual machine schedules"
}
catch
{
    $errorMessage = $_.Exception.Message
    throw "Unexpected exception: $errorMessage"
}
finally
{
    Write-Output "Runbook finished (Duration: $(("{0:hh\:mm\:ss}" -f ((Get-Date).ToUniversalTime() - $currentTime)))"
}
