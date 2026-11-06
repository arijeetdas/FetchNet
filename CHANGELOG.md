# 📜 Changelog

All notable changes to FetchNet are listed here, newest first.
Versions follow `version: <name>+<build>` in `pubspec.yaml`.

---

## 🚀 v1.1.0 — 2026-11-06

> **Build 2** · A big step up: a built-in YouTube experience, one-tap sites, smarter sign-ins, in-app update alerts and a livelier look.

### ✨ Highlights

- 📺 **YouTube, inside FetchNet**: browse your recommended feed, search, and watch videos in a clean FetchNet-styled view, then grab any video in one tap.
- 🔐 **Sign in with Google**: downloads that YouTube blocks for anonymous visitors, and age-restricted videos, now just work.
- 🧭 **Sites panel on Home**: one-tap shortcuts to YouTube, Instagram, Facebook and X, plus any yt-dlp-supported site you add.
- 🔔 **Update alerts**: FetchNet tells you when a new version is out.
- 🎞️ **Living icons**: animated page icons, including the FetchNet logo animation from our website.

### 🆕 New

#### 📺 YouTube

- 🏠 **Personal YouTube view** with your recommended feed, Shorts shelves, search and endless scrolling.
- ▶️ **Watch page** with the player up top, video details, an expandable description and **Up next**.
- ⬇️ **Grab this video** button on every watch page, plus a quick-grab icon on each feed card.
- 🔀 Opening any youtube.com link in the browser switches straight to the YouTube view, landing on that video or search.
- 🧯 **Won't play here?** Open the full YouTube page in the built-in browser.

#### ⚙️ YouTube Settings (new section in Settings)

- 🔐 **Sign in to YouTube with Google** on Google's own page. The page closes by itself once you're in and confirms with *"Sign in Successful"*.
- 👤 Your **Google profile photo, name and email** are shown and kept up to date. **Sign out** is one tap away.
- 🖼️ **Thumbnail downloads**: a new **Thumbnail** tab next to Video and Audio, offering every size the video actually has (up to 1280×720, JPG and WebP, plus vertical Shorts thumbnails).
- 🏷️ **Video tags**: see a video's tags under the Download button, with **Copy all tags**.

#### 🧭 Sites

- 🌐 A **Sites** panel on Home replaces the old Browser Mode button: YouTube, Instagram, Facebook and X are always there.
- ➕ **Add any site**: FetchNet checks it against yt-dlp, then fetches its name and icon automatically. Unsupported sites get *"Platform not supported by yt-dlp"*.
- ↕️ Reorder or remove the sites you added (long-press a site, or tap **Edit sites**).
- 🧭 A **Browser** tile opens any link without adding a site.

#### 🌍 Built-in browser

- ⋮ A new menu with **Reload**, **Desktop view** (phones and tablets) and **Pin this site**.
- 🍪 **Stays signed in** like a regular browser: sign in to a site once and FetchNet remembers it.
- 🔁 **Smarter downloads**: when a download needs a sign-in, FetchNet retries once with your saved sign-in for that site (for YouTube, only when you've signed in with Google).

#### 📥 Downloads

- 📤 **Share** any saved file: the system share sheet on Android, or copy the file itself to paste anywhere on Windows, macOS and Linux.
- 🗂️ A **redesigned ⋮ menu**: a file preview with type, quality and size, big **Open / Share / Show in folder** buttons, and **Copy link**, **Open source page**, **Fetch again** and **Delete file**.

#### 🔔 Updates

- 🔴 A **red dot on Settings** and an **Update available** banner on Home and Settings when a newer FetchNet is out. The banner stays until you're on the latest version.
- 🔗 **Check for Updates** opens the right download for your device: the recommended build for your phone's CPU on Android.
- 📡 **Offline at startup?** FetchNet tells you and offers to close, with a short countdown, and cancels it if your connection comes back.

#### 🎨 Look & feel

- 🎞️ The **FetchNet logo animation** from our website, just above the link box on Home.
- 🖼️ **Big page icons** next to the Downloads, History and Settings headings, each with its own animation: a downloading arrow, a rewinding clock and turning gears.
- 🎛️ **Show animations** switch in Settings → Appearance; when off, the icons stay still.

#### ℹ️ About

- 🐙 **FetchNet on GitHub** link in Settings → About.

### 🛠️ Improved

- 🧹 The About FetchNet popup is simpler: the yt-dlp link now lives only in Settings → About.
- 🏷️ The *Stuck?* tip on Home now points to the Sites panel.
- 🧮 Android update checks now use the app's real version number, so per-CPU (split) builds are always compared correctly.

### 🐞 Fixed

- 📋 **Duplicate download records**: re-downloading a file under the same name after deleting it no longer lists it twice. Existing duplicates are cleaned up automatically.
- 📤 **"Couldn't share this file"** on Android: sharing now uses Android's standard file sharing, and any remaining failure explains why.

### ⚠️ Notes

- 🪟 **Windows**: the built-in browser now keeps its data in FetchNet's own app folder, so sites you signed in to before this update need one more sign-in.
- 🔑 Google may occasionally refuse sign-in from in-app browsers. If that happens, try again later or sign in on a different network.

### 🧰 Under the hood

- 🧪 New tests for YouTube parsing, site support checks, update checks, animation timing and duplicate cleanup.
- 🪶 Animations are drawn from one shared clock and pause when their page is hidden or scrolled off screen, so they stay light on battery.
- 📦 New dependencies: `crypto` (YouTube request signing) and `path_parsing` (logo animation).

---

## 🎬 v1.0.0 — First release

> **Build 1** · The first public release of FetchNet.

- 🔗 Paste a link from YouTube and the thousands of other sites supported by yt-dlp.
- 🎚️ Video from 144p up to 4K (merged to MP4), or audio as MP3 (320/192/128 kbps), M4A or the original stream.
- ✏️ Choose the file name for every download, with a random-name option and an overwrite warning.
- 🌐 **Browser Mode** finds the video and audio playing on pages that can't be read directly.
- 🕘 **History** with search and filters.
- 🔄 yt-dlp updates itself daily, with a manual update button in Settings.
- 🎨 Violet-gradient design with light, dark and system themes.
- 🤖 **Android**: yt-dlp, Python, FFmpeg and QuickJS built in, share-to-FetchNet, per-download notifications (Live Updates on Android 16), files saved to `Download/FetchNet`, per-CPU and universal APKs.
