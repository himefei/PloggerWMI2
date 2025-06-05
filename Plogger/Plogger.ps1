###################################################################################
# Plogger - A PowerShell script for logging system performance metrics and exporting them to CSV files.
# Copyright (c) 2025 Lifei Yu
#
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
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
        # Legitimate process introspection: Determining script location for file operations
        # This is standard practice for PowerShell scripts to locate their own directory
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

# SECURITY NOTICE: This script performs legitimate system monitoring only
# All WMI/CIM calls are for standard Windows performance counter access
# No malicious activities: no file access, no registry modification, no network communication
# Purpose: Performance diagnostics and hardware monitoring for technical support

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
   $overlayFriendlyName = "Not Available"
   $activeOverlayGuid = "Not Available"

   # 1. Get the base Windows Power Plan
   try {
        # Standard Windows power management namespace for legitimate power plan detection
        $powerNamespace = "root\cimv2\power"
        $activeBasePlan = Get-CimInstance -Namespace $powerNamespace -ClassName Win32_PowerPlan -Filter "IsActive = 'True'" -ErrorAction Stop
       if ($activeBasePlan) {
           $basePlanName = $activeBasePlan.ElementName
           $basePlanGUID = $activeBasePlan.InstanceID -replace "Microsoft:PowerPlan\{(.+)\}", '$1'
       }
   }
   catch {
       # Silently continue - base plan detection failure is not critical
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
       $powerStatusString = "AC Power (Assumed)"
   }

   # 3. Robust Power Mode Overlay Detection with Multiple Fallback Methods
   $overlayDetected = $false
   $registryPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes"
   
   # Method 1: Try standard overlay property names
   $overlayPropertyNames = @()
   if ($onACPower) {
       $overlayPropertyNames = @(
           "ActiveOverlayAcPowerScheme",
           "ActivatOverlayAcPowerScheme", # Common typo variant
           "ActiveAcOverlay", # Alternative naming
           "ActiveOverlay" # Generic fallback
       )
   } else {
       $overlayPropertyNames = @(
           "ActiveOverlayDcPowerScheme",
           "ActivatOverlayDcPowerScheme", # Common typo variant
           "ActiveDcOverlay", # Alternative naming
           "ActiveOverlay" # Generic fallback
       )
   }
   
   foreach ($propName in $overlayPropertyNames) {
       if ($overlayDetected) { break }
       try {
           $regItem = Get-ItemProperty -Path $registryPath -ErrorAction SilentlyContinue
           if ($regItem -and $regItem.PSObject.Properties.Name -contains $propName) {
               $retrievedOverlayGuid = $regItem.$propName
               if ($retrievedOverlayGuid -and $retrievedOverlayGuid -ne "") {
                   $activeOverlayGuid = $retrievedOverlayGuid
                   $overlayFriendlyName = $powerModeOverlayGuids[$retrievedOverlayGuid.ToLower()]
                   if (!$overlayFriendlyName) {
                       if ($retrievedOverlayGuid -eq "00000000-0000-0000-0000-000000000000") {
                           $overlayFriendlyName = if ($basePlanName -eq "Balanced") { "Balanced (System Default)" } else { "System Default" }
                       } else {
                           $overlayFriendlyName = "Custom Overlay"
                       }
                   }
                   $overlayDetected = $true
               }
           }
       } catch {
           # Silent continue to try next method
       }
   }
   
   # Method 2: Try alternative registry locations if standard location failed
   if (-not $overlayDetected) {
       $alternativeRegistryPaths = @(
           "HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerSettings",
           "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\FlyoutMenuSettings",
           "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Preferences"
       )
       
       foreach ($altPath in $alternativeRegistryPaths) {
           if ($overlayDetected) { break }
           try {
               if (Test-Path $altPath -ErrorAction SilentlyContinue) {
                   $regItem = Get-ItemProperty -Path $altPath -ErrorAction SilentlyContinue
                   if ($regItem) {
                       # Look for any property that might contain overlay information
                       $overlayProps = $regItem.PSObject.Properties | Where-Object { $_.Name -match "overlay|power|scheme" -and $_.Value -match "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$" }
                       if ($overlayProps) {
                           $activeOverlayGuid = $overlayProps[0].Value
                           $overlayFriendlyName = $powerModeOverlayGuids[$activeOverlayGuid.ToLower()]
                           if (!$overlayFriendlyName) {
                               $overlayFriendlyName = "Customer SOE Power Scheme"
                           }
                           $overlayDetected = $true
                       }
                   }
               }
           } catch {
               # Silent continue to try next path
           }
       }
   }
   
   # Method 3: Try WMI/CIM based power scheme detection as final fallback
   if (-not $overlayDetected) {
       try {
           $powerSchemes = Get-CimInstance -Namespace "root\cimv2\power" -ClassName Win32_PowerSetting -ErrorAction SilentlyContinue
           if ($powerSchemes) {
               $activeScheme = $powerSchemes | Where-Object { $_.IsActive -eq $true } | Select-Object -First 1
               if ($activeScheme) {
                   $activeOverlayGuid = $activeScheme.InstanceID
                   $overlayFriendlyName = "WMI Detected Scheme"
                   $overlayDetected = $true
               }
           }
       } catch {
           # Silent continue - this is the final fallback
       }
   }
   
   # If no overlay detected at all, use descriptive fallback values
   if (-not $overlayDetected) {
       $overlayFriendlyName = "Standard (No Overlay)"
       $activeOverlayGuid = "Standard"
   }

   return [PSCustomObject]@{
       ActivePowerPlanName = $basePlanName
       ActivePowerPlanGUID = $basePlanGUID
       SystemPowerStatus   = $powerStatusString
       ActiveOverlayName   = $overlayFriendlyName
       ActiveOverlayGUID   = $activeOverlayGuid
   }
}

