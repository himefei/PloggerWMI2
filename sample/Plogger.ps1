#####################################################################################################################################
# Plogger - A PowerShell script for logging system performance metrics and exporting them to CSV files.
# Author: Lifei Yu
#
# --- Third-Party Component Information ---
#
# Plogger uses Sensor.dll (Compiled from LibreHardwareMonitorLib) partially to read sensors are not supported by native Windows Powershell, WMI/CIM such as CPU, GPU temperature, power consumption real-time clock speed, etc.
#
# LibreHardwareMonitorLib is licensed under the Mozilla Public License 2.0 (MPL 2.0).
# Original project source code (LibreHardwareMonitor) is available at: https://github.com/LibreHardwareMonitor/LibreHardwareMonitor
# The MPL 2.0 license terms are available at: https://www.mozilla.org/en-US/MPL/2.0/
# Copyright (c) LibreHardwareMonitor contributors
#
#####################################################################################################################################
# IMPORTANT: This script requires administrator privileges to function correctly due to its use of WMI/CIM and external libraries.
# Please run this script in Powershell with Administrator (e.g., Right-click -> Run as Administrator).
# Then run the script using the command: "& "C:\Users\username\Plogger.ps1""
# If the script is blocked by security policies, please run the command in PowerShell ISE with Administrator privileges.
#####################################################################################################################################
# IMPORTATNT: If you encountered issue with execution policy, please run the command: "set-executionpolicy unrestricted" in PowerShell with Administrator privileges.
#####################################################################################################################################

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
    Write-Error "Ensure Sensor.dll is in the same directory as Plogger.ps1 or the compiled Plogger.exe."
    exit 1
}

Write-Host "Plogger base directory determined as: $Global:ResolvedScriptRoot"

# Restore original try/catch for loading Sensor.dll
try {
    Add-Type -Path "$Global:ResolvedScriptRoot\Sensor.dll" -ErrorAction Stop
} catch {
    Write-Error "Failed to load Sensor.dll. Ensure the DLL is in the same directory as the script ($Global:ResolvedScriptRoot). Error: $($_.Exception.Message)"
    exit 1
}

# Define the Visitor class needed by the hardware monitoring library
Add-Type -TypeDefinition @"
using LibreHardwareMonitor.Hardware;
public class UpdateVisitor : IVisitor {
    public void VisitComputer(IComputer computer) {
        computer.Traverse(this);
    }
    public void VisitHardware(IHardware hardware) {
        hardware.Update();
        foreach (IHardware subHardware in hardware.SubHardware) {
            subHardware.Accept(this);
        }
    }
    public void VisitSensor(ISensor sensor) { }
    public void VisitParameter(IParameter parameter) { }
}
"@ -ReferencedAssemblies "$Global:ResolvedScriptRoot\Sensor.dll"


# Display disclaimer
Write-Host "DISCLAIMER

This script collects system resource usage data (CPU, RAM, running processes, and resource consumption metrics) from your computer for diagnostic purposes only. It utilizes native Windows functionality and incorporates the Sensor.dll library to gather comprehensive performance information, including data points that may not be accessible via native Windows tool.

By running this script, you acknowledge and agree that:

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


