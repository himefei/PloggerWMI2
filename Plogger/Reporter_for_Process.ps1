# Reporter_for_Process.ps1
# Requires -Modules Microsoft.PowerShell.Utility

# Import required assemblies for multithreading
Add-Type -AssemblyName System.Threading

function Select-CsvFile {
    param(
        [string]$InitialDirectory = $PSScriptRoot
    )
    Add-Type -AssemblyName System.Windows.Forms
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.InitialDirectory = $InitialDirectory
    $dlg.Filter = 'CSV files (*.csv)|*.csv|All files (*.*)|*.*'
    $dlg.Title = 'Select Process Usage CSV File'
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        return $dlg.FileName
    }
    Write-Warning 'No file selected.'
    exit
}

# Helper function for parallel processing
function Start-ParallelProcessing {
    param(
        [parameter(Mandatory=$true)][array]$InputData,
        [parameter(Mandatory=$true)][scriptblock]$ScriptBlock,
        [int]$ThrottleLimit = [Environment]::ProcessorCount
    )

    Write-Host "Starting parallel processing with $ThrottleLimit threads"
    
    # Create runspace pool
    $sessionState = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    $runspacePool = [runspacefactory]::CreateRunspacePool(1, $ThrottleLimit, $sessionState, $Host)
    $runspacePool.Open()
    
    $jobs = @()
    $results = @()
    
    # Create jobs for each item
    foreach ($item in $InputData) {
        $powerShell = [powershell]::Create().AddScript($ScriptBlock).AddArgument($item)
        $powerShell.RunspacePool = $runspacePool
        
        $jobs += [PSCustomObject]@{
            PowerShell = $powerShell
            Handle = $powerShell.BeginInvoke()
        }
    }
    
    # Wait for all jobs to complete and collect results
    foreach ($job in $jobs) {
        $results += $job.PowerShell.EndInvoke($job.Handle)
        $job.PowerShell.Dispose()
    }
    
    # Clean up
    $runspacePool.Close()
    $runspacePool.Dispose()
    
    return $results
}

# Main
$csvPath = Select-CsvFile
$startTime = Get-Date
Write-Host "Processing process CSV: $csvPath"

# Enable maximum threading for optimization
$maxThreads = [Environment]::ProcessorCount
Write-Host "Using $maxThreads threads for processing"

# Import data
Write-Host "Importing data..."
$data = Import-Csv -Path $csvPath -ErrorAction Stop

# Validate columns - handle both old and new format
$reqOld = 'Timestamp','ProcessName','CPUPercent','RAM_MB','IOReadBytesPerSec','IOWriteBytesPerSec','GPUDedicatedMemoryMB','GPUSharedMemoryMB'
$reqNew = 'Timestamp','ProcessName','CPUPercentRaw','LogicalCoreCount','RAM_MB','IOReadBytesPerSec','IOWriteBytesPerSec','GPUDedicatedMemoryMB','GPUSharedMemoryMB'

$hasOldFormat = $reqOld | ForEach-Object { $data[0].PSObject.Properties.Name.Contains($_) } | Where-Object { $_ -eq $false } | Measure-Object | Select-Object -ExpandProperty Count
$hasNewFormat = $reqNew | ForEach-Object { $data[0].PSObject.Properties.Name.Contains($_) } | Where-Object { $_ -eq $false } | Measure-Object | Select-Object -ExpandProperty Count

if ($hasOldFormat -eq 0) {
    Write-Host "Processing legacy process data format..."
    $useNewFormat = $false
} elseif ($hasNewFormat -eq 0) {
    Write-Host "Processing optimized process data format..."
    $useNewFormat = $true
    
    # Convert raw CPU data to calculated percentages
    Write-Host "Converting raw CPU data to percentages..."
    $data = $data | ForEach-Object {
        if ($_.CPUPercentRaw -and $_.LogicalCoreCount) {
            try {
                $rawCPU = [double]$_.CPUPercentRaw
                $coreCount = [double]$_.LogicalCoreCount
                if ($coreCount -gt 0) {
                    $_ | Add-Member -MemberType NoteProperty -Name 'CPUPercent' -Value ([math]::Round($rawCPU / $coreCount, 2)) -Force
                } else {
                    $_ | Add-Member -MemberType NoteProperty -Name 'CPUPercent' -Value ([math]::Round($rawCPU, 2)) -Force
                }
            } catch {
                $_ | Add-Member -MemberType NoteProperty -Name 'CPUPercent' -Value 0 -Force
            }
        } else {
            $_ | Add-Member -MemberType NoteProperty -Name 'CPUPercent' -Value 0 -Force
        }
        $_
    }
} else {
    Write-Error "CSV file does not match expected format. Missing columns from both old and new formats."; exit
}

Write-Host "Data loaded. Processing in parallel..."

# Create indexed data structures and calculate sums in a single pass
Write-Host "Creating indexed data structures and calculating sums..."
$dataByProcessTimestamp = @{}
$processList = @{}

