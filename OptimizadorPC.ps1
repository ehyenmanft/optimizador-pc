#Requires -Version 5.1
<#
    Optimizador PC v4 - herramienta para Windows 10/11 con interfaz glass y bandeja del sistema
    - Panel en vivo (CPU, RAM, memoria de GPU, disco) y Modo Turbo
    - Diagnóstico de hardware y de dual channel de la RAM
    - Ajustes de rendimiento reversibles (se guarda un respaldo)
    - Procesos, programas de arranque y juegos con impulso automático
    - Audio: volumen, silencio y mejoras
    - Widget flotante: CPU, RAM y red en tiempo real, con pulsador para liberar la RAM caché
#>
param([switch]$Minimized, [switch]$Consola)

$ScriptPath = $PSCommandPath

# --- Auto-elevación a administrador ---------------------------------------
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    # Con -Consola la ventana de PowerShell queda abierta para leer cualquier error
    $winArg = if ($Consola) { '-NoExit' } else { '-WindowStyle Hidden' }
    $relaunch = "-NoProfile -ExecutionPolicy Bypass $winArg -File `"$ScriptPath`""
    if ($Minimized) { $relaunch += ' -Minimized' }
    if ($Consola) { $relaunch += ' -Consola' }
    Start-Process powershell.exe -Verb RunAs -ArgumentList $relaunch
    exit
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, System.Drawing

# La consola va oculta: cualquier error grave al arrancar se muestra en una ventana
trap {
    [System.Windows.MessageBox]::Show("Error al iniciar el Optimizador PC:`n$($_.Exception.Message)`n`nLínea $($_.InvocationInfo.ScriptLineNumber)", 'Optimizador PC', 'OK', 'Error') | Out-Null
    exit 1
}

# --- Una sola instancia: si ya está abierto, se le pide que se muestre -----
$ShowEventName = 'Global\OptimizadorPC_Mostrar'
$created = $false
$script:Mutex = New-Object System.Threading.Mutex($true, 'Global\OptimizadorPC_Instancia', [ref]$created)
if (-not $created) {
    try { [System.Threading.EventWaitHandle]::OpenExisting($ShowEventName).Set() | Out-Null } catch {}
    exit
}
$script:ShowEvent = New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::AutoReset, $ShowEventName)

# --- Código nativo -----------------------------------------------------------
# Ventana: desenfoque tipo cristal detrás de la ventana y ocultar la consola
$script:NativeOk = $true
try {
    Add-Type -ErrorAction Stop -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class OptWin {
    [StructLayout(LayoutKind.Sequential)]
    struct AccentPolicy { public int AccentState; public int AccentFlags; public int GradientColor; public int AnimationId; }
    [StructLayout(LayoutKind.Sequential)]
    struct WinCompAttrData { public int Attribute; public IntPtr Data; public int SizeOfData; }
    [DllImport("user32.dll")] static extern int SetWindowCompositionAttribute(IntPtr hwnd, ref WinCompAttrData data);
    [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    public static bool EnableBlur(IntPtr hwnd) {
        AccentPolicy accent = new AccentPolicy();
        accent.AccentState = 3; // ACCENT_ENABLE_BLURBEHIND
        int size = Marshal.SizeOf(accent);
        IntPtr ptr = Marshal.AllocHGlobal(size);
        try {
            Marshal.StructureToPtr(accent, ptr, false);
            WinCompAttrData data = new WinCompAttrData();
            data.Attribute = 19; // WCA_ACCENT_POLICY
            data.Data = ptr;
            data.SizeOfData = size;
            return SetWindowCompositionAttribute(hwnd, ref data) != 0;
        } finally { Marshal.FreeHGlobal(ptr); }
    }
    public static void HideConsole() {
        IntPtr h = GetConsoleWindow();
        if (h != IntPtr.Zero) ShowWindow(h, 0);
    }
}
"@
    if (-not $Consola) { [OptWin]::HideConsole() }
} catch { $script:NativeOk = $false }

# Memoria: vaciar la lista "en espera" (caché) como hace ISLC
$script:MemOk = $true
try {
    Add-Type -ErrorAction Stop -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class OptMem {
    [DllImport("ntdll.dll")]
    static extern uint RtlAdjustPrivilege(int privilege, [MarshalAs(UnmanagedType.U1)] bool enable,
        [MarshalAs(UnmanagedType.U1)] bool currentThread, [MarshalAs(UnmanagedType.U1)] out bool previous);
    [DllImport("ntdll.dll")]
    static extern uint NtSetSystemInformation(int infoClass, ref int info, int length);
    public static uint PurgeStandby() {
        bool prev;
        RtlAdjustPrivilege(13, true, false, out prev); // SeProfileSingleProcessPrivilege
        int cmd = 4;                                    // MemoryPurgeStandbyList
        return NtSetSystemInformation(80, ref cmd, 4);  // SystemMemoryListInformation
    }
}
"@
} catch { $script:MemOk = $false }

# Widget: CPU y RAM sin contadores de rendimiento (sus nombres cambian con el idioma de Windows)
$script:StatsOk = $true
try {
    Add-Type -ErrorAction Stop -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class OptStats {
    [StructLayout(LayoutKind.Sequential)]
    struct MemStatus { public uint Length; public uint Load; public ulong TotalPhys, AvailPhys, TotalPage, AvailPage, TotalVirt, AvailVirt, AvailExt; }
    [DllImport("kernel32.dll")] static extern bool GlobalMemoryStatusEx(ref MemStatus m);
    [DllImport("kernel32.dll")] static extern bool GetSystemTimes(out long idle, out long kernel, out long user);
    [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr hwnd, int index);
    [DllImport("user32.dll")] static extern int SetWindowLong(IntPtr hwnd, int index, int value);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr hwnd);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hwnd, IntPtr pid);
    [DllImport("user32.dll")] static extern bool AttachThreadInput(uint from, uint to, bool attach);
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
    static long lastIdle, lastTotal;

    public static int Cpu() {
        long idle, kernel, user;
        if (!GetSystemTimes(out idle, out kernel, out user)) return 0;
        long total = kernel + user; // el tiempo de kernel ya incluye el inactivo
        long dIdle = idle - lastIdle, dTotal = total - lastTotal;
        lastIdle = idle; lastTotal = total;
        if (dTotal <= 0) return 0;
        return (int)Math.Max(0, Math.Min(100, 100 * (dTotal - dIdle) / dTotal));
    }
    public static int Ram() {
        MemStatus m = new MemStatus();
        m.Length = (uint)Marshal.SizeOf(m);
        return GlobalMemoryStatusEx(ref m) ? (int)m.Load : 0;
    }
    // Windows niega el foco a quien hizo clic en una ventana que no se activa: se toma prestado de la ventana activa
    public static void BringToFront(IntPtr hwnd) {
        uint me = GetCurrentThreadId(), other = GetWindowThreadProcessId(GetForegroundWindow(), IntPtr.Zero);
        AttachThreadInput(me, other, true);
        SetForegroundWindow(hwnd);
        AttachThreadInput(me, other, false);
    }
    // Fuera de Alt+Tab y sin quitar el foco a la ventana activa (por ejemplo, un juego)
    public static void MakeOverlay(IntPtr hwnd) {
        SetWindowLong(hwnd, -20, GetWindowLong(hwnd, -20) | 0x80 | 0x08000000); // GWL_EXSTYLE: TOOLWINDOW | NOACTIVATE
    }
}
"@
} catch { $script:StatsOk = $false }

