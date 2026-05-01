# Brave Debloater Scripts

These scripts disable non-core Brave Browser features to replicate the **Brave Origin** debloated experience — without paying for it.

## Disclaimer

**Brave**, **Brave Browser**, **Brave Origin**, **Brave Search**, **Brave Shields**, **Brave Rewards**, **Brave Talk**, **Brave VPN**, **Brave Wallet**, **Brave News**, **Leo**, **Speedreader**, and all related product names, logos, and trademarks are the property of **Brave Software, Inc.** and are used here for identification purposes only.

This project is **not affiliated with, endorsed by, or sponsored by** Brave Software, Inc. in any way.

These scripts are independent community tools that configure existing, officially documented Group Policy settings. They do not modify, reverse-engineer, or redistribute any Brave software.

## What Gets Disabled

| Feature | Policy Key |
|---------|-----------|
| Brave News | `BraveNewsDisabled = 1` |
| Brave Rewards & Ads | `BraveRewardsDisabled = 1` |
| Brave Wallet & Web3 | `BraveWalletDisabled = 1` |
| Speedreader | `BraveSpeedreaderEnabled = 0` |
| Telemetry (P3A, daily ping, metrics) | `BraveP3AEnabled = 0`, `BraveStatsPingEnabled = 0`, `MetricsReportingEnabled = 0` |
| Brave Talk | `BraveTalkDisabled = 1` |
| Tor Private Windows | `TorDisabled = 1` |
| Brave VPN | `BraveVPNDisabled = 1` |
| Wayback Machine | `BraveWaybackMachineEnabled = 0` |
| Web Discovery Project | `BraveWebDiscoveryEnabled = 0` |

### Not Disabled (causes crashes in Brave v147+)

| Feature | Why Skipped |
|---------|------------|
| Leo AI Chat | `BraveAIChatEnabled = 0` triggers CHECK assertion crash. Disable manually at `brave://settings/leo` |
| Sync | `SyncDisabled = 1` breaks browser state restoration on startup |

**What you keep:** Brave Shields (ad/tracker blocking), Brave Search, core browser speed & security updates.

---

## macOS — `debloat-brave-macos.sh`

### Requirements
- macOS 10.14 or later
- Brave Browser installed

### Why Two Files?

On **macOS 14+**, raw plist files in `/Library/Managed Preferences/` are removed on reboot by `mdmclient` unless delivered via a **configuration profile**. To solve this, we provide two files:

| File | Purpose | Persistence |
|------|---------|-------------|
| `debloat-brave-macos.sh` | Script that applies policies **immediately** and installs the profile | Temporary (plist) + Permanent (profile) |
| `debloat-brave.mobileconfig` | macOS configuration profile with all policies | **Permanent** — survives reboots |

### Method 1: Script (Recommended)

The script applies policies **right now** and automatically installs the `.mobileconfig` profile for permanence.

1. **Close Brave completely** (Cmd+Q)
2. Open Terminal and run:

```bash
cd /path/to/this/folder
chmod +x debloat-brave-macos.sh
sudo ./debloat-brave-macos.sh              # Apply debloat + install profile
sudo ./debloat-brave-macos.sh --dry-run    # Preview changes only
sudo ./debloat-brave-macos.sh --restore    # Restore from backup
sudo ./debloat-brave-macos.sh --uninstall  # Remove all policies + profile
```

3. Restart Brave and visit `brave://policy` to verify.

### Method 2: Configuration Profile Only

If you prefer not to run the script, you can install the profile directly:

1. **Close Brave completely** (Cmd+Q)
2. Double-click `debloat-brave.mobileconfig`
3. Go to **System Settings > Privacy & Security > Profiles**
4. Click **Install** and authenticate
5. Restart Brave and visit `brave://policy` to verify

### Undo

```bash
sudo ./debloat-brave-macos.sh --restore    # Pick a backup to restore
sudo ./debloat-brave-macos.sh --uninstall  # Remove all policies + profile
```

Or manually remove the profile:
- **System Settings > Privacy & Security > Profiles > Brave Browser Debloat > Remove**

---

## Windows — Option A: PowerShell Script

### Requirements
- Windows 10/11
- Brave Browser installed
- PowerShell run as **Administrator**

### Usage

1. **Close Brave completely**
2. Right-click PowerShell → **Run as Administrator**
3. Allow script execution (one-time):

```powershell
Set-ExecutionPolicy -Scope Process RemoteSigned
```

4. Run the script:

```powershell
cd C:\path\to\this\folder
.\debloat-brave-windows.ps1              # Apply debloat
.\debloat-brave-windows.ps1 -DryRun      # Preview changes only
.\debloat-brave-windows.ps1 -Restore     # Restore from backup
.\debloat-brave-windows.ps1 -Uninstall   # Remove all policies
```

