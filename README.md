# Jio STB ADB Setup Guide (Windows 11 & 10)

A beginner-friendly, clutter-free walkthrough to enable **network ADB debugging** and sideload custom launchers/apps on supported Jio Set-Top Boxes using a Windows PC and your home Wi-Fi router.

> [!TIP]
> **Need Hands-On Help or Want Vishal Beniwal to Do It For You?**
> * **Mail-in Service:** If you find this guide too technical or complicated, you can ship your box to Vishal Beniwal and he will set it up for you! You can pay whatever your heart desires + return shipping.
> * **Reddit:** Reach out directly to Vishal at [u/ilikechocopies](https://www.reddit.com/user/ilikechocopies)
> * **Instagram:** [@soloxsurfer](https://instagram.com/soloxsurfer)

> [!NOTE]
> **Supported Hardware & Firmware:**
> * **JMSC200Av2** and **JMSB200A** across firmware builds `22.1.09`, `24.1.39`, `25.1.9`, and older.
> * **JHS series (JHSC200 v1 / JioOS 2.0)** on firmware build `stb-jhcs200-11.3.46`.
>
> *Both box families use the exact same `./stage1.sh` workflow. The only minor difference is in **Step 8** (launching the proxy listener).*

> [!TIP]
> **Don't Panic If Something Goes Wrong:**
> * **Box acting up?** Simply factory reset your Jio STB to restore it back to default settings, then start over.
> * **Wi-Fi not connecting properly?** Go into network settings, choose **Forget Network**, re-enter your password, and reconnect. Everything will work fine.

> [!IMPORTANT]
> **Package Installer Limitation (Read This!):**
> Jio disabled the stock Android package installer UI on the box. Because of this, you cannot simply click an APK file directly on the TV to install it. **Every time you want to install apps, you must install them via ADB** from your PC using:
>
> ```bash
> adb install "filename.apk"
> ```

> ❤️ **A quick note from Vishal Beniwal (Instagram @soloxsurfer / Reddit u/ilikechocopies):**  
> If you prefer me to do it for you, you can ship the box over—pay whatever your heart desires + shipping. Otherwise, just keep me in your blessings for future success!

---

## ✨ What Happens After Running the Script?

Once you execute Stage 1, the script performs several handy quality-of-life modifications on your Jio STB:

* 🔓 **ADB Enabled:** Network ADB is activated (expires in 2037) so you can manage and sideload apps.
* 🚀 **Monet Launcher Activated:** Replaces the cluttered stock interface with a clean, customizable TV launcher. The stock launcher is suspended to prevent boot ad reversion.
* ⚡ **Shevery (Shizuku-Compatible API) Installed:** Standalone manager granted full permissions (`WRITE_SECURE_SETTINGS`, `DUMP`, `PACKAGE_USAGE_STATS`, AppOps, and battery exemption) so apps can access privileged APIs and ADB can be re-enabled through Shevery if ever disabled after reboot.
* 🛑 **Automatic Updates, TR-069 & Telemetry Removed:** `com.jio.httpupdate`, `com.jio.usbupdate`, `com.jio.tr069client`, `com.rjil.jio.stb.commandreceiver`, `com.jio.backgroundscheduler`, and JHS `com.iwedia.*` OTA services are completely uninstalled (or disabled if protected by the ROM).
* 🚫 **Startup Boot Ads Removed:** `com.jio.stbadservice` is completely uninstalled (or disabled if protected) so commercial promo and intro ads are suppressed.

---

## ⚡ Quick Navigation

* [Prerequisites](#-prerequisites)
* [Step-by-Step Guide](#-step-by-step-guide)
  * [1. Network Pairing](#step-1-network-pairing)
  * [2. Get Host IP](#step-2-get-host-ip)
  * [3. Configure STB DNS via USB Bug](#step-3-configure-stb-dns-via-usb-bug)
  * [4. Isolate Network & Temporarily Disable Firewall](#step-4-isolate-network--temporarily-disable-windows-firewall)
  * [5. Run Docker](#step-5-run-docker)
  * [6. Setup Technitium DNS](#step-6-setup-technitium-dns)
  * [7. Deploy TLS Containers](#step-7-deploy-tls-containers)
  * [8. Launch Proxy Listener (Model Specific)](#step-8-launch-proxy-listener)
  * [9. Initialize Git Bash & Health Check](#step-9-initialize-git-bash--health-check)
  * [10. Execute Stage 1](#step-10-execute-stage-1)
  * [11. Verify ADB Connection](#step-11-verify-adb-connection)
  * [12. Teardown & Reset](#step-12-teardown--reset)
* [How to Install Apps via ADB](#-how-to-install-apps-via-adb)
* [Advanced CLI & JHS Options](#-advanced-cli-options)
* [Get Hands-On Help / Mail-In Setup](#-get-hands-on-help--mail-in-setup)
* [Credits & Acknowledgments](#-credits--acknowledgments)

---

## 🛠 Prerequisites

Install these utilities on your Windows system before starting:

| Tool | Purpose | Download | 
| ----- | ----- | ----- | 
| **Docker Desktop** | Hosts local GenieACS backend services | [Official Download](https://docs.docker.com/desktop/setup/install/windows-install/) | 
| **Python 3** | Runs proxy and diagnostic scripts (`Add to PATH` checked) | [python.org](https://www.python.org/downloads/) | 
| **Technitium DNS** | Overrides local domain resolution | [technitium.com](https://technitium.com/dns/) | 
| **Git for Windows** | Bash terminal environment | [gitforwindows.org](https://gitforwindows.org/) | 

*(Note: Android platform-tools ADB binaries are already bundled inside this folder).*

---

## 🚀 Step-by-Step Guide

### Step 1: Network Pairing

* Connect your Windows PC to your primary home Wi-Fi.
* Connect your Jio STB to the same router (via standard Wi-Fi or Ethernet).
* **Do not use Guest Wi-Fi** (guest networks isolate connected devices from talking to each other).

### Step 2: Get Host IP

Open Command Prompt (`Win + R` $\rightarrow$ `cmd`) and type:

```cmd
ipconfig
```

Find **Wireless LAN adapter Wi-Fi** (or Ethernet if wired) and copy your **IPv4 Address** (example: `192.168.1.20`).

### Step 3: Configure STB DNS via USB Bug

> [!NOTE]
> An empty USB pendrive is required strictly to access the hidden stock Android settings menu.

1. Plug any USB thumb drive into the Jio STB.
2. Turn on the STB $\rightarrow$ Launch **My Music** $\rightarrow$ **Settings** $\rightarrow$ Select **Eject USB**.
3. Tap **Internal Storage** $\rightarrow$ Open **Apps** $\rightarrow$ Select the stock **Settings** app (gear icon).
4. Navigate to **Network** $\rightarrow$ Select your Wi-Fi network $\rightarrow$ Open **Advanced IP Settings**.
5. Change IP Settings from **DHCP** to **Static**.
6. Keep IP Address, Gateway, Subnet, and DNS 2 unchanged.
7. Set **DNS 1** to your Windows PC's IPv4 Address from Step 2.
8. Save and ensure the STB reconnects to your Wi-Fi.

> [!WARNING]
> If the Gateway or IP fields auto-clear upon selecting Static, switch back to DHCP, note the default values, switch to Static, and re-enter them manually before saving.

### Step 4: Isolate Network & Temporarily Disable Windows Firewall

1. **Unplug Incoming Internet:**
   Unplug the **WAN / incoming fiber cable** from your router (keep the router powered on).
   * Both devices must communicate over the local network without active internet access.

2. **Temporarily Disable Windows Defender Firewall:**
   > [!IMPORTANT]
   > Windows Firewall frequently blocks incoming connections from the STB on port **53** (DNS) and port **8443/9443** (TLS proxy), causing the exploit to silently fail. You must temporarily turn it off:
   >
   > 1. Press `Win + R`, type `firewall.cpl`, and press **Enter**.
   > 2. Click **"Turn Windows Defender Firewall on or off"** on the left menu.
   > 3. Select **"Turn off Windows Defender Firewall (not recommended)"** for both *Private* and *Public* network settings.
   > 4. Click **OK**. *(You will re-enable it in Step 12 once finished.)*

### Step 5: Run Docker

Launch **Docker Desktop** from your Start Menu and wait until the engine status switches to running.

### Step 6: Setup Technitium DNS

1. Open the Technitium console in your browser at [`http://localhost:5380`](http://localhost:5380).
2. Go to **Zones** $\rightarrow$ Click **Add Zone**:
   * **Zone Name:** `jio.com`
   * **Zone Type:** `Primary Zone`
3. Click into `jio.com` $\rightarrow$ Click **Add Record**:
   * **Name:** `acs.oss`
   * **Type:** `A`
   * **IP Address:** *Your Windows IPv4 Address from Step 2*
4. Save the record and ensure the `jio.com` zone is **Enabled**.

### Step 7: Deploy TLS Containers

1. Open File Explorer and navigate to `sideload-jiostb/tls`.
2. Click the address bar, type `cmd`, and press Enter.
3. In Command Prompt, run:

```cmd
docker compose up -d
```

### Step 8: Launch Proxy Listener

Depending on your model, pick **Option A** or **Option B**:

#### Option A: For JMSC / JMSB Boxes (Default)

In the same Command Prompt window (inside the `tls` folder):

```cmd
python -m pip install pycryptodome
python pass_front.py
```

*(Leave this window running. `pass_front.py` includes a precomputed token fallback, so it works even if pycryptodome is absent).*

#### Option B: For JHS Boxes (JHSC200 / JioOS 2.0)

JHS boxes enforce strict system CA certificate validation and reject the default certificate chain. Instead of `python pass_front.py`:

1. Open **Git Bash** in the main `sideload-jiostb` folder.
2. Run the automated eMudhra certificate minting script:
   ```bash
   ./jhs/run_acs.sh
   ```

*(This automatically recovers the leaked eMudhra intermediate key, mints a certificate trusted by the STB's system store, and launches the proxy on ports 8443 and 9443. Leave this terminal open).*

### Step 9: Initialize Git Bash & Health Check

1. Open the main `sideload-jiostb` folder.
2. Right-click blank space $\rightarrow$ **Show more options** $\rightarrow$ **Open Git Bash here**.
3. *(Optional but highly recommended)* Prove your PC setup works before touching the TV:
   ```bash
   python doctor.py --quick
   python doctor.py --simulate
   ```
   `--simulate` sends a synthetic Inform through the proxy and GenieACS, verifying the entire chain is 100% operational.

### Step 10: Execute Stage 1

Ensure Docker, Technitium, and your proxy listener (from Step 8) are active, then run:

```bash
./stage1.sh --list-devices
```

Select your STB when prompted. To run only the required payload without stripping extras, you can alternatively use:

```bash
./stage1.sh --tasks-only
```

> [!IMPORTANT]
> **Cold Power-Cycle Is Mandatory (Unplug Wall Power):**
> The Jio STB only contacts the ACS server during **boot**. Its periodic background check-in takes hours, and remote wake is impossible because `NATDetected=True` closes incoming port 7547 on the STB.
>
> 1. Unplug the STB power adapter from the wall (do not just put it in standby with the remote).
> 2. Wait 5 seconds $\rightarrow$ Plug it back in.
> 3. Allow it to boot up completely.

> [!TIP]
> **Stuck at any point during Steps 5 to 10?**
> If you find the technical setup too cumbersome, **Vishal Beniwal** can do the entire process for you—just cover shipping + whatever you feel like paying. Reach out via Instagram at [**@soloxsurfer**](https://instagram.com/soloxsurfer) or Reddit at [**u/ilikechocopies**](https://www.reddit.com/user/ilikechocopies).

### Step 11: Verify ADB Connection

> [!NOTE]
> **"Allow USB Debugging?" Dialog on TV:**
> No prompt will appear on your TV until the STB boots and applies the CWMP task. Once connected, your TV screen will display an RSA key prompt.
> Check **"Always allow from this computer"** and select **OK**.
>
> If running `adb connect` initially shows `failed to authenticate` or `unauthorized`, that is completely normal before you click OK on the TV. Simply run `adb connect <STB_IP>:5555` again after approving.

In Git Bash, confirm your connection:

```bash
adb devices
```

Your device should now be listed with the status **`device`**.

### Step 12: Teardown & Reset

Once ADB is confirmed and your setup is complete:

1. Stop `pass_front.py` / `run_acs.sh` by pressing `Ctrl + C` in its window (or run `./stage1.sh --stop`).
2. In Git Bash, stop Docker containers:
   ```bash
   docker compose down
   ```
3. Reconnect your router's incoming WAN/Internet cable.
4. **Turn Windows Defender Firewall back on:** Press `Win + R` $\rightarrow$ `firewall.cpl` $\rightarrow$ Turn Windows Defender Firewall back on.

---

## 📲 How to Install Apps via ADB

Since the built-in package installer UI is disabled on the STB, install any Android TV APK from your PC:

1. Connect your PC to the STB over ADB (if not already connected):
   ```bash
   adb connect <STB_IP_ADDRESS>:5555
   ```
2. Sideload your preferred application:
   ```bash
   adb install "C:\path\to\your_app.apk"
   ```
3. The app will immediately appear inside **Monet Launcher**.

---

## 🧰 Advanced CLI Options

| Command | Purpose |
|---|---|
| `./stage1.sh --doctor` | Run full diagnostic checklist of ports, NBI, and DNS |
| `./stage1.sh --simulate` | Test synthetic CWMP session through TLS front & GenieACS |
| `./stage1.sh --watch` | Real-time watcher polling for STB Inform and port 5555 |
| `./stage1.sh --tasks` | Inspect all pending TR-069 tasks queued for your STB |
| `./stage1.sh --clear-tasks` | Clear duplicate or stale tasks from GenieACS queue |
| `./stage1.sh --stop` | Stop background `pass_front.py` process |
| `./stage1.sh --yes-disable-tr069` | Legacy no-op flag (TR-069 & bloat deletion/fallback-disable now runs by default) |
| `./jhs/run_acs.sh` | Mint eMudhra-forged TLS cert & start proxy for JHS boxes |
| `./jhs/jhs_stage1.sh --status` | Display persisted Iwedia ADB properties and launcher state on JHS |
| `./jhs/jhs_stage1.sh --post-setup` | Sideload Monet/Shevery, delete/disable OTA & TR-069 packages, and grant Shevery permissions on JHS |
| `./jhs/jhs_stage1.sh --clu-probe` | Queue native root command execution probe via `tr069native` |
| `./jhs/jhs_stage1.sh --clu-read` | Read back executed command output from `tr069native` root probe |

---

## 📬 Get Hands-On Help / Mail-In Setup

If you find this guide too complicated or don't have the time to configure Docker, DNS records, and TLS certificates, **Vishal Beniwal** can handle the entire setup for you:

* **Mail-In Modification:** Send your box over, and Vishal will unlock network ADB, configure Monet Launcher, and set everything up.
* **Pricing:** Pay whatever your heart desires + return shipping charges.
* **Contact:** Reach out to **Vishal Beniwal** on Instagram at [**@soloxsurfer**](https://instagram.com/soloxsurfer) or Reddit at [**u/ilikechocopies**](https://www.reddit.com/user/ilikechocopies).

---

## ⚠️ Important Disclaimers

* **Scope:** Stage 1 performs modifications such as enabling ADB, queueing downgrade flags, installing Monet Launcher and Shevery (with full permissions), and deleting (or disabling if protected) TR-069, OTA update, command receiver, background scheduler, and ad service packages.
* **Root/Bootloader:** This guide deliberately excludes `unlock.sh` and `pull_boot.sh`. Do not run Stage 2 utilities unless you know what you are doing.
* **Liability:** Use only on hardware you own or have explicit authorization to test.

---

## 🌟 Credits & Acknowledgments

* **Documentation, Windows 11 Streamlining & Maintenance:**  
  Maintained by **Vishal Beniwal** (Instagram: [**@soloxsurfer**](https://instagram.com/soloxsurfer) / Reddit: [**u/ilikechocopies**](https://www.reddit.com/user/ilikechocopies))  
  *The guide and any personal support are completely free. If you need Vishal to do the process for you, pay whatever your heart desires + shipping!*

* **Original Vulnerability Research & Tooling:**  
  Massive respect to **Bihaan Sen**, **ak_0o7**, and **Otus9051** for the reverse-engineering and original [Housekeeping-PoC](https://github.com/JFC-Group/Housekeeping-PoC/) repository. Please star and support their project!

* **JHS Series & eMudhra Chain Research:**  
  Huge thanks to **Pavit Chhabra** ([@mesosan16](https://twitter.com/mesosan16) on Twitter) for helping add JHS series support.
