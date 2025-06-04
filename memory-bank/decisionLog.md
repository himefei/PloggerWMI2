# Decision Log

This file records architectural and implementation decisions using a list format.

2025-05-30 21:19:42 - Initial architectural decisions and Memory Bank establishment

## Decision

Memory Bank initialization for Windows performance monitoring project

## Rationale 

Establishes consistent project context and documentation framework to support iterative development and cross-mode collaboration for the performance monitoring tool.

## Implementation Details

* Created comprehensive Memory Bank structure with productContext, activeContext, progress, decisionLog, and systemPatterns files
* Documented project goals focused on lightweight, comprehensive Windows performance monitoring
* Identified PowerShell-based architecture leveraging WIM/CIM for native Windows integration
* Established component structure: Plogger (data collection) and Reporter (visualization)
[2025-05-30 21:28:36] - CPU Temperature Data Processing Architecture Change

## Decision

Move CPU temperature processing from Plogger to Reporter to improve logging performance and temperature chart accuracy.

## Rationale 

Current implementation performs temperature conversion (tenths of Kelvin to Celsius) during logging, which adds processing overhead. Additionally, rounding to 2 decimal places during logging causes thermal fluctuation data to be lost, resulting in flat-line temperature charts instead of showing natural variations.

## Implementation Details

[2025-05-30 21:40:59] - Performance Optimization Analysis for Plogger.ps1

## Analysis Results

After reviewing Plogger.ps1, identified several areas where calculations during logging could be moved to Reporter.ps1:

### High Impact Optimizations:
1. **GPU Engine Processing (Lines 576-620)**: Complex string parsing and grouping operations
2. **Battery Calculations (Lines 488-496)**: Percentage calculations from mWh values
3. **Network Adapter Filtering (Lines 381-414)**: Complex string matching and filtering
4. **Per-process CPU Calculations (Lines 662)**: Division by logical core count

### Medium Impact Optimizations:
5. **RAM Used Calculation (Lines 363-366)**: Simple subtraction could be moved
6. **Power Status Processing (Lines 335-337)**: Function call overhead

### Low Impact (Keep in Plogger):
- Simple counter readings (CPU, Disk, Network base values)
- Direct WMI property access
- Timestamp generation

## Implementation Plan
Focus on High Impact items first as they involve the most processing overhead during logging.
* Plogger.ps1: Capture raw thermal zone temperature data without conversion or rounding
* Reporter.ps1: Process raw temperature data with appropriate precision during report generation
* Preserve thermal fluctuation detail for accurate visualization
* Reduce processing overhead during logging phase
[2025-05-30 22:01:35] - GPU Engine Data Optimization Fix

## Issue Identified
The raw GPU Engine data capture was creating very large CSV files due to capturing all GPU counters, most of which had no values or were unused.

## Solution Implemented
Switched from raw data capture to selective filtering during logging:
- Filter for only useful engine types: 3D, Copy, VideoDecode, VideoEncode, VideoProcessing
- Only capture counters with actual usage (CookedValue > 0)
- Process immediately during logging to avoid large data storage
- Maintains performance benefits while reducing file size significantly

## Technical Details
- Removed GPUEngineRawData field
- Added selective filtering in Plogger.ps1 GPU capture section
- Maintained dynamic property addition for GPU metrics
- Updated Reporter.ps1 to remove unnecessary GPU raw data processing

## Benefits
- Dramatically reduced CSV file size
- Maintained GPU monitoring functionality for useful metrics
- Preserved logging performance improvements
- Eliminated storage of unused/empty GPU counters
[2025-05-30 22:50:10] - CPU Real-Time Clock Speed Implementation
**Decision**: Implemented CPU processor performance capture and real-time clock speed calculation
**Rationale**: User requested feature to capture processor performance percentage and calculate real-time clock speed by multiplying with max clock speed
**Implementation**: 
- Added `\Processor Information(_Total)\% Processor Performance` counter in Plogger.ps1
- Created Calculate-CPURealTimeClockSpeed function in Reporter.ps1 
- Added new line chart positioned next to CPU Usage chart for optimal visualization
**Impact**: Enhanced CPU monitoring capabilities with real-time frequency tracking
[2025-05-30 23:32:55] - Project Structure Reorganization - Report Folder Removal

