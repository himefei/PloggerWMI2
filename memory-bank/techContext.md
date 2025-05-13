# Technical Context

## Technologies Used
- PowerShell (for all scripts)
- Windows Management Instrumentation (WMI) and CIM (for system data collection)
- CSV (Comma-Separated Values) for data export and interchange
- HTML, CSS, JavaScript (for report generation)
- Chart.js (for interactive charts in HTML reports)

## Development Setup
- Standard Windows environment with PowerShell 5.1+ or PowerShell Core
- No external dependencies required for logging (WMI/CIM are built-in)
- Reporter scripts require Chart.js (bundled locally in the Reporter directory)

## Technical Constraints
- All system data collection must use WMI and CIM only (no external DLLs or libraries)
- Scripts must work both as .ps1 and when compiled to .exe (using ps2exe)
- Output CSV schema must remain stable for compatibility with reporting scripts

## Dependencies
- Native Windows PowerShell and WMI/CIM providers
- Chart.js (local file) for HTML report visualization