5. Restart Brave and visit `brave://policy` to verify.

### Undo

```powershell
.\debloat-brave-windows.ps1 -Restore      # Pick a backup to restore
.\debloat-brave-windows.ps1 -Uninstall    # Remove all policies directly
```

---

## Windows — Option B: Registry File (Easiest)

If you prefer not to use PowerShell, just double-click the `.reg` file.

### Usage

1. **Close Brave completely**
2. Double-click `debloat-brave-windows.reg`
3. Click **Yes** on the UAC prompt
4. Click **Yes** to confirm adding to registry
5. Restart Brave and visit `brave://policy` to verify.

### Undo

Double-click `debloat-brave-windows-undo.reg` to remove all policies.

Or open Registry Editor (`regedit`), navigate to:
```
HKEY_LOCAL_MACHINE\SOFTWARE\Policies\BraveSoftware\Brave
```
Delete the value names you want to revert, or change `1` → `0` (and `0` → `1` for `*Enabled` keys).

---

## How It Works

### macOS
Writes managed policy preferences to `/Library/Managed Preferences/com.brave.Browser.plist` using PlistBuddy with correct data types. This is the proper macOS enterprise policy path for Chromium-based browsers.

**CRITICAL:** On macOS, Brave boolean policies **must** be written to the managed preferences location with proper types via PlistBuddy. Writing them to the user plist via `defaults write -bool` causes Brave to crash on startup with `EXC_BREAKPOINT`. The script handles this correctly.

**PERSISTENCE:** On **macOS 14+**, `mdmclient` removes raw plist files from `/Library/Managed Preferences/` on reboot unless they are delivered via a configuration profile. The script installs a `.mobileconfig` profile (`debloat-brave.mobileconfig`) to ensure policies survive reboots permanently. The profile uses the `com.apple.ManagedClient.preferences` payload type with Brave's bundle ID as the managed domain, which is the officially supported method for browser policy management on macOS.

### Windows
Writes **Group Policy registry values** under `HKLM:\SOFTWARE\Policies\BraveSoftware\Brave`. This is the officially supported method to manage Brave in enterprise environments — it completely disables the targeted features rather than just hiding them.

> **Note:** After applying these policies, you may see "Your browser is managed by your organization" in Brave's settings or menu. This is normal and expected — it simply means policy values are active.

---

## Safety & Backups

Both the macOS and PowerShell scripts **automatically back up** your existing settings before making changes:
- **macOS**: Backups saved to `~/.brave-debloat-backups/<timestamp>/`
- **Windows**: Backups saved to `%USERPROFILE%\.brave-debloat-backups\<timestamp>\`

You can restore from these backups using the `--restore` (macOS) or `-Restore` (Windows) flags, or remove all policies directly with `--uninstall` / `-Uninstall`.

---

## References

- [Brave Support — What is Brave Origin?](https://support.brave.app/hc/en-us/articles/38561489788173-What-is-Brave-Origin)
- [Brave Support — Group Policy](https://support.brave.app/hc/en-us/articles/360039248271-Group-Policy)
- [Brave Group Policy Templates](https://support.brave.com/hc/en-us/articles/360039248271)

---

## AI-Generated Code

This project includes code that was generated or assisted by artificial intelligence (AI) tools, including small language models.

### Contributions

We welcome AI-assisted contributions via pull requests. When submitting AI-generated code:

- **Manual review is required.** All code must be reviewed by a human maintainer before merging.
- **You are responsible** for any code you submit, regardless of how it was generated.
- **Test your changes.** Ensure scripts run correctly on the target platform before submitting.
- **Explain the logic.** PR descriptions should explain what the code does and why, especially for complex changes.

### Using AI for Review

AI tools may be used to assist with code review (e.g., catching syntax errors, suggesting improvements, or explaining changes). However:

- **Human oversight is mandatory.** AI suggestions should be verified and validated by a human reviewer.
- **Keep an eye on what is changing.** Reviewers must understand and approve every line that is modified.
- **AI can hallucinate.** Always verify that suggestions are accurate, safe, and appropriate for the codebase.

---

## Disclaimer

**Brave**, **Brave Browser**, **Brave Origin**, **Brave Search**, **Brave Shields**, **Brave Rewards**, **Brave Talk**, **Brave VPN**, **Brave Wallet**, **Brave News**, **Leo**, **Speedreader**, and all related product names, logos, and trademarks are the property of **Brave Software, Inc.** and are used here for identification purposes only.

This project is **not affiliated with, endorsed by, or sponsored by** Brave Software, Inc. in any way.

These scripts are independent community tools that configure existing, officially documented Group Policy settings. They do not modify, reverse-engineer, or redistribute any Brave software.