# Use a single pass through the data to calculate all sums and store raw data
$data | ForEach-Object {
    $processName = $_.ProcessName
    $timestamp = $_.Timestamp
    
    # Initialize process entry if it doesn't exist
    if (-not $processList.ContainsKey($processName)) {
        $processList[$processName] = @{
            Count = 0
            CPUSum = 0.0
            RAMSum = 0.0
            IOReadSum = 0.0
            IOWriteSum = 0.0
            DedicatedVRAMSum = 0.0
            SharedVRAMSum = 0.0
            # Store the raw data points keyed by timestamp FOR LATER USE IN CHARTS
            RawData = @{}
        }
    }
    
    # Accumulate sums and count
    $procEntry = $processList[$processName]
    $procEntry.Count++
    $procEntry.CPUSum += [double]$_.CPUPercent
    $procEntry.RAMSum += [double]$_.RAM_MB
    $procEntry.IOReadSum += [double]$_.IOReadBytesPerSec
    $procEntry.IOWriteSum += [double]$_.IOWriteBytesPerSec
    $procEntry.DedicatedVRAMSum += [double]$_.GPUDedicatedMemoryMB
    $procEntry.SharedVRAMSum += [double]$_.GPUSharedMemoryMB
    
    # Store the raw data point for this timestamp (needed for charts later)
    $procEntry.RawData[$timestamp] = $_
    
    # Keep the timestamp lookup if needed elsewhere
    $key = "${processName}|${timestamp}"
    $dataByProcessTimestamp[$key] = $_
}

# Determine top 5 by average CPU usage using our optimized data
$topProcesses = $processList.Keys | ForEach-Object {
    $process = $processList[$_]
    [PSCustomObject]@{
        Name = $_
        AvgCPU = $process.CPUSum / $process.Count
    }
} | Sort-Object AvgCPU -Descending | Select-Object -First 5 -ExpandProperty Name

# Unique sorted timestamps - this is a quick operation
$timestamps = $data | Select-Object -ExpandProperty Timestamp | Sort-Object -Unique

# --- Aggregation: Build base name map and pre-group data by timestamp and process name ---
Write-Host "Pre-grouping data for aggregation..."
$dataByTimestampAndProcessName = @{}
$data | ForEach-Object {
    $ts = $_.Timestamp
    $procName = $_.ProcessName
    if (-not $dataByTimestampAndProcessName.ContainsKey($ts)) {
        $dataByTimestampAndProcessName[$ts] = @{}
    }
    $dataByTimestampAndProcessName[$ts][$procName] = $_
}

$baseNameMap = @{}
$data | Select-Object -ExpandProperty ProcessName -Unique | ForEach-Object {
    $origName = $_
    if ($origName -match '^(.*?)(#\d+)?$') {
        $base = $matches[1]
        if (-not $baseNameMap.ContainsKey($base)) {
            $baseNameMap[$base] = [System.Collections.Generic.List[string]]::new()
        }
        $baseNameMap[$base].Add($origName)
    }
}
Write-Host "Base name map created. Starting per-timestamp aggregation..."

# For each timestamp, sum metrics for all instances of each base name
$aggregatedByBaseAndTimestamp = @{}
foreach ($timestamp in $timestamps) {
    foreach ($base in $baseNameMap.Keys) {
        $sumCPU = 0.0; $sumRAM = 0.0; $sumRead = 0.0; $sumWrite = 0.0; $sumDedicated = 0.0; $sumShared = 0.0
        $found = $false
        if ($baseNameMap.ContainsKey($base)) {
            foreach ($inst in $baseNameMap[$base]) {
                if ($dataByTimestampAndProcessName.ContainsKey($timestamp) -and $dataByTimestampAndProcessName[$timestamp].ContainsKey($inst)) {
                    $row = $dataByTimestampAndProcessName[$timestamp][$inst]
                    $found = $true
                    $sumCPU += [double]$row.CPUPercent
                    $sumRAM += [double]$row.RAM_MB
                    $sumRead += [double]$row.IOReadBytesPerSec
                    $sumWrite += [double]$row.IOWriteBytesPerSec
                    $sumDedicated += [double]$row.GPUDedicatedMemoryMB
                    $sumShared += [double]$row.GPUSharedMemoryMB
                }
            }
        }
        if ($found) {
            if (-not $aggregatedByBaseAndTimestamp.ContainsKey($base)) {
                $aggregatedByBaseAndTimestamp[$base] = @{}
            }
            $aggregatedByBaseAndTimestamp[$base][$timestamp] = @{
                CPU = $sumCPU
                RAM = $sumRAM
                Read = $sumRead
                Write = $sumWrite
                Dedicated = $sumDedicated
                Shared = $sumShared
            }
        }
    }
}
Write-Host "Per-timestamp aggregation complete."

# Prepare series for charts using our indexed lookup for dramatically faster access
Write-Host "Processing chart data for top processes..."
$colors = '255,99,132','54,162,235','255,159,64','75,192,192','153,102,255'
$series = @{}

# Process each of the top processes in parallel
$processParams = @()
for ($i = 0; $i -lt $topProcesses.Count; $i++) {
    $processParams += @{
        Name = $topProcesses[$i]
        Color = $colors[$i % $colors.Count]
        Timestamps = $timestamps
        DataLookup = $dataByProcessTimestamp
    }
}