# Function to capture hardware resource usage
function Capture-ResourceUsage {
    param (
        [int]$Duration # Duration in minutes. 0 means indefinite.
    )

    # --- ADDED: Power Mode Overlay GUIDs Mapping ---
    $powerModeOverlayGuids = @{
        "ded574b5-45a0-4f42-8737-46345c09c238" = "Best Performance"
        "31fccf00-1979-49fb-97ca-292516017500" = "Better Performance"
        "961cc777-2547-4f9d-8174-7d86181b8a7a" = "Balanced (Recommended / Better Battery)"
        "12957487-2663-4308-8a36-80225202370b" = "Battery Saver / Best Power Efficiency"
        "00000000-0000-0000-0000-000000000000" = "System Default / Varies"
    }
    # --- END ADDED ---

    # --- Get Logical Core Count ---
    $logicalCoreCount = [Environment]::ProcessorCount
    Write-Host "System has $logicalCoreCount logical processors."
    # --- END ---

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

    $startTime = Get-Date
    # If Duration is 0, loop indefinitely, otherwise calculate endTime
    $endTime = if ($Duration -gt 0) { $startTime.AddMinutes($Duration) } else { $null }
    $data = @()
    # --- CHANGE: Use $PSScriptRoot and new filename format ---
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

    # Initialize hardware monitoring library
    $computer = New-Object LibreHardwareMonitor.Hardware.Computer
    $computer.IsCpuEnabled = $true
    $computer.IsGpuEnabled = $true # Enable GPU monitoring
    # Add other hardware types if needed later:
    # $computer.IsMemoryEnabled = $true
    $computer.IsMotherboardEnabled = $true # Enable motherboard monitoring for fans
    $computer.IsBatteryEnabled = $true     # Enable battery monitoring via LHM
    # $computer.IsControllerEnabled = $true
    # $computer.IsNetworkEnabled = $true # Already handled by WMI/CIM, keep false unless needed
    # $computer.IsStorageEnabled = $true # Already handled by PerfCounters, keep false unless needed

    try {
        $computer.Open()
        $updateVisitor = New-Object UpdateVisitor # Instantiate the visitor

        # --- CHANGE: Add flags for one-time warnings ---
        # $script:cpuTempWarningLogged = $false # No longer needed with direct hardware monitoring library use
        # $script:fanSpeedWarningLogged = $false # REMOVED
        $script:diskIOWarningLogged = $false   # Add flag for Disk IO warning
        $script:batteryWarningLogged = $false  # Add flag for battery warnings
        # --- END CHANGE ---

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
            $cpuUsageVal = $null
            $ramAvailableMBVal = $null
            $ramUsedMBVal = $null
            $diskIOVal = $null
            $networkIOVal = $null
            $batteryVal = $null
            $brightnessVal = $null
            $cpuTempVal = $null
            # $fanSpeedVal = $null # REMOVED
            $cpuPowerVal = $null # RE-ADDED: Variable for CPU Power
            # $gpuPowerVal = $null # REMOVED
            # REMOVED: Variables for GPU Load Metrics
            # $gpuLoadVal = $null
            # $gpuVideoEncodeVal = $null
            # $gpuVideoDecodeVal = $null
            # $gpu3dLoadVal = $null
            # --- ADDED: Initialize Power Plan Metric Variables ---
            $basePlanNameVal = $null
            $basePlanGUIDVal = $null
            $powerStatusVal = $null # For AC/DC status
            $activeOverlayNameVal = $null
            $activeOverlayGUIDVal = $null
            # --- END ADDED ---
            # --- ADDED: New Battery and Voltage Metrics ---
            $lhmBatteryChargeCurrentVal = $null
            $lhmBatteryChargeRateVal = $null
            $lhmBatteryWearVal = $null          # For direct wear/health from LHM
            $lhmBatteryDesignCapacityVal = $null # For design capacity from LHM
            $finalBatteryDegradationPercVal = $null
            # Note: $allVoltageData will be initialized inside the loop before collection
            # --- ADDED: WMI Battery Capacity/Rate Variables ---
            $script:wmiDesignCapacitymWh = $null
            $script:wmiFullChargedCapacitymWh = $null
            $script:wmiRemainingCapacitymWh = $null
            $script:wmiDischargeRateW = $null
            # --- END ADDED ---

            # Use try-catch for each potentially failing call
            # --- MODIFIED: Get CPU Usage using hardware monitoring library ---
            $cpuUsageVal = $null # Reset before trying
            try {
                # Update sensor values if not already updated in this loop iteration
                $computer.Accept($updateVisitor)
            
                # Find CPU hardware if not already found
                if ($null -eq $cpuHardware) {
                    $cpuHardware = $computer.Hardware | Where-Object {
                        $_.HardwareType -eq [LibreHardwareMonitor.Hardware.HardwareType]::Cpu
                    } | Select-Object -First 1
                }
            
                if ($cpuHardware) {
                    # Look specifically for the /intelcpu/0/load/0 sensor as requested
                    $loadSensor = $cpuHardware.Sensors | Where-Object {
                        $_.SensorType -eq [LibreHardwareMonitor.Hardware.SensorType]::Load -and
                        $_.Identifier.ToString() -like "*/intelcpu/0/load/0*"
                    } | Select-Object -First 1
            
                    # Fallback 1: Try to find the "CPU Total" load sensor if specific one not found
                    if (-not $loadSensor) {
                        $loadSensor = $cpuHardware.Sensors | Where-Object {
                            $_.SensorType -eq [LibreHardwareMonitor.Hardware.SensorType]::Load -and
                            $_.Name -eq 'CPU Total'
                        } | Select-Object -First 1
                    }
            
                    # Fallback 2: Get the first available CPU Load sensor if neither specific nor "CPU Total" found
                    if (-not $loadSensor) {
                        $loadSensor = $cpuHardware.Sensors | Where-Object {
                            $_.SensorType -eq [LibreHardwareMonitor.Hardware.SensorType]::Load
                        } | Select-Object -First 1
                        
                        if ($loadSensor) {
                            Write-Verbose "Using fallback CPU Load sensor: $($loadSensor.Name) ($($loadSensor.Identifier))"
                        }
                    }
            
                    if ($loadSensor -and $loadSensor.Value -ne $null) {
                        $cpuUsageVal = $loadSensor.Value
                        Write-Verbose "CPU Usage from hardware monitoring library ($($loadSensor.Name)): $cpuUsageVal %"
                    } else {
                        Write-Warning "Could not find a suitable CPU Load sensor via hardware monitoring library."
                        # Fallback to original method if no LibreHardwareMonitor sensor found
                        try {
                            $cpuUsageVal = (Get-Counter '\Processor(_Total)\% Processor Time' -ErrorAction Stop).CounterSamples.CookedValue
                            Write-Verbose "Falling back to WMI for CPU usage: $cpuUsageVal %"
                        } catch {
                            Write-Warning "Failed to get CPU Usage via WMI fallback: $($_.Exception.Message)"
                        }
                    }
                } else {
                    Write-Warning "Could not find CPU hardware via hardware monitoring library."
                    # Fallback to original method if no CPU hardware found
                    try {
                        $cpuUsageVal = (Get-Counter '\Processor(_Total)\% Processor Time' -ErrorAction Stop).CounterSamples.CookedValue
                        Write-Verbose "Falling back to WMI for CPU usage: $cpuUsageVal %"
                    } catch {
                        Write-Warning "Failed to get CPU Usage via WMI fallback: $($_.Exception.Message)"
                    }
                }
            } catch {
                Write-Warning "Failed to get CPU Usage via hardware monitoring library: $($_.Exception.Message)"
                # Fallback to original method on exception
                try {
                    $cpuUsageVal = (Get-Counter '\Processor(_Total)\% Processor Time' -ErrorAction Stop).CounterSamples.CookedValue
                    Write-Verbose "Falling back to WMI for CPU usage: $cpuUsageVal %"
                } catch {
                    Write-Warning "Failed to get CPU Usage via WMI fallback: $($_.Exception.Message)"
                }
            }
            # --- END MODIFIED ---
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
            # --- COMPLETELY REVISED: Network IO monitoring using WMI/CIM instead of counters ---
            try {
                # Get network interface statistics using CIM instead of performance counters
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
                
                # Log the adapter names if needed for debugging
                # Write-Host "Found adapters: $($physicalAdapters.Name -join ', ')"
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
            # --- END COMPLETELY REVISED ---
            # --- ENHANCED: Battery monitoring with multiple methods and WMI classes ---
            try { 
                # PRIMARY METHOD: Get battery data from ROOT\cimv2 namespace
                $batteryVal = $null
                $batteries = Get-CimInstance -Namespace "ROOT\cimv2" -ClassName Win32_Battery -ErrorAction Stop
                
                # Check if any batteries were found
                if ($batteries -and $batteries.Count -gt 0) {
                    # Get charge remaining from the first battery
                    $batteryVal = $batteries[0].EstimatedChargeRemaining
                    
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
                
                # FALLBACK METHOD: If no battery data from primary method, try ROOT\WMI namespace classes
                if ($null -eq $batteryVal) {
                    try {
                        # Try getting data from ROOT\WMI namespace
                        $wmiNamespace = "ROOT\WMI"
                        # Reset script variables for this iteration
                        $script:wmiDesignCapacitymWh = $null
                        $script:wmiFullChargedCapacitymWh = $null
                        $script:wmiRemainingCapacitymWh = $null
                        $script:wmiDischargeRateW = $null

                        # Get Full Charged Capacity
                        try {
                            $tempFullChargedCapacity = (Get-CimInstance -Namespace $wmiNamespace -ClassName "BatteryFullChargedCapacity" -ErrorAction Stop).FullChargedCapacity
                            if ($null -ne $tempFullChargedCapacity) {
                                $script:wmiFullChargedCapacitymWh = $tempFullChargedCapacity
                                Write-Verbose "WMI Full Charged Capacity: $($script:wmiFullChargedCapacitymWh) mWh"
                            }
                        } catch { Write-Warning "Failed to get WMI BatteryFullChargedCapacity: $($_.Exception.Message)" }

                        # Get Design Capacity
                        # try {
                        #     $batteryStaticData = Get-CimInstance -Namespace $wmiNamespace -ClassName "BatteryStaticData" -ErrorAction Stop
                        #     if ($null -ne $batteryStaticData.DesignedCapacity) {
                        #         $script:wmiDesignCapacitymWh = $batteryStaticData.DesignedCapacity
                        #         Write-Verbose "WMI Design Capacity (BatteryStaticData): $($script:wmiDesignCapacitymWh) mWh"
                        #     }
                        # } catch { Write-Warning "Failed to get WMI BatteryStaticData (Design Capacity): $($_.Exception.Message)" }

                        # Get Remaining Capacity and Discharge Rate
                        try {
                            $batteryStatus = Get-CimInstance -Namespace $wmiNamespace -ClassName "BatteryStatus" -ErrorAction Stop
                            if ($null -ne $batteryStatus.RemainingCapacity) {
                                $script:wmiRemainingCapacitymWh = $batteryStatus.RemainingCapacity
                                Write-Verbose "WMI Remaining Capacity: $($script:wmiRemainingCapacitymWh) mWh"
                            }
                            if ($null -ne $batteryStatus.DischargeRate) {
                                # DischargeRate is often in mW, convert to W
                                try {
                                    $dischargeRateMw = [double]$batteryStatus.DischargeRate
                                    if ($dischargeRateMw -gt 0) { # Only store positive discharge rate
                                        $script:wmiDischargeRateW = [math]::Round($dischargeRateMw / 1000, 3)
                                        Write-Verbose "WMI Discharge Rate: $($script:wmiDischargeRateW) W (from $dischargeRateMw mW)"
                                    } else {
                                        $script:wmiDischargeRateW = 0 # Store 0 if not discharging or charging
                                        Write-Verbose "WMI Discharge Rate is zero or negative (Charging/Idle): $dischargeRateMw mW"
                                    }
                                } catch {
                                    Write-Warning "Could not convert WMI DischargeRate '$($batteryStatus.DischargeRate)' to numeric Watts: $($_.Exception.Message)"
                                }
                            }
                            # Optional: Capture charging status if needed later
                            # $charging = $batteryStatus.Charging
                            # $powerOnline = $batteryStatus.PowerOnline
                        } catch { Write-Warning "Failed to get WMI BatteryStatus (Remaining Capacity/Discharge Rate): $($_.Exception.Message)" }

                        # Calculate percentage if possible (for fallback $batteryVal)
                        if ($script:wmiFullChargedCapacitymWh -gt 0 -and $null -ne $script:wmiRemainingCapacitymWh) {
                            $batteryVal = [Math]::Round(($script:wmiRemainingCapacitymWh / $script:wmiFullChargedCapacitymWh) * 100)
                            if (-not $script:batteryWarningLogged) {
                                Write-Host "Battery detected (using ROOT\WMI): $batteryVal%"
                                Write-Verbose "WMI Details - Design: $($script:wmiDesignCapacitymWh), Full: $($script:wmiFullChargedCapacitymWh), Remaining: $($script:wmiRemainingCapacitymWh), Discharge Rate: $($script:wmiDischargeRateW) W"
                            }
                        }
                    } catch {
                        Write-Verbose "Fallback battery detection failed: $($_.Exception.Message)"
                    }
                }
                
                # If still no battery data, mark as N/A (desktop PC)
                if ($null -eq $batteryVal) {
                    if (-not $script:batteryWarningLogged) {
                        Write-Verbose "No battery detected - this appears to be a desktop PC or VM"
                    }
                    $batteryVal = "N/A" # Use N/A to indicate desktop PC
                }
                
                $script:batteryWarningLogged = $true
                
            } catch { 
                if (-not $script:batteryWarningLogged) {
                    Write-Warning "Failed to get Battery Status: $($_.Exception.Message)"
                    $script:batteryWarningLogged = $true
                }
                $batteryVal = "Error"  # Indicate an error occurred
            }
            # --- END IMPROVED ---
            try { $brightnessVal = (Get-CimInstance -Namespace root/wmi -ClassName WmiMonitorBrightness -ErrorAction Stop).CurrentBrightness } catch { Write-Warning "Failed to get Brightness: $($_.Exception.Message)" } # Use Get-CimInstance

            # --- CHANGE: Disk IO retrieval with single warning scope fix ---
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

            # --- NEW: Get CPU Temperature using hardware monitoring library ---
            $cpuTempVal = $null # Reset before trying
            try {
                $computer.Accept($updateVisitor) # Update sensor values

                $cpuHardware = $computer.Hardware | Where-Object { $_.HardwareType -eq [LibreHardwareMonitor.Hardware.HardwareType]::Cpu }

                if ($cpuHardware) {
                    # Prioritize "CPU Package" sensor, fallback to any temperature sensor if not found
                    $tempSensor = $cpuHardware.Sensors | Where-Object {
                        $_.SensorType -eq [LibreHardwareMonitor.Hardware.SensorType]::Temperature -and $_.Name -like '*Package*'
                    } | Select-Object -First 1

                    if (-not $tempSensor) {
                         # Fallback: Get the first available temperature sensor for the CPU
                         $tempSensor = $cpuHardware.Sensors | Where-Object {
                            $_.SensorType -eq [LibreHardwareMonitor.Hardware.SensorType]::Temperature
                         } | Select-Object -First 1
                         if ($tempSensor) {
                             Write-Verbose "Using fallback CPU temperature sensor: $($tempSensor.Name)"
                         }
                    }

                    if ($tempSensor -and $tempSensor.Value -ne $null) {
                        $cpuTempVal = $tempSensor.Value
                        Write-Verbose "CPU Temp from hardware monitoring library ($($tempSensor.Name)): $cpuTempVal °C"
                    } else {
                        Write-Warning "Could not find a suitable CPU Temperature sensor via hardware monitoring library."
                    }
                } else {
                    Write-Warning "Could not find CPU hardware via hardware monitoring library."
                }
            } catch {
                Write-Warning "Failed to get CPU Temperature via hardware monitoring library: $($_.Exception.Message)"
                $cpuTempVal = $null # Ensure it's null on error
            }

            # --- RE-ADDED: Get CPU Power using hardware monitoring library ---
            try {
                # $computer.Accept($updateVisitor) # Already called for temperature

                # $cpuHardware already found in temperature section
                if ($cpuHardware) {
                    # Find the power sensor, often named "CPU Package" or similar
                    $powerSensor = $cpuHardware.Sensors | Where-Object {
                        $_.SensorType -eq [LibreHardwareMonitor.Hardware.SensorType]::Power -and ($_.Name -like '*Package*' -or $_.Name -like '*CPU Power*')
                    } | Select-Object -First 1

                    if ($powerSensor -and $powerSensor.Value -ne $null) {
                        $cpuPowerVal = $powerSensor.Value
                        Write-Verbose "CPU Power from hardware monitoring library ($($powerSensor.Name)): $cpuPowerVal W"
                    } else {
                        Write-Warning "Could not find a suitable CPU Power sensor via hardware monitoring library."
                    }
                } # No need for else, warning already given if CPU hardware not found
            } catch {
                Write-Warning "Failed to get CPU Power via hardware monitoring library: $($_.Exception.Message)"
                $cpuPowerVal = $null # Ensure it's null on error
            }
            # --- END RE-ADDED ---

            # --- NEW: Get Fan Speeds using hardware monitoring library (simplified) ---
            try {
                # Initialize hashtable to store fan data
                $fanData = @{}
                
                # Make sure to update all hardware
                $computer.Accept($updateVisitor)
                
                # Iterate through all hardware components
                foreach ($hardware in $computer.Hardware) {
                    # Find all fan sensors
                    $fanSensors = $hardware.Sensors | Where-Object {
                        $_.SensorType -eq [LibreHardwareMonitor.Hardware.SensorType]::Fan
                    }
                    
                    # Store each fan's name and RPM value
                    foreach ($sensor in $fanSensors) {
                        if ($null -ne $sensor.Value) {
                            $fanData[$sensor.Name] = [math]::Round($sensor.Value)
                            Write-Verbose "Fan detected: $($sensor.Name) at $($fanData[$sensor.Name]) RPM"
                        }
                    }
                }
                
                # Convert hashtable to string format for CSV storage
                if ($fanData.Count -gt 0) {
                    $fanSpeedsVal = ($fanData.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ";"
                    Write-Verbose "Fan speeds: $fanSpeedsVal"
                } else {
                    $fanSpeedsVal = $null
                    Write-Verbose "No fan sensors detected"
                }
            } catch {
                Write-Warning "Failed to get Fan Speeds via hardware monitoring library: $($_.Exception.Message)"
                $fanSpeedsVal = $null # Ensure it's null on error
            }
            # --- END NEW ---

            # --- MODIFIED: Get GPU Metrics (with multi-GPU support) ---
            try {
                # Initialize a hashtable to store metrics for each GPU
                $gpuMetrics = @{}
                
                # Find GPU hardware
                $gpuHardware = $computer.Hardware | Where-Object {
                    $_.HardwareType -eq [LibreHardwareMonitor.Hardware.HardwareType]::GpuNvidia -or
                    $_.HardwareType -eq [LibreHardwareMonitor.Hardware.HardwareType]::GpuAmd -or
                    $_.HardwareType -eq [LibreHardwareMonitor.Hardware.HardwareType]::GpuIntel
                }
                
                # Log how many GPUs were found
                Write-Verbose "Found $($gpuHardware.Count) GPU(s)"
                
                foreach ($gpu in $gpuHardware) {
                    # Get GPU name and create a sanitized version for use in property names
                    $gpuName = $gpu.Name
                    $gpuType = $gpu.HardwareType.ToString() -replace 'Gpu', ''  # Extract vendor (Nvidia, Amd, Intel)
                    
                    # Create a sanitized key for this GPU (remove spaces, special chars)
                    $gpuKey = "$gpuType-$($gpuName -replace '[^a-zA-Z0-9]', '_')"
                    
                    Write-Verbose "Processing GPU: $gpuName (Key: $gpuKey)"
                    
                    # Initialize metrics for this GPU
                    $gpuMetrics[$gpuKey] = @{
                        'Name' = $gpuName
                        'Type' = $gpuType
                        'Power' = $null
                        'VideoDecode' = $null
                        'VideoProcessing' = $null
                        '3DLoad' = $null
                        'CoreLoad' = $null      # Added for NVIDIA GPU core usage
                        'Temperature' = $null   # Added for NVIDIA GPU temperature
                    }
                    
                    # Check if this is an NVIDIA GPU to use specific sensor paths
                    $isNvidiaGpu = $gpu.HardwareType -eq [LibreHardwareMonitor.Hardware.HardwareType]::GpuNvidia
                    
                    # GPU Core Load (NVIDIA specific path)
                    if ($isNvidiaGpu) {
                        $coreLoadSensor = $gpu.Sensors | Where-Object {
                            $_.SensorType -eq [LibreHardwareMonitor.Hardware.SensorType]::Load -and
                            $_.Identifier.ToString() -like "*/gpu-nvidia/0/load/0*"
                        } | Select-Object -First 1
                        
                        if ($coreLoadSensor -and $coreLoadSensor.Value -ne $null) {
                            $gpuMetrics[$gpuKey]['CoreLoad'] = $coreLoadSensor.Value
                            Write-Verbose "GPU $gpuKey Core Load: $($coreLoadSensor.Value) % (using /gpu-nvidia/0/load/0)"
                        }
                    }
                    
                    # GPU Temperature (NVIDIA specific path)
                    if ($isNvidiaGpu) {
                        $tempSensor = $gpu.Sensors | Where-Object {
                            $_.SensorType -eq [LibreHardwareMonitor.Hardware.SensorType]::Temperature -and
                            $_.Identifier.ToString() -like "*/gpu-nvidia/0/temperature/0*"
                        } | Select-Object -First 1
                        
                        if ($tempSensor -and $tempSensor.Value -ne $null) {
                            $gpuMetrics[$gpuKey]['Temperature'] = $tempSensor.Value
                            Write-Verbose "GPU $gpuKey Temperature: $($tempSensor.Value) °C (using /gpu-nvidia/0/temperature/0)"
                        }
                    }
                    
                    # GPU Power (NVIDIA specific path first, then fallback)
                    $powerSensor = $null
                    if ($isNvidiaGpu) {
                        $powerSensor = $gpu.Sensors | Where-Object {
                            $_.SensorType -eq [LibreHardwareMonitor.Hardware.SensorType]::Power -and
                            $_.Identifier.ToString() -like "*/gpu-nvidia/0/power/0*"
                        } | Select-Object -First 1
                        
                        if ($powerSensor -and $powerSensor.Value -ne $null) {
                            $gpuMetrics[$gpuKey]['Power'] = $powerSensor.Value
                            Write-Verbose "GPU $gpuKey Power: $($powerSensor.Value) W (using /gpu-nvidia/0/power/0)"
                        }
                    }
                    
                    # Fallback to generic GPU Power sensor if specific one not found
                    if ($null -eq $powerSensor -or $null -eq $powerSensor.Value) {
                        $powerSensor = $gpu.Sensors | Where-Object {
                            $_.SensorType -eq [LibreHardwareMonitor.Hardware.SensorType]::Power -and
                            $_.Name -like "*GPU Power*"
                        } | Select-Object -First 1
                        
                        if ($powerSensor -and $powerSensor.Value -ne $null) {
                            $gpuMetrics[$gpuKey]['Power'] = $powerSensor.Value
                            Write-Verbose "GPU $gpuKey Power: $($powerSensor.Value) W (using generic sensor)"
                        }
                    }
                    
                    # GPU Video Decode Load
                    $videoDecodeSensor = $gpu.Sensors | Where-Object {
                        $_.SensorType -eq [LibreHardwareMonitor.Hardware.SensorType]::Load -and
                        $_.Name -like "*Video Decode*"
                    } | Select-Object -First 1
                    
                    if ($videoDecodeSensor -and $videoDecodeSensor.Value -ne $null) {
                        $gpuMetrics[$gpuKey]['VideoDecode'] = $videoDecodeSensor.Value
                        Write-Verbose "GPU $gpuKey Video Decode: $($videoDecodeSensor.Value) %"
                    }
                    
                    # GPU Video Processing Load
                    $videoProcessingSensor = $gpu.Sensors | Where-Object {
                        $_.SensorType -eq [LibreHardwareMonitor.Hardware.SensorType]::Load -and
                        $_.Name -like "*Video Processing*"
                    } | Select-Object -First 1
                    
                    if ($videoProcessingSensor -and $videoProcessingSensor.Value -ne $null) {
                        $gpuMetrics[$gpuKey]['VideoProcessing'] = $videoProcessingSensor.Value
                        Write-Verbose "GPU $gpuKey Video Processing: $($videoProcessingSensor.Value) %"
                    }
                    
                    # GPU 3D Load
                    $gpu3dSensor = $gpu.Sensors | Where-Object {
                        $_.SensorType -eq [LibreHardwareMonitor.Hardware.SensorType]::Load -and
                        $_.Name -like "*3D*"
                    } | Select-Object -First 1
                    
                    if ($gpu3dSensor -and $gpu3dSensor.Value -ne $null) {
                        $gpuMetrics[$gpuKey]['3DLoad'] = $gpu3dSensor.Value
                        Write-Verbose "GPU $gpuKey 3D Load: $($gpu3dSensor.Value) %"
                    }
                }
                
                # If no GPUs were found, log a message
                if ($gpuMetrics.Count -eq 0) {
                    Write-Verbose "No GPUs detected via hardware monitoring library"
                }
            } catch {
                Write-Warning "Failed to get GPU Metrics via hardware monitoring library: $($_.Exception.Message)"
                $gpuMetrics = @{} # Ensure it's an empty hashtable on error
            }
            # --- END MODIFIED ---

            # --- NEW: Get CPU Platform Power and Core Clocks ---
            try {
                $cpuPlatformPowerVal = $null
                $cpuCoreClocks = @{}
                
                # Find CPU hardware
                $cpuHardware = $computer.Hardware | Where-Object {
                    $_.HardwareType -eq [LibreHardwareMonitor.Hardware.HardwareType]::Cpu
                }
                
                foreach ($cpu in $cpuHardware) {
                    # CPU Platform Power
                    $platformPowerSensor = $cpu.Sensors | Where-Object {
                        $_.SensorType -eq [LibreHardwareMonitor.Hardware.SensorType]::Power -and
                        $_.Name -like "*Platform*"
                    } | Select-Object -First 1
                    
                    if ($platformPowerSensor -and $platformPowerSensor.Value -ne $null) {
                        $cpuPlatformPowerVal = $platformPowerSensor.Value
                        Write-Verbose "CPU Platform Power: $cpuPlatformPowerVal W"
                    }
                    
                    # CPU Core Clocks
                    $clockSensors = $cpu.Sensors | Where-Object {
                        $_.SensorType -eq [LibreHardwareMonitor.Hardware.SensorType]::Clock -and
                        $_.Name -like "CPU Core #*"
                    }
                    
                    foreach ($sensor in $clockSensors) {
                        if ($null -ne $sensor.Value) {
                            $cpuCoreClocks[$sensor.Name] = [math]::Round($sensor.Value)
                            Write-Verbose "$($sensor.Name): $($cpuCoreClocks[$sensor.Name]) MHz"
                        }
                    }
                }
                
                # Convert CPU core clocks hashtable to string format for CSV storage
                if ($cpuCoreClocks.Count -gt 0) {
                    $cpuCoreClockVal = ($cpuCoreClocks.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ";"
                    Write-Verbose "CPU Core Clocks: $cpuCoreClockVal"
                } else {
                    $cpuCoreClockVal = $null
                    Write-Verbose "No CPU core clock sensors detected"
                }
            } catch {
                Write-Warning "Failed to get CPU Platform Power and Core Clocks: $($_.Exception.Message)"
                $cpuPlatformPowerVal = $null
                $cpuCoreClockVal = $null
            }
            # --- END NEW ---

            # --- NEW: Collect All Voltages & LHM Battery Metrics ---
            $allVoltageData = @{} # Initialize/clear for current iteration
            $lhmBatteryChargeCurrentVal = $null
            $lhmBatteryChargeRateVal = $null
            $lhmBatteryWearVal = $null
            $lhmBatteryDesignCapacityVal = $null

            try {
                # $computer.Accept($updateVisitor) # Already called earlier in the loop

                # Collect All Voltages
                foreach ($hardwareItem in $computer.Hardware) {
                    foreach ($sensorItem in $hardwareItem.Sensors) {
                        if ($sensorItem.SensorType -eq [LibreHardwareMonitor.Hardware.SensorType]::Voltage) {
                            if ($null -ne $sensorItem.Value) {
                                $hwTypeSafe = ($hardwareItem.HardwareType.ToString() -replace '[^a-zA-Z0-9_]', '_').TrimStart('_')
                                $hwNameSafe = ($hardwareItem.Name -replace '[^a-zA-Z0-9_]', '_').TrimStart('_')
                                $sNameSafe  = ($sensorItem.Name -replace '[^a-zA-Z0-9_]', '_').TrimStart('_')
                                # Identifier can contain slashes, replace with something CSV safe
                                $sIdSafe    = ($sensorItem.Identifier.ToString() -replace '/', '_slash_' -replace '[^a-zA-Z0-9_]', '_').TrimStart('_')
                                
                                $voltageKey = "Voltage_${hwTypeSafe}_${hwNameSafe}_${sNameSafe}_${sIdSafe}"
                                # Ensure key uniqueness if names are too generic (though identifier should mostly handle this)
                                $counter = 1
                                $originalVoltageKey = $voltageKey
                                while ($allVoltageData.ContainsKey($voltageKey)) {
                                    $voltageKey = "${originalVoltageKey}_${counter}"
                                    $counter++
                                }
                                $allVoltageData[$voltageKey] = $sensorItem.Value
                                Write-Verbose "Voltage Sensor: $voltageKey = $($sensorItem.Value) V"
                            }
                        }
                    }
                }

                # Collect LHM Battery Metrics
                $batteryHardware = $computer.Hardware | Where-Object { $_.HardwareType -eq [LibreHardwareMonitor.Hardware.HardwareType]::Battery } | Select-Object -First 1
                if (-not $batteryHardware) {
                    # Battery sensors might be on the motherboard for some systems
                    $batteryHardware = $computer.Hardware | Where-Object { $_.HardwareType -eq [LibreHardwareMonitor.Hardware.HardwareType]::Motherboard } | Select-Object -First 1
                    if ($batteryHardware) { Write-Verbose "No dedicated LHM Battery hardware found, checking Motherboard for battery sensors."}
                }

                if ($batteryHardware) {
                    Write-Verbose "Processing LHM Battery Hardware: $($batteryHardware.Name)"
                    foreach ($sensor in $batteryHardware.Sensors) {
                        # Charge Current
                        if ($sensor.SensorType -eq [LibreHardwareMonitor.Hardware.SensorType]::Current -and ($sensor.Name -like "*Charge Current*" -or $sensor.Name -like "*Battery Current*")) {
                            if ($null -ne $sensor.Value) {
                                $lhmBatteryChargeCurrentVal = $sensor.Value
                                Write-Verbose "LHM Battery Charge Current ($($sensor.Name)): $lhmBatteryChargeCurrentVal A"
                            }
                        }
                        # Charge Rate
                        if ($sensor.SensorType -eq [LibreHardwareMonitor.Hardware.SensorType]::Power -and ($sensor.Name -like "*Charge Rate*" -or $sensor.Name -like "*Battery Power*")) {
                            if ($null -ne $sensor.Value) {
                                $lhmBatteryChargeRateVal = $sensor.Value
                                Write-Verbose "LHM Battery Charge Rate ($($sensor.Name)): $lhmBatteryChargeRateVal W"
                            }
                        }
                        # Wear Level / Health
                        if (($sensor.SensorType -eq [LibreHardwareMonitor.Hardware.SensorType]::Level -or $sensor.SensorType -eq [LibreHardwareMonitor.Hardware.SensorType]::Factor) `
                            -and ($sensor.Name -like "*Wear*" -or $sensor.Name -like "*Health*" -or $sensor.Name -like "*Degradation*")) {
                            if ($null -ne $sensor.Value) {
                                $lhmBatteryWearVal = $sensor.Value # Assuming this is a percentage. If it's "Health", degradation = 100 - Health.
                                                                # If it's "Wear Level" directly, it might be the degradation.
                                Write-Verbose "LHM Battery Wear/Health Sensor ($($sensor.Name)): $lhmBatteryWearVal %"
                            }
                        }
                        # Design Capacity
                        if ($sensor.SensorType -eq [LibreHardwareMonitor.Hardware.SensorType]::Capacity -and $sensor.Name -like "*Design*Capacity*") {
                            if ($null -ne $sensor.Value) {
                                $lhmBatteryDesignCapacityVal = $sensor.Value # Assuming mWh, consistent with WMI
                                Write-Verbose "LHM Battery Design Capacity ($($sensor.Name)): $lhmBatteryDesignCapacityVal mWh"
                            }
                        }
                    }
                } else {
                    Write-Verbose "No LHM Battery or suitable Motherboard hardware found for battery-specific sensors."
                }
            } catch {
                Write-Warning "Failed to get LHM Voltage/Battery metrics: $($_.Exception.Message)"
            }
            # --- END NEW ---

            # --- NEW: Calculate Battery Degradation ---
            $finalBatteryDegradationPercVal = $null
            try {
                $calcDesignCapacity = $null
                $calcFullChargeCapacity = $script:wmiFullChargedCapacityVal # From WMI block

                # Priority 1: LHM Direct Wear/Degradation Value
                # This requires interpreting $lhmBatteryWearVal. If it's "Health %", degradation is 100 - Health.
                # If it's "Wear Level %", it might be the degradation directly.
                # For now, we'll assume if $lhmBatteryWearVal is found, it's the degradation %. This might need adjustment based on actual sensor behavior.
                # Example: If LHM reports "Battery Health" as 90%, then degradation is 10%. If it reports "Wear Level" as 10%, that's degradation.
                # Let's assume $lhmBatteryWearVal is "Wear Level %" if found.
                if ($null -ne $lhmBatteryWearVal) {
                    $finalBatteryDegradationPercVal = $lhmBatteryWearVal
                    Write-Verbose "Using LHM direct Wear Level for degradation: $finalBatteryDegradationPercVal %"
                } else {
                    # Priority 2: Calculation using Design and Full Charge Capacity
                    # Determine Design Capacity source
                    if ($null -ne $lhmBatteryDesignCapacityVal) {
                        $calcDesignCapacity = $lhmBatteryDesignCapacityVal
                        Write-Verbose "Using LHM Design Capacity for degradation calculation: $calcDesignCapacity mWh"
                    } elseif ($null -ne $script:wmiDesignCapacityVal) {
                        $calcDesignCapacity = $script:wmiDesignCapacityVal
                        Write-Verbose "Using WMI Design Capacity for degradation calculation: $calcDesignCapacity mWh"
                    } else {
                        # Try one more WMI query for DesignCapacity from Win32_Battery if not found via BatteryStaticData
                        try {
                            $win32Battery = Get-CimInstance -ClassName Win32_Battery -ErrorAction SilentlyContinue | Select-Object -First 1
                            if ($null -ne $win32Battery.DesignCapacity) {
                                $calcDesignCapacity = $win32Battery.DesignCapacity
                                Write-Verbose "Using Win32_Battery Design Capacity for degradation calculation: $calcDesignCapacity mWh"
                                if ($null -eq $calcFullChargeCapacity -and $null -ne $win32Battery.FullChargeCapacity) { # Also get FullCharge if not available
                                     $calcFullChargeCapacity = $win32Battery.FullChargeCapacity
                                     Write-Verbose "Using Win32_Battery Full Charge Capacity: $calcFullChargeCapacity mWh"
                                }
                            }
                        } catch { Write-Warning "Failed to query Win32_Battery for DesignCapacity: $($_.Exception.Message)"}
                    }

                    # Perform calculation if we have both design and full charge capacity
                    if (($null -ne $calcDesignCapacity) -and ($calcDesignCapacity -gt 0) -and ($null -ne $calcFullChargeCapacity)) {
                        $finalBatteryDegradationPercVal = (($calcDesignCapacity - $calcFullChargeCapacity) / $calcDesignCapacity) * 100
                        Write-Verbose "Calculated Battery Degradation: $finalBatteryDegradationPercVal % (Design: $calcDesignCapacity, Full: $calcFullChargeCapacity)"
                    } else {
                        Write-Verbose "Could not calculate battery degradation due to missing Design or Full Charge Capacity."
                        Write-Verbose "LHM Design: $lhmBatteryDesignCapacityVal, WMI Design: $($script:wmiDesignCapacityVal), WMI Full: $($script:wmiFullChargedCapacityVal)"
                    }
                }
            } catch {
                Write-Warning "Error calculating battery degradation: $($_.Exception.Message)"
            }
            # --- END NEW ---

            # --- NEW: Capture Active Power Plan and Overlay ---
            try {
                # 1. Get the base Windows Power Plan
                $activeBasePlan = Get-CimInstance -Namespace root\cimv2\power -ClassName Win32_PowerPlan -Filter "IsActive = 'True'" -ErrorAction SilentlyContinue
                if ($activeBasePlan) {
                    $basePlanNameVal = $activeBasePlan.ElementName
                    $basePlanGUIDVal = $activeBasePlan.InstanceID -replace "Microsoft:PowerPlan\{(.+)\}", '$1'
                } else {
                    Write-Warning "Could not determine the active base Windows Power Plan."
                }
            } catch {
                Write-Warning "Error getting base Windows Power Plan: $($_.Exception.Message)"
            }

            # Determine AC/DC Power Status (needed for overlay logic and as a metric)
            $onACPower = $true # Assume AC if no battery or battery status indicates AC
            try {
                $powerSource = Get-CimInstance -ClassName Win32_Battery -ErrorAction SilentlyContinue
                if ($powerSource) {
                    if ($powerSource.BatteryStatus -eq 1) { # 1 = Discharging (DC)
                        $onACPower = $false
                    }
                }
                $powerStatusVal = if ($onACPower) { "AC Power" } else { "DC (Battery) Power" }
            } catch {
                Write-Warning "Error determining AC/DC Power Status: $($_.Exception.Message)"
                $powerStatusVal = "Error Determining Status" # Fallback value
            }

            try {
                # 3. Read the Active Power Mode Overlay from Registry
                $registryPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes"
                $overlayValueName = if ($onACPower) { "ActiveOverlayAcPowerScheme" } else { "ActiveOverlayDcPowerScheme" }
                
                $activeOverlayGuidVal = (Get-ItemProperty -Path $registryPath -Name $overlayValueName -ErrorAction SilentlyContinue).$overlayValueName
                
                if ($activeOverlayGuidVal) {
                    $activeOverlayNameVal = $powerModeOverlayGuids[$activeOverlayGuidVal.ToLower()] # Get from map

                    if (!$activeOverlayNameVal) { # Not in map
                        $activeOverlayNameVal = "Unknown Overlay GUID ($activeOverlayGuidVal)"
                    } else {
                        # It was found in the map. Check if it's the default GUID and refine if necessary.
                        if ($activeOverlayGuidVal.ToLower() -eq "00000000-0000-0000-0000-000000000000") {
                            if ($basePlanNameVal -and $basePlanNameVal -eq "Balanced") { # Check if basePlanNameVal is not null
                                $activeOverlayNameVal = "Balanced (Overlay matches base plan or system default)"
                            }
                            # else, it remains "System Default / Varies" from the map
                        }
                        # For other known GUIDs, $activeOverlayNameVal is already correctly set from the map.
                    }
                } else { # $activeOverlayGuidVal is null or empty (property not found or empty)
                    Write-Verbose "Active Power Mode Overlay GUID not found or empty in registry for '$overlayValueName'."
                    if ($basePlanNameVal) {
                        $activeOverlayNameVal = "Matches Base Plan ($basePlanNameVal)"
                    } else {
                        $activeOverlayNameVal = "No Overlay Set / Not Determined"
                    }
                    # $activeOverlayGuidVal is already $null or empty
                }
            } catch {
                Write-Warning "Error reading Power Mode Overlay from registry: $($_.Exception.Message)"
                $activeOverlayNameVal = "Error Reading Overlay"
            }
            # --- END NEW ---

            # --- REMOVED: GPU Power & Load retrieval ---

            # Create the base data object with non-GPU metrics
            $currentData = [PSCustomObject]@{
                Timestamp              = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
                CPUUsage               = $cpuUsageVal
                RAMUsedMB              = $ramUsedMBVal
                RAMAvailableMB         = $ramAvailableMBVal
                DiskIOTransferSec      = $diskIOVal
                NetworkIOBytesSec      = $networkIOVal
                BatteryPercentage      = $batteryVal
                ScreenBrightness       = $brightnessVal
                CPUTemperatureC        = if ($null -ne $cpuTempVal) { [math]::Round($cpuTempVal, 2) } else { $null }
                FanSpeeds              = $fanSpeedsVal # Fan speeds data
                CPUPowerW              = if ($null -ne $cpuPowerVal) { [math]::Round($cpuPowerVal, 2) } else { $null }
                CPUPlatformPowerW      = if ($null -ne $cpuPlatformPowerVal) { [math]::Round($cpuPlatformPowerVal, 2) } else { $null }
                CPUCoreClocks          = $cpuCoreClockVal
                # --- ADDED: Power Plan Metrics ---
                BasePowerPlanName      = $basePlanNameVal
                BasePowerPlanGUID      = $basePlanGUIDVal
                PowerStatus            = $powerStatusVal
                ActiveOverlayName      = $activeOverlayNameVal
                ActiveOverlayGUID      = $activeOverlayGUIDVal
                BatteryChargeCurrentA  = if ($null -ne $lhmBatteryChargeCurrentVal) { [math]::Round($lhmBatteryChargeCurrentVal, 3) } else { $null }
                BatteryChargeRateW     = if ($null -ne $lhmBatteryChargeRateVal) { [math]::Round($lhmBatteryChargeRateVal, 2) } else { $null }
                BatteryDegradationPerc = if ($null -ne $finalBatteryDegradationPercVal) { [math]::Round($finalBatteryDegradationPercVal, 2) } else { $null }
                # --- ADDED: WMI Battery Capacity/Rate Metrics ---
                BatteryDesignCapacitymWh    = $script:wmiDesignCapacitymWh
                BatteryFullChargedCapacitymWh = $script:wmiFullChargedCapacitymWh
                BatteryRemainingCapacitymWh = $script:wmiRemainingCapacitymWh
                BatteryDischargeRateW       = $script:wmiDischargeRateW
            }
            
            # --- ADDED: Dynamically add all collected voltage metrics ---
            if ($null -ne $allVoltageData) {
                foreach ($key in $allVoltageData.Keys) {
                    $value = $allVoltageData[$key]
                    $currentData | Add-Member -MemberType NoteProperty -Name $key -Value $(if ($null -ne $value) { [math]::Round($value, 3) } else { $null }) -ErrorAction SilentlyContinue
                }
            }
            # --- END ADDED ---

            # Add GPU metrics as separate columns for each GPU
            foreach ($gpuKey in $gpuMetrics.Keys) {
                $gpu = $gpuMetrics[$gpuKey]
                
                # Add Power metric
                if ($null -ne $gpu['Power']) {
                    $propertyName = "GPU_${gpuKey}_PowerW"
                    $currentData | Add-Member -MemberType NoteProperty -Name $propertyName -Value ([math]::Round($gpu['Power'], 2))
                }
                
                # Add Video Decode metric
                if ($null -ne $gpu['VideoDecode']) {
                    $propertyName = "GPU_${gpuKey}_VideoDecodePercent"
                    $currentData | Add-Member -MemberType NoteProperty -Name $propertyName -Value ([math]::Round($gpu['VideoDecode'], 2))
                }
                
                # Add Video Processing metric
                if ($null -ne $gpu['VideoProcessing']) {
                    $propertyName = "GPU_${gpuKey}_VideoProcessingPercent"
                    $currentData | Add-Member -MemberType NoteProperty -Name $propertyName -Value ([math]::Round($gpu['VideoProcessing'], 2))
                }
                
                # Add 3D Load metric
                if ($null -ne $gpu['3DLoad']) {
                    $propertyName = "GPU_${gpuKey}_3DLoadPercent"
                    $currentData | Add-Member -MemberType NoteProperty -Name $propertyName -Value ([math]::Round($gpu['3DLoad'], 2))
                }
                
                # Add GPU Core Load metric
                if ($null -ne $gpu['CoreLoad']) {
                    $propertyName = "GPU_${gpuKey}_CoreLoadPercent"
                    $currentData | Add-Member -MemberType NoteProperty -Name $propertyName -Value ([math]::Round($gpu['CoreLoad'], 2))
                }
                
                # Add GPU Temperature metric
                if ($null -ne $gpu['Temperature']) {
                    $propertyName = "GPU_${gpuKey}_TemperatureC"
                    $currentData | Add-Member -MemberType NoteProperty -Name $propertyName -Value ([math]::Round($gpu['Temperature'], 2))
                }
            }
            $data += $currentData

            # --- MODIFIED: Log per-process metrics including GPU memory ---
            try {
                $processBlockStartTime = Get-Date
                Write-Verbose "Starting process data collection block at $($processBlockStartTime.ToString('yyyy-MM-dd HH:mm:ss.fff'))"
                # Get standard process metrics
                # Use the timestamp captured at the start of this block for all processes in this collection
                $currentBlockTimestamp = $processBlockStartTime.ToString('yyyy-MM-dd HH:mm:ss')
                $procPerf = Get-CimInstance -ClassName Win32_PerfFormattedData_PerfProc_Process -ErrorAction Stop |
                    Where-Object { $_.Name -notin @('Idle','_Total') } |
                    Select-Object @{Name='Timestamp';Expression={$currentBlockTimestamp}},
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
                
                $processBlockEndTime = Get-Date
                Write-Verbose "Finished process data collection block at $($processBlockEndTime.ToString('yyyy-MM-dd HH:mm:ss.fff')). Duration: $(($processBlockEndTime - $processBlockStartTime).TotalMilliseconds) ms"
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
        # Close hardware monitoring library
        if ($computer -ne $null) {
            try {
                $computer.Close()
                Write-Verbose "Hardware monitoring library Computer object closed."
            } catch {
                 Write-Warning "Error closing hardware monitoring library Computer object: $($_.Exception.Message)"
            }
        }

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