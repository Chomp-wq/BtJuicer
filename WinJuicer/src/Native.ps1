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

        // Current mode of every display attached to the desktop, plus the
        // highest refresh rate the driver offers at that same resolution.
        public static Display[] GetDisplays() {
            var list = new List<Display>();
            for (uint i = 0; ; i++) {
                var dd = new DISPLAY_DEVICE();
                dd.cb = Marshal.SizeOf(dd);
                if (!EnumDisplayDevices(null, i, ref dd, 0)) break;
                if ((dd.StateFlags & 1) == 0) continue;
                var cur = new DEVMODE();
                cur.dmSize = (short)Marshal.SizeOf(cur);
                if (!EnumDisplaySettings(dd.DeviceName, -1, ref cur)) continue;
                int max = cur.dmDisplayFrequency;
                for (int m = 0; ; m++) {
                    var dm = new DEVMODE();
                    dm.dmSize = (short)Marshal.SizeOf(dm);
                    if (!EnumDisplaySettings(dd.DeviceName, m, ref dm)) break;
                    if (dm.dmPelsWidth == cur.dmPelsWidth && dm.dmPelsHeight == cur.dmPelsHeight && dm.dmDisplayFrequency > max) {
                        max = dm.dmDisplayFrequency;
                    }
                }
                var mon = new DISPLAY_DEVICE();
                mon.cb = Marshal.SizeOf(mon);
                var d = new Display();
                d.Device = dd.DeviceName;
                d.Adapter = dd.DeviceString;
                d.Monitor = EnumDisplayDevices(dd.DeviceName, 0, ref mon, 0) ? mon.DeviceString : "";
                d.Width = cur.dmPelsWidth;
                d.Height = cur.dmPelsHeight;
                d.Hz = cur.dmDisplayFrequency;
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
    @([WinJuicer.Native]::GetDisplays())
}
