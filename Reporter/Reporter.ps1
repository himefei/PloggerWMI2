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
            },
            {
                label: "dGPU Temperature (" + dgpuNameForTemp + ")", // Use extracted name
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

# Save the report to the HTML file
Write-Host "Saving report to $htmlOutputPath..."
$reportContent | Out-File -FilePath $htmlOutputPath -Encoding UTF8 -Force

Write-Host "Report generated successfully: $htmlOutputPath"