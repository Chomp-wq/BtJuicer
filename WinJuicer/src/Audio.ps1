# Audio: what the default output is doing to latency, and the one thing that
# really lowers it for every program: asking the audio engine for its shortest
# period.
#
# Windows mixes shared-mode audio in periods of 10 ms (about 20-30 ms from a
# game to the speaker, all told). Since Windows 10, IAudioClient3 lets a program
# ask for a shorter period (128 samples = 2.7 ms at 48 kHz) if the driver
# supports it. While any program holds a stream with the short period, the
# engine runs at it for that device, so every program benefits, still mixed.
# Win Juicer does that with a silent stream kept open by a small script that
# runs at sign-in as the user.
#
# What is NOT here, on purpose: audiodg.exe priority or affinity, disabling the
# HPET, exclusive mode or ASIO. The first two are placebo (see Get-JuicerMyths);
# the last two only work if the program itself asks for them, which games do not.

# --- The interop --------------------------------------------------------------
#
# C# 5 and nothing newer: Windows PowerShell 5.1 compiles it with the .NET
# Framework's compiler. Every COM interface lists ALL its methods in vtable
# order, the inherited ones first (IAudioClient3 extends IAudioClient2 extends
# IAudioClient): a method missing or out of order calls the wrong function.
# Pointers to WAVEFORMATEX and PROPVARIANT travel as IntPtr and are read by
# offset, so the same code is right in 32 and 64 bits.

$script:AudioCSharp = @'
using System;
using System.Runtime.InteropServices;
using System.Threading;

namespace WinJuicer {
    // What AudioProbe.GetDefaultRender found out about the default output.
    // Frames are samples per engine period at SampleRate; zero means unknown.
    public class AudioEndpointInfo {
        public string Id = "";
        public string Name = "";
        public string Enumerator = "";
        public string AdapterId = "";
        public int FormFactor = -1;
        public int DisableSysFx = -1;
        public int SampleRate;
        public int Bits;
        public int Channels;
        public uint DefaultFrames;
        public uint FundamentalFrames;
        public uint MinFrames;
        public uint MaxFrames;
        public uint CurrentFrames;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct PropertyKey {
        public Guid fmtid;
        public uint pid;
    }

