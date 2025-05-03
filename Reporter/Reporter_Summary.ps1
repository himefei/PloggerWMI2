# Reporter_Summary.ps1
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

# Define the output HTML file path (same directory, same name + _summary.html)
$fileNameWithoutExt = [System.IO.Path]::GetFileNameWithoutExtension($csvFilePath)
$directory = [System.IO.Path]::GetDirectoryName($csvFilePath)
$htmlOutputPath = [System.IO.Path]::Combine($directory, "$fileNameWithoutExt" + "_summary.html")

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
$requiredColumns = @('Timestamp', 'CPUUsage')
$missingColumns = $requiredColumns | Where-Object { -not $data[0].PSObject.Properties.Name -contains $_ }
if ($missingColumns) {
    Write-Error "The CSV file '$csvFilePath' is missing required columns: $($missingColumns -join ', ')"
    exit
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

# Function to identify GPU columns and extract GPU names
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

# Identify GPU columns
$gpuInfo = Get-GpuColumns -Data $data

# Calculate statistics for each metric
$metrics = @()

# CPU Usage
$metrics += Get-MetricStatistics -Data $data -PropertyName "CPUUsage" -Label "CPU Usage" -Unit "%"

# RAM
$metrics += Get-MetricStatistics -Data $data -PropertyName "RAMUsedMB" -Label "RAM Used" -Unit "MB"
$metrics += Get-MetricStatistics -Data $data -PropertyName "RAMAvailableMB" -Label "RAM Available" -Unit "MB"

# Disk and Network IO
$metrics += Get-MetricStatistics -Data $data -PropertyName "DiskIOTransferSec" -Label "Disk I/O" -Unit "transfers/sec"
$metrics += Get-MetricStatistics -Data $data -PropertyName "NetworkIOBytesSec" -Label "Network I/O" -Unit "bytes/sec"

# CPU Temperature
$metrics += Get-MetricStatistics -Data $data -PropertyName "CPUTemperatureC" -Label "CPU Temperature" -Unit "°C"

# Screen Brightness
$metrics += Get-MetricStatistics -Data $data -PropertyName "ScreenBrightness" -Label "Screen Brightness" -Unit "%"

# Power Metrics
$metrics += Get-MetricStatistics -Data $data -PropertyName "CPUPowerW" -Label "CPU Power" -Unit "W"
$metrics += Get-MetricStatistics -Data $data -PropertyName "CPUPlatformPowerW" -Label "Platform Power" -Unit "W"

# iGPU Metrics (if available)
if ($gpuInfo.iGPU.Columns.Count -gt 0) {
    $igpuName = $gpuInfo.iGPU.Name
    
    if ($gpuInfo.iGPU.Columns.temperature) {
        $metrics += Get-MetricStatistics -Data $data -PropertyName $gpuInfo.iGPU.Columns.temperature -Label "$igpuName Temperature" -Unit "°C"
    }
    
    if ($gpuInfo.iGPU.Columns.power) {
        $metrics += Get-MetricStatistics -Data $data -PropertyName $gpuInfo.iGPU.Columns.power -Label "$igpuName Power" -Unit "W"
    }
    
    if ($gpuInfo.iGPU.Columns.coreLoad) {
        $metrics += Get-MetricStatistics -Data $data -PropertyName $gpuInfo.iGPU.Columns.coreLoad -Label "$igpuName Core Load" -Unit "%"
    }
    
    if ($gpuInfo.iGPU.Columns.load3d) {
        $metrics += Get-MetricStatistics -Data $data -PropertyName $gpuInfo.iGPU.Columns.load3d -Label "$igpuName 3D Load" -Unit "%"
    }
    
    if ($gpuInfo.iGPU.Columns.videoDecode) {
        $metrics += Get-MetricStatistics -Data $data -PropertyName $gpuInfo.iGPU.Columns.videoDecode -Label "$igpuName Video Decode" -Unit "%"
    }
    
    if ($gpuInfo.iGPU.Columns.videoProcessing) {
        $metrics += Get-MetricStatistics -Data $data -PropertyName $gpuInfo.iGPU.Columns.videoProcessing -Label "$igpuName Video Processing" -Unit "%"
    }
}

# dGPU Metrics (if available)
if ($gpuInfo.dGPU.Columns.Count -gt 0) {
    $dgpuName = $gpuInfo.dGPU.Name
    
    if ($gpuInfo.dGPU.Columns.temperature) {
        $metrics += Get-MetricStatistics -Data $data -PropertyName $gpuInfo.dGPU.Columns.temperature -Label "$dgpuName Temperature" -Unit "°C"
    }
    
    if ($gpuInfo.dGPU.Columns.power) {
        $metrics += Get-MetricStatistics -Data $data -PropertyName $gpuInfo.dGPU.Columns.power -Label "$dgpuName Power" -Unit "W"
    }
    
    if ($gpuInfo.dGPU.Columns.coreLoad) {
        $metrics += Get-MetricStatistics -Data $data -PropertyName $gpuInfo.dGPU.Columns.coreLoad -Label "$dgpuName Core Load" -Unit "%"
    }
    
    if ($gpuInfo.dGPU.Columns.load3d) {
        $metrics += Get-MetricStatistics -Data $data -PropertyName $gpuInfo.dGPU.Columns.load3d -Label "$dgpuName 3D Load" -Unit "%"
    }
    
    if ($gpuInfo.dGPU.Columns.videoDecode) {
        $metrics += Get-MetricStatistics -Data $data -PropertyName $gpuInfo.dGPU.Columns.videoDecode -Label "$dgpuName Video Decode" -Unit "%"
    }
    
    if ($gpuInfo.dGPU.Columns.videoProcessing) {
        $metrics += Get-MetricStatistics -Data $data -PropertyName $gpuInfo.dGPU.Columns.videoProcessing -Label "$dgpuName Video Processing" -Unit "%"
    }
}

# Calculate log duration information
$timestamps = $data | ForEach-Object {
    try {
        [datetime]::ParseExact($_.Timestamp, "yyyy-MM-dd HH:mm:ss", [System.Globalization.CultureInfo]::InvariantCulture)
    } catch {
        $null
    }
} | Where-Object { $_ -ne $null }

$startTime = $timestamps | Sort-Object | Select-Object -First 1
$endTime = $timestamps | Sort-Object | Select-Object -Last 1
$duration = $endTime - $startTime
$durationHours = [math]::Round($duration.TotalHours, 2)

# Generate HTML table rows for metrics
$tableRows = $metrics | ForEach-Object {
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

# Generate the HTML report
$reportContent = @"
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
            <p>Log Duration: $durationHours hours (From $($startTime.ToString("yyyy-MM-dd HH:mm:ss")) to $($endTime.ToString("yyyy-MM-dd HH:mm:ss")))</p>
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
                $tableRows
            </tbody>
        </table>
    </div>

    <div class="footer">
        <p>Report generated on $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")</p>
    </div>

</body>
</html>
"@

# Save the report to the HTML file
Write-Host "Saving summary report to $htmlOutputPath..."
$reportContent | Out-File -FilePath $htmlOutputPath -Encoding UTF8 -Force

Write-Host "Summary report generated successfully: $htmlOutputPath"