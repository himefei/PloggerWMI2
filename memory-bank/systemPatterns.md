# System Patterns

## System Architecture
- PowerShell-based logging and reporting system.
- Data collection is performed by Plogger.ps1 using only WMI and CIM interfaces.
- Data is exported in CSV format for portability and ease of analysis.
- HTML reports are generated from CSV using Reporter.ps1 and Reporter_for_Process.ps1.

## Key Technical Decisions
- No external libraries or dependencies for logging; only native Windows WMI/CIM.
- Robust script/EXE path detection to support both script and compiled EXE execution.
- Consistent CSV schema to ensure compatibility with reporting scripts.
- HTML reports use Chart.js for interactive data visualization.

## Design Patterns in Use
- Separation of concerns: Logging and reporting are handled by distinct scripts.
- Data pipeline: WMI/CIM → CSV → HTML.
- Modular reporting: Reporter scripts can be extended or replaced without changing the logger.

## Component Relationships
- Plogger.ps1 (or EXE) → generates CSV files.
- Reporter.ps1 and Reporter_for_Process.ps1 → consume CSV files and generate HTML reports.
- All scripts are designed to work independently but follow a common data format.
