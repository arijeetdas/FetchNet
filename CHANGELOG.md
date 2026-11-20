# 📜 Changelog

All notable changes to FetchNet are listed here, newest first.
Versions follow `version: <name>+<build>` in `pubspec.yaml`.

---

## 🚧 Unreleased

<!-- Notes for the next version go here, in the same style as the releases
     below (### ✨ Highlights, ### 🆕 New with #### groups, ### 🛠️ Improved,
     ### 🐞 Fixed, ### ⚠️ Notes, ### 🧰 Under the hood; a "#### 🤖 Android"
     group is shown on Android only). A "> One-line summary." under this
     heading becomes the summary. When a commit bumps `version:` in
     pubspec.yaml, the pre-commit hook turns this heading into
     "## 🚀 vX.Y.Z — date" with "> **Build N**"; with no notes written, it
     uses the commit subjects since the last version bump. -->

---

## 🚀 v1.2.6 — 2026-11-20

> **Build 6** · A roomier FetchNet on large screens, and Windows closes properly.

### ✨ Highlights

- 🖥️ **Made for large screens**: on desktops, laptops and tablets in landscape, FetchNet uses the room it has. Phones look exactly as before.

### 🛠️ Improved

#### 🏠 Home

- 🧭 On wide windows, Home has **two columns** that fill the window, whatever its size: the link box and results on the left, downloads in progress and **Popular sites** on the right.
- 🕘 A **Recent downloads** panel shows your latest downloads (as many as fit); tap one to open History.
- 💡 **How it works** walks through the three steps under the link box, with pictures that grow on bigger screens.
- 🎬 Video results show the **picture and details next to the qualities** when there's room.
- 🟪 The four **What FetchNet saves** cards are now all the **same size**, whatever their text, and no longer act like buttons.

#### 🖥️ Large screens

- ⚙️ **Settings** shows its sections in two columns.
- 🕘 **History** lists downloads in a grid, with the search and the filters on one row.
- 📥 **Downloads** shows more saved files side by side.
- 📐 Every page lines up with its title.

### 🐞 Fixed

#### 🪟 Windows

- 🧹 Closing FetchNet now really ends it. Before, it could stay in the background without a window, using a CPU core and keeping its files locked, so installing an update failed.
- 🔢 After an in-app update, **Installed apps** shows the new version number.

---

## 🚀 v1.2.5 — 2026-11-19

> **Build 5** · A redesigned Home, and updates that download and install right inside FetchNet.

### ✨ Highlights

- 🏠 **A new Home**: a smarter link box, a status deck for everything FetchNet needs to tell you, live progress for each engine, and results as cards with full-screen previews.
- ⬇️ **In-app updates**: a new updater shows what's new in the latest version, downloads it, and installs it without leaving FetchNet.
- 🔄 **Relaunch to update** on Windows, like Chrome: the new version is put in place while FetchNet runs.

### 🆕 New

#### 🏠 Home

