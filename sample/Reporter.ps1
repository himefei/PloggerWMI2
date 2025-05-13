# Reporter.ps1
# Requires -Modules Microsoft.PowerShell.Utility

# Function to prompt for CSV file selection
function Select-CsvFile {
    param(
        [string]$InitialDirectory = $PSScriptRoot # Default to script's directory
    )
    Add-Type -AssemblyName System.Windows.Forms
    $openFileDialog = New-Object System.Windows.Forms.OpenFileDialog
    $openFileDialog.InitialDirectory = $InitialDirectory
    $openFileDialog.Filter = "CSV files (*.csv)|*.csv|All files (*.*)|*.*"
    $openFileDialog.Title = "Select Resource Usage CSV File"
    if ($openFileDialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        return $openFileDialog.FileName
    } else {
        Write-Warning "No file selected."
        return $null
    }
}

# --- Main Script ---

# Prompt user to select the CSV file
$csvFilePath = Select-CsvFile
if (-not $csvFilePath) {
    Write-Host "Operation cancelled."
    exit
}

Write-Host "Processing file: $csvFilePath"

# Check if the selected CSV file exists
if (-Not (Test-Path $csvFilePath -PathType Leaf)) {
    Write-Error "CSV file not found at path: $csvFilePath"
    exit
}

# Define the output HTML file path (same directory, same name + .html)
$htmlOutputPath = [System.IO.Path]::ChangeExtension($csvFilePath, ".html")

# Import the CSV data
try {
    $data = Import-Csv -Path $csvFilePath -ErrorAction Stop
} catch {
    Write-Error "Failed to import CSV data from '$csvFilePath'. Error: $($_.Exception.Message)"
    exit
}

if ($null -eq $data -or $data.Count -eq 0) {
    Write-Error "CSV file '$csvFilePath' is empty or could not be parsed correctly."
    exit
}

# Check for essential columns
$requiredColumns = @('Timestamp', 'CPUUsage', 'RAMUsedMB')
$missingColumns = $requiredColumns | Where-Object { -not $data[0].PSObject.Properties.Name -contains $_ }
if ($missingColumns) {
    Write-Error "The CSV file '$csvFilePath' is missing required columns: $($missingColumns -join ', ')"
    exit
}

# Function to check if Chart.js is available locally
function Get-ChartJsReference {
    $scriptDir = $PSScriptRoot
    $localChartJsPath = Join-Path $scriptDir "chart.js"
    
    # Check if local Chart.js file exists and embed it directly
    if (Test-Path $localChartJsPath) {
        Write-Host "Embedding Chart.js directly in the HTML report"
        $chartJsContent = Get-Content -Path $localChartJsPath -Raw
        return "<script>$chartJsContent</script>"
    } else {
        Write-Error "Oops, you are missing some key files (chart.js). Report generation requires chart.js in the script directory."
        exit 1
    }
}

# Function to calculate statistics for a given metric
function Get-MetricStatistics {
    param (
        [Parameter(Mandatory=$true)]
        [array]$Data,
        
        [Parameter(Mandatory=$true)]
        [string]$PropertyName,
        
        [string]$Label = $PropertyName,
        
        [string]$Unit = ""
    )
    
    # Extract numeric values, handling potential non-numeric or empty values
    $numericValues = $Data | ForEach-Object {
        $value = $_.$PropertyName
        if ([string]::IsNullOrWhiteSpace($value)) {
            $null
        } else {
            try {
                [double]$value
            } catch {
                $null # Ignore conversion errors for individual values
            }
        }
    } | Where-Object { $null -ne $_ }
    
    # If no valid numeric values, return N/A
    if ($null -eq $numericValues -or $numericValues.Count -eq 0) {
        return @{
            Label = $Label
            Unit = $Unit
            Average = "N/A"
            Minimum = "N/A"
            Maximum = "N/A"
            Available = $false
        }
    }
    
    # Calculate statistics
    $stats = $numericValues | Measure-Object -Average -Minimum -Maximum
    
    return @{
        Label = $Label
        Unit = $Unit
        Average = [math]::Round($stats.Average, 2)
        Minimum = [math]::Round($stats.Minimum, 2)
        Maximum = [math]::Round($stats.Maximum, 2)
        Available = $true
    }
}

# Function to find a column name based on keywords
function Get-DynamicColumnName {
    param(
        [Parameter(Mandatory=$true)]
        [array]$ColumnHeaders,
        [Parameter(Mandatory=$true)]
        [string]$PrimaryKeyword,
        [string]$SecondaryKeyword = $null
    )

    foreach ($header in $ColumnHeaders) {
        if ($header -ilike "*$PrimaryKeyword*") {
            if ($null -ne $SecondaryKeyword) {
                if ($header -ilike "*$SecondaryKeyword*") {
                    return $header
                }
            } else {
                return $header
            }
        }
    }
    return $null
}

# Function to identify GPU columns and extract GPU names
function Get-GpuColumns {
    param (
        [Parameter(Mandatory=$true)]
        [array]$Data
    )
    
    $igpuColumns = @{}
    $dgpuColumns = @{}
    $igpuName = "Intel GPU" # Default name
    $dgpuName = "NVIDIA GPU" # Default name
    
    if ($Data.Count -gt 0) {
        $firstRow = $Data[0]
        $columnNames = $firstRow.PSObject.Properties.Name
        
        # Find GPU column names and extract GPU names
        foreach ($colName in $columnNames) {
            # Match Intel GPU columns (iGPU)
            if ($colName -match 'GPU_Intel' -or ($colName -match '^GPU_' -and $colName -notmatch 'Nvidia')) {
                if ($colName -match '^GPU_(.+?)_(.+?)$') {
                    $extractedName = $matches[1] -replace '_', ' '
                    if ($extractedName -ne "Intel") { # Avoid just "Intel" if more specific name found
                        $igpuName = $extractedName
                    }
                    
                    if ($colName -match '3DLoadPercent$') {
                        $igpuColumns.load3d = $colName
                    } elseif ($colName -match 'VideoDecodePercent$') {
                        $igpuColumns.videoDecode = $colName
                    } elseif ($colName -match 'VideoProcessingPercent$') {
                        $igpuColumns.videoProcessing = $colName
                    } elseif ($colName -match 'PowerW$') {
                        $igpuColumns.power = $colName
                    } elseif ($colName -match 'TemperatureC$') {
                        $igpuColumns.temperature = $colName
                    } elseif ($colName -match 'CoreLoadPercent$') {
                        $igpuColumns.coreLoad = $colName
                    }
                }
            }
            
            # Match NVIDIA GPU columns (dGPU)
            if ($colName -match 'GPU_Nvidia') {
                if ($colName -match '^GPU_(.+?)_(.+?)$') {
                    $extractedName = $matches[1] -replace '_', ' '
                     if ($extractedName -ne "Nvidia") { # Avoid just "Nvidia" if more specific name found
                        $dgpuName = $extractedName
                    }

                    if ($colName -match 'CoreLoadPercent$') {
                        $dgpuColumns.coreLoad = $colName
                    } elseif ($colName -match '3DLoadPercent$') {
                        $dgpuColumns.load3d = $colName
                    } elseif ($colName -match 'VideoDecodePercent$') {
                        $dgpuColumns.videoDecode = $colName
                    } elseif ($colName -match 'VideoProcessingPercent$') {
                        $dgpuColumns.videoProcessing = $colName
                    } elseif ($colName -match 'PowerW$') {
                        $dgpuColumns.power = $colName
                    } elseif ($colName -match 'TemperatureC$') {
                        $dgpuColumns.temperature = $colName
                    }
                }
            }
        }
    }
    
    return @{
        iGPU = @{
            Name = $igpuName
            Columns = $igpuColumns
        }
        dGPU = @{
            Name = $dgpuName
            Columns = $dgpuColumns
        }
    }
}
# Function to calculate statistics for all CPU core clocks
function Get-AllCoreClockStatistics {
    param (
        [Parameter(Mandatory=$true)]
        [array]$Data,

        [string]$ClockColumnName = "CPUCoreClocks", # Default column name

        [string]$Label = "CPU Clock Speed (All Cores)",
        [string]$Unit = "MHz"
    )

    $allCoreClockValues = [System.Collections.Generic.List[double]]::new()

    # Check if the column exists in the first data row (assuming consistent CSV structure)
    if (-not ($Data.Count -gt 0 -and $Data[0].PSObject.Properties.Name -contains $ClockColumnName)) {
        # Write-Warning "Column '$ClockColumnName' not found in the data." # Optional: for debugging
        return @{
            Label = $Label
            Unit = $Unit
            Average = "N/A"
            Minimum = "N/A"
            Maximum = "N/A"
            Available = $false
        }
    }

    foreach ($row in $Data) {
        $clockDataString = $row.$ClockColumnName
        if (-not [string]::IsNullOrWhiteSpace($clockDataString)) {
            $coreEntries = $clockDataString -split ';'
            foreach ($entry in $coreEntries) {
                if ($entry -match '.+=(\d+(\.\d+)?)$') { # Match the numeric value after '='
                    try {
                        $clockValue = [double]$matches[1]
                        $allCoreClockValues.Add($clockValue)
                    } catch {
                        # Silently ignore conversion errors for individual clock values within a row
                        # Write-Warning "Could not parse clock value from '$entry' in row: $row" # Optional: for debugging
                    }
                }
            }
        }
    }

    if ($allCoreClockValues.Count -eq 0) {
        return @{
            Label = $Label
            Unit = $Unit
            Average = "N/A"
            Minimum = "N/A"
            Maximum = "N/A"
            Available = $false
        }
    }

    $stats = $allCoreClockValues | Measure-Object -Average -Minimum -Maximum

    return @{
        Label = $Label
        Unit = $Unit
        Average = [math]::Round($stats.Average, 0) # Round to 0 decimal places for MHz
        Minimum = [math]::Round($stats.Minimum, 0)
        Maximum = [math]::Round($stats.Maximum, 0)
        Available = $true
    }
}

