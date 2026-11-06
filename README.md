# Notch Agents

A tiny macOS app that turns your MacBook's camera notch into a launcher for your AI agents. Move the mouse up into the notch and a black tray drops out of it with your agents in a row. Click one to open it. Move the mouse off it and the tray shrinks right back in.

```
                 ▇▇▇▇ camera ▇▇▇▇
   ╰ [⚡ Instinct] [Muse]   [Claude] [Gemini] ╯
```

(The notch is a cutout with no screen pixels, so nothing can be drawn inside it. The tray drops down from it instead.)

- **Instinct**: opens your iMessage chat with Instinct in Messages (set its number in the config; see below)
- **Muse**: opens the Meta AI app (found by name anywhere on your Mac)
- **Claude**: opens the Claude desktop app (falls back to claude.ai)
- **Gemini**: opens the Gemini app (falls back to gemini.google.com)

There's no Dock icon, and it works on every Space and in full screen. **Right-click** (or Control-click) any icon to edit agents, reload, toggle *Open at Login*, or quit.

## Install

Requirements: macOS 13+ and the Xcode Command Line Tools (`xcode-select --install`).

```bash
git clone https://github.com/kourakis34/nest.git
cd nest
./scripts/build-app.sh --install
```

That builds `NotchAgents.app`, copies it to `/Applications`, and launches it. Then right-click an icon and choose **Open at Login** so it starts with your Mac.

**Permissions and rebuilding:** macOS ties the Accessibility and Full Disk Access permissions to the app's code signature. The build script creates a local signing identity called "NotchAgents Local Signing" in your login keychain the first time it runs, and signs every build with it. That way rebuilds keep their permissions. The first time, macOS may ask whether `codesign` can use the key; choose **Always Allow**. Because the signature is new, remove any old NotchAgents entries under both Accessibility and Full Disk Access and add the app again. The script prints these steps.

## Working / done glow

While an agent is working on a prompt, a neon outline glows around the notch: **white** for Instinct, **blue** for Muse, **orange** for Claude and **rainbow** for Gemini. If several are working at once, their colors share one rotating ring. When an agent finishes, a wide neon-green bloom pulses three times around the notch and then fades out. If the tray is open, the working agent's icon gets the same ring.

How "working" is detected:

- **Muse, Claude, Gemini:** the app is showing its **Stop** button. Chat apps show it only while a reply is being written, so the button appearing means working and the button disappearing means done. Notch Agents reads this through macOS Accessibility. For Claude and other web-based apps, it asks the window for its list of buttons directly (the same search VoiceOver uses), so even long chats are checked quickly. On first launch macOS asks you to allow it. Allow it under System Settings → Privacy & Security → **Accessibility**, or right-click an icon → *Allow App Status (Accessibility)…*. It only looks for that button.
- **Instinct (iMessage):** Notch Agents reads your Messages history (`~/Library/Messages/chat.db`, read-only) about every 0.7 seconds and checks the newest message in your one-on-one chat with Instinct. It finds that chat by the **last 10 digits** of the number, so `+1 (555) 123-4567`, `+15551234567` and `5551234567` all match however Messages stored it. If the newest message is from you (and under 15 minutes old), Instinct counts as working. When its reply arrives, the outline flashes green. Tapbacks are ignored. macOS requires **Full Disk Access** for this. The app asks shortly after launch, or you can right-click an icon → *Allow Instinct Status (Full Disk Access)…*. Turn on NotchAgents, then quit and reopen it.

Right-click an icon to see what's being detected under **Activity (live)**, for example `Claude: Stop button visible → working`. For troubleshooting, **Copy Diagnostics** copies a full report to the clipboard: permission status, which app it found, how much of the window it could scan, and which buttons it saw. Copy it while an app is in the middle of answering.

**If an app's glow doesn't come on,** its stop button probably has a different label. While that app is answering, right-click an icon → **Show Button Names** → the app. A list of every button it's showing opens. Find the stop button and put its label in that agent's `stopButtons`:

```json
{ "name": "Muse", "stopButtons": ["Stop generating"], ... }
```

When Claude or Muse is in the background (another app in front, another desktop, or full screen elsewhere), macOS treats its window as hidden. The app then stops updating its Stop button and barely uses CPU, even mid-reply. So once it's working, it keeps glowing until one of these happens:
  - **The app posts a macOS notification**, such as Claude's "response finished". Notch Agents reads Notification Center's history read-only, using the Full Disk Access you granted for Instinct. Turn on Claude's notifications (in Claude's settings and in System Settings → Notifications) for the best results.
  - **It comes back to the front.** The window is then re-scanned immediately.
  - **For apps that never post notifications,** all of its processes stay quiet for about 15 seconds.
  - **A 30-minute safety limit** passes.

  This is `"backgroundDone"`, on by default for Claude and Muse.

Muse has no labeled Stop button. Instead, sending it a message counts as working, and a new **Copy response** button appearing under its reply counts as done (`"responseButtons": ["Copy response"]`, on by default for Muse). Muse also counts as working while reply text keeps streaming into its window, in case its stop button has no label. Turn this on for other apps with `"watchText": true`, or off with `false`.

