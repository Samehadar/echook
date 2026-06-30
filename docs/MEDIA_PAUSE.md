# Media-pause-during-alert (fork customization)

> Personal fork patch. Not upstream echook behaviour.

On macOS, instead of just playing the alert over your music, this fork **pauses
the currently-playing media, plays the alert at full volume, then resumes it** —
with smooth volume fades around it. Works for any macOS *Now Playing* source
(Chrome / YouTube / Telegram / Spotify / Apple Music …).

## Why it's built this way

macOS 15.4+ (incl. 26 "Tahoe") locked down media control:

- The private **MediaRemote** API and `nowplaying-cli` stopped working
  (`mediaremoted` now does entitlement verification).
- Synthetic media keys (`NX_KEYTYPE_PLAY` via `CGEventPost`) no longer pause the
  Now Playing session — they fall through to volume.
- Pausing Chrome via AppleScript→JS is too slow with many tabs (loops every tab)
  and misses background-tab / iframe players.

The working tool is **[`media-control`](https://github.com/ungive/media-control)**
(wraps `ungive/mediaremote-adapter`, which reaches MediaRemote through the
entitled `/usr/bin/perl`). **Catch:** `media-control` only loads its framework
when spawned by **launchd** — it fails (`Failed to load framework`) when spawned
under the hook's Python. So this patch drives it through three on-demand
**LaunchAgents** and triggers them with `launchctl kickstart` (which re-parents
the work to launchd, where the framework loads):

| Agent | Runs |
|---|---|
| `com.echook.get`   | `media-control get` → writes Now Playing JSON to `/tmp/echook_np.json` |
| `com.echook.pause` | `media-control pause` |
| `com.echook.play`  | `media-control play` |

## Per-alert sequence (`play_audio_macos`)

Only when `get` reports something is playing (so it never resumes media you
paused yourself, and never blasts):

1. fade the system volume **out to 0** (`DOWN_MS`)
2. `kickstart com.echook.pause`
3. volume back to full, play the alert (`afplay -v ALERT_V`)
4. volume to 0, `kickstart com.echook.play`
5. fade the volume **back in from 0 to the previous level** (`UP_MS`)

`PAUSE_WAIT` is a short wait after the pause kick before the alert (keeps the
pre-alert gap tiny); `RESUME_DELAY` ≈ media-control's resume latency so the
fade-in begins as the music actually returns. A self-healing lock
(`$TMPDIR/echook_duck.lock`, 20s TTL) keeps overlapping or killed alerts from
stranding the volume.

## Stay silent while dictating (VoiceInk) / on a call

Before doing anything, the alert is **skipped entirely** if the microphone is in
use — so it can't break through VoiceInk's recording (or a call). The desktop
toast still fires, so you don't miss the notification. Mic state is read from
CoreAudio (`kAudioDevicePropertyDeviceIsRunningSomewhere` on the default input
device) by the tiny `echook-mic-busy` helper (`scripts/echook-mic-busy.swift`).
The alert is also skipped if the output is muted.

(Detecting the mic, rather than VoiceInk's own state, is what makes it robust:
VoiceInk's recording state isn't exposed externally, but the mic-in-use flag is,
and it covers any dictation/call app.)

## Setup

```bash
brew install media-control
bash scripts/echook-media-agents-setup.sh   # registers the 3 LaunchAgents (login) + builds echook-mic-busy
```

(`scripts/echook-mic-busy.swift` must sit next to the setup script so it can
compile the helper to `~/.claude/bin/echook-mic-busy`; needs Xcode CLT / swiftc.)

The patch lives in `hooks/hook_runner.py` → `play_audio_macos` (marked
`echook-duck v12`). Tunables at the top of that function: `ALERT_V`, `DOWN_MS`,
`UP_MS`, `PAUSE_WAIT`, `RESUME_DELAY`, `RAMP_STEPS`.

## Notes

- If `media-control` is missing or nothing is playing, the alert just plays at
  the current volume — no pause, no error.
- Re-run `scripts/echook-media-agents-setup.sh` if `launchctl kickstart` reports
  the label isn't found (e.g. after reinstalling media-control).
