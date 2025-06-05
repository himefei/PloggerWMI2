# System Patterns

This file documents recurring patterns and standards used in the project.
It is optional, but recommended to be updated as the project evolves.

2025-05-30 21:19:51 - Initial system patterns documentation for Windows performance monitoring tool

## Coding Patterns

* PowerShell-based implementation for native Windows integration
* WIM/CIM API utilization for system data access
* Component-based architecture (Plogger for collection, Reporter for visualization)
* Lightweight design principles to minimize system impact

## Architectural Patterns

* Separation of concerns: data collection vs. visualization/reporting
* Windows Management Instrumentation (WMI) integration pattern
* File-based component organization (separate directories for distinct functionality)
* Asset management for supporting files (icons, resources)

## Testing Patterns

* Customer system deployment considerations
* Performance impact validation requirements
* Accuracy verification for collected metrics
* Cross-system compatibility testing patterns
[2025-05-30 23:07:14] - Chart Layout Standardization
**Pattern**: All charts in Reporter.ps1 should use consistent half-width layout
**Implementation**: 
- Charts are organized in chart-row divs with chart-half containers
- Each chart-half uses 48% width with responsive design (100% width on screens <1200px)
- Standard chart-container styling with consistent dimensions (height: 400px)
- GPU Engine chart moved from full-width to half-width for consistency
**Benefit**: Consistent visual layout, better space utilization, uniform user experience
**Template**: 
```html
<div class="chart-row">
    <div class="chart-half">
        <div class="chart-container">
            <div class="chart-title">Chart Title</div>
            <canvas id="chartId"></canvas>
        </div>
    </div>
    <div class="chart-half">
        <div class="chart-container">
            <div class="chart-title">Chart Title</div>
            <canvas id="chartId2"></canvas>
        </div>
    </div>
</div>
```
[2025-05-30 23:12:47] - Drag & Drop Chart Functionality Implementation
**Pattern**: Interactive chart rearrangement using HTML5 drag and drop API
**Implementation**:
- Added draggable="true" attribute to all chart containers
- CSS classes for visual feedback: .dragging, .drag-over, hover effects
- JavaScript event handlers: dragstart, dragend, dragover, dragleave, drop
- Dynamic event listener reattachment after DOM manipulation
- User instructions banner for discoverability

**Key Features**:
- Visual feedback during drag (opacity, rotation, border highlighting)
- Automatic chart swapping between positions
- Maintains chart functionality after rearrangement
- Responsive design preservation
- Cross-browser HTML5 drag and drop support

**Technical Details**:
- Uses cloneNode(true) and replaceChild() for DOM manipulation
- attachDragListeners() function for reusable event binding
- setTimeout() delay for chart re-initialization after updates
- User-select: none on titles to prevent text selection during drag

