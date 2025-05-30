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