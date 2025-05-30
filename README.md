# PloggerWMI2 - Windows Performance Monitor

A lightweight Windows performance monitoring tool that captures comprehensive system metrics using WMI/CIM and generates interactive visualized reports.

## 🎯 Project Overview

PloggerWMI2 is designed to provide accurate and comprehensive performance logging from Windows systems with minimal system impact. Built entirely with PowerShell and native Windows modules, it offers real-time monitoring and detailed reporting capabilities for system administrators and performance analysts.

## ✨ Key Features

- **Comprehensive Metrics Collection**: CPU usage, memory, disk I/O, network, GPU utilization, temperature monitoring, and process-level analysis
- **Real-time CPU Clock Speed**: Captures processor performance percentage and calculates real-time clock speeds
- **Interactive Visualizations**: HTML reports with Chart.js-powered interactive charts
- **Drag & Drop Interface**: Rearrange charts for custom comparison layouts
- **Lightweight Design**: Minimal system impact during data collection
- **Native Windows Integration**: Uses WMI/CIM APIs and existing Windows modules
- **Dual Reporting Modes**: System-wide performance and process-specific analysis
- **Temperature Monitoring**: Accurate thermal zone monitoring with preserved fluctuation details

## 🏗️ Architecture

### Single-Folder Deployment Structure
```
Plogger/
├── Plogger.ps1              # Core performance logging engine
├── Plogger.exe              # Compiled executable version
├── Reporter.ps1             # System performance visualization
├── Reporter_for_Process.ps1 # Process-specific reporting
└── chart.js                 # Chart.js visualization library
```

### Component Responsibilities

- **Plogger.ps1**: Core data collection using WMI/CIM performance counters
- **Reporter.ps1**: System-wide performance analysis and HTML report generation
- **Reporter_for_Process.ps1**: Process-level performance monitoring and visualization
- **chart.js**: Interactive charting library for web-based reports

## 🚀 Quick Start

### Prerequisites
- Windows 10/11 or Windows Server 2016+
- PowerShell 5.1 or later
- Administrator privileges (recommended for full system access)

### Basic Usage

1. **Data Collection**:
   ```powershell
   .\Plogger\Plogger.ps1
   ```

2. **Generate System Report**:
   ```powershell
   .\Plogger\Reporter.ps1
   ```

3. **Generate Process Report**:
   ```powershell
   .\Plogger\Reporter_for_Process.ps1
   ```

## 📊 Monitoring Capabilities

### System Metrics
- **CPU**: Usage percentage, real-time clock speeds, processor performance
- **Memory**: RAM usage, available memory
- **Storage**: Disk I/O operations, read/write speeds
- **Network**: Adapter utilization, bandwidth usage
- **GPU**: Engine utilization across 3D, Copy, Video processing
- **Thermal**: CPU temperature monitoring with high precision
- **Power**: Battery status and power consumption (laptops)

### Process Metrics
- Per-process CPU utilization
- Memory consumption by process
- Process-specific performance analysis
- Resource usage trends over time

## 🎨 Interactive Features

### Chart Customization
- **Drag & Drop**: Rearrange charts for comparative analysis
- **Responsive Design**: Adapts to different screen sizes
- **Real-time Data**: Live updating during data collection
- **Multiple Chart Types**: Line charts, area charts, and utilization graphs

### Report Features
- HTML-based reports with embedded Chart.js
- Statistical summaries with min/max/average values
- Time-series visualization
- Exportable data in CSV format

## 🔧 Advanced Configuration

### Performance Optimization
The tool implements several optimization patterns:
- Raw data capture during logging for minimal overhead
- Processing-intensive calculations moved to reporting phase
- Selective filtering for GPU metrics to reduce data size
- Backward compatibility with existing CSV files

### Data Precision
- Temperature monitoring: 3 decimal place precision
- CPU clock speeds: Real-time calculation from performance counters
- High-frequency sampling for accurate trend analysis

## 📈 Technical Specifications

### Performance Impact
- **Logging Overhead**: Minimized through optimized data collection
- **Memory Usage**: Lightweight PowerShell-based implementation
- **Storage**: Efficient CSV format with selective data capture
- **CPU Impact**: Non-intrusive background monitoring

### Compatibility
- **Windows Versions**: Windows 10, Windows 11, Windows Server 2016+
- **PowerShell**: 5.1+ (Windows PowerShell) or 7+ (PowerShell Core)
- **Architecture**: x64 and x86 systems supported
- **Virtualization**: Compatible with Hyper-V and VMware environments

## 🛠️ Development

### Project Structure
The project follows a consolidated single-folder architecture for simplified deployment and testing. All core components are centralized in the `Plogger/` directory.

### Key Design Patterns
- **Separation of Concerns**: Data collection vs. visualization
- **WMI/CIM Integration**: Native Windows instrumentation
- **Component-based Architecture**: Modular functionality
- **Performance-first Design**: Optimized for minimal system impact

## 📝 Data Output

### CSV Format
Raw performance data is stored in CSV format with timestamped entries for:
- System performance metrics
- Process-level statistics
- Temperature readings
- GPU utilization data

### HTML Reports
Interactive web-based reports featuring:
- Real-time chart updates
- Statistical analysis
- Customizable chart layouts
- Export capabilities

## 🤝 Contributing

This project uses a Memory Bank system for comprehensive documentation and decision tracking. All architectural decisions, system patterns, and progress are documented in the `memory-bank/` directory.

## 📄 License

This project is designed for Windows system performance monitoring and analysis.

---

**Built with ❤️ for Windows system administrators and performance analysts**