$seriesResults = Start-ParallelProcessing -InputData $processParams -ScriptBlock {
    param($params)
    
    $name = $params.Name
    $col = $params.Color
    $timestamps = $params.Timestamps
    $lookup = $params.DataLookup
    
    $cpu = $timestamps | ForEach-Object {
        $timestamp = $_
        $key = "${name}|${timestamp}"
        $r = $lookup[$key]
        if ($r) { [double]$r.CPUPercent } else { $null }
    }
    
    $ram = $timestamps | ForEach-Object {
        $timestamp = $_
        $key = "${name}|${timestamp}"
        $r = $lookup[$key]
        if ($r) { [double]$r.RAM_MB } else { $null }
    }
    
    $ioRead = $timestamps | ForEach-Object {
        $timestamp = $_
        $key = "${name}|${timestamp}"
        $r = $lookup[$key]
        if ($r) { [double]$r.IOReadBytesPerSec } else { $null }
    }
    
    $ioWrite = $timestamps | ForEach-Object {
        $timestamp = $_
        $key = "${name}|${timestamp}"
        $r = $lookup[$key]
        if ($r) { [double]$r.IOWriteBytesPerSec } else { $null }
    }
    
    # Extract VRAM data
    $dedicatedVRAM = $timestamps | ForEach-Object {
        $timestamp = $_
        $key = "${name}|${timestamp}"
        $r = $lookup[$key]
        if ($r) { [double]$r.GPUDedicatedMemoryMB } else { $null }
    }
    
    $sharedVRAM = $timestamps | ForEach-Object {
        $timestamp = $_
        $key = "${name}|${timestamp}"
        $r = $lookup[$key]
        if ($r) { [double]$r.GPUSharedMemoryMB } else { $null }
    }
    
    return @{
        Name = $name
        Data = [PSCustomObject]@{
            Color = $col
            CPU = $cpu
            RAM = $ram
            ReadIO = $ioRead
            WriteIO = $ioWrite
            DedicatedVRAM = $dedicatedVRAM
            SharedVRAM = $sharedVRAM
        }
    }
}

# Reconstruct the series dictionary from parallel results
foreach ($result in $seriesResults) {
    $series[$result.Name] = $result.Data
}

# Output HTML path
$htmlPath = [IO.Path]::ChangeExtension($csvPath, '.html')

Write-Host "Preparing process statistics from aggregated data..."

# Calculate averages and prepare stats without parallel processing
$processStats = [System.Collections.ArrayList]::new()
$ramStats = [System.Collections.ArrayList]::new()
$vramStatsDedicated = [System.Collections.ArrayList]::new()
$vramStatsShared = [System.Collections.ArrayList]::new()
$processData = @{} # Prepare data for the JSON

$uniqueProcesses = $processList.Keys | Sort-Object # Sort names if needed for dropdown order

# Add aggregated process names for dropdowns
# Identify base names that have more than one instance
$multiInstanceBaseNames = $baseNameMap.Keys | Where-Object { ($baseNameMap[$_]).Count -gt 1 }

# Create the list for dropdowns
$dropdownNameList = [System.Collections.Generic.List[string]]::new()

# Add all original process names
foreach ($upn in $uniqueProcesses) { # Corrected AddRange to handle potential type mismatch
    $dropdownNameList.Add($upn)
}

# Add "Aggregated [BaseName]" for multi-instance base names
foreach ($baseName in $multiInstanceBaseNames) {
    $dropdownNameList.Add("Aggregated $baseName")
}

$allDropdownNames = $dropdownNameList | Sort-Object -Unique

