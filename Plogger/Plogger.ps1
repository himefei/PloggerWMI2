###################################################################################
# Plogger - A PowerShell script for logging system performance metrics and exporting them to CSV files.
# Copyright (c) 2025 Lifei Yu
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.
###################################################################################
# IMPORTANT: This script requires administrator privileges to function correctly due to its use of WMI/CIM.
# Please run this script in Powershell with Administrator (e.g., Right-click -> Run as Administrator).
# Then run the script using the command: "& "C:\Users\username\Plogger.ps1""
# If the script is blocked by security policies, please run the command in PowerShell ISE with Administrator privileges.
###################################################################################
# IMPORTATNT: If you encountered issue with execution policy, please run the command: "set-executionpolicy unrestricted" in PowerShell with Administrator privileges.
###################################################################################

# --- Robust script/exe directory resolution for both .ps1 and .exe ---
$Global:ResolvedScriptRoot = $null
Write-Verbose "Attempting to determine Plogger base directory..."

if ($PSScriptRoot) {
    $Global:ResolvedScriptRoot = $PSScriptRoot
    Write-Verbose "Using PSScriptRoot: $Global:ResolvedScriptRoot"
} elseif ($MyInvocation.MyCommand.Path -and ($MyInvocation.MyCommand.Path -like '*.exe')) {
    $Global:ResolvedScriptRoot = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
    Write-Verbose "Using MyInvocation.MyCommand.Path (EXE): $Global:ResolvedScriptRoot"
} else {
    try {
        $processPath = (Get-Process -Id $PID).Path
        if ($processPath) {
            $Global:ResolvedScriptRoot = Split-Path -Path $processPath -Parent
            Write-Verbose "Using Get-Process Path: $Global:ResolvedScriptRoot"
        } else {
            Write-Warning "Get-Process -Id $PID did not return a path."
        }
    } catch {
        Write-Warning "Failed to get path from Get-Process: $($_.Exception.Message)"
    }

    if (-not $Global:ResolvedScriptRoot) {
        if ($MyInvocation.MyCommand.Path) {
            $Global:ResolvedScriptRoot = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
            Write-Warning "Fallback to MyInvocation.MyCommand.Path (non-EXE or other context): $Global:ResolvedScriptRoot"
        } else {
            Write-Error "FATAL: Unable to determine Plogger base directory using PSScriptRoot, MyInvocation.MyCommand.Path, or Get-Process."
            Write-Warning "As a final attempt, using current working directory: $(Get-Location). This may be unreliable for locating dependencies."
            $Global:ResolvedScriptRoot = $PWD.Path # Current working directory
        }
    }
}

if (-not $Global:ResolvedScriptRoot -or -not (Test-Path $Global:ResolvedScriptRoot -PathType Container)) {
    Write-Error "FATAL: Plogger base directory could not be reliably determined or is invalid: '$Global:ResolvedScriptRoot'."
    exit 1
}

Write-Host "Plogger base directory determined as: $Global:ResolvedScriptRoot"

# Display disclaimer
Write-Host "DISCLAIMER

Using native Windows functionality, this script collects system resource usage data (CPU, RAM, running processes, and resource consumption metrics)
from your computer for diagnostic purposes only. By running this script, you acknowledge and agree that:

1. The data collected will be used solely to analyze performance issues on your system.
2. The script generates a CSV file containing system resource usage information only.
3. No personal files, documents, browsing history, or personally identifiable information will be collected.
4. You are voluntarily providing this information to Lenovo for troubleshooting purposes.
5. Lenovo will handle all collected information according to its Privacy Policy (available at www.lenovo.com/privacy).
6. Lenovo is not responsible for any system changes or issues that may arise from running this script.
7. You must review the generated CSV file and its contents before sending it to Lenovo."
$confirmation = Read-Host "Do you want to proceed? (Y/N)"
if ($confirmation -ne 'Y' -and $confirmation -ne 'y') {
    Write-Host "Exiting script."
    exit
}