# --- BEGIN Overall Statistics Summary Calculation ---
Write-Host "Calculating Overall Statistics Summary..."
$overallStatsSummaryHtml = ""
$statsTableRows = [System.Collections.Generic.List[string]]::new()

# Define metrics to summarize
$metricsToSummarize = @(
    @{ Name = 'CPUUsage'; Label = 'CPU Usage'; Unit = '%' }
    @{ Name = 'RAMUsedMB'; Label = 'RAM Used'; Unit = 'MB' }
    @{ Name = 'DiskIOTransferSec'; Label = 'Disk I/O'; Unit = 'Transfers/sec' }
    @{ Name = 'NetworkIOBytesSec'; Label = 'Network I/O'; Unit = 'Bytes/sec' }
    @{ Name = 'CPUTemperatureC'; Label = 'CPU Temperature'; Unit = '°C' }
    @{ Name = 'CPUPowerW'; Label = 'CPU Power'; Unit = 'W' }
    @{ Name = 'CPUPlatformPowerW'; Label = 'CPU Platform Power'; Unit = 'W' }
    # BatteryDegradationPerc and Battery Voltage will be moved to Power Statistics
)

foreach ($metricInfo in $metricsToSummarize) {
    if ($data[0].PSObject.Properties.Name -contains $metricInfo.Name) {
        $stats = Get-MetricStatistics -Data $data -PropertyName $metricInfo.Name -Label $metricInfo.Label -Unit $metricInfo.Unit
        if ($stats.Available) {
            $statsTableRows.Add("<tr><td>$($stats.Label)</td><td>$($stats.Average) $($stats.Unit)</td><td>$($stats.Minimum) $($stats.Unit)</td><td>$($stats.Maximum) $($stats.Unit)</td></tr>")
        } else {
            $statsTableRows.Add("<tr><td>$($metricInfo.Label)</td><td colspan='3'>N/A (column present but no valid data)</td></tr>")
        }
    } else {
        # $statsTableRows.Add("<tr><td>$($metricInfo.Label)</td><td colspan='3'>N/A (column not found)</td></tr>") # Optional: report missing columns
    }
}

# Add CPU Core Clock Statistics
if ($data.Count -gt 0 -and $data[0].PSObject.Properties.Name -contains "CPUCoreClocks") {
    $cpuClockStats = Get-AllCoreClockStatistics -Data $data
    if ($cpuClockStats.Available) {
        $statsTableRows.Add("<tr><td>$($cpuClockStats.Label)</td><td>$($cpuClockStats.Average) $($cpuClockStats.Unit)</td><td>$($cpuClockStats.Minimum) $($cpuClockStats.Unit)</td><td>$($cpuClockStats.Maximum) $($cpuClockStats.Unit)</td></tr>")
    } else {
        $statsTableRows.Add("<tr><td>$($cpuClockStats.Label)</td><td colspan='3'>N/A (column present but no valid data or parsing issues)</td></tr>")
    }
} else {
    # Optional: Add a row indicating the CPUCoreClocks column was not found if you want to explicitly state its absence.
    # For now, if the column isn't there, it simply won't be added to the summary.
    # $statsTableRows.Add("<tr><td>CPU Clock Speed (All Cores)</td><td colspan='3'>N/A (CPUCoreClocks column not found)</td></tr>")
}
# Dynamically add GPU statistics
$gpuInfo = Get-GpuColumns -Data $data
foreach ($gpuType in @('iGPU', 'dGPU')) {
    $currentGpu = $gpuInfo[$gpuType]
    if ($currentGpu -and $currentGpu.Columns.Count -gt 0) {
        foreach ($metricKey in $currentGpu.Columns.Keys) {
            $columnName = $currentGpu.Columns[$metricKey]
            if ($columnName -and $data[0].PSObject.Properties.Name -contains $columnName) {
                $label = "$($currentGpu.Name) $($metricKey -replace '([A-Z])', ' $1' | ForEach-Object {$_.TrimStart()})" # Add space before caps
                $unit = ""
                if ($metricKey -like '*Power*') { $unit = 'W' }
                elseif ($metricKey -like '*Temperature*') { $unit = '°C' }
                elseif ($metricKey -like '*Load*' -or $metricKey -like '*Decode*' -or $metricKey -like '*Processing*') { $unit = '%' }
                
                $stats = Get-MetricStatistics -Data $data -PropertyName $columnName -Label $label -Unit $unit
                 if ($stats.Available) {
                    $statsTableRows.Add("<tr><td>$($stats.Label)</td><td>$($stats.Average) $($stats.Unit)</td><td>$($stats.Minimum) $($stats.Unit)</td><td>$($stats.Maximum) $($stats.Unit)</td></tr>")
                } else {
                    $statsTableRows.Add("<tr><td>$label</td><td colspan='3'>N/A (column present but no valid data)</td></tr>")
                }
            }
        }
    }
}

# Battery Voltage and Degradation are now handled in the Power Statistics section

if ($statsTableRows.Count -gt 0) {
    $overallStatsSummaryHtml = @"
<div class="stats-section summary-stats">
    <h2>Overall Statistics Summary</h2>
    <table>
        <thead>
            <tr>
                <th>Metric</th>
                <th>Average</th>
                <th>Minimum</th>
                <th>Maximum</th>
            </tr>
        </thead>
        <tbody>
            $($statsTableRows -join "`n            ")
        </tbody>
    </table>
</div>
"@
} else {
    $overallStatsSummaryHtml = @"
<div class="stats-section summary-stats">
    <h2>Overall Statistics Summary</h2>
    <p>No summary statistics could be calculated.</p>
</div>
"@
}
Write-Host "Overall Statistics Summary Calculation Complete."
# --- END Overall Statistics Summary Calculation ---

