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