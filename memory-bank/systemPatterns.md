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