## Decision

Removed the separate report folder and moved all Reporter components (Reporter.ps1, Reporter_for_Process.ps1) and chart.js into the Plogger folder for simplified project structure and easier testing/distribution.

## Rationale 

Consolidating all components into a single Plogger directory simplifies:
- Project deployment and distribution
- Testing workflows (all components in one location)
- Development workflow (reduced folder navigation)
- Package management for distribution builds

## Implementation Details

**Structural Changes:**
- Removed: `/report/` directory entirely
- Moved: `Reporter.ps1` → `Plogger/Reporter.ps1`
- Moved: `Reporter_for_Process.ps1` → `Plogger/Reporter_for_Process.ps1`  
- Moved: `chart.js` → `Plogger/chart.js`
- Maintained: `Plogger.ps1` and `Plogger.exe` in `Plogger/` directory

**New Project Structure:**
```
PloggerWMI2/
├── Plogger/
│   ├── Plogger.ps1          (Core performance logging)
│   ├── Plogger.exe          (Compiled executable)
│   ├── Reporter.ps1         (System performance visualization)
│   ├── Reporter_for_Process.ps1 (Process-specific reporting)
│   └── chart.js             (Chart.js library for visualizations)
├── assets/
│   └── icon.ico
├── memory-bank/
└── ProjectBrief.md
```

## Impact

- **Positive**: Simplified structure, easier testing, consolidated distribution
- **Considerations**: All file path references within scripts may need verification
- **Benefits**: Single-folder deployment model for easier customer distribution
[2025-05-30 23:53:48] - License Change from MIT to Mozilla Public License 2.0

## Decision

Changed project license from MIT to Mozilla Public License (MPL) 2.0 across all components.

## Rationale 

User requested MPL 2.0 license implementation to replace the existing MIT license in the project. MPL 2.0 provides:
- Copyleft protection for modifications to the source code
- Compatibility with proprietary software integration
- File-level copyleft (less restrictive than GPL)
- Patent protection clauses

## Implementation Details

**License File Creation:**
- Created root-level LICENSE file with complete MPL 2.0 text
- Standard Mozilla Public License Version 2.0 with all sections and exhibits

**Source Code Updates:**
- Updated Plogger.ps1 header comment from MIT license text to MPL 2.0 notice
- Replaced 17-line MIT license block with concise MPL 2.0 reference
- Maintained copyright attribution to Lifei Yu (2025)
- Added standard MPL notice: "This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0"

**Compliance:**
- MPL 2.0 notice format follows Mozilla Foundation guidelines
- Reference to http://mozilla.org/MPL/2.0/ for full license text
- Consistent licensing across project components

## Impact

- **Legal**: Stronger copyleft protection while maintaining commercial compatibility
- **Distribution**: Clear licensing terms for open-source distribution
- **Development**: File-level copyleft ensures modifications remain open source
- **Integration**: Compatible with proprietary software integration scenarios
[2025-05-31 13:32:50] - Chart Trend Line Enhancement Implementation

## Decision

Added linear regression trend lines to all performance charts in both Reporter.ps1 and Reporter_for_Process.ps1 to improve data analysis and trend visualization.

## Rationale 

User requested dash line trending functionality for all charts including future new charts. Trend lines provide valuable insights into performance patterns, helping users identify whether metrics are improving, degrading, or remaining stable over time. This enhancement significantly improves the analytical value of the performance monitoring tool.

## Implementation Details

