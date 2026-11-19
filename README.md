# PortKeeper

PortKeeper is a macOS menu bar app that shows which programs are listening for local TCP connections and lets you stop a development server you started. It stays on your Mac. There is no account and no extra package to install.

## Download

You can install and use PortKeeper without building it. Download [PortKeeper-0.1.6.zip](https://github.com/etc11/PortKeeper/releases/tag/v0.1.6). Unzip it and move PortKeeper.app to Applications. You need macOS 14 or newer.

## What you need to build

macOS 14 or newer, and Xcode or the Swift command-line tools.

## Build

```sh
swift build -c release
```

## Run

```sh
swift run -c release
```

PortKeeper appears as a network icon in the menu bar and does not add a Dock icon. Click the icon to open the panel.

## How to use it

The panel groups listening sockets by process and shows the ports, command, PID, address, executable path, and resident memory. It refreshes when you open it, about every two seconds while the panel is open, and about every ten seconds in the background. The refresh button updates the list immediately.

Search matches the process, port, PID, or path. The Show menu has three views. **My processes**, the default, lists unprotected processes owned by you. **Favorites** lists listeners on ports you saved. **All processes** includes every listener PortKeeper can see. Favorites sort first. Settings is where you save favorite ports, separated by commas, and where you turn **Launch at login** on or off. That login setting registers an installed copy of the app. A `swift run` process does not have the same app-bundle identity.

**Stop** asks the process to quit. If it is still listed, **Force Kill** is available after you confirm. Stopping a process closes every listening port it owns. Child processes are not stopped separately, and a supervisor may start the server again.

PortKeeper will not stop PID 1, itself, a process owned by someone else, a macOS system executable, a process signed by Apple, or a process whose identity or signature cannot be checked. Those rows show a shield instead of Stop.

From a process you can open `http://localhost` on one of its ports, or copy the port, PID, or executable path. Opening that address does not mean the program is a website.

Only listeners visible to your account appear. Memory is resident memory for the whole process and can differ from Activity Monitor. Discovery stays on this Mac and does not look up host names.