# Get Chart.js reference
$chartJsRef = Get-ChartJsReference

# --- BEGIN Power Statistics Calculation ---
Write-Host "Calculating Power Statistics..."
$powerStatisticsSectionHtml = "" # Initialize a single variable for the whole section

if ($data.Count -gt 0) {
    $powerEvents = [System.Collections.Generic.List[string]]::new()
    $powerModeEvents = [System.Collections.Generic.List[string]]::new()
    $previousPowerStatus = $null
    $previousPowerMode = $null
    $totalLogDurationSeconds = 0
    $acPowerDurationSeconds = 0
    $dcPowerConsumptionSumWatts = 0.0
    $dcPowerSampleCount = 0
    $firstTimestampObj = $null
    $lastTimestampObj = $null
    $previousTimestampObj = $null
    $gpuPowerColumns = @()

    # Identify GPU Power Columns
    $columnNames = $data[0].PSObject.Properties.Name
    $gpuPowerColumns = $columnNames | Where-Object { $_ -like 'GPU_*_PowerW' }

    foreach ($row in $data) {
        try {
            $currentTimestampObj = [datetime]::ParseExact($row.Timestamp, 'yyyy-MM-dd HH:mm:ss', $null)
        } catch {
            Write-Warning "Could not parse timestamp: $($row.Timestamp). Skipping row for duration calculations."
            continue
        }

        if ($null -eq $firstTimestampObj) {
            $firstTimestampObj = $currentTimestampObj
        }
        $lastTimestampObj = $currentTimestampObj
        $timeDiffSeconds = 0
        if ($null -ne $previousTimestampObj) {
            $timeDiffSeconds = ($currentTimestampObj - $previousTimestampObj).TotalSeconds
        }

        # Power Status & Events
        $currentPowerStatus = $row.PowerStatus
        if ($null -ne $previousPowerStatus -and $currentPowerStatus -ne $previousPowerStatus) {
            $powerEvents.Add("<li>Switched to '$currentPowerStatus' at $($row.Timestamp)</li>")
        }
        if ($currentPowerStatus -eq "AC Power" -and $timeDiffSeconds -gt 0) {
            $acPowerDurationSeconds += $timeDiffSeconds
        }
        $previousPowerStatus = $currentPowerStatus

        # Power Mode & Events
        $currentPowerMode = $row.ActiveOverlayName
        if ($null -ne $previousPowerMode -and $currentPowerMode -ne $previousPowerMode) {
            $powerModeEvents.Add("<li>Power mode changed to '$currentPowerMode' at $($row.Timestamp)</li>")
        }
        $previousPowerMode = $currentPowerMode

        # REMOVED: Battery Life Estimate Data based on average power draw
        # The new calculation will happen after the loop using the last data point
        $previousTimestampObj = $currentTimestampObj
    }

    if ($null -ne $firstTimestampObj -and $null -ne $lastTimestampObj) {
        $totalLogDurationSeconds = ($lastTimestampObj - $firstTimestampObj).TotalSeconds
    }

    if ($totalLogDurationSeconds -gt 0) {
        $onAcPercentage = [math]::Round(($acPowerDurationSeconds / $totalLogDurationSeconds) * 100, 1)
    }

    # --- NEW: Calculate Estimated Runtime based on last recorded values ---
    $_batteryEstimatesHtml = "<li>Estimated runtime: N/A (Required data missing or insufficient log duration)</li>" # Default
    if ($data.Count -gt 0) {
        $lastRow = $data[-1]
        $lastPowerStatus = $lastRow.PowerStatus
        $lastRemainingCapacitymWh = $null
        $lastDischargeRateW = $null

        # Check if required columns exist and try to parse values
        if ($lastRow.PSObject.Properties.Name -contains 'BatteryRemainingCapacitymWh') {
            try { $lastRemainingCapacitymWh = [double]$lastRow.BatteryRemainingCapacitymWh } catch {}
        }
        if ($lastRow.PSObject.Properties.Name -contains 'BatteryDischargeRateW') {
            try { $lastDischargeRateW = [double]$lastRow.BatteryDischargeRateW } catch {}
        }

        if ($lastPowerStatus -eq "DC (Battery) Power") {
            if (($null -ne $lastRemainingCapacitymWh) -and ($null -ne $lastDischargeRateW) -and ($lastDischargeRateW -gt 0)) {
                try {
                    # Convert remaining capacity from mWh to Wh by dividing by 1000
                    $remainingWh = $lastRemainingCapacitymWh / 1000
                    $estimatedRuntimeHours = [math]::Round(($remainingWh / $lastDischargeRateW), 1)
                    $_batteryEstimatesHtml = "<li>Estimated runtime: approx. $($estimatedRuntimeHours) hours (Remaining: $($lastRemainingCapacitymWh) mWh / Rate: $($lastDischargeRateW) W)</li>"
                } catch {
                    $_batteryEstimatesHtml = "<li>Estimated runtime: Error during calculation.</li>"
                }
            } elseif (($null -ne $lastDischargeRateW) -and ($lastDischargeRateW -le 0)) {
                $_batteryEstimatesHtml = "<li>Estimated runtime: N/A (System on Battery, but not discharging or charging rate is zero)</li>"
            } else {
                $_batteryEstimatesHtml = "<li>Estimated runtime: N/A (Required capacity or discharge rate data missing for DC state)</li>"
            }
        } elseif ($lastPowerStatus -eq "AC Power") {
            $_batteryEstimatesHtml = "<li>Estimated runtime: N/A (System on AC Power)</li>"
        } else {
            $_batteryEstimatesHtml = "<li>Estimated runtime: N/A (Unknown power state)</li>"
        }
    }
    # --- END NEW Runtime Calculation ---
    
    # Calculate Battery Degradation and Voltage for Power Statistics
    $_batteryDegradationHtml = "<li>Battery Degradation: N/A (column 'BatteryDegradationPerc' not found or no data)</li>"
    if ($data[0].PSObject.Properties.Name -contains 'BatteryDegradationPerc') {
        $degradationStats = Get-MetricStatistics -Data $data -PropertyName 'BatteryDegradationPerc' -Label 'Battery Degradation' -Unit '%'
        if ($degradationStats.Available) {
            # Display the last known battery degradation value
            $lastDegradationRaw = $data[-1].BatteryDegradationPerc
            if (-not [string]::IsNullOrWhiteSpace($lastDegradationRaw)) {
                try {
                    $lastDegradationNumeric = [double]$lastDegradationRaw
                    $_batteryDegradationHtml = "<li>Battery Degradation: $([math]::Round($lastDegradationNumeric, 2))%</li>"
                } catch {
                    $_batteryDegradationHtml = "<li>Battery Degradation: N/A (last value invalid format)</li>"
                }
            } else {
                $_batteryDegradationHtml = "<li>Battery Degradation: N/A (last value empty)</li>"
            }
        }
    }

    $_batteryVoltageHtml = "<li>Battery Voltage: N/A (column not found or no data)</li>"
    $firstRowHeaders = $data[0].PSObject.Properties.Name
    $batteryVoltageColumn = Get-DynamicColumnName -ColumnHeaders $firstRowHeaders -PrimaryKeyword "Voltage" -SecondaryKeyword "Battery"
    if ($batteryVoltageColumn) {
        $voltageStats = Get-MetricStatistics -Data $data -PropertyName $batteryVoltageColumn -Label "Battery Voltage" -Unit "V"
        if ($voltageStats.Available) {
            $_batteryVoltageHtml = "<li>Battery Voltage: $($voltageStats.Average)$($voltageStats.Unit) (Average)</li>"
        } else {
            $_batteryVoltageHtml = "<li>Battery Voltage: N/A (column '$batteryVoltageColumn' present but no valid data)</li>"
        }
    }

    # Local variables for constructing the HTML for this section
    $_currentPowerStatusVal = $data[-1].PowerStatus
    $_currentPowerStatusDisplay = if ($_currentPowerStatusVal -eq "AC Power") { "System is plugged in." } elseif ($_currentPowerStatusVal -eq "DC (Battery) Power") { "System is running on battery." } else { "Status: $_currentPowerStatusVal" }
    $_currentPowerModeDisplay = $data[0].ActiveOverlayName # Use first row for starting mode

    $_powerEventsHtml = if ($powerEvents.Count -gt 0) { $powerEvents -join "" } else { "<li>No changes in AC/DC power status during logging.</li>" }
    $_powerModeEventsHtml = if ($powerModeEvents.Count -gt 0) { $powerModeEvents -join "" } else { "<li>Power mode remained '$_currentPowerModeDisplay' throughout the logging session.</li>" }
    
    # $_batteryEstimatesHtml is now calculated above (lines 476-511)

    # --- NEW: Add Battery Capacity Metrics ---
    $_batteryDesignCapacityHtml = "<li>Designed Capacity: N/A</li>"
    $_batteryFullChargedCapacityHtml = "<li>Full Charged Capacity: N/A</li>"
    $_batteryRemainingCapacityHtml = "<li>Remaining Capacity: N/A</li>"
    if ($data.Count -gt 0) {
        $lastRow = $data[-1]
        if ($lastRow.PSObject.Properties.Name -contains 'BatteryDesignCapacitymWh' -and -not [string]::IsNullOrWhiteSpace($lastRow.BatteryDesignCapacitymWh)) {
            $_batteryDesignCapacityHtml = "<li>Designed Capacity: $($lastRow.BatteryDesignCapacitymWh) mWh</li>"
        }
        if ($lastRow.PSObject.Properties.Name -contains 'BatteryFullChargedCapacitymWh' -and -not [string]::IsNullOrWhiteSpace($lastRow.BatteryFullChargedCapacitymWh)) {
            $_batteryFullChargedCapacityHtml = "<li>Full Charged Capacity: $($lastRow.BatteryFullChargedCapacitymWh) mWh</li>"
        }
        if ($lastRow.PSObject.Properties.Name -contains 'BatteryRemainingCapacitymWh' -and -not [string]::IsNullOrWhiteSpace($lastRow.BatteryRemainingCapacitymWh)) {
            $_batteryRemainingCapacityHtml = "<li>Remaining Capacity: $($lastRow.BatteryRemainingCapacitymWh) mWh</li>"
        }
    }
    # --- END NEW Capacity Metrics ---

    # Construct the entire HTML section into one variable
    $powerStatisticsSectionHtml = @"
    <div class="stats-section">
        <h2>Power Statistics</h2>
        <div class="stats-subsection">
            <h3>AC/DC Power Status</h3>
            <p><strong>Current Status:</strong> $_currentPowerStatusDisplay</p>
            <p><strong>Time on AC Power:</strong> $onAcPercentage %</p>
            <h4>Power Events:</h4>
            <ul>
                $_powerEventsHtml
            </ul>
        </div>
        <div class="stats-subsection">
            <h3>Power Mode</h3>
            <p><strong>Starting Mode:</strong> $_currentPowerModeDisplay</p>
            <h4>Power Mode Events:</h4>
            <ul>
                $_powerModeEventsHtml
            </ul>
        </div>
        <div class="stats-subsection">
            <h3>Estimated Battery Runtime</h3>
            <p><em>(Calculated based on last reported remaining capacity and discharge rate)</em></p>
            <ul>
                $_batteryEstimatesHtml
            </ul>
        </div>
        <div class="stats-subsection">
           <h3>Battery Health & Status</h3>
           <ul>
               $_batteryDesignCapacityHtml
               $_batteryFullChargedCapacityHtml
               $_batteryRemainingCapacityHtml
               $_batteryDegradationHtml
               $_batteryVoltageHtml
           </ul>
       </div>
    </div>
"@
} else { # if data.count -eq 0
    $powerStatisticsSectionHtml = @"
    <div class="stats-section">
        <h2>Power Statistics</h2>
        <p>No data available to calculate power statistics.</p>
    </div>
"@
}

