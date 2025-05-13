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
                if ($entry -match '.+=(\d+(\.\d+)?)$') {
                    try {
                        $clockValue = [double]$matches[1]
                        $allCoreClockValues.Add($clockValue)
                    } catch {}
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
        Average = [math]::Round($stats.Average, 0)
        Minimum = [math]::Round($stats.Minimum, 0)
        Maximum = [math]::Round($stats.Maximum, 0)
        Available = $true
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

# Check for essential columns (use CPUUsagePercent, not CPUUsage)
$requiredColumns = @('Timestamp', 'CPUUsagePercent', 'RAMUsedMB')
$missingColumns = $requiredColumns | Where-Object { -not $data[0].PSObject.Properties.Name -contains $_ }
if ($missingColumns) {
    Write-Error "The CSV file '$csvFilePath' is missing required columns: $($missingColumns -join ', ')"
    exit
}

# Get Chart.js reference
function Get-ChartJsReference {
    $scriptDir = $PSScriptRoot
    $localChartJsPath = Join-Path $scriptDir "chart.js"
    if (Test-Path $localChartJsPath) {
        Write-Host "Embedding Chart.js directly in the HTML report"
        $chartJsContent = Get-Content -Path $localChartJsPath -Raw
        return "<script>$chartJsContent</script>"
    } else {
        Write-Error "Oops, you are missing some key files (chart.js). Report generation requires chart.js in the script directory."
        exit 1
    }
}
$chartJsRef = Get-ChartJsReference

# --- BEGIN Overall Statistics Summary Calculation ---
Write-Host "Calculating Overall Statistics Summary..."
$overallStatsSummaryHtml = ""
$statsTableRows = [System.Collections.Generic.List[string]]::new()

# Define metrics to summarize (use CPUUsagePercent)
$metricsToSummarize = @(
    @{ Name = 'CPUUsagePercent'; Label = 'CPU Usage'; Unit = '%' }
    @{ Name = 'RAMUsedMB'; Label = 'RAM Used'; Unit = 'MB' }
    @{ Name = 'DiskIOTransferSec'; Label = 'Disk I/O'; Unit = 'Transfers/sec' }
    @{ Name = 'NetworkIOBytesSec'; Label = 'Network I/O'; Unit = 'Bytes/sec' }
    @{ Name = 'CPUTemperatureC'; Label = 'CPU Temperature'; Unit = '°C' }
    @{ Name = 'CPUPowerW'; Label = 'CPU Power'; Unit = 'W' }
    @{ Name = 'CPUPlatformPowerW'; Label = 'CPU Platform Power'; Unit = 'W' }
)

foreach ($metricInfo in $metricsToSummarize) {
    if ($data[0].PSObject.Properties.Name -contains $metricInfo.Name) {
        $stats = Get-MetricStatistics -Data $data -PropertyName $metricInfo.Name -Label $metricInfo.Label -Unit $metricInfo.Unit
        if ($stats.Available) {
            $statsTableRows.Add("<tr><td>$($stats.Label)</td><td>$($stats.Average) $($stats.Unit)</td><td>$($stats.Minimum) $($stats.Unit)</td><td>$($stats.Maximum) $($stats.Unit)</td></tr>")
        } else {
            $statsTableRows.Add("<tr><td>$($metricInfo.Label)</td><td colspan='3'>N/A (column present but no valid data)</td></tr>")
        }
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
}

# Dynamically add GPU statistics
$gpuInfo = Get-GpuColumns -Data $data
foreach ($gpuType in @('iGPU', 'dGPU')) {
    $currentGpu = $gpuInfo[$gpuType]
    if ($currentGpu -and $currentGpu.Columns.Count -gt 0) {
        foreach ($metricKey in $currentGpu.Columns.Keys) {
            $columnName = $currentGpu.Columns[$metricKey]
            if ($columnName -and $data[0].PSObject.Properties.Name -contains $columnName) {
                $label = "$($currentGpu.Name) $($metricKey -replace '([A-Z])', ' $1' | ForEach-Object {$_.TrimStart()})"
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

# --- Power Statistics Section (simplified for WMI-only logger) ---
$powerStatisticsSectionHtml = ""
if ($data.Count -gt 0) {
    $lastRow = $data[-1]
    $powerStatus = $lastRow.SystemPowerStatus
    $activePlan = $lastRow.ActivePowerPlanName
    $activeOverlay = $lastRow.ActiveOverlayName
    $batteryPercentage = $lastRow.BatteryPercentage
    $batteryDesignCapacity = $lastRow.BatteryDesignCapacitymWh
    $batteryFullChargedCapacity = $lastRow.BatteryFullChargedCapacitymWh
    $batteryRemainingCapacity = $lastRow.BatteryRemainingCapacitymWh
    $batteryDischargeRate = $lastRow.BatteryDischargeRateW

    $powerStatisticsSectionHtml = @"
    <div class="stats-section">
        <h2>Power Statistics</h2>
        <ul>
            <li><strong>Current Power Status:</strong> $powerStatus</li>
            <li><strong>Active Power Plan:</strong> $activePlan</li>
            <li><strong>Active Overlay:</strong> $activeOverlay</li>
            <li><strong>Battery Percentage:</strong> $batteryPercentage</li>
            <li><strong>Battery Design Capacity (mWh):</strong> $batteryDesignCapacity</li>
            <li><strong>Battery Full Charged Capacity (mWh):</strong> $batteryFullChargedCapacity</li>
            <li><strong>Battery Remaining Capacity (mWh):</strong> $batteryRemainingCapacity</li>
            <li><strong>Battery Discharge Rate (W):</strong> $batteryDischargeRate</li>
        </ul>
    </div>
"@
}

# Pre-process the CSV data to JSON for JavaScript
$jsonData = $data | ConvertTo-Json -Depth 10 -Compress
$jsonDataForJs = $jsonData.Replace('\', '\\').Replace('"', '\"')

# Generate the HTML report (charts: CPU, RAM, Disk, Network, Temp, Brightness/Battery, GPU Engine)
$reportContent = @"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Hardware Resource Usage Report - $(Split-Path $csvFilePath -Leaf)</title>
    $chartJsRef
    <style>
        body { font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif; margin: 0; padding: 20px; background-color: #f5f5f5; color: #333; }
        .header { text-align: center; margin-bottom: 30px; color: #2c3e50; }
        .chart-container { position: relative; height: 400px; width: 90%; margin: 30px auto; background-color: white; border-radius: 10px; box-shadow: 0 4px 6px rgba(0, 0, 0, 0.1); padding: 20px; }
        .chart-title { text-align: center; font-size: 18px; font-weight: 600; margin-bottom: 15px; color: #2c3e50; }
        .chart-row { display: flex; flex-wrap: wrap; justify-content: space-between; }
        .chart-half { width: 48%; margin-bottom: 20px; }
        @media (max-width: 1200px) { .chart-half { width: 100%; } }
        .stats-section { background-color: #fff; padding: 20px; margin: 30px auto; border-radius: 10px; box-shadow: 0 4px 6px rgba(0,0,0,0.1); width: 90%; }
        .summary-stats table { width: 100%; border-collapse: collapse; margin-top: 15px; }
        .summary-stats th, .summary-stats td { border: 1px solid #ddd; padding: 10px; text-align: left; }
        .summary-stats th { background-color: #e9ecef; color: #495057; font-weight: 600; }
        .summary-stats tr:nth-child(even) { background-color: #f8f9fa; }
        .summary-stats td:nth-child(n+2) { text-align: right; }
        .stats-section h2 { text-align: center; color: #2c3e50; margin-top: 0; margin-bottom: 25px; }
    </style>
</head>
<body>
    <div class="header">
        <h1>Hardware Resource Usage Report</h1>
        <h2>Source File: $(Split-Path $csvFilePath -Leaf)</h2>
    </div>

    $overallStatsSummaryHtml
    $powerStatisticsSectionHtml

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
                <div class="chart-title">CPU Temperature (C)</div>
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
        <div class="chart-container" style="width: 90%; height: 500px;">
            <div class="chart-title">GPU Engine Utilization (%)</div>
            <canvas id="gpuEngineChart"></canvas>
        </div>
    </div>

    <script>
        // Parse the CSV data
        const csvData = [];
        const timestamps = [];
        const cpuUsage = [];
        const ramUsed = [];
        const ramAvailable = [];
        const diskIO = [];
        const networkIO = [];
        const cpuTemp = [];
        const screenBrightness = [];
        const batteryPercentage = [];
        const gpuEngines = {};
        const gpuEngineNames = [];

        function parseNumeric(value) {
            if (value === undefined || value === null || value === "") return null;
            const parsed = parseFloat(value);
            return isNaN(parsed) ? null : parsed;
        }

        const rawDataJson = "$jsonDataForJs";
        const rawData = JSON.parse(rawDataJson);

        if (rawData.length > 0) {
            const firstRow = rawData[0];
            const columnNames = Object.keys(firstRow);
            columnNames.forEach(colName => {
                if (colName.startsWith('GPUEngine_') && colName.endsWith('_Percent')) {
                    const engineName = colName.replace('GPUEngine_', '').replace('_Percent', '');
                    if (engineName && !gpuEngineNames.includes(engineName)) {
                        gpuEngineNames.push(engineName);
                    }
                }
            });
        }

        rawData.forEach((row, index) => {
            timestamps.push(row.Timestamp);
            cpuUsage.push(parseNumeric(row.CPUUsagePercent));
            ramUsed.push(parseNumeric(row.RAMUsedMB));
            ramAvailable.push(parseNumeric(row.RAMAvailableMB));
            diskIO.push(parseNumeric(row.DiskIOTransferSec));
            networkIO.push(parseNumeric(row.NetworkIOBytesSec));
            cpuTemp.push(parseNumeric(row.CPUTemperatureC));
            screenBrightness.push(parseNumeric(row.ScreenBrightness));
            batteryPercentage.push(parseNumeric(row.BatteryPercentage));
            gpuEngineNames.forEach(engineName => {
                const colName = 'GPUEngine_' + engineName + '_Percent';
                if (!gpuEngines[engineName]) {
                    gpuEngines[engineName] = Array(index).fill(null);
                }
                while (gpuEngines[engineName].length < index) {
                    gpuEngines[engineName].push(null);
                }
                if (row.hasOwnProperty(colName)) {
                    gpuEngines[engineName].push(parseNumeric(row[colName]));
                } else {
                    gpuEngines[engineName].push(null);
                }
            });
        });

        const totalRows = rawData.length;
        gpuEngineNames.forEach(engineName => {
            if (gpuEngines[engineName]) {
                while (gpuEngines[engineName].length < totalRows) {
                    gpuEngines[engineName].push(null);
                }
            }
        });

        const commonOptions = {
            responsive: true,
            maintainAspectRatio: false,
            plugins: {
                legend: { position: 'top' },
                tooltip: { mode: 'index', intersect: false }
            },
            scales: {
                x: { grid: { color: 'rgba(0, 0, 0, 0.1)' } },
                y: { beginAtZero: true, grid: { color: 'rgba(0, 0, 0, 0.1)' } }
            }
        };

        function createChart(canvasId, label, data, color, yAxisLabel, min = null, max = null) {
            const ctx = document.getElementById(canvasId).getContext('2d');
            const options = JSON.parse(JSON.stringify(commonOptions));
            options.scales.y.title = { display: true, text: yAxisLabel };
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

        function createMultiChart(canvasId, datasets, yAxisLabel, min = null, max = null) {
            const ctx = document.getElementById(canvasId).getContext('2d');
            const options = JSON.parse(JSON.stringify(commonOptions));
            options.scales.y.title = { display: true, text: yAxisLabel };
            if (min !== null) options.scales.y.min = min;
            if (max !== null) options.scales.y.max = max;
            return new Chart(ctx, {
                type: 'line',
                data: { labels: timestamps, datasets: datasets },
                options: options
            });
        }

        createChart('cpuChart', 'CPU Usage', cpuUsage, 'rgb(255, 99, 132)', 'Usage (%)', 0, 100);

        createMultiChart('ramChart', [
            { label: 'RAM Used', data: ramUsed, borderColor: 'rgb(54, 162, 235)', backgroundColor: 'rgba(54, 162, 235, 0.2)', borderWidth: 2, tension: 0.4, pointRadius: 0, pointHoverRadius: 5, pointHitRadius: 10 },
            { label: 'RAM Available', data: ramAvailable, borderColor: 'rgb(75, 192, 192)', backgroundColor: 'rgba(75, 192, 192, 0.2)', borderWidth: 2, tension: 0.4, pointRadius: 0, pointHoverRadius: 5, pointHitRadius: 10 }
        ], 'Memory (MB)');

        createChart('diskChart', 'Disk Transfers/sec', diskIO, 'rgb(255, 159, 64)', 'Transfers/sec');
        createChart('networkChart', 'Network Bytes/sec', networkIO, 'rgb(153, 102, 255)', 'Bytes/sec');
        createChart('tempChart', 'CPU Temperature', cpuTemp, 'rgb(255, 99, 132)', 'Temperature (°C)');
        createMultiChart('brightnessChart', [
            { label: 'Screen Brightness', data: screenBrightness, borderColor: 'rgb(255, 206, 86)', backgroundColor: 'rgba(255, 206, 86, 0.2)', borderWidth: 2, tension: 0.4, pointRadius: 0, pointHoverRadius: 5, pointHitRadius: 10 },
            { label: 'Battery', data: batteryPercentage, borderColor: 'rgb(75, 192, 192)', backgroundColor: 'rgba(75, 192, 192, 0.2)', borderWidth: 2, tension: 0.4, pointRadius: 0, pointHoverRadius: 5, pointHitRadius: 10 }
        ], 'Percentage (%)', 0, 100);

        const ctxGpuEngine = document.getElementById('gpuEngineChart').getContext('2d');
        if (gpuEngineNames.length > 0) {
            const engineDatasets = [];
            const engineColors = [
                { border: 'rgb(255, 99, 132)', background: 'rgba(255, 99, 132, 0.2)' }, { border: 'rgb(54, 162, 235)', background: 'rgba(54, 162, 235, 0.2)' },
                { border: 'rgb(255, 206, 86)', background: 'rgba(255, 206, 86, 0.2)' }, { border: 'rgb(75, 192, 192)', background: 'rgba(75, 192, 192, 0.2)' },
                { border: 'rgb(153, 102, 255)', background: 'rgba(153, 102, 255, 0.2)' }, { border: 'rgb(255, 159, 64)', background: 'rgba(255, 159, 64, 0.2)' }
            ];
            gpuEngineNames.forEach((engineName, i) => {
                const colorIndex = i % engineColors.length;
                engineDatasets.push({
                    label: engineName,
                    data: gpuEngines[engineName],
                    borderColor: engineColors[colorIndex].border,
                    backgroundColor: engineColors[colorIndex].background,
                    borderWidth: 2,
                    tension: 0.4,
                    pointRadius: 0,
                    pointHoverRadius: 4,
                    pointHitRadius: 10
                });
            });
            createMultiChart('gpuEngineChart', engineDatasets, 'Utilization (%)', 0, 100);
        } else {
            const gpuEngineCanvas = document.getElementById('gpuEngineChart');
            if (gpuEngineCanvas) {
                const ctx = gpuEngineCanvas.getContext('2d');
                ctx.font = '20px Arial';
                ctx.textAlign = 'center';
                ctx.fillStyle = '#666';
                ctx.fillText('No GPU Engine Utilization data found in CSV', gpuEngineCanvas.width / 2, gpuEngineCanvas.height / 2);
            }
        }
    </script>
</body>
</html>
"@

# Save the report to the HTML file
Write-Host "Saving report to $htmlOutputPath..."
$reportContent | Out-File -FilePath $htmlOutputPath -Encoding UTF8 -Force

Write-Host "Report generated successfully: $htmlOutputPath"