# Function to get current power status and overlay metrics
function Get-PowerStatusMetrics {
   # Mapping of known Power Mode Overlay GUIDs to friendly names
   $powerModeOverlayGuids = @{
       "ded574b5-45a0-4f42-8737-46345c09c238" = "Best Performance"
       "31fccf00-1979-49fb-97ca-292516017500" = "Better Performance" # Often an intermediate step
       "961cc777-2547-4f9d-8174-7d86181b8a7a" = "Balanced (Recommended / Better Battery)" # Can vary based on slider position
       "12957487-2663-4308-8a36-80225202370b" = "Battery Saver / Best Power Efficiency"
       "00000000-0000-0000-0000-000000000000" = "System Default / Varies (Often aligns with base plan or 'Balanced' overlay)"
       # Add other OEM-specific overlay GUIDs here if discovered
   }

   $basePlanName = "Error"
   $basePlanGUID = "Error"
   $powerStatusString = "Error"
   $overlayFriendlyName = "Error"
   $activeOverlayGuid = "Error"

   # 1. Get the base Windows Power Plan
   try {
       $activeBasePlan = Get-CimInstance -Namespace root\cimv2\power -ClassName Win32_PowerPlan -Filter "IsActive = 'True'" -ErrorAction Stop
       if ($activeBasePlan) {
           $basePlanName = $activeBasePlan.ElementName
           $basePlanGUID = $activeBasePlan.InstanceID -replace "Microsoft:PowerPlan\{(.+)\}", '$1'
       } else {
           Write-Warning "Could not determine the active base Windows Power Plan."
       }
   }
   catch {
       Write-Warning "Error getting base Windows Power Plan: $($_.Exception.Message)"
   }

   # 2. Determine AC/DC Power Status
   $onACPower = $true # Assume AC if no battery or battery status indicates AC
   try {
       $powerSource = Get-CimInstance -ClassName Win32_Battery -ErrorAction SilentlyContinue # SilentlyContinue as desktops won't have it
       if ($powerSource) {
           # BatteryStatus: 1 = Discharging (DC), 2 = On AC, other values exist
           if ($powerSource.BatteryStatus -eq 1) {
               $onACPower = $false
           }
       }
       $powerStatusString = if ($onACPower) { "AC Power" } else { "DC (Battery) Power" }
   } catch {
       Write-Warning "Error determining AC/DC Power Status: $($_.Exception.Message). Assuming AC Power."
       $powerStatusString = "AC Power (Assumed due to error)"
   }


   # 3. Read the Active Power Mode Overlay from Registry
   $registryPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes"
   $overlayValueName = if ($onACPower) { "ActiveOverlayAcPowerScheme" } else { "ActiveOverlayDcPowerScheme" }

   try {
       $retrievedOverlayGuid = (Get-ItemProperty -Path $registryPath -Name $overlayValueName -ErrorAction Stop).$overlayValueName
       if ($retrievedOverlayGuid) {
           $activeOverlayGuid = $retrievedOverlayGuid # Store the raw GUID
           $overlayFriendlyName = $powerModeOverlayGuids[$retrievedOverlayGuid.ToLower()]
           if (!$overlayFriendlyName) {
               if ($retrievedOverlayGuid -eq "00000000-0000-0000-0000-000000000000") {
                   if ($basePlanName -eq "Balanced") {
                        $overlayFriendlyName = "Balanced (Overlay matches base plan or system default)"
                   } else {
                        $overlayFriendlyName = "System Default / No Specific Overlay (using base plan settings)"
                   }
               }
               else {
                    $overlayFriendlyName = "Unknown Overlay GUID"
               }
           }
       } else {
           Write-Warning "Could not determine the active Power Mode Overlay (GUID not found or empty)."
           # $activeOverlayGuid and $overlayFriendlyName remain "Error"
       }
   }
   catch {
       if ($_.CategoryInfo.Reason -eq 'PropertyNotFoundException') {
           Write-Warning "The Power Mode Overlay property ('$overlayValueName') was not found in the registry path '$registryPath'. This can happen on some systems and is not critical. Plogger will continue, using default 'Error' values for this specific information."
       } else {
           # Log the full error for unexpected issues
           Write-Warning "An unexpected error occurred while trying to read Power Mode Overlay from registry (Path: '$registryPath', Property: '$overlayValueName'): $($_.Exception.ToString()). Plogger will continue, using default 'Error' values for this information."
       }
       # $activeOverlayGuid and $overlayFriendlyName were initialized to "Error"
       # and are not changed here, effectively using them as the fallback.
   }

   return [PSCustomObject]@{
       ActivePowerPlanName = $basePlanName
       ActivePowerPlanGUID = $basePlanGUID
       SystemPowerStatus   = $powerStatusString
       ActiveOverlayName   = $overlayFriendlyName
       ActiveOverlayGUID   = $activeOverlayGuid
   }
}

