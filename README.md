# 🎵 Lirik — Touch Bar Synced Lyrics for macOS

**Lirik** is a macOS Touch Bar widget that displays real-time synchronized lyrics for whatever song is playing in **Spotify** or **Apple Music**. Built as a native plugin for **Pock**.

![Lirik Touch Bar Demo](assets/demo.jpg)

---

## ⚡ Features

- **Real-Time Karaoke Lyrics**: Synchronized line-by-line lyrics powered by LRCLIB API.
- **Pock Widget Native**: Integrates into your Touch Bar via [Pock](https://pock.app).
- **Customizable Preferences**:
  - **Display Mode**: Choose between **2-Line Karaoke** or **1-Line Compact** mode.
  - **Lyric Text Size**: Small (10pt), Medium (11pt), or Large (12pt).
  - **Music Player Source**: Auto-detect, Spotify Only, or Apple Music Only.
  - **Pause Indicator**: Toggle `⏸` icon display when paused.
- **Zero Backend**: 100% client-side, lightweight, and fast.

---

## 📥 How to Install

### Prerequisites

1. Ensure you have **Pock** installed on your Mac:
   👉 **Download Pock**: [https://pock.app](https://pock.app)

---

### Step-by-Step Installation Guide

#### 1. Download the Widget
- Download the latest **`lirik.pock.zip`** from [GitHub Releases](https://github.com/RidhaAF/lirik/releases).

#### 2. Install into Pock
- Unzip `lirik.pock.zip` to get `lirik.pock`.
- **Double-click `lirik.pock`** to open and install it automatically in Pock.
- *(Alternative)*: Move `lirik.pock` directly into your Widgets folder:
  ```bash
  ~/Library/Application Support/Pock/Widgets/
  ```

#### 3. Enable Lirik on your Touch Bar
1. Click the **Pock** icon in your macOS menu bar.
2. Select **Preferences** $\rightarrow$ **Widgets Manager**.
3. Ensure **Lirik** is enabled (green indicator dot).
4. Click **Customize Pock** to drag **Lirik** onto your physical Touch Bar layout.

---

### 🔑 First-Time Permission Setup (macOS 15+)

When playing music for the first time:

1. Open **Spotify** or **Apple Music** and start playing a track.
2. macOS will present a system authorization popup:
   > **"Pock.app" wants access to control "Spotify.app"** $\rightarrow$ Click **Allow**.
3. If the popup does not appear or permission was previously denied:
   - Go to **System Settings** $\rightarrow$ **Privacy & Security** $\rightarrow$ **Automation**.
   - Find **Pock** and toggle **Spotify** (and **Music**) to **ON**.
   - Or run this command in Terminal to reset prompts:
     ```bash
     tccutil reset AppleEvents
     ```

---

## ⚙️ Customizing Preferences

You can customize Lirik's layout and font size directly inside Pock:

1. Open **Pock Preferences** $\rightarrow$ **Widgets Manager**.
2. Select **Lirik** in the left sidebar.
3. Configure your preferred settings:
   - **Display Mode**: Select *2-Line Karaoke* or *1-Line Compact*.
   - **Text Size**: Choose *Small*, *Medium*, or *Large*.
   - **Player Source**: Select *Auto-detect*, *Spotify*, or *Apple Music*.

---

## 🛠 Building from Source

```bash
# Clone the repository
git clone https://github.com/RidhaAF/lirik.git
cd lirik

# Install dependencies via CocoaPods
pod install

# Build release bundle
xcodebuild -workspace lirik.xcworkspace -scheme lirik -configuration Release build ENABLE_USER_SCRIPT_SANDBOXING=NO
```

The output bundle `lirik.pock` will be located in `dist/lirik.pock`.

---

## 📄 License

[MIT License](LICENSE) © Ridha Ahmad Firdaus
