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
    </script>
</body>
</html>
"@

# Save the report to the HTML file
Write-Host "Saving report to $htmlOutputPath..."
$reportContent | Out-File -FilePath $htmlOutputPath -Encoding UTF8 -Force

Write-Host "Report generated successfully: $htmlOutputPath"