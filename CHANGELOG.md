# Changelog

Notable changes to this project, newest first. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[semantic versioning](https://semver.org/).

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
