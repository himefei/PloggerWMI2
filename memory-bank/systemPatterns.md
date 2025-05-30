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