# Function to capture hardware resource usage
function Capture-ResourceUsage {
    param (
        [int]$Duration # Duration in minutes. 0 means indefinite.
    )

    # --- Get PC Serial Number and Total RAM ---
    $pcSerialNumber = "UnknownSerial"
    $totalRamMB = $null
    try {
        $biosInfo = Get-CimInstance -ClassName Win32_BIOS -ErrorAction Stop | Select-Object -First 1
        if ($biosInfo.SerialNumber) {
            $pcSerialNumber = $biosInfo.SerialNumber -replace '[^a-zA-Z0-9]', '' # Remove non-alphanumeric chars
        }
    } catch {
        Write-Warning "Failed to get PC Serial Number: $($_.Exception.Message)"
    }
    try {
        # Get total physical memory in bytes and convert to MB
        $computerSystem = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        $totalRamMB = [math]::Round($computerSystem.TotalPhysicalMemory / 1MB)
    } catch {
        Write-Warning "Failed to get Total Physical Memory: $($_.Exception.Message)"
    }

    # Get CPU Max Clock Speed
    $cpuMaxClockSpeedMHz = $null
    try {
        $cpuInfo = Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop | Select-Object -First 1
        $cpuMaxClockSpeedMHz = $cpuInfo.MaxClockSpeed
        Write-Verbose "CPU Max Clock Speed: $cpuMaxClockSpeedMHz MHz"
    } catch {
        Write-Warning "Failed to get CPU Max Clock Speed: $($_.Exception.Message)"
    }

    $startTime = Get-Date
    # If Duration is 0, loop indefinitely, otherwise calculate endTime
    $endTime = if ($Duration -gt 0) { $startTime.AddMinutes($Duration) } else { $null }
    $data = @()
    # --- CHANGE: Use $Global:ResolvedScriptRoot and new filename format ---
    $scriptDirectory = $Global:ResolvedScriptRoot # More reliable way to get script's directory
    $logFileName = "$($pcSerialNumber)_$(Get-Date -Format 'HHmmss_ddMMyyyy').csv"
    $logFilePath = Join-Path $scriptDirectory $logFileName
    # --- ADDED: Prepare per-process log file path ---
    $processLogFileName = "${pcSerialNumber}_$(Get-Date -Format 'HHmmss_ddMMyyyy')_process.csv"
    $processLogFilePath = Join-Path $scriptDirectory $processLogFileName
    Write-Host "Per-process log file will be saved to: $processLogFilePath"
    # --- END CHANGE ---
    
    # --- NEW: Initialize write timers and process data buffer for 15-second write intervals ---
    $lastHardwareWriteTime = $startTime
    $lastProcessWriteTime = $startTime
    $processDataBuffer = @()
    $writeIntervalSeconds = 15 # Write interval in seconds
    Write-Host "Data will be written to log files every $writeIntervalSeconds seconds."
    # --- END NEW ---

    Write-Host "Starting data logging..."
    if ($Duration -eq 0) {
        Write-Host "Logging indefinitely. Press Ctrl+C to stop and save."
    } else {
        Write-Host "Logging for $Duration minute(s)."
    }
    Write-Host "Log file will be saved to: $logFilePath" # Inform user

    # Register action on Ctrl+C
    $action = {
        Write-Host "`nStopping logging and saving data..." -ForegroundColor Yellow
        
        # --- MODIFIED: Save both hardware and process data on Ctrl+C ---
        # Save hardware data
        if ($script:data.Count -gt 0) {
            # Check if the file exists and is empty, if so, write the header
            if (-not (Test-Path $script:logFilePath -PathType Leaf) -or $null -eq (Get-Content $script:logFilePath -ErrorAction SilentlyContinue | Select-Object -First 1)) {
                # File doesn't exist or is empty, write header + data
                $script:data | Export-Csv -Path $script:logFilePath -NoTypeInformation
            } else {
                # File exists and has content, append data
                $script:data | Export-Csv -Path $script:logFilePath -NoTypeInformation -Append
            }
            Write-Host "Hardware data saved to $script:logFilePath"
        } else {
            Write-Host "No new hardware data to save."
        }
        
        # Save process data
        if ($script:processDataBuffer.Count -gt 0) {
            # Check if the file exists and is empty, if so, write the header
            if (-not (Test-Path $script:processLogFilePath -PathType Leaf) -or $null -eq (Get-Content $script:processLogFilePath -ErrorAction SilentlyContinue | Select-Object -First 1)) {
                # File doesn't exist or is empty, write header + data
                $script:processDataBuffer | Export-Csv -Path $script:processLogFilePath -NoTypeInformation
            } else {
                # File exists and has content, append data
                $script:processDataBuffer | Export-Csv -Path $script:processLogFilePath -NoTypeInformation -Append
            }
            Write-Host "Process data saved to $script:processLogFilePath"
        } else {
            Write-Host "No new process data to save."
        }
        # --- END MODIFIED ---
        
        exit # Exit the script
    }
    # Make variables accessible in the action scope
    $ExecutionContext.SessionState.PSVariable.Set('script:data', $data)
    $ExecutionContext.SessionState.PSVariable.Set('script:logFilePath', $logFilePath) # Already passing the absolute path
    $ExecutionContext.SessionState.PSVariable.Set('script:processDataBuffer', $processDataBuffer)
    $ExecutionContext.SessionState.PSVariable.Set('script:processLogFilePath', $processLogFilePath)
    # Unregister previous event handler if it exists, before registering new one
    Get-EventSubscriber -SourceIdentifier PowerShell.ProcessArchitecture -ErrorAction SilentlyContinue | Unregister-Event
    Register-EngineEvent -SourceIdentifier PowerShell.ProcessArchitecture -Action $action -SupportEvent

    # --- CHANGE: Add flags for one-time warnings ---
    $script:diskIOWarningLogged = $false   # Add flag for Disk IO warning
    $script:batteryWarningLogged = $false  # Add flag for battery warnings
    $script:cpuTempWarningLogged = $false  # Add flag for CPU temperature warnings
    # --- END CHANGE ---

    try {
        # Loop until duration is met or stopped manually
        while ($true) {
            # Check if the logging duration has been reached
            if ($null -ne $endTime -and (Get-Date) -ge $endTime) {
                Write-Host "Logging duration reached. Stopping..."
                break
            }
            
            # Show progress bar if a fixed duration is set
            if ($null -ne $endTime) {
                $elapsedTime = (Get-Date) - $startTime
                $percentComplete = [math]::Min(100, [math]::Round(($elapsedTime.TotalMinutes / $Duration) * 100))
                Write-Progress -Activity "Logging Resource Usage" -Status "$percentComplete% Complete" -PercentComplete $percentComplete
            }

            # Initialize variables for metrics
            # $cpuTimeVal = $null # REMOVED: Using % Processor Time
            $cpuUtilityVal = $null # Using % Processor Utility
            $ramAvailableMBVal = $null
            $ramUsedMBVal = $null
            $diskIOVal = $null
            $networkIOVal = $null
            $batteryVal = $null
            $batteryFullChargedCapacity_mWh = $null
            $batteryRemainingCapacity_mWh = $null
            $batteryDesignCapacity_mWh = $null
           $brightnessVal = $null
           $cpuTempVal = $null
           
           # --- Get Power Status Metrics ---
           $powerMetrics = Get-PowerStatusMetrics
           # --- END Power Status Metrics ---

           # --- REMOVED: Get CPU Usage using % Processor Time ---
            # try {
            #     # Keep the original counter
            #     $cpuTimeVal = (Get-Counter '\Processor(_Total)\% Processor Time' -ErrorAction Stop).CounterSamples.CookedValue
            #     Write-Verbose "CPU Usage (% Processor Time): $cpuTimeVal %"
            # } catch {
            #     Write-Warning "Failed to get CPU Usage (% Processor Time): $($_.Exception.Message). Check permissions or run 'lodctr /R' as Admin."
            #     $cpuTimeVal = $null # Ensure it's null if counter fails
            # }

            # --- Get CPU Usage using % Processor Utility ---
            try {
                # Add the new counter
                $cpuUtilityVal = (Get-Counter '\Processor Information(_Total)\% Processor Utility' -ErrorAction Stop).CounterSamples.CookedValue
                Write-Verbose "CPU Usage (% Processor Utility): $cpuUtilityVal %"
            } catch {
                # Add specific warning for this counter, maybe it doesn't exist on all systems
                Write-Warning "Failed to get CPU Usage (% Processor Utility): $($_.Exception.Message). This counter might not be available on all systems. Check permissions or run 'lodctr /R' as Admin."
                $cpuUtilityVal = $null # Ensure it's null if counter fails
            }
            # --- END NEW ---

            try {
                $ramAvailableMBVal = (Get-Counter '\Memory\Available MBytes' -ErrorAction Stop).CounterSamples.CookedValue
                if ($null -ne $totalRamMB -and $null -ne $ramAvailableMBVal) {
                    $ramUsedMBVal = $totalRamMB - $ramAvailableMBVal
                }
            } catch { Write-Warning "Failed to get Available RAM: $($_.Exception.Message). Check permissions or run 'lodctr /R' as Admin." } # Added hint
            
            # --- CHANGE: Add single warning flag for Disk IO --- 
            try { 
                $diskIOVal = (Get-Counter '\PhysicalDisk(_Total)\Disk Transfers/sec' -ErrorAction Stop).CounterSamples.CookedValue 
            } catch { 
                $diskIOVal = $null # Ensure value is null on failure
                if (-not $script:diskIOWarningLogged) { 
                    Write-Warning "Failed to get Disk IO: $($_.Exception.Message). Check permissions or run 'lodctr /R' as Admin. Further Disk IO warnings will be suppressed."
                    $script:diskIOWarningLogged = $true 
                } 
            } 
            # --- END CHANGE ---
            
            # --- Network IO monitoring using WMI/CIM ---
            try {
                # Get network interface statistics using CIM
                $networkAdapters = Get-CimInstance -ClassName Win32_PerfFormattedData_Tcpip_NetworkInterface -ErrorAction Stop
                
                # Filter out virtual and inactive adapters, sum bytes in and out across all physical adapters
                $physicalAdapters = $networkAdapters | Where-Object {
                    $_.Name -notmatch 'isatap|Loopback|Teredo|Tunnel|Virtual' -and
                    ($_.BytesTotalPersec -gt 0 -or $_.CurrentBandwidth -gt 0)
                }
                
                if ($physicalAdapters) {
                    # Sum the total bytes per second across all adapters
                    $networkIOVal = ($physicalAdapters | Measure-Object -Property BytesTotalPersec -Sum).Sum
                } else {
                    # If we have adapters but none are active, use 0
                    $networkIOVal = 0
                }
            } catch {
                # Handle the case where the WMI class isn't available or other errors
                Write-Warning "Failed to get Network IO via Win32_PerfFormattedData_Tcpip_NetworkInterface: $($_.Exception.Message)"
                $networkIOVal = $null
                
                # Attempt fallback to direct WMI query
                try {
                    $netAdapters = Get-CimInstance -ClassName Win32_NetworkAdapter -ErrorAction Stop | 
                                   Where-Object { $_.NetConnectionStatus -eq 2 } # Only connected adapters
                    
                    if ($netAdapters) {
                        $networkIOVal = 0 # Default to 0 when adapters exist but we can't get throughput
                    }
                } catch {
                    Write-Warning "Fallback network detection also failed: $($_.Exception.Message)"
                }
            }
            # --- END Network IO ---
            
            # --- Battery monitoring with multiple methods and WMI classes ---
            try {
                # PRIMARY METHOD: Get battery data from ROOT\cimv2 namespace
                $batteryVal = $null
                $batteries = Get-CimInstance -Namespace "ROOT\cimv2" -ClassName Win32_Battery -ErrorAction SilentlyContinue
                
                # Check if any batteries were found
                if ($batteries -and $batteries.Count -gt 0) {
                    # Get charge remaining from the first battery
                    $batteryVal = $batteries[0].EstimatedChargeRemaining

                    # Try to get DesignCapacity from Win32_Battery
                    try {
                        $batteryDesignCapacity_mWh = $batteries[0].DesignCapacity
                        if ($null -ne $batteryDesignCapacity_mWh) {
                            Write-Verbose "DesignCapacity from Win32_Battery: $batteryDesignCapacity_mWh mWh"
                        }
                    } catch {
                        Write-Verbose "Could not get DesignCapacity from Win32_Battery: $($_.Exception.Message)"
                    }
                    
                    # Also capture battery status info for more detailed reporting
                    $batteryStatus = $batteries[0].BatteryStatus
                    $batteryStatusText = switch ($batteryStatus) {
                        1 {"Discharging"}
                        2 {"AC Power"}
                        3 {"Fully Charged"}
                        4 {"Low"}
                        5 {"Critical"}
                        6 {"Charging"}
                        7 {"Charging and High"}
                        8 {"Charging and Low"}
                        9 {"Charging and Critical"}
                        10 {"Undefined"}
                        11 {"Partially Charged"}
                        default {"Unknown"}
                    }
                    
                    # Log battery status only once on startup
                    if (-not $script:batteryWarningLogged) {
                        Write-Host "Battery detected: $batteryVal% ($batteryStatusText)"
                    }
                }
                
                # FALLBACK METHOD: If no battery data from primary method, or to get mWh values, try ROOT\WMI namespace classes
                $wmiNamespace = "ROOT\WMI"
                try {
                    # Get FullChargedCapacity
                    $fccInstance = Get-CimInstance -Namespace $wmiNamespace -ClassName "BatteryFullChargedCapacity" -ErrorAction SilentlyContinue
                    if ($fccInstance) {
                        $batteryFullChargedCapacity_mWh = $fccInstance.FullChargedCapacity
                        Write-Verbose "FullChargedCapacity from ROOT\WMI: $batteryFullChargedCapacity_mWh mWh"
                    }

                    # Get RemainingCapacity
                    $bsInstance = Get-CimInstance -Namespace $wmiNamespace -ClassName "BatteryStatus" -ErrorAction SilentlyContinue
                    if ($bsInstance) {
                        $batteryRemainingCapacity_mWh = $bsInstance.RemainingCapacity
                        Write-Verbose "RemainingCapacity from ROOT\WMI: $batteryRemainingCapacity_mWh mWh"
                    }
                    
                    # Attempt to get DesignCapacity from BatteryStaticData (prioritized for ROOT\WMI)
                    $bsdInstance = Get-CimInstance -Namespace $wmiNamespace -ClassName "BatteryStaticData" -ErrorAction SilentlyContinue
                    if ($bsdInstance -and $bsdInstance.DesignedCapacity) {
                        $batteryDesignCapacity_mWh_static = $bsdInstance.DesignedCapacity
                        Write-Verbose "DesignCapacity from ROOT\WMI\BatteryStaticData: $batteryDesignCapacity_mWh_static mWh"
                        # Always prefer ROOT\WMI\BatteryStaticData if available and valid
                        if ($batteryDesignCapacity_mWh_static -ne $null -and $batteryDesignCapacity_mWh_static -gt 0) {
                            $batteryDesignCapacity_mWh = $batteryDesignCapacity_mWh_static
                        }
                    }

                    # Calculate percentage if both mWh values are valid from ROOT\WMI
                    if ($null -ne $batteryFullChargedCapacity_mWh -and $batteryFullChargedCapacity_mWh -gt 0 -and $null -ne $batteryRemainingCapacity_mWh) {
                        $batteryVal = [Math]::Round(($batteryRemainingCapacity_mWh / $batteryFullChargedCapacity_mWh) * 100)
                        # Log that we're using the fallback method for percentage calculation
                        if (-not $script:batteryWarningLogged) {
                            Write-Host "Battery percentage ($batteryVal%) calculated using ROOT\WMI mWh values."
                        }
                    }
                } catch {
                    Write-Verbose "Fallback battery mWh detection (ROOT\WMI) failed: $($_.Exception.Message)"
                }
                
                # If still no battery data, mark as N/A (desktop PC)
                if ($null -eq $batteryVal) {
                    if (-not $script:batteryWarningLogged) {
                        Write-Verbose "No battery detected - this appears to be a desktop PC or VM"
                    }
                    $batteryVal = "N/A" # Use N/A to indicate desktop PC
                }
                if ($null -eq $batteryFullChargedCapacity_mWh) { $batteryFullChargedCapacity_mWh = "N/A" }
                if ($null -eq $batteryRemainingCapacity_mWh) { $batteryRemainingCapacity_mWh = "N/A" }
                if ($null -eq $batteryDesignCapacity_mWh) { $batteryDesignCapacity_mWh = "N/A" }
                
                $script:batteryWarningLogged = $true
                
            } catch {
                if (-not $script:batteryWarningLogged) {
                    Write-Warning "Failed to get Battery Status: $($_.Exception.Message)"
                    $script:batteryWarningLogged = $true
                }
                $batteryVal = "Error"  # Indicate an error occurred
                if ($null -eq $batteryFullChargedCapacity_mWh) { $batteryFullChargedCapacity_mWh = "Error" }
                if ($null -eq $batteryRemainingCapacity_mWh) { $batteryRemainingCapacity_mWh = "Error" }
                if ($null -eq $batteryDesignCapacity_mWh) { $batteryDesignCapacity_mWh = "Error" }
            }
            # --- END Battery monitoring ---
            
            try { 
                $brightnessVal = (Get-CimInstance -Namespace root/wmi -ClassName WmiMonitorBrightness -ErrorAction Stop).CurrentBrightness 
            } catch { 
                Write-Warning "Failed to get Brightness: $($_.Exception.Message)" 
            }

            # --- NEW: Capture raw CPU Temperature data without conversion ---
            try {
                $cpuTempVal = $null
                
                # Try MSAcpi_ThermalZoneTemperature from root/wmi namespace - capture raw value
                try {
                    $thermalZone = Get-CimInstance -Namespace "root/wmi" -ClassName "MSAcpi_ThermalZoneTemperature" -ErrorAction Stop
                    if ($thermalZone -and $thermalZone.CurrentTemperature) {
                        # Store raw value (tenths of Kelvin) for processing in Reporter
                        $cpuTempVal = $thermalZone.CurrentTemperature
                        Write-Verbose "Raw CPU Temperature from MSAcpi_ThermalZoneTemperature: $cpuTempVal (tenths of Kelvin)"
                    }
                } catch {
                    Write-Verbose "Failed to get CPU Temperature via MSAcpi_ThermalZoneTemperature: $($_.Exception.Message)"
                }
                
                # If first method failed, try Win32_PerfFormattedData_Counters_ThermalZoneInformation
                if ($null -eq $cpuTempVal) {
                    try {
                        $thermalInfo = Get-CimInstance -Namespace "root/cimv2" -ClassName "Win32_PerfFormattedData_Counters_ThermalZoneInformation" -ErrorAction Stop
                        if ($thermalInfo -and $thermalInfo.Temperature) {
                            # This counter provides temperature in Celsius, prefix with marker for Reporter processing
                            $cpuTempVal = "CELSIUS:$($thermalInfo.Temperature)"
                            Write-Verbose "CPU Temperature from Win32_PerfFormattedData_Counters_ThermalZoneInformation: $($thermalInfo.Temperature) °C"
                        }
                    } catch {
                        Write-Verbose "Failed to get CPU Temperature via Win32_PerfFormattedData_Counters_ThermalZoneInformation: $($_.Exception.Message)"
                    }
                }
                
                # If still no temperature data, log a warning once
                if ($null -eq $cpuTempVal -and -not $script:cpuTempWarningLogged) {
                    Write-Warning "Could not retrieve CPU temperature via WMI. This data may not be available on your system."
                    $script:cpuTempWarningLogged = $true
                }
            } catch {
                if (-not $script:cpuTempWarningLogged) {
                    Write-Warning "Failed to get CPU Temperature: $($_.Exception.Message)"
                    $script:cpuTempWarningLogged = $true
                }
                $cpuTempVal = $null
            }
            # --- END NEW Raw CPU Temperature Capture ---

            # --- NEW: Get GPU Engine Utilization using Performance Counters ---
            $gpuEngineUsage = @{} # Hashtable to store results
            try {
                $engineCounters = Get-Counter '\GPU Engine(*)\Utilization Percentage' -ErrorAction SilentlyContinue
                if ($null -ne $engineCounters) {
                    $engineDataRaw = $engineCounters.CounterSamples | ForEach-Object {
                        # Extract Engine Name and LUID
                        $engineName = "Unknown"
                        if ($_.InstanceName -match 'engtype_([a-zA-Z0-9]+)') { 
                            $engineName = $matches[1] 
                        }
                        elseif ($_.InstanceName -match 'luid_\w+_phys_\d+_eng_\d+_type_([a-zA-Z0-9]+)') { 
                            $engineName = $matches[1] 
                        }
                        elseif ($_.InstanceName -match 'eng_(\d+)') { 
                            $engineName = "Engine_$($matches[1])" 
                        }

                        $luid = "N/A"
                        if ($_.InstanceName -match 'luid_([^_]+)') { 
                            $luid = $matches[1] 
                        }

                        [PSCustomObject]@{ 
                            GPU_LUID = $luid
                            Engine = $engineName
                            UsagePercent = $_.CookedValue 
                        }
                    }
                    
                    # Group by Engine Type, Sum Percentages
                    $engineDataGrouped = $engineDataRaw | Group-Object Engine | ForEach-Object {
                        $key = "GPUEngine_$($_.Name)_Percent"
                        $value = [math]::Round(($_.Group.UsagePercent | Measure-Object -Sum).Sum, 2)
                        $gpuEngineUsage[$key] = $value
                    }
                    
                    Write-Verbose "GPU Engine Usage: $($gpuEngineUsage | Out-String)"
                } else { 
                    Write-Verbose "No '\GPU Engine(*)\Utilization Percentage' counters found." 
                }
            } catch { 
                Write-Warning "Failed to get GPU Engine Utilization: $($_.Exception.Message)" 
            }
            # --- END NEW GPU Engine Utilization ---

            # Create the base data object with metrics
            $currentData = [PSCustomObject]@{
                Timestamp                     = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
                # CPUUsagePercentTime         = $cpuTimeVal # REMOVED
                CPUUsagePercent               = $cpuUtilityVal # RENAMED from CPUUsagePercentUtility
                CPUMaxClockSpeedMHz           = $cpuMaxClockSpeedMHz
                RAMUsedMB                     = $ramUsedMBVal
                RAMAvailableMB                = $ramAvailableMBVal
                DiskIOTransferSec             = $diskIOVal
                NetworkIOBytesSec             = $networkIOVal
                BatteryPercentage             = $batteryVal
                BatteryFullChargedCapacity_mWh = $batteryFullChargedCapacity_mWh
                BatteryRemainingCapacity_mWh  = $batteryRemainingCapacity_mWh
                BatteryDesignCapacity_mWh     = $batteryDesignCapacity_mWh
                ScreenBrightness              = $brightnessVal
               CPUTemperatureRaw             = $cpuTempVal
               ActivePowerPlanName           = $powerMetrics.ActivePowerPlanName
               ActivePowerPlanGUID           = $powerMetrics.ActivePowerPlanGUID
               SystemPowerStatus             = $powerMetrics.SystemPowerStatus
               ActiveOverlayName             = $powerMetrics.ActiveOverlayName
               ActiveOverlayGUID             = $powerMetrics.ActiveOverlayGUID
           }
           
           # Add GPU Engine metrics from the hashtable
            foreach ($key in $gpuEngineUsage.Keys) {
                $currentData | Add-Member -MemberType NoteProperty -Name $key -Value $gpuEngineUsage[$key]
            }
            $data += $currentData

            # --- MODIFIED: Log per-process metrics including GPU memory ---
            # --- Get Logical Core Count for per-process CPU usage ---
            $logicalCoreCount = [Environment]::ProcessorCount

            try {
                # Get standard process metrics
                $procPerf = Get-CimInstance -ClassName Win32_PerfFormattedData_PerfProc_Process -ErrorAction Stop |
                    Where-Object { $_.Name -notin @('Idle','_Total') } |
                    Select-Object @{Name='Timestamp';Expression={Get-Date -Format 'yyyy-MM-dd HH:mm:ss'}},
                                  @{Name='ProcessName';Expression={$_.Name}},
                                  @{Name='ProcessId';Expression={$_.IDProcess}},
                                  @{Name='CPUPercent';Expression={ if ($logicalCoreCount -gt 0) { [math]::Round($_.PercentProcessorTime / $logicalCoreCount, 2) } else { [math]::Round($_.PercentProcessorTime, 2) } }},
                                  @{Name='RAM_MB';Expression={[math]::Round($_.WorkingSet/1MB,2)}},
                                  @{Name='IOReadBytesPerSec';Expression={$_.IOReadBytesPersec}},
                                  @{Name='IOWriteBytesPerSec';Expression={$_.IOWriteBytesPersec}}

                # Get GPU memory usage per process
                $gpuMemory = @{}
                try {
                    # Get Dedicated Usage counters
                    $dedicatedCounters = Get-Counter '\GPU Process Memory(*)\Dedicated Usage' -ErrorAction SilentlyContinue
                    if ($dedicatedCounters) {
                        foreach ($sample in $dedicatedCounters.CounterSamples) {
                            if ($sample.InstanceName -eq '_Total') { continue }
                            $parts = $sample.InstanceName -split '_'
                            if ($parts.Length -lt 2) { continue }
                            $procIdKey = $parts[1]
                            if (-not $gpuMemory.ContainsKey($procIdKey)) {
                                $gpuMemory[$procIdKey] = [PSCustomObject]@{ DedicatedMB = 0; SharedMB = 0 }
                            }
                            $gpuMemory[$procIdKey].DedicatedMB = [math]::Round($sample.CookedValue / 1MB, 2)
                        }
                    }
                    # Get Shared Usage counters
                    $sharedCounters = Get-Counter '\GPU Process Memory(*)\Shared Usage' -ErrorAction SilentlyContinue
                    if ($sharedCounters) {
                        foreach ($sample in $sharedCounters.CounterSamples) {
                            if ($sample.InstanceName -eq '_Total') { continue }
                            $parts = $sample.InstanceName -split '_'
                            if ($parts.Length -lt 2) { continue }
                            $procIdKey = $parts[1]
                            if (-not $gpuMemory.ContainsKey($procIdKey)) {
                                $gpuMemory[$procIdKey] = [PSCustomObject]@{ DedicatedMB = 0; SharedMB = 0 }
                            }
                            $gpuMemory[$procIdKey].SharedMB = [math]::Round($sample.CookedValue / 1MB, 2)
                        }
                    }
                } catch {
                    Write-Warning "Failed to get GPU Process Memory counters: $($_.Exception.Message)"
                }

                # Merge process data with GPU memory
                $procPerf = $procPerf | ForEach-Object {
                    $gpuData = $gpuMemory["$($_.ProcessId)"]
                    $dedicated = 0
                    $shared = 0
                    if ($gpuData) {
                        $dedicated = $gpuData.DedicatedMB
                        $shared = $gpuData.SharedMB
                    }
                    $_ | Add-Member -NotePropertyName 'GPUDedicatedMemoryMB' -NotePropertyValue $dedicated
                    $_ | Add-Member -NotePropertyName 'GPUSharedMemoryMB' -NotePropertyValue $shared
                    $_
                }
                
                # Add to buffer instead of writing immediately
                $processDataBuffer += $procPerf
                
                # Check if it's time to write process data (every 15 seconds)
                $currentTime = Get-Date
                if (($currentTime - $lastProcessWriteTime).TotalSeconds -ge $writeIntervalSeconds) {
                    if ($processDataBuffer.Count -gt 0) {
                        # Write buffered process data to CSV
                        if (-not (Test-Path $processLogFilePath)) {
                            $processDataBuffer | Export-Csv -Path $processLogFilePath -NoTypeInformation
                        } else {
                            $processDataBuffer | Export-Csv -Path $processLogFilePath -NoTypeInformation -Append
                        }
                        Write-Verbose "Process data written to $processLogFilePath ($(($currentTime - $lastProcessWriteTime).TotalSeconds) seconds since last write)"
                        
                        # Clear buffer and update last write time
                        $processDataBuffer = @()
                        $lastProcessWriteTime = $currentTime
                    }
                }
            } catch {
                Write-Warning "Failed to log per-process metrics: $($_.Exception.Message)"
            }
            # --- END MODIFIED ---

            # --- MODIFIED: Write hardware data every 15 seconds regardless of logging duration ---
            # Check if it's time to write hardware data
            $currentTime = Get-Date
            if (($currentTime - $lastHardwareWriteTime).TotalSeconds -ge $writeIntervalSeconds) {
                if ($data.Count -gt 0) {
                    # Ensure header is written only once if appending
                    if (-not (Test-Path $logFilePath -PathType Leaf) -or ($null -eq (Get-Content $logFilePath -ErrorAction SilentlyContinue | Select-Object -First 1))) {
                        $data | Export-Csv -Path $logFilePath -NoTypeInformation # Write header first time + data
                    } else {
                        $data | Export-Csv -Path $logFilePath -NoTypeInformation -Append -NoClobber # Append subsequent data
                    }
                    Write-Verbose "Hardware data written to $logFilePath ($(($currentTime - $lastHardwareWriteTime).TotalSeconds) seconds since last write)"
                    
                    # Clear the array after appending and update last write time
                    $data = @()
                    $lastHardwareWriteTime = $currentTime
                }
            }
            # --- END MODIFIED ---


            Start-Sleep -Seconds 1
        } # End While loop
    } # End Try block
    finally {
        # --- MODIFIED: Save both hardware and process data when finishing ---
        # Save hardware data
        if ($data.Count -gt 0) {
             if (-not (Test-Path $logFilePath -PathType Leaf) -or ($null -eq (Get-Content $logFilePath -ErrorAction SilentlyContinue | Select-Object -First 1))) {
                 $data | Export-Csv -Path $logFilePath -NoTypeInformation
             } else {
                 $data | Export-Csv -Path $logFilePath -NoTypeInformation -Append -NoClobber
             }
             Write-Host "`nLogging finished. Final hardware data saved to $logFilePath"
        } else {
             Write-Host "`nLogging finished. No final hardware data points to save."
        }
        
        # Save process data
        if ($processDataBuffer.Count -gt 0) {
             if (-not (Test-Path $processLogFilePath -PathType Leaf) -or ($null -eq (Get-Content $processLogFilePath -ErrorAction SilentlyContinue | Select-Object -First 1))) {
                 $processDataBuffer | Export-Csv -Path $processLogFilePath -NoTypeInformation
             } else {
                 $processDataBuffer | Export-Csv -Path $processLogFilePath -NoTypeInformation -Append -NoClobber
             }
             Write-Host "Final process data saved to $processLogFilePath"
        } else {
             Write-Host "No final process data points to save."
        }
        # --- END MODIFIED ---
        # Unregister the event handler
        Get-EventSubscriber -SourceIdentifier PowerShell.ProcessArchitecture -ErrorAction SilentlyContinue | Unregister-Event
    } # End Finally block
} # End Function Capture-ResourceUsage

# Prompt for logging duration
while ($true) {
    $durationOption = Read-Host "Enter logging duration (1, 10, 30 minutes, or '0' for until stopped by pressing Ctrl+C)"
    if ($durationOption -match '^(1|10|30|0)$') {
        break
    } else {
        Write-Warning "Invalid input. Please enter 1, 10, 30, or 0."
    }
}

# Convert to integer
$durationMinutes = [int]$durationOption

# Call the capture function
Capture-ResourceUsage -Duration $durationMinutes

Write-Host "Script finished."