# Audio: volumen maestro del altavoz predeterminado (API Core Audio)
$script:AudioOk = $true
try {
    Add-Type -ErrorAction Stop -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
[Guid("5CDF2C82-841E-4546-9722-0CF74078229A"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IAudioEndpointVolume {
    int f(); int g(); int h(); int i();
    int SetMasterVolumeLevelScalar(float fLevel, Guid pguidEventContext);
    int j();
    int GetMasterVolumeLevelScalar(out float pfLevel);
    int k(); int l(); int m(); int n();
    int SetMute([MarshalAs(UnmanagedType.Bool)] bool bMute, Guid pguidEventContext);
    int GetMute(out bool pbMute);
}
[Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IMMDevice { int Activate(ref Guid id, int clsCtx, int activationParams, out IAudioEndpointVolume aev); }
[Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IMMDeviceEnumerator { int f(); int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice endpoint); }
[ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")] class MMDeviceEnumeratorComObject { }
public class OptAudio {
    static IAudioEndpointVolume Vol() {
        var enumerator = new MMDeviceEnumeratorComObject() as IMMDeviceEnumerator;
        IMMDevice dev = null;
        Marshal.ThrowExceptionForHR(enumerator.GetDefaultAudioEndpoint(0, 1, out dev));
        IAudioEndpointVolume epv = null;
        var epvid = typeof(IAudioEndpointVolume).GUID;
        Marshal.ThrowExceptionForHR(dev.Activate(ref epvid, 23, 0, out epv));
        return epv;
    }
    public static float Volume {
        get { float v = -1; Marshal.ThrowExceptionForHR(Vol().GetMasterVolumeLevelScalar(out v)); return v; }
        set { Marshal.ThrowExceptionForHR(Vol().SetMasterVolumeLevelScalar(value, Guid.Empty)); }
    }
    public static bool Mute {
        get { bool mute; Marshal.ThrowExceptionForHR(Vol().GetMute(out mute)); return mute; }
        set { Marshal.ThrowExceptionForHR(Vol().SetMute(value, Guid.Empty)); }
    }
}
"@
} catch { $script:AudioOk = $false }

# Menú oscuro para el icono de la bandeja
$script:DarkMenuOk = $true
try {
    Add-Type -ErrorAction Stop -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition @"
using System.Drawing;
using System.Windows.Forms;
public class OptDarkColors : ProfessionalColorTable {
    static Color Bg = Color.FromArgb(22, 25, 34);
    static Color Sel = Color.FromArgb(42, 51, 74);
    static Color Bd = Color.FromArgb(51, 58, 77);
    static Color Acc = Color.FromArgb(118, 185, 0);
    public override Color ToolStripDropDownBackground { get { return Bg; } }
    public override Color ImageMarginGradientBegin { get { return Bg; } }
    public override Color ImageMarginGradientMiddle { get { return Bg; } }
    public override Color ImageMarginGradientEnd { get { return Bg; } }
    public override Color MenuBorder { get { return Bd; } }
    public override Color MenuItemBorder { get { return Sel; } }
    public override Color MenuItemSelected { get { return Sel; } }
    public override Color SeparatorDark { get { return Bd; } }
    public override Color SeparatorLight { get { return Bg; } }
    public override Color CheckBackground { get { return Acc; } }
    public override Color CheckSelectedBackground { get { return Acc; } }
    public override Color CheckPressedBackground { get { return Acc; } }
}
"@
} catch { $script:DarkMenuOk = $false }

# --- Rutas y constantes -------------------------------------------------------
$BackupFile   = Join-Path $PSScriptRoot 'optimizador_respaldo.json'
$SettingsFile = Join-Path $PSScriptRoot 'optimizador_ajustes.json'
$TaskName     = 'OptimizadorPC'
$OwnPlanGuid  = '3c1d6a7e-5b2f-4f0e-9a51-0c0ffee0aa01'   # copia propia del plan "Máximo rendimiento"
$UltimateGuid = 'e9a42b02-d5df-448d-aa00-03f14749eb61'
$HighPerfGuid = '8c5e7fda-e8bf-4a96-9a85-e6e09a20f6e2'
$AppVersion   = 'v4.2'

$script:ui = @{}
$script:PendingLog = @()

# --- Registro y respaldo ---------------------------------------------------
function Get-RegValue($Path, $Name) {
    try { (Get-ItemProperty -Path $Path -Name $Name -ErrorAction Stop).$Name } catch { $null }
}

function Set-RegValue($Path, $Name, $Value, $Type = 'DWord') {
    if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
    New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
}

function Load-Backup {
    if (Test-Path $BackupFile) {
        try { return Get-Content $BackupFile -Raw | ConvertFrom-Json } catch {}
    }
    [pscustomobject]@{ Registry = @(); PowerScheme = $null }
}

function Save-Backup {
    $script:Backup | ConvertTo-Json -Depth 4 | Set-Content -Path $BackupFile -Encoding UTF8
}

# Guarda el valor original solo la primera vez, para que "Revertir" vuelva al estado previo real
function Set-RegTracked($Path, $Name, $Value, $Type = 'DWord') {
    $known = @($script:Backup.Registry) | Where-Object { $_.Path -eq $Path -and $_.Name -eq $Name }
    if (-not $known) {
        $old = Get-RegValue $Path $Name
        $script:Backup.Registry = @($script:Backup.Registry) + [pscustomobject]@{
            Path = $Path; Name = $Name; Type = $Type; Old = $old; Existed = ($null -ne $old)
        }
    }
    Set-RegValue $Path $Name $Value $Type
}

$script:Backup = Load-Backup

# --- Ajustes del programa ------------------------------------------------------
function Load-Settings {
    $s = @{ Games = @(); AutoPriority = $true; AutoTurbo = $true; Notify = $true; CloseToTray = $true; TrayHintShown = $false; Widget = $true }
    if (Test-Path $SettingsFile) {
        try {
            $j = Get-Content $SettingsFile -Raw | ConvertFrom-Json
            foreach ($p in $j.PSObject.Properties) { $s[$p.Name] = $p.Value }
        } catch {}
    }
    $s.Games = @($s.Games | Where-Object { $_ })
    $s
}

function Save-Settings {
    try { [pscustomobject]$script:Settings | ConvertTo-Json -Depth 3 | Set-Content -Path $SettingsFile -Encoding UTF8 }
    catch { Log "No se pudieron guardar los ajustes: $($_.Exception.Message)" }
}

$script:Settings = Load-Settings

# --- Utilidades ----------------------------------------------------------------
function Log($msg) {
    $line = '[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $msg
    if ($script:ui.LogBox) {
        $script:ui.LogBox.AppendText($line + "`r`n")
        $script:ui.LogBox.ScrollToEnd()
    } else {
        $script:PendingLog += $line
    }
}

function Notify($text) {
    if ($script:Tray -and $script:Settings.Notify) {
        $script:Tray.ShowBalloonTip(4000, 'Optimizador PC', $text, [System.Windows.Forms.ToolTipIcon]::Info)
    }
}

function Format-GB($bytes) { '{0:N1} GB' -f ($bytes / 1GB) }

function Set-Busy([bool]$busy) {
    if (-not $script:Window) { return }
    $script:Window.Cursor = if ($busy) { [System.Windows.Input.Cursors]::Wait } else { $null }
    # Deja que la interfaz se redibuje antes de una tarea larga
    $script:Window.Dispatcher.Invoke([action]{}, [System.Windows.Threading.DispatcherPriority]::Background)
}

# Tareas largas en segundo plano (punto de restauración, desfragmentar)
$script:Jobs = @()
function Start-BgTask($name, [scriptblock]$block) {
    $job = Start-Job -ScriptBlock $block
    $script:Jobs += [pscustomobject]@{ Job = $job; Name = $name }
    Log "${name}: en curso. Puedes seguir usando el programa."
}

function Update-BgTasks {
    foreach ($t in @($script:Jobs)) {
        if ($t.Job.State -notin 'Completed', 'Failed', 'Stopped') { continue }
        $out = @(Receive-Job $t.Job -ErrorAction SilentlyContinue 2>&1)
        foreach ($o in $out) { Log "$($t.Name): $o" }
        if ($out.Count -eq 0) { Log "$($t.Name): terminado." }
        if (-not $script:Window.IsVisible) { Notify "$($t.Name): terminado." }
        Remove-Job $t.Job -Force -ErrorAction SilentlyContinue
        $script:Jobs = @($script:Jobs | Where-Object { $_ -ne $t })
    }
}

# --- Información del sistema -----------------------------------------------
function Get-GpuInfo {
    $gpus = @()
    $classKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'
    $regs = Get-ChildItem $classKey -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match '^\d{4}$' }
    foreach ($vc in Get-CimInstance Win32_VideoController) {
        $vram = $null
        foreach ($k in $regs) {
            $p = Get-ItemProperty $k.PSPath -ErrorAction SilentlyContinue
            if ($p.DriverDesc -ne $vc.Name) { continue }
            $q = $p.'HardwareInformation.qwMemorySize'
            $d = $p.'HardwareInformation.MemorySize'
            if ($q) { $vram = [uint64]$q }
            elseif ($d -is [byte[]]) { $vram = [BitConverter]::ToUInt32($d, 0) }
            elseif ($d) { $vram = [uint64]$d }
        }
        if (-not $vram) { $vram = [uint64]$vc.AdapterRAM }
        $gpus += [pscustomobject]@{ Name = $vc.Name; Driver = $vc.DriverVersion; VRAM = $vram }
    }
    $gpus
}

function Get-MemTypeName($code) {
    switch ([int]$code) { 20 { 'DDR' } 21 { 'DDR2' } 24 { 'DDR3' } 26 { 'DDR4' } 34 { 'DDR5' } 35 { 'LPDDR5' } default { 'DDR?' } }
}

function Describe-Module($m) {
    '{0} {1} a {2} MT/s ({3} {4})' -f (Format-GB $m.Capacity), (Get-MemTypeName $m.SMBIOSMemoryType), $m.Speed, "$($m.Manufacturer)".Trim(), "$($m.PartNumber)".Trim()
}

function Get-DualChannelReport {
    $mods = @(Get-CimInstance Win32_PhysicalMemory)
    $slots = (Get-CimInstance Win32_PhysicalMemoryArray | Measure-Object MemoryDevices -Sum).Sum
    $r = @()
    $n = $mods.Count
    if ($n -eq 0) { return @('No se pudieron leer los módulos de RAM.') }

    if ($n -eq 1) {
        $r += 'Estado: SINGLE CHANNEL (un solo módulo).'
        $r += '  Pierdes cerca de la mitad del ancho de banda de memoria. Con gráficos integrados'
        $r += '  (Intel UHD/Iris, AMD Vega/Radeon) el impacto en juegos puede ser de 20-50% de FPS.'
        if ($slots -gt 1) {
            $r += "  Tienes $($slots - 1) ranura(s) libre(s). Solución: añadir un módulo IDÉNTICO al actual:"
            $r += "  -> $(Describe-Module $mods[0])"
        } else {
            $r += '  Windows reporta una sola ranura: no se puede pasar a dual channel. (En algunos'
            $r += '  portátiles con RAM soldada el dato es inexacto; revisa el manual del equipo.)'
        }
    } else {
        $channels = @()
        foreach ($m in $mods) {
            $s = "$($m.BankLabel) $($m.DeviceLocator)"
            $ctrl = if ($s -match '(?i)controller\s*(\d)') { "C$($matches[1])" } else { '' }
            if ($s -match '(?i)(?:channel|ch|dimm|ddr\d?)[\s_-]*([A-D])(?:\d|\b|-|_)') {
                $channels += "$ctrl$($matches[1].ToUpper())"
            }
        }
        $distinct = @($channels | Select-Object -Unique).Count
        if ($slots -ge 2 -and $n -eq $slots -and $n % 2 -eq 0) {
            $r += "Estado: DUAL CHANNEL. Todas las ranuras ($slots) están ocupadas, así que ambos canales tienen memoria."
        } elseif ($channels.Count -eq $n -and $distinct -ge 2) {
            $r += "Estado: DUAL CHANNEL (probable). Módulos en canales: $($channels -join ', ')"
        } elseif ($channels.Count -eq $n -and $distinct -eq 1) {
            $r += "Estado: los $n módulos parecen estar en el MISMO canal ($($channels[0]))."
            $r += '  Muévelos a ranuras de canales distintos (en placas de 4 ranuras suele ser'
            $r += '  A2 y B2: la 2.a y 4.a contando desde el procesador). Consulta el manual.'
        } else {
            $r += "Estado: $n módulos instalados; no se pudo deducir el canal por los nombres de ranura."
        }
        $caps = @($mods | Select-Object -ExpandProperty Capacity -Unique)
        if ($caps.Count -gt 1) {
            $r += '  Aviso: los módulos tienen distinta capacidad -> modo asimétrico/flex: solo la parte'
            $r += '  común funciona en dual channel. Lo ideal son módulos idénticos.'
        }
        $speeds = @($mods | Select-Object -ExpandProperty Speed -Unique)
        if ($speeds.Count -gt 1) {
            $r += '  Aviso: velocidades distintas -> todos los módulos funcionan a la del más lento.'
        }
    }

    $slow = $mods | Where-Object { $_.ConfiguredClockSpeed -gt 0 -and $_.ConfiguredClockSpeed -lt $_.Speed }
    if ($slow) {
        $m = @($slow)[0]
        $r += "  La RAM funciona a $($m.ConfiguredClockSpeed) MT/s pero admite $($m.Speed) MT/s."
        $r += '  En PC de escritorio: activa XMP (Intel) o EXPO/DOCP (AMD) en la BIOS.'
    }
    $r += '  Para confirmar: CPU-Z -> pestaña "Memory" -> campo "Channel #" (Single/Dual).'
    $r += ''
    $r += 'Módulos detectados:'
    foreach ($m in $mods) { $r += "  [$($m.BankLabel) / $($m.DeviceLocator)]  $(Describe-Module $m)" }
    $r += "  Ranuras totales reportadas: $slots"
    $r
}

function Get-SystemReport {
    $L = @()
    $os = Get-CimInstance Win32_OperatingSystem
    $cpu = @(Get-CimInstance Win32_Processor)[0]
    $L += "SISTEMA: $($os.Caption) (build $($os.BuildNumber))"
    $L += "CPU:     $($cpu.Name.Trim())  -  $($cpu.NumberOfCores) núcleos / $($cpu.NumberOfLogicalProcessors) hilos"
    $L += "RAM:     $(Format-GB ($os.TotalVisibleMemorySize * 1KB)) utilizables"
    foreach ($g in $script:Hw.Gpus) {
        $L += "GPU:     $($g.Name)  -  VRAM dedicada: $(Format-GB $g.VRAM)  -  driver $($g.Driver)"
    }
    try {
        foreach ($d in Get-PhysicalDisk) {
            $L += "DISCO:   $($d.FriendlyName)  -  $($d.MediaType) / $($d.BusType)  -  $(Format-GB $d.Size)"
        }
    } catch {}
    $hags = Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' 'HwSchMode'
    $hagsText = if (-not $script:Hw.HagsSupported) { 'no compatible con esta GPU/driver' } elseif ($hags -eq 2) { 'activada' } else { 'desactivada' }
    $L += "Programación de GPU acelerada por hardware: $hagsText"
    $L += "Plan de energía: $((powercfg /getactivescheme) -replace '^.*?:\s*', '')"
    $L += ''
    $L += '=== RAM / DUAL CHANNEL ==='
    $L += Get-DualChannelReport
    $L -join "`r`n"
}

# Datos del hardware que usan las recomendaciones y los ajustes
function Get-HardwareFacts {
    $hw = @{}
    $hw.Gpus = @(Get-GpuInfo)
    $real = @($hw.Gpus | Where-Object { $_.Name -notmatch 'Basic Display|Básico|Remote|Virtual|Parsec' })
    $hw.NoGpuDriver = ($real.Count -eq 0)
    $hw.GpuName = if ($real.Count) { $real[0].Name } else { 'sin driver' }
    $integratedRx = 'Intel.*(HD|UHD|Iris).*Graphics|Intel\(R\) Graphics|Radeon\(TM\) (Vega|R\d|Graphics)|AMD Radeon\(TM\) Graphics'
    $hw.IntegratedOnly = ($real.Count -gt 0) -and (@($real | Where-Object { $_.Name -notmatch $integratedRx }).Count -eq 0)
    $dedicated = @($real | Where-Object { $_.Name -notmatch $integratedRx })
    if ($dedicated.Count) { $hw.GpuName = $dedicated[0].Name }
    # El primer número de la versión del driver indica la versión WDDM (27 = WDDM 2.7, necesaria para HAGS)
    $hw.HagsSupported = @($real | Where-Object { [int]("$($_.Driver)".Split('.')[0]) -ge 27 }).Count -gt 0
    $hw.TotalVram = ($real | Measure-Object VRAM -Maximum).Maximum

    $os = Get-CimInstance Win32_OperatingSystem
    $hw.RamGB = [math]::Round($os.TotalVisibleMemorySize * 1KB / 1GB, 1)
    $cpu = @(Get-CimInstance Win32_Processor)[0]
    $hw.CpuName = ($cpu.Name -replace '\(R\)|\(TM\)|CPU|\s+@.*$', '' -replace '\s+', ' ').Trim()
    $hw.CpuDesc = "$($cpu.NumberOfCores) núcleos / $($cpu.NumberOfLogicalProcessors) hilos"

    $mods = @(Get-CimInstance Win32_PhysicalMemory)
    $slots = (Get-CimInstance Win32_PhysicalMemoryArray | Measure-Object MemoryDevices -Sum).Sum
    $hw.SingleChannel = ($mods.Count -eq 1 -and $slots -gt 1)
    $hw.XmpOff = @($mods | Where-Object { $_.ConfiguredClockSpeed -gt 0 -and $_.ConfiguredClockSpeed -lt $_.Speed }).Count -gt 0

    $hw.SysHdd = $false
    try {
        $dn = (Get-Partition -DriveLetter $env:SystemDrive[0] -ErrorAction Stop).DiskNumber
        $pd = Get-PhysicalDisk | Where-Object { "$($_.DeviceId)" -eq "$dn" }
        $hw.SysHdd = ("$($pd.MediaType)" -eq 'HDD' -or "$($pd.MediaType)" -eq '3')
    } catch {}
    $hw
}

function Get-Recommendations {
    $hw = $script:Hw
    $r = @()
    if ($hw.NoGpuDriver) {
        $r += '• No hay driver de gráficos instalado. Instálalo desde Sistema > "Drivers de la GPU": es lo primero.'
    } elseif ($hw.IntegratedOnly) {
        $r += "• Tu gráfica es integrada ($($hw.GpuName)). Es el mayor límite para jugar: una tarjeta dedicada (por ejemplo una GTX 1650, que no necesita cable extra de la fuente) multiplica el rendimiento."
    }
    if ($hw.SysHdd) {
        $r += '• Windows está en un disco duro mecánico (HDD). Un SSD SATA es la mejora más barata y notable: arranque y cargas mucho más rápidos y menos tirones.'
        $r += '• Mientras tanto, optimiza el disco C: desde Sistema y desactiva programas de arranque innecesarios en "Arranque".'
    }
    if ($hw.RamGB -lt 8) { $r += "• Tienes $($hw.RamGB) GB de RAM. Para juegos actuales conviene tener 16 GB." }
    if ($hw.SingleChannel) { $r += '• La RAM está en single channel. Añadir un módulo idéntico activa el dual channel (detalles en Sistema).' }
    if ($hw.XmpOff) { $r += '• La RAM funciona por debajo de su velocidad. Activa XMP/EXPO en la BIOS.' }
    if ($r.Count -eq 0) { $r += '• Tu equipo está bien equilibrado. Usa el Modo Turbo al jugar.' }
    $r += '• Añade tus juegos en "Mis juegos" para que el Modo Turbo se active solo al abrirlos.'
    $r -join "`n"
}

# --- Optimizaciones --------------------------------------------------------
function Get-ActiveScheme {
    if ((powercfg /getactivescheme) -match '([0-9a-fA-F-]{36})') { $matches[1] }
}

function Enable-PerformancePlan {
    $list = powercfg /list | Out-String
    if ($list -notmatch $OwnPlanGuid) {
        powercfg /duplicatescheme $UltimateGuid $OwnPlanGuid | Out-Null
    }
    powercfg /setactive $OwnPlanGuid 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) { Log 'Plan "Máximo rendimiento" activado.'; return }
    powercfg /setactive $HighPerfGuid 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) { Log 'Plan "Alto rendimiento" activado.'; return }
    Log 'Este equipo no permite planes de alto rendimiento (Modern Standby). Usa el control deslizante de energía de Windows en "Máximo rendimiento".'
}

function Set-PerformancePlan {
    if (-not $script:Backup.PowerScheme) { $script:Backup.PowerScheme = Get-ActiveScheme }
    Enable-PerformancePlan
}

function Enable-Hags {
    Set-RegTracked 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' 'HwSchMode' 2
    Log 'Programación de GPU acelerada por hardware activada (requiere reiniciar).'
}

function Enable-GameMode {
    Set-RegTracked 'HKCU:\Software\Microsoft\GameBar' 'AutoGameModeEnabled' 1
    Set-RegTracked 'HKCU:\Software\Microsoft\GameBar' 'AllowAutoGameMode' 1
    Log 'Modo juego activado.'
}

function Disable-GameDvr {
    Set-RegTracked 'HKCU:\System\GameConfigStore' 'GameDVR_Enabled' 0
    Set-RegTracked 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' 'AppCaptureEnabled' 0
    Log 'Grabación en segundo plano de Xbox Game Bar desactivada.'
}

function Set-MultimediaProfile {
    $sp = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'
    Set-RegTracked $sp 'SystemResponsiveness' 10
    Set-RegTracked $sp 'NetworkThrottlingIndex' 0xffffffff
    Set-RegTracked "$sp\Tasks\Games" 'GPU Priority' 8
    Set-RegTracked "$sp\Tasks\Games" 'Priority' 6
    Set-RegTracked "$sp\Tasks\Games" 'Scheduling Category' 'High' 'String'
    Set-RegTracked "$sp\Tasks\Games" 'SFIO Priority' 'High' 'String'
    Log 'Prioridad de CPU/GPU para juegos aumentada (perfil multimedia).'
}

function Disable-BackgroundApps {
    Set-RegTracked 'HKCU:\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications' 'GlobalUserDisabled' 1
    Set-RegTracked 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' 'BackgroundAppGlobalToggle' 0
    Log 'Apps de la Tienda en segundo plano desactivadas.'
}

function Disable-Transparency {
    Set-RegTracked 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' 'EnableTransparency' 0
    Log 'Efectos de transparencia de Windows desactivados.'
}

function Set-AutoPagefile {
    $cs = Get-CimInstance Win32_ComputerSystem
    if ($cs.AutomaticManagedPagefile) { Log 'El archivo de paginación ya está administrado por el sistema.'; return }
    Set-CimInstance -InputObject $cs -Property @{ AutomaticManagedPagefile = $true }
    Log 'Archivo de paginación: ahora administrado por Windows (aplica tras reiniciar). Este cambio no se revierte automáticamente.'
}

function Clear-TempFiles {
    $paths = @($env:TEMP, "$env:windir\Temp", "$env:windir\SoftwareDistribution\Download")
    $before = 0; $after = 0
    foreach ($p in $paths) {
        if (-not (Test-Path $p)) { continue }
        $before += (Get-ChildItem $p -Recurse -Force -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
        Get-ChildItem $p -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        $after += (Get-ChildItem $p -Recurse -Force -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
    }
    Log ('Archivos temporales eliminados: {0:N0} MB liberados (los que estaban en uso se omiten).' -f (($before - $after) / 1MB))
}

function Clear-StandbyMemory {
    if (-not $script:MemOk) { Log 'Liberar memoria no está disponible en este equipo.'; return }
    $mem = { [double](Get-CimInstance Win32_PerfFormattedData_PerfOS_Memory).FreeAndZeroPageListBytes }
    $before = & $mem
    $code = [OptMem]::PurgeStandby()
    $after = & $mem
    if ($code -eq 0) {
        $freed = [math]::Max(0, $after - $before)
        Log ('Memoria en espera liberada: {0:N0} MB pasaron a memoria libre.' -f ($freed / 1MB))
        return $freed
    } else {
        Log ('No se pudo liberar la memoria en espera (código 0x{0:X}).' -f $code)
    }
}

function Undo-Optimizations {
    foreach ($e in @($script:Backup.Registry)) {
        if ($e.Existed) { Set-RegValue $e.Path $e.Name $e.Old $e.Type }
        else { Remove-ItemProperty -Path $e.Path -Name $e.Name -ErrorAction SilentlyContinue }
    }
    if ($script:Backup.PowerScheme) { powercfg /setactive $script:Backup.PowerScheme | Out-Null }
    Remove-Item $BackupFile -ErrorAction SilentlyContinue
    $script:Backup = [pscustomobject]@{ Registry = @(); PowerScheme = $null }
    Log 'Ajustes revertidos a los valores originales. Reinicia para que todo surta efecto.'
}

# --- Modo Turbo ----------------------------------------------------------------
$script:TurboOn = $false
$script:TurboPrev = $null
$script:TurboByGame = $false

function Enable-Turbo {
    if ($script:TurboOn) { return }
    $script:TurboPrev = Get-ActiveScheme
    Enable-PerformancePlan
    [void](Clear-StandbyMemory)
    $script:TurboOn = $true
    Log 'Modo Turbo ACTIVADO.'
    Update-TurboUi
}

function Disable-Turbo {
    if (-not $script:TurboOn) { return }
    if ($script:TurboPrev) { powercfg /setactive $script:TurboPrev | Out-Null }
    $script:TurboOn = $false
    $script:TurboByGame = $false
    Log 'Modo Turbo desactivado: plan de energía anterior restaurado.'
    Update-TurboUi
}

function Update-TurboUi {
    $on = $script:TurboOn
    if ($script:ui.TurboSwitch) { $script:ui.TurboSwitch.IsChecked = $on }
    if ($script:ui.TurboBadge) { $script:ui.TurboBadge.Visibility = if ($on) { 'Visible' } else { 'Collapsed' } }
    if ($script:TrayTurbo) { $script:TrayTurbo.Checked = $on }
    if ($script:Tray) { $script:Tray.Icon = if ($on) { $script:IconTurbo } else { $script:IconNormal } }
}

# --- Juegos: impulso automático ----------------------------------------------------
$script:BoostedPids = @{}

function Update-Games {
    $names = @($script:Settings.Games | ForEach-Object { [IO.Path]::GetFileNameWithoutExtension($_) })
    $procs = @()
    if ($names.Count) { $procs = @(Get-Process -Name $names -ErrorAction SilentlyContinue) }
    foreach ($p in $procs) {
        if ($script:BoostedPids.ContainsKey($p.Id)) { continue }
        $script:BoostedPids[$p.Id] = $p.ProcessName
        $msg = "Juego detectado: $($p.ProcessName)."
        if ($script:Settings.AutoPriority) {
            try { $p.PriorityClass = 'High'; $msg += ' Prioridad alta aplicada.' }
            catch { $msg += ' No se pudo subir su prioridad (algunos antitrampas lo bloquean).' }
        }
        if ($script:Settings.AutoTurbo -and -not $script:TurboOn) {
            Enable-Turbo
            $script:TurboByGame = $true
            $msg += ' Modo Turbo activado.'
        }
        Log $msg
        Notify $msg
    }
    $alive = @($procs | ForEach-Object { $_.Id })
    foreach ($id in @($script:BoostedPids.Keys)) {
        if ($alive -notcontains $id) { $script:BoostedPids.Remove($id) }
    }
    if ($procs.Count -eq 0 -and $script:TurboByGame) {
        Disable-Turbo
        Notify 'Juego cerrado. Modo Turbo desactivado.'
    }
    if ($script:ui.GameStatus) {
        $script:ui.GameStatus.Text = if ($procs.Count) {
            'En juego: ' + (($procs | ForEach-Object { $_.ProcessName } | Select-Object -Unique) -join ', ')
        } else { 'Ningún juego de la lista está abierto.' }
    }
}

# --- Programas de arranque ---------------------------------------------------------
# Se usa el mismo mecanismo que el Administrador de tareas (claves StartupApproved), así que es reversible
$StartupRunKeys = @(
    @{ Run = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'; Approved = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'; Loc = 'Registro (usuario)' }
    @{ Run = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'; Approved = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'; Loc = 'Registro (equipo)' }
    @{ Run = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'; Approved = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run32'; Loc = 'Registro (equipo, 32 bits)' }
)

function Get-StartupState($approvedKey, $name) {
    $v = Get-RegValue $approvedKey $name
    -not ($v -is [byte[]] -and $v.Length -gt 0 -and ($v[0] -band 1))
}

function Get-StartupItems {
    $items = @()
    foreach ($src in $StartupRunKeys) {
        if (-not (Test-Path $src.Run)) { continue }
        $key = Get-Item $src.Run
        foreach ($n in $key.GetValueNames()) {
            if (-not $n) { continue }
            $on = Get-StartupState $src.Approved $n
            $items += [pscustomobject]@{
                Name = $n; Command = [string]$key.GetValue($n); Location = $src.Loc; Approved = $src.Approved
                Enabled = $on; Estado = if ($on) { 'Activado' } else { 'Desactivado' }
            }
        }
    }
    $folders = @(
        @{ Path = [Environment]::GetFolderPath('Startup'); Approved = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder'; Loc = 'Carpeta Inicio (usuario)' }
        @{ Path = [Environment]::GetFolderPath('CommonStartup'); Approved = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder'; Loc = 'Carpeta Inicio (todos)' }
    )
    foreach ($f in $folders) {
        if (-not $f.Path -or -not (Test-Path $f.Path)) { continue }
        foreach ($file in Get-ChildItem $f.Path -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'desktop.ini' }) {
            $on = Get-StartupState $f.Approved $file.Name
            $items += [pscustomobject]@{
                Name = $file.Name; Command = $file.FullName; Location = $f.Loc; Approved = $f.Approved
                Enabled = $on; Estado = if ($on) { 'Activado' } else { 'Desactivado' }
            }
        }
    }
    $items | Sort-Object Name
}

function Set-StartupItem($item, [bool]$enable) {
    $bytes = New-Object byte[] 12
    $bytes[0] = if ($enable) { 2 } else { 3 }
    if (-not $enable) { [BitConverter]::GetBytes([DateTime]::Now.ToFileTimeUtc()).CopyTo($bytes, 4) }
    Set-RegValue $item.Approved $item.Name $bytes 'Binary'
}

# --- Iniciar con Windows (tarea programada con permisos de administrador, sin aviso de UAC) ---
function Get-Autostart { [bool](Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) }

function Set-Autostart([bool]$on) {
    if ($on) {
        $user = "$env:USERDOMAIN\$env:USERNAME"
        $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$ScriptPath`" -Minimized"
        $trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
        $principal = New-ScheduledTaskPrincipal -UserId $user -RunLevel Highest -LogonType Interactive
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero)
        Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
        Log 'El optimizador se iniciará con Windows, minimizado en la bandeja.'
    } else {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
        Log 'El optimizador ya no se iniciará con Windows.'
    }
}

# --- Audio ----------------------------------------------------------------
function Get-AudioReport {
    $L = @('=== HARDWARE DE AUDIO ===')
    foreach ($d in Get-CimInstance Win32_PnPSignedDriver -Filter "DeviceClass='MEDIA'" -ErrorAction SilentlyContinue) {
        $L += "  $($d.DeviceName)  -  $($d.Manufacturer)  -  driver $($d.DriverVersion) ($('{0:yyyy-MM-dd}' -f $d.DriverDate))"
    }
    $L += ''
    $L += '=== SALIDAS / ENTRADAS DE AUDIO ==='
    try {
        foreach ($e in Get-PnpDevice -Class AudioEndpoint -ErrorAction Stop | Sort-Object Status) {
            $estado = if ($e.Status -eq 'OK') { 'activo' } else { 'desconectado/deshabilitado' }
            $L += "  $($e.FriendlyName)  -  $estado"
        }
    } catch { $L += '  No se pudieron listar.' }
    $L += ''
    $L += '=== PARA MÁS VOLUMEN ==='
    $L += '  1. "Panel de sonido" -> doble clic en tu altavoz -> pestaña "Mejoras" ->'
    $L += '     marca "Ecualización de sonoridad". Sube el volumen percibido sin distorsionar.'
    $L += '     Si no aparece la pestaña, instala el driver Realtek del fabricante de tu placa o usa Equalizer APO.'
    $L += '  2. Equalizer APO + Peace (gratis): amplifica por encima del 100% (preamp) y ecualiza.'
    $L += '  3. Revisa el volumen por aplicación: un juego o el navegador pueden estar bajos por separado.'
    $L += '  4. Altavoces externos: perilla física al máximo y Windows al 80-100% para no amplificar ruido.'
    $L -join "`r`n"
}

function Disable-AudioDucking {
    # 3 = "No hacer nada" cuando Windows detecta una llamada
    Set-RegTracked 'HKCU:\Software\Microsoft\Multimedia\Audio' 'UserDuckingPreference' 3
    Save-Backup
    Log 'Windows ya no bajará el volumen automáticamente durante llamadas (Discord, WhatsApp, etc.).'
}

function Restart-AudioServices {
    Log 'Reiniciando servicios de audio...'
    Restart-Service AudioEndpointBuilder -Force -ErrorAction Stop
    Start-Service Audiosrv -ErrorAction SilentlyContinue
    Log 'Servicios de audio reiniciados. Útil si hay chasquidos, cortes o el sonido desaparece.'
}

function Set-MaxVolume {
    if (-not $script:AudioOk) { Log 'El control de volumen no está disponible.'; return }
    [OptAudio]::Mute = $false
    [OptAudio]::Volume = 1.0
    Update-VolumeUi
    Log 'Volumen del altavoz al 100%.'
}

function Switch-Mute {
    if (-not $script:AudioOk) { return }
    [OptAudio]::Mute = -not [OptAudio]::Mute
    Update-VolumeUi
}

# --- Procesos --------------------------------------------------------------
$Protected = 'Idle','System','Registry','smss','csrss','wininit','winlogon','services','lsass','svchost',
             'dwm','explorer','fontdrvhost','MemCompression','sihost','ctfmon','audiodg','spoolsv',
             'SecurityHealthService','MsMpEng','NisSrv','powershell','conhost','RuntimeBroker','StartMenuExperienceHost'

function Get-ProcessRows {
    Get-Process | Where-Object { $Protected -notcontains $_.ProcessName -and $_.Id -ne $PID } |
        Sort-Object WorkingSet64 -Descending | Select-Object -First 60 | ForEach-Object {
            $prio = '?'
            try { $prio = [string]$_.PriorityClass } catch {}
            [pscustomobject]@{ Name = $_.ProcessName; Id = $_.Id; RamMB = '{0:N0}' -f ($_.WorkingSet64 / 1MB); Priority = $prio }
        }
}

# === INTERFAZ (WPF, estilo glass) ===========================================
[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Optimizador PC" Width="1100" Height="720" MinWidth="940" MinHeight="620"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        ResizeMode="CanResizeWithGrip" WindowStartupLocation="CenterScreen"
        FontFamily="Segoe UI" FontSize="13" Foreground="White">
  <Window.Resources>
    <SolidColorBrush x:Key="Accent" Color="#76B900"/>
    <SolidColorBrush x:Key="Glass" Color="#B3141A24"/>
    <SolidColorBrush x:Key="GlassBorder" Color="#24FFFFFF"/>
    <SolidColorBrush x:Key="TextSec" Color="#9AA4B2"/>
    <SolidColorBrush x:Key="TextMuted" Color="#5E6878"/>

    <Style x:Key="Card" TargetType="Border">
      <Setter Property="Background" Value="{StaticResource Glass}"/>
      <Setter Property="BorderBrush" Value="{StaticResource GlassBorder}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CornerRadius" Value="14"/>
      <Setter Property="Padding" Value="16"/>
      <Setter Property="Margin" Value="0,0,12,12"/>
    </Style>
    <Style x:Key="H1" TargetType="TextBlock">
      <Setter Property="FontSize" Value="22"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Margin" Value="0,0,0,2"/>
    </Style>
    <Style x:Key="Sub" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{StaticResource TextSec}"/>
      <Setter Property="FontSize" Value="12.5"/>
      <Setter Property="TextWrapping" Value="Wrap"/>
      <Setter Property="Margin" Value="0,0,0,14"/>
    </Style>
    <Style x:Key="CardTitle" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{StaticResource TextSec}"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
    </Style>
    <Style x:Key="Big" TargetType="TextBlock">
      <Setter Property="FontSize" Value="26"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Margin" Value="0,4,0,8"/>
    </Style>
    <Style x:Key="Small" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{StaticResource TextSec}"/>
      <Setter Property="FontSize" Value="11.5"/>
      <Setter Property="Margin" Value="0,8,0,0"/>
      <Setter Property="TextTrimming" Value="CharacterEllipsis"/>
    </Style>

    <Style x:Key="GlassButton" TargetType="Button">
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="Background" Value="#14FFFFFF"/>
      <Setter Property="BorderBrush" Value="{StaticResource GlassBorder}"/>
      <Setter Property="Padding" Value="14,8"/>
      <Setter Property="Margin" Value="0,0,8,8"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Grid>
              <Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1" CornerRadius="9"/>
              <Border x:Name="Hl" Background="White" Opacity="0" CornerRadius="9"/>
              <ContentPresenter Margin="{TemplateBinding Padding}" HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Hl" Property="Opacity" Value="0.10"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="Hl" Property="Opacity" Value="0.18"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.4"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="AccentButton" TargetType="Button" BasedOn="{StaticResource GlassButton}">
      <Setter Property="Background" Value="{StaticResource Accent}"/>
      <Setter Property="BorderBrush" Value="{StaticResource Accent}"/>
      <Setter Property="Foreground" Value="Black"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
    </Style>
    <Style x:Key="TitleButton" TargetType="Button" BasedOn="{StaticResource GlassButton}">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="BorderBrush" Value="Transparent"/>
      <Setter Property="FontFamily" Value="Segoe MDL2 Assets"/>
      <Setter Property="FontSize" Value="10"/>
      <Setter Property="Padding" Value="16,8"/>
      <Setter Property="Margin" Value="0,6,6,0"/>
      <Setter Property="VerticalAlignment" Value="Top"/>
    </Style>

    <Style x:Key="Nav" TargetType="RadioButton">
      <Setter Property="Foreground" Value="#C9D1DB"/>
      <Setter Property="Margin" Value="10,2"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RadioButton">
            <Border x:Name="Bd" Background="Transparent" CornerRadius="9" Padding="12,9">
              <Grid>
                <Border x:Name="Bar" Width="3" CornerRadius="2" Background="{StaticResource Accent}" HorizontalAlignment="Left" Margin="-10,2,0,2" Visibility="Hidden"/>
                <ContentPresenter VerticalAlignment="Center"/>
              </Grid>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bd" Property="Background" Value="#12FFFFFF"/></Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#2676B900"/>
                <Setter TargetName="Bar" Property="Visibility" Value="Visible"/>
                <Setter Property="Foreground" Value="White"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Switch" TargetType="CheckBox">
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Margin" Value="0,4"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <Grid Background="Transparent">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="Auto"/>
                <ColumnDefinition Width="*"/>
              </Grid.ColumnDefinitions>
              <Border x:Name="Track" Width="40" Height="22" CornerRadius="11" Background="#33FFFFFF" VerticalAlignment="Center">
                <Ellipse x:Name="Thumb" Width="16" Height="16" Fill="White" HorizontalAlignment="Left" Margin="3,0"/>
              </Border>
              <ContentPresenter Grid.Column="1" Margin="12,0,0,0" VerticalAlignment="Center"/>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="Track" Property="Background" Value="{StaticResource Accent}"/>
                <Setter TargetName="Thumb" Property="HorizontalAlignment" Value="Right"/>
                <Setter TargetName="Thumb" Property="Fill" Value="Black"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.45"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="ProgressBar">
      <Setter Property="Height" Value="6"/>
      <Setter Property="Maximum" Value="100"/>
      <Setter Property="Foreground" Value="{StaticResource Accent}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ProgressBar">
            <Grid>
              <Border x:Name="PART_Track" CornerRadius="3" Background="#1FFFFFFF"/>
              <Border x:Name="PART_Indicator" CornerRadius="3" Background="{TemplateBinding Foreground}" HorizontalAlignment="Left"/>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="TextBox">
      <Setter Property="Background" Value="#0FFFFFFF"/>
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="BorderBrush" Value="{StaticResource GlassBorder}"/>
      <Setter Property="CaretBrush" Value="White"/>
      <Setter Property="Padding" Value="8,6"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TextBox">
            <Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1" CornerRadius="10">
              <ScrollViewer x:Name="PART_ContentHost" Margin="{TemplateBinding Padding}"/>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="ListView">
      <Setter Property="Background" Value="#0AFFFFFF"/>
      <Setter Property="BorderBrush" Value="{StaticResource GlassBorder}"/>
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="Padding" Value="4"/>
    </Style>
    <Style TargetType="GridViewColumnHeader">
      <Setter Property="Foreground" Value="{StaticResource TextSec}"/>
      <Setter Property="HorizontalContentAlignment" Value="Left"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="GridViewColumnHeader">
            <Border Background="#14FFFFFF" BorderBrush="#1AFFFFFF" BorderThickness="0,0,1,1" Padding="10,7">
              <ContentPresenter/>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="ListViewItem">
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ListViewItem">
            <Border x:Name="Bd" Background="Transparent" CornerRadius="6" Padding="0,5">
              <GridViewRowPresenter Columns="{TemplateBinding GridView.ColumnCollection}" Content="{TemplateBinding Content}"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bd" Property="Background" Value="#14FFFFFF"/></Trigger>
              <Trigger Property="IsSelected" Value="True"><Setter TargetName="Bd" Property="Background" Value="#4076B900"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="ListBox">
      <Setter Property="Background" Value="#0AFFFFFF"/>
      <Setter Property="BorderBrush" Value="{StaticResource GlassBorder}"/>
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="Padding" Value="4"/>
    </Style>
    <Style TargetType="ListBoxItem">
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ListBoxItem">
            <Border x:Name="Bd" Background="Transparent" CornerRadius="6" Padding="10,7">
              <ContentPresenter/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bd" Property="Background" Value="#14FFFFFF"/></Trigger>
              <Trigger Property="IsSelected" Value="True"><Setter TargetName="Bd" Property="Background" Value="#4076B900"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Border x:Name="Root" CornerRadius="12" Background="#CC0A0D12" BorderBrush="#2EFFFFFF" BorderThickness="1">
    <Grid>
      <Grid.RowDefinitions>
        <RowDefinition Height="48"/>
        <RowDefinition Height="*"/>
      </Grid.RowDefinitions>
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="214"/>
        <ColumnDefinition Width="*"/>
      </Grid.ColumnDefinitions>

      <!-- Barra de título -->
      <Grid x:Name="TitleBar" Grid.ColumnSpan="2" Background="Transparent">
        <StackPanel Orientation="Horizontal" VerticalAlignment="Center" Margin="20,0,0,0">
          <Border Width="24" Height="24" CornerRadius="12" Background="{StaticResource Accent}">
            <TextBlock Text="&#xE945;" FontFamily="Segoe MDL2 Assets" Foreground="Black" FontSize="12" HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Border>
          <TextBlock Text="Optimizador PC" FontWeight="SemiBold" FontSize="14" Margin="10,0,0,0" VerticalAlignment="Center"/>
          <Border x:Name="TurboBadge" Background="#3376B900" BorderBrush="{StaticResource Accent}" BorderThickness="1" CornerRadius="10" Padding="9,2" Margin="12,0,0,0" Visibility="Collapsed" VerticalAlignment="Center">
            <TextBlock Text="TURBO" FontSize="10" FontWeight="Bold" Foreground="{StaticResource Accent}"/>
          </Border>
        </StackPanel>
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
          <Button x:Name="BtnMin" Style="{StaticResource TitleButton}" Content="&#xE921;" ToolTip="Minimizar"/>
          <Button x:Name="BtnClose" Style="{StaticResource TitleButton}" Content="&#xE8BB;" ToolTip="Cerrar"/>
        </StackPanel>
      </Grid>

      <!-- Menú lateral -->
      <Grid Grid.Row="1">
        <StackPanel x:Name="NavPanel" Margin="0,6,0,0">
          <RadioButton Style="{StaticResource Nav}" GroupName="nav" Tag="Panel" IsChecked="True">
            <StackPanel Orientation="Horizontal"><TextBlock FontFamily="Segoe MDL2 Assets" Text="&#xE80F;" Width="28" VerticalAlignment="Center"/><TextBlock Text="Panel"/></StackPanel>
          </RadioButton>
          <RadioButton Style="{StaticResource Nav}" GroupName="nav" Tag="Sistema">
            <StackPanel Orientation="Horizontal"><TextBlock FontFamily="Segoe MDL2 Assets" Text="&#xE7F4;" Width="28" VerticalAlignment="Center"/><TextBlock Text="Sistema"/></StackPanel>
          </RadioButton>
          <RadioButton Style="{StaticResource Nav}" GroupName="nav" Tag="Optimizar">
            <StackPanel Orientation="Horizontal"><TextBlock FontFamily="Segoe MDL2 Assets" Text="&#xE945;" Width="28" VerticalAlignment="Center"/><TextBlock Text="Optimizar"/></StackPanel>
          </RadioButton>
          <RadioButton Style="{StaticResource Nav}" GroupName="nav" Tag="Procesos">
            <StackPanel Orientation="Horizontal"><TextBlock FontFamily="Segoe MDL2 Assets" Text="&#xE9D9;" Width="28" VerticalAlignment="Center"/><TextBlock Text="Procesos"/></StackPanel>
          </RadioButton>
          <RadioButton Style="{StaticResource Nav}" GroupName="nav" Tag="Arranque">
            <StackPanel Orientation="Horizontal"><TextBlock FontFamily="Segoe MDL2 Assets" Text="&#xE7E8;" Width="28" VerticalAlignment="Center"/><TextBlock Text="Arranque"/></StackPanel>
          </RadioButton>
          <RadioButton Style="{StaticResource Nav}" GroupName="nav" Tag="Juegos">
            <StackPanel Orientation="Horizontal"><TextBlock FontFamily="Segoe MDL2 Assets" Text="&#xE7FC;" Width="28" VerticalAlignment="Center"/><TextBlock Text="Mis juegos"/></StackPanel>
          </RadioButton>
          <RadioButton Style="{StaticResource Nav}" GroupName="nav" Tag="Audio">
            <StackPanel Orientation="Horizontal"><TextBlock FontFamily="Segoe MDL2 Assets" Text="&#xE767;" Width="28" VerticalAlignment="Center"/><TextBlock Text="Audio"/></StackPanel>
          </RadioButton>
          <RadioButton Style="{StaticResource Nav}" GroupName="nav" Tag="Ajustes">
            <StackPanel Orientation="Horizontal"><TextBlock FontFamily="Segoe MDL2 Assets" Text="&#xE713;" Width="28" VerticalAlignment="Center"/><TextBlock Text="Ajustes"/></StackPanel>
          </RadioButton>
        </StackPanel>
        <TextBlock x:Name="VersionText" VerticalAlignment="Bottom" Margin="24,0,0,18" Foreground="{StaticResource TextMuted}" FontSize="11"/>
      </Grid>

      <!-- Contenido -->
      <Grid Grid.Row="1" Grid.Column="1" Margin="8,4,18,18">
        <Grid.RowDefinitions>
          <RowDefinition Height="*"/>
          <RowDefinition Height="92"/>
        </Grid.RowDefinitions>
        <Grid x:Name="Pages">

          <!-- Panel -->
          <ScrollViewer x:Name="Page_Panel" VerticalScrollBarVisibility="Auto">
            <StackPanel>
              <TextBlock Style="{StaticResource H1}" Text="Panel"/>
              <TextBlock Style="{StaticResource Sub}" Text="Estado del equipo en tiempo real y acciones rápidas."/>
              <UniformGrid Columns="4">
                <Border Style="{StaticResource Card}">
                  <StackPanel>
                    <TextBlock Style="{StaticResource CardTitle}" Text="CPU"/>
                    <TextBlock x:Name="CpuText" Style="{StaticResource Big}" Text="--"/>
                    <ProgressBar x:Name="CpuBar"/>
                    <TextBlock x:Name="CpuSub" Style="{StaticResource Small}"/>
                  </StackPanel>
                </Border>
                <Border Style="{StaticResource Card}">
                  <StackPanel>
                    <TextBlock Style="{StaticResource CardTitle}" Text="MEMORIA RAM"/>
                    <TextBlock x:Name="RamText" Style="{StaticResource Big}" Text="--"/>
                    <ProgressBar x:Name="RamBar"/>
                    <TextBlock x:Name="RamSub" Style="{StaticResource Small}"/>
                  </StackPanel>
                </Border>
                <Border Style="{StaticResource Card}">
                  <StackPanel>
                    <TextBlock Style="{StaticResource CardTitle}" Text="GPU"/>
                    <TextBlock x:Name="GpuText" Style="{StaticResource Big}" Text="--"/>
                    <ProgressBar x:Name="GpuBar"/>
                    <TextBlock x:Name="GpuSub" Style="{StaticResource Small}"/>
                  </StackPanel>
                </Border>
                <Border Style="{StaticResource Card}">
                  <StackPanel>
                    <TextBlock Style="{StaticResource CardTitle}" Text="DISCO DEL SISTEMA"/>
                    <TextBlock x:Name="DiskText" Style="{StaticResource Big}" Text="--"/>
                    <ProgressBar x:Name="DiskBar"/>
                    <TextBlock x:Name="DiskSub" Style="{StaticResource Small}"/>
                  </StackPanel>
                </Border>
              </UniformGrid>
              <Grid>
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="*"/>
                  <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>
                <Border Style="{StaticResource Card}">
                  <StackPanel>
                    <DockPanel>
                      <CheckBox x:Name="TurboSwitch" Style="{StaticResource Switch}" DockPanel.Dock="Right"/>
                      <TextBlock Text="Modo Turbo" FontSize="16" FontWeight="SemiBold" VerticalAlignment="Center"/>
                    </DockPanel>
                    <TextBlock Style="{StaticResource Sub}" Margin="0,6,0,12" Text="Activa el plan de energía de máximo rendimiento y libera la memoria en espera. Al desactivarlo vuelve tu plan anterior. Se activa solo cuando abres un juego de tu lista."/>
                    <WrapPanel>
                      <Button x:Name="BtnPurge" Style="{StaticResource GlassButton}" Content="Liberar memoria"/>
                      <Button x:Name="BtnTempQuick" Style="{StaticResource GlassButton}" Content="Limpiar temporales"/>
                      <Button x:Name="BtnVolQuick" Style="{StaticResource GlassButton}" Content="Volumen al 100%"/>
                    </WrapPanel>
                  </StackPanel>
                </Border>
                <Border Grid.Column="1" Style="{StaticResource Card}">
                  <StackPanel>
                    <TextBlock Text="Recomendaciones para tu PC" FontSize="16" FontWeight="SemiBold" Margin="0,0,0,10"/>
                    <TextBlock x:Name="RecText" TextWrapping="Wrap" Foreground="#C9D1DB" LineHeight="20" Text="Analizando el equipo..."/>
                  </StackPanel>
                </Border>
              </Grid>
            </StackPanel>
          </ScrollViewer>

          <!-- Sistema -->
          <DockPanel x:Name="Page_Sistema" Visibility="Collapsed">
            <StackPanel DockPanel.Dock="Top">
              <TextBlock Style="{StaticResource H1}" Text="Sistema y dual channel"/>
              <TextBlock Style="{StaticResource Sub}" Text="Hardware detectado, estado de la RAM y mantenimiento del disco."/>
            </StackPanel>
            <WrapPanel DockPanel.Dock="Bottom" Margin="0,10,0,0">
              <Button x:Name="BtnAnalyze" Style="{StaticResource GlassButton}" Content="Analizar de nuevo"/>
              <Button x:Name="BtnDrivers" Style="{StaticResource GlassButton}" Content="Drivers de la GPU"/>
              <Button x:Name="BtnDefrag" Style="{StaticResource GlassButton}" Content="Optimizar disco C:"/>
              <Button x:Name="BtnRestore" Style="{StaticResource GlassButton}" Content="Crear punto de restauración"/>
            </WrapPanel>
            <TextBox x:Name="InfoBox" IsReadOnly="True" FontFamily="Consolas" FontSize="12.5" HorizontalScrollBarVisibility="Auto" VerticalScrollBarVisibility="Auto"/>
          </DockPanel>

          <!-- Optimizar -->
          <DockPanel x:Name="Page_Optimizar" Visibility="Collapsed">
            <StackPanel DockPanel.Dock="Top">
              <TextBlock Style="{StaticResource H1}" Text="Optimizar Windows"/>
              <TextBlock Style="{StaticResource Sub}" Text="Elige los ajustes y pulsa Aplicar. Los valores originales se guardan y puedes revertirlos cuando quieras. Algunos cambios requieren reiniciar."/>
            </StackPanel>
            <WrapPanel DockPanel.Dock="Bottom" Margin="0,10,0,0">
              <Button x:Name="BtnRestore2" Style="{StaticResource GlassButton}" Content="Crear punto de restauración"/>
              <Button x:Name="BtnApply" Style="{StaticResource AccentButton}" Content="Aplicar seleccionados"/>
              <Button x:Name="BtnUndo" Style="{StaticResource GlassButton}" Content="Revertir cambios"/>
            </WrapPanel>
            <ScrollViewer VerticalScrollBarVisibility="Auto">
              <StackPanel x:Name="OptList"/>
            </ScrollViewer>
          </DockPanel>

          <!-- Procesos -->
          <DockPanel x:Name="Page_Procesos" Visibility="Collapsed">
            <StackPanel DockPanel.Dock="Top">
              <TextBlock Style="{StaticResource H1}" Text="Procesos"/>
              <TextBlock Style="{StaticResource Sub}" Text="Los programas que más RAM usan. Selecciona uno o varios (Ctrl + clic) para cerrarlos antes de jugar, o dale prioridad alta al juego."/>
            </StackPanel>
            <WrapPanel DockPanel.Dock="Bottom" Margin="0,10,0,0">
              <Button x:Name="BtnProcRefresh" Style="{StaticResource GlassButton}" Content="Actualizar"/>
              <Button x:Name="BtnProcKill" Style="{StaticResource GlassButton}" Content="Cerrar seleccionados"/>
              <Button x:Name="BtnProcHigh" Style="{StaticResource GlassButton}" Content="Prioridad alta"/>
              <Button x:Name="BtnProcGame" Style="{StaticResource AccentButton}" Content="Añadir a mis juegos"/>
            </WrapPanel>
            <ListView x:Name="ProcList" SelectionMode="Extended">
              <ListView.View>
                <GridView>
                  <GridViewColumn Header="Proceso" Width="300" DisplayMemberBinding="{Binding Name}"/>
                  <GridViewColumn Header="PID" Width="90" DisplayMemberBinding="{Binding Id}"/>
                  <GridViewColumn Header="RAM (MB)" Width="120" DisplayMemberBinding="{Binding RamMB}"/>
                  <GridViewColumn Header="Prioridad" Width="140" DisplayMemberBinding="{Binding Priority}"/>
                </GridView>
              </ListView.View>
            </ListView>
          </DockPanel>

          <!-- Arranque -->
          <DockPanel x:Name="Page_Arranque" Visibility="Collapsed">
            <StackPanel DockPanel.Dock="Top">
              <TextBlock Style="{StaticResource H1}" Text="Programas de arranque"/>
              <TextBlock Style="{StaticResource Sub}" Text="Cada programa que arranca con Windows hace más lento el inicio, sobre todo en discos HDD. Desactivar no lo desinstala: igual que en el Administrador de tareas, puedes volver a activarlo. El cambio se nota en el próximo reinicio."/>
            </StackPanel>
            <WrapPanel DockPanel.Dock="Bottom" Margin="0,10,0,0">
              <Button x:Name="BtnStartRefresh" Style="{StaticResource GlassButton}" Content="Actualizar"/>
              <Button x:Name="BtnStartOff" Style="{StaticResource AccentButton}" Content="Desactivar seleccionados"/>
              <Button x:Name="BtnStartOn" Style="{StaticResource GlassButton}" Content="Activar seleccionados"/>
            </WrapPanel>
            <ListView x:Name="StartList" SelectionMode="Extended">
              <ListView.View>
                <GridView>
                  <GridViewColumn Header="Programa" Width="230" DisplayMemberBinding="{Binding Name}"/>
                  <GridViewColumn Header="Estado" Width="110" DisplayMemberBinding="{Binding Estado}"/>
                  <GridViewColumn Header="Origen" Width="190" DisplayMemberBinding="{Binding Location}"/>
                  <GridViewColumn Header="Comando" Width="420" DisplayMemberBinding="{Binding Command}"/>
                </GridView>
              </ListView.View>
            </ListView>
          </DockPanel>

          <!-- Mis juegos -->
          <DockPanel x:Name="Page_Juegos" Visibility="Collapsed">
            <StackPanel DockPanel.Dock="Top">
              <TextBlock Style="{StaticResource H1}" Text="Mis juegos"/>
              <TextBlock Style="{StaticResource Sub}" Text="Cuando abras uno de estos programas, el optimizador lo detecta (también desde la bandeja), le da prioridad alta y activa el Modo Turbo. Al cerrarlo, todo vuelve a la normalidad."/>
              <DockPanel Margin="0,0,0,10">
                <Button x:Name="BtnGameRemove" DockPanel.Dock="Right" Style="{StaticResource GlassButton}" Content="Quitar" Margin="8,0,0,0"/>
                <Button x:Name="BtnGameBrowse" DockPanel.Dock="Right" Style="{StaticResource GlassButton}" Content="Buscar .exe..." Margin="8,0,0,0"/>
                <Button x:Name="BtnGameAdd" DockPanel.Dock="Right" Style="{StaticResource AccentButton}" Content="Agregar" Margin="8,0,0,0"/>
                <TextBox x:Name="GameInput" ToolTip="Nombre del ejecutable, por ejemplo GTA5.exe"/>
              </DockPanel>
            </StackPanel>
            <Border DockPanel.Dock="Bottom" Style="{StaticResource Card}" Margin="0,10,0,0">
              <StackPanel>
                <CheckBox x:Name="GameAutoPriority" Style="{StaticResource Switch}" Content="Dar prioridad alta al juego"/>
                <CheckBox x:Name="GameAutoTurbo" Style="{StaticResource Switch}" Content="Activar el Modo Turbo mientras juego"/>
                <CheckBox x:Name="GameNotify" Style="{StaticResource Switch}" Content="Avisarme con una notificación"/>
                <TextBlock x:Name="GameStatus" Foreground="{StaticResource Accent}" Margin="0,8,0,0"/>
              </StackPanel>
            </Border>
            <ListBox x:Name="GamesList" SelectionMode="Extended"/>
          </DockPanel>

          <!-- Audio -->
          <DockPanel x:Name="Page_Audio" Visibility="Collapsed">
            <StackPanel DockPanel.Dock="Top">
              <TextBlock Style="{StaticResource H1}" Text="Audio"/>
              <TextBlock Style="{StaticResource Sub}" Text="Volumen del altavoz, mejoras de sonido y solución de problemas."/>
              <Border Style="{StaticResource Card}" Margin="0,0,0,10">
                <DockPanel>
                  <CheckBox x:Name="MuteSwitch" Style="{StaticResource Switch}" Content="Silenciado" DockPanel.Dock="Right" Margin="16,0,0,0"/>
                  <TextBlock x:Name="VolText" DockPanel.Dock="Right" FontSize="18" FontWeight="SemiBold" Width="56" TextAlignment="Right" VerticalAlignment="Center"/>
                  <TextBlock Text="Volumen" FontSize="15" FontWeight="SemiBold" DockPanel.Dock="Left" Width="90" VerticalAlignment="Center"/>
                  <Slider x:Name="VolSlider" Minimum="0" Maximum="100" IsMoveToPointEnabled="True" VerticalAlignment="Center" Margin="0,0,12,0"/>
                </DockPanel>
              </Border>
              <WrapPanel>
                <Button x:Name="BtnVolMax" Style="{StaticResource AccentButton}" Content="Volumen al 100%"/>
                <Button x:Name="BtnDucking" Style="{StaticResource GlassButton}" Content="No bajar volumen en llamadas"/>
                <Button x:Name="BtnAudioRst" Style="{StaticResource GlassButton}" Content="Reiniciar servicio de audio"/>
                <Button x:Name="BtnMmsys" Style="{StaticResource GlassButton}" Content="Panel de sonido (Mejoras)"/>
                <Button x:Name="BtnAppVol" Style="{StaticResource GlassButton}" Content="Volumen por aplicación"/>
                <Button x:Name="BtnApo" Style="{StaticResource GlassButton}" Content="Equalizer APO"/>
                <Button x:Name="BtnAudioRef" Style="{StaticResource GlassButton}" Content="Analizar de nuevo"/>
              </WrapPanel>
            </StackPanel>
            <TextBox x:Name="AudioInfo" IsReadOnly="True" FontFamily="Consolas" FontSize="12.5" HorizontalScrollBarVisibility="Auto" VerticalScrollBarVisibility="Auto" Margin="0,4,0,0"/>
          </DockPanel>

          <!-- Ajustes -->
          <ScrollViewer x:Name="Page_Ajustes" Visibility="Collapsed" VerticalScrollBarVisibility="Auto">
            <StackPanel>
              <TextBlock Style="{StaticResource H1}" Text="Ajustes"/>
              <TextBlock Style="{StaticResource Sub}" Text="Comportamiento del programa y de la bandeja del sistema."/>
              <Border Style="{StaticResource Card}">
                <StackPanel>
                  <CheckBox x:Name="AutoStartSwitch" Style="{StaticResource Switch}" Content="Iniciar con Windows (minimizado en la bandeja, sin aviso de permisos)"/>
                  <CheckBox x:Name="CloseTraySwitch" Style="{StaticResource Switch}" Content="Al cerrar la ventana, seguir funcionando en la bandeja del sistema"/>
                  <CheckBox x:Name="WidgetSwitch" Style="{StaticResource Switch}" Content="Mostrar el widget flotante (CPU, RAM, red y pulsador para liberar RAM)"/>
                </StackPanel>
              </Border>
              <Border Style="{StaticResource Card}">
                <StackPanel>
                  <TextBlock Text="Archivos del programa" FontSize="15" FontWeight="SemiBold" Margin="0,0,0,8"/>
                  <TextBlock x:Name="PathsText" Style="{StaticResource Sub}" FontFamily="Consolas"/>
                  <WrapPanel>
                    <Button x:Name="BtnOpenFolder" Style="{StaticResource GlassButton}" Content="Abrir carpeta del programa"/>
                    <Button x:Name="BtnExit" Style="{StaticResource GlassButton}" Content="Salir del optimizador"/>
                  </WrapPanel>
                </StackPanel>
              </Border>
            </StackPanel>
          </ScrollViewer>
        </Grid>

        <TextBox x:Name="LogBox" Grid.Row="1" Margin="0,6,0,0" IsReadOnly="True" FontFamily="Consolas" FontSize="11.5"
                 VerticalScrollBarVisibility="Auto" TextWrapping="Wrap" Foreground="#9AA4B2"/>
      </Grid>
    </Grid>
  </Border>
</Window>
'@

try {
    $script:Window = [System.Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
} catch {
    [System.Windows.MessageBox]::Show("No se pudo crear la interfaz:`n$($_.Exception.Message)", 'Optimizador PC', 'OK', 'Error') | Out-Null
    exit 1
}
$window = $script:Window
foreach ($n in $xaml.SelectNodes("//*[@*[local-name()='Name']]")) {
    $name = $n.GetAttribute('Name', 'http://schemas.microsoft.com/winfx/2006/xaml')
    if ($name) { $script:ui[$name] = $window.FindName($name) }
}
$ui = $script:ui
foreach ($line in $script:PendingLog) { $ui.LogBox.AppendText($line + "`r`n") }
$script:PendingLog = @()

$PageNames = 'Panel', 'Sistema', 'Optimizar', 'Procesos', 'Arranque', 'Juegos', 'Audio', 'Ajustes'
$ui.VersionText.Text = "Optimizador PC $AppVersion"
$ui.PathsText.Text = "Programa:  $ScriptPath`nAjustes:   $SettingsFile`nRespaldo:  $BackupFile"

# --- Icono (rayo sobre círculo verde; naranja en Modo Turbo) --------------------
function New-AppIcon([System.Drawing.Color]$color) {
    $bmp = New-Object System.Drawing.Bitmap 32, 32
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([System.Drawing.Color]::Transparent)
    $brush = New-Object System.Drawing.SolidBrush $color
    $g.FillEllipse($brush, 1, 1, 30, 30)
    $pts = [System.Drawing.Point[]]@(
        (New-Object System.Drawing.Point 18, 4), (New-Object System.Drawing.Point 8, 18), (New-Object System.Drawing.Point 15, 18),
        (New-Object System.Drawing.Point 13, 28), (New-Object System.Drawing.Point 24, 13), (New-Object System.Drawing.Point 17, 13)
    )
    $g.FillPolygon([System.Drawing.Brushes]::Black, $pts)
    $brush.Dispose(); $g.Dispose()
    [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
}
$script:IconNormal = New-AppIcon ([System.Drawing.Color]::FromArgb(118, 185, 0))
$script:IconTurbo  = New-AppIcon ([System.Drawing.Color]::FromArgb(255, 140, 0))
try {
    $window.Icon = [System.Windows.Interop.Imaging]::CreateBitmapSourceFromHIcon($script:IconNormal.Handle,
        [System.Windows.Int32Rect]::Empty, [System.Windows.Media.Imaging.BitmapSizeOptions]::FromEmptyOptions())
} catch {}

# --- Navegación ----------------------------------------------------------------
$script:Loaded = @{}
function Show-Page($page) {
    foreach ($p in $PageNames) {
        $ui["Page_$p"].Visibility = if ($p -eq $page) { 'Visible' } else { 'Collapsed' }
    }
    try {
        switch ($page) {
            'Procesos' { $ui.ProcList.ItemsSource = @(Get-ProcessRows) }
            'Arranque' { if (-not $script:Loaded.Arranque) { Update-StartupList; $script:Loaded.Arranque = $true } }
            'Audio'    { if (-not $script:Loaded.Audio) { Update-AudioPage; $script:Loaded.Audio = $true } else { Update-VolumeUi } }
            'Ajustes'  { $ui.AutoStartSwitch.IsChecked = Get-Autostart }
        }
    } catch { Log "Error: $($_.Exception.Message)" }
}
foreach ($rb in $ui.NavPanel.Children) {
    $rb.Add_Checked({ param($s, $e) Show-Page $s.Tag })
}

# --- Ventana: arrastrar, minimizar, cerrar a la bandeja --------------------------
$script:Exiting = $false
$ui.TitleBar.Add_MouseLeftButtonDown({ try { $window.DragMove() } catch {} })
$ui.BtnMin.Add_Click({ $window.WindowState = 'Minimized' })
$ui.BtnClose.Add_Click({ $window.Close() })
$ui.BtnExit.Add_Click({ Exit-App })

$window.Add_Closing({
    param($s, $e)
    if ($script:Exiting) { return }
    if (-not $script:Settings.CloseToTray) {
        # Cerrar de verdad: no se puede llamar a Close() de nuevo mientras la ventana se está cerrando
        $script:Exiting = $true
        Stop-App
        [void]$script:App.Dispatcher.BeginInvoke([action]{ $script:App.Shutdown() })
        return
    }
    $e.Cancel = $true
    $window.Hide()
    if (-not $script:Settings.TrayHintShown) {
        $script:Tray.ShowBalloonTip(5000, 'Optimizador PC', 'Sigo funcionando aquí. Haz clic en el icono para abrirme o clic derecho para el menú.', [System.Windows.Forms.ToolTipIcon]::Info)
        $script:Settings.TrayHintShown = $true
        Save-Settings
    }
})

$window.Add_SourceInitialized({
    if ($script:NativeOk) {
        try { [void][OptWin]::EnableBlur((New-Object System.Windows.Interop.WindowInteropHelper $window).Handle) } catch {}
    }
})

function Show-Main {
    $window.Show()
    if ($window.WindowState -eq 'Minimized') { $window.WindowState = 'Normal' }
    $window.Activate() | Out-Null
    Initialize-Data
}

$script:Stopped = $false
function Stop-App {
    if ($script:Stopped) { return }
    $script:Stopped = $true
    try { Disable-Turbo } catch {}
    $script:Timer.Stop()
    $script:FastTimer.Stop()
    $script:WidgetTimer.Stop()
    $script:Widget.Close()
    $script:Tray.Visible = $false
    $script:Tray.Dispose()
}

function Exit-App {
    $script:Exiting = $true
    Stop-App
    $window.Close()
    $script:App.Shutdown()
}

# --- Carga inicial de datos (al mostrar la ventana por primera vez) -------------
$script:Initialized = $false
function Initialize-Data {
    if ($script:Initialized) { return }
    $script:Initialized = $true
    Set-Busy $true
    try {
        $script:Hw = Get-HardwareFacts
        $ui.RecText.Text = Get-Recommendations
        $ui.CpuSub.Text = "$($script:Hw.CpuName) · $($script:Hw.CpuDesc)"
        Build-OptList
        $ui.InfoBox.Text = Get-SystemReport
        Log 'Análisis completo. Recomendado: crea un punto de restauración antes de aplicar ajustes.'
    } catch { Log "Error al analizar el equipo: $($_.Exception.Message)" }
    Set-Busy $false
    Update-Monitor
}
$window.Add_ContentRendered({ Initialize-Data })

# --- Panel -----------------------------------------------------------------------
$ui.TurboSwitch.Add_Click({
    Set-Busy $true
    try {
        if ($ui.TurboSwitch.IsChecked) { Enable-Turbo } else { Disable-Turbo }
    } catch { Log "Error en Modo Turbo: $($_.Exception.Message)" }
    Set-Busy $false
})
$ui.BtnPurge.Add_Click({ Set-Busy $true; try { Clear-StandbyMemory } catch { Log "Error: $($_.Exception.Message)" }; Set-Busy $false })
$ui.BtnTempQuick.Add_Click({ Set-Busy $true; try { Clear-TempFiles } catch { Log "Error: $($_.Exception.Message)" }; Set-Busy $false })
$ui.BtnVolQuick.Add_Click({ try { Set-MaxVolume } catch { Log "No se pudo cambiar el volumen: $($_.Exception.Message)" } })

# --- Sistema -------------------------------------------------------------------------
$ui.BtnAnalyze.Add_Click({
    Set-Busy $true
    try {
        $script:Hw = Get-HardwareFacts
        $ui.InfoBox.Text = Get-SystemReport
        $ui.RecText.Text = Get-Recommendations
        Log 'Análisis actualizado.'
    } catch { Log "Error al analizar: $($_.Exception.Message)" }
    Set-Busy $false
})

$ui.BtnDrivers.Add_Click({
    $name = ($script:Hw.Gpus | ForEach-Object { $_.Name }) -join ' '
    $url = if ($name -match 'NVIDIA') { 'https://www.nvidia.com/es-la/drivers/' }
           elseif ($name -match 'AMD|Radeon') { 'https://www.amd.com/es/support/download/drivers.html' }
           else { 'https://www.intel.com/content/www/us/en/support/detect.html' }
    Start-Process $url
    Log "Abriendo página de drivers: $url"
})

$ui.BtnDefrag.Add_Click({
    Start-BgTask 'Optimizar disco C:' {
        try {
            Optimize-Volume -DriveLetter C -ErrorAction Stop
            'Disco C: optimizado (desfragmentado si es HDD, TRIM si es SSD).'
        } catch { "No se pudo optimizar: $($_.Exception.Message)" }
    }
})

$restoreBlock = {
    try {
        Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction SilentlyContinue
        Checkpoint-Computer -Description 'Optimizador PC' -RestorePointType MODIFY_SETTINGS -ErrorAction Stop -WarningVariable w 3>$null
        if ($w) { "Aviso: $w" } else { 'Punto de restauración creado.' }
    } catch { "No se pudo crear el punto de restauración: $($_.Exception.Message)" }
}
$ui.BtnRestore.Add_Click({ Start-BgTask 'Punto de restauración' $restoreBlock })
$ui.BtnRestore2.Add_Click({ Start-BgTask 'Punto de restauración' $restoreBlock })

# --- Optimizar -----------------------------------------------------------------------
$script:OptDefs = @(
    @{ T = 'Plan de energía de máximo rendimiento'; D = 'La CPU no baja su frecuencia. En portátiles, úsalo enchufado: gasta más batería.'; A = { Set-PerformancePlan } }
    @{ T = 'Programación de GPU acelerada por hardware (HAGS)'; D = 'Reduce la latencia de la GPU. Requiere reiniciar.'; A = { Enable-Hags }; Hags = $true }
    @{ T = 'Activar Modo juego de Windows'; D = 'Windows prioriza el juego y pausa actualizaciones mientras juegas.'; A = { Enable-GameMode } }
    @{ T = 'Desactivar grabación en segundo plano (Xbox Game Bar)'; D = 'Evita que Windows grabe la pantalla continuamente mientras juegas.'; A = { Disable-GameDvr } }
    @{ T = 'Prioridad multimedia para juegos (CPU/GPU/red)'; D = 'Asigna más tiempo de CPU y GPU a las tareas de juego.'; A = { Set-MultimediaProfile } }
    @{ T = 'Desactivar apps de la Tienda en segundo plano'; D = 'Las apps como Correo, Fotos o Noticias dejan de ejecutarse cuando no las usas.'; A = { Disable-BackgroundApps } }
    @{ T = 'Desactivar transparencias de Windows'; D = 'Libera un poco de GPU, útil con gráficos integrados.'; A = { Disable-Transparency } }
    @{ T = 'Archivo de paginación administrado por el sistema'; D = 'Evita cierres por falta de memoria. No aumenta los FPS.'; A = { Set-AutoPagefile } }
    @{ T = 'Limpiar archivos temporales'; D = 'Borra la carpeta temporal del usuario, la de Windows y la caché de Windows Update.'; A = { Clear-TempFiles } }
)
$script:OptChecks = @()

function Build-OptList {
    $ui.OptList.Children.Clear()
    $script:OptChecks = @()
    $switchStyle = $window.FindResource('Switch')
    $cardStyle = $window.FindResource('Card')
    foreach ($o in $script:OptDefs) {
        $card = New-Object System.Windows.Controls.Border
        $card.Style = $cardStyle
        $card.Margin = New-Object System.Windows.Thickness(0, 0, 0, 8)
        $card.Padding = New-Object System.Windows.Thickness(14, 12, 14, 12)

        $text = New-Object System.Windows.Controls.StackPanel
        $title = New-Object System.Windows.Controls.TextBlock
        $title.Text = $o.T; $title.FontSize = 14; $title.FontWeight = [System.Windows.FontWeights]::SemiBold
        $desc = New-Object System.Windows.Controls.TextBlock
        $desc.Text = $o.D; $desc.TextWrapping = 'Wrap'; $desc.Margin = New-Object System.Windows.Thickness(0, 2, 0, 0)
        $desc.Foreground = $window.FindResource('TextSec')
        [void]$text.Children.Add($title); [void]$text.Children.Add($desc)

        $cb = New-Object System.Windows.Controls.CheckBox
        $cb.Style = $switchStyle
        $cb.Content = $text
        $cb.IsChecked = $true
        $cb.Tag = $o.A
        if ($o.Hags -and -not $script:Hw.HagsSupported) {
            $cb.IsChecked = $false
            $cb.IsEnabled = $false
            $desc.Text += ' No compatible con tu GPU o su driver (necesita WDDM 2.7 o superior).'
        }
        $card.Child = $cb
        [void]$ui.OptList.Children.Add($card)
        $script:OptChecks += $cb
    }
}

$ui.BtnApply.Add_Click({
    Set-Busy $true
    foreach ($cb in $script:OptChecks) {
        if (-not $cb.IsChecked) { continue }
        try { & $cb.Tag } catch { Log "Error: $($_.Exception.Message)" }
    }
    Save-Backup
    Log 'Listo. Reinicia el equipo para aplicar todos los cambios.'
    Set-Busy $false
})

$ui.BtnUndo.Add_Click({
    if (-not (Test-Path $BackupFile)) { Log 'No hay cambios guardados para revertir.'; return }
    $ok = [System.Windows.MessageBox]::Show('¿Restaurar los valores que había antes de optimizar?', 'Revertir', 'YesNo', 'Question')
    if ($ok -eq 'Yes') { try { Undo-Optimizations } catch { Log "Error al revertir: $($_.Exception.Message)" } }
})

# --- Procesos ------------------------------------------------------------------------
$ui.BtnProcRefresh.Add_Click({ $ui.ProcList.ItemsSource = @(Get-ProcessRows) })

$ui.BtnProcKill.Add_Click({
    $sel = @($ui.ProcList.SelectedItems)
    if ($sel.Count -eq 0) { Log 'Selecciona uno o varios procesos primero.'; return }
    $names = ($sel | ForEach-Object { $_.Name }) -join ', '
    $ok = [System.Windows.MessageBox]::Show("Se cerrarán: $names`n`nLo no guardado en esos programas se perderá. ¿Continuar?", 'Cerrar procesos', 'YesNo', 'Warning')
    if ($ok -ne 'Yes') { return }
    foreach ($it in $sel) {
        try { Stop-Process -Id $it.Id -Force -ErrorAction Stop; Log "Cerrado: $($it.Name)" }
        catch { Log "No se pudo cerrar $($it.Name): $($_.Exception.Message)" }
    }
    $ui.ProcList.ItemsSource = @(Get-ProcessRows)
})

$ui.BtnProcHigh.Add_Click({
    $sel = @($ui.ProcList.SelectedItems)
    if ($sel.Count -eq 0) { Log 'Selecciona el juego en la lista primero.'; return }
    foreach ($it in $sel) {
        try {
            (Get-Process -Id $it.Id -ErrorAction Stop).PriorityClass = 'High'
            Log "Prioridad ALTA aplicada a $($it.Name). Se pierde al cerrarlo (añádelo a Mis juegos para que sea automático)."
        } catch { Log "No se pudo cambiar la prioridad de $($it.Name): $($_.Exception.Message)" }
    }
    $ui.ProcList.ItemsSource = @(Get-ProcessRows)
})

$ui.BtnProcGame.Add_Click({
    $sel = @($ui.ProcList.SelectedItems)
    if ($sel.Count -eq 0) { Log 'Selecciona el juego en la lista primero.'; return }
    foreach ($it in $sel) { Add-Game "$($it.Name).exe" }
})

# --- Arranque ------------------------------------------------------------------------
function Update-StartupList { $ui.StartList.ItemsSource = @(Get-StartupItems) }

function Set-SelectedStartup([bool]$enable) {
    $sel = @($ui.StartList.SelectedItems)
    if ($sel.Count -eq 0) { Log 'Selecciona uno o varios programas primero.'; return }
    foreach ($it in $sel) {
        try {
            Set-StartupItem $it $enable
            Log ('{0}: {1} al iniciar Windows.' -f $it.Name, $(if ($enable) { 'activado' } else { 'desactivado' }))
        } catch { Log "No se pudo cambiar $($it.Name): $($_.Exception.Message)" }
    }
    Update-StartupList
}
$ui.BtnStartRefresh.Add_Click({ try { Update-StartupList } catch { Log "Error: $($_.Exception.Message)" } })
$ui.BtnStartOff.Add_Click({ Set-SelectedStartup $false })
$ui.BtnStartOn.Add_Click({ Set-SelectedStartup $true })

# --- Mis juegos ----------------------------------------------------------------------
function Update-GamesList {
    $ui.GamesList.ItemsSource = $null
    $ui.GamesList.ItemsSource = @($script:Settings.Games)
}

function Add-Game($exe) {
    $exe = "$exe".Trim()
    if (-not $exe) { return }
    if ($exe -notmatch '\.exe$') { $exe += '.exe' }
    $exe = [IO.Path]::GetFileName($exe)
    if (@($script:Settings.Games) -contains $exe) { Log "$exe ya está en tu lista."; return }
    $script:Settings.Games = @($script:Settings.Games) + $exe
    Save-Settings
    Update-GamesList
    Log "Juego añadido: $exe"
}

$ui.BtnGameAdd.Add_Click({ Add-Game $ui.GameInput.Text; $ui.GameInput.Text = '' })
$ui.GameInput.Add_KeyDown({ param($s, $e) if ($e.Key -eq 'Return') { Add-Game $ui.GameInput.Text; $ui.GameInput.Text = '' } })
$ui.BtnGameBrowse.Add_Click({
    $dlg = New-Object Microsoft.Win32.OpenFileDialog
    $dlg.Filter = 'Programas (*.exe)|*.exe'
    $dlg.Title = 'Elige el ejecutable del juego'
    if ($dlg.ShowDialog($window)) { Add-Game $dlg.FileName }
})
$ui.BtnGameRemove.Add_Click({
    $sel = @($ui.GamesList.SelectedItems)
    if ($sel.Count -eq 0) { return }
    $script:Settings.Games = @($script:Settings.Games | Where-Object { $sel -notcontains $_ })
    Save-Settings
    Update-GamesList
    Log "Quitado de la lista: $($sel -join ', ')"
})

$ui.GameAutoPriority.IsChecked = [bool]$script:Settings.AutoPriority
$ui.GameAutoTurbo.IsChecked = [bool]$script:Settings.AutoTurbo
$ui.GameNotify.IsChecked = [bool]$script:Settings.Notify
$ui.GameAutoPriority.Add_Click({ $script:Settings.AutoPriority = [bool]$ui.GameAutoPriority.IsChecked; Save-Settings })
$ui.GameAutoTurbo.Add_Click({ $script:Settings.AutoTurbo = [bool]$ui.GameAutoTurbo.IsChecked; Save-Settings })
$ui.GameNotify.Add_Click({ $script:Settings.Notify = [bool]$ui.GameNotify.IsChecked; Save-Settings })
Update-GamesList

# --- Audio ---------------------------------------------------------------------------
$script:VolUpdating = $false
function Update-VolumeUi {
    if (-not $script:AudioOk) {
        $ui.VolSlider.IsEnabled = $false; $ui.MuteSwitch.IsEnabled = $false; $ui.VolText.Text = 'N/D'
        return
    }
    try {
        $script:VolUpdating = $true
        $ui.VolSlider.Value = [math]::Round([OptAudio]::Volume * 100)
        $ui.MuteSwitch.IsChecked = [OptAudio]::Mute
        $ui.VolText.Text = "$([int]$ui.VolSlider.Value)%"
        $ui.VolSlider.IsEnabled = $true
    } catch {
        $ui.VolText.Text = '--'
        $ui.VolSlider.IsEnabled = $false
    } finally { $script:VolUpdating = $false }
}

function Update-AudioPage {
    Set-Busy $true
    try { $ui.AudioInfo.Text = Get-AudioReport } catch { Log "Error al analizar el audio: $($_.Exception.Message)" }
    Update-VolumeUi
    Set-Busy $false
}

$ui.VolSlider.Add_ValueChanged({
    $ui.VolText.Text = "$([int]$ui.VolSlider.Value)%"
    if ($script:VolUpdating) { return }
    try { [OptAudio]::Volume = [float]($ui.VolSlider.Value / 100) } catch {}
})
$ui.MuteSwitch.Add_Click({ try { [OptAudio]::Mute = [bool]$ui.MuteSwitch.IsChecked } catch {} })
$ui.BtnVolMax.Add_Click({ try { Set-MaxVolume } catch { Log "No se pudo cambiar el volumen: $($_.Exception.Message)" } })
$ui.BtnDucking.Add_Click({ try { Disable-AudioDucking } catch { Log "Error: $($_.Exception.Message)" } })
$ui.BtnAudioRst.Add_Click({
    Set-Busy $true
    try { Restart-AudioServices } catch { Log "No se pudo reiniciar el audio: $($_.Exception.Message)" }
    Start-Sleep -Seconds 2
    Update-VolumeUi
    Set-Busy $false
})
$ui.BtnMmsys.Add_Click({
    Start-Process 'control.exe' 'mmsys.cpl,,0'
    Log 'Panel de sonido: doble clic en el altavoz -> "Mejoras" -> "Ecualización de sonoridad" -> Aceptar.'
})
$ui.BtnAppVol.Add_Click({ Start-Process 'ms-settings:apps-volume' })
$ui.BtnApo.Add_Click({
    Start-Process 'https://sourceforge.net/projects/equalizerapo/'
    Log 'Equalizer APO: al instalar marca tu altavoz, reinicia, y luego instala "Peace" para una interfaz sencilla.'
})
$ui.BtnAudioRef.Add_Click({ Update-AudioPage })

# --- Ajustes -------------------------------------------------------------------------
$ui.CloseTraySwitch.IsChecked = [bool]$script:Settings.CloseToTray
$ui.CloseTraySwitch.Add_Click({ $script:Settings.CloseToTray = [bool]$ui.CloseTraySwitch.IsChecked; Save-Settings })
$ui.WidgetSwitch.Add_Click({ Set-Widget ([bool]$ui.WidgetSwitch.IsChecked) })
$ui.AutoStartSwitch.Add_Click({
    try { Set-Autostart ([bool]$ui.AutoStartSwitch.IsChecked) }
    catch { Log "No se pudo cambiar el inicio automático: $($_.Exception.Message)" }
    $ui.AutoStartSwitch.IsChecked = Get-Autostart
})
$ui.BtnOpenFolder.Add_Click({ Start-Process explorer.exe $PSScriptRoot })

# --- Bandeja del sistema ---------------------------------------------------------------
$script:Tray = New-Object System.Windows.Forms.NotifyIcon
$script:Tray.Icon = $script:IconNormal
$script:Tray.Text = 'Optimizador PC'

$menu = New-Object System.Windows.Forms.ContextMenuStrip
if ($script:DarkMenuOk) { $menu.Renderer = New-Object System.Windows.Forms.ToolStripProfessionalRenderer (New-Object OptDarkColors) }
$menu.BackColor = [System.Drawing.Color]::FromArgb(22, 25, 34)
$menu.ForeColor = [System.Drawing.Color]::FromArgb(224, 230, 237)
$menu.Font = New-Object System.Drawing.Font('Segoe UI', 9.5)
$menu.ShowImageMargin = $false
$menu.ShowCheckMargin = $true

function Add-TrayItem($text, [scriptblock]$action) {
    $item = New-Object System.Windows.Forms.ToolStripMenuItem $text
    $item.ForeColor = [System.Drawing.Color]::FromArgb(224, 230, 237)
    $item.Add_Click($action)
    [void]$menu.Items.Add($item)
    $item
}
function Add-TraySeparator { [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) }

$openItem = Add-TrayItem 'Abrir Optimizador PC' { Show-Main }
$openItem.Font = New-Object System.Drawing.Font('Segoe UI', 9.5, [System.Drawing.FontStyle]::Bold)
Add-TraySeparator
$script:TrayTurbo = Add-TrayItem 'Modo Turbo' {
    try { if ($script:TurboOn) { Disable-Turbo } else { Enable-Turbo } } catch { Log "Error en Modo Turbo: $($_.Exception.Message)" }
    Notify $(if ($script:TurboOn) { 'Modo Turbo activado.' } else { 'Modo Turbo desactivado.' })
}
$script:TrayWidget = Add-TrayItem 'Widget flotante' { Set-Widget (-not $script:Settings.Widget) }
[void](Add-TrayItem 'Liberar memoria' { try { Clear-StandbyMemory } catch {} ; Notify 'Memoria en espera liberada.' })
[void](Add-TrayItem 'Limpiar temporales' { try { Clear-TempFiles } catch {} ; Notify 'Archivos temporales eliminados.' })
Add-TraySeparator
[void](Add-TrayItem 'Volumen al 100%' { try { Set-MaxVolume } catch {} })
[void](Add-TrayItem 'Silenciar / activar sonido' { try { Switch-Mute } catch {} })
Add-TraySeparator
[void](Add-TrayItem 'Salir' { Exit-App })

$script:Tray.ContextMenuStrip = $menu
$script:Tray.Add_MouseClick({
    param($s, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) { Show-Main }
})
$script:Tray.Visible = $true

# --- Monitor en vivo -------------------------------------------------------------------
function Update-Monitor {
    $cpu = $null; $ramPct = $null
    try {
        $cpu = [int](Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'").PercentProcessorTime
        $os = Get-CimInstance Win32_OperatingSystem
        $total = $os.TotalVisibleMemorySize * 1KB
        $used = $total - $os.FreePhysicalMemory * 1KB
        $ramPct = [int](100 * $used / $total)
    } catch {}

    if ($null -ne $cpu -and $null -ne $ramPct) {
        $tip = "Optimizador PC - CPU $cpu% - RAM $ramPct%"
        if ($script:TurboOn) { $tip += ' - TURBO' }
        $script:Tray.Text = $tip
    }
    if (-not $window.IsVisible -or -not $script:Initialized) { return }

    if ($null -ne $cpu) { $ui.CpuText.Text = "$cpu%"; $ui.CpuBar.Value = $cpu }
    if ($null -ne $ramPct) {
        $ui.RamText.Text = "$ramPct%"
        $ui.RamBar.Value = $ramPct
        $ui.RamSub.Text = "$(Format-GB $used) de $(Format-GB $total) en uso"
    }
    try {
        $mem = Get-CimInstance Win32_PerfFormattedData_GPUPerformanceCounters_GPUAdapterMemory -ErrorAction Stop |
               Sort-Object { $_.DedicatedUsage + $_.SharedUsage } -Descending | Select-Object -First 1
        # Las GPU integradas casi no usan memoria "dedicada": se suma la compartida
        $gpuMem = [double]$mem.DedicatedUsage + [double]$mem.SharedUsage
        $eng = Get-CimInstance Win32_PerfFormattedData_GPUPerformanceCounters_GPUEngine -Filter "Name LIKE '%engtype_3D'" -ErrorAction Stop
        $gpu = [int][math]::Min(100, ($eng | Measure-Object UtilizationPercentage -Sum).Sum)
        $ui.GpuText.Text = "$gpu%"
        $ui.GpuBar.Value = $gpu
        $ui.GpuSub.Text = "Memoria: $(Format-GB $gpuMem) · $($script:Hw.GpuName)"
    } catch { $ui.GpuText.Text = 'N/D'; $ui.GpuSub.Text = "$($script:Hw.GpuName)" }
    try {
        $disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$env:SystemDrive'"
        $usedPct = [int](100 * ($disk.Size - $disk.FreeSpace) / $disk.Size)
        $ui.DiskText.Text = Format-GB $disk.FreeSpace
        $ui.DiskBar.Value = $usedPct
        $ui.DiskBar.Foreground = if ($usedPct -ge 90) { [System.Windows.Media.Brushes]::OrangeRed } else { $window.FindResource('Accent') }
        $kind = if ($script:Hw.SysHdd) { 'HDD' } else { 'SSD' }
        $ui.DiskSub.Text = "libres en $env:SystemDrive ($kind) · $usedPct% usado"
    } catch {}
}

$script:Tick = 0
$script:Timer = New-Object System.Windows.Threading.DispatcherTimer
$script:Timer.Interval = [TimeSpan]::FromSeconds(2)
$script:Timer.Add_Tick({
    $script:Tick++
    try { Update-Monitor } catch {}
    try { Update-BgTasks } catch {}
    if ($script:Tick % 2 -eq 0) { try { Update-Games } catch { Log "Error al vigilar juegos: $($_.Exception.Message)" } }
})

# Otra instancia pidió mostrar la ventana
$script:FastTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:FastTimer.Interval = [TimeSpan]::FromMilliseconds(500)
$script:FastTimer.Add_Tick({ if ($script:ShowEvent.WaitOne(0)) { Show-Main } })

# --- Widget flotante -------------------------------------------------------------------
[xml]$widgetXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Widget Optimizador PC" Width="240" Height="112"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent" ResizeMode="NoResize"
        ShowInTaskbar="False" Topmost="True" ShowActivated="False"
        Foreground="#E0E6ED" FontFamily="Segoe UI" FontSize="11.5" UseLayoutRounding="True">
  <Window.Resources>
    <Style x:Key="Label" TargetType="TextBlock">
      <Setter Property="Foreground" Value="#9AA4B2"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
      <Setter Property="Width" Value="30"/>
    </Style>
    <Style x:Key="Value" TargetType="TextBlock">
      <Setter Property="VerticalAlignment" Value="Center"/>
      <Setter Property="HorizontalAlignment" Value="Right"/>
    </Style>
    <Style x:Key="Track" TargetType="Border">
      <Setter Property="Background" Value="#24FFFFFF"/>
      <Setter Property="CornerRadius" Value="3"/>
      <Setter Property="Height" Value="6"/>
      <Setter Property="Width" Value="84"/>
      <Setter Property="HorizontalAlignment" Value="Left"/>
    </Style>
    <Style x:Key="Fill" TargetType="Border">
      <Setter Property="Background" Value="#76B900"/>
      <Setter Property="CornerRadius" Value="3"/>
      <Setter Property="Width" Value="0"/>
      <Setter Property="HorizontalAlignment" Value="Left"/>
    </Style>
    <Style x:Key="WTitle" TargetType="Button">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Focusable" Value="False"/>
      <Setter Property="Foreground" Value="#9AA4B2"/>
      <Setter Property="FontFamily" Value="Segoe MDL2 Assets"/>
      <Setter Property="FontSize" Value="10"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Width="24" Height="20" CornerRadius="5" Background="Transparent">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bd" Property="Background" Value="#30FFFFFF"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Pulsador" TargetType="Button">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Focusable" Value="False"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Grid Width="44" Height="44" Background="Transparent">
              <Ellipse Fill="#0B0E14" Stroke="#4D5568"/>
              <Grid x:Name="Cap" Margin="5" RenderTransformOrigin="0.5,0.5">
                <Ellipse>
                  <Ellipse.Fill>
                    <RadialGradientBrush GradientOrigin="0.38,0.28" Center="0.5,0.5" RadiusX="0.62" RadiusY="0.62">
                      <GradientStop Color="#C4F25A" Offset="0"/>
                      <GradientStop Color="#76B900" Offset="0.6"/>
                      <GradientStop Color="#4A7300" Offset="1"/>
                    </RadialGradientBrush>
                  </Ellipse.Fill>
                </Ellipse>
                <Ellipse x:Name="Glow" Fill="White" Opacity="0"/>
                <Ellipse x:Name="Shade" Fill="Black" Opacity="0"/>
                <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
              </Grid>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Glow" Property="Opacity" Value="0.15"/></Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="Cap" Property="RenderTransform"><Setter.Value><ScaleTransform ScaleX="0.86" ScaleY="0.86"/></Setter.Value></Setter>
                <Setter TargetName="Shade" Property="Opacity" Value="0.3"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="Cap" Property="RenderTransform"><Setter.Value><ScaleTransform ScaleX="0.86" ScaleY="0.86"/></Setter.Value></Setter>
                <Setter TargetName="Shade" Property="Opacity" Value="0.55"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>
  <Border x:Name="WidgetRoot" Background="#EE141A24" BorderBrush="#24FFFFFF" BorderThickness="1" CornerRadius="12" Padding="12,4,6,8" ToolTip="Arrastra para mover">
    <DockPanel>
    <DockPanel DockPanel.Dock="Top">
      <StackPanel DockPanel.Dock="Right" Orientation="Horizontal">
        <Button x:Name="WOpen" Style="{StaticResource WTitle}" Content="&#xE8A7;" AutomationProperties.Name="Abrir panel" ToolTip="Abrir panel"/>
        <Button x:Name="WMin" Style="{StaticResource WTitle}" Content="&#xE921;" AutomationProperties.Name="Minimizar widget" ToolTip="Minimizar"/>
        <Button x:Name="WClose" Style="{StaticResource WTitle}" Content="&#xE8BB;" AutomationProperties.Name="Cerrar widget" ToolTip="Cerrar (vuelve desde el icono de la bandeja)"/>
      </StackPanel>
      <TextBlock x:Name="WMiniText" VerticalAlignment="Center" Visibility="Collapsed"/>
    </DockPanel>
    <Grid x:Name="WBody">
      <Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="58"/></Grid.ColumnDefinitions>
      <Grid.RowDefinitions><RowDefinition/><RowDefinition/><RowDefinition/></Grid.RowDefinitions>
      <DockPanel>
        <TextBlock Style="{StaticResource Label}" Text="CPU"/>
        <TextBlock x:Name="WCpuText" Style="{StaticResource Value}" DockPanel.Dock="Right" Text="-"/>
        <Border Style="{StaticResource Track}"><Border x:Name="WCpuBar" Style="{StaticResource Fill}"/></Border>
      </DockPanel>
      <DockPanel Grid.Row="1">
        <TextBlock Style="{StaticResource Label}" Text="RAM"/>
        <TextBlock x:Name="WRamText" Style="{StaticResource Value}" DockPanel.Dock="Right" Text="-"/>
        <Border Style="{StaticResource Track}"><Border x:Name="WRamBar" Style="{StaticResource Fill}"/></Border>
      </DockPanel>
      <DockPanel Grid.Row="2">
        <TextBlock Style="{StaticResource Label}" Text="Red"/>
        <TextBlock x:Name="WNetText" VerticalAlignment="Center" FontSize="10.5" Text="-"/>
      </DockPanel>
      <StackPanel Grid.Column="1" Grid.RowSpan="3" HorizontalAlignment="Center" VerticalAlignment="Center">
        <Button x:Name="WPurge" Style="{StaticResource Pulsador}" AutomationProperties.Name="Liberar RAM caché"
                ToolTip="Liberar RAM caché (memoria en espera)">
          <TextBlock FontFamily="Segoe MDL2 Assets" Text="&#xE945;" FontSize="14" Foreground="#101408"/>
        </Button>
        <TextBlock x:Name="WPurgeText" Text="Liberar" FontSize="10.5" HorizontalAlignment="Center" Foreground="#9AA4B2"/>
      </StackPanel>
    </Grid>
    </DockPanel>
  </Border>
</Window>
'@

$script:Widget = [System.Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $widgetXaml))
$wg = @{}
foreach ($n in 'WidgetRoot', 'WCpuText', 'WCpuBar', 'WRamText', 'WRamBar', 'WNetText', 'WPurge', 'WPurgeText', 'WOpen', 'WMin', 'WClose', 'WBody', 'WMiniText') { $wg[$n] = $script:Widget.FindName($n) }

function Format-Rate([double]$bytesPerSec) {
    if ($bytesPerSec -ge 1MB) { '{0:N1} MB/s' -f ($bytesPerSec / 1MB) } else { '{0:N0} KB/s' -f ($bytesPerSec / 1KB) }
}

function Get-NetBytes {
    # Solo adaptadores físicos: un túnel como Cloudflare WARP contaría el mismo tráfico dos veces
    $rx = 0.0; $tx = 0.0
    foreach ($n in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
        if ($n.OperationalStatus -ne 'Up' -or $n.NetworkInterfaceType -notin 'Ethernet', 'Wireless80211') { continue }
        $s = $n.GetIPStatistics()
        $rx += $s.BytesReceived; $tx += $s.BytesSent
    }
    @{ Rx = $rx; Tx = $tx; Time = [DateTime]::UtcNow }
}

function Set-WidgetBar($bar, $text, [int]$pct) {
    $text.Text = "$pct%"
    $bar.Width = 84 * $pct / 100
    $bar.Background = if ($pct -ge 90) { [System.Windows.Media.Brushes]::OrangeRed } else { $script:WidgetAccent }
}

function Update-Widget {
    Set-WidgetBar $wg.WCpuBar $wg.WCpuText ([OptStats]::Cpu())
    Set-WidgetBar $wg.WRamBar $wg.WRamText ([OptStats]::Ram())
    $wg.WMiniText.Text = "CPU $($wg.WCpuText.Text)   RAM $($wg.WRamText.Text)"
    $net = Get-NetBytes
    if ($script:NetPrev) {
        $sec = ($net.Time - $script:NetPrev.Time).TotalSeconds
        # El contador vuelve a cero si el adaptador se reconecta: nunca mostrar negativos
        $down = [math]::Max(0, $net.Rx - $script:NetPrev.Rx) / $sec
        $up = [math]::Max(0, $net.Tx - $script:NetPrev.Tx) / $sec
        $wg.WNetText.Text = "↓ $(Format-Rate $down)  ↑ $(Format-Rate $up)"
    }
    $script:NetPrev = $net
    if ($script:PurgeMsgUntil -and (Get-Date) -gt $script:PurgeMsgUntil) {
        $wg.WPurgeText.Text = 'Liberar'
        $script:PurgeMsgUntil = $null
    }
}

function Switch-WidgetSize {
    $min = $wg.WBody.Visibility -eq 'Visible'
    $wg.WBody.Visibility = if ($min) { 'Collapsed' } else { 'Visible' }
    $wg.WMiniText.Visibility = if ($min) { 'Visible' } else { 'Collapsed' }
    $wg.WMin.Content = [string][char]$(if ($min) { 0xE922 } else { 0xE921 })
    $wg.WMin.ToolTip = if ($min) { 'Restaurar' } else { 'Minimizar' }
    $script:Widget.Height = if ($min) { 30 } else { 112 }
}

function Set-Widget([bool]$on) {
    if ($on -and -not $script:StatsOk) { Log 'El widget no está disponible en este equipo.'; $on = $false }
    $script:Settings.Widget = $on
    Save-Settings
    $script:TrayWidget.Checked = $on
    $ui.WidgetSwitch.IsChecked = $on
    if ($on) {
        $script:NetPrev = $null
        $script:Widget.Show()
        try { Update-Widget } catch {}
        $script:WidgetTimer.Start()
    } else {
        $script:WidgetTimer.Stop()
        $script:Widget.Hide()
    }
}

# Sobre la bandeja por defecto; la posición guardada se descarta si quedó fuera de la pantalla (monitor desconectado)
$wa = [System.Windows.SystemParameters]::WorkArea
$script:Widget.Left = $wa.Right - $script:Widget.Width - 12
$script:Widget.Top = $wa.Bottom - $script:Widget.Height - 12
$vs = New-Object System.Windows.Rect ([System.Windows.SystemParameters]::VirtualScreenLeft), ([System.Windows.SystemParameters]::VirtualScreenTop), ([System.Windows.SystemParameters]::VirtualScreenWidth), ([System.Windows.SystemParameters]::VirtualScreenHeight)
if ($null -ne $script:Settings.WidgetX -and $vs.Contains([double]$script:Settings.WidgetX, [double]$script:Settings.WidgetY)) {
    $script:Widget.Left = $script:Settings.WidgetX
    $script:Widget.Top = $script:Settings.WidgetY
}

$script:WidgetAccent = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(118, 185, 0))
$script:Widget.Add_SourceInitialized({
    [OptStats]::MakeOverlay((New-Object System.Windows.Interop.WindowInteropHelper $script:Widget).Handle)
})
$wg.WidgetRoot.Add_MouseLeftButtonDown({
    try { $script:Widget.DragMove() } catch {}
    $script:Settings.WidgetX = $script:Widget.Left
    $script:Settings.WidgetY = $script:Widget.Top
    Save-Settings
})
$wg.WOpen.Add_Click({
    Show-Main
    [OptStats]::BringToFront((New-Object System.Windows.Interop.WindowInteropHelper $window).Handle)
})
$wg.WMin.Add_Click({ Switch-WidgetSize })
$wg.WClose.Add_Click({ Set-Widget $false })
$wg.WPurge.Add_Click({
    $wg.WPurge.IsEnabled = $false
    $wg.WPurgeText.Text = 'Liberando'
    # Deja que el pulsador se vea hundido antes de la tarea, que bloquea la interfaz un momento
    $script:Widget.Dispatcher.Invoke([action]{}, [System.Windows.Threading.DispatcherPriority]::Background)
    $freed = $null
    try { $freed = Clear-StandbyMemory } catch { Log "Error: $($_.Exception.Message)" }
    $wg.WPurgeText.Text = if ($null -ne $freed) { "+$(Format-GB $freed)" } else { 'Error' }
    $script:PurgeMsgUntil = (Get-Date).AddSeconds(4)
    $wg.WPurge.IsEnabled = $true
})

$script:WidgetTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:WidgetTimer.Interval = [TimeSpan]::FromSeconds(1)
$script:WidgetTimer.Add_Tick({ try { Update-Widget } catch {} })

# --- Arranque de la aplicación -----------------------------------------------------------
$script:App = New-Object System.Windows.Application
$script:App.ShutdownMode = [System.Windows.ShutdownMode]::OnExplicitShutdown
$script:App.Add_DispatcherUnhandledException({
    param($s, $e)
    Log "Error inesperado: $($e.Exception.Message)"
    $e.Handled = $true
})

$script:Timer.Start()
$script:FastTimer.Start()
Set-Widget ([bool]$script:Settings.Widget)
if ($Minimized) {
    Log 'Iniciado en la bandeja del sistema.'
} else {
    $window.Show()
}

try {
    [void]$script:App.Run()
} catch {
    [System.Windows.MessageBox]::Show("Error: $($_.Exception.Message)", 'Optimizador PC', 'OK', 'Error') | Out-Null
} finally {
    if ($script:Tray) { $script:Tray.Visible = $false; $script:Tray.Dispose() }
    try { $script:Mutex.ReleaseMutex() } catch {}
}