Your `stopButtons` labels match like this: a single word (like `stop`) must match a button's label exactly; a phrase may appear anywhere in it. Matching ignores capitalization. On top of those, Notch Agents recognizes common stop controls on its own: short labels starting with "Stop", "Cancel generating", "Cancel response" or "Interrupt", and hidden button names like `stop-button`. It ignores stop buttons for dictation, voice, recording and sharing.

**Keeping it light:** after a full scan, Notch Agents remembers where the chat box is (the area around the Send/Stop button). Most checks look only there, with a full scan every 8 seconds or whenever the Stop button seems to disappear. CPU use for the background fallback is read directly from macOS for the tracked apps' own processes; it doesn't launch any extra programs.

**Other desktops and full screen:** macOS's public Accessibility API only lists windows on the desktop you're looking at. When an app seems to have no windows, Notch Agents probes for its windows on other desktops and full-screen spaces, at most every 30 seconds per app. It uses an undocumented macOS function to do this, the same approach window switchers use. If a future macOS changes it, only this extra lookup stops working.

Per-agent settings:

```json
{ "name": "Claude", "glow": "#FF7A2F", "activity": "buttons", "stopButtons": ["Stop response"], ... }
```

- `glow`: `"#RRGGBB"` or `"rainbow"`
- `activity`: `"auto"` (default: `"buttons"` for apps, `"imessage"` for iMessage), `"buttons"`, `"imessage"`, `"cpu"` (old CPU-based guess, less reliable) or `"none"`
- `stopButtons`: labels of the app's stop button (default: `stop`, `stop response`, `stop generating`, `stop streaming`, `stop responding`, `stop answer`)
- `cpuThreshold` (only for `"cpu"`): CPU points above the app's idle level that count as working. Raise it if the outline lights up when you're just using the app; lower it if it misses responses

Global: `"showActivity": false` turns the feature off; `"doneColor"` changes the finish flash (default `"#39FF14"`).

## Config file

On first launch the app writes its config to `~/.config/notch-agents/config.json`. Right-click an icon and choose **Edit Agents…** to change it. Changes apply within about two seconds, with no restart.

**Set Instinct's number:** in that file, replace `REPLACE_WITH_INSTINCT_NUMBER_OR_EMAIL` with the phone number or email you text Instinct at:

```json
"action": { "type": "imessage", "handle": "+15551234567" }
```

**Custom icons:** put an image named after an agent in `~/.config/notch-agents/icons/` (for example `muse.png`) and it's used for that agent's icon.

## Customizing

Each side (`left`, `right`) is a list of agents, ordered left to right. In hover mode the tray shows the left group, then the right group, with a small gap between them. You can have as many as fit.

```json
{
  "mode": "hover",        // "hover" = drop-down tray; "wings" = always visible beside the notch
  "iconSize": 0,          // 0 = auto (62 in hover mode, menu-bar height in wings mode)
  "spacing": 8,           // gap between icons
  "notchPadding": 8,      // wings mode: gap between the notch and the nearest icon
  "extendNotch": true,    // wings mode: black strip behind icons so the notch "grows wings"
  "left":  [ ... ],
  "right": [ ... ]
}
```

(The real file is plain JSON. The comments above are only for explanation.)

### Action types

| `type`     | Fields                                      | Example |
|------------|---------------------------------------------|---------|
| `app`      | `bundleId`, `appName`, or `appPath`; optional `alternateNames` | `{"type":"app","appName":"Meta AI","alternateNames":["Muse"]}` |
| `imessage` | `handle` (phone number or email)            | `{"type":"imessage","handle":"+15551234567"}` |
| `url`      | `url` (web or custom scheme)                | `{"type":"url","url":"https://chatgpt.com"}` |
| `shell`    | `command` (runs in `zsh -lc`)               | `{"type":"shell","command":"open -a Terminal"}` |

Any action can also take `fallbackURL`, which opens if the main action fails (for example, when the app isn't installed).

### Icons

`icon` is optional. If you leave it out, the app looks for an image named after the agent in `~/.config/notch-agents/icons/` (for example `muse.png`). If there isn't one, it uses an icon bundled with the app (`Resources/icons/<name>.png`, which is where Muse's icon lives), then the target app's own icon (the Messages icon for iMessage agents).

- `"builtin:instinct"` draws Instinct's "I" badge; `"builtin:robot"` draws a neutral robot head
- `"sf:bolt.fill"` uses an [SF Symbol](https://developer.apple.com/sf-symbols/)
- `"app:com.apple.MobileSMS"` borrows another app's icon
- `"~/Pictures/muse.png"` uses an image file (`.png`, `.icns`, `.jpg`)

## Notes

- On Macs without a notch (or with only an external display), push the mouse to the very top center of the screen to open the tray.
- In wings mode the icons are drawn above the menu bar. If an app has a very long menu, its last menus may end up under the left icons. Reduce `iconSize` or move agents to the right if that happens.