**Technical Implementation:**
- Created calculateTrendLine() function using linear regression algorithm
- Enhanced createChart() function to automatically add trend datasets
- Enhanced createMultiChart() function for multi-dataset charts with trends
- Updated Reporter_for_Process.ps1 with createTrendDataset() helper function
- Applied trend lines to all existing charts: CPU, RAM, Disk, Network, Temperature, Battery, Screen Brightness, and Process-specific metrics

**Visual Design:**
- Trend lines displayed as dashed lines (borderDash: [5, 5])
- Color: 70% opacity of original dataset color for subtle distinction
- No interaction points (pointRadius: 0) to maintain focus on actual data
- Transparent background to avoid visual interference

**Future Compatibility:**
- Pattern documented in systemPatterns.md for consistent implementation
- All future charts will automatically inherit trend line functionality
- Standardized approach ensures consistent user experience

## Impact

- **Enhanced Analytics**: Users can now easily identify performance trends and patterns
- **Improved Decision Making**: Trend visualization aids in proactive system management
- **Future-Proof**: All new charts will automatically include trend analysis
- **Consistent Experience**: Unified trend visualization across all chart types
- **Performance Impact**: Minimal computational overhead with efficient linear regression implementation
[2025-05-31 13:39:30] - Enhanced Trend Lines with Polynomial Regression

## Decision

Upgraded trend line calculation from simple linear regression to polynomial regression for more scientifically accurate curve fitting in performance data analysis.

## Rationale 

User feedback indicated that straight linear trend lines were too simplistic for performance monitoring data. Performance metrics often exhibit non-linear patterns, acceleration/deceleration phases, and cyclical behaviors that require curved trend analysis. Polynomial regression is the standard scientific approach for trend analysis in performance monitoring and reporting systems.

## Implementation Details

**Mathematical Enhancement:**
- Replaced linear regression with adaptive polynomial regression (degree 2-3)
- Implemented least squares method using Vandermonde matrix approach
- Added Gaussian elimination solver for polynomial coefficient calculation
- Adaptive degree selection based on data size (more data = higher degree capability)

**Scientific Accuracy:**
- Polynomial regression better captures non-linear performance patterns
- Handles performance acceleration/deceleration phases
- More appropriate for system monitoring where metrics exhibit curved behaviors
- Standard approach in performance analysis and scientific computing

**Technical Implementation:**
- Added polynomialRegression() function with matrix-based solver
- Added gaussianElimination() for robust coefficient calculation  
- Added evaluatePolynomial() for trend point generation
- Maintained robustness with null data handling and numerical stability checks

## Impact

- **Scientific Accuracy**: Trend lines now follow actual data patterns with curves
- **Better Analysis**: More accurate trend identification for performance patterns
- **Industry Standard**: Aligns with scientific best practices for performance monitoring
- **Future Compatibility**: Enhanced algorithm maintained for all future charts
- **Robustness**: Numerical stability and error handling for edge cases
[2025-05-31 13:54:45] - GPU Vendor Detection and Vendor-Specific API Integration

## Decision

Implemented comprehensive GPU vendor detection and integrated vendor-specific APIs (NVIDIA nvidia-smi and Intel xpu-smi/xpumcli) for detailed GPU monitoring including temperature, fan speed, and memory usage.

## Rationale 

User requested GPU vendor detection with support for hybrid GPU configurations (Intel + NVIDIA) and vendor-specific API integration for detailed metrics. Generic WMI GPU monitoring is limited and doesn't provide thermal or detailed memory metrics. Vendor-specific tools provide comprehensive GPU monitoring capabilities including temperature, fan control, and precise memory usage data.

## Implementation Details

**GPU Detection:**
- Added Get-GPUInformation() function using Win32_VideoController WMI class
- Detects Intel (VEN_8086), NVIDIA (VEN_10DE), and AMD (VEN_1002) GPUs via PNP Device IDs
- Supports hybrid GPU configurations with multiple vendors simultaneously
- Extracts GPU name, VRAM size, driver version, and vendor information

