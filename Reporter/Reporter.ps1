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

# Function to calculate statistics for a given metric (from Reporter_Summary.ps1)
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
                $null
            }
        }
    } | Where-Object { $null -ne $_ }
    
    # If no valid numeric values, return null
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

# Function to identify GPU columns and extract GPU names (from Reporter_Summary.ps1)
function Get-GpuColumns {
    param (
        [Parameter(Mandatory=$true)]
        [array]$Data
    )
    
    $igpuColumns = @{}
    $dgpuColumns = @{}
    $igpuName = "Intel GPU"
    $dgpuName = "NVIDIA GPU"
    
    if ($Data.Count -gt 0) {
        $firstRow = $Data[0]
        $columnNames = $firstRow.PSObject.Properties.Name
        
        # Find GPU column names and extract GPU names
        foreach ($colName in $columnNames) {
            # Match Intel GPU columns (iGPU)
            if ($colName -match 'GPU_Intel' -or ($colName -match '^GPU_' -and $colName -notmatch 'Nvidia')) {
                # Extract GPU name from column name
                if ($colName -match '^GPU_(.+?)_(.+?)$') {
                    $fullName = $matches[1]
                    $igpuName = $fullName -replace '_', ' '
                    
                    # Identify metric type
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
                # Extract GPU name from column name
                if ($colName -match '^GPU_(.+?)_(.+?)$') {
                    $fullName = $matches[1]
                    $dgpuName = $fullName -replace '_', ' '
                    
                    # Identify metric type
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
$requiredColumns = @('Timestamp', 'CPUUsagePercent', 'RAMUsedMB') # Updated CPUUsage to CPUUsagePercent
$missingColumns = $requiredColumns | Where-Object { -not $data[0].PSObject.Properties.Name -contains $_ }
if ($missingColumns) {
    Write-Error "The CSV file '$csvFilePath' is missing required columns: $($missingColumns -join ', ')"
    exit
}

# Function to check if Chart.js is available locally
function Get-ChartJsReference {
    $scriptDir = $PSScriptRoot
    $localChartJsPath = Join-Path $scriptDir "chart.js"
# --- Summary Report Generation (Merged from Reporter_Summary.ps1) ---

# Define the output HTML file path for the summary report
$fileNameWithoutExt = [System.IO.Path]::GetFileNameWithoutExtension($csvFilePath)
$directory = [System.IO.Path]::GetDirectoryName($csvFilePath)
$summaryHtmlOutputPath = [System.IO.Path]::Combine($directory, "$fileNameWithoutExt" + "_summary.html")

# Identify GPU columns for summary
$gpuInfoSummary = Get-GpuColumns -Data $data

# Calculate statistics for each metric for summary
$summaryMetrics = @()
$summaryMetrics += Get-MetricStatistics -Data $data -PropertyName "CPUUsagePercent" -Label "CPU Usage" -Unit "%"
$summaryMetrics += Get-MetricStatistics -Data $data -PropertyName "RAMUsedMB" -Label "RAM Used" -Unit "MB"
$summaryMetrics += Get-MetricStatistics -Data $data -PropertyName "RAMAvailableMB" -Label "RAM Available" -Unit "MB"
$summaryMetrics += Get-MetricStatistics -Data $data -PropertyName "DiskIOTransferSec" -Label "Disk I/O" -Unit "transfers/sec"
$summaryMetrics += Get-MetricStatistics -Data $data -PropertyName "NetworkIOBytesSec" -Label "Network I/O" -Unit "bytes/sec"
$summaryMetrics += Get-MetricStatistics -Data $data -PropertyName "CPUTemperatureC" -Label "CPU Temperature (for reference only)" -Unit "°C"
$summaryMetrics += Get-MetricStatistics -Data $data -PropertyName "ScreenBrightness" -Label "Screen Brightness" -Unit "%"
$summaryMetrics += Get-MetricStatistics -Data $data -PropertyName "CPUPowerW" -Label "CPU Power" -Unit "W"
$summaryMetrics += Get-MetricStatistics -Data $data -PropertyName "CPUPlatformPowerW" -Label "Platform Power" -Unit "W"

# iGPU Metrics for summary (if available)
if ($gpuInfoSummary.iGPU.Columns.Count -gt 0) {
    $igpuNameSummary = $gpuInfoSummary.iGPU.Name
    if ($gpuInfoSummary.iGPU.Columns.temperature) {
        $summaryMetrics += Get-MetricStatistics -Data $data -PropertyName $gpuInfoSummary.iGPU.Columns.temperature -Label "$igpuNameSummary Temperature (for reference only)" -Unit "°C"
    }
    if ($gpuInfoSummary.iGPU.Columns.power) {
        $summaryMetrics += Get-MetricStatistics -Data $data -PropertyName $gpuInfoSummary.iGPU.Columns.power -Label "$igpuNameSummary Power" -Unit "W"
    }
    if ($gpuInfoSummary.iGPU.Columns.coreLoad) {
        $summaryMetrics += Get-MetricStatistics -Data $data -PropertyName $gpuInfoSummary.iGPU.Columns.coreLoad -Label "$igpuNameSummary Core Load" -Unit "%"
    }
    if ($gpuInfoSummary.iGPU.Columns.load3d) {
        $summaryMetrics += Get-MetricStatistics -Data $data -PropertyName $gpuInfoSummary.iGPU.Columns.load3d -Label "$igpuNameSummary 3D Load" -Unit "%"
    }
    if ($gpuInfoSummary.iGPU.Columns.videoDecode) {
        $summaryMetrics += Get-MetricStatistics -Data $data -PropertyName $gpuInfoSummary.iGPU.Columns.videoDecode -Label "$igpuNameSummary Video Decode" -Unit "%"
    }
    if ($gpuInfoSummary.iGPU.Columns.videoProcessing) {
        $summaryMetrics += Get-MetricStatistics -Data $data -PropertyName $gpuInfoSummary.iGPU.Columns.videoProcessing -Label "$igpuNameSummary Video Processing" -Unit "%"
    }
}

# dGPU Metrics for summary (if available)
if ($gpuInfoSummary.dGPU.Columns.Count -gt 0) {
    $dgpuNameSummary = $gpuInfoSummary.dGPU.Name
    if ($gpuInfoSummary.dGPU.Columns.temperature) {
        $summaryMetrics += Get-MetricStatistics -Data $data -PropertyName $gpuInfoSummary.dGPU.Columns.temperature -Label "$dgpuNameSummary Temperature (for reference only)" -Unit "°C"
    }
    if ($gpuInfoSummary.dGPU.Columns.power) {
        $summaryMetrics += Get-MetricStatistics -Data $data -PropertyName $gpuInfoSummary.dGPU.Columns.power -Label "$dgpuNameSummary Power" -Unit "W"
    }
    if ($gpuInfoSummary.dGPU.Columns.coreLoad) {
        $summaryMetrics += Get-MetricStatistics -Data $data -PropertyName $gpuInfoSummary.dGPU.Columns.coreLoad -Label "$dgpuNameSummary Core Load" -Unit "%"
    }
    if ($gpuInfoSummary.dGPU.Columns.load3d) {
        $summaryMetrics += Get-MetricStatistics -Data $data -PropertyName $gpuInfoSummary.dGPU.Columns.load3d -Label "$dgpuNameSummary 3D Load" -Unit "%"
    }
    if ($gpuInfoSummary.dGPU.Columns.videoDecode) {
        $summaryMetrics += Get-MetricStatistics -Data $data -PropertyName $gpuInfoSummary.dGPU.Columns.videoDecode -Label "$dgpuNameSummary Video Decode" -Unit "%"
    }
    if ($gpuInfoSummary.dGPU.Columns.videoProcessing) {
        $summaryMetrics += Get-MetricStatistics -Data $data -PropertyName $gpuInfoSummary.dGPU.Columns.videoProcessing -Label "$dgpuNameSummary Video Processing" -Unit "%"
    }
}

# Calculate log duration information for summary
$summaryTimestamps = $data | ForEach-Object {
    try {
        [datetime]::ParseExact($_.Timestamp, "yyyy-MM-dd HH:mm:ss", [System.Globalization.CultureInfo]::InvariantCulture)
    } catch {
        $null
    }
} | Where-Object { $_ -ne $null }

$summaryStartTime = $summaryTimestamps | Sort-Object | Select-Object -First 1
$summaryEndTime = $summaryTimestamps | Sort-Object | Select-Object -Last 1
$summaryDuration = $summaryEndTime - $summaryStartTime
$summaryDurationHours = [math]::Round($summaryDuration.TotalHours, 2)

# Generate HTML table rows for summary metrics
$summaryTableRows = $summaryMetrics | ForEach-Object {
    if ($_.Available) {
        "<tr>
            <td>$($_.Label)</td>
            <td>$($_.Average) $($_.Unit)</td>
            <td>$($_.Minimum) $($_.Unit)</td>
            <td>$($_.Maximum) $($_.Unit)</td>
        </tr>"
    } else {
        "<tr>
            <td>$($_.Label)</td>
            <td colspan='3'>Data Not Available</td>
        </tr>"
    }
}

# Generate the summary HTML report content
$summaryReportContent = @"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Hardware Resource Usage Summary - $(Split-Path $csvFilePath -Leaf)</title>
    <style>
        body { 
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
        .duration-info {
            background-color: #f8f9fa;
            padding: 10px;
            border-radius: 5px;
            margin: 10px auto;
            max-width: 80%;
            border: 1px solid #e0e0e0;
        }
        .summary-container {
            width: 90%;
            margin: 30px auto;
            background-color: white;
            border-radius: 10px;
            box-shadow: 0 4px 6px rgba(0, 0, 0, 0.1);
            padding: 20px;
        }
        .summary-title {
            text-align: center;
            font-size: 24px;
            font-weight: 600;
            margin-bottom: 20px;
            color: #2c3e50;
        }
        table {
            width: 100%;
            border-collapse: collapse;
            margin-top: 20px;
        }
        th, td {
            padding: 12px 15px;
            text-align: left;
            border-bottom: 1px solid #e0e0e0;
        }
        th {
            background-color: #f8f9fa;
            font-weight: 600;
            color: #2c3e50;
        }
        tr:hover {
            background-color: #f8f9fa;
        }
        .footer {
            text-align: center;
            margin-top: 30px;
            font-size: 14px;
            color: #7f8c8d;
        }
    </style>
</head>
<body>
    <div class="header">
        <h1>Hardware Resource Usage Summary</h1>
        <h2>Source File: $(Split-Path $csvFilePath -Leaf)</h2>
        <div class="duration-info">
            <p>Log Duration: $summaryDurationHours hours (From $($summaryStartTime.ToString("yyyy-MM-dd HH:mm:ss")) to $($summaryEndTime.ToString("yyyy-MM-dd HH:mm:ss")))</p>
        </div>
    </div>

    <div class="summary-container">
        <div class="summary-title">Resource Usage Statistics</div>
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
                $summaryTableRows
            </tbody>
        </table>
    </div>

    <div class="footer">
        <p>Report generated on $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")</p>
    </div>

</body>
</html>
"@

# Save the summary report to its HTML file
Write-Host "Saving summary report to $summaryHtmlOutputPath..."
$summaryReportContent | Out-File -FilePath $summaryHtmlOutputPath -Encoding UTF8 -Force

# --- End of Summary Report Generation ---
    
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

# Get Chart.js reference
$chartJsRef = Get-ChartJsReference

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
        body { 
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
    </style>
</head>
<body>
    <div class="header">
        <h1>Hardware Resource Usage Report</h1>
        <h2>Source File: $(Split-Path $csvFilePath -Leaf)</h2>
    </div>

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
                <div class="chart-title">CPU Temperature (C) (for reference only)</div>
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

    <!-- Old iGPU/dGPU charts removed -->
    <!-- Combined Power chart removed -->
    <!-- CPU Core Clock chart removed -->

    <div class="chart-row">
        <div class="chart-container" style="width: 90%; height: 500px;">
            <div class="chart-title">GPU Engine Utilization (%)</div>
            <canvas id="gpuEngineChart"></canvas>
        </div>
    </div>

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
        const screenBrightness = [];
        const batteryPercentage = [];
        const dgpuTemperature = []; // Keep dGPU temp if available
        
        // GPU Engine data
        const gpuEngines = {};
        const gpuEngineNames = [];
        
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
        
        // Identify column names from the first row if available
        let dgpuNameForTemp = "dGPU"; // Default name for temp chart label - MOVED DECLARATION OUTSIDE IF
        if (rawData.length > 0) {
            const firstRow = rawData[0];
            const columnNames = Object.keys(firstRow);
            
            // Find GPU column names and extract GPU names
            // let dgpuNameForTemp = "dGPU"; // Default name for temp chart label - REMOVED FROM HERE
            columnNames.forEach(colName => {
                // Extract dGPU name if temperature column exists
                 if (colName.includes('GPU_Nvidia') && colName.endsWith('TemperatureC')) {
                     const nameParts = colName.split('_');
                     if (nameParts.length >= 3) {
                         const nameEndIndex = colName.lastIndexOf('_');
                         const nameStartIndex = colName.indexOf('_') + 1;
                         const fullName = colName.substring(nameStartIndex, nameEndIndex);
                         dgpuNameForTemp = fullName.replace(/_/g, ' ');
                     }
                 }
                
                // Match GPU Engine columns
                if (colName.startsWith('GPUEngine_') && colName.endsWith('_Percent')) {
                    const engineName = colName.replace('GPUEngine_', '').replace('_Percent', '');
                    // Ensure engineName is not empty before adding
                    if (engineName && !gpuEngineNames.includes(engineName)) {
                        gpuEngineNames.push(engineName);
                    }
                }
            });
            
            // REMOVED old chart title updates
            // REMOVED old console logs for igpu/dgpu columns
        }
        
        // Process each row of data
        rawData.forEach((row, index) => {
            timestamps.push(row.Timestamp);
            cpuUsage.push(parseNumeric(row.CPUUsagePercent)); // Updated CPUUsage to CPUUsagePercent
            ramUsed.push(parseNumeric(row.RAMUsedMB));
            ramAvailable.push(parseNumeric(row.RAMAvailableMB));
            diskIO.push(parseNumeric(row.DiskIOTransferSec));
            networkIO.push(parseNumeric(row.NetworkIOBytesSec));
            cpuTemp.push(parseNumeric(row.CPUTemperatureC));
            screenBrightness.push(parseNumeric(row.ScreenBrightness));
            batteryPercentage.push(parseNumeric(row.BatteryPercentage));
            
            // Process dGPU Temperature data
            let dgpuTempColName = Object.keys(row).find(k => k.includes('GPU_Nvidia') && k.endsWith('TemperatureC'));
            dgpuTemperature.push(dgpuTempColName ? parseNumeric(row[dgpuTempColName]) : null);
            
            // Process GPU Engine data
            gpuEngineNames.forEach(engineName => {
                // Only process if engineName is valid
                if (engineName) {
                    const colName = 'GPUEngine_' + engineName + '_Percent'; // Use concatenation
                    if (!gpuEngines[engineName]) {
                        gpuEngines[engineName] = Array(index).fill(null); // Initialize with nulls for previous rows
                    }
                     // Make sure all engine arrays have the same length up to the current index
                    while (gpuEngines[engineName].length < index) {
                        gpuEngines[engineName].push(null);
                    }
                    // Check if the column actually exists in the row before accessing
                    if (row.hasOwnProperty(colName)) {
                         gpuEngines[engineName].push(parseNumeric(row[colName]));
                    } else {
                         gpuEngines[engineName].push(null); // Push null if column doesn't exist for this row
                    }
                }
            });
        });
        
        // Ensure all GPU engine and CPU core arrays have the full length after processing all rows
        const totalRows = rawData.length;
        gpuEngineNames.forEach(engineName => {
             if (gpuEngines[engineName]) {
                 while (gpuEngines[engineName].length < totalRows) {
                     gpuEngines[engineName].push(null);
                  }
              }
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
        function createMultiChart(canvasId, datasets, yAxisLabel, min = null, max = null) {
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
            }
        ], 'Temperature (°C)');

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

        // REMOVED CPU Core Clock Speed Chart creation
        
        // Create GPU Engine Utilization Chart
        const ctxGpuEngine = document.getElementById('gpuEngineChart').getContext('2d');
        if (gpuEngineNames.length > 0) {
            const engineDatasets = [];
            const engineColors = [ // Use a predefined color list
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
             // Display a message if no GPU Engine data is found
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

# Save the main chart report to its HTML file
Write-Host "Saving main chart report to $htmlOutputPath..."
$reportContent | Out-File -FilePath $htmlOutputPath -Encoding UTF8 -Force

Write-Host "Main chart report generated successfully: $htmlOutputPath"
Write-Host "Summary report generated successfully: $summaryHtmlOutputPath"