foreach ($processName in $allDropdownNames) {
    $isAggregated = $false
    $cpuPoints = @(); $ramPoints = @(); $dedicatedVRAMPoints = @(); $sharedVRAMPoints = @()
    $readIOPoints = @(); $writeIOPoints = @()
    $color = 'rgb(0, 130, 0)'
    if ($processName -like "Aggregated *") {
        $isAggregated = $true
        $base = $processName -replace "^Aggregated ", ""
        foreach ($timestamp in $timestamps) {
            $agg = $aggregatedByBaseAndTimestamp[$base][$timestamp]
            $cpuPoints += $agg.CPU
            $ramPoints += $agg.RAM
            $readIOPoints += $agg.Read
            $writeIOPoints += $agg.Write
            $dedicatedVRAMPoints += $agg.Dedicated
            $sharedVRAMPoints += $agg.Shared
        }
    } else {
        $procEntry = $processList[$processName]
        $count = $procEntry.Count
        if ($count -eq 0) { continue } # Skip if no data points
        $cpuPoints = $procEntry.RawData.Values | ForEach-Object { [double]$_.CPUPercent }
        $ramPoints = $procEntry.RawData.Values | ForEach-Object { [double]$_.RAM_MB }
        $dedicatedVRAMPoints = $procEntry.RawData.Values | ForEach-Object { [double]$_.GPUDedicatedMemoryMB }
        $sharedVRAMPoints = $procEntry.RawData.Values | ForEach-Object { [double]$_.GPUSharedMemoryMB }
        $readIOPoints = $procEntry.RawData.Values | ForEach-Object { [double]$_.IOReadBytesPerSec }
        $writeIOPoints = $procEntry.RawData.Values | ForEach-Object { [double]$_.IOWriteBytesPerSec }
        $color = if (($cpuPoints | Measure-Object -Average).Average -gt 30) {'rgb(190, 0, 0)'}
                elseif (($cpuPoints | Measure-Object -Average).Average -ge 10) {'rgb(255, 204, 0)'}
                else {'rgb(0, 130, 0)'}
    }

    # Calculate Medians
    function Get-Median($values) {
        $filtered = $values | Where-Object { $_ -ne $null }
        $sorted = $filtered | Sort-Object
        $n = $sorted.Count
        if ($n -eq 0) { return 0 }
        if ($n % 2 -eq 1) {
            return $sorted[([int][math]::Floor($n/2))]
        } else {
            $mid1 = $sorted[($n/2)-1]
            $mid2 = $sorted[($n/2)]
            return (($mid1 + $mid2) / 2)
        }
    }

    $medianCPU = [math]::Round((Get-Median $cpuPoints), 2)
    $medianRAM = [math]::Round((Get-Median $ramPoints), 2)
    $medianDedicatedVRAM = [math]::Round((Get-Median $dedicatedVRAMPoints), 2)
    $medianSharedVRAM = [math]::Round((Get-Median $sharedVRAMPoints), 2)

    $avgCPUFormatted = [math]::Round((($cpuPoints | Measure-Object -Average).Average), 2)
    $avgRAMFormatted = [math]::Round((($ramPoints | Measure-Object -Average).Average), 2)
    $avgDedicatedVRAMFormatted = [math]::Round((($dedicatedVRAMPoints | Measure-Object -Average).Average), 2)
    $avgSharedVRAMFormatted = [math]::Round((($sharedVRAMPoints | Measure-Object -Average).Average), 2)

    [void]$processStats.Add([PSCustomObject]@{
        Name   = $processName
        AvgCPU = $avgCPUFormatted
        MedianCPU = $medianCPU
        Color  = $color
        IsAggregated = $isAggregated
    })

    [void]$ramStats.Add([PSCustomObject]@{
        Name   = $processName
        AvgRAM = $avgRAMFormatted
        MedianRAM = $medianRAM
        IsAggregated = $isAggregated
    })

    [void]$vramStatsDedicated.Add([PSCustomObject]@{
        Name = $processName
        AvgDedicatedVRAM = $avgDedicatedVRAMFormatted
        MedianDedicatedVRAM = $medianDedicatedVRAM
        Color = $color
        IsAggregated = $isAggregated
    })

    [void]$vramStatsShared.Add([PSCustomObject]@{
        Name = $processName
        AvgSharedVRAM = $avgSharedVRAMFormatted
        MedianSharedVRAM = $medianSharedVRAM
        IsAggregated = $isAggregated
    })

    # Prepare data for $processData JSON
    $processData[$processName] = [PSCustomObject]@{
        CPU = $cpuPoints
        RAM = $ramPoints
        ReadIO = $readIOPoints
        WriteIO = $writeIOPoints
        DedicatedVRAM = $dedicatedVRAMPoints
        SharedVRAM = $sharedVRAMPoints
    }
}

# Sort the final lists
$processStats = $processStats | Sort-Object MedianCPU -Descending
$ramStats = $ramStats | Sort-Object MedianRAM -Descending
$vramStatsDedicated = $vramStatsDedicated | Sort-Object MedianDedicatedVRAM -Descending
$vramStatsShared = $vramStatsShared | Sort-Object MedianSharedVRAM -Descending

# Convert to JSON
$listJson = $processStats | ConvertTo-Json -Compress
$dataJson = $processData | ConvertTo-Json -Compress
$ramListJson = $ramStats | ConvertTo-Json -Compress
$vramDedicatedJson = $vramStatsDedicated | ConvertTo-Json -Compress
$vramSharedJson = $vramStatsShared | ConvertTo-Json -Compress

# Add processing time information
$endTime = Get-Date
$processingTime = ($endTime - $startTime).TotalSeconds
Write-Host "Processing completed in $processingTime seconds"

# Function to embed Chart.js directly in the HTML
function Get-ChartJsReference {
    # Get script directory reliably regardless of how the script is invoked
    if ($PSScriptRoot) {
        $scriptDir = $PSScriptRoot  # Use PowerShell automatic variable if available
    } elseif ($MyInvocation.MyCommand.Path) {
        $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    } else {
        # Fallback to current directory if all else fails
        $scriptDir = (Get-Location).Path
        Write-Warning "Using current directory for script path: $scriptDir"
    }
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

# Get Chart.js reference (local or CDN)
$chartJsRef = Get-ChartJsReference

# Generate HTML
$html = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Process Usage Report - $(Split-Path $csvPath -Leaf)</title>
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
        cursor: move;
        transition: all 0.3s ease;
    }
    .chart-container:hover {
        box-shadow: 0 6px 12px rgba(0, 0, 0, 0.15);
        transform: translateY(-2px);
    }
    .chart-container.dragging {
        opacity: 0.7;
        transform: rotate(3deg);
    }
    .chart-container.drag-over {
        border: 2px dashed #007bff;
        background-color: #f8f9fa;
    }
    .chart-title {
        text-align: center;
        font-size: 18px;
        font-weight: 600;
        margin-bottom: 15px;
        color: #2c3e50;
        user-select: none;
    }
    .chart-row {
        display: flex;
        flex-wrap: wrap;
        justify-content: space-between;
        min-height: 50px;
    }
    .chart-half {
        width: 48%;
        margin-bottom: 20px;
        min-height: 450px;
    }
    .controls {
        text-align: center;
        margin: 20px 0;
        padding: 15px;
        background-color: white;
        border-radius: 10px;
        box-shadow: 0 2px 4px rgba(0, 0, 0, 0.1);
    }
    select {
        padding: 8px 12px;
        border-radius: 5px;
        border: 1px solid #ddd;
        margin: 0 10px;
        font-size: 14px;
    }
    label {
        font-weight: 600;
        color: #2c3e50;
    }
    @media (max-width: 1200px) {
        .chart-half {
            width: 100%;
        }
    }
    h1, h2 {
        text-align: center;
        color: #2c3e50;
    }
    .drag-instructions {
        background-color: #e3f2fd;
        border: 1px solid #1976d2;
        padding: 15px;
        margin: 20px auto;
        border-radius: 8px;
        text-align: center;
        width: 90%;
        color: #1976d2;
        font-weight: 500;
    }