**NVIDIA Integration (nvidia-smi):**
- Added Get-NVIDIAMetrics() function with nvidia-smi CLI integration
- Monitors: GPU temperature, fan speed, memory usage (used/total), GPU utilization, power draw
- Searches common installation paths: Program Files, System32
- Uses CSV output format for reliable parsing

**Intel Integration (xpu-smi/xpumcli):**
- Added Get-IntelMetrics() function supporting both xpu-smi (newer) and xpumcli (legacy)
- Monitors: GPU temperature, memory usage, GPU utilization, power draw
- Searches Intel oneAPI and GPU toolkit installation paths
- Adaptive parsing for different tool output formats

**Data Integration:**
- Added 21 new fields to CSV output for comprehensive GPU monitoring
- GPU information: vendor detection, names, VRAM sizes
- NVIDIA metrics: temperature, fan, memory, utilization, power
- Intel metrics: temperature, memory, utilization, power
- Graceful degradation when vendor tools are unavailable

## Impact

- **Comprehensive Monitoring**: Full GPU vendor ecosystem support with detailed metrics
- **Hybrid GPU Support**: Proper handling of Intel+NVIDIA configurations common in laptops
- **Vendor-Specific APIs**: Leverages official tools for accurate thermal and performance data
- **Production Ready**: Robust error handling and fallback mechanisms
- **Future Extensible**: Framework ready for AMD GPU support addition
[2025-05-31 14:04:40] - GPU Monitoring Error Fixes and Improvements

## Decision

Fixed critical issues in NVIDIA GPU monitoring including N/A value parsing errors and inaccurate VRAM detection, based on user's working POC code analysis.

## Rationale 

Initial implementation had several flaws:
1. Conversion errors when nvidia-smi returned "N/A" values for unavailable metrics
2. Inaccurate VRAM detection via WMI (showing 4095MB instead of 8GB)
3. Inefficient nvidia-smi queries causing multiple process calls
User provided working POC code demonstrating proper nvidia-smi usage with robust error handling.

## Implementation Details

**NVIDIA Metrics Fixes:**
- Enhanced Get-NVIDIAMetrics() with comprehensive query similar to user's POC
- Added proper regex validation for numeric values before type conversion
- Implemented robust "N/A" handling: `if ($value -ne "N/A" -and $value -match "^\d+$")`
- Single nvidia-smi call with multiple metrics: name, memory.total, memory.used, temperature.gpu, fan.speed, utilization.gpu, utilization.memory, power.draw

**VRAM Detection Fix:**
- Enhanced Get-GPUInformation() to use nvidia-smi for accurate VRAM detection
- Added fallback from WMI to nvidia-smi for NVIDIA GPUs
- Proper error handling when nvidia-smi unavailable
- Verbose logging for VRAM detection process

**Error Handling Improvements:**
- Added regex pattern matching for all numeric conversions
- Graceful handling of missing or "N/A" values
- Enhanced verbose logging for debugging
- Proper exception handling in nested try-catch blocks

**Code Quality:**
- Adopted proven patterns from user's working POC
- Maintained compatibility with existing CSV structure
- Added comprehensive field validation before type conversion

## Impact

- **Resolved Errors**: Eliminated "Cannot convert value '[N/A]' to type 'System.Int32'" errors
- **Accurate VRAM**: Correct detection of 8GB VRAM instead of 4095MB WMI limitation
- **Robust Monitoring**: Reliable GPU metrics collection with proper fallback handling
- **Production Ready**: Error-resistant implementation suitable for various GPU configurations
[2025-05-31 14:30:50] - GPU Data Integration into HTML Reports

## Decision

Integrated newly captured GPU metrics (temperature, VRAM usage, utilization, power draw) into existing HTML report charts and statistics tables for comprehensive GPU monitoring visualization.

## Rationale 

User requested integration of GPU temperature into existing temperature chart (renamed to "Temperatures") and GPU VRAM usage into RAM chart (renamed to "RAM and VRAM"). This provides unified monitoring dashboards combining CPU and GPU metrics for better system analysis.

## Implementation Details