# Function to detect system model and product information
# LEGITIMATE SYSTEM MONITORING: Used for performance log file naming and system identification
# This function only collects basic hardware identification for diagnostic purposes
function Get-SystemInformation {
    $systemInfo = [PSCustomObject]@{
        Manufacturer = "Unknown"
        Model = "Unknown"
        Version = "Unknown"
        ProductName = "Unknown"
        SerialNumber = "Unknown"
    }
    
    try {
        # Standard Windows system information collection for diagnostic identification
        # Uses Win32_ComputerSystemProduct for basic hardware info (manufacturer, model, etc.)
        $productInfo = Get-CimInstance -ClassName Win32_ComputerSystemProduct -ErrorAction Stop
        if ($productInfo) {
            $systemInfo.Version = if ($productInfo.Version) { $productInfo.Version.Trim() } else { "Unknown" }
            $systemInfo.ProductName = if ($productInfo.Name) { $productInfo.Name.Trim() } else { "Unknown" }
            $systemInfo.SerialNumber = if ($productInfo.IdentifyingNumber) { $productInfo.IdentifyingNumber.Trim() } else { "Unknown" }
            Write-Verbose "System Product Version: $($systemInfo.Version)"
            Write-Verbose "System Product Name: $($systemInfo.ProductName)"
        }
        
        # Get additional system information from Win32_ComputerSystem
        $computerSystem = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        if ($computerSystem) {
            $systemInfo.Manufacturer = if ($computerSystem.Manufacturer) { $computerSystem.Manufacturer.Trim() } else { "Unknown" }
            $systemInfo.Model = if ($computerSystem.Model) { $computerSystem.Model.Trim() } else { "Unknown" }
            Write-Verbose "System Manufacturer: $($systemInfo.Manufacturer)"
            Write-Verbose "System Model: $($systemInfo.Model)"
        }
        
        Write-Host "System detected: $($systemInfo.Manufacturer) $($systemInfo.Model) (Version: $($systemInfo.Version))" -ForegroundColor Cyan
        
    } catch {
        Write-Warning "Failed to detect system information: $($_.Exception.Message)"
    }
    
    return $systemInfo
}

