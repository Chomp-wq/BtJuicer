# The few things PowerShell cannot reach without P/Invoke: SystemParametersInfo
# (so visual settings apply now, not at next sign-in), display modes (the
# refresh-rate check), and the power APIs Modern Standby laptops are driven by.

function Test-JuicerWindows { [Environment]::OSVersion.Platform -eq 'Win32NT' }

function Initialize-JuicerNative {
    if ('WinJuicer.Native' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;

namespace WinJuicer {
    public class Display {
        public string Device;
        public string Adapter;
        public string Monitor;
        public int Width;
        public int Height;
        public int Hz;
        public int MaxHz;
        public bool Primary;
        public string MonitorId;
        public string[] Resolutions;
        public int[] RefreshRates;
        public int NativeWidth;
        public int NativeHeight;
        public double ExactHz;
    }

    public static class Native {
        [DllImport("user32.dll", SetLastError = true)]
        static extern bool SystemParametersInfo(uint action, uint param, ref int value, uint flags);

        [DllImport("user32.dll", SetLastError = true, EntryPoint = "SystemParametersInfo")]
        static extern bool SystemParametersInfoPtr(uint action, uint param, IntPtr value, uint flags);

        public static bool SpiGetBool(uint action) {
            int v = 0;
            if (!SystemParametersInfo(action, 0, ref v, 0)) throw new Win32Exception();
            return v != 0;
        }

        // SPIF_UPDATEINIFILE | SPIF_SENDCHANGE: persist it and tell running apps.
        public static void SpiSetBool(uint action, bool value) {
            if (!SystemParametersInfoPtr(action, 0, value ? new IntPtr(1) : IntPtr.Zero, 3)) throw new Win32Exception();
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        struct DISPLAY_DEVICE {
            public int cb;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string DeviceName;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceString;
            public int StateFlags;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceID;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceKey;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        struct DEVMODE {
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmDeviceName;
            public short dmSpecVersion, dmDriverVersion, dmSize, dmDriverExtra;
            public int dmFields;
            public int dmPositionX, dmPositionY, dmDisplayOrientation, dmDisplayFixedOutput;
            public short dmColor, dmDuplex, dmYResolution, dmTTOption, dmCollate;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmFormName;
            public short dmLogPixels;
            public int dmBitsPerPel, dmPelsWidth, dmPelsHeight, dmDisplayFlags, dmDisplayFrequency;
            public int dmICMMethod, dmICMIntent, dmMediaType, dmDitherType, dmReserved1, dmReserved2, dmPanningWidth, dmPanningHeight;
        }

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        static extern bool EnumDisplayDevices(string device, uint index, ref DISPLAY_DEVICE dd, uint flags);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        static extern bool EnumDisplaySettings(string device, int mode, ref DEVMODE dm);

        // QueryDisplayConfig: the refresh rate as the fraction the display
        // really runs at (179.96 Hz, not 180), by GDI name (\\.\DISPLAY1).
        [StructLayout(LayoutKind.Sequential)] struct LUID { public uint Low; public int High; }
        [StructLayout(LayoutKind.Sequential)] struct RATIONAL { public uint Num; public uint Den; }
        [StructLayout(LayoutKind.Sequential)] struct PATH_SOURCE { public LUID adapterId; public uint id; public uint modeInfoIdx; public uint statusFlags; }
        [StructLayout(LayoutKind.Sequential)] struct PATH_TARGET {
            public LUID adapterId; public uint id; public uint modeInfoIdx; public int outputTechnology; public int rotation; public int scaling;
            public RATIONAL refreshRate; public int scanLineOrdering; public int targetAvailable; public uint statusFlags;
        }
        [StructLayout(LayoutKind.Sequential)] struct PATH_INFO { public PATH_SOURCE sourceInfo; public PATH_TARGET targetInfo; public uint flags; }
        // DISPLAYCONFIG_MODE_INFO: 16 bytes of header, then the target mode's
        // video signal (vSyncFreq at 32) or the source mode, in 48.
        [StructLayout(LayoutKind.Explicit, Size = 64)] struct MODE_INFO {
            [FieldOffset(0)] public int infoType;
            [FieldOffset(32)] public uint vSyncNum;
            [FieldOffset(36)] public uint vSyncDen;
        }
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] struct SOURCE_NAME {
            public int type; public int size; public LUID adapterId; public uint id;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string viewGdiDeviceName;
        }

        [DllImport("user32.dll")] static extern int GetDisplayConfigBufferSizes(uint flags, out uint numPaths, out uint numModes);
        [DllImport("user32.dll")] static extern int QueryDisplayConfig(uint flags, ref uint numPaths, [Out] PATH_INFO[] paths, ref uint numModes, [Out] MODE_INFO[] modes, IntPtr topology);
        [DllImport("user32.dll")] static extern int DisplayConfigGetDeviceInfo(ref SOURCE_NAME info);

        public static Dictionary<string, double> GetExactRefresh() {
            var map = new Dictionary<string, double>(StringComparer.OrdinalIgnoreCase);
            uint np, nm;
            if (GetDisplayConfigBufferSizes(2, out np, out nm) != 0) return map;   // QDC_ONLY_ACTIVE_PATHS
            var paths = new PATH_INFO[np];
            var modes = new MODE_INFO[nm];
            if (QueryDisplayConfig(2, ref np, paths, ref nm, modes, IntPtr.Zero) != 0) return map;
            for (int i = 0; i < np; i++) {
                var p = paths[i];
                var name = new SOURCE_NAME();
                name.type = 1;   // DISPLAYCONFIG_DEVICE_INFO_GET_SOURCE_NAME
                name.size = Marshal.SizeOf(name);
                name.adapterId = p.sourceInfo.adapterId;
                name.id = p.sourceInfo.id;
                if (DisplayConfigGetDeviceInfo(ref name) != 0) continue;
                double hz = 0;
                uint t = p.targetInfo.modeInfoIdx;
                if (t < nm && modes[t].infoType == 2 && modes[t].vSyncDen != 0) hz = (double)modes[t].vSyncNum / modes[t].vSyncDen;
                else if (p.targetInfo.refreshRate.Den != 0) hz = (double)p.targetInfo.refreshRate.Num / p.targetInfo.refreshRate.Den;
                if (hz > 0 && !map.ContainsKey(name.viewGdiDeviceName)) map[name.viewGdiDeviceName] = hz;
            }
            return map;
        }

        // Current mode of every display attached to the desktop, plus the
        // highest refresh rate the driver offers at that same resolution.
        public static Display[] GetDisplays() {
            var list = new List<Display>();
            Dictionary<string, double> exact;
            try { exact = GetExactRefresh(); } catch { exact = new Dictionary<string, double>(); }
            for (uint i = 0; ; i++) {
                var dd = new DISPLAY_DEVICE();
                dd.cb = Marshal.SizeOf(dd);
                if (!EnumDisplayDevices(null, i, ref dd, 0)) break;
                if ((dd.StateFlags & 1) == 0) continue;
                var cur = new DEVMODE();
                cur.dmSize = (short)Marshal.SizeOf(cur);
                if (!EnumDisplaySettings(dd.DeviceName, -1, ref cur)) continue;
                int max = cur.dmDisplayFrequency;
                var sizes = new List<string>();
                var rates = new List<int>();
                for (int m = 0; ; m++) {
                    var dm = new DEVMODE();
                    dm.dmSize = (short)Marshal.SizeOf(dm);
                    if (!EnumDisplaySettings(dd.DeviceName, m, ref dm)) break;
                    if (dm.dmPelsWidth == cur.dmPelsWidth && dm.dmPelsHeight == cur.dmPelsHeight) {
                        if (dm.dmDisplayFrequency > max) max = dm.dmDisplayFrequency;
                        if (dm.dmDisplayFrequency > 1 && !rates.Contains(dm.dmDisplayFrequency)) rates.Add(dm.dmDisplayFrequency);
                    }
                    string size = dm.dmPelsWidth + "x" + dm.dmPelsHeight;
                    if (!sizes.Contains(size)) sizes.Add(size);
                }
                // Flag 1, EDD_GET_DEVICE_INTERFACE_NAME: DeviceID becomes the
                // monitor's device path, which leads to its EDID.
                var mon = new DISPLAY_DEVICE();
                mon.cb = Marshal.SizeOf(mon);
                bool hasMon = EnumDisplayDevices(dd.DeviceName, 0, ref mon, 1);
                var d = new Display();
                d.Device = dd.DeviceName;
                d.Adapter = dd.DeviceString;
                d.Primary = (dd.StateFlags & 4) != 0;
                d.Monitor = hasMon ? mon.DeviceString : "";
                d.MonitorId = hasMon ? mon.DeviceID : "";
                d.Resolutions = sizes.ToArray();
                if (!rates.Contains(cur.dmDisplayFrequency)) rates.Add(cur.dmDisplayFrequency);
                rates.Sort();
                d.RefreshRates = rates.ToArray();
                d.Width = cur.dmPelsWidth;
                d.Height = cur.dmPelsHeight;
                d.Hz = cur.dmDisplayFrequency;
                double x;
                d.ExactHz = exact.TryGetValue(dd.DeviceName, out x) && Math.Abs(x - d.Hz) < 1 ? x : d.Hz;
                d.MaxHz = max;
                list.Add(d);
            }
            return list.ToArray();
        }

        [DllImport("powrprof.dll")]
        static extern byte GetPwrCapabilities(byte[] caps);

        // SYSTEM_POWER_CAPABILITIES.AoAc, at byte 20 of the structure.
        public static bool IsModernStandby() {
            var caps = new byte[256];
            if (GetPwrCapabilities(caps) == 0) return false;
            return caps[20] != 0;
        }

        // The "Power mode" slider. Not in the SDK headers, but exported by
        // powrprof.dll since Windows 10 1709 and what Settings itself calls.
        [DllImport("powrprof.dll")]
        static extern uint PowerGetEffectiveOverlayScheme(out Guid scheme);

        [DllImport("powrprof.dll")]
        static extern uint PowerSetActiveOverlayScheme(Guid scheme);

        public static string GetPowerMode() {
            Guid g;
            uint r = PowerGetEffectiveOverlayScheme(out g);
            if (r != 0) throw new Win32Exception((int)r);
            return g.ToString();
        }

        public static void SetPowerMode(string scheme) {
            uint r = PowerSetActiveOverlayScheme(new Guid(scheme));
            if (r != 0) throw new Win32Exception((int)r);
        }

        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool GetSystemCpuSetInformation(IntPtr info, uint length, out uint returned, IntPtr process, uint flags);

        // EfficiencyClass of every logical processor: on hybrid CPUs the
        // performance cores have a higher class than the efficient ones.
        // SYSTEM_CPU_SET_INFORMATION: Size, Type, then Id (4), Group (2),
        // LogicalProcessorIndex, CoreIndex, LastLevelCacheIndex,
        // NumaNodeIndex and EfficiencyClass (1 each): byte 18.
        public static int[] GetEfficiencyClasses() {
            uint len;
            GetSystemCpuSetInformation(IntPtr.Zero, 0, out len, IntPtr.Zero, 0);
            if (len == 0) return new int[0];
            IntPtr buf = Marshal.AllocHGlobal((int)len);
            try {
                if (!GetSystemCpuSetInformation(buf, len, out len, IntPtr.Zero, 0)) return new int[0];
                var list = new List<int>();
                int offset = 0;
                while (offset + 19 <= len) {
                    int size = Marshal.ReadInt32(buf, offset);
                    if (Marshal.ReadInt32(buf, offset + 4) == 0) list.Add(Marshal.ReadByte(buf, offset + 18));
                    if (size <= 0) break;
                    offset += size;
                }
                return list.ToArray();
            } finally {
                Marshal.FreeHGlobal(buf);
            }
        }
    }
}
'@
}

$script:ModernStandby = $null

function Test-JuicerModernStandby {
    if ($null -eq $script:ModernStandby) {
        $script:ModernStandby = $false
        if (Test-JuicerWindows) {
            try {
                Initialize-JuicerNative
                $script:ModernStandby = [WinJuicer.Native]::IsModernStandby()
            } catch {
                Write-Verbose "No se pudo consultar Modern Standby: $_"
            }
        }
    }
    $script:ModernStandby
}

function Get-JuicerDisplays {
    if (-not (Test-JuicerWindows)) { return @() }
    Initialize-JuicerNative
    $displays = @([WinJuicer.Native]::GetDisplays())
    foreach ($d in $displays) {
        $path = ConvertTo-JuicerEdidKey $d.MonitorId
        if (-not $path) { continue }
        $edid = Read-JuicerReg $path 'EDID'
        $native = if ($edid) { ConvertFrom-JuicerEdid $edid.Value }
        if ($native) { $d.NativeWidth = $native.Width; $d.NativeHeight = $native.Height }
    }
    $displays
}

# \\?\DISPLAY#GSM5B7F#5&2d3b7a1f&0&UID4353#{e6f07b5f-...} is the monitor's
# instance under Enum\DISPLAY, where Windows keeps the EDID it read from it.
function ConvertTo-JuicerEdidKey {
    param([string]$MonitorId)
    $p = $MonitorId -split '#'
    if ($p.Count -lt 3 -or $p[0] -notmatch 'DISPLAY$') { return $null }
    "HKLM\SYSTEM\CurrentControlSet\Enum\DISPLAY\$($p[1])\$($p[2])\Device Parameters"
}

# The panel's native resolution is the first detailed timing of the EDID,
# the one the monitor prefers. Twelve bits per side: past 4095 pixels (5K
# and up) it lives in an extension instead, and this says nothing.
function ConvertFrom-JuicerEdid {
    param([byte[]]$Edid)
    if (-not $Edid -or $Edid.Count -lt 128) { return $null }
    if ($Edid[0] -ne 0 -or $Edid[1] -ne 0xFF -or $Edid[7] -ne 0) { return $null }
    if ($Edid[54] -eq 0 -and $Edid[55] -eq 0) { return $null }
    $w = $Edid[56] + (($Edid[58] -band 0xF0) -shl 4)
    $h = $Edid[59] + (($Edid[61] -band 0xF0) -shl 4)
    if ($w -lt 640 -or $h -lt 480) { return $null }
    @{ Width = $w; Height = $h }
}

# The NVIDIA driver's own frame limiter («Max Frame Rate» in the NVIDIA
# Control Panel), per program, through NVAPI's driver settings (DRS): the
# same profiles the Control Panel and Profile Inspector edit. Nothing is
# injected into the game, so anti-cheats have nothing to object to, and the
# driver applies it every time that .exe runs, with Win Juicer closed.
# Function ids, structures and codes are those of NVIDIA's nvapi.h and
# nvapi_interface.h (github.com/NVIDIA/nvapi).
function Initialize-JuicerNvApi {
    if ('WinJuicer.NvDrs' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace WinJuicer {
    public static class NvDrs {
        public const uint FrameRateLimiterId = 0x10835002;   // FRL_FPS_ID
        public const uint VSyncModeId = 0x00A879CF;          // VSYNCMODE_ID
        public const uint VSyncForceOn = 0x47814940;         // VSYNCMODE_FORCEON
        public const uint PreRenderLimitId = 0x007BA09E;     // PRERENDERLIMIT_ID
        const int StrMax = 2048;                              // NVAPI_UNICODE_STRING_MAX
        const int NotFoundApp = -166, NotFoundSetting = -160, NotFoundProfile = -163, AppInUse = -167;

        [StructLayout(LayoutKind.Sequential, Pack = 4)]
        public struct Setting {
            public uint version;
            [MarshalAs(UnmanagedType.ByValArray, SizeConst = StrMax)] public ushort[] settingName;
            public uint settingId;
            public int settingType;
            public int settingLocation;
            public uint isCurrentPredefined;
            public uint isPredefinedValid;
            [MarshalAs(UnmanagedType.ByValArray, SizeConst = 4100)] public byte[] predefinedValue;
            [MarshalAs(UnmanagedType.ByValArray, SizeConst = 4100)] public byte[] currentValue;
        }

        [StructLayout(LayoutKind.Sequential, Pack = 4)]
        public struct Application {
            public uint version;
            public uint isPredefined;
            [MarshalAs(UnmanagedType.ByValArray, SizeConst = StrMax)] public ushort[] appName;
            [MarshalAs(UnmanagedType.ByValArray, SizeConst = StrMax)] public ushort[] userFriendlyName;
            [MarshalAs(UnmanagedType.ByValArray, SizeConst = StrMax)] public ushort[] launcher;
            [MarshalAs(UnmanagedType.ByValArray, SizeConst = StrMax)] public ushort[] fileInFolder;
            public uint flags;
            [MarshalAs(UnmanagedType.ByValArray, SizeConst = StrMax)] public ushort[] commandLine;
        }

        [StructLayout(LayoutKind.Sequential, Pack = 4)]
        public struct Profile {
            public uint version;
            [MarshalAs(UnmanagedType.ByValArray, SizeConst = StrMax)] public ushort[] profileName;
            public uint gpuSupport;
            public uint isPredefined;
            public uint numOfApps;
            public uint numOfSettings;
        }

        // MAKE_NVAPI_VERSION: the size in the low word, the version above it.
        public static uint SettingVersion { get { return (uint)Marshal.SizeOf(typeof(Setting)) | (1u << 16); } }
        public static uint ApplicationVersion { get { return (uint)Marshal.SizeOf(typeof(Application)) | (4u << 16); } }
        public static uint ProfileVersion { get { return (uint)Marshal.SizeOf(typeof(Profile)) | (1u << 16); } }

        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int NoArgs();
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int CreateSessionFn(out IntPtr session);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int SessionFn(IntPtr session);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int FindAppFn(IntPtr session, ushort[] appName, out IntPtr profile, ref Application app);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int FindProfileFn(IntPtr session, ushort[] name, out IntPtr profile);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int CreateProfileFn(IntPtr session, ref Profile info, out IntPtr profile);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int CreateAppFn(IntPtr session, IntPtr profile, ref Application app);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int SetSettingFn(IntPtr session, IntPtr profile, ref Setting setting);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int GetSettingFn(IntPtr session, IntPtr profile, uint id, ref Setting setting);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int DeleteSettingFn(IntPtr session, IntPtr profile, uint id);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int BaseProfileFn(IntPtr session, out IntPtr profile);

        [DllImport("nvapi64.dll", EntryPoint = "nvapi_QueryInterface", CallingConvention = CallingConvention.Cdecl)]
        static extern IntPtr QueryInterface(uint id);

        static T Fn<T>(uint id) where T : class {
            IntPtr p = QueryInterface(id);
            if (p == IntPtr.Zero) throw new InvalidOperationException("NVAPI no tiene la función 0x" + id.ToString("X8"));
            return Marshal.GetDelegateForFunctionPointer(p, typeof(T)) as T;
        }

        static void Check(int status, string what) {
            if (status != 0) throw new InvalidOperationException("NVAPI " + what + ": código " + status);
        }

        public static ushort[] Str(string s) {
            var a = new ushort[StrMax];
            for (int i = 0; i < s.Length && i < StrMax - 1; i++) a[i] = s[i];
            return a;
        }

        static Application NewApplication(string name) {
            var a = new Application();
            a.version = ApplicationVersion;
            a.appName = Str(name ?? "");
            a.userFriendlyName = Str(""); a.launcher = Str(""); a.fileInFolder = Str(""); a.commandLine = Str("");
            return a;
        }

        static Setting NewSetting() {
            var s = new Setting();
            s.version = SettingVersion;
            s.settingName = Str("");
            s.predefinedValue = new byte[4100];
            s.currentValue = new byte[4100];
            return s;
        }

        // A 64-bit process with an NVIDIA driver that answers.
        public static bool Available() {
            if (IntPtr.Size != 8) return false;
            try { return Fn<NoArgs>(0x0150E828)() == 0; } catch { return false; }
        }

        static IntPtr Open() {
            Check(Fn<NoArgs>(0x0150E828)(), "Initialize");
            IntPtr s;
            Check(Fn<CreateSessionFn>(0x0694D52E)(out s), "CreateSession");
            int r = Fn<SessionFn>(0x375DBD6B)(s);
            if (r != 0) { Fn<SessionFn>(0xDAD9CFF8)(s); Check(r, "LoadSettings"); }
            return s;
        }

        static void Close(IntPtr s) { Fn<SessionFn>(0xDAD9CFF8)(s); }

        // The profile the driver uses for this .exe, or zero if none has it.
        static IntPtr FindApp(IntPtr s, string exe) {
            IntPtr profile;
            var app = NewApplication(null);
            int r = Fn<FindAppFn>(0xEEE566B2)(s, Str(exe), out profile, ref app);
            if (r == NotFoundApp) return IntPtr.Zero;
            Check(r, "FindApplicationByName");
            return profile;
        }

        // A DWORD setting set by the user in this program's profile, or -1
        // when there is none (no profile, or only NVIDIA's own value).
        public static long GetDword(string exe, uint id) {
            IntPtr s = Open();
            try {
                IntPtr profile = FindApp(s, exe);
                if (profile == IntPtr.Zero) return -1;
                var st = NewSetting();
                int r = Fn<GetSettingFn>(0x73BF8338)(s, profile, id, ref st);
                if (r == NotFoundSetting) return -1;
                Check(r, "GetSetting");
                if (st.settingLocation != 0 || st.isCurrentPredefined != 0) return -1;
                return (long)BitConverter.ToUInt32(st.currentValue, 0);
            } finally { Close(s); }
        }

        // The same, in the global profile (Manage 3D settings > Global): what
        // every program without its own value gets.
        public static long GetGlobalDword(uint id) {
            IntPtr s = Open();
            try {
                IntPtr profile;
                Check(Fn<BaseProfileFn>(0xDA8466A0)(s, out profile), "GetBaseProfile");
                var st = NewSetting();
                int r = Fn<GetSettingFn>(0x73BF8338)(s, profile, id, ref st);
                if (r == NotFoundSetting) return -1;
                Check(r, "GetSetting");
                if (st.isCurrentPredefined != 0) return -1;
                return (long)BitConverter.ToUInt32(st.currentValue, 0);
            } finally { Close(s); }
        }

        // A negative value removes the user value, back to NVIDIA's. The
        // program gets a «Win Juicer - name.exe» profile if it had none.
        public static void SetDword(string exe, uint id, long value) {
            IntPtr s = Open();
            try {
                IntPtr profile = FindApp(s, exe);
                if (profile == IntPtr.Zero) {
                    if (value < 0) return;
                    string name = "Win Juicer - " + exe;
                    int r = Fn<FindProfileFn>(0x7E4A9A0B)(s, Str(name), out profile);
                    if (r == NotFoundProfile) {
                        var info = new Profile();
                        info.version = ProfileVersion;
                        info.profileName = Str(name);
                        Check(Fn<CreateProfileFn>(0xCC176068)(s, ref info, out profile), "CreateProfile");
                    } else {
                        Check(r, "FindProfileByName");
                    }
                    var app = NewApplication(exe);
                    r = Fn<CreateAppFn>(0x4347A9DE)(s, profile, ref app);
                    if (r != AppInUse) Check(r, "CreateApplication");
                }
                if (value >= 0) {
                    var st = NewSetting();
                    st.settingId = id;
                    st.settingType = 0;   // NVDRS_DWORD_TYPE
                    BitConverter.GetBytes((uint)value).CopyTo(st.currentValue, 0);
                    Check(Fn<SetSettingFn>(0x577DD202)(s, profile, ref st), "SetSetting");
                } else {
                    int r = Fn<DeleteSettingFn>(0xE4A26362)(s, profile, id);
                    if (r != NotFoundSetting) Check(r, "DeleteProfileSetting");
                }
                Check(Fn<SessionFn>(0xFCBC7E14)(s), "SaveSettings");
            } finally { Close(s); }
        }
    }
}
'@
}
