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

# Validate columns
$req = 'Timestamp','ProcessName','CPUPercent','RAM_MB','IOReadBytesPerSec','IOWriteBytesPerSec','GPUDedicatedMemoryMB','GPUSharedMemoryMB'
$missing = $req | Where-Object { -not $data[0].PSObject.Properties.Name.Contains($_) }
if ($missing) { Write-Error "Missing columns: $($missing -join ', ')"; exit }

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

foreach ($processName in $uniqueProcesses) {
    $procEntry = $processList[$processName]
    $count = $procEntry.Count
    if ($count -eq 0) { continue } # Skip if no data points

    # Calculate Averages
    $avgCPU = $procEntry.CPUSum / $count
    $avgRAM = $procEntry.RAMSum / $count
    $avgDedicatedVRAM = $procEntry.DedicatedVRAMSum / $count
    $avgSharedVRAM = $procEntry.SharedVRAMSum / $count
    
    # Format the averages
    $avgCPUFormatted = [math]::Round($avgCPU, 2)
    $avgRAMFormatted = [math]::Round($avgRAM, 2)
    $avgDedicatedVRAMFormatted = [math]::Round($avgDedicatedVRAM, 2)
    $avgSharedVRAMFormatted = [math]::Round($avgSharedVRAM, 2)

    # Build stats objects (using ArrayList.Add is faster than +=)
    [void]$processStats.Add([PSCustomObject]@{
        Name   = $processName
        AvgCPU = $avgCPUFormatted
        Color  = if ($avgCPU -gt 30) {'rgb(190, 0, 0)'}
                 elseif ($avgCPU -ge 10) {'rgb(255, 204, 0)'}
                 else {'rgb(0, 130, 0)'}
    })
    
    [void]$ramStats.Add([PSCustomObject]@{
        Name   = $processName
        AvgRAM = $avgRAMFormatted
    })
    
    [void]$vramStatsDedicated.Add([PSCustomObject]@{
        Name = $processName
        AvgDedicatedVRAM = $avgDedicatedVRAMFormatted
        Color = if ($avgDedicatedVRAM -gt 300) {'rgb(190, 0, 0)'}
                elseif ($avgDedicatedVRAM -ge 100) {'rgb(255, 204, 0)'}
                else {'rgb(0, 130, 0)'}
    })
    
    [void]$vramStatsShared.Add([PSCustomObject]@{
        Name = $processName
        AvgSharedVRAM = $avgSharedVRAMFormatted
    })

    # --- Prepare data for $processData JSON ---
    # We need the individual data points for the charts
    $timestamps = $procEntry.RawData.Keys | Sort-Object
    
    $cpuPoints = $timestamps | ForEach-Object {
        $ts = $_
        if ($procEntry.RawData.Contains($ts)) { [double]$procEntry.RawData[$ts].CPUPercent } else { $null }
    }
    
    $ramPoints = $timestamps | ForEach-Object {
        $ts = $_
        if ($procEntry.RawData.Contains($ts)) { [double]$procEntry.RawData[$ts].RAM_MB } else { $null }
    }
    
    $readIOPoints = $timestamps | ForEach-Object {
        $ts = $_
        if ($procEntry.RawData.Contains($ts)) { [double]$procEntry.RawData[$ts].IOReadBytesPerSec } else { $null }
    }
    
    $writeIOPoints = $timestamps | ForEach-Object {
        $ts = $_
        if ($procEntry.RawData.Contains($ts)) { [double]$procEntry.RawData[$ts].IOWriteBytesPerSec } else { $null }
    }
    
    $dedicatedVRAMPoints = $timestamps | ForEach-Object {
        $ts = $_
        if ($procEntry.RawData.Contains($ts)) { [double]$procEntry.RawData[$ts].GPUDedicatedMemoryMB } else { $null }
    }
    
    $sharedVRAMPoints = $timestamps | ForEach-Object {
        $ts = $_
        if ($procEntry.RawData.Contains($ts)) { [double]$procEntry.RawData[$ts].GPUSharedMemoryMB } else { $null }
    }

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
$processStats = $processStats | Sort-Object AvgCPU -Descending
$ramStats = $ramStats | Sort-Object AvgRAM -Descending
$vramStatsDedicated = $vramStatsDedicated | Sort-Object AvgDedicatedVRAM -Descending
$vramStatsShared = $vramStatsShared | Sort-Object AvgSharedVRAM -Descending

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
</style>
</head>
<body>
  <div class="header">
    <h1>Process Usage Report</h1>
    <h2>Source File: $(Split-Path $csvPath -Leaf)</h2>
  </div>

  <div class="controls">
    <label for="processSelect">Select Process:</label>
    <select id="processSelect"><option value="">Sort by average CPU usage</option></select>
    <label for="processSelectRam">Select by AvgRAM:</label>
    <select id="processSelectRam"><option value="">Sort by average RAM usage</option></select>
    <label for="processSelectVram">Select by Dedicated VRAM:</label>
    <select id="processSelectVram"><option value="">Sort by average Dedicated VRAM</option></select>
    <label for="processSelectVramShared">Select by Shared VRAM:</label>
    <select id="processSelectVramShared"><option value="">Sort by average Shared VRAM</option></select>
  </div>
  
  <!-- Charts container, hidden until selection -->
  <div id="chartsContainer" style="display:none;">
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
          <div class="chart-title">Disk Read (Bytes/sec)</div>
          <canvas id="readChart"></canvas>
        </div>
      </div>
      <div class="chart-half">
        <div class="chart-container">
          <div class="chart-title">Disk Write (Bytes/sec)</div>
          <canvas id="writeChart"></canvas>
        </div>
      </div>
    </div>
    
    <div class="chart-row">
      <div class="chart-half">
        <div class="chart-container">
          <div class="chart-title">Dedicated VRAM (MB)</div>
          <canvas id="dedicatedVramChart"></canvas>
        </div>
      </div>
      <div class="chart-half">
        <div class="chart-container">
          <div class="chart-title">Shared VRAM (MB)</div>
          <canvas id="sharedVramChart"></canvas>
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
  o.text = p.Name + ' (' + p.AvgCPU + '%)';
  o.style.color = p.Color;
  sel.appendChild(o);
});
// Populate RAM dropdown using existing element
const ramList = $ramListJson;
const ramSel = document.getElementById('processSelectRam');
// Reset and add default option
ramSel.innerHTML = '<option value="">Sort by average RAM usage</option>';
// Add options with color coding
ramList.forEach(p => {
  const o2 = document.createElement('option');
  o2.value = p.Name;
  o2.text = p.Name + ' (' + p.AvgRAM + 'MB)';
  if (p.AvgRAM > 1000) o2.style.color = 'rgb(190, 0, 0)';
  else if (p.AvgRAM >= 300) o2.style.color = 'rgb(255, 204, 0)';
  else o2.style.color = 'rgb(0, 130, 0)';
  ramSel.appendChild(o2);
});
// Populate VRAM dropdown
const vramListDedicated = $vramDedicatedJson;
const vramSel = document.getElementById('processSelectVram');
// Reset and add default option
vramSel.innerHTML = '<option value="">Sort by average Dedicated VRAM</option>';
// Add options with color coding based on VRAM thresholds
vramListDedicated.forEach(p => {
  const o3 = document.createElement('option');
  o3.value = p.Name;
  o3.text = p.Name + ' (' + p.AvgDedicatedVRAM + 'MB)';
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
vramSharedSel.innerHTML = '<option value="">Sort by average Shared VRAM</option>';
// Add options with color coding based on VRAM thresholds
vramListShared.forEach(p => {
  const o4 = document.createElement('option');
  o4.value = p.Name;
  o4.text = p.Name + ' (' + p.AvgSharedVRAM + 'MB)';
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
  
  // render all charts with enhanced styling
  charts.cpu = new Chart(document.getElementById('cpuChart').getContext('2d'), {
    type: 'line',
    data: {
      labels,
      datasets: [createDataset(processName, d.CPU, 'rgb(255, 99, 132)')]
    },
    options: chartOptions
  });
  
  charts.ram = new Chart(document.getElementById('ramChart').getContext('2d'), {
    type: 'line',
    data: {
      labels,
      datasets: [createDataset(processName, d.RAM, 'rgb(54, 162, 235)')]
    },
    options: chartOptions
  });
  
  charts.read = new Chart(document.getElementById('readChart').getContext('2d'), {
    type: 'line',
    data: {
      labels,
      datasets: [createDataset(processName, d.ReadIO, 'rgb(75, 192, 192)')]
    },
    options: chartOptions
  });
  
  charts.write = new Chart(document.getElementById('writeChart').getContext('2d'), {
    type: 'line',
    data: {
      labels,
      datasets: [createDataset(processName, d.WriteIO, 'rgb(255, 159, 64)')]
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
</script>
</body>
</html>
"@

# Save HTML to file
$html | Out-File -FilePath $htmlPath -Encoding UTF8 -Force
Write-Host "Process report generated: $htmlPath"
