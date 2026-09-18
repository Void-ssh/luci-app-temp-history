# Changelog

Notable changes to this project, newest first. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[semantic versioning](https://semver.org/).

## [1.1.1] — 2026-09-18

### Fixed

- **New ubus methods were not registered until rpcd was restarted by hand.**
  Install ran `/etc/init.d/rpcd reload`, which re-reads the ACLs but leaves a
  newly added method missing from the plugin's table — confirmed on a live
  router, where `resetHistory` was absent from `ubus -v list luci.temp-status`
  until rpcd was restarted. Methods with a CGI fallback degraded quietly; the
  ones without (fan control, setpoints, reset) simply failed.

  Install now restarts rpcd, falling back to a reload if that fails. The cost
  is that ubus sessions are dropped, so an admin signed in during an upgrade
  may have to sign in again — a far smaller surprise than a control that does
  nothing until someone thinks to restart a daemon.

- The matching error message now says what to do — restart rpcd and sign in
  again — instead of suggesting `ubus list`, which confirms a method is missing
  without hinting at the cause.

## [1.1.0] — 2026-09-18

### Added

- **Start a fresh series, from Settings.** Two buttons, because the two
  actions differ in kind and one combined "wipe" would have to be as
  frightening as its worst half:

  - **Rebuild daily summary** sets `temp-daily.tsv` aside. This is a *repair*,
    not a loss — the next flush recomputes every complete day still present in
    the 15-minute series. No confirmation, because nothing meaningful is at
    risk.
  - **Wipe all history** sets every series aside as well: temperatures, fan,
    CPU/memory, uptime and the rollup. Confirmed, and the dialog names the
    recorded row count so the number itself gives you pause. It also clears
    the RAM buffers — leaving them would let the next flush append readings
    from before the reset onto the fresh file, exactly the mixing the schema
    header exists to prevent — and the per-sensor min/max cutoffs, which with
    no readings left could only hide the new series from itself.

  **Nothing is deleted.** Each file is renamed to `<name>.<timestamp>.old`,
  the same thing a sensor-set change has always done. A mis-click costs an
  `mv` over SSH rather than six months of readings, and the page reports the
  paths so they can be removed deliberately.

  The helper takes the **same lock as the flush**: renaming a series out from
  under a running flush would let it append to a file nobody will read again.
  `resetHistory` is on both rpcd backends and, like the setpoints, deliberately
  absent from the CGI — destructive and unauthenticated do not belong in the
  same endpoint.

## [1.0.2] — 2026-09-18

### Fixed

- **The daily rollup was being destroyed on every flush.** On OpenWrt 25.12
  this build of `sort` accepts `-o`, exits 0, writes the sorted text to
  **stdout**, and creates no file. The rollup code took that exit status as
  success, truncated `temp-daily.tsv`, and refilled it from the file that was
  never written — leaving a bare header. So the one file in this package that
  is *never trimmed*, the one that exists to answer "is this router hotter
  than it was six months ago", accumulated nothing at all. Silently, while the
  flush reported success.

  The stray stdout from that same `sort` is what produced the
  "unexpected output from flush helper" banner in 1.0.1.

  Two changes: the sort writes through a plain redirect rather than `-o`, and
  the result is built in a third file and moved into place only once it is
  known good. The old code destroyed the data *before* knowing the replacement
  was usable, which is what turned an unsupported option into data loss.

  The regression test stubs a `sort` that behaves exactly like that one. It has
  to run under **dash**: BusyBox ash resolves `sort` as a built-in applet and
  never consults `PATH`, so under ash the stub is invisible.

## [1.0.1] — 2026-09-18

### Fixed

- **"Flush failed: unexpected output from flush helper" on a flush that
  actually succeeded.** Seen on OpenWrt 25.12: the rows reached flash and the
  RAM buffer emptied, but the page reported a failure — the worst kind of
  wrong, because it teaches you to distrust a working flush.

  The ucode backend parses the helper's *entire* stdout as one JSON object, so
  a single stray byte from any command the script calls breaks it. The script
  itself never printed outside the final line, but it calls `uci`, `awk`,
  `sort`, `grep`, `find`, `logger`, `mkdir` and `mv` — on firmware this was
  never run against.

  Rather than chase which one is chatty on which build, stdout is now reserved
  for the result: the script hands its JSON out on fd 3 and points fd 1 at
  stderr, which every caller already discards. Anything added later is safe by
  construction instead of by review. Command substitution is unaffected, since
  `$(...)` redirects fd 1 for its own subshell.

  The regression test poisons `mkdir` — one of the few commands whose output
  is not already swallowed by a `$( )` — and asserts the result still parses,
  is one line, says `ok`, and that the row was written.

## [1.0.0] — 2026-09-03

First release.

### Added

- **Temperature history.** A reading from every sensor every 15 minutes, 30
  days of it, plus a daily min/max/mean rollup that is never trimmed. Buffered
  in RAM and written to flash once a day — ~365 flash writes a year instead of
  ~35 000.

- **A page under *Status → Temperature*.** A live card per sensor with today's
  min, max and average; a 30-day chart with drag-to-zoom and per-sensor legend
  toggles; an uptime strip marking reboots, with the current uptime on its
  title line.

- **Fan monitoring and manual control**, where the hardware has a tachometer
  and a writable PWM. Fan RPM shares the temperature chart on its own
  right-hand axis. A manual speed expires on its own, is handed back to the
  kernel if any sensor reaches the critical threshold or if the guard process
  dies, and cannot be used to stall the fan.

- **CPU and memory**, live and over 30 days, on a fixed 0–100 % axis beside the
  temperature series — so *it was hot* can be told apart from *it was hot and
  working*.

- **Thermal setpoints on GL.iNet firmware.** Where the fan is run by GL's
  `gl_fan` daemon rather than the kernel governor, the Settings panel sets its
  minimum and maximum setpoints and restores the factory values. Every change
  starts from the factory baseline rather than from an already-patched file,
  and `glfan-setpoints.sh check` is a read-only pre-flight that reports what
  each substitution would match on *your* firmware before anything is written.
  Hidden entirely on other hardware.

- **An Events panel** reading back the threshold crossings and fan stalls the
  collector logs to syslog, newest first, colour-coded by level.

- **Watchdogs for the failures that are otherwise silent**: a fan driven but
  not turning, collection that has stopped, and a sensor map that no longer
  matches the recorded columns. The age of the newest sample is always on
  screen, because a frozen history looks exactly like a quiet one — the live
  cards keep updating from a direct sensor read either way.

- **A Status Overview widget** taking its bar and reading colours from the
  active LuCI theme at runtime, so it matches whatever theme the router wears.

- **Three backends, so every OpenWrt version from 21.02 gets the same page**: a
  ucode rpcd plugin (22.03+), an rpcd *shell* plugin (all versions), and a
  read-only CGI for the data itself. Every mutating operation runs over ubus,
  where LuCI authenticates it; the CGI's write verbs are a break-glass route
  that closes automatically whenever rpcd answers.
