# Plogger Refactoring Plan: WMI/CIM Only

**Goal:** Refactor `Plogger/Plogger.ps1` to remove the dependency on `Sensor.dll` (LibreHardwareMonitor) and rely solely on native Windows WMI/CIM queries and Performance Counters for data collection.

**Key Changes:**

1.  **Remove Sensor.dll Integration:**
    *   Delete `Add-Type` for `Sensor.dll`.
    *   Delete `UpdateVisitor` C# class definition.
    *   Delete `LibreHardwareMonitor.Hardware.Computer` object initialization and usage (`$computer`, `$updateVisitor`, `$computer.Accept`, `$computer.Open/Close`).
    *   Remove related variables (`$cpuHardware`, `$gpuHardware`).
    *   Update comments/disclaimer to remove references to `Sensor.dll`.

2.  **Refactor CPU Metrics:**
    *   **CPU Usage:** Use `Get-Counter '\Processor(_Total)\% Processor Time'` exclusively.
    *   **CPU Clock Speed:** Use `Get-CimInstance -ClassName Win32_Processor | Select-Object -ExpandProperty MaxClockSpeed`. Log as `CPUMaxClockSpeedMHz`. Remove old per-core clock logic.
    *   **CPU Temperature:** *Attempt* to fetch using WMI (e.g., `Get-CimInstance -Namespace root/wmi -ClassName MSAcpi_ThermalZoneTemperature`). Log the value (converted to Celsius if needed) or `N/A`/`Error` if unavailable. Remove old `Sensor.dll` logic.
    *   **CPU Power:** Remove `$cpuPowerVal`, `$cpuPlatformPowerVal`, and corresponding CSV columns (`CPUPowerW`, `CPUPlatformPowerW`).

3.  **Remove Fan Speed Logging:**
    *   Remove `$fanSpeedsVal` logic and the `FanSpeeds` CSV column.

4.  **Refactor GPU Metrics:**
    *   **Overall GPU Metrics (Load/Temp/Power from Sensor.dll):** Remove the `$gpuMetrics` hashtable population and the dynamic addition of `GPU_*` properties derived from it.
    *   **Add GPU Engine Utilization (from Counters):**
        *   Implement logic using `Get-Counter '\GPU Engine(*)\Utilization Percentage'`.
        *   Parse `InstanceName` to identify Engine Type (e.g., 3D, VideoDecode) and GPU LUID.
        *   Group results by LUID and Engine Type, summing percentages.
        *   Store results in a hashtable (e.g., `$gpuEngineUsage`).
        *   Dynamically add properties to the `$currentData` object based on the keys/values in `$gpuEngineUsage` (e.g., `GPU_LUID*_Engine_3D_Percent`).
    *   **Per-Process GPU Memory:** Keep the existing `Get-Counter '\GPU Process Memory(*)\*'` logic.

5.  **Data Object (`$currentData`) Update:**
    *   Remove properties: `FanSpeeds`, `CPUPowerW`, `CPUPlatformPowerW`, `CPUCoreClocks`. (Note: `CPUTemperatureC` is kept but populated differently).
    *   Add property: `CPUMaxClockSpeedMHz`.
    *   Modify property: `CPUTemperatureC` (populated by WMI attempt).
    *   Dynamically add `GPUEngine_*_Percent` properties based on counter results.

6.  **Cleanup:**
    *   Remove unused variable initializations.
    *   Review and update script comments, help text, and disclaimer.

**Diagram (Simplified Flow):**

```mermaid
graph TD
    A[Start Script] --> B{Load Dependencies};
    B -- Sensor.dll --> B_Fail(Remove Sensor.dll Load);
    B -- WMI/Counters --> C{Initialize Logging};
    C --> D[Get Static Info - Serial, RAM, CPU Max Clock];
    D --> E{Start Logging Loop};
    E --> F[Get WMI/Counter Metrics];
    F --> F_CPU[CPU Usage %];
    F --> F_RAM[RAM Usage];
    F --> F_Disk[Disk IO];
    F --> F_Net[Network IO];
    F --> F_Batt[Battery %];
    F --> F_Bright[Brightness];
    F --> F_CPUTemp(Attempt CPU Temp);
    F --> F_GPUEngine[GPU Engine %];
    F --> F_Proc[Per-Process Metrics];
    F_Proc --> F_ProcGPU[Incl. GPU Memory];
    F_CPU & F_RAM & F_Disk & F_Net & F_Batt & F_Bright & F_CPUTemp & F_GPUEngine --> G{Combine Hardware Data};
    G --> H{Write Hardware Data periodically};
    F_ProcGPU --> I{Combine Process Data};
    I --> J{Write Process Data periodically};
    E --> K{Check Duration / Ctrl+C};
    K -- Stop --> L[Save Remaining Data];
    L --> M[End Script];
    K -- Continue --> E;

    style B_Fail fill:#f9f,stroke:#333,stroke-width:2px
    style F_CPUTemp fill:#lightyellow,stroke:#333,stroke-width:1px