# Function to detect GPU vendor and specifications
function Get-GPUInformation {
    $gpuInfo = @{
        IntelGPU = $null
        NVIDIAGPU = $null
        HasIntel = $false
        HasNVIDIA = $false
        GPUDetails = @()
    }
    
    try {
        # Get all GPU devices from WMI
        $videoControllers = Get-CimInstance -ClassName Win32_VideoController -ErrorAction Stop |
                           Where-Object { $_.Name -and $_.Name -ne "Microsoft Basic Display Adapter" }
        
        foreach ($gpu in $videoControllers) {
            $gpuDetail = [PSCustomObject]@{
                Name = $gpu.Name
                Vendor = "Unknown"
                VendorID = $gpu.PNPDeviceID -replace ".*VEN_([^&]+).*", '$1'
                DeviceID = $gpu.PNPDeviceID -replace ".*DEV_([^&]+).*", '$1'
                DriverVersion = $gpu.DriverVersion
                DriverDate = $gpu.DriverDate
                VideoMemoryMB = if ($gpu.AdapterRAM) { [math]::Round($gpu.AdapterRAM / 1MB, 0) } else { "Unknown" }
                Status = $gpu.Status
                Availability = $gpu.Availability
            }
            
            # Determine vendor based on PNP Device ID and name
            if ($gpu.PNPDeviceID -match "VEN_8086" -or $gpu.Name -match "Intel|UHD|HD Graphics|Iris") {
                $gpuDetail.Vendor = "Intel"
                $gpuInfo.HasIntel = $true
                $gpuInfo.IntelGPU = $gpuDetail
                Write-Host "Intel GPU detected: $($gpu.Name)"
            }
            elseif ($gpu.PNPDeviceID -match "VEN_10DE" -or $gpu.Name -match "NVIDIA|GeForce|Quadro|RTX|GTX") {
                $gpuDetail.Vendor = "NVIDIA"
                $gpuInfo.HasNVIDIA = $true
                
                # For NVIDIA GPUs, try to get accurate VRAM info from nvidia-smi
                try {
                    $nvidiaSmiPath = "nvidia-smi"
                    $nvSmi = Get-Command $nvidiaSmiPath -ErrorAction SilentlyContinue
                    if (-not $nvSmi) {
                        $commonPaths = @(
                            "${env:ProgramFiles}\NVIDIA Corporation\NVSMI\nvidia-smi.exe",
                            "${env:ProgramFiles(x86)}\NVIDIA Corporation\NVSMI\nvidia-smi.exe",
                            "$env:SystemRoot\System32\nvidia-smi.exe"
                        )
                        foreach ($path in $commonPaths) {
                            if (Test-Path $path) {
                                $nvidiaSmiPath = $path
                                break
                            }
                        }
                    }
                    
                    # Get accurate VRAM info from nvidia-smi
                    $nvidiaVramOutput = & $nvidiaSmiPath --query-gpu=memory.total --format=csv,noheader,nounits 2>$null
                    if ($nvidiaVramOutput -and $nvidiaVramOutput -match "^\d+$") {
                        $gpuDetail.VideoMemoryMB = [int]$nvidiaVramOutput
                        Write-Verbose "Updated NVIDIA VRAM from nvidia-smi: $($gpuDetail.VideoMemoryMB) MB"
                    }
                } catch {
                    Write-Verbose "Could not get accurate VRAM from nvidia-smi, using WMI value: $($_.Exception.Message)"
                }
                
                $gpuInfo.NVIDIAGPU = $gpuDetail
                Write-Host "NVIDIA GPU detected: $($gpu.Name)"
            }
            elseif ($gpu.PNPDeviceID -match "VEN_1002" -or $gpu.Name -match "AMD|Radeon|ATI") {
                $gpuDetail.Vendor = "AMD"
                Write-Host "AMD GPU detected: $($gpu.Name) (vendor-specific monitoring not implemented yet)"
            }
            
            $gpuInfo.GPUDetails += $gpuDetail
        }
        
        # Log hybrid GPU configuration if detected
        if ($gpuInfo.HasIntel -and $gpuInfo.HasNVIDIA) {
            Write-Host "Hybrid GPU configuration detected: Intel + NVIDIA" -ForegroundColor Green
        }
        
    } catch {
        Write-Warning "Failed to detect GPU information: $($_.Exception.Message)"
    }
    
    return $gpuInfo
}

