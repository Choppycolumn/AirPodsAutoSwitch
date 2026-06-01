[CmdletBinding()]
param(
    [string]$DeviceNamePattern = "AirPods",
    [string]$AudioEndpointNamePattern = "AirPods",
    [double]$PeakThreshold = 0.015,
    [int]$ActiveSamples = 3,
    [int]$PollMs = 500,
    [int]$CooldownSeconds = 10,
    [switch]$ForceReconnect,
    [switch]$DisconnectWhenIdle,
    [int]$IdleDisconnectSeconds = 180,
    [switch]$SetCommunicationsDefault,
    [switch]$ListDevices,
    [switch]$Once,
    [switch]$LoadOnly,
    [switch]$ConnectNow,
    [switch]$DisconnectNow,
    [int]$EndpointReadyTimeoutSeconds = 10,
    [int]$EndpointRetryMs = 700
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

$source = @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace AirPodsSwitch
{
    public sealed class BluetoothDeviceRecord
    {
        public string Name { get; set; }
        public string Address { get; set; }
        public bool Connected { get; set; }
        public bool Remembered { get; set; }
        public bool Authenticated { get; set; }
    }

    public sealed class BluetoothOperationResult
    {
        public string DeviceName { get; set; }
        public string Service { get; set; }
        public string Action { get; set; }
        public int ResultCode { get; set; }
        public bool Success { get { return ResultCode == 0; } }
    }

    public static class BluetoothTools
    {
        private const uint BLUETOOTH_SERVICE_DISABLE = 0x00000000;
        private const uint BLUETOOTH_SERVICE_ENABLE = 0x00000001;

        private static readonly Guid AudioSink = new Guid("0000110B-0000-1000-8000-00805F9B34FB");
        private static readonly Guid AvRemoteControlTarget = new Guid("0000110C-0000-1000-8000-00805F9B34FB");
        private static readonly Guid AvRemoteControl = new Guid("0000110E-0000-1000-8000-00805F9B34FB");
        private static readonly Guid Headset = new Guid("00001108-0000-1000-8000-00805F9B34FB");
        private static readonly Guid Handsfree = new Guid("0000111E-0000-1000-8000-00805F9B34FB");

        public static List<BluetoothDeviceRecord> ListDevices()
        {
            List<BluetoothDeviceRecord> records = new List<BluetoothDeviceRecord>();
            ForEachDevice(delegate(IntPtr radio, BLUETOOTH_DEVICE_INFO info)
            {
                records.Add(new BluetoothDeviceRecord
                {
                    Name = info.szName,
                    Address = FormatAddress(info.Address.ullLong),
                    Connected = info.fConnected,
                    Remembered = info.fRemembered,
                    Authenticated = info.fAuthenticated
                });
            });
            return records;
        }

        public static List<BluetoothOperationResult> SetAudioStateByName(string namePattern, bool enable, bool includeHandsfree)
        {
            List<BluetoothOperationResult> results = new List<BluetoothOperationResult>();
            bool found = false;
            Guid[] services = includeHandsfree
                ? new Guid[] { AudioSink, AvRemoteControlTarget, AvRemoteControl, Headset, Handsfree }
                : new Guid[] { AudioSink, AvRemoteControlTarget, AvRemoteControl };

            ForEachDevice(delegate(IntPtr radio, BLUETOOTH_DEVICE_INFO info)
            {
                string name = info.szName == null ? "" : info.szName;
                if (name.IndexOf(namePattern, StringComparison.OrdinalIgnoreCase) < 0)
                {
                    return;
                }

                found = true;
                for (int i = 0; i < services.Length; i++)
                {
                    Guid service = services[i];
                    string serviceName = ServiceName(service);
                    BLUETOOTH_DEVICE_INFO copy = info;
                    copy.dwSize = Marshal.SizeOf(typeof(BLUETOOTH_DEVICE_INFO));
                    int code = BluetoothSetServiceState(
                        radio,
                        ref copy,
                        ref service,
                        enable ? BLUETOOTH_SERVICE_ENABLE : BLUETOOTH_SERVICE_DISABLE);

                    results.Add(new BluetoothOperationResult
                    {
                        DeviceName = name,
                        Service = serviceName,
                        Action = enable ? "enable" : "disable",
                        ResultCode = code
                    });
                }
            });

            if (!found)
            {
                results.Add(new BluetoothOperationResult
                {
                    DeviceName = namePattern,
                    Service = "match",
                    Action = enable ? "enable" : "disable",
                    ResultCode = -1
                });
            }

            return results;
        }

        private delegate void DeviceVisitor(IntPtr radio, BLUETOOTH_DEVICE_INFO info);

        private static void ForEachDevice(DeviceVisitor visitor)
        {
            BLUETOOTH_FIND_RADIO_PARAMS radioParams = new BLUETOOTH_FIND_RADIO_PARAMS();
            radioParams.dwSize = Marshal.SizeOf(typeof(BLUETOOTH_FIND_RADIO_PARAMS));

            IntPtr radio;
            IntPtr radioFind = BluetoothFindFirstRadio(ref radioParams, out radio);
            if (radioFind == IntPtr.Zero)
            {
                return;
            }

            try
            {
                bool hasRadio = true;
                while (hasRadio)
                {
                    try
                    {
                        EnumerateDevicesForRadio(radio, visitor);
                    }
                    finally
                    {
                        CloseHandle(radio);
                    }

                    hasRadio = BluetoothFindNextRadio(radioFind, out radio);
                }
            }
            finally
            {
                BluetoothFindRadioClose(radioFind);
            }
        }

        private static void EnumerateDevicesForRadio(IntPtr radio, DeviceVisitor visitor)
        {
            BLUETOOTH_DEVICE_SEARCH_PARAMS search = new BLUETOOTH_DEVICE_SEARCH_PARAMS();
            search.dwSize = Marshal.SizeOf(typeof(BLUETOOTH_DEVICE_SEARCH_PARAMS));
            search.fReturnAuthenticated = true;
            search.fReturnRemembered = true;
            search.fReturnUnknown = false;
            search.fReturnConnected = true;
            search.fIssueInquiry = false;
            search.cTimeoutMultiplier = 0;
            search.hRadio = radio;

            BLUETOOTH_DEVICE_INFO info = new BLUETOOTH_DEVICE_INFO();
            info.dwSize = Marshal.SizeOf(typeof(BLUETOOTH_DEVICE_INFO));

            IntPtr deviceFind = BluetoothFindFirstDevice(ref search, ref info);
            if (deviceFind == IntPtr.Zero)
            {
                return;
            }

            try
            {
                bool hasDevice = true;
                while (hasDevice)
                {
                    visitor(radio, info);
                    info.dwSize = Marshal.SizeOf(typeof(BLUETOOTH_DEVICE_INFO));
                    hasDevice = BluetoothFindNextDevice(deviceFind, ref info);
                }
            }
            finally
            {
                BluetoothFindDeviceClose(deviceFind);
            }
        }

        private static string ServiceName(Guid service)
        {
            if (service == AudioSink) return "AudioSink";
            if (service == AvRemoteControlTarget) return "AvRemoteControlTarget";
            if (service == AvRemoteControl) return "AvRemoteControl";
            if (service == Headset) return "Headset";
            if (service == Handsfree) return "Handsfree";
            return service.ToString();
        }

        private static string FormatAddress(ulong value)
        {
            ulong address = value & 0x0000FFFFFFFFFFFFUL;
            string[] parts = new string[6];
            for (int i = 5; i >= 0; i--)
            {
                int index = 5 - i;
                parts[index] = ((address >> (8 * i)) & 0xFF).ToString("X2");
            }
            return string.Join(":", parts);
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct BLUETOOTH_FIND_RADIO_PARAMS
        {
            public int dwSize;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct BLUETOOTH_ADDRESS
        {
            public ulong ullLong;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct SYSTEMTIME
        {
            public ushort wYear;
            public ushort wMonth;
            public ushort wDayOfWeek;
            public ushort wDay;
            public ushort wHour;
            public ushort wMinute;
            public ushort wSecond;
            public ushort wMilliseconds;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct BLUETOOTH_DEVICE_INFO
        {
            public int dwSize;
            public BLUETOOTH_ADDRESS Address;
            public uint ulClassofDevice;
            [MarshalAs(UnmanagedType.Bool)]
            public bool fConnected;
            [MarshalAs(UnmanagedType.Bool)]
            public bool fRemembered;
            [MarshalAs(UnmanagedType.Bool)]
            public bool fAuthenticated;
            public SYSTEMTIME stLastSeen;
            public SYSTEMTIME stLastUsed;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 248)]
            public string szName;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct BLUETOOTH_DEVICE_SEARCH_PARAMS
        {
            public int dwSize;
            [MarshalAs(UnmanagedType.Bool)]
            public bool fReturnAuthenticated;
            [MarshalAs(UnmanagedType.Bool)]
            public bool fReturnRemembered;
            [MarshalAs(UnmanagedType.Bool)]
            public bool fReturnUnknown;
            [MarshalAs(UnmanagedType.Bool)]
            public bool fReturnConnected;
            [MarshalAs(UnmanagedType.Bool)]
            public bool fIssueInquiry;
            public byte cTimeoutMultiplier;
            public IntPtr hRadio;
        }

        [DllImport("Bthprops.cpl", SetLastError = true)]
        private static extern IntPtr BluetoothFindFirstRadio(ref BLUETOOTH_FIND_RADIO_PARAMS pbtfrp, out IntPtr phRadio);

        [DllImport("Bthprops.cpl", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool BluetoothFindNextRadio(IntPtr hFind, out IntPtr phRadio);

        [DllImport("Bthprops.cpl", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool BluetoothFindRadioClose(IntPtr hFind);

        [DllImport("Bthprops.cpl", SetLastError = true)]
        private static extern IntPtr BluetoothFindFirstDevice(ref BLUETOOTH_DEVICE_SEARCH_PARAMS pbtsp, ref BLUETOOTH_DEVICE_INFO pbtdi);

        [DllImport("Bthprops.cpl", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool BluetoothFindNextDevice(IntPtr hFind, ref BLUETOOTH_DEVICE_INFO pbtdi);

        [DllImport("Bthprops.cpl", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool BluetoothFindDeviceClose(IntPtr hFind);

        [DllImport("Bthprops.cpl", SetLastError = true)]
        private static extern int BluetoothSetServiceState(IntPtr hRadio, ref BLUETOOTH_DEVICE_INFO pbtdi, ref Guid pGuidService, uint dwServiceFlags);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CloseHandle(IntPtr hObject);
    }

    public sealed class AudioEndpointRecord
    {
        public string Name { get; set; }
        public string Id { get; set; }
        public string State { get; set; }
    }

    public static class AudioTools
    {
        private static readonly PROPERTYKEY PKEY_Device_FriendlyName = new PROPERTYKEY
        {
            fmtid = new Guid("A45C254E-DF1C-4EFD-8020-67D146A850E0"),
            pid = 14
        };

        public static float GetDefaultRenderPeak()
        {
            IMMDeviceEnumerator enumerator = null;
            IMMDevice device = null;
            object meterObject = null;
            try
            {
                enumerator = (IMMDeviceEnumerator)(new MMDeviceEnumeratorComObject());
                int hr = enumerator.GetDefaultAudioEndpoint(EDataFlow.eRender, ERole.eMultimedia, out device);
                if (hr != 0 || device == null)
                {
                    return 0.0f;
                }

                Guid iid = typeof(IAudioMeterInformation).GUID;
                hr = device.Activate(ref iid, CLSCTX.ALL, IntPtr.Zero, out meterObject);
                if (hr != 0 || meterObject == null)
                {
                    return 0.0f;
                }

                float peak;
                hr = ((IAudioMeterInformation)meterObject).GetPeakValue(out peak);
                return hr == 0 ? peak : 0.0f;
            }
            finally
            {
                ReleaseCom(meterObject);
                ReleaseCom(device);
                ReleaseCom(enumerator);
            }
        }

        public static List<AudioEndpointRecord> ListRenderEndpoints()
        {
            List<AudioEndpointRecord> records = new List<AudioEndpointRecord>();
            IMMDeviceEnumerator enumerator = null;
            IMMDeviceCollection collection = null;
            try
            {
                enumerator = (IMMDeviceEnumerator)(new MMDeviceEnumeratorComObject());
                int hr = enumerator.EnumAudioEndpoints(EDataFlow.eRender, DEVICE_STATE.MASK_ALL, out collection);
                if (hr != 0 || collection == null)
                {
                    return records;
                }

                uint count;
                collection.GetCount(out count);
                for (uint i = 0; i < count; i++)
                {
                    IMMDevice device = null;
                    try
                    {
                        if (collection.Item(i, out device) != 0 || device == null)
                        {
                            continue;
                        }

                        string id;
                        device.GetId(out id);
                        DEVICE_STATE state;
                        device.GetState(out state);
                        records.Add(new AudioEndpointRecord
                        {
                            Name = GetFriendlyName(device),
                            Id = id,
                            State = state.ToString()
                        });
                    }
                    finally
                    {
                        ReleaseCom(device);
                    }
                }
            }
            finally
            {
                ReleaseCom(collection);
                ReleaseCom(enumerator);
            }

            return records;
        }

        public static AudioEndpointRecord GetDefaultRenderEndpoint()
        {
            IMMDeviceEnumerator enumerator = null;
            IMMDevice device = null;
            try
            {
                enumerator = (IMMDeviceEnumerator)(new MMDeviceEnumeratorComObject());
                int hr = enumerator.GetDefaultAudioEndpoint(EDataFlow.eRender, ERole.eMultimedia, out device);
                if (hr != 0 || device == null)
                {
                    return null;
                }

                string id;
                device.GetId(out id);
                DEVICE_STATE state;
                device.GetState(out state);
                return new AudioEndpointRecord
                {
                    Name = GetFriendlyName(device),
                    Id = id,
                    State = state.ToString()
                };
            }
            finally
            {
                ReleaseCom(device);
                ReleaseCom(enumerator);
            }
        }

        public static bool DefaultRenderEndpointMatches(string namePattern)
        {
            AudioEndpointRecord endpoint = GetDefaultRenderEndpoint();
            return endpoint != null &&
                endpoint.Name != null &&
                endpoint.Name.IndexOf(namePattern, StringComparison.OrdinalIgnoreCase) >= 0;
        }

        public static bool SetDefaultRenderEndpointByName(string namePattern, bool includeCommunications)
        {
            List<AudioEndpointRecord> records = ListRenderEndpoints();
            string id = null;
            for (int i = 0; i < records.Count; i++)
            {
                AudioEndpointRecord record = records[i];
                if (record.Name != null &&
                    record.State.IndexOf("ACTIVE", StringComparison.OrdinalIgnoreCase) >= 0 &&
                    record.Name.IndexOf(namePattern, StringComparison.OrdinalIgnoreCase) >= 0)
                {
                    id = record.Id;
                    break;
                }
            }

            if (id == null)
            {
                return false;
            }

            IPolicyConfig policy = null;
            try
            {
                policy = (IPolicyConfig)(new PolicyConfigClient());
                bool ok = true;
                ok = policy.SetDefaultEndpoint(id, ERole.eConsole) == 0 && ok;
                ok = policy.SetDefaultEndpoint(id, ERole.eMultimedia) == 0 && ok;
                if (includeCommunications)
                {
                    ok = policy.SetDefaultEndpoint(id, ERole.eCommunications) == 0 && ok;
                }
                return ok;
            }
            finally
            {
                ReleaseCom(policy);
            }
        }

        private static string GetFriendlyName(IMMDevice device)
        {
            IPropertyStore store = null;
            try
            {
                if (device.OpenPropertyStore(STGM.READ, out store) != 0 || store == null)
                {
                    return "";
                }

                PROPERTYKEY friendlyNameKey = PKEY_Device_FriendlyName;
                PROPVARIANT variant;
                if (store.GetValue(ref friendlyNameKey, out variant) != 0)
                {
                    return "";
                }

                try
                {
                    if (variant.vt == 31 && variant.p != IntPtr.Zero)
                    {
                        return Marshal.PtrToStringUni(variant.p);
                    }
                    return "";
                }
                finally
                {
                    PropVariantClear(ref variant);
                }
            }
            finally
            {
                ReleaseCom(store);
            }
        }

        private static void ReleaseCom(object obj)
        {
            if (obj != null && Marshal.IsComObject(obj))
            {
                Marshal.ReleaseComObject(obj);
            }
        }

        [ComImport]
        [Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
        private class MMDeviceEnumeratorComObject
        {
        }

        [ComImport]
        [Guid("870AF99C-171D-4F9E-AF0D-E63DF40C2BC9")]
        private class PolicyConfigClient
        {
        }

        private enum EDataFlow
        {
            eRender = 0,
            eCapture = 1,
            eAll = 2
        }

        private enum ERole
        {
            eConsole = 0,
            eMultimedia = 1,
            eCommunications = 2
        }

        [Flags]
        private enum DEVICE_STATE : uint
        {
            ACTIVE = 0x00000001,
            DISABLED = 0x00000002,
            NOTPRESENT = 0x00000004,
            UNPLUGGED = 0x00000008,
            MASK_ALL = 0x0000000F
        }

        private enum STGM
        {
            READ = 0
        }

        [Flags]
        private enum CLSCTX
        {
            INPROC_SERVER = 0x1,
            INPROC_HANDLER = 0x2,
            LOCAL_SERVER = 0x4,
            REMOTE_SERVER = 0x10,
            ALL = INPROC_SERVER | INPROC_HANDLER | LOCAL_SERVER | REMOTE_SERVER
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct PROPERTYKEY
        {
            public Guid fmtid;
            public int pid;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct PROPVARIANT
        {
            public ushort vt;
            public ushort wReserved1;
            public ushort wReserved2;
            public ushort wReserved3;
            public IntPtr p;
            public int p2;
        }

        [ComImport]
        [Guid("A95664D2-9614-4F35-A746-DE8DB63617E6")]
        [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        private interface IMMDeviceEnumerator
        {
            [PreserveSig]
            int EnumAudioEndpoints(EDataFlow dataFlow, DEVICE_STATE dwStateMask, out IMMDeviceCollection ppDevices);

            [PreserveSig]
            int GetDefaultAudioEndpoint(EDataFlow dataFlow, ERole role, out IMMDevice ppEndpoint);

            [PreserveSig]
            int GetDevice([MarshalAs(UnmanagedType.LPWStr)] string pwstrId, out IMMDevice ppDevice);

            [PreserveSig]
            int RegisterEndpointNotificationCallback(IntPtr pClient);

            [PreserveSig]
            int UnregisterEndpointNotificationCallback(IntPtr pClient);
        }

        [ComImport]
        [Guid("0BD7A1BE-7A1A-44DB-8397-CC5392387B5E")]
        [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        private interface IMMDeviceCollection
        {
            [PreserveSig]
            int GetCount(out uint pcDevices);

            [PreserveSig]
            int Item(uint nDevice, out IMMDevice ppDevice);
        }

        [ComImport]
        [Guid("D666063F-1587-4E43-81F1-B948E807363F")]
        [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        private interface IMMDevice
        {
            [PreserveSig]
            int Activate(ref Guid iid, CLSCTX dwClsCtx, IntPtr pActivationParams, [MarshalAs(UnmanagedType.IUnknown)] out object ppInterface);

            [PreserveSig]
            int OpenPropertyStore(STGM stgmAccess, out IPropertyStore ppProperties);

            [PreserveSig]
            int GetId([MarshalAs(UnmanagedType.LPWStr)] out string ppstrId);

            [PreserveSig]
            int GetState(out DEVICE_STATE pdwState);
        }

        [ComImport]
        [Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99")]
        [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        private interface IPropertyStore
        {
            [PreserveSig]
            int GetCount(out uint cProps);

            [PreserveSig]
            int GetAt(uint iProp, out PROPERTYKEY pkey);

            [PreserveSig]
            int GetValue(ref PROPERTYKEY key, out PROPVARIANT pv);

            [PreserveSig]
            int SetValue(ref PROPERTYKEY key, ref PROPVARIANT propvar);

            [PreserveSig]
            int Commit();
        }

        [ComImport]
        [Guid("C02216F6-8C67-4B5B-9D00-D008E73E0064")]
        [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        private interface IAudioMeterInformation
        {
            [PreserveSig]
            int GetPeakValue(out float pfPeak);

            [PreserveSig]
            int GetMeteringChannelCount(out int pnChannelCount);

            [PreserveSig]
            int GetChannelsPeakValues(int u32ChannelCount, [Out] float[] afPeakValues);

            [PreserveSig]
            int QueryHardwareSupport(out int pdwHardwareSupportMask);
        }

        [ComImport]
        [Guid("F8679F50-850A-41CF-9C72-430F290290C8")]
        [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        private interface IPolicyConfig
        {
            [PreserveSig]
            int GetMixFormat([MarshalAs(UnmanagedType.LPWStr)] string pszDeviceName, out IntPtr ppFormat);

            [PreserveSig]
            int GetDeviceFormat([MarshalAs(UnmanagedType.LPWStr)] string pszDeviceName, int bDefault, out IntPtr ppFormat);

            [PreserveSig]
            int ResetDeviceFormat([MarshalAs(UnmanagedType.LPWStr)] string pszDeviceName);

            [PreserveSig]
            int SetDeviceFormat([MarshalAs(UnmanagedType.LPWStr)] string pszDeviceName, IntPtr pEndpointFormat, IntPtr mixFormat);

            [PreserveSig]
            int GetProcessingPeriod([MarshalAs(UnmanagedType.LPWStr)] string pszDeviceName, int bDefault, out long pmftDefaultPeriod, out long pmftMinimumPeriod);

            [PreserveSig]
            int SetProcessingPeriod([MarshalAs(UnmanagedType.LPWStr)] string pszDeviceName, ref long pmftPeriod);

            [PreserveSig]
            int GetShareMode([MarshalAs(UnmanagedType.LPWStr)] string pszDeviceName, IntPtr pMode);

            [PreserveSig]
            int SetShareMode([MarshalAs(UnmanagedType.LPWStr)] string pszDeviceName, IntPtr mode);

            [PreserveSig]
            int GetPropertyValue([MarshalAs(UnmanagedType.LPWStr)] string pszDeviceName, ref PROPERTYKEY key, out PROPVARIANT pv);

            [PreserveSig]
            int SetPropertyValue([MarshalAs(UnmanagedType.LPWStr)] string pszDeviceName, ref PROPERTYKEY key, ref PROPVARIANT pv);

            [PreserveSig]
            int SetDefaultEndpoint([MarshalAs(UnmanagedType.LPWStr)] string pszDeviceName, ERole role);

            [PreserveSig]
            int SetEndpointVisibility([MarshalAs(UnmanagedType.LPWStr)] string pszDeviceName, int bVisible);
        }

        [DllImport("ole32.dll")]
        private static extern int PropVariantClear(ref PROPVARIANT pvar);
    }
}
"@

if (-not ("AirPodsSwitch.BluetoothTools" -as [type])) {
    Add-Type -Language CSharp -TypeDefinition $source
}

if ($LoadOnly) {
    return
}

function Write-OperationResults {
    param([object[]]$Results)

    foreach ($result in $Results) {
        $status = if ($result.Success) { "ok" } else { "error $($result.ResultCode)" }
        Write-Host ("  {0,-22} {1,-24} {2}" -f $result.Action, $result.Service, $status)
    }
}

function Get-DefaultRenderEndpointName {
    $endpoint = [AirPodsSwitch.AudioTools]::GetDefaultRenderEndpoint()
    if ($null -eq $endpoint -or -not $endpoint.Name) {
        return ""
    }

    return $endpoint.Name
}

function Set-VerifiedDefaultEndpoint {
    param([string]$Pattern)

    if (-not $Pattern) {
        return $true
    }

    $retryMs = [Math]::Max(250, $EndpointRetryMs)
    $deadline = (Get-Date).AddSeconds([Math]::Max(1, $EndpointReadyTimeoutSeconds))
    $reportedWaiting = $false

    do {
        $activeMatches = @(
            [AirPodsSwitch.AudioTools]::ListRenderEndpoints() |
                Where-Object {
                    $_.Name -and
                    $_.Name.IndexOf($Pattern, [StringComparison]::OrdinalIgnoreCase) -ge 0 -and
                    $_.State.IndexOf("ACTIVE", [StringComparison]::OrdinalIgnoreCase) -ge 0
                }
        )

        if ($activeMatches.Count -gt 0) {
            $switched = [AirPodsSwitch.AudioTools]::SetDefaultRenderEndpointByName($Pattern, [bool]$SetCommunicationsDefault)
            Start-Sleep -Milliseconds 300
            $defaultEndpoint = [AirPodsSwitch.AudioTools]::GetDefaultRenderEndpoint()
            if ($switched -and
                $null -ne $defaultEndpoint -and
                $defaultEndpoint.Name -and
                $defaultEndpoint.Name.IndexOf($Pattern, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
                Write-Host ("Verified default Windows output: {0}" -f $defaultEndpoint.Name)
                return $true
            }
        } elseif (-not $reportedWaiting) {
            Write-Host ("Waiting for active Windows audio endpoint matching '{0}'..." -f $Pattern)
            $reportedWaiting = $true
        }

        Start-Sleep -Milliseconds $retryMs
    } while ((Get-Date) -lt $deadline)

    $defaultName = Get-DefaultRenderEndpointName
    if (-not $defaultName) {
        $defaultName = "<none>"
    }

    Write-Host ("Switch verification failed. Current default output: {0}" -f $defaultName)
    $matches = @(
        [AirPodsSwitch.AudioTools]::ListRenderEndpoints() |
            Where-Object { $_.Name -and $_.Name.IndexOf($Pattern, [StringComparison]::OrdinalIgnoreCase) -ge 0 }
    )

    if ($matches.Count -gt 0) {
        Write-Host "Matching Windows audio endpoints:"
        $matches | ForEach-Object {
            Write-Host ("  {0} [{1}]" -f $_.Name, $_.State)
        }
    } else {
        Write-Host ("No Windows audio endpoint matched '{0}'." -f $Pattern)
    }

    return $false
}

function Connect-MatchedHeadphones {
    if ($ForceReconnect) {
        Write-Host "Forcing Bluetooth audio service refresh for '$DeviceNamePattern'..."
        $off = [AirPodsSwitch.BluetoothTools]::SetAudioStateByName($DeviceNamePattern, $false, [bool]$SetCommunicationsDefault)
        Write-OperationResults $off
        Start-Sleep -Milliseconds 500
    }

    Write-Host "Connecting Bluetooth audio service for '$DeviceNamePattern'..."
    $on = [AirPodsSwitch.BluetoothTools]::SetAudioStateByName($DeviceNamePattern, $true, [bool]$SetCommunicationsDefault)
    Write-OperationResults $on

    $serviceSuccess = @($on | Where-Object { $_.Success }).Count -gt 0
    if (-not $serviceSuccess) {
        Write-Host ("No Bluetooth audio service was enabled for '{0}'." -f $DeviceNamePattern)
        return $false
    }

    Start-Sleep -Milliseconds 800
    return (Set-VerifiedDefaultEndpoint $AudioEndpointNamePattern)
}

if ($ListDevices) {
    Write-Host "Bluetooth devices:"
    [AirPodsSwitch.BluetoothTools]::ListDevices() |
        Sort-Object Name |
        Format-Table Name, Address, Connected, Remembered, Authenticated -AutoSize

    Write-Host ""
    Write-Host "Windows render endpoints:"
    [AirPodsSwitch.AudioTools]::ListRenderEndpoints() |
        Sort-Object Name |
        Format-Table Name, State, Id -AutoSize

    $peak = [AirPodsSwitch.AudioTools]::GetDefaultRenderPeak()
    Write-Host ""
    Write-Host ("Current default render endpoint: {0}" -f (Get-DefaultRenderEndpointName))
    Write-Host ("Current default render peak: {0:N4}" -f $peak)
    exit 0
}

if ($ConnectNow) {
    $ok = Connect-MatchedHeadphones
    if ($ok) {
        exit 0
    }
    exit 2
}

if ($DisconnectNow) {
    Write-Host "Disconnecting Bluetooth audio service for '$DeviceNamePattern'..."
    $off = [AirPodsSwitch.BluetoothTools]::SetAudioStateByName($DeviceNamePattern, $false, [bool]$SetCommunicationsDefault)
    Write-OperationResults $off
    exit 0
}

Write-Host "Watching Windows audio. Press Ctrl+C to stop."
Write-Host ("DeviceNamePattern='{0}', AudioEndpointNamePattern='{1}', threshold={2}, poll={3}ms" -f $DeviceNamePattern, $AudioEndpointNamePattern, $PeakThreshold, $PollMs)

$consecutiveActive = 0
$lastConnect = [DateTime]::MinValue
$lastLocalAudio = [DateTime]::MinValue
$idleDisconnectDone = $false

while ($true) {
    $now = Get-Date
    $peak = [AirPodsSwitch.AudioTools]::GetDefaultRenderPeak()
    $isActive = $peak -ge $PeakThreshold

    if ($isActive) {
        $consecutiveActive += 1
        $lastLocalAudio = $now
        $idleDisconnectDone = $false
    } else {
        $consecutiveActive = 0
    }

    $cooldownPassed = (($now - $lastConnect).TotalSeconds -ge $CooldownSeconds)
    if ($consecutiveActive -ge $ActiveSamples -and $cooldownPassed) {
        Write-Host ("Audio detected at {0:T}; peak={1:N4}" -f $now, $peak)
        [void](Connect-MatchedHeadphones)
        $lastConnect = Get-Date
        $consecutiveActive = 0

        if ($Once) {
            break
        }
    }

    if ($DisconnectWhenIdle -and -not $idleDisconnectDone -and $lastLocalAudio -ne [DateTime]::MinValue) {
        $idleSeconds = (($now - $lastLocalAudio).TotalSeconds)
        if ($idleSeconds -ge $IdleDisconnectSeconds) {
            Write-Host ("Idle for {0:N0}s; disabling Bluetooth audio service for '$DeviceNamePattern'..." -f $idleSeconds)
            $off = [AirPodsSwitch.BluetoothTools]::SetAudioStateByName($DeviceNamePattern, $false, [bool]$SetCommunicationsDefault)
            Write-OperationResults $off
            $idleDisconnectDone = $true
        }
    }

    Start-Sleep -Milliseconds $PollMs
}