</style>
</head>
<body>
  <div class="header">
    <h1>Process Usage Report</h1>
    <h2>Source File: $(Split-Path $csvPath -Leaf)</h2>
  </div>

  <div class="controls">
    <label for="processSelect">Select Process:</label>
    <select id="processSelect"><option value="">Sort by median CPU usage</option></select>
    <label for="processSelectRam">Select by Median RAM:</label>
    <select id="processSelectRam"><option value="">Sort by median RAM usage</option></select>
    <label for="processSelectVram">Select by Median Dedicated VRAM:</label>
    <select id="processSelectVram"><option value="">Sort by median Dedicated VRAM</option></select>
    <label for="processSelectVramShared">Select by Median Shared VRAM:</label>
    <select id="processSelectVramShared"><option value="">Sort by median Shared VRAM</option></select>
  </div>
  
  <!-- Charts container, hidden until selection -->
  <div id="chartsContainer" style="display:none;">
    <div class="drag-instructions">
      📊 <strong>Drag & Drop Charts:</strong> Click and drag any chart to rearrange them for easy comparison. Charts will automatically reposition as you move them around.
    </div>
    
    <div id="chartsGrid">
      <div class="chart-row">
        <div class="chart-half">
          <div class="chart-container" draggable="true" data-chart-id="cpuChart">
            <div class="chart-title">CPU Usage (%)</div>
            <canvas id="cpuChart"></canvas>
          </div>
        </div>
        <div class="chart-half">
          <div class="chart-container" draggable="true" data-chart-id="ramChart">
            <div class="chart-title">RAM Usage (MB)</div>
            <canvas id="ramChart"></canvas>
          </div>
        </div>
      </div>
      
      <div class="chart-row">
        <div class="chart-half">
          <div class="chart-container" draggable="true" data-chart-id="readChart">
            <div class="chart-title">Disk Read (Bytes/sec)</div>
            <canvas id="readChart"></canvas>
          </div>
        </div>
        <div class="chart-half">
          <div class="chart-container" draggable="true" data-chart-id="writeChart">
            <div class="chart-title">Disk Write (Bytes/sec)</div>
            <canvas id="writeChart"></canvas>
          </div>
        </div>
      </div>
      
      <div class="chart-row">
        <div class="chart-half">
          <div class="chart-container" draggable="true" data-chart-id="dedicatedVramChart">
            <div class="chart-title">Dedicated VRAM (MB)</div>
            <canvas id="dedicatedVramChart"></canvas>
          </div>
        </div>
        <div class="chart-half">
          <div class="chart-container" draggable="true" data-chart-id="sharedVramChart">
            <div class="chart-title">Shared VRAM (MB)</div>
            <canvas id="sharedVramChart"></canvas>
          </div>
        </div>
      </div>
    </div>
  </div>

<script>
const labels = $($timestamps | ConvertTo-Json -Compress);
const processList = $listJson;
const processData = $dataJson;
// Populate CPU dropdown
const sel = document.getElementById('processSelect');
processList.forEach(p => {
  const o = document.createElement('option');
  o.value = p.Name;
  if (p.IsAggregated === true) { // Explicit boolean check
    o.text = '**' + p.Name.toUpperCase() + '** (' + p.MedianCPU + '%)';
  } else {
    o.text = p.Name + ' (' + p.MedianCPU + '%)';
  }
  o.style.color = p.Color;
  sel.appendChild(o);
});
// Populate RAM dropdown using existing element
const ramList = $ramListJson;
const ramSel = document.getElementById('processSelectRam');
// Reset and add default option
ramSel.innerHTML = '<option value="">Sort by median RAM usage</option>';
// Add options with color coding
ramList.forEach(p => {
  const o2 = document.createElement('option');
  o2.value = p.Name;
  if (p.IsAggregated === true) { // Explicit boolean check
    o2.text = '**' + p.Name.toUpperCase() + '** (' + p.MedianRAM + 'MB)';
  } else {
    o2.text = p.Name + ' (' + p.MedianRAM + 'MB)';
  }
  if (p.AvgRAM > 1000) o2.style.color = 'rgb(190, 0, 0)';
  else if (p.AvgRAM >= 300) o2.style.color = 'rgb(255, 204, 0)';
  else o2.style.color = 'rgb(0, 130, 0)';
  ramSel.appendChild(o2);
});
// Populate VRAM dropdown
const vramListDedicated = $vramDedicatedJson;
const vramSel = document.getElementById('processSelectVram');
// Reset and add default option
vramSel.innerHTML = '<option value="">Sort by median Dedicated VRAM</option>';
// Add options with color coding based on VRAM thresholds
vramListDedicated.forEach(p => {
  const o3 = document.createElement('option');
  o3.value = p.Name;
  if (p.IsAggregated === true) { // Explicit boolean check
    o3.text = '**' + p.Name.toUpperCase() + '** (' + p.MedianDedicatedVRAM + 'MB)';
  } else {
    o3.text = p.Name + ' (' + p.MedianDedicatedVRAM + 'MB)';
  }
  // Color coding: <100MB = green, 100-300MB = yellow, >300MB = red
  if (p.AvgDedicatedVRAM > 300) o3.style.color = 'rgb(190, 0, 0)';
  else if (p.AvgDedicatedVRAM >= 100) o3.style.color = 'rgb(255, 204, 0)';
  else o3.style.color = 'rgb(0, 130, 0)';
  vramSel.appendChild(o3);
});

