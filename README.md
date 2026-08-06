# 🎵 Lirik — Touch Bar Synced Lyrics for macOS (v1.2)

**Lirik** is a macOS Touch Bar widget that displays real-time synchronized lyrics for whatever song is playing in **Spotify** or **Apple Music**. Built as a native plugin for **Pock**.

![Lirik Touch Bar Demo](assets/demo.jpg)

---

## ⚡ Features

- **Real-Time Karaoke Lyrics**: Synchronized line-by-line lyrics powered by LRCLIB API with binary-search sync engine.
- **Smart Track Sanitization**: Automatically cleans track titles (strips `(Remastered)`, `[feat.]`, `- Live`) for **30%+ higher lyric match rates**.
- **Tap-to-Copy Touch Bar Gesture**: Tap any active lyric on your Touch Bar to instantly copy the text to your macOS clipboard.
- **Auto-Advancing Plain-Text Fallback**: Progressively steps through static lyrics if time-synced LRC lyrics are unavailable.
- **Customizable Preferences**:
  - **Display Mode**: Choose between **2-Line Karaoke** or **1-Line Compact** mode.
  - **Text Alignment**: **Left Aligned** or **Center Aligned**.
  - **Lyric Text Size**: Small (10pt), Medium (11pt), or Large (12pt).
  - **8 Highlight Color Themes**: White, Gold, Cyan, Green, Purple, Pink, Orange, and Red.
  - **Marquee Scrolling Toggle**: Enable/disable smooth horizontal marquee scrolling for long lyric lines.
  - **Music Player Source**: Auto-detect, Spotify Only, or Apple Music Only.
  - **Pause Indicator**: Toggle `⏸` icon display when paused.
  - **Clear Cache Button**: Purge local disk cache with one click.
- **Zero Backend**: 100% client-side, lightweight, and fast.

---

## 📥 How to Install

### Prerequisites

1. Ensure you have **Pock** installed on your Mac:
   👉 **Download Pock**: [https://pock.app](https://pock.app)

---

### Step-by-Step Installation Guide

#### 1. Download the Widget
- Download the latest **`lirik.zip`** from [GitHub Releases](https://github.com/RidhaAF/lirik/releases).

#### 2. Clear macOS Quarantine (Crucial)
To prevent macOS Gatekeeper from showing **"lirik.pock is damaged and can't be opened"** or Pock's **`error.invalid-bundle`**:

![lirik.pock is damaged error](assets/damaged-error.png)

Run this single command in **Terminal** before opening the widget:
```bash
xattr -cr ~/Downloads/lirik.pock
```

#### 3. Install into Pock
- **Double-click `lirik.pock`** to install automatically in Pock.
- *(Alternative Manual Copy)*: Move `lirik.pock` directly into your Widgets folder:
  ```bash
  cp -R ~/Downloads/lirik.pock ~/Library/Application\ Support/Pock/Widgets/
  ```

#### 4. Enable Lirik on your Touch Bar
1. Click the **Pock** icon in your macOS menu bar.
2. Select **Manage widgets...** (or **Preferences...**).
3. Ensure **Lirik** is enabled (green indicator dot).
4. Click **Customize Pock...** to drag **Lirik** onto your physical Touch Bar layout.

---

### 🔑 First-Time Permission Setup (macOS 15+)

When playing music for the first time:

1. Open **Spotify** or **Apple Music** and start playing a track.
2. macOS will present a system authorization popup:

   ![Pock Automation Permission Prompt](assets/permission-prompt.png)

   Click **Allow**.
3. If the popup does not appear or permission was previously denied:
   - Go to **System Settings** $\rightarrow$ **Privacy & Security** $\rightarrow$ **Automation**.
   - Find **Pock** and toggle **Spotify** (and **Music**) to **ON**.
   - Or run this command in **Terminal** to reset system permission prompts, then quit and reopen **Pock** and **Spotify** / **Apple Music**:
     ```bash
     tccutil reset AppleEvents
     ```

---

## ⚙️ Customizing Preferences

You can customize Lirik's layout, colors, alignment, and font size directly inside Pock:

1. Click the **Pock** icon in your macOS menu bar $\rightarrow$ **Manage widgets...**
2. Select **Lirik** in the left sidebar.
3. Configure your preferred settings:
   - **Display Mode**: Select *2-Line Karaoke* or *1-Line Compact*.
   - **Text Alignment**: Select *Left Aligned* or *Center Aligned*.
   - **Text Size**: Choose *Small*, *Medium*, or *Large*.
   - **Highlight Color**: Choose from 8 themes (*White, Gold, Cyan, Green, Purple, Pink, Orange, Red*).
   - **Marquee Scrolling**: Toggle smooth scrolling for long lines.
   - **Player Source**: Select *Auto-detect*, *Spotify*, or *Apple Music*.
   - **Clear Cache**: One-click button to purge local lyrics cache.

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