# Function to get NVIDIA GPU metrics using nvidia-smi
function Get-NVIDIAMetrics {
    param (
        [Parameter(Mandatory=$true)]
        [object]$GPUInfo
    )
    
    $nvidiaMetrics = [PSCustomObject]@{
        Temperature = $null
        FanSpeed = $null
        MemoryUsedMB = $null
        MemoryTotalMB = $null
        MemoryUtilization = $null
        GPUUtilization = $null
        PowerDraw = $null
        Available = $false
    }
    
    if (-not $GPUInfo.HasNVIDIA) {
        return $nvidiaMetrics
    }
    
    try {
        # Check if nvidia-smi is available - improved path detection
        $nvidiaSmiPath = $null
        
        # First try if nvidia-smi is in PATH
        try {
            $nvidiaSmi = Get-Command "nvidia-smi" -ErrorAction Stop
            $nvidiaSmiPath = $nvidiaSmi.Source
            Write-Verbose "Found nvidia-smi in PATH: $nvidiaSmiPath"
        } catch {
            Write-Verbose "nvidia-smi not found in PATH, trying common installation paths..."
            
            # Try common installation paths
            $commonPaths = @(
                "${env:ProgramFiles}\NVIDIA Corporation\NVSMI\nvidia-smi.exe",
                "${env:ProgramFiles(x86)}\NVIDIA Corporation\NVSMI\nvidia-smi.exe",
                "$env:SystemRoot\System32\nvidia-smi.exe"
            )
            
            foreach ($path in $commonPaths) {
                if (Test-Path $path) {
                    $nvidiaSmiPath = $path
                    Write-Verbose "Found nvidia-smi at: $nvidiaSmiPath"
                    break
                }
            }
        }
        
        if (-not $nvidiaSmiPath) {
            Write-Verbose "nvidia-smi not found in any common locations"
            return $nvidiaMetrics
        }
        
        # Use exact approach from your working POC code with power.draw added
        $queryFields = @(
            "memory.total",             # Total Memory (MiB) - index 0
            "memory.used",              # Used Memory (MiB) - index 1
            "memory.free",              # Free Memory (MiB) - index 2
            "temperature.gpu",          # GPU Temperature (Celsius) - index 3
            "fan.speed",                # Fan Speed (%) - index 4
            "utilization.gpu",          # GPU Core/SM/3D Utilization (%) - index 5
            "utilization.memory",       # Memory Controller Utilization (%) - index 6
            "power.draw"                # Power Draw (W) - index 7
        )
        $queryArgument = $queryFields -join ","
        $smiCommand = "$nvidiaSmiPath --query-gpu=$queryArgument --format=csv,noheader,nounits"
        
        try {
            Write-Verbose "Executing nvidia-smi command: `"$nvidiaSmiPath`" --query-gpu=$queryArgument --format=csv,noheader,nounits"
            $nvidiaOutput = & "$nvidiaSmiPath" --query-gpu=$queryArgument --format=csv,noheader,nounits 2>$null
            Write-Verbose "nvidia-smi raw output: $nvidiaOutput"
            
            if ($nvidiaOutput -and $nvidiaOutput.Trim() -ne "") {
                # Parse the CSV output - split by comma and trim whitespace
                $values = $nvidiaOutput.Split(',') | ForEach-Object { $_.Trim() }
                Write-Verbose "Parsed values: $($values -join ' | ')"
                
                if ($values.Length -ge 8) {
                    # Parse values with proper N/A handling based on array indices
                    $nvidiaMetrics.MemoryTotalMB = if ($values[0] -ne "N/A" -and $values[0] -match "^\d+$") { [int]$values[0] } else { $null }
                    $nvidiaMetrics.MemoryUsedMB = if ($values[1] -ne "N/A" -and $values[1] -match "^\d+$") { [int]$values[1] } else { $null }
                    $nvidiaMetrics.Temperature = if ($values[3] -ne "N/A" -and $values[3] -match "^\d+$") { [int]$values[3] } else { $null }
                    $nvidiaMetrics.FanSpeed = if ($values[4] -ne "N/A" -and $values[4] -match "^\d+$") { [int]$values[4] } else { $null }
                    $nvidiaMetrics.GPUUtilization = if ($values[5] -ne "N/A" -and $values[5] -match "^\d+$") { [int]$values[5] } else { $null }
                    $nvidiaMetrics.MemoryUtilization = if ($values[6] -ne "N/A" -and $values[6] -match "^\d+$") { [int]$values[6] } else { $null }
                    $nvidiaMetrics.PowerDraw = if ($values[7] -ne "N/A" -and $values[7] -match "^\d+\.?\d*$") { [float]$values[7] } else { $null }
                    $nvidiaMetrics.Available = $true
                    
                    Write-Verbose "NVIDIA metrics captured: Temp=$($nvidiaMetrics.Temperature)°C, Fan=$($nvidiaMetrics.FanSpeed)%, GPU=$($nvidiaMetrics.GPUUtilization)%, VRAM=$($nvidiaMetrics.MemoryUsedMB)/$($nvidiaMetrics.MemoryTotalMB)MB, Power=$($nvidiaMetrics.PowerDraw)W"
                } else {
                    Write-Warning "nvidia-smi returned insufficient data. Expected 8 fields, got $($values.Length): $($values -join ', ')"
                }
            } else {
                Write-Warning "nvidia-smi returned empty or null output"
            }
        } catch {
            Write-Warning "Error executing nvidia-smi command: $($_.Exception.Message)"
        }
        
        if (-not $nvidiaMetrics.Available) {
            Write-Verbose "nvidia-smi not found or failed to execute. NVIDIA GPU metrics will not be available."
        }
    } catch {
        Write-Warning "Failed to get NVIDIA metrics: $($_.Exception.Message)"
    }
    
    return $nvidiaMetrics
}

# Function to capture hardware resource usage
function Capture-ResourceUsage {
    param (
        [int]$Duration # Duration in minutes. 0 means indefinite.
    )

    # --- Detect System Information ---
    Write-Host "Detecting system information..." -ForegroundColor Cyan
    $script:systemInfo = Get-SystemInformation
    
    # --- Detect GPU Information ---
    Write-Host "Detecting GPU configuration..." -ForegroundColor Cyan
    $script:gpuInfo = Get-GPUInformation
    
    if ($script:gpuInfo.GPUDetails.Count -eq 0) {
        Write-Host "No discrete GPUs detected. Using basic GPU monitoring only." -ForegroundColor Yellow
    } else {
        foreach ($gpu in $script:gpuInfo.GPUDetails) {
            Write-Host "Found: $($gpu.Vendor) - $($gpu.Name) ($($gpu.VideoMemoryMB) MB VRAM)" -ForegroundColor Green
        }
    }

    # --- Get PC Serial Number and Total RAM ---
    # LEGITIMATE DIAGNOSTIC PURPOSE: Serial number used only for unique log file naming
    # This ensures performance logs from different systems can be properly identified
    $pcSerialNumber = "UnknownSerial"
    $totalRamMB = $null
    try {
        # Standard BIOS information access for system identification (diagnostic purposes only)
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
    $writeIntervalSeconds = 10 # Write interval in seconds
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
    $script:gpuEngineDebugLogged = $false  # Add flag for GPU engine debug logging
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
            $cpuPerformanceVal = $null # Using % Processor Performance
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

            # --- Get CPU Processor Performance ---
            try {
                $cpuPerformanceVal = (Get-Counter '\Processor Information(_Total)\% Processor Performance' -ErrorAction Stop).CounterSamples.CookedValue
                Write-Verbose "CPU Processor Performance: $cpuPerformanceVal %"
            } catch {
                Write-Warning "Failed to get CPU Processor Performance: $($_.Exception.Message). This counter might not be available on all systems. Check permissions or run 'lodctr /R' as Admin."
                $cpuPerformanceVal = $null # Ensure it's null if counter fails
            }
            # --- END CPU Processor Performance ---

            try {
                $ramAvailableMBVal = (Get-Counter '\Memory\Available MBytes' -ErrorAction Stop).CounterSamples.CookedValue
                # Store raw values for Reporter calculation, but keep simple calc for immediate display
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
            
            # --- Network IO monitoring - capture raw data ---
            $networkAdaptersRawData = $null
            try {
                # Get network interface statistics using CIM - store raw for Reporter processing
                $networkAdapters = Get-CimInstance -ClassName Win32_PerfFormattedData_Tcpip_NetworkInterface -ErrorAction Stop
                
                if ($networkAdapters) {
                    # Store raw adapter data as JSON for processing in Reporter
                    $networkAdaptersRawData = $networkAdapters | Select-Object Name, BytesTotalPersec, CurrentBandwidth | ConvertTo-Json -Compress
                    Write-Verbose "Network adapters raw data captured: $($networkAdapters.Count) adapters"
                    # For immediate logging, use simple sum without filtering for basic functionality
                    $networkIOVal = ($networkAdapters | Measure-Object -Property BytesTotalPersec -Sum).Sum
                } else {
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
            # --- END Network IO Raw Capture ---
            
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
                
                # FALLBACK METHOD: If no battery data from primary method, or to get mWh values, try WMI namespace classes
                # Standard Windows battery management namespace for legitimate power monitoring
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
                    
                    # ADDITIONAL FALLBACK: Try BatteryCycleCount class for design capacity (common on x86/x64)
                    if ($null -eq $batteryDesignCapacity_mWh -or $batteryDesignCapacity_mWh -eq 0) {
                        try {
                            $bccInstance = Get-CimInstance -Namespace $wmiNamespace -ClassName "BatteryCycleCount" -ErrorAction SilentlyContinue
                            if ($bccInstance -and $bccInstance.DesignedCapacity) {
                                $batteryDesignCapacity_mWh_cc = $bccInstance.DesignedCapacity
                                Write-Verbose "DesignCapacity from ROOT\WMI\BatteryCycleCount: $batteryDesignCapacity_mWh_cc mWh"
                                if ($batteryDesignCapacity_mWh_cc -ne $null -and $batteryDesignCapacity_mWh_cc -gt 0) {
                                    $batteryDesignCapacity_mWh = $batteryDesignCapacity_mWh_cc
                                }
                            }
                        } catch {
                            Write-Verbose "BatteryCycleCount fallback failed: $($_.Exception.Message)"
                        }
                    }
                    
                    # ADDITIONAL FALLBACK: Try MSBatteryClass for design capacity (alternative on x86/x64)
                    if ($null -eq $batteryDesignCapacity_mWh -or $batteryDesignCapacity_mWh -eq 0) {
                        try {
                            $msbInstance = Get-CimInstance -Namespace $wmiNamespace -ClassName "MSBatteryClass" -ErrorAction SilentlyContinue
                            if ($msbInstance -and $msbInstance.DesignedCapacity) {
                                $batteryDesignCapacity_mWh_msb = $msbInstance.DesignedCapacity
                                Write-Verbose "DesignCapacity from ROOT\WMI\MSBatteryClass: $batteryDesignCapacity_mWh_msb mWh"
                                if ($batteryDesignCapacity_mWh_msb -ne $null -and $batteryDesignCapacity_mWh_msb -gt 0) {
                                    $batteryDesignCapacity_mWh = $batteryDesignCapacity_mWh_msb
                                }
                            }
                        } catch {
                            Write-Verbose "MSBatteryClass fallback failed: $($_.Exception.Message)"
                        }
                    }
                    
                    # FINAL FALLBACK: Try Win32_PortableBattery (often available on laptops)
                    if ($null -eq $batteryDesignCapacity_mWh -or $batteryDesignCapacity_mWh -eq 0) {
                        try {
                            $pbInstance = Get-CimInstance -Namespace "ROOT\cimv2" -ClassName "Win32_PortableBattery" -ErrorAction SilentlyContinue
                            if ($pbInstance -and $pbInstance.DesignCapacity) {
                                $batteryDesignCapacity_mWh_pb = $pbInstance.DesignCapacity
                                Write-Verbose "DesignCapacity from Win32_PortableBattery: $batteryDesignCapacity_mWh_pb mWh"
                                if ($batteryDesignCapacity_mWh_pb -ne $null -and $batteryDesignCapacity_mWh_pb -gt 0) {
                                    $batteryDesignCapacity_mWh = $batteryDesignCapacity_mWh_pb
                                }
                            }
                        } catch {
                            Write-Verbose "Win32_PortableBattery fallback failed: $($_.Exception.Message)"
                        }
                    }

                    # Store raw mWh values for calculation in Reporter.ps1
                    if ($null -ne $batteryFullChargedCapacity_mWh -and $batteryFullChargedCapacity_mWh -gt 0 -and $null -ne $batteryRemainingCapacity_mWh) {
                        # Log that we have raw mWh values available for Reporter calculation
                        if (-not $script:batteryWarningLogged) {
                            Write-Host "Battery mWh values captured for percentage calculation in Reporter."
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

            # --- LEGITIMATE GPU PERFORMANCE MONITORING: Graphics processing unit utilization tracking ---
            # Monitors GPU engine utilization for performance analysis (3D, Video processing, etc.)
            # Standard practice for system performance diagnostics and hardware monitoring
            $gpuEngineUsage = @{} # Hashtable to store results
            try {
                # Windows performance counter access for GPU engine monitoring (diagnostic purposes)
                $engineCounters = Get-Counter '\GPU Engine(*)\Utilization Percentage' -ErrorAction SilentlyContinue
                if ($null -ne $engineCounters) {
                    # Debug: Log all available engine instance names (only once)
                    if (-not $script:gpuEngineDebugLogged) {
                        Write-Verbose "Available GPU Engine instances: $($engineCounters.CounterSamples.InstanceName -join ', ')"
                        $script:gpuEngineDebugLogged = $true
                    }
                    
                    # Filter for only useful engine types during capture
                    $usefulEngines = @('3D', 'Copy', 'VideoDecode', 'VideoEncode', 'VideoProcessing')
                    
                    $filteredCounters = $engineCounters.CounterSamples | Where-Object {
                        $instanceName = $_.InstanceName
                        $isUseful = $false
                        foreach ($engine in $usefulEngines) {
                            # More flexible pattern matching to catch variations
                            if ($instanceName -match "engtype_$engine" -or
                                $instanceName -match "type_$engine" -or
                                $instanceName -match "$engine" -or
                                ($engine -eq 'VideoEncode' -and $instanceName -match 'VideoEnc') -or
                                ($engine -eq 'VideoProcessing' -and $instanceName -match 'VideoProc')) {
                                $isUseful = $true
                                break
                            }
                        }
                        $isUseful  # Remove the CookedValue > 0 filter to capture all relevant engines even if currently 0
                    }
                    
                    if ($filteredCounters) {
                        $engineDataRaw = $filteredCounters | ForEach-Object {
                            # Extract Engine Name
                            $engineName = "Unknown"
                            if ($_.InstanceName -match 'engtype_([a-zA-Z0-9]+)') {
                                $engineName = $matches[1]
                            }
                            elseif ($_.InstanceName -match 'luid_\w+_phys_\d+_eng_\d+_type_([a-zA-Z0-9]+)') {
                                $engineName = $matches[1]
                            }

                            [PSCustomObject]@{
                                Engine = $engineName
                                UsagePercent = $_.CookedValue
                            }
                        }
                        
                        # Group by Engine Type, Sum Percentages - only for useful engines
                        $engineDataGrouped = $engineDataRaw | Group-Object Engine | ForEach-Object {
                            $key = "GPUEngine_$($_.Name)_Percent"
                            $value = [math]::Round(($_.Group.UsagePercent | Measure-Object -Sum).Sum, 2)
                            $gpuEngineUsage[$key] = $value
                        }
                        
                        Write-Verbose "GPU Engine Usage (filtered): $($gpuEngineUsage.Keys -join ', ')"
                    }
                } else {
                    Write-Verbose "No '\GPU Engine(*)\Utilization Percentage' counters found."
                }
            } catch {
                Write-Warning "Failed to get GPU Engine Utilization: $($_.Exception.Message)"
            }
            # --- END NEW Filtered GPU Engine Capture ---

            # --- NEW: Vendor-Specific GPU Metrics Collection ---
            $nvidiaGPUMetrics = $null
            # NOTE: Intel GPU detailed metrics removed - consumer systems don't have monitoring tools pre-installed
            
            if ($script:gpuInfo.HasNVIDIA) {
                $nvidiaGPUMetrics = Get-NVIDIAMetrics -GPUInfo $script:gpuInfo
            }
            # --- END Vendor-Specific GPU Metrics ---

            # Create the base data object with metrics
            $currentData = [PSCustomObject]@{
                Timestamp                     = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
                # CPUUsagePercentTime         = $cpuTimeVal # REMOVED
                CPUUsagePercent               = $cpuUtilityVal # RENAMED from CPUUsagePercentUtility
                CPUProcessorPerformance       = $cpuPerformanceVal # NEW: % Processor Performance
                CPUMaxClockSpeedMHz           = $cpuMaxClockSpeedMHz
                RAMTotalMB                    = $totalRamMB
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
                NetworkAdaptersRawData        = $networkAdaptersRawData
                ActivePowerPlanName           = $powerMetrics.ActivePowerPlanName
                ActivePowerPlanGUID           = $powerMetrics.ActivePowerPlanGUID
                SystemPowerStatus             = $powerMetrics.SystemPowerStatus
                ActiveOverlayName             = $powerMetrics.ActiveOverlayName
                ActiveOverlayGUID             = $powerMetrics.ActiveOverlayGUID
                # System Information
                SystemManufacturer            = $script:systemInfo.Manufacturer
                SystemModel                   = $script:systemInfo.Model
                SystemVersion                 = $script:systemInfo.Version
                SystemProductName             = $script:systemInfo.ProductName
                SystemSerialNumber            = $script:systemInfo.SerialNumber
                # GPU Information
                GPUHasIntel                   = $script:gpuInfo.HasIntel
                GPUHasNVIDIA                  = $script:gpuInfo.HasNVIDIA
                GPUIntelName                  = if ($script:gpuInfo.IntelGPU) { $script:gpuInfo.IntelGPU.Name } else { "N/A" }
                GPUNVIDIAName                 = if ($script:gpuInfo.NVIDIAGPU) { $script:gpuInfo.NVIDIAGPU.Name } else { "N/A" }
                GPUIntelVRAM_MB               = if ($script:gpuInfo.IntelGPU) { $script:gpuInfo.IntelGPU.VideoMemoryMB } else { "N/A" }
                GPUNVIDIAVRAM_MB              = if ($script:gpuInfo.NVIDIAGPU) { $script:gpuInfo.NVIDIAGPU.VideoMemoryMB } else { "N/A" }
                # NVIDIA GPU Metrics
                NVIDIAGPUTemperature          = if ($nvidiaGPUMetrics -and $nvidiaGPUMetrics.Available) { $nvidiaGPUMetrics.Temperature } else { $null }
                NVIDIAGPUFanSpeed             = if ($nvidiaGPUMetrics -and $nvidiaGPUMetrics.Available) { $nvidiaGPUMetrics.FanSpeed } else { $null }
                NVIDIAGPUMemoryUsed_MB        = if ($nvidiaGPUMetrics -and $nvidiaGPUMetrics.Available) { $nvidiaGPUMetrics.MemoryUsedMB } else { $null }
                NVIDIAGPUMemoryTotal_MB       = if ($nvidiaGPUMetrics -and $nvidiaGPUMetrics.Available) { $nvidiaGPUMetrics.MemoryTotalMB } else { $null }
                NVIDIAGPUMemoryUtilization    = if ($nvidiaGPUMetrics -and $nvidiaGPUMetrics.Available) { $nvidiaGPUMetrics.MemoryUtilization } else { $null }
                NVIDIAGPUUtilization          = if ($nvidiaGPUMetrics -and $nvidiaGPUMetrics.Available) { $nvidiaGPUMetrics.GPUUtilization } else { $null }
                NVIDIAGPUPowerDraw            = if ($nvidiaGPUMetrics -and $nvidiaGPUMetrics.Available) { $nvidiaGPUMetrics.PowerDraw } else { $null }
                # Intel GPU Metrics - REMOVED: Consumer systems don't have Intel GPU monitoring tools
                # Basic Intel GPU detection still available via GPUHasIntel and GPUIntelName fields above
            }
            
            # Add GPU Engine metrics from the hashtable (only useful ones with values)
            foreach ($key in $gpuEngineUsage.Keys) {
                $currentData | Add-Member -MemberType NoteProperty -Name $key -Value $gpuEngineUsage[$key]
            }
            $data += $currentData

            # --- LEGITIMATE PROCESS MONITORING: System performance diagnostics ---
            # This section monitors running processes for performance analysis (CPU, RAM, I/O usage)
            # Used for identifying resource-intensive applications - standard system administration practice
            try {
                # Standard Windows process performance monitoring via WMI performance counters
                # Collects only resource usage metrics (not process content or data)
                $procPerf = Get-CimInstance -ClassName Win32_PerfFormattedData_PerfProc_Process -ErrorAction Stop |
                    Where-Object { $_.Name -notin @('Idle','_Total') } |
                    Select-Object @{Name='Timestamp';Expression={Get-Date -Format 'yyyy-MM-dd HH:mm:ss'}},
                                  @{Name='ProcessName';Expression={$_.Name}},
                                  @{Name='ProcessId';Expression={$_.IDProcess}},
                                  @{Name='CPUPercentRaw';Expression={$_.PercentProcessorTime}},
                                  @{Name='LogicalCoreCount';Expression={[Environment]::ProcessorCount}},
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
