# Product Context

This file provides a high-level overview of the project and the expected product that will be created. Initially it is based upon projectBrief.md (if provided) and all other available project-related information in the working directory. This file is intended to be updated as the project evolves, and should be used to inform all other modes of the project's goals and context.

2025-05-30 21:19:07 - Initial Memory Bank creation based on ProjectBrief.md

## Project Goal

Create a lightweight tool that can capture comprehensive Windows PC performance metrics and generate a visualized report using WIM/CIM and existing Windows modules.

## Key Features

* Performance metrics capture using WIM/CIM APIs
* Comprehensive system monitoring capabilities  
* Lightweight design for minimal system impact
* Accurate data collection from customer systems
* Visualized report generation
* Utilizes existing Windows modules and infrastructure

## Overall Architecture

* **Plogger Directory**: Consolidated single-folder structure containing all components
  * **Plogger.ps1**: Core performance logging functionality (PowerShell-based)
  * **Reporter.ps1**: System performance data visualization and report generation
  * **Reporter_for_Process.ps1**: Process-specific performance reporting
  * **chart.js**: Chart.js visualization library for HTML reports
  * **Plogger.exe**: Compiled executable version
* **Assets**: Supporting files including application icon
* **WIM/CIM Integration**: Leverages Windows Management Instrumentation for system data access
* **PowerShell Foundation**: Built on PowerShell for native Windows integration
* **Single-Folder Deployment**: Simplified structure for easier testing and distribution

[2025-05-30 23:33:38] - Updated architecture to reflect consolidated Plogger/ directory structure