// Populate Shared VRAM dropdown
const vramListShared = $vramSharedJson;
const vramSharedSel = document.getElementById('processSelectVramShared');
// Reset and add default option
vramSharedSel.innerHTML = '<option value="">Sort by median Shared VRAM</option>';
// Add options with color coding based on VRAM thresholds
vramListShared.forEach(p => {
  const o4 = document.createElement('option');
  o4.value = p.Name;
  if (p.IsAggregated === true) { // Explicit boolean check
    o4.text = '**' + p.Name.toUpperCase() + '** (' + p.MedianSharedVRAM + 'MB)';
  } else {
    o4.text = p.Name + ' (' + p.MedianSharedVRAM + 'MB)';
  }
  // Color coding: <100MB = green, 100-300MB = yellow, >300MB = red
  if (p.AvgSharedVRAM > 300) o4.style.color = 'rgb(190, 0, 0)';
  else if (p.AvgSharedVRAM >= 100) o4.style.color = 'rgb(255, 204, 0)';
  else o4.style.color = 'rgb(0, 130, 0)';
  vramSharedSel.appendChild(o4);
});

// Common chart options
const chartOptions = {
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

// Function to calculate polynomial regression trend line (more scientific approach)
function calculateTrendLine(data) {
    if (!data || data.length < 3) return [];
    
    const validData = data.map((val, idx) => ({ x: idx, y: val }))
                         .filter(point => point.y !== null && point.y !== undefined && !isNaN(point.y));
    
    if (validData.length < 3) return [];
    
    // Use polynomial regression (degree 2 for curves, degree 3 for more complex patterns)
    const degree = Math.min(3, Math.floor(validData.length / 10) + 2); // Adaptive degree based on data size
    const coefficients = polynomialRegression(validData, degree);
    
    if (!coefficients) return [];
    
    // Generate curved trend line points
    return data.map((val, idx) => {
        if (val === null || val === undefined || isNaN(val)) return null;
        return evaluatePolynomial(coefficients, idx);
    });
}

// Polynomial regression implementation using least squares method
function polynomialRegression(data, degree) {
    if (data.length <= degree) return null;
    
    const n = data.length;
    const matrix = [];
    const vector = [];
    
    // Build the normal equations matrix (Vandermonde-style)
    for (let i = 0; i <= degree; i++) {
        const row = [];
        let sum = 0;
        
        for (let j = 0; j <= degree; j++) {
            let powSum = 0;
            for (const point of data) {
                powSum += Math.pow(point.x, i + j);
            }
            row.push(powSum);
        }
        matrix.push(row);
        
        // Build the result vector
        for (const point of data) {
            sum += point.y * Math.pow(point.x, i);
        }
        vector.push(sum);
    }
    
    // Solve the system using Gaussian elimination
    return gaussianElimination(matrix, vector);
}

// Gaussian elimination solver for polynomial coefficients
function gaussianElimination(matrix, vector) {
    const n = matrix.length;
    const augmented = matrix.map((row, i) => [...row, vector[i]]);
    
    // Forward elimination
    for (let i = 0; i < n; i++) {
        // Find pivot
        let maxRow = i;
        for (let k = i + 1; k < n; k++) {
            if (Math.abs(augmented[k][i]) > Math.abs(augmented[maxRow][i])) {
                maxRow = k;
            }
        }
        [augmented[i], augmented[maxRow]] = [augmented[maxRow], augmented[i]];
        
        // Make all rows below this one 0 in current column
        for (let k = i + 1; k < n; k++) {
            if (Math.abs(augmented[i][i]) < 1e-10) continue; // Avoid division by zero
            const factor = augmented[k][i] / augmented[i][i];
            for (let j = i; j <= n; j++) {
                augmented[k][j] -= factor * augmented[i][j];
            }
        }
    }
    
    // Back substitution
    const solution = new Array(n);
    for (let i = n - 1; i >= 0; i--) {
        solution[i] = augmented[i][n];
        for (let j = i + 1; j < n; j++) {
            solution[i] -= augmented[i][j] * solution[j];
        }
        if (Math.abs(augmented[i][i]) < 1e-10) return null; // Singular matrix
        solution[i] /= augmented[i][i];
    }
    
    return solution;
}

// Evaluate polynomial at given x value
function evaluatePolynomial(coefficients, x) {
    let result = 0;
    for (let i = 0; i < coefficients.length; i++) {
        result += coefficients[i] * Math.pow(x, i);
    }
    return result;
}

// Function to create dataset with consistent styling
function createDataset(label, data, color) {
  return {
    label: label,
    data: data,
    borderColor: color,
    backgroundColor: color.replace(')', ', 0.2)').replace('rgb', 'rgba'),
    borderWidth: 2,
    tension: 0.4,
    pointRadius: 0,
    pointHoverRadius: 5,
    pointHitRadius: 10
  };
}

// Function to create trend dataset
function createTrendDataset(label, data, color) {
  const trendData = calculateTrendLine(data);
  if (trendData.length === 0) return null;
  
  const trendColor = color.replace('rgb', 'rgba').replace(')', ', 0.7)');
  return {
    label: label + ' Trend',
    data: trendData,
    borderColor: trendColor,
    backgroundColor: 'transparent',
    borderWidth: 2,
    borderDash: [5, 5],
    tension: 0,
    pointRadius: 0,
    pointHoverRadius: 0,
    pointHitRadius: 0
  };
}

// Chart instances
let charts = {};

// Function to update all charts for a selected process
function updateAllCharts(processName) {
  const container = document.getElementById('chartsContainer');
  if (!processName) {
    container.style.display = 'none';
    return;
  }
  
  container.style.display = 'block';
  const d = processData[processName];
  
  // destroy existing charts
  Object.values(charts).forEach(c=>c.destroy());
  charts = {};
  
  // render all charts with enhanced styling and trend lines
  const cpuDatasets = [createDataset(processName, d.CPU, 'rgb(255, 99, 132)')];
  const cpuTrend = createTrendDataset(processName, d.CPU, 'rgb(255, 99, 132)');
  if (cpuTrend) cpuDatasets.push(cpuTrend);
  
  charts.cpu = new Chart(document.getElementById('cpuChart').getContext('2d'), {
    type: 'line',
    data: {
      labels,
      datasets: cpuDatasets
    },
    options: chartOptions
  });
  
  const ramDatasets = [createDataset(processName, d.RAM, 'rgb(54, 162, 235)')];
  const ramTrend = createTrendDataset(processName, d.RAM, 'rgb(54, 162, 235)');
  if (ramTrend) ramDatasets.push(ramTrend);
  
  charts.ram = new Chart(document.getElementById('ramChart').getContext('2d'), {
    type: 'line',
    data: {
      labels,
      datasets: ramDatasets
    },
    options: chartOptions
  });
  
  const readDatasets = [createDataset(processName, d.ReadIO, 'rgb(75, 192, 192)')];
  const readTrend = createTrendDataset(processName, d.ReadIO, 'rgb(75, 192, 192)');
  if (readTrend) readDatasets.push(readTrend);
  
  charts.read = new Chart(document.getElementById('readChart').getContext('2d'), {
    type: 'line',
    data: {
      labels,
      datasets: readDatasets
    },
    options: chartOptions
  });
  
  const writeDatasets = [createDataset(processName, d.WriteIO, 'rgb(255, 159, 64)')];
  const writeTrend = createTrendDataset(processName, d.WriteIO, 'rgb(255, 159, 64)');
  if (writeTrend) writeDatasets.push(writeTrend);
  
  charts.write = new Chart(document.getElementById('writeChart').getContext('2d'), {
    type: 'line',
    data: {
      labels,
      datasets: writeDatasets
    },
    options: chartOptions
  });
  
  // Add VRAM charts
  charts.dedicatedVram = new Chart(document.getElementById('dedicatedVramChart').getContext('2d'), {
    type: 'line',
    data: {
      labels,
      datasets: [createDataset(processName, d.DedicatedVRAM, 'rgb(153, 102, 255)')]
    },
    options: chartOptions
  });
  
  charts.sharedVram = new Chart(document.getElementById('sharedVramChart').getContext('2d'), {
    type: 'line',
    data: {
      labels,
      datasets: [createDataset(processName, d.SharedVRAM, 'rgb(201, 203, 207)')]
    },
    options: chartOptions
  });
}

// CPU selection listener
sel.addEventListener('change', () => {
  updateAllCharts(sel.value);
});

// RAM selection listener
ramSel.addEventListener('change', () => {
  updateAllCharts(ramSel.value);
});

// VRAM selection listener
vramSel.addEventListener('change', () => {
  updateAllCharts(vramSel.value);
});

// Shared VRAM selection listener
vramSharedSel.addEventListener('change', () => {
  updateAllCharts(vramSharedSel.value);
});

// Store chart instances and their configurations for drag and drop
const chartInstances = {};
const chartConfigs = {};

// Store chart configurations after creation
function storeChartConfig(chartId, chart) {
  chartInstances[chartId] = chart;
  chartConfigs[chartId] = {
    type: chart.config.type,
    data: JSON.parse(JSON.stringify(chart.config.data)),
    options: JSON.parse(JSON.stringify(chart.config.options))
  };
}

// Recreate chart in a new canvas
function recreateChart(canvasId) {
  const canvas = document.getElementById(canvasId);
  if (!canvas || !chartConfigs[canvasId]) return;
  
  // Destroy existing chart if it exists
  if (chartInstances[canvasId]) {
    chartInstances[canvasId].destroy();
  }
  
  // Create new chart with stored config
  const ctx = canvas.getContext('2d');
  const newChart = new Chart(ctx, chartConfigs[canvasId]);
  chartInstances[canvasId] = newChart;
  return newChart;
}

// Drag and Drop functionality
let draggedElement = null;

function attachDragListeners(container) {
  container.addEventListener('dragstart', function(e) {
    draggedElement = this;
    this.classList.add('dragging');
    e.dataTransfer.effectAllowed = 'move';
    e.dataTransfer.setData('text/html', this.outerHTML);
  });
  
  container.addEventListener('dragend', function(e) {
    this.classList.remove('dragging');
    draggedElement = null;
  });
  
  container.addEventListener('dragover', function(e) {
    e.preventDefault();
    e.dataTransfer.dropEffect = 'move';
    this.classList.add('drag-over');
  });
  
  container.addEventListener('dragleave', function(e) {
    this.classList.remove('drag-over');
  });
  
  container.addEventListener('drop', function(e) {
    e.preventDefault();
    this.classList.remove('drag-over');
    
    if (draggedElement !== this) {
      // Get canvas IDs before swapping
      const draggedCanvas = draggedElement.querySelector('canvas');
      const targetCanvas = this.querySelector('canvas');
      const draggedCanvasId = draggedCanvas ? draggedCanvas.id : null;
      const targetCanvasId = targetCanvas ? targetCanvas.id : null;
      
      // Get the parent elements (chart-half containers)
      const draggedParent = draggedElement.parentNode;
      const targetParent = this.parentNode;
      
      // Swap the chart containers
      const draggedClone = draggedElement.cloneNode(true);
      const targetClone = this.cloneNode(true);
      
      // Clean up any drag-related CSS classes from cloned elements
      draggedClone.classList.remove('dragging', 'drag-over');
      targetClone.classList.remove('dragging', 'drag-over');
      
      // Replace the containers
      draggedParent.replaceChild(targetClone, draggedElement);
      targetParent.replaceChild(draggedClone, this);
      
      // Recreate charts in the new positions
      if (draggedCanvasId && targetCanvasId) {
        setTimeout(() => {
          recreateChart(draggedCanvasId);
          recreateChart(targetCanvasId);
        }, 50);
      }
      
      // Re-attach event listeners to the new elements
      attachDragListeners(draggedClone);
      attachDragListeners(targetClone);
    }
  });
}

// Initialize drag and drop for existing charts
document.querySelectorAll('.chart-container').forEach(container => {
  attachDragListeners(container);
});

// Enhanced updateAllCharts function with chart storage
const originalUpdateAllCharts = updateAllCharts;
updateAllCharts = function(processName) {
  const container = document.getElementById('chartsContainer');
  if (!processName) {
    container.style.display = 'none';
    return;
  }
  
  container.style.display = 'block';
  const d = processData[processName];
  
  // destroy existing charts
  Object.values(charts).forEach(c=>c.destroy());
  charts = {};
  
  // render all charts with enhanced styling and store configs
  charts.cpu = new Chart(document.getElementById('cpuChart').getContext('2d'), {
    type: 'line',
    data: {
      labels,
      datasets: [createDataset(processName, d.CPU, 'rgb(255, 99, 132)')]
    },
    options: chartOptions
  });
  storeChartConfig('cpuChart', charts.cpu);
  
  charts.ram = new Chart(document.getElementById('ramChart').getContext('2d'), {
    type: 'line',
    data: {
      labels,
      datasets: [createDataset(processName, d.RAM, 'rgb(54, 162, 235)')]
    },
    options: chartOptions
  });
  storeChartConfig('ramChart', charts.ram);
  
  charts.read = new Chart(document.getElementById('readChart').getContext('2d'), {
    type: 'line',
    data: {
      labels,
      datasets: [createDataset(processName, d.ReadIO, 'rgb(75, 192, 192)')]
    },
    options: chartOptions
  });
  storeChartConfig('readChart', charts.read);
  
  charts.write = new Chart(document.getElementById('writeChart').getContext('2d'), {
    type: 'line',
    data: {
      labels,
      datasets: [createDataset(processName, d.WriteIO, 'rgb(255, 159, 64)')]
    },
    options: chartOptions
  });
  storeChartConfig('writeChart', charts.write);
  
  // Add VRAM charts
  charts.dedicatedVram = new Chart(document.getElementById('dedicatedVramChart').getContext('2d'), {
    type: 'line',
    data: {
      labels,
      datasets: [createDataset(processName, d.DedicatedVRAM, 'rgb(153, 102, 255)')]
    },
    options: chartOptions
  });
  storeChartConfig('dedicatedVramChart', charts.dedicatedVram);
  
  charts.sharedVram = new Chart(document.getElementById('sharedVramChart').getContext('2d'), {
    type: 'line',
    data: {
      labels,
      datasets: [createDataset(processName, d.SharedVRAM, 'rgb(201, 203, 207)')]
    },
    options: chartOptions
  });
  storeChartConfig('sharedVramChart', charts.sharedVram);
  
  // Re-attach drag listeners after charts are updated
  setTimeout(() => {
    document.querySelectorAll('.chart-container').forEach(container => {
      attachDragListeners(container);
    });
  }, 100);
};
</script>
</body>
</html>
"@

# Save HTML to file
$html | Out-File -FilePath $htmlPath -Encoding UTF8 -Force
Write-Host "Process report generated: $htmlPath"