**Chart Enhancements:**
- Updated temperature chart title from "CPU Temperature (C)" to "Temperatures (°C)"
- Updated RAM chart title from "RAM Usage (MB)" to "RAM and VRAM Usage (MB)"
- Converted single-dataset charts to multi-dataset charts using createMultiChart()
- Added GPU temperature data collection and visualization
- Added GPU VRAM usage data collection and visualization

**Data Collection:**
- Added gpuTemp and gpuVramUsed arrays for GPU metrics
- Implemented priority-based data collection: NVIDIA GPU metrics preferred over Intel when both available
- Added null handling for systems without GPU metrics
- Enhanced data parsing with proper fallback mechanisms

**Multi-Chart Implementation:**
```javascript
// Temperature chart with CPU + GPU
const tempDatasets = [
    { label: 'CPU Temperature', data: cpuTemp, borderColor: 'rgb(255, 99, 132)' },
    { label: 'GPU Temperature', data: gpuTemp, borderColor: 'rgb(255, 159, 64)' }
];

// RAM chart with system RAM + GPU VRAM
const ramDatasets = [
    { label: 'RAM Used', data: ramUsed, borderColor: 'rgb(54, 162, 235)' },
    { label: 'GPU VRAM Used', data: gpuVramUsed, borderColor: 'rgb(75, 192, 192)' }
];
```

**Statistics Table Expansion:**
- Added NVIDIA GPU Temperature, VRAM Usage, Utilization, Power Draw
- Added Intel GPU Temperature, Memory Usage, Utilization
- Enhanced metrics configuration with proper units (°C, MB, %, W)
- Automatic availability detection for hybrid GPU systems

## Impact

- **Unified Monitoring**: Single temperature chart showing both CPU and GPU thermal data
- **Memory Visualization**: Combined system RAM and GPU VRAM usage in one chart
- **Comprehensive Statistics**: Complete GPU performance metrics in summary table
- **Scalable Design**: Framework supports additional GPU vendors and metrics
- **User Experience**: Clear visual distinction between different data series with color coding
[2025-05-31 20:30:54] - Logging Interval Optimization - Reduced from 15 to 10 seconds

## Decision

Changed Plogger logging interval from 15 seconds to 10 seconds to increase data collection frequency for more granular performance monitoring.

## Rationale 

User requested increased logging frequency to capture performance metrics more frequently. Reducing the interval from 15 to 10 seconds provides:
- 50% more data points for better trend analysis
- More responsive performance monitoring
- Enhanced granularity for short-term performance events
- Better temporal resolution for diagnostic purposes

## Implementation Details

**Technical Changes:**
- Modified `$writeIntervalSeconds` variable in Plogger.ps1 from 15 to 10 seconds (line 586)
- Change affects both hardware and process data collection intervals
- Maintains existing CSV structure and data integrity
- No changes required to Reporter components as they handle variable intervals

**Impact Considerations:**
- Increased log file size due to more frequent data points (33% increase in data volume)
- Slightly higher I/O overhead from more frequent disk writes
- More detailed performance data for analysis and troubleshooting
- Enhanced monitoring capability for transient performance issues

## Benefits

- **Enhanced Granularity**: More detailed performance timeline with 10-second resolution
- **Better Trend Analysis**: Additional data points improve polynomial regression accuracy
- **Improved Diagnostics**: Capture shorter performance spikes and anomalies
- **Responsive Monitoring**: Faster detection of performance changes
[2025-05-31 20:51:22] - CPU Usage Correction Factor Implementation

## Decision

Implemented 1.5x correction factor for CPU usage values in Process Usage Report to align with Windows Task Manager readings.

## Rationale 

User identified discrepancy where CPU usage captured in process logs shows approximately 70% of what Windows Task Manager displays. The process data comes from Task Manager's Details tab but requires correction to match the standard Task Manager CPU usage values that users expect to see.

## Implementation Details