    [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
    class MMDeviceEnumeratorClass { }

    [ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDeviceEnumerator {
        [PreserveSig] int EnumAudioEndpoints(int dataFlow, uint stateMask, out IntPtr devices);
        [PreserveSig] int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice endpoint);
        [PreserveSig] int GetDevice([MarshalAs(UnmanagedType.LPWStr)] string id, out IMMDevice device);
        [PreserveSig] int RegisterEndpointNotificationCallback(IntPtr client);
        [PreserveSig] int UnregisterEndpointNotificationCallback(IntPtr client);
    }

    [ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDevice {
        [PreserveSig] int Activate(ref Guid iid, uint clsCtx, IntPtr activationParams, [MarshalAs(UnmanagedType.IUnknown)] out object iface);
        [PreserveSig] int OpenPropertyStore(uint access, out IPropertyStore properties);
        [PreserveSig] int GetId([MarshalAs(UnmanagedType.LPWStr)] out string id);
        [PreserveSig] int GetState(out uint state);
    }

    [ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IPropertyStore {
        [PreserveSig] int GetCount(out uint count);
        [PreserveSig] int GetAt(uint index, out PropertyKey key);
        [PreserveSig] int GetValue(ref PropertyKey key, IntPtr value);
        [PreserveSig] int SetValue(ref PropertyKey key, IntPtr value);
        [PreserveSig] int Commit();
    }

    [ComImport, Guid("7ED4EE07-8E67-4CD4-8C1A-2B7A5987AD42"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioClient3 {
        // IAudioClient
        [PreserveSig] int Initialize(int shareMode, uint streamFlags, long bufferDuration, long periodicity, IntPtr format, ref Guid sessionGuid);
        [PreserveSig] int GetBufferSize(out uint bufferFrames);
        [PreserveSig] int GetStreamLatency(out long latency);
        [PreserveSig] int GetCurrentPadding(out uint paddingFrames);
        [PreserveSig] int IsFormatSupported(int shareMode, IntPtr format, out IntPtr closestMatch);
        [PreserveSig] int GetMixFormat(out IntPtr format);
        [PreserveSig] int GetDevicePeriod(out long defaultPeriod, out long minimumPeriod);
        [PreserveSig] int Start();
        [PreserveSig] int Stop();
        [PreserveSig] int Reset();
        [PreserveSig] int SetEventHandle(IntPtr eventHandle);
        [PreserveSig] int GetService(ref Guid riid, [MarshalAs(UnmanagedType.IUnknown)] out object service);
        // IAudioClient2
        [PreserveSig] int IsOffloadCapable(int category, out int offloadCapable);
        [PreserveSig] int SetClientProperties(IntPtr properties);
        [PreserveSig] int GetBufferSizeLimits(IntPtr format, int eventDriven, out long minBufferDuration, out long maxBufferDuration);
        // IAudioClient3
        [PreserveSig] int GetSharedModeEnginePeriod(IntPtr format, out uint defaultPeriodInFrames, out uint fundamentalPeriodInFrames, out uint minPeriodInFrames, out uint maxPeriodInFrames);
        [PreserveSig] int GetCurrentSharedModeEnginePeriod(out IntPtr format, out uint currentPeriodInFrames);
        [PreserveSig] int InitializeSharedAudioStream(uint streamFlags, uint periodInFrames, IntPtr format, ref Guid sessionGuid);
    }

    [ComImport, Guid("F294ACFC-3146-4483-A7BF-ADDCA7C260E2"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioRenderClient {
        [PreserveSig] int GetBuffer(uint framesRequested, out IntPtr data);
        [PreserveSig] int ReleaseBuffer(uint framesWritten, uint flags);
    }

    static class AudioNative {
        [DllImport("ole32.dll")]
        internal static extern int PropVariantClear(IntPtr value);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, EntryPoint = "CreateEventW", SetLastError = true)]
        internal static extern IntPtr CreateEvent(IntPtr attributes, bool manualReset, bool initialState, string name);

        [DllImport("kernel32.dll")]
        internal static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);

        [DllImport("kernel32.dll")]
        internal static extern bool CloseHandle(IntPtr handle);
    }

    public static class AudioProbe {
        internal static readonly Guid IidAudioClient3 = new Guid("7ED4EE07-8E67-4CD4-8C1A-2B7A5987AD42");
        internal static readonly Guid IidRenderClient = new Guid("F294ACFC-3146-4483-A7BF-ADDCA7C260E2");
        static readonly Guid DeviceProps = new Guid("A45C254E-DF1C-4EFD-8020-67D146A850E0");
        static readonly Guid EndpointProps = new Guid("1DA5D803-D492-4EDD-8C23-E0C0FFEE7F0E");
        static readonly Guid AdapterProps = new Guid("B3F8FA53-0004-438E-9003-51A46E139BFC");
        const int E_NOTFOUND = unchecked((int)0x80070490);

        internal static void Check(int hr, string what) {
            if (hr < 0) throw new InvalidOperationException(what + ": 0x" + hr.ToString("X8"));
        }

        // The default output for games and media (render, console role), or
        // null when there is none.
        internal static IMMDevice DefaultRender() {
            IMMDeviceEnumerator en = (IMMDeviceEnumerator)new MMDeviceEnumeratorClass();
            try {
                IMMDevice dev;
                int hr = en.GetDefaultAudioEndpoint(0, 0, out dev);
                if (hr == E_NOTFOUND) return null;
                Check(hr, "GetDefaultAudioEndpoint");
                return dev;
            } finally {
                Marshal.ReleaseComObject(en);
            }
        }

        // A PROPVARIANT is 16 bytes in 32 bits and 24 in 64: 24 is enough for both,
        // with the type at 0 and the value at 8.
        static IntPtr NewVariant() {
            IntPtr pv = Marshal.AllocCoTaskMem(24);
            for (int i = 0; i < 24; i++) Marshal.WriteByte(pv, i, 0);
            return pv;
        }

        static string PropString(IPropertyStore ps, Guid fmtid, uint pid) {
            PropertyKey key = new PropertyKey();
            key.fmtid = fmtid;
            key.pid = pid;
            IntPtr pv = NewVariant();
            try {
                if (ps.GetValue(ref key, pv) < 0) return "";
                int vt = Marshal.ReadInt16(pv, 0) & 0xFFFF;
                if (vt != 31) return "";   // VT_LPWSTR
                IntPtr p = Marshal.ReadIntPtr(pv, 8);
                if (p == IntPtr.Zero) return "";
                return Marshal.PtrToStringUni(p) ?? "";
            } finally {
                AudioNative.PropVariantClear(pv);
                Marshal.FreeCoTaskMem(pv);
            }
        }

        // -1 when the property is not there.
        static int PropInt(IPropertyStore ps, Guid fmtid, uint pid) {
            PropertyKey key = new PropertyKey();
            key.fmtid = fmtid;
            key.pid = pid;
            IntPtr pv = NewVariant();
            try {
                if (ps.GetValue(ref key, pv) < 0) return -1;
                int vt = Marshal.ReadInt16(pv, 0) & 0xFFFF;
                if (vt != 19 && vt != 3) return -1;   // VT_UI4, VT_I4
                return Marshal.ReadInt32(pv, 8);
            } finally {
                AudioNative.PropVariantClear(pv);
                Marshal.FreeCoTaskMem(pv);
            }
        }

        static void ReadProperties(IMMDevice dev, AudioEndpointInfo info) {
            IPropertyStore ps;
            if (dev.OpenPropertyStore(0, out ps) < 0 || ps == null) return;
            try {
                info.Name = PropString(ps, DeviceProps, 14);                  // PKEY_Device_FriendlyName
                info.Enumerator = PropString(ps, DeviceProps, 24);            // PKEY_Device_EnumeratorName
                info.AdapterId = (PropString(ps, AdapterProps, 2) + " " + PropString(ps, AdapterProps, 6)).Trim();
                info.FormFactor = PropInt(ps, EndpointProps, 0);              // PKEY_AudioEndpoint_FormFactor
                info.DisableSysFx = PropInt(ps, EndpointProps, 5);            // PKEY_AudioEndpoint_Disable_SysFx
            } finally {
                Marshal.ReleaseComObject(ps);
            }
        }

        // The shared-mode mix format and the engine periods. Nothing is
        // initialized: the client is only asked.
        static void ReadEngine(IMMDevice dev, AudioEndpointInfo info) {
            object o;
            Guid iid = IidAudioClient3;
            if (dev.Activate(ref iid, 23, IntPtr.Zero, out o) < 0 || o == null) return;   // 23: CLSCTX_ALL
            IAudioClient3 client = (IAudioClient3)o;
            try {
                IntPtr fmt;
                if (client.GetMixFormat(out fmt) < 0 || fmt == IntPtr.Zero) return;
                try {
                    info.Channels = Marshal.ReadInt16(fmt, 2);
                    info.SampleRate = Marshal.ReadInt32(fmt, 4);
                    info.Bits = Marshal.ReadInt16(fmt, 14);
                    uint def, fund, min, max;
                    if (client.GetSharedModeEnginePeriod(fmt, out def, out fund, out min, out max) >= 0) {
                        info.DefaultFrames = def;
                        info.FundamentalFrames = fund;
                        info.MinFrames = min;
                        info.MaxFrames = max;
                    }
                    IntPtr curFmt;
                    uint cur;
                    if (client.GetCurrentSharedModeEnginePeriod(out curFmt, out cur) >= 0) {
                        info.CurrentFrames = cur;
                        if (curFmt != IntPtr.Zero) Marshal.FreeCoTaskMem(curFmt);
                    }
                } finally {
                    Marshal.FreeCoTaskMem(fmt);
                }
            } finally {
                Marshal.ReleaseComObject(client);
            }
        }

        // Null when there is no default output; throws when the audio service
        // cannot be reached at all.
        public static AudioEndpointInfo GetDefaultRender() {
            IMMDevice dev = DefaultRender();
            if (dev == null) return null;
            AudioEndpointInfo info = new AudioEndpointInfo();
            try {
                string id;
                if (dev.GetId(out id) >= 0 && id != null) info.Id = id;
                ReadProperties(dev, info);
                ReadEngine(dev, info);
            } finally {
                Marshal.ReleaseComObject(dev);
            }
            return info;
        }
    }

    // One silent shared-mode stream at the shortest period the driver allows.
    // Everything COM happens on its own thread (MTA), and nothing it writes is
    // audible: each period is handed back flagged as silence. The device is
    // never taken in exclusive mode, so every other program keeps mixing.
    sealed class HoldStream : IDisposable {
        Thread thread;
        readonly ManualResetEvent opened = new ManualResetEvent(false);
        volatile bool stop;
        public volatile bool Failed;
        public string Error = "";

        public static HoldStream Start() {
            HoldStream s = new HoldStream();
            s.thread = new Thread(new ThreadStart(s.Work));
            s.thread.SetApartmentState(ApartmentState.MTA);
            s.thread.IsBackground = true;
            s.thread.Start();
            if (!s.opened.WaitOne(10000)) s.Failed = true;
            return s;
        }

        // AUDCLNT_BUFFERFLAGS_SILENT = 2: the engine takes it as zeros without reading the buffer.
        static void Fill(IAudioRenderClient render, uint frames) {
            IntPtr data;
            AudioProbe.Check(render.GetBuffer(frames, out data), "GetBuffer");
            AudioProbe.Check(render.ReleaseBuffer(frames, 2), "ReleaseBuffer");
        }

        void Work() {
            IAudioClient3 client = null;
            IAudioRenderClient render = null;
            IntPtr evt = IntPtr.Zero;
            IntPtr fmt = IntPtr.Zero;
            bool started = false;
            try {
                IMMDevice dev = AudioProbe.DefaultRender();
                if (dev == null) throw new InvalidOperationException("no hay salida de audio");
                object o;
                try {
                    Guid iid = AudioProbe.IidAudioClient3;
                    AudioProbe.Check(dev.Activate(ref iid, 23, IntPtr.Zero, out o), "Activate");
                } finally {
                    Marshal.ReleaseComObject(dev);
                }
                client = (IAudioClient3)o;
                AudioProbe.Check(client.GetMixFormat(out fmt), "GetMixFormat");
                uint def, fund, min, max;
                AudioProbe.Check(client.GetSharedModeEnginePeriod(fmt, out def, out fund, out min, out max), "GetSharedModeEnginePeriod");
                if (min == 0 || min >= def) throw new InvalidOperationException("el driver no admite un periodo mas corto");
                Guid none = Guid.Empty;
                // 0x00040000: AUDCLNT_STREAMFLAGS_EVENTCALLBACK
                AudioProbe.Check(client.InitializeSharedAudioStream(0x00040000, min, fmt, ref none), "InitializeSharedAudioStream");
                evt = AudioNative.CreateEvent(IntPtr.Zero, false, false, null);
                AudioProbe.Check(client.SetEventHandle(evt), "SetEventHandle");
                uint frames;
                AudioProbe.Check(client.GetBufferSize(out frames), "GetBufferSize");
                object r;
                Guid riid = AudioProbe.IidRenderClient;
                AudioProbe.Check(client.GetService(ref riid, out r), "GetService");
                render = (IAudioRenderClient)r;
                Fill(render, frames);
                AudioProbe.Check(client.Start(), "Start");
                started = true;
                opened.Set();
                while (!stop) {
                    uint w = AudioNative.WaitForSingleObject(evt, 500);
                    if (stop) break;
                    if (w == 258) continue;   // WAIT_TIMEOUT
                    if (w != 0) throw new InvalidOperationException("espera fallida");
                    uint padding;
                    AudioProbe.Check(client.GetCurrentPadding(out padding), "GetCurrentPadding");
                    if (frames > padding) Fill(render, frames - padding);
                }
            } catch (Exception e) {
                Error = e.Message;
                Failed = true;
            } finally {
                try { if (started && client != null) client.Stop(); } catch (Exception) { }
                if (render != null) Marshal.ReleaseComObject(render);
                if (client != null) Marshal.ReleaseComObject(client);
                if (evt != IntPtr.Zero) AudioNative.CloseHandle(evt);
                if (fmt != IntPtr.Zero) Marshal.FreeCoTaskMem(fmt);
                opened.Set();
            }
        }

        public void Dispose() {
            stop = true;
            if (thread != null) thread.Join(3000);
        }
    }

    public static class AudioHold {
        static int pollMs = 3000;

        // Blocks for ever: it is the whole life of the helper script. Every few
        // seconds it checks that the default output is still the one it holds
        // (a headset plugged in, a driver reset) and opens a new stream if not.
        public static void Run(int pollMilliseconds) {
            pollMs = pollMilliseconds < 500 ? 500 : pollMilliseconds;
            Thread t = new Thread(new ThreadStart(PollMain));
            t.SetApartmentState(ApartmentState.MTA);
            t.IsBackground = false;
            t.Start();
            t.Join();
        }

        static void PollMain() {
            string currentId = null;
            HoldStream stream = null;
            DateTime nextTry = DateTime.MinValue;
            while (true) {
                try {
                    string id = null;
                    IMMDevice dev = AudioProbe.DefaultRender();
                    if (dev != null) {
                        try { dev.GetId(out id); } finally { Marshal.ReleaseComObject(dev); }
                    }
                    bool dead = stream != null && stream.Failed;
                    bool retry = stream == null && id != null && DateTime.UtcNow >= nextTry;
                    if (id != currentId || dead || retry) {
                        if (stream != null) { stream.Dispose(); stream = null; }
                        currentId = id;
                        if (id != null) {
                            stream = HoldStream.Start();
                            if (stream.Failed) {
                                // A driver without short periods, or a device still starting:
                                // look again later, not every few seconds.
                                stream.Dispose();
                                stream = null;
                                nextTry = DateTime.UtcNow.AddSeconds(30);
                            }
                        }
                    }
                } catch (Exception) {
                    // The device list changes under us while things are plugged in or the
                    // audio service restarts: try again at the next round.
                }
                Thread.Sleep(pollMs);
            }
        }
    }
}
'@

$script:AudioTask = 'Win Juicer - audio de baja latencia'
$script:AudioHelperFile = 'audio-baja-latencia.ps1'
$script:AudioInitFailed = $false
$script:AudioCache = $null

# Compiles the interop once per session; a failure is remembered so that a
# machine that cannot compile it does not retry on every read.
function Initialize-JuicerAudio {
    if ('WinJuicer.AudioProbe' -as [type]) { return }
    if ($script:AudioInitFailed) { throw 'La parte nativa de audio no compiló antes en esta sesión.' }
    try {
        Add-Type -TypeDefinition $script:AudioCSharp -ErrorAction Stop
    } catch {
        $script:AudioInitFailed = $true
        throw
    }
}

# --- What the output is, from the raw probe --------------------------------------

# Whether the endpoint is a Bluetooth one, by the bus of its audio adapter
# (BTHENUM for classic Bluetooth, BTHHFENUM for hands-free, BTHLEDevice for LE
# Audio), or by what the name itself says (Windows names hands-free headsets
# «… Hands-Free»).
function Test-JuicerBluetoothEndpoint {
    param([string]$Enumerator, [string]$AdapterId, [string]$Name)
    if (([string]$Enumerator + ' ' + [string]$AdapterId) -match '(?i)(^|[^a-z])BTH') { return $true }
    [string]$Name -match '(?i)bluetooth|hands-?free'
}

$script:AudioFormFactors = @{
    0 = 'por red'; 1 = 'altavoces'; 2 = 'salida de línea'; 3 = 'auriculares'; 5 = 'auriculares con micrófono'
    6 = 'auricular de teléfono'; 7 = 'digital'; 8 = 'S/PDIF'; 9 = 'HDMI o DisplayPort'
}

function ConvertTo-JuicerAudioMs {
    param([double]$Frames, [double]$Rate)
    if ($Frames -le 0 -or $Rate -le 0) { return 0.0 }
    [Math]::Round($Frames * 1000.0 / $Rate, 2)
}

# 2,7 and 10, with the decimal comma and no trailing zeros.
function Format-JuicerAudioMs {
    param([double]$Ms)
    ([Math]::Round($Ms, 1)).ToString('0.#', [Globalization.CultureInfo]::InvariantCulture).Replace('.', ',')
}

# Raw probe (AudioEndpointInfo, or any object with the same fields) into the
# hashtable the rest of Win Juicer uses; null for no device.
#   Name, Kind (Spanish, '' if unknown), Bluetooth, Enumerator, SampleRate, Bits, Channels,
#   EnhancementsOff ($true / $false, $null when Windows does not say),
#   DefaultFrames, FundamentalFrames, MinFrames, MaxFrames, CurrentFrames (0 = unknown),
#   DefaultMs, MinMs, MaxMs, CurrentMs (0 = unknown),
#   LowLatency ($true: the driver allows a shorter period; $false: min = default; $null: unknown).
function ConvertTo-JuicerAudioInfo {
    param($Raw)
    if (-not $Raw) { return $null }
    $rate = [int]$Raw.SampleRate
    $def = [int]$Raw.DefaultFrames
    $min = [int]$Raw.MinFrames
    $low = $null
    if ($def -gt 0 -and $min -gt 0) { $low = ($min -lt $def) }
    $sysfx = if ($null -eq $Raw.DisableSysFx) { -1 } else { [int]$Raw.DisableSysFx }
    $off = $null
    if ($sysfx -eq 1) { $off = $true } elseif ($sysfx -eq 0) { $off = $false }
    $ff = if ($null -eq $Raw.FormFactor) { -1 } else { [int]$Raw.FormFactor }
    @{
        Name = [string]$Raw.Name; Kind = $(if ($script:AudioFormFactors.ContainsKey($ff)) { $script:AudioFormFactors[$ff] } else { '' })
        Bluetooth = [bool](Test-JuicerBluetoothEndpoint ([string]$Raw.Enumerator) ([string]$Raw.AdapterId) ([string]$Raw.Name))
        Enumerator = [string]$Raw.Enumerator
        SampleRate = $rate; Bits = [int]$Raw.Bits; Channels = [int]$Raw.Channels
        EnhancementsOff = $off
        DefaultFrames = $def; FundamentalFrames = [int]$Raw.FundamentalFrames; MinFrames = $min
        MaxFrames = [int]$Raw.MaxFrames; CurrentFrames = [int]$Raw.CurrentFrames
        DefaultMs = (ConvertTo-JuicerAudioMs $def $rate); MinMs = (ConvertTo-JuicerAudioMs $min $rate)
        MaxMs = (ConvertTo-JuicerAudioMs ([int]$Raw.MaxFrames) $rate); CurrentMs = (ConvertTo-JuicerAudioMs ([int]$Raw.CurrentFrames) $rate)
        LowLatency = $low
    }
}

# --- Reading this PC ----------------------------------------------------------------

# The real backend's AudioInfo. Read again at most every ten seconds: every
# state refresh of the catalog asks, and opening the audio endpoint is not free.
function Get-WinAudioInfo {
    if (-not (Test-JuicerWindows)) { return $null }
    if ($script:AudioCache -and ((Get-Date) - $script:AudioCache.When).TotalSeconds -lt 10) { return $script:AudioCache.Info }
    $info = $null
    try {
        Initialize-JuicerAudio
        $info = ConvertTo-JuicerAudioInfo ([WinJuicer.AudioProbe]::GetDefaultRender())
    } catch {
        # No audio service, no output, a driver that errors: unknown, not a failure.
        Write-JuicerLog "Audio: no se pudo leer la salida predeterminada: $_"
    }
    $script:AudioCache = @{ When = Get-Date; Info = $info }
    $info
}

# The default output as ConvertTo-JuicerAudioInfo gives it, null when it cannot be read.
function Get-JuicerAudioInfo {
    try { & (Get-JuicerBackend).AudioInfo } catch { Write-Verbose "Sin audio: $_"; $null }
}

# --- What it means ----------------------------------------------------------------------

# Findings for the diagnosis. Unknown things are not mentioned. With Bluetooth
# nothing about the engine period is said: the radio adds a hundred times what
# a shorter period saves.
function Get-JuicerAudioFindings {
    param($Info)
    $area = 'Audio'
    $out = @()
    if (-not $Info) { return $out }
    $kind = if ($Info.Kind) { " ($($Info.Kind))" } else { '' }
    $mix = ''
    if ($Info.SampleRate -gt 0) { $mix = ', mezcla a {0} Hz' -f $Info.SampleRate; if ($Info.Bits -gt 0) { $mix += ' y {0} bits' -f $Info.Bits } }
    $out += New-JuicerFinding $area 'Info' "Salida de audio predeterminada: $($Info.Name)$kind$mix"
    if ($Info.Bluetooth) {
        $out += New-JuicerFinding $area 'Medio' 'La salida de audio es Bluetooth: añade entre 100 y 300 ms de retardo' 'El sonido por Bluetooth tarda entre 100 y 300 ms según el códec (más con el micrófono activo, en modo manos libres), cien veces más de lo que se gana con cualquier ajuste de Windows. Para jugar, usa auriculares con cable o con receptor propio de 2,4 GHz (el que va en un USB), no Bluetooth.'
    }
    if ($Info.EnhancementsOff -eq $false) {
        $out += New-JuicerFinding $area 'Bajo' 'Las mejoras de audio están activadas' 'Los efectos (refuerzo de graves, sonido envolvente virtual, igualación de sonoridad, ecualizador) procesan el sonido antes de sacarlo, y algunos suman latencia y CPU. Si no usas ninguno, desactívalas en Configuración > Sistema > Sonido > tu dispositivo de salida > Mejoras de audio. El sonido sólo cambia si usabas uno de esos efectos.'
    }
    if ($Info.SampleRate -gt 0 -and $Info.SampleRate -ne 48000) {
        $out += New-JuicerFinding $area 'Info' ('La mezcla de Windows va a {0} Hz, no a 48000 Hz' -f $Info.SampleRate) 'Casi todos los juegos, Discord y los navegadores trabajan a 48000 Hz: con otra frecuencia, Windows reconvierte el sonido de cada uno (remuestreo), con algo de CPU y de latencia. Si no tienes una razón para otra (música en alta resolución), cámbiala en Configuración > Sistema > Sonido > tu dispositivo de salida > Formato.'
    }
    if (-not $Info.Bluetooth) {
        if ($Info.CurrentFrames -gt 0 -and $Info.DefaultFrames -gt 0 -and $Info.CurrentFrames -lt $Info.DefaultFrames) {
            $out += New-JuicerFinding $area 'Ok' ('El motor de audio ya va a {0} ms (Windows usa {1} ms por defecto)' -f (Format-JuicerAudioMs $Info.CurrentMs), (Format-JuicerAudioMs $Info.DefaultMs)) 'Algún programa, o el modo «Audio de baja latencia» de Win Juicer, tiene pedido el período corto: lo aprovechan todos los programas que suenan por esta salida.'
        } elseif ($Info.LowLatency -eq $true) {
            $out += New-JuicerFinding $area 'Info' ('Audio: {0} ms ahora; tu driver permite {1} ms' -f (Format-JuicerAudioMs $Info.DefaultMs), (Format-JuicerAudioMs $Info.MinMs)) 'Windows mezcla el audio en períodos de 10 ms (unos 20-30 ms de la partida al altavoz). Tu driver admite períodos más cortos: el ajuste «Audio de baja latencia» (audio.latencia) mantiene uno abierto y todos los programas, juegos y Discord incluidos, se benefician, siempre mezclados. Quita unos 5-7 ms; no es un milagro, pero es gratis y se deshace.' 'audio.latencia'
        } elseif ($Info.LowLatency -eq $false) {
            $out += New-JuicerFinding $area 'Info' ('Tu driver de audio no admite baja latencia (mínimo = por defecto: {0} ms)' -f (Format-JuicerAudioMs $Info.DefaultMs)) 'El período más corto que admite es el que Windows ya usa, así que no hay nada que ganar. Es cosa del driver: algunos de fabricante lo fijan y el genérico de Windows («Dispositivo de audio de alta definición») suele admitir períodos cortos.'
        }
    }
    $out
}

# The lines «Listo para jugar» shows (see Get-JuicerReadyStatus): the same
# things, as a tick or a warning. Unknown things are left out.
function Get-JuicerAudioReadyLines {
    param($Info)
    $out = New-Object System.Collections.ArrayList
    if (-not $Info) { return @() }
    # Neutral lines are context, not a verdict: they carry Ok = $true and Info = $true.
    $add = { param($k, $ok, $t, $r, $neutral) [void]$out.Add(@{ Key = $k; Ok = [bool]$ok; Info = [bool]$neutral; Title = $t; Reason = $r }) }
    if ($Info.Bluetooth) {
        & $add 'audio-bt' $false 'El audio sale por Bluetooth' 'Añade entre 100 y 300 ms de retardo: es lo que más pesa en el audio de un juego. Usa auriculares con cable o con receptor de 2,4 GHz.' $false
    } elseif ($Info.Name) {
        & $add 'audio-bt' $true "Audio sin Bluetooth: $($Info.Name)" '' $false
    }
    if ($null -ne $Info.EnhancementsOff) {
        if ($Info.EnhancementsOff) { & $add 'audio-mejoras' $true 'Mejoras de audio desactivadas' '' $false }
        else { & $add 'audio-mejoras' $false 'Mejoras de audio activadas' 'Procesan el sonido y algunas suman latencia. Si no las usas: Configuración > Sistema > Sonido > tu dispositivo > Mejoras de audio.' $false }
    }
    if ($Info.SampleRate -gt 0) {
        if ($Info.SampleRate -eq 48000) { & $add 'audio-frecuencia' $true 'Audio a 48000 Hz' '' $false }
        else { & $add 'audio-frecuencia' $true ('Audio a {0} Hz, no a 48000 Hz' -f $Info.SampleRate) 'Los juegos y Discord usan 48000 Hz: con otra frecuencia Windows reconvierte el sonido. Cámbiala en Configuración > Sistema > Sonido > tu dispositivo > Formato.' $true }
    }
    if (-not $Info.Bluetooth) {
        if ($Info.CurrentFrames -gt 0 -and $Info.DefaultFrames -gt 0 -and $Info.CurrentFrames -lt $Info.DefaultFrames) {
            & $add 'audio-latencia' $true ('Audio de baja latencia en marcha: {0} ms (por defecto {1} ms)' -f (Format-JuicerAudioMs $Info.CurrentMs), (Format-JuicerAudioMs $Info.DefaultMs)) '' $false
        } elseif ($Info.LowLatency -eq $true) {
            & $add 'audio-latencia' $true ('Audio: {0} ms ahora; tu driver permite {1} ms' -f (Format-JuicerAudioMs $Info.DefaultMs), (Format-JuicerAudioMs $Info.MinMs)) 'Quita unos 5-7 ms de latencia de audio a todos los programas. Ajuste «audio.latencia» (a la carta, se deshace).' $true
        } elseif ($Info.LowLatency -eq $false) {
            & $add 'audio-latencia' $true 'Tu driver de audio no admite baja latencia (mínimo = por defecto)' 'No hay período más corto que ganar con este driver.' $true
        }
    }
    $out.ToArray()
}

function Get-JuicerAudioAudit {
    Get-JuicerAudioFindings (Get-JuicerAudioInfo)
}

# --- The tweak ---------------------------------------------------------------------------

# Why «Audio de baja latencia» cannot apply here, or null. Once it is in place it is never
# skipped, so a different default output (a Bluetooth headset) cannot hide it from Undo.
function Get-JuicerAudioSkip {
    $h = & (Get-JuicerBackend).AudioHelperState
    if ($h -and $h.Installed) { return $null }
    $info = Get-JuicerAudioInfo
    if (-not $info) { return 'No hay una salida de audio activa que Win Juicer pueda leer: sin dispositivo de reproducción no hay nada que mantener a baja latencia.' }
    if ($info.DefaultFrames -le 0 -or $info.MinFrames -le 0) {
        return "Windows no ha dicho qué períodos admite «$($info.Name)» (hace falta Windows 10 o posterior y un driver que lo informe): no se puede saber si ganaría algo."
    }
    if ($info.MinFrames -ge $info.DefaultFrames) {
        return ('Tu driver de audio no admite baja latencia: el período mínimo de «{0}» es de {1} ms, el mismo que usa Windows. Es cosa del driver; el genérico de Windows («Dispositivo de audio de alta definición») suele admitir períodos cortos.' -f $info.Name, (Format-JuicerAudioMs $info.MinMs))
    }
    $null
}

function New-JuicerAudioTweak {
    @{
        Id = 'audio.latencia'; Category = 'Audio'; Level = 0; Impact = 'Bajo'; Reboot = 'No'
        Title = 'Audio de baja latencia'
        What = 'Mantiene abierto un flujo de audio silencioso en tu salida predeterminada con el período más corto que admite el driver (por ejemplo 2,7 ms en vez de 10 ms). Mientras exista, el motor de audio de Windows trabaja a ese período para todos los programas (juegos, Discord, el navegador), que siguen mezclándose como siempre: no toma el dispositivo en exclusiva. Lo hace un script pequeño que arranca al iniciar sesión con tu usuario (tarea programada «Win Juicer - audio de baja latencia»), oculto y con prioridad baja, y se pone en marcha ahora.'
        Gain = 'Unos 5-7 ms menos de latencia de salida, de los 20-30 ms que suma Windows. Se nota en juegos de ritmo o de puntería con sonido de pasos, no en los FPS. No sirve con Bluetooth, que añade 100-300 ms por su cuenta.'
        Cost = 'Un proceso de PowerShell oculto siempre abierto (unas decenas de MB) y unos cientos de despertares de CPU por segundo: poca CPU, pero en un portátil, algo de batería. Depende del driver: con alguno, un período tan corto puede dar chasquidos si el equipo va muy cargado; si te pasa, Deshacer lo quita y el audio vuelve a 10 ms.'
        Skip = { Get-JuicerAudioSkip }
        Actions = @(
            @{
                Type = 'Custom'; Key = 'audiolatencia'; Label = 'Tarea «Win Juicer - audio de baja latencia», su script y su flujo silencioso'
                Test = { $h = & (Get-JuicerBackend).AudioHelperState; [bool]($h -and $h.Installed) }
                Capture = { $h = & (Get-JuicerBackend).AudioHelperState; @{ Installed = [bool]($h -and $h.Installed) } }
                Apply = { & (Get-JuicerBackend).AudioHelperInstall }
                Restore = { param($s) if (-not $s.Installed) { & (Get-JuicerBackend).AudioHelperRemove } }
            }
        )
    }
}

# --- The helper script and its task -------------------------------------------------------

function Get-JuicerAudioHelperDir { Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'WinJuicer' }

# The script the task runs: self-contained (the interop is inside it), because it
# lives in the user's profile and cannot depend on where Win Juicer was started from.
# One copy at a time, by a mutex per session.
function Get-JuicerAudioHelperScript {
    $head = @'
# Win Juicer: audio de baja latencia.
# Mantiene abierto un flujo compartido y silencioso en la salida de audio predeterminada, con el
# período más corto que admite el driver, para que el motor de audio de Windows trabaje a ese
# período con todos los programas. No reproduce nada ni toma el dispositivo en exclusiva.
# Lo arranca una tarea programada al iniciar sesión; «Deshacer» en Win Juicer la quita junto con este archivo.
$ErrorActionPreference = 'Stop'
$created = $false
$mutex = New-Object System.Threading.Mutex($true, 'Local\WinJuicerAudioBajaLatencia', [ref]$created)
if (-not $created) { return }
try {
    try { [System.Diagnostics.Process]::GetCurrentProcess().PriorityClass = 'BelowNormal' } catch { $null = $_ }
'@
    $tail = @'
    [WinJuicer.AudioHold]::Run(3000)
} finally {
    $mutex.ReleaseMutex()
}
'@
    $head + "`n    Add-Type -TypeDefinition @'`n" + $script:AudioCSharp + "`n'@`n" + $tail
}

function Get-WinAudioHelperState {
    if (-not (Test-JuicerWindows)) { return @{ Installed = $false; Running = $false } }
    $task = $null
    try { $task = Get-ScheduledTask -TaskName $script:AudioTask -ErrorAction SilentlyContinue } catch { Write-Verbose "Sin tareas programadas: $_" }
    $file = Join-Path (Get-JuicerAudioHelperDir) $script:AudioHelperFile
    @{
        Installed = [bool]($null -ne $task -and (Test-Path -LiteralPath $file))
        Running = [bool]($null -ne $task -and [string]$task.State -eq 'Running')
    }
}

function Install-WinAudioHelper {
    if (-not (Test-JuicerWindows)) { return }
    $dir = Get-JuicerAudioHelperDir
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $file = Join-Path $dir $script:AudioHelperFile
    # With a BOM, so Windows PowerShell 5.1 reads the accents.
    [IO.File]::WriteAllText($file, (Get-JuicerAudioHelperScript), (New-Object Text.UTF8Encoding $true))
    # Windows PowerShell 5.1 compiles the interop with its own compiler and is on every Windows 11.
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $action = New-ScheduledTaskAction -Execute $ps -Argument "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$file`""
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
    $trigger.Delay = 'PT30S'
    # As the person signed in, not elevated: audio sessions belong to the user.
    $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
    # No time limit, one copy, below normal priority, and back up if it ever stops.
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew -Priority 8 -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
    $script:AudioCache = $null
    Register-ScheduledTask -TaskName $script:AudioTask -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description 'Mantiene el motor de audio de Windows en su período mínimo (Win Juicer).' -Force | Out-Null
    Write-JuicerLog "Audio de baja latencia: tarea registrada con $file"
    try { Start-ScheduledTask -TaskName $script:AudioTask -ErrorAction Stop } catch { Write-JuicerLog "Audio de baja latencia: no se pudo arrancar ahora, lo hará al iniciar sesión: $_" }
}

function Remove-WinAudioHelper {
    if (-not (Test-JuicerWindows)) { return }
    $file = Join-Path (Get-JuicerAudioHelperDir) $script:AudioHelperFile
    if ($null -ne (Get-ScheduledTask -TaskName $script:AudioTask -ErrorAction SilentlyContinue)) {
        Stop-ScheduledTask -TaskName $script:AudioTask -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $script:AudioTask -Confirm:$false
    }
    # A copy the task did not start (or that outlived it): ending the process releases the stream.
    try {
        foreach ($p in @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction Stop | Where-Object { $_.CommandLine -like "*$($script:AudioHelperFile)*" })) {
            Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
        }
    } catch {
        Write-JuicerLog "Audio de baja latencia: no se pudo buscar el proceso: $_"
    }
    Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
    $script:AudioCache = $null
    Write-JuicerLog 'Audio de baja latencia: tarea, script y flujo quitados'
}
