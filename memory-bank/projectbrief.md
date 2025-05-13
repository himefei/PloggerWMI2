# Project Name: PloggerWMI

## Primary Goal
This project purely uses WMI and CIM for system performance logging and exports data in CSV format. It then uses Reporter.ps1 and Reporter_for_Process.ps1 to generate HTML reports from the CSV data.

## Key High-Level Requirements
- Enhance Plogger.ps1 with robust script/EXE path detection.
- Incorporate additional WMI-based logging capabilities into Plogger.ps1 from sample/Plogger.ps1, focusing on WMI-only features.
- Update Reporter.ps1 using sample/Reporter.ps1 as a base for more advanced HTML reporting.
- Ensure data compatibility between the CSV output of Plogger.ps1 and the input expected by Reporter.ps1.
- The system must function correctly when Plogger.ps1 is compiled into an executable.