**Applied to**: Both Reporter.ps1 and Reporter_for_Process.ps1
**Benefit**: Enhanced user experience allowing custom chart arrangements for comparative analysis
[2025-05-30 23:33:19] - Consolidated Project Structure Pattern
**Pattern**: Single-folder deployment architecture
**Implementation**: 
- All core components consolidated in Plogger/ directory
- Eliminated separate report/ folder for simplified structure
- Components: Plogger.ps1 (logging), Reporter.ps1 (system viz), Reporter_for_Process.ps1 (process viz), chart.js (library)
- Single-directory model enables easier testing, distribution, and deployment
**Benefit**: Simplified project structure, reduced complexity, easier customer deployment
**Structure**:
```
Plogger/
├── Plogger.ps1              # Core performance logging
├── Plogger.exe              # Compiled executable  
├── Reporter.ps1             # System performance visualization
├── Reporter_for_Process.ps1 # Process-specific reporting
└── chart.js                 # Chart.js visualization library
```
[2025-05-31 13:39:30] - Scientific Polynomial Regression Trend Line Pattern
**Pattern**: All line charts automatically include curved trend lines calculated using polynomial regression for scientific accuracy
**Implementation**:
- Added calculateTrendLine() function using adaptive polynomial regression (degree 2-3)
- Implemented polynomialRegression() with least squares method and Vandermonde matrix approach
- Added gaussianElimination() solver for robust coefficient calculation
- Enhanced createChart() and createMultiChart() functions to automatically add curved trend datasets
- Trend lines displayed as dashed curves with 70% opacity of the original color
- Applied to both system monitoring (Reporter.ps1) and process monitoring (Reporter_for_Process.ps1)
**Mathematical Features**:
- Polynomial regression using least squares method for optimal curve fitting
- Adaptive degree selection based on data size (minimum degree 2, maximum degree 3)
- Gaussian elimination for numerically stable coefficient solving
- Handles non-linear performance patterns, acceleration/deceleration phases
**Visual Features**:
- Curved trend lines that follow actual data patterns
- Visual distinction using borderDash: [5, 5] pattern
- Transparent background to avoid interference with main data
- Zero interaction points (pointRadius: 0) to maintain focus on main data
**Benefits**: Scientifically accurate trend analysis, better curve fitting for performance data, industry-standard approach for monitoring systems
**Template**:
```javascript
// Calculate polynomial trend line
const trendData = calculateTrendLine(data); // Uses polynomial regression
const trendDataset = {
    label: label + ' Trend',
    data: trendData,
    borderColor: color.replace('rgb', 'rgba').replace(')', ', 0.7)'),
    backgroundColor: 'transparent',
    borderWidth: 2,
    borderDash: [5, 5],
    tension: 0,
    pointRadius: 0
};
```
[2025-05-31 13:54:45] - GPU Vendor Detection and Monitoring Pattern
**Pattern**: Multi-vendor GPU detection with vendor-specific API integration for comprehensive monitoring
**Implementation**:
- Get-GPUInformation() function for WMI-based vendor detection using Win32_VideoController
- Vendor identification via PNP Device IDs (Intel: VEN_8086, NVIDIA: VEN_10DE, AMD: VEN_1002)
- Get-NVIDIAMetrics() function using nvidia-smi CLI with CSV output parsing
- Get-IntelMetrics() function supporting xpu-smi/xpumcli tools with adaptive parsing
- Hybrid GPU configuration support for Intel+NVIDIA systems
**Features**:
- Automatic vendor tool detection across common installation paths
- Robust error handling with graceful degradation when tools unavailable
- Comprehensive metrics: temperature, fan speed, memory usage, utilization, power draw
- CSV integration with 21 new GPU-related fields
- Vendor-agnostic framework extensible for additional GPU vendors
**Benefits**: Detailed thermal monitoring, precise memory tracking, vendor-optimized data collection, hybrid GPU support
**Template**:
```powershell
# GPU Detection and Monitoring
$gpuInfo = Get-GPUInformation
$nvidiaMetrics = Get-NVIDIAMetrics -GPUInfo $gpuInfo
$intelMetrics = Get-IntelMetrics -GPUInfo $gpuInfo
# Data integration with null handling
GPUVendorMetric = if ($metrics -and $metrics.Available) { $metrics.Value } else { $null }
```

[2025-05-31 16:22:00] - Emoji and Special Character Encoding Fix
**Problem**: Emojis display as garbled characters like "ðŸ"Š" in HTML reports, temperature symbols show as "Â°C" instead of "°C"
**Root Causes**:
- PowerShell console not set to UTF-8 encoding
- Direct emoji characters in source code get corrupted during processing
- `Out-File -Encoding UTF8` adds BOM which can cause display issues
- Temperature degree symbol (°) gets double-encoded

**Complete Solution**:
1. **Set Console Encoding** (at script start):
```powershell
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
```

2. **Replace Direct Characters with HTML Entities**:
- Emoji `📊` → `&#128202;`
- Emoji `📈` → `&#128200;`
- Emoji `🔄` → `&#128260;`
- Temperature `°C` → `&#176;C`

3. **Use Proper File Writing**:
```powershell
# Instead of: $html | Out-File -FilePath $path -Encoding UTF8
# Use: [System.IO.File]::WriteAllText($path, $html, [System.Text.UTF8Encoding]::new($false))
```

