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
[2025-05-31 13:32:50] - Chart Trend Line Visualization Pattern
**Pattern**: All line charts automatically include dashed trend lines calculated using linear regression
**Implementation**:
- Added calculateTrendLine() function for linear regression analysis of chart data
- Enhanced createChart() and createMultiChart() functions to automatically add trend datasets
- Trend lines displayed as dashed lines with 70% opacity of the original color
- Applied to both system monitoring (Reporter.ps1) and process monitoring (Reporter_for_Process.ps1)
**Features**:
- Automatic trend calculation for all valid data points
- Visual distinction using borderDash: [5, 5] pattern
- Transparent background to avoid interference with main data
- Zero interaction points (pointRadius: 0) to maintain focus on main data
**Benefits**: Enhanced data analysis capabilities, improved trend identification, better performance pattern recognition
**Template**:
```javascript
// Calculate trend line
const trendData = calculateTrendLine(data);
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