- 🔗 **Link box**: while empty it cycles through examples of what FetchNet can read; with a link in, it shows which site it's from. It lights up while you type, and a gradient runs around it while the link is read.
- 📋 **Status deck**: a new FetchNet version, yt-dlp and gallery-dl starting, installing, updating or failing, the download folder, and add-ons to install, as cards that update in place.
- ⏳ **Reading the link** shows a lane per engine (yt-dlp reading the formats, gallery-dl looking for the post's files) and how long it has been going.
- 🎚️ **Results as cards**: video qualities, audio formats and YouTube thumbnail sizes, two or three across, with the selected one highlighted.
- 🖼️ **Full-screen previews** for a post's files: swipe between them, pinch or double-tap to zoom, and pick files while you look at them. A small fanned stack of the post's pictures sits on top.
- 📥 The downloads running right now appear live on Home, with a shortcut to Downloads.
- ✨ Smooth entrance and press animations throughout, following Settings → **Show animations** and the system's "remove animations" switch.

#### ⬇️ Updater

- 🪟 A new **updater popup** opens from the **Update** button on Home and in Settings: the new version's changes, then **Download update** with progress, size and speed.
- 🔎 **Check for Updates** (in *FetchNet for your platform*) now checks right away (**Checking for Updates…**), then opens the updater, or tells you you're already on the latest version.
- 📰 **What's new** shows the latest release's notes, loaded from the website. When you're not on the latest version, it opens the updater instead.
- 🧪 On a build newer than the latest public one, **Check for Updates** and **What's new** say so: *"This is an unreleased/modified build"*.
- 🌐 If an update can't be downloaded or installed in the app, **Open the update page** takes you to the website, as before.

#### 🤖 Android

- 📦 The update is handed to Android's installer. FetchNet downloads the same kind of APK you have installed, so Android always accepts it, and asks once for permission to install apps.

#### 🪟 Windows

- 🔄 The new version is unzipped and put in place while FetchNet runs; **Relaunch** finishes the update. If the new version can't start, FetchNet goes back to the previous one by itself.
- 👤 FetchNet now installs for your user account (no administrator prompt for updates). Installs in Program Files update through the installer instead.

### 🛠️ Improved

- 🗂️ **No more folder per post**: several files of a post go straight into the **Images**, **Audio** and **Video** folders, numbered after the name you give (`Beach day 1.jpg`, `Beach day 2.jpg`, …). A single file keeps its name as before.

### 🧰 Under the hood

- 🌐 The website publishes `/update-manifest.json` (latest version, download links and notes per platform) and `/changelog.json`; `/releases.json` stays for older versions.
- 📦 The app no longer ships any release notes: they come from the website.

---

## 🚀 v1.2.0 — 2026-11-17

> **Build 4** · Images and whole posts, powered by a second self-updating engine (gallery-dl), tidy Images, Audio and Video folders, and downloads that retry by themselves.

### ✨ Highlights

- 🖼️ **Images and posts**: paste a link to a post or gallery (Instagram, X, Reddit, Pinterest, Tumblr, Pixiv and many more) and FetchNet lists every image, video and audio file in it. Pick some or all, and they're sorted into the new Images, Audio and Video folders.
- 🌐 **Browser Mode finds images**: a new **Images** section in *Media found* lists the large pictures on the page.
- 🔁 **Downloads retry by themselves** when a site refuses them for a moment.
- 🗂️ **Tidy folders**: `Download/FetchNet` now has **Images**, **Audio** and **Video** folders, and every download goes into the one for its type.
- 📰 A one-time **What's new** popup after every update.

### 🆕 New

#### 🖼️ Images & posts

- 🧩 **gallery-dl**, the engine for images and galleries, installs in the background and keeps itself up to date like yt-dlp. Its version and a **Check for updates** button are on the new **Engines** screen.
- 🗂️ A **Post** view lists every file in a post: type filters (**Images**, **Videos**, **Audio**) with counts, previews, and a badge on each file. Tap files to pick them, or **Select all**.
- 🔀 When a post has a video that yt-dlp can also read, switch between **Post** (every file) and **Video** (all of yt-dlp's qualities) on the same result.
- 📁 A single file is saved like any download; several files of one type share a folder named after the post.
- 🧭 Links to a whole profile or board list their posts first; tap one to open it.

#### 🌍 Built-in browser

- 🖼️ **Images** in *Media found*: large pictures on the page (small icons and avatars are left out), with previews. Download one, several, or all of them.
- 🔗 **Grab this page** on a post opens the Post view.

#### 🗂️ Images, Audio and Video folders

- 📁 `Download/FetchNet` (`Downloads/FetchNet` on computers) now holds three folders: **Images**, **Audio** and **Video**. Videos, songs, pictures and thumbnails each land in the one for their type.
- 🧩 A post's files are sorted the same way: its pictures go to **Images**, its videos to **Video** and its audio to **Audio**, each in a folder named after the post when there's more than one.
- 🗄️ Files you downloaded before stay where they are, and still show in Downloads and History.

#### ⚙️ Engines screen

- ⚙️ Settings → **Engines** opens a screen for yt-dlp (video & audio) and gallery-dl (images & posts): each with its version, a status, how it runs on your device, when it last checked for updates, its license and maintainers, a **Check for updates** button (**Retry setup** if setting it up failed), links to its source code and supported sites, and credits.
- 🎛️ The **Keep engines up to date** and **Images & posts** switches, and FFmpeg and the JavaScript runtime on computers, stay on the main Settings page. The yt-dlp link moved from About to the Engines screen.

#### 📰 What's new

- 📰 After you update to a newer version, FetchNet shows what changed in it, once, in a popup styled like *FetchNet for your platform*: the release notes scroll inside it to fit any screen, and **OK** closes it. Reinstalling the same version or a fresh install doesn't show it.
- 🔖 It lists the installed version's changes only, never earlier versions, and Settings → About → **What's new** shows the same notes again.

### 🛠️ Improved

- 🔁 Downloads that YouTube refuses for a moment (a bot check, a 403, a quality that briefly disappears) now **retry by themselves**, up to two times.
- 🔑 When a site refuses an anonymous download or wants a sign-in (age-restricted, members-only, a bot check), FetchNet tries again with the sign-in from its built-in browser, for posts and images as well as videos.
- 👋 The **Welcome** screen, the **Disclaimer** and **About FetchNet** now cover images and posts and name both engines, yt-dlp and gallery-dl. Settings → About links to gallery-dl too.

### 🐞 Fixed

- 🖼️ **Instagram posts of pictures** (or pictures and videos) no longer fail with a misleading "no video" error. When a site only shows a post to signed-in visitors, FetchNet now says so, retries with your Browser Mode sign-in, and points to *Media found* as a quick way to save what the page shows.
- ⏳ While a link is read, Home and the YouTube download popup now say *"Looking up the available formats. This can take a few seconds."*
- 💬 Error hints no longer point you the wrong way: a signed-in YouTube user is never asked to sign in, YouTube links are never sent to Browser Mode, and network errors are no longer mistaken for age-restricted videos.

### 🧰 Under the hood

- 🧩 gallery-dl runs on the Python already built into the Android app; computers download the official standalone gallery-dl, checked against its published checksums.
- 📝 CHANGELOG.md is now the single source of release notes: a pre-commit hook files these notes when the version is bumped and regenerates the app's popup data and the website's release notes.

---

## 🎬 v1.1.1 — 2026-11-07

> **Build 3** · YouTube in FetchNet, rebuilt: its own ad-free player, new tabs, channels and posts, smarter search, plus a media notification, album covers for music and app shortcuts on Android.

### ✨ Highlights

- ▶️ **A real video player**: FetchNet now plays YouTube videos itself, straight from the video files, so **no ads**. Double-tap to skip, quality, speed, loop, lock, full screen and more.
- 🧭 **New YouTube tabs**: **Home**, **Trending**, **Music** and **Channels**, with the same navigation bar and side rail as the rest of the app.
- 📺 **Channels and posts**: the latest videos and community posts from the channels you follow, plus a page for every channel with **Subscribe**.
- 🎵 **Album covers for music**: songs downloaded from YouTube Music get their square album cover built into the file.
- 🔔 **Media notification** (Android): control playback from the notification, lock screen, headphones or Bluetooth.

### 🆕 New

#### ▶️ YouTube player

- 🚫 **Ad-free playback**: yt-dlp finds the video's own files and FetchNet plays them directly.
- 👆 **Double-tap** the left or right side to skip back or ahead 10 seconds. Keep tapping to skip further.
- ⏯️ **Previous, play/pause and next**, plus 10-second skip buttons.
- 🎚️ **Quality** from 144p up to 4K, or **Auto** (720p on phones, 1080p on computers).
- 🐢 **Playback speed** from 0.25× to 3×, and **hold anywhere for 2×** while you press.
- 🔁 **Loop**, **Fit / Fill screen**, **lock controls** and **full screen**. On phones, turning the phone sideways goes full screen.
- 😴 **Sleep timer**: stop after 10–90 minutes or at the end of the video.
- ⌨️ **Keyboard shortcuts** on Windows, macOS and Linux: Space or K, J / L, arrow keys, F, M, 0–9, Shift+N / Shift+P, plus a volume slider.
- ⏭️ **Up next** with an **Autoplay** switch and a 5-second countdown before the next video starts.

#### 📄 Watch page

- 👤 Title, channel picture and name, subscriber count, and a **Subscribe** button.
- ⬇️ **Download** opens a popup inside the YouTube view, with the same qualities, thumbnail and tag options and file naming as Home. You no longer leave YouTube to download.
- 🎧 **Listen only** plays just the sound, keeps going in the background and uses less data.
- 🖼️ **Picture-in-picture** on Android, which also starts by itself when you leave the app mid-video. On computers, the video shrinks to a **mini player**.
- 📤 **Share**: the share sheet on Android, or copy the link on computers.
- 📝 An **expandable description** box.
- ⬇️ Back keeps the video playing in a **mini player** while you browse. Tap it to return.

#### 🧭 Browsing

- 🔥 **Trending**, with **Now**, **News**, **Sports**, **Live** and **Gaming** chips.
- 🎵 **Music**: what's new on YouTube Music.
- 📺 **Channels**: everyone you follow at a glance, with a **Videos / Posts** switch.
- 🏷️ **Channel pages** with their videos, their posts and **Subscribe / Unsubscribe**.
- 🔎 **Search suggestions** as you type and your **recent searches**. Remove one, or clear them all.
- ⬆️ Tap the tab you're already on to jump back to the top.

#### ⚙️ YouTube Settings

- 🎵 **YouTube Music → Album cover art**: audio downloaded from music.youtube.com links gets the song's square album cover built in.
- 🖼️ **Thumbnail as cover art**: audio downloaded from regular YouTube videos gets the video's thumbnail as its cover.

#### 🤖 Android

- 🔔 **Media notification** for the YouTube player: title, channel, artwork, previous / play-pause / next and a seek bar, also on the lock screen and in quick settings.
- 🎧 Playback **pauses for calls** and other apps, then picks up again after short interruptions. It also **pauses when headphones are unplugged**.
- 🚀 **App shortcuts**: long-press the FetchNet icon to jump straight to **Downloads**, **History** or **Settings**. The icons match your light or dark theme.

### 🛠️ Improved

- 🧱 **Cleaner YouTube top bar**: it sits on the app's own background, and the back button is a proper circle.
- 🔍 Search results no longer show a *"Results for …"* heading and **Home** button. Back clears the search.
- ⚡ **Videos start faster**: FetchNet skips data playback doesn't need, stops lookups for videos you've moved away from, and on Android keeps yt-dlp's cache so each video (and each download) does less work.
- ⏱️ While a video gets ready, the player counts the seconds. If YouTube doesn't answer in time, you get a **Try again** button instead of endless loading.
- 🎚️ A new **Adding cover art…** step shows in download progress.

### 🐞 Fixed

- 🎞️ **Downloads page**: the animation no longer slides down while a download is in progress.
- 🔔 **Download notification stuck at "Saving…"** (mostly with audio): it now always turns into the finished notification.
- 📊 Download progress could skip updates after a processing step. It now updates smoothly.

### ⚠️ Notes

- 🎵 Cover art works for **MP3 and M4A** and needs FFmpeg (built into the Android app; installable on Windows, macOS and Linux). If a cover can't be added, the download finishes without it.
- 🔥 YouTube has retired its own Trending page, so FetchNet's Trending is built from YouTube's News, Sports, Live, Music and Gaming pages.
- 🎬 On Android, a video pauses when you leave the app unless picture-in-picture or **Listen only** is on. You can resume it from the notification.
- 📦 The Android app is larger, because it now includes a video player.

### 🧰 Under the hood

- 📦 New dependencies: `media_kit`, `media_kit_video` and `media_kit_libs_video` (the video player).
- 🔄 The navigation bar and side rail are now shared between the main screens and YouTube.
- 🧪 New tests for stream picking, video lookups, search suggestions, posts, channel pages, cover art and overlapping fetches.

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
