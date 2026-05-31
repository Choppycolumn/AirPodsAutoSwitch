# AirPods Auto Switch for Windows

This is a best-effort Windows helper for AirPods and other Bluetooth headphones.

It cannot join Apple's official AirPods automatic switching system. Apple's feature
works between Apple devices signed in to the same Apple Account, while Windows only
sees the headphones as a normal Bluetooth audio device.

What this helper can do:

- Watch the current Windows output level.
- When this PC starts playing audio, ask Windows to connect a paired Bluetooth
  audio device whose name matches `AirPods`.
- Optionally set the matching AirPods audio endpoint as the default Windows output.
- Optionally disconnect the AirPods after this PC has been idle for a while.

What it cannot do by itself:

- Know that your iPhone or iPad started playing audio.
- Force iOS to release the AirPods in the same way Apple's private auto-switching
  does.
- Guarantee instant switching. Windows Bluetooth behavior depends on the Bluetooth
  adapter, driver, headset firmware, and whether another device is actively using
  the headphones.

## Quick Start

### Desktop app

Double-click:

```text
Start-AirPodsAutoSwitchApp.cmd
```

Or build a single executable package:

```powershell
.\Build-AppPackage.ps1
```

The generated package is written to:

```text
dist\AirPodsAutoSwitchApp.exe
```

In the app:

- Pick `所有 AirPods` to let Windows try every paired AirPods-like device, or pick
  a specific paired headset.
- Click `开启自动切换` / `关闭自动切换` to turn the watcher on or off.
- Click `立即连接` to test the selected device immediately.
- Close the window while auto switch is running to keep it in the system tray.

Settings are saved in `%APPDATA%\AirPodsAutoSwitchApp\config.json`, so they also
persist when the app is launched from the packaged `.exe`.

### Command line

Open PowerShell in this folder and list detected devices first:

```powershell
.\AirPodsAutoSwitch.ps1 -ListDevices
```

Run the local auto-connect loop:

```powershell
.\AirPodsAutoSwitch.ps1 -DeviceNamePattern "AirPods" -AudioEndpointNamePattern "AirPods"
```

If Windows does not connect when audio starts, retry with a service toggle:

```powershell
.\AirPodsAutoSwitch.ps1 -DeviceNamePattern "AirPods" -AudioEndpointNamePattern "AirPods" -ForceReconnect
```

Disconnect after 3 minutes of no local playback:

```powershell
.\AirPodsAutoSwitch.ps1 -DeviceNamePattern "AirPods" -AudioEndpointNamePattern "AirPods" -DisconnectWhenIdle -IdleDisconnectSeconds 180
```

## Notes

- Pair the AirPods with Windows manually before using this helper.
- Leave Bluetooth enabled in Windows.
- Keep the AirPods out of the case and nearby.
- `-ForceReconnect` and `-DisconnectWhenIdle` toggle the Bluetooth audio service
  state for the matched device. If Windows gets confused, run the script again
  without `-DisconnectWhenIdle`, or reconnect from Windows Bluetooth settings.
- For real "whichever computer plays" switching across multiple Windows PCs, each
  PC needs a small companion app and a shared coordination channel. This script is
  the local trigger piece.
