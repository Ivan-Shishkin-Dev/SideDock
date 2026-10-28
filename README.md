# SideDock

A second dock for macOS that lives on the left or right edge of your screen. It sits alongside the system Dock and doesn't replace it.

## Features

- **Apps.** Pinned apps plus every running app, with running indicators.
- **Folder stacks.** Pin Downloads, Home or any folder. Click it for a grid of its contents with Quick Look thumbnails. Browse into subfolders and drag files out.
- **Notification badges.** Mirrors the red badges from the system Dock. Optional; needs Accessibility access.
- **Drag and drop.** Drag icons to reorder them. Drop apps, folders or files on the dock to keep them.
- **Auto-hide.** Slides in when the pointer touches the screen edge.
- **Settings.** ⌘-click the dock, or use the menu bar icon. Covers edge, position, icon size, magnification, background style, corner radius, auto-hide timing, folder defaults, launch at login and more.

## Build

Requires macOS 14+ and Xcode (Swift 5.10+).

```bash
./build.sh
open SideDock.app
```

To keep it around, move `SideDock.app` to `/Applications` and turn on **Launch at login** in Settings.

## Usage

| Action | How |
| --- | --- |
| Open an app or file | Click |
| Open a folder stack | Click a folder |
| Options (keep, remove, quit, sort) | Right-click |
| Reorder | Drag an icon |
| Add to dock | Drop an app, folder or file on it |
| Settings | ⌘-click the dock |