Write-Host "Power Statistics Calculation Complete."
# --- END Power Statistics Calculation ---

# Pre-process the CSV data to JSON for JavaScript
$jsonData = $data | ConvertTo-Json -Depth 10 -Compress
# Escape double quotes and backslashes for JavaScript string literal
$jsonDataForJs = $jsonData.Replace('\', '\\').Replace('"', '\"')

# Generate the HTML report
$reportContent = @"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Hardware Resource Usage Report - $(Split-Path $csvFilePath -Leaf)</title>
    $chartJsRef
    <style>
        body { /* General body styling */
            font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
            margin: 0;
            padding: 20px;
            background-color: #f5f5f5;
            color: #333;
        }
        .header {
            text-align: center;
            margin-bottom: 30px;
            color: #2c3e50;
        }
        .chart-container {
            position: relative;
            height: 400px;
            width: 90%;
            margin: 30px auto;
            background-color: white;
            border-radius: 10px;
            box-shadow: 0 4px 6px rgba(0, 0, 0, 0.1);
            padding: 20px;
        }
        .chart-title {
            text-align: center;
            font-size: 18px;
            font-weight: 600;
            margin-bottom: 15px;
            color: #2c3e50;
        }
        .chart-row {
            display: flex;
            flex-wrap: wrap;
            justify-content: space-between;
        }
        .chart-half {
            width: 48%;
            margin-bottom: 20px;
        }
        @media (max-width: 1200px) {
            .chart-half {
                width: 100%;
            }
        }
        .stats-section { /* General styling for all stat sections */
            background-color: #fff;
            padding: 20px;
            margin: 30px auto; /* Increased top/bottom margin */
            border-radius: 10px;
            box-shadow: 0 4px 6px rgba(0,0,0,0.1);
            width: 90%;
        }
        .summary-stats table { /* Specific for summary stats table */
            width: 100%;
            border-collapse: collapse;
            margin-top: 15px;
        }
        .summary-stats th, .summary-stats td {
            border: 1px solid #ddd;
            padding: 10px;
            text-align: left;
        }
        .summary-stats th {
            background-color: #e9ecef;
            color: #495057;
            font-weight: 600;
        }
        .summary-stats tr:nth-child(even) {
            background-color: #f8f9fa;
        }
        .summary-stats td:nth-child(n+2) {
            text-align: right;
        }
        /* General h2 styling for stat sections */
        .stats-section h2 {
            text-align: center;
            color: #2c3e50;
            margin-top: 0; /* Adjusted margin */
            margin-bottom: 25px; /* Increased margin */
        }
        .stats-subsection {
            margin-bottom: 25px; /* Increased margin */
            padding-bottom: 20px; /* Increased padding */
            border-bottom: 1px solid #eee;
        }
        .stats-subsection:last-child {
            border-bottom: none;
            margin-bottom: 0;
            padding-bottom: 0;
        }
        .stats-subsection h3 {
            color: #34495e;
            margin-top: 0; /* Adjusted margin */
            margin-bottom: 12px; /* Increased margin */
            font-size: 1.1em; /* Slightly larger */
        }
        .stats-subsection h4 {
            color: #7f8c8d;
            margin-top: 18px; /* Increased margin */
            margin-bottom: 8px; /* Increased margin */
            font-size: 0.95em; /* Slightly larger */
        }
        .stats-subsection p {
            margin: 8px 0; /* Increased margin */
            line-height: 1.6;
        }
        .stats-subsection ul {
            list-style-type: disc;
            margin-left: 25px; /* Increased margin */
            padding-left: 0;
        }
        .stats-subsection li {
            margin-bottom: 6px; /* Increased margin */
        }
    </style>
</head>
<body>
    <div class="header">
        <h1>Hardware Resource Usage Report</h1>
        <h2>Source File: $(Split-Path $csvFilePath -Leaf)</h2>
    </div>

    <!-- Overall Statistics Summary Section -->
    $overallStatsSummaryHtml
    <!-- End Overall Statistics Summary Section -->

    <!-- Power Statistics Section (interpolated as a single block) -->
    $powerStatisticsSectionHtml
    <!-- End Power Statistics Section -->

    <div class="chart-row">
        <div class="chart-half">
            <div class="chart-container">
                <div class="chart-title">CPU Usage (%)</div>
                <canvas id="cpuChart"></canvas>
            </div>
        </div>
        <div class="chart-half">
            <div class="chart-container">
                <div class="chart-title">RAM Usage (MB)</div>
                <canvas id="ramChart"></canvas>
            </div>
        </div>
    </div>

    <div class="chart-row">
        <div class="chart-half">
            <div class="chart-container">
                <div class="chart-title">Disk I/O (Transfers/sec)</div>
                <canvas id="diskChart"></canvas>
            </div>
        </div>
        <div class="chart-half">
            <div class="chart-container">
                <div class="chart-title">Network I/O (Bytes/sec)</div>
                <canvas id="networkChart"></canvas>
            </div>
        </div>
    </div>

    <div class="chart-row">
        <div class="chart-half">
            <div class="chart-container">
                <div class="chart-title">CPU and GPU Temperature (°C)</div>
                <canvas id="tempChart"></canvas>
            </div>
        </div>
        <div class="chart-half">
            <div class="chart-container">
                <div class="chart-title">Screen Brightness & Battery Percentage (%)</div>
                <canvas id="brightnessChart"></canvas>
            </div>
        </div>
    </div>

    <div class="chart-row">
        <div class="chart-half">
            <div class="chart-container">
                <div id="igpuChartTitle" class="chart-title">iGPU Usage (%)</div>
                <canvas id="igpuUsageChart"></canvas>
            </div>
        </div>
        <div class="chart-half">
            <div class="chart-container">
                <div id="dgpuChartTitle" class="chart-title">dGPU Usage (%)</div>
                <canvas id="dgpuUsageChart"></canvas>
            </div>
        </div>
    </div>

    <div class="chart-row">
        <div class="chart-container" style="width: 90%; height: 500px;">
            <div class="chart-title">Combined Power Usage (W)</div>
            <canvas id="combinedPowerChart"></canvas>
        </div>
    </div>

    <div class="chart-row">
        <div class="chart-container" style="width: 90%; height: 500px;">
            <div class="chart-title">CPU Core Clock Speeds (MHz)</div>
            <canvas id="cpuCoreClockChart"></canvas>
        </div>
    </div>

    <div class="chart-row">
        <div class="chart-container" style="width: 90%; height: 500px;">
            <div class="chart-title">Battery Charge/Discharge Rate</div>
            <canvas id="batteryChargeRateChart"></canvas>
        </div>
    </div>

    <!-- No additional chart rows needed -->

    <script>
        // Parse the CSV data
        const csvData = [];
        
        // Extract data from the CSV
        const timestamps = [];
        const cpuUsage = [];
        const ramUsed = [];
        const ramAvailable = [];
        const diskIO = [];
        const networkIO = [];
        const cpuTemp = [];
        const cpuPower = [];
        const platformPower = [];  // Renamed from cpuPlatformPower
        const screenBrightness = [];
        const batteryPercentage = [];

        // Battery Charge/Discharge Data
        const batteryChargeCurrentA = [];
        const batteryChargeRateW = [];
        const powerStatusValues = [];
        
        // GPU data arrays
        const igpuPower = [];
        const igpuVideoDecode = [];
        const igpuVideoProcessing = [];
        const igpu3dLoad = [];
        
        const dgpuPower = [];
        const dgpuCoreLoad = [];
        const dgpuVideoDecode = [];
        const dgpuVideoProcessing = [];
        const dgpu3dLoad = [];
        const dgpuTemperature = [];
        
        // GPU names
        let igpuName = "Intel GPU";
        let dgpuName = "NVIDIA GPU";
        
        // CPU Core Clock data
        const cpuCores = {};
        const cpuCoreNames = [];
        
        // Function to safely parse numeric values
        function parseNumeric(value) {
            if (value === undefined || value === null || value === "") {
                return null;
            }
            const parsed = parseFloat(value);
            return isNaN(parsed) ? null : parsed;
        }
        
        // Process the CSV data
        const rawDataJson = "$jsonDataForJs";
        const rawData = JSON.parse(rawDataJson);
        
        // GPU column identification
        let igpuColumns = {};
        let dgpuColumns = {};
        
        // Identify GPU column names from the first row if available
        if (rawData.length > 0) {
            const firstRow = rawData[0];
            const columnNames = Object.keys(firstRow);
            
            // Find GPU column names and extract GPU names
            columnNames.forEach(colName => {
                // Match Intel GPU columns (iGPU)
                if (colName.includes('GPU_Intel') || (colName.startsWith('GPU_') && !colName.includes('Nvidia'))) {
                    // Extract GPU name from column name
                    const nameParts = colName.split('_');
                    if (nameParts.length >= 3) {
                        // Extract name parts between GPU_ and _MetricName
                        const nameEndIndex = colName.lastIndexOf('_');
                        const nameStartIndex = colName.indexOf('_') + 1;
                        const fullName = colName.substring(nameStartIndex, nameEndIndex);
                        igpuName = fullName.replace(/_/g, ' ');
                        
                        // Identify metric type
                        if (colName.endsWith('3DLoadPercent')) {
                            igpuColumns.load3d = colName;
                        } else if (colName.endsWith('VideoDecodePercent')) {
                            igpuColumns.videoDecode = colName;
                        } else if (colName.endsWith('VideoProcessingPercent')) {
                            igpuColumns.videoProcessing = colName;
                        } else if (colName.endsWith('PowerW')) {
                            igpuColumns.power = colName;
                        }
                    }
                }
                
                // Match NVIDIA GPU columns (dGPU)
                if (colName.includes('GPU_Nvidia')) {
                    // Extract GPU name from column name
                    const nameParts = colName.split('_');
                    if (nameParts.length >= 3) {
                        // Extract name parts between GPU_ and _MetricName
                        const nameEndIndex = colName.lastIndexOf('_');
                        const nameStartIndex = colName.indexOf('_') + 1;
                        const fullName = colName.substring(nameStartIndex, nameEndIndex);
                        dgpuName = fullName.replace(/_/g, ' ');
                        
                        // Identify metric type
                        if (colName.endsWith('CoreLoadPercent')) {
                            dgpuColumns.coreLoad = colName;
                        } else if (colName.endsWith('3DLoadPercent')) {
                            dgpuColumns.load3d = colName;
                        } else if (colName.endsWith('VideoDecodePercent')) {
                            dgpuColumns.videoDecode = colName;
                        } else if (colName.endsWith('VideoProcessingPercent')) {
                            dgpuColumns.videoProcessing = colName;
                        } else if (colName.endsWith('PowerW')) {
                            dgpuColumns.power = colName;
                        } else if (colName.endsWith('TemperatureC')) {
                            dgpuColumns.temperature = colName;
                        }
                    }
                }
            });
            
            // Update chart titles with GPU names
            setTimeout(() => {
                if (document.getElementById('igpuChartTitle')) {
                    document.getElementById('igpuChartTitle').textContent = igpuName + " Usage (%)";
                }
                if (document.getElementById('dgpuChartTitle')) {
                    document.getElementById('dgpuChartTitle').textContent = dgpuName + " Usage (%)";
                }
            }, 0);
            
            console.log("iGPU columns:", igpuColumns);
            console.log("dGPU columns:", dgpuColumns);
        }
        
        // Process each row of data
        rawData.forEach((row, index) => {
            timestamps.push(row.Timestamp);
            cpuUsage.push(parseNumeric(row.CPUUsage));
            ramUsed.push(parseNumeric(row.RAMUsedMB));
            ramAvailable.push(parseNumeric(row.RAMAvailableMB));
            diskIO.push(parseNumeric(row.DiskIOTransferSec));
            networkIO.push(parseNumeric(row.NetworkIOBytesSec));
            cpuTemp.push(parseNumeric(row.CPUTemperatureC));
            cpuPower.push(parseNumeric(row.CPUPowerW));
            platformPower.push(parseNumeric(row.CPUPlatformPowerW));
            screenBrightness.push(parseNumeric(row.ScreenBrightness));
            batteryPercentage.push(parseNumeric(row.BatteryPercentage));
            
            // Extract Battery Charge/Discharge Data
            const bCurrentA = parseNumeric(row.BatteryChargeCurrentA);
            const bRateW = parseNumeric(row.BatteryChargeRateW);
            const pStatus = row.PowerStatus;
            batteryChargeCurrentA.push(bCurrentA);
            batteryChargeRateW.push(bRateW);
            powerStatusValues.push(pStatus);
            // if (index < 2 || index > rawData.length - 3) { // Log first/last few rows for brevity
            //    console.log(`Row ${index}: BatteryChargeCurrentA=${bCurrentA}, BatteryChargeRateW=${bRateW}, PowerStatus=${pStatus}`);
            // }

            // Process iGPU data using identified column names
            if (igpuColumns) {
                igpuPower.push(parseNumeric(row[igpuColumns.power]));
                igpuVideoDecode.push(parseNumeric(row[igpuColumns.videoDecode]));
                igpuVideoProcessing.push(parseNumeric(row[igpuColumns.videoProcessing]));
                igpu3dLoad.push(parseNumeric(row[igpuColumns.load3d]));
            }
            
            // Process dGPU data using identified column names
            if (dgpuColumns) {
                dgpuPower.push(parseNumeric(row[dgpuColumns.power]));
                dgpuCoreLoad.push(parseNumeric(row[dgpuColumns.coreLoad]));
                dgpuVideoDecode.push(parseNumeric(row[dgpuColumns.videoDecode]));
                dgpuVideoProcessing.push(parseNumeric(row[dgpuColumns.videoProcessing]));
                dgpu3dLoad.push(parseNumeric(row[dgpuColumns.load3d]));
                dgpuTemperature.push(parseNumeric(row[dgpuColumns.temperature]));
            }
            
            // Process CPU Core Clock data
            if (row.CPUCoreClocks) {
                // Split the string by semicolons to get individual core data
                const coreEntries = row.CPUCoreClocks.split(';');
                
                // Process each core entry
                coreEntries.forEach(entry => {
                    if (entry) {
                        // Split by equals sign to get core name and clock speed
                        const parts = entry.split('=');
                        if (parts.length === 2) {
                            const coreName = parts[0].trim();
                            const clockSpeed = parseNumeric(parts[1]);
                            
                            // Add core name to the list of core names if it's not already there
                            if (!cpuCoreNames.includes(coreName) && coreName) {
                                cpuCoreNames.push(coreName);
                            }
                            
                            // Initialize array for this core if it doesn't exist
                            if (!cpuCores[coreName]) {
                                cpuCores[coreName] = Array(index).fill(null);
                            }
                            
                            // Make sure all core arrays have the same length
                            while (cpuCores[coreName].length < index) {
                                cpuCores[coreName].push(null);
                            }
                            
                            // Add the clock speed to the array
                            cpuCores[coreName].push(clockSpeed);
                        }
                    }
                });
            }
            
            // Make sure all core arrays have the same length
            cpuCoreNames.forEach(coreName => {
                if (cpuCores[coreName]) {
                    while (cpuCores[coreName].length <= index) {
                        cpuCores[coreName].push(null);
                    }
                }
            });
        });

        // Common chart options
        const commonOptions = {
            responsive: true,
            maintainAspectRatio: false,
            plugins: {
                legend: {
                    position: 'top',
                },
                tooltip: {
                    mode: 'index',
                    intersect: false,
                }
            },
            scales: {
                x: {
                    grid: {
                        color: 'rgba(0, 0, 0, 0.1)',
                    }
                },
                y: {
                    beginAtZero: true,
                    grid: {
                        color: 'rgba(0, 0, 0, 0.1)',
                    }
                }
            }
        };

        // Helper function to create a chart
        function createChart(canvasId, label, data, color, yAxisLabel, min = null, max = null) {
            const ctx = document.getElementById(canvasId).getContext('2d');
            
            // Deep clone the common options
            const options = JSON.parse(JSON.stringify(commonOptions));
            
            // Set y-axis label
            options.scales.y.title = {
                display: true,
                text: yAxisLabel
            };
            
            // Set min/max if provided
            if (min !== null) options.scales.y.min = min;
            if (max !== null) options.scales.y.max = max;
            
            return new Chart(ctx, {
                type: 'line',
                data: {
                    labels: timestamps,
                    datasets: [{
                        label: label,
                        data: data,
                        borderColor: color,
                        backgroundColor: color.replace(')', ', 0.2)').replace('rgb', 'rgba'),
                        borderWidth: 2,
                        tension: 0.4,
                        pointRadius: 0,
                        pointHoverRadius: 5,
                        pointHitRadius: 10
                    }]
                },
                options: options
            });
        }

        // Helper function to create a multi-dataset chart
        function createMultiChart(canvasId, datasets, yAxisLabel, min = null, max = null, scalesOverride = null) {
            const ctx = document.getElementById(canvasId).getContext('2d');
            
            // Deep clone the common options
            let options = JSON.parse(JSON.stringify(commonOptions)); // Use let for modification
            
            // Set default y-axis label only if not overridden by a more specific scales configuration
            if (!scalesOverride || (!scalesOverride.y && !Object.keys(scalesOverride).some(key => key.startsWith('y') && key !== 'y'))) {
                if (!options.scales.y) options.scales.y = {}; // Ensure y scale object exists
                options.scales.y.title = {
                    display: true,
                    text: yAxisLabel
                };
            }
            
            // Set min/max if provided and not overridden by scalesOverride for the primary 'y' axis
            if (min !== null) {
                if (options.scales.y && (scalesOverride ? scalesOverride.y?.min === undefined : true)) {
                     options.scales.y.min = min;
                }
            }
            if (max !== null) {
                if (options.scales.y && (scalesOverride ? scalesOverride.y?.max === undefined : true)) {
                    options.scales.y.max = max;
                }
            }

            // Merge scalesOverride if provided
            if (scalesOverride) {
                // If scalesOverride defines specific y-axes (e.g., yAmps, yWatts) and a default 'y' exists from commonOptions,
                // and scalesOverride does NOT provide its own 'y', then remove the default 'y' to prevent conflicts.
                if (Object.keys(scalesOverride).some(key => key.startsWith('y') && key !== 'y') && options.scales.y && !scalesOverride.y) {
                   delete options.scales.y;
                }
                // Merge all provided scales. This allows overriding 'x', 'y', or adding new axes like 'yAmps'.
                options.scales = {...options.scales, ...scalesOverride };
            }
            
            return new Chart(ctx, {
                type: 'line',
                data: {
                    labels: timestamps,
                    datasets: datasets
                },
                options: options
            });
        }

        // Create CPU Usage Chart
        createChart('cpuChart', 'CPU Usage', cpuUsage, 'rgb(255, 99, 132)', 'Usage (%)', 0, 100);

        // Create RAM Chart with multiple datasets
        createMultiChart('ramChart', [
            {
                label: 'RAM Used',
                data: ramUsed,
                borderColor: 'rgb(54, 162, 235)',
                backgroundColor: 'rgba(54, 162, 235, 0.2)',
                borderWidth: 2,
                tension: 0.4,
                pointRadius: 0,
                pointHoverRadius: 5,
                pointHitRadius: 10
            },
            {
                label: 'RAM Available',
                data: ramAvailable,
                borderColor: 'rgb(75, 192, 192)',
                backgroundColor: 'rgba(75, 192, 192, 0.2)',
                borderWidth: 2,
                tension: 0.4,
                pointRadius: 0,
                pointHoverRadius: 5,
                pointHitRadius: 10
            }
        ], 'Memory (MB)');

        // Create Disk I/O Chart
        createChart('diskChart', 'Disk Transfers/sec', diskIO, 'rgb(255, 159, 64)', 'Transfers/sec');

        // Create Network I/O Chart
        createChart('networkChart', 'Network Bytes/sec', networkIO, 'rgb(153, 102, 255)', 'Bytes/sec');

        // Create CPU and GPU Temperature Chart
        createMultiChart('tempChart', [
            {
                label: 'CPU Temperature',
                data: cpuTemp,
                borderColor: 'rgb(255, 99, 132)',
                backgroundColor: 'rgba(255, 99, 132, 0.2)',
                borderWidth: 2,
                tension: 0.4,
                pointRadius: 0,
                pointHoverRadius: 5,
                pointHitRadius: 10
            },
            {
                label: "dGPU Temperature (" + dgpuName + ")",
                data: dgpuTemperature,
                borderColor: 'rgb(153, 102, 255)',
                backgroundColor: 'rgba(153, 102, 255, 0.2)',
                borderWidth: 2,
                tension: 0.4,
                pointRadius: 0,
                pointHoverRadius: 5,
                pointHitRadius: 10
            }
        ], 'Temperature (°C)');

        // Create Combined Power Chart with multiple datasets
        createMultiChart('combinedPowerChart', [
            {
                label: 'CPU Power',
                data: cpuPower,
                borderColor: 'rgb(54, 162, 235)',
                backgroundColor: 'rgba(54, 162, 235, 0.2)',
                borderWidth: 2,
                tension: 0.4,
                pointRadius: 0,
                pointHoverRadius: 5,
                pointHitRadius: 10
            },
            {
                label: "iGPU Power (" + igpuName + ")",
                data: igpuPower,
                borderColor: 'rgb(255, 99, 132)',
                backgroundColor: 'rgba(255, 99, 132, 0.2)',
                borderWidth: 2,
                tension: 0.4,
                pointRadius: 0,
                pointHoverRadius: 5,
                pointHitRadius: 10
            },
            {
                label: "dGPU Power (" + dgpuName + ")",
                data: dgpuPower,
                borderColor: 'rgb(153, 102, 255)',
                backgroundColor: 'rgba(153, 102, 255, 0.2)',
                borderWidth: 2,
                tension: 0.4,
                pointRadius: 0,
                pointHoverRadius: 5,
                pointHitRadius: 10
            },
            {
                label: 'Platform Power',
                data: platformPower,
                borderColor: 'rgb(75, 192, 192)',
                backgroundColor: 'rgba(75, 192, 192, 0.2)',
                borderWidth: 2,
                tension: 0.4,
                pointRadius: 0,
                pointHoverRadius: 5,
                pointHitRadius: 10
            }
        ], 'Power (W)');

        // Create iGPU Usage Chart with multiple datasets
        createMultiChart('igpuUsageChart', [
            {
                label: 'Video Decode',
                data: igpuVideoDecode,
                borderColor: 'rgb(54, 162, 235)',
                backgroundColor: 'rgba(54, 162, 235, 0.2)',
                borderWidth: 2,
                tension: 0.4,
                pointRadius: 0,
                pointHoverRadius: 5,
                pointHitRadius: 10
            },
            {
                label: 'Video Processing',
                data: igpuVideoProcessing,
                borderColor: 'rgb(255, 206, 86)',
                backgroundColor: 'rgba(255, 206, 86, 0.2)',
                borderWidth: 2,
                tension: 0.4,
                pointRadius: 0,
                pointHoverRadius: 5,
                pointHitRadius: 10
            },
            {
                label: '3D Load',
                data: igpu3dLoad,
                borderColor: 'rgb(153, 102, 255)',
                backgroundColor: 'rgba(153, 102, 255, 0.2)',
                borderWidth: 2,
                tension: 0.4,
                pointRadius: 0,
                pointHoverRadius: 5,
                pointHitRadius: 10
            }
        ], 'Load (%)', 0, 100);
        
        // Create dGPU Usage Chart with multiple datasets
        createMultiChart('dgpuUsageChart', [
            {
                label: 'Core Load',
                data: dgpuCoreLoad,
                borderColor: 'rgb(255, 99, 132)',
                backgroundColor: 'rgba(255, 99, 132, 0.2)',
                borderWidth: 2,
                tension: 0.4,
                pointRadius: 0,
                pointHoverRadius: 5,
                pointHitRadius: 10
            },
            {
                label: 'Video Decode',
                data: dgpuVideoDecode,
                borderColor: 'rgb(54, 162, 235)',
                backgroundColor: 'rgba(54, 162, 235, 0.2)',
                borderWidth: 2,
                tension: 0.4,
                pointRadius: 0,
                pointHoverRadius: 5,
                pointHitRadius: 10
            },
            {
                label: 'Video Processing',
                data: dgpuVideoProcessing,
                borderColor: 'rgb(255, 206, 86)',
                backgroundColor: 'rgba(255, 206, 86, 0.2)',
                borderWidth: 2,
                tension: 0.4,
                pointRadius: 0,
                pointHoverRadius: 5,
                pointHitRadius: 10
            },
            {
                label: '3D Load',
                data: dgpu3dLoad,
                borderColor: 'rgb(153, 102, 255)',
                backgroundColor: 'rgba(153, 102, 255, 0.2)',
                borderWidth: 2,
                tension: 0.4,
                pointRadius: 0,
                pointHoverRadius: 5,
                pointHitRadius: 10
            }
        ], 'Load (%)', 0, 100);

        // Create Screen Brightness & Battery Percentage Chart
        createMultiChart('brightnessChart', [
            {
                label: 'Screen Brightness',
                data: screenBrightness,
                borderColor: 'rgb(255, 206, 86)', // Yellow/Orange
                backgroundColor: 'rgba(255, 206, 86, 0.2)',
                borderWidth: 2,
                tension: 0.4,
                pointRadius: 0,
                pointHoverRadius: 5,
                pointHitRadius: 10
            },
            {
                label: 'Battery',
                data: batteryPercentage,
                borderColor: 'rgb(75, 192, 192)', // Green/Teal
                backgroundColor: 'rgba(75, 192, 192, 0.2)',
                borderWidth: 2,
                tension: 0.4,
                pointRadius: 0,
                pointHoverRadius: 5,
                pointHitRadius: 10
            }
        ], 'Percentage (%)', 0, 100);

        // Create CPU Core Clock Speed Chart
        const ctxCpuCoreClocks = document.getElementById('cpuCoreClockChart').getContext('2d');
        
        // Check if we have CPU core clock data
        if (cpuCoreNames.length > 0) {
            // Create an array of colors for different cores
            const coreColors = [
                { border: 'rgb(255, 99, 132)', background: 'rgba(255, 99, 132, 0.2)' },  // Red
                { border: 'rgb(54, 162, 235)', background: 'rgba(54, 162, 235, 0.2)' },  // Blue
                { border: 'rgb(255, 206, 86)', background: 'rgba(255, 206, 86, 0.2)' },  // Yellow
                { border: 'rgb(75, 192, 192)', background: 'rgba(75, 192, 192, 0.2)' },  // Green
                { border: 'rgb(153, 102, 255)', background: 'rgba(153, 102, 255, 0.2)' }, // Purple
                { border: 'rgb(255, 159, 64)', background: 'rgba(255, 159, 64, 0.2)' },   // Orange
                { border: 'rgb(201, 203, 207)', background: 'rgba(201, 203, 207, 0.2)' }, // Grey
                { border: 'rgb(0, 128, 0)', background: 'rgba(0, 128, 0, 0.2)' },         // Dark Green
                { border: 'rgb(139, 69, 19)', background: 'rgba(139, 69, 19, 0.2)' },     // Brown
                { border: 'rgb(0, 191, 255)', background: 'rgba(0, 191, 255, 0.2)' }      // Deep Sky Blue
            ];
            
            // Create datasets for each core
            const datasets = [];
            cpuCoreNames.forEach((coreName, i) => {
                const colorIndex = i % coreColors.length;
                datasets.push({
                    label: coreName,
                    data: cpuCores[coreName],
                    borderColor: coreColors[colorIndex].border,
                    backgroundColor: coreColors[colorIndex].background,
                    borderWidth: 2,
                    tension: 0.4,
                    pointRadius: 0,
                    pointHoverRadius: 4,
                    pointHitRadius: 10
                });
            });
            
            new Chart(ctxCpuCoreClocks, {
                type: 'line',
                data: {
                    labels: timestamps,
                    datasets: datasets
                },
                options: {
                    responsive: true,
                    maintainAspectRatio: false,
                    plugins: {
                        legend: {
                            position: 'right',
                            labels: {
                                boxWidth: 12,
                                font: {
                                    size: 10
                                }
                            }
                        },
                        tooltip: {
                            mode: 'index',
                            intersect: false
                        }
                    },
                    scales: {
                        y: {
                            beginAtZero: true,
                            title: {
                                display: true,
                                text: 'Clock Speed (MHz)'
                            }
                        },
                        x: {
                            display: true,
                            title: {
                                display: true,
                                text: 'Time'
                            }
                        }
                    }
                }
            });
        } else {
            // Display a message if no CPU core clock data is found
            const cpuCoreClockCanvas = document.getElementById('cpuCoreClockChart');
            if (cpuCoreClockCanvas) {
                const ctx = cpuCoreClockCanvas.getContext('2d');
                ctx.font = '20px Arial';
                ctx.textAlign = 'center';
                ctx.fillStyle = '#666';
                ctx.fillText('No CPU Core Clock data found in CSV', cpuCoreClockCanvas.width / 2, cpuCoreClockCanvas.height / 2);
            }
        }
        console.log("Initial Battery Data: ", { batteryChargeCurrentA, batteryChargeRateW, powerStatusValues });

        // Create Battery Charge/Discharge Rate Chart
        const chargingCurrentData = [];
        const dischargingCurrentData = [];
        const chargingRateData = [];
        const dischargingRateData = [];

        for (let i = 0; i < timestamps.length; i++) {
            const status = powerStatusValues[i];
            const currentA = batteryChargeCurrentA[i];
            const rateW = batteryChargeRateW[i];

            if (status === "AC Power") {
                chargingCurrentData.push(currentA);
                dischargingCurrentData.push(null);
                chargingRateData.push(rateW);
                dischargingRateData.push(null);
            } else if (status === "DC (Battery) Power") {
                chargingCurrentData.push(null);
                dischargingCurrentData.push(currentA); // Assuming positive CSV values mean discharge
                chargingRateData.push(null);
                dischargingRateData.push(rateW);     // Assuming positive CSV values mean discharge
            } else {
                chargingCurrentData.push(null);
                dischargingCurrentData.push(null);
                chargingRateData.push(null);
                dischargingRateData.push(null);
            }
        }
        console.log("Processed Battery Chart Data: ", { chargingCurrentData, dischargingCurrentData, chargingRateData, dischargingRateData });
        console.log("Attempting to create batteryChargeRateChart...");

        createMultiChart('batteryChargeRateChart', [
            {
                label: 'Charging Current (A)',
                data: chargingCurrentData,
                borderColor: 'rgb(75, 192, 75)',
                backgroundColor: 'rgba(75, 192, 75, 0.2)',
                yAxisID: 'yAmps',
                borderWidth: 2, tension: 0.4, pointRadius: 0, pointHoverRadius: 5, pointHitRadius: 10
            },
            {
                label: 'Discharging Current (A)',
                data: dischargingCurrentData,
                borderColor: 'rgb(255, 159, 64)',
                backgroundColor: 'rgba(255, 159, 64, 0.2)',
                yAxisID: 'yAmps',
                borderWidth: 2, tension: 0.4, pointRadius: 0, pointHoverRadius: 5, pointHitRadius: 10
            },
            {
                label: 'Charging Rate (W)',
                data: chargingRateData,
                borderColor: 'rgb(54, 162, 235)',
                backgroundColor: 'rgba(54, 162, 235, 0.2)',
                yAxisID: 'yWatts',
                borderWidth: 2, tension: 0.4, pointRadius: 0, pointHoverRadius: 5, pointHitRadius: 10
            },
            {
                label: 'Discharging Rate (W)',
                data: dischargingRateData,
                borderColor: 'rgb(255, 99, 132)',
                backgroundColor: 'rgba(255, 99, 132, 0.2)',
                yAxisID: 'yWatts',
                borderWidth: 2, tension: 0.4, pointRadius: 0, pointHoverRadius: 5, pointHitRadius: 10
            }
        ],
        'Rate / Current', // This yAxisLabel is mostly a fallback if scalesOverride isn't used or doesn't define titles
        null, null,       // min, max (let Chart.js auto-scale or rely on scalesOverride)
        { // scalesOverride for dual Y-axes
            yAmps: {
                type: 'linear',
                display: true,
                position: 'left',
                title: { display: true, text: 'Current (A)' },
                grid: {
                    color: 'rgba(0, 0, 0, 0.1)', // Keep grid consistent
                }
            },
            yWatts: {
                type: 'linear',
                display: true,
                position: 'right',
                title: { display: true, text: 'Rate (W)' },
                grid: {
                    drawOnChartArea: false, // Only draw grid for the first Y axis (yAmps)
                    color: 'rgba(0, 0, 0, 0.1)',
                }
            },
            // Ensure x-axis common grid settings are preserved if not part of commonOptions.scales.x
            x: { // Re-iterate x-axis options if they were not part of the commonOptions.scales object directly
                grid: {
                    color: 'rgba(0, 0, 0, 0.1)',
                }
            }
        });
        console.log("batteryChargeRateChart creation call complete. Check for errors above if chart is missing.");
   </script>
</body>
</html>
"@

# Save the report to the HTML file
Write-Host "Saving report to $htmlOutputPath..."
$reportContent | Out-File -FilePath $htmlOutputPath -Encoding UTF8 -Force

Write-Host "Report generated successfully: $htmlOutputPath"
# --- Summary Report Generation is now integrated into the main report ---
# The code block for generating a separate _summary.html file (previously here) has been removed.
# All summary information is now part of the primary HTML report.