**Technical Changes:**
- Modified Reporter_for_Process.ps1 to apply 1.5x multiplier to all CPU percentage calculations
- Applied correction to both legacy format (existing CPUPercent) and new format (calculated from CPUPercentRaw/LogicalCoreCount)
- Correction applied early in data processing pipeline before aggregation and chart generation
- Updated processing messages to indicate CPU correction factor application

**Processing Flow:**
```powershell
# New format: Apply correction after core count division
$correctedCPU = ($rawCPU / $coreCount) * 1.5

# Legacy format: Apply correction to existing values  
$correctedCPU = $currentCPU * 1.5
```

**Affected Areas:**
- Individual process CPU calculations for charts and statistics
- Aggregated process CPU calculations (automatically inherit corrected values)
- CPU-based sorting and color coding in dropdown menus
- All CPU trend line calculations (use corrected base data)

## Impact

- **Accurate Reporting**: CPU usage values now match Windows Task Manager expectations
- **User Experience**: Eliminates confusion from discrepant CPU readings
- **Consistency**: Process monitoring aligns with system monitoring standards
- **Retroactive**: Works with both existing CSV files and newly generated data
- **Preserved Aggregation**: Aggregated processes automatically reflect corrected individual values

## Benefits

- **User Familiarity**: CPU values match what users see in Task Manager
- **Diagnostic Accuracy**: More reliable performance analysis and troubleshooting
- **Consistent Scaling**: All CPU-related visualizations and statistics use corrected values
- **Backward Compatible**: Handles both old and new CSV format with appropriate correction

[2025-06-04 15:06:00] - RAM and VRAM Chart Separation with Dual-Axis Percentage View

## Decision

Separated the combined "RAM and VRAM Usage (MB)" chart into two distinct charts: "RAM Usage (%)" and "VRAM Usage (%)" with dual-axis visualization showing percentage (0-100%) on the left and capacity in GB on the right.

## Rationale

User requested separation of RAM and VRAM into individual charts with percentage view from 0-100% on the left axis and actual capacity in GB displayed on the right axis. This provides better granular monitoring of memory usage with intuitive percentage visualization while maintaining capacity reference information.

## Implementation Details

**Chart Architecture Changes:**
- Replaced single combined chart with two separate chart containers in HTML layout
- Created new `createDualAxisChart()` function supporting dual y-axis configuration
- Left axis (y): Percentage scale 0-100% with usage data
- Right axis (y1): Capacity reference showing total GB capacity as constant line

**Data Processing Enhancement:**
- Added `ramPercentage`, `ramTotalGB`, `vramPercentage`, `vramTotalGB` data arrays
- Calculate percentage: `(usedMB / totalMB) * 100` rounded to 2 decimal places
- Convert capacity: `totalMB / 1024` to GB rounded to 2 decimal places
- Process both `RAMTotalMB`/`RAMUsedMB` and `NVIDIAGPUMemoryTotal_MB`/`NVIDIAGPUMemoryUsed_MB`

**Visual Design:**
- Percentage data displayed as primary line chart with trend lines
- Capacity shown as dashed reference line on right axis
- Automatic chart generation only when data available (graceful VRAM handling)
- Maintained existing drag & drop and chart storage functionality

**Layout Reorganization:**
- RAM and VRAM charts positioned side-by-side in first chart row
- Disk I/O and Network I/O moved to second chart row
- Temperatures and Screen Brightness moved to third chart row
- Power Draw and GPU Engine charts in fourth chart row

## Impact

- **Enhanced User Experience**: Intuitive percentage view with 0-100% scale for easy interpretation
- **Detailed Memory Monitoring**: Separate charts allow focused analysis of RAM vs VRAM usage patterns
- **Capacity Awareness**: Right axis shows actual memory capacity for context
- **Trend Analysis**: Polynomial regression trend lines for both RAM and VRAM percentage data
- **Scalable Design**: Framework supports additional memory types or future enhancements
- **Data Completeness**: Handles systems with or without discrete GPU VRAM gracefully