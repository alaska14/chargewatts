<div align="center">
  <img src="docs/assets/ChargeWatts-Cover.png" alt="ChargeWatts Banner" width="100%">
  <br><br>
  <h1>ChargeWatts</h1>
  <p><strong>1:1 pixel-perfect Apple battery replacement that shows live wattage on hover & plug-in.</strong></p>

  [![Support on Gumroad](https://img.shields.io/badge/Support_on_Gumroad-%242.99+-102039?style=for-the-badge&logo=gumroad&logoColor=white)](https://monolab-apps.gumroad.com/l/chargewatts)
  [![Free Release](https://img.shields.io/badge/Download-Free_DMG_(v1.2.0)-success?style=for-the-badge&logo=apple&logoColor=white)](https://github.com/alaska14/chargewatts/releases/latest)
  [![AlternativeTo](https://img.shields.io/badge/AlternativeTo-Listed-blue?style=for-the-badge)](https://alternativeto.net/software/chargewatts/)
  [![Homebrew](https://img.shields.io/badge/Homebrew-v1.2.0-orange?style=for-the-badge&logo=homebrew&logoColor=white)](#-installation)
</div>

<br>

macOS's default battery icon hides the most critical information: **How fast is your Mac actually charging?** Is your desk dock, power bank, or monitor trickle-charging at 15W, or fast-charging at 67W, 96W, or 140W?

**ChargeWatts** is a 1:1 pixel-perfect drop-in replacement for the native macOS battery icon that reveals real-time charging speed with **0.0% CPU overhead**.

---

## ✨ Features

- 🎯 **1:1 Stock Apple Visual Replication:** Evaluated directly against the native macOS Golden Gate battery cutout (MSE 0.050). Looks completely indistinguishable from the stock battery.
- 🖱️ **Live Mouse Hover Interaction:** Hover your mouse over the battery anytime to instantly reveal live hardware wattage (e.g. `67W` on AC, or active hardware power draw on battery), reverting smoothly when you move away.
- ⚡ **Plug-In Pulse:** Momentarily pulses your active charging wattage right inside the battery pill for 2.0s when connecting a charger.
- 📊 **De-Cluttered Monochrome Menu:** Minimalist, distraction-free right-click menu with zero colored clutter. Inspect authentic hardware battery health, Coulomb cycle count, and time estimates cleanly.
- 🍃 **0.0% CPU Overhead:** Uses pure native IOKit kernel callbacks (`IOPSNotificationCreateRunLoopSource`). Zero polling loops.

---

## 📦 Installation

### Option 1: Homebrew (Recommended)
```bash
brew tap alaska14/tap
brew install --cask chargewatts
```

### Option 2: Download Signed DMG
Download the signed DMG from **[GitHub Releases](https://github.com/alaska14/chargewatts/releases/latest)**.

### Pro-Tip: Hide the Default macOS Battery Icon
Open **System Settings** → **Control Center** → **Battery** → Set to **"Don't Show in Menu Bar"**. ChargeWatts takes over seamlessly in the exact same spot!

---

Crafted with care by **MonoLab** ([monolab-apps.gumroad.com](https://monolab-apps.gumroad.com)).
