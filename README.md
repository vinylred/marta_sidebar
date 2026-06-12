# Places Sidebar — a Marta plugin

A [Marta](https://marta.sh) plugin that opens a macOS-style **source-list
sidebar** docked to the left edge of the Marta window, listing your home
folders, Finder favorites, and mounted volumes. Clicking an item navigates
Marta's **active pane** to that folder. The sidebar matches Marta's active theme
(colors and appearance) and follows the window as you move it.

![places sidebar](docs/screenshot.png)

---

## Install (for users)

> **Requirements:** macOS, [Marta](https://marta.sh) installed at
> `/Applications/Marta.app`. Works on Apple Silicon and Intel (universal build).

1. **Download** the latest `places-sidebar-*.zip` from the
   [Releases](../../releases) page and unzip it. You'll get a `places-sidebar/`
   folder.

2. **Open Marta's plugin folder.** In Marta, press `⌘⇧P`, run **Open plugin
   directory** (or open
   `~/Library/Application Support/org.yanex.marta/Plugins`).

3. **Move** the `places-sidebar/` folder into that `Plugins` directory.

4. **Clear the macOS quarantine flag.** Because the plugin ships an *unsigned*
   native library downloaded from the internet, macOS Gatekeeper quarantines it
   and Marta will refuse to load it until you clear the flag. In Terminal:

   ```sh
   xattr -dr com.apple.quarantine \
     ~/Library/Application\ Support/org.yanex.marta/Plugins/places-sidebar
   ```

   > **Why this is needed / is it safe?** macOS tags anything downloaded from
   > the web with a `com.apple.quarantine` attribute. For unsigned/un-notarized
   > binaries this blocks loading. The command above removes that tag for this
   > one folder. Only run it on software you trust — or build from source
   > yourself (see below) to avoid the quarantine entirely.

5. **Restart Marta**, press `⌘⇧P`, and run **Show Places Sidebar**.

### Build from source instead (skips the quarantine step)

If you have Xcode command-line tools (`swiftc`), you can build locally — a
binary you compile yourself is never quarantined:

```sh
git clone <this-repo>
cd marta_plugin
./build.sh install      # builds universal .so + copies into the Plugins folder
```

Then restart Marta and run **Show Places Sidebar**.

---

## Developer guide

### Layout

```
plugin.swift                      Swift: Lua bridge, themed sidebar window + table
martasidebar-Bridging-Header.h    Re-exposes Lua macros/helpers to Swift
init.lua                          Plugin declaration, theme parsing, the action
build.sh                          Universal (arm64+x86_64) swiftc build [+ install]
package.sh                        Builds and zips a release artifact
dist/places-sidebar/              Build output: init.lua + libmartasidebar.so
```

### Build / package

```sh
./build.sh             # universal .so into dist/places-sidebar/
./build.sh install     # same, then copy into Marta's Plugins folder
./package.sh 1.0.0     # build + produce release/places-sidebar-1.0.0.zip
```

### How it works

- `init.lua` registers the **Show Places Sidebar** action. On invoke it parses
  Marta's active theme file (`conf.marco` → the `*.theme` file) for colors, then
  calls the native `interop.showSidebar(nsWindow, callback, …theme…)`.
- `plugin.swift` exposes `luaopen_libmartasidebar` (the `require` entry point),
  builds the item list (home folders, Finder favorites via `LSSharedFileList`,
  `/Volumes`), and opens an `NSWindow` with an `NSTableView`. It is added as a
  **child window** of Marta's window so it docks to the left edge, follows
  moves/resizes, and closes with Marta.
- On click, Swift invokes the saved Lua callback with the path; `init.lua`
  resolves the **currently** active pane and calls
  `pane.model:load(marta.localFileSystem:get(marta.parsePath(path)))`.
- The Lua callback is invoked with `lua_pcall` (protected) so a callback error
  is reported, never a process abort.

### Notes / limitations

- Marta has no plugin registry; distribution is manual (drop the folder into the
  Plugins directory). This README's install steps reflect that.
- The plugin ships an unsigned native binary, hence the quarantine step. For a
  signed/notarized release you'd need an Apple Developer ID.
- **Finder favorites** use the deprecated `LSSharedFileList` API. If it returns
  nothing, only the home-folder + Volumes sections appear (always reliable).
- The sidebar sits just outside Marta's left edge; if Marta is flush against the
  left of the screen it may run off-screen.

## License

MIT — see [LICENSE](LICENSE).
