# Product Context

## Why this project exists
Many system performance logging tools rely on external libraries or require complex setups. This project aims to provide a lightweight, portable solution that leverages only native Windows WMI and CIM interfaces for collecting system performance data.

## Problems it solves
- Enables system administrators and users to log detailed performance metrics without installing third-party monitoring software.
- Provides a consistent, scriptable way to export system metrics to CSV for further analysis.
- Facilitates troubleshooting and diagnostics by generating clear, interactive HTML reports from the collected data.

## How it should work
- The user runs Plogger.ps1 (or its compiled EXE) to collect system metrics using WMI/CIM and exports the results to CSV files.
- The user then runs Reporter.ps1 or Reporter_for_Process.ps1 to generate HTML reports from the CSV files.
- The workflow is designed to be simple, requiring minimal user interaction and no dependencies beyond PowerShell and standard Windows components.

## User experience goals
- Easy to execute for both scripts and compiled EXEs.
- Clear prompts and error messages.
- Output files (CSV and HTML) are easy to locate and interpret.
- Reports are visually clear and provide actionable insights.