4. **HTML Meta Tag** (ensure present):
```html
<meta charset="UTF-8">
```

**Fixed Locations**:
- Reporter.ps1: Console encoding, temperature units, drag & drop emoji, file writing
- Reporter_for_Process.ps1: Console encoding, drag & drop emoji, file writing

**Benefit**: Proper display of emojis and special characters across all browsers, professional appearance of HTML reports
[2025-06-05 11:19:00] - Robust Power Overlay Detection Pattern
**Pattern**: Multi-tier fallback system for power overlay detection with silent error handling
**Implementation**: 
- Three-method detection strategy: standard registry properties → alternative registry locations → WMI/CIM fallback
- Property name variant checking for different system configurations and common typos
- Silent error handling with try-catch blocks that don't output warnings to maintain clean logging
- Alternative registry path checking for custom SOE configurations
- Pattern-based GUID detection in non-standard registry locations
- Descriptive fallback values instead of generic error messages

**Key Features**:
- Method 1: Multiple property name variants (ActiveOverlayAcPowerScheme, ActivatOverlayAcPowerScheme, ActiveAcOverlay, ActiveOverlay)
- Method 2: Alternative registry paths (PowerSettings, FlyoutMenuSettings, Explorer Preferences)
- Method 3: WMI/CIM power scheme detection for final fallback
- Property existence validation before registry access to prevent exceptions
- GUID pattern matching for detecting power schemes in unexpected locations
- Silent degradation through all methods without verbose error reporting

**Error Handling Strategy**:
- Replace Write-Warning with silent try-catch blocks
- Use descriptive fallback values ("Not Available", "Standard", "Customer SOE Power Scheme")
- Graceful degradation that doesn't interrupt logging performance
- Property existence checking before access to prevent PropertyNotFoundException

**Benefits**: Clean logging output, enhanced system compatibility, SOE configuration support, maintained efficiency
**Applied to**: Get-PowerStatusMetrics function in Plogger.ps1
**Use Case**: Systems without Lenovo power management drivers, custom enterprise configurations, varying Windows installations
[2025-06-05 14:42:00] - Version Management System for Plogger Project
## Version Number Management Instructions

### Current Version: 2.0.0

### Version Format: X.Y.Z (Semantic Versioning)
- **X (Major Version)**: Manual decision by project owner based on release schedule and significant milestones
- **Y (Minor Version)**: New features, major enhancements, significant functionality additions (increment by 0.1.0)
- **Z (Patch Version)**: Small changes, minor updates, bug fixes (increment by 0.0.1)

### Version Update Rules
1. **Bug Fixes & Small Updates**: Increment patch version (e.g., 2.0.0 → 2.0.1)
   - Temperature calibration adjustments
   - Minor UI improvements
   - Small performance optimizations
   - Documentation updates

2. **New Features & Major Enhancements**: Increment minor version (e.g., 2.0.0 → 2.1.0)
   - New monitoring capabilities
   - Additional chart types
   - New GPU vendor support
   - Significant algorithm improvements

3. **Major Releases**: Project owner decision for major version increment (e.g., 2.0.0 → 3.0.0)
   - Complete feature overhauls
   - Breaking changes
   - Major architecture changes
   - Release milestones

### Implementation Instructions
- **Location**: Update version number in header comment of `Plogger/Plogger.ps1`
- **Format**: `# Version: X.Y.Z`
- **Line**: Should be placed on line 3 after the project description
- **Update Requirement**: Every commit that introduces changes should update the version number appropriately

### Version Update Process
1. Identify change type (bug fix, new feature, or major release)
2. Update version number in `Plogger/Plogger.ps1` header comment
3. Document the change in memory bank progress or decision log
4. Include version change in commit message

### Examples of Version Increments
- **2.0.0 → 2.0.1**: Fixed temperature calibration range from 60-97°C to 85-97°C
- **2.0.0 → 2.1.0**: Added AMD GPU monitoring support
- **2.0.0 → 3.0.0**: Complete rewrite with new architecture (project owner decision)

### Current Version History
- **2.0.0**: Initial version with enhanced CPU temperature calibration system and 105°C fixed chart scaling