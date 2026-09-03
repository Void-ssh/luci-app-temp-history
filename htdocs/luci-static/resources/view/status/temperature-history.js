// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Void
'use strict';
'require view';
'require poll';
'require request';
'require rpc';
'require uci';

// Stamped at package time by tools/build-ipk.sh. Left as the raw token in the
// source tree, so a file that was edited in place on a router and never
// rebuilt honestly reports itself as "dev" rather than claiming a release.
const PKG_VERSION_RAW = '@@PKG_VERSION@@';
const PKG_VERSION = (PKG_VERSION_RAW.indexOf('@@') === 0) ? 'dev' : PKG_VERSION_RAW;

document.head.append(E('style', { type: 'text/css' }, `
  :root {
    --th-good:    #46a3d1;
    --th-warn:    #c87f0a;
    --th-hot:     #b5261e;
    --th-hi-clr:  #b5261e;
    --th-lo-clr:  #2471a3;
    --th-avg-clr: #6c757d;
    --th-label:   #222;
    --th-dim:     #888;
    --th-text:    #222;
    --th-bar-start: #46a3d1;
    --th-bar-end:   #4fc3c7;
    --th-border:  rgba(0,0,0,0.12);
    --th-tip-bg:  #fff;
    --th-sel-bg:  rgba(80,130,255,0.12);
    --th-sel-bd:  rgba(80,130,255,0.45);
  }
  /* Themes that signal dark mode explicitly (Bootstrap, Material, Aurora)
     set data-darkmode. Themes that do not are covered by the media query
     below, which is scoped so an explicit data-darkmode="false" still wins. */
  @media (prefers-color-scheme: dark) {
    :root:not([data-darkmode="false"]) {
      --th-good:    #009890;
      --th-warn:    #e67e22;
      --th-hot:     #e74c3c;
      --th-hi-clr:  #e74c3c;
      --th-lo-clr:  #64b5f6;
      --th-avg-clr: #adb5bd;
      --th-label:   #e8e8e8;
      --th-dim:     #888;
      --th-text:    #e8e8e8;
      --th-bar-start: #00a199;
      --th-bar-end:   #065f46;
      --th-border:  rgba(255,255,255,0.08);
      --th-tip-bg:  #1e2230;
      --th-sel-bg:  rgba(80,130,255,0.15);
      --th-sel-bd:  rgba(80,130,255,0.55);
    }
  }
  :root[data-darkmode="true"] {
    --th-good:    #009890;
    --th-warn:    #e67e22;
    --th-hot:     #e74c3c;
    --th-hi-clr:  #e74c3c;
    --th-lo-clr:  #64b5f6;
    --th-avg-clr: #adb5bd;
    --th-label:   #e8e8e8;
    --th-dim:     #888;
    --th-text:    #e8e8e8;
    --th-bar-start: #00a199;
    --th-bar-end:   #065f46;
    --th-border:  rgba(255,255,255,0.08);
    --th-tip-bg:  #1e2230;
    --th-sel-bg:  rgba(80,130,255,0.15);
    --th-sel-bd:  rgba(80,130,255,0.55);
  }
  .th-desc     { color: var(--th-dim) !important; font-size: 0.85rem; }
  .th-status-bar {
    font-size: 0.68rem;
    color: var(--th-dim);
    font-family: monospace;
    margin-bottom: 0.75rem;
    letter-spacing: 0.5px;
  }
  .th-status-bar a, .th-status-bar button.th-flush-btn {
    color: var(--th-good);
    cursor: pointer;
    text-decoration: underline;
    background: none;
    border: none;
    font: inherit;
    letter-spacing: inherit;
    padding: 0;
  }
  .th-status-bar button.th-flush-btn:hover { opacity: 0.8; }
  .th-status-bar button.th-flush-btn:focus-visible,
  .th-legend-item:focus-visible,
  .th-range-btn:focus-visible,
  .th-reset-minmax:focus-visible,
  .th-reset-zoom:focus-visible {
    outline: 2px solid var(--th-good);
    outline-offset: 2px;
  }
  .th-cards {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(140px, 170px));
    gap: 0.5rem;
    margin-bottom: 0.75rem;
  }
  .th-card {
    position: relative;
    border: 1px solid var(--th-border);
    border-radius: 10px;
    padding: 0.75rem 0.9rem 0.65rem;
    transition: border-color 0.3s;
    background: rgba(128,128,128,0.04);
  }
  .th-card.th-warm { border-color: rgba(200,127,10,0.45); }
  .th-card.th-hot  {
    border-color: rgba(231,76,60,0.55);
    box-shadow: 0 0 8px rgba(231,76,60,0.12);
  }
  .th-label {
    font-size: 0.6rem;
    text-transform: uppercase;
    letter-spacing: 1.4px;
    color: var(--th-label);
    margin-bottom: 0.3rem;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }
  .th-label-text { display: none; }
  .th-val {
    font-size: 1.6rem;
    font-weight: 700;
    line-height: 1.1;
    font-family: monospace;
    color: var(--th-good);
    transition: color 0.3s;
  }
  .th-val.th-c-warn { color: var(--th-warn); }
  .th-val.th-c-hot  { color: var(--th-hot);  }
  .th-unit {
    font-size: 0.78rem;
    font-weight: 400;
    color: var(--th-label);
    margin-left: 2px;
  }
  .th-bar {
    height: 3px;
    background: rgba(128,128,128,0.12);
    border-radius: 99px;
    overflow: hidden;
    margin: 0.35rem 0 0.45rem;
  }
  .th-bar-fill {
    height: 100%;
    border-radius: 99px;
    transition: width 0.6s ease, background 0.3s;
    background: linear-gradient(to right, var(--th-bar-start), var(--th-bar-end));
  }
  .th-stat {
    font-size: 0.65rem;
    color: var(--th-text);
    line-height: 1.85;
    white-space: nowrap;
    font-family: monospace;
  }
  .th-arrow-hi  { color: var(--th-hi-clr); font-weight: 700; }
  .th-arrow-lo  { color: var(--th-lo-clr); font-weight: 700; }
  .th-arrow-avg { color: var(--th-avg-clr); }
  .th-stat-ts   { color: var(--th-dim); margin-left: 4px; }
  .th-chart-box {
    border: 1px solid var(--th-border);
    border-radius: 10px;
    padding: 0.75rem 0.9rem 0.5rem;
    background: rgba(128,128,128,0.04);
    margin-bottom: 0.75rem;
  }
  .th-chart-label {
    font-size: 0.6rem;
    text-transform: uppercase;
    letter-spacing: 2px;
    color: var(--th-dim);
    font-family: monospace;
    margin-bottom: 0.4rem;
  }
  .th-canvas-wrap {
    position: relative;
    height: 200px;
    cursor: crosshair;
  }
  .th-canvas-wrap canvas { width:100%!important; height:100%!important; display:block; }
  .th-reset-zoom {
    position: absolute;
    top: 6px;
    right: 6px;
    display: none;
    padding: 3px 9px;
    font-size: 0.65rem;
    font-family: monospace;
    background: var(--th-tip-bg);
    border: 1px solid var(--th-border);
    border-radius: 6px;
    color: var(--th-good);
    cursor: pointer;
    opacity: 0.9;
    z-index: 10;
  }
  .th-reset-zoom:hover { opacity: 1; }
  .th-legend {
    display: flex;
    flex-wrap: wrap;
    gap: 12px;
    margin-top: 8px;
  }
  .th-legend-item {
    display: flex;
    align-items: center;
    gap: 6px;
    font-size: 0.65rem;
    color: var(--th-text);
    font-family: monospace;
    cursor: pointer;
    user-select: none;
    opacity: 1;
    transition: opacity 0.2s;
    background: none;
    border: none;
    padding: 0;
    letter-spacing: inherit;
  }
  .th-legend-item.th-hidden { opacity: 0.38; }
  .th-legend-dot {
    width: 9px; height: 9px;
    border-radius: 50%;
    flex-shrink: 0;
  }
  .th-tooltip {
    position: fixed;
    pointer-events: none;
    display: none;
    background: var(--th-tip-bg);
    border: 1px solid var(--th-border);
    border-radius: 8px;
    padding: 7px 11px;
    font-family: monospace;
    font-size: 11.5px;
    color: var(--th-text);
    z-index: 9999;
    box-shadow: 0 4px 20px rgba(0,0,0,.18);
    white-space: nowrap;
    line-height: 1.75;
  }
  .th-uptime-wrap {
    position: relative;
    height: 100px;
    cursor: crosshair;
  }
  .th-uptime-wrap canvas { width:100%!important; height:100%!important; display:block; }
  .th-range-btns {
    display: flex;
    gap: 6px;
    margin-bottom: 0.55rem;
  }
  .th-range-btn {
    font-size: 0.62rem;
    font-family: monospace;
    letter-spacing: 0.8px;
    padding: 3px 10px;
    border-radius: 6px;
    border: 1px solid var(--th-border);
    background: rgba(128,128,128,0.06);
    color: var(--th-dim);
    cursor: pointer;
    transition: background 0.15s, color 0.15s, border-color 0.15s;
  }
  .th-range-btn:hover { color: var(--th-text); border-color: var(--th-good); }
  .th-range-btn.th-active {
    background: rgba(0,152,144,0.12);
    color: var(--th-good);
    border-color: var(--th-good);
  }
  .th-reset-minmax {
    position: absolute;
    top: 0.5rem;
    right: 0.55rem;
    font-size: 0.62rem;
    font-family: monospace;
    padding: 1px 4px;
    border-radius: 4px;
    border: 1px solid var(--th-border);
    background: rgba(0,0,0,0.25);
    color: var(--th-dim);
    cursor: pointer;
    opacity: 0;
    transition: opacity 0.18s, color 0.15s, border-color 0.15s;
  }
  .th-card:hover .th-reset-minmax,
  .th-reset-minmax:focus-visible { opacity: 0.75; }
  .th-banner {
    border: 1px solid rgba(200,127,10,0.5);
    background: rgba(200,127,10,0.10);
    color: var(--th-text);
    border-radius: 8px;
    padding: 0.6rem 0.8rem;
    font-size: 0.72rem;
    line-height: 1.6;
    margin-bottom: 0.75rem;
  }
  .th-banner strong { color: var(--th-warn); }
  .th-export {
    font-size: 0.7rem; text-decoration: none; color: var(--th-good);
    border: 1px solid var(--th-good); border-radius: 3px; padding: 1px 6px;
    opacity: 0.85;
  }
  .th-export:hover { opacity: 1; }
  /* The banner can carry more than one message, one per line. */
  .th-banner { white-space: pre-line; }
  .th-settings { margin-bottom: 0.75rem; }
  .th-settings summary {
    font-size: 0.6rem;
    text-transform: uppercase;
    letter-spacing: 2px;
    color: var(--th-dim);
    font-family: monospace;
    cursor: pointer;
    padding: 0.2rem 0;
  }
  .th-settings summary:focus-visible { outline: 2px solid var(--th-good); outline-offset: 2px; }
  .th-settings-body {
    display: flex;
    flex-wrap: wrap;
    align-items: flex-end;
    gap: 12px;
    border: 1px solid var(--th-border);
    border-radius: 10px;
    background: rgba(128,128,128,0.04);
    padding: 0.7rem 0.9rem;
    margin-top: 0.4rem;
  }
  .th-field { display: flex; flex-direction: column; gap: 3px; }
  .th-field label {
    font-size: 0.6rem;
    text-transform: uppercase;
    letter-spacing: 1.2px;
    color: var(--th-dim);
    font-family: monospace;
  }
  .th-field input {
    width: 7rem;
    font-family: monospace;
    font-size: 0.8rem;
    padding: 3px 6px;
    border-radius: 6px;
    border: 1px solid var(--th-border);
    background: rgba(128,128,128,0.06);
    color: var(--th-text);
  }
  .th-save {
    font-size: 0.68rem;
    font-family: monospace;
    letter-spacing: 0.8px;
    padding: 5px 14px;
    border-radius: 6px;
    border: 1px solid var(--th-good);
    background: rgba(0,152,144,0.12);
    color: var(--th-good);
    cursor: pointer;
  }
  .th-save[disabled] { opacity: 0.5; cursor: default; }
  .th-save:focus-visible { outline: 2px solid var(--th-good); outline-offset: 2px; }
  .th-settings-msg { font-size: 0.68rem; font-family: monospace; color: var(--th-dim); }
  /* Thermal setpoints. Full width inside the settings body and separated by a
     rule, because it configures a different thing from the fields above it:
     those are this package's own preferences, these rewrite the firmware's
     fan controller. */
  .th-setp {
    width: 100%;
    border-top: 1px solid var(--th-border);
    margin-top: 4px;
    padding-top: 0.7rem;
    display: flex;
    flex-wrap: wrap;
    align-items: flex-end;
    gap: 12px;
  }
  .th-setp-head {
    width: 100%;
    font-size: 0.6rem;
    text-transform: uppercase;
    letter-spacing: 1.6px;
    color: var(--th-dim);
    font-family: monospace;
  }
  .th-setp-ro {
    font-size: 0.68rem;
    font-family: monospace;
    color: var(--th-dim);
    padding-bottom: 4px;
  }
  .th-setp-ro strong { color: var(--th-text); font-weight: 600; }
  .th-setp-ro em { font-style: normal; color: var(--th-warn); opacity: 0.85; }
  .th-setp-check {
    display: flex; align-items: center; gap: 6px;
    font-size: 0.68rem; font-family: monospace; color: var(--th-text);
    padding-bottom: 4px; cursor: pointer;
  }
  .th-setp-danger {
    border-color: var(--th-hot);
    background: rgba(181,38,30,0.10);
    color: var(--th-hot);
  }
  .th-setp-note {
    width: 100%;
    font-size: 0.64rem;
    line-height: 1.7;
    font-family: monospace;
    color: var(--th-dim);
    white-space: pre-line;
  }
  .th-setp-note strong { color: var(--th-warn); }
  /* Device / firmware line at the foot of the page. Sits above LuCI's own
     "Powered by" footer and reads as a quieter sibling of it. */
  .th-title { display: flex; align-items: center; gap: 9px; }
  .th-title-icon {
    display: inline-flex; align-items: center;
    color: var(--th-good);
    flex: 0 0 auto;
  }
  .th-title-icon svg { display: block; }
  /* The system cards sit in the same row as the sensors and share their
     styling; they only differ in having no min/max/avg rows to show. */
  .th-card-sys .th-bar { margin-bottom: 0; }
  .th-device {
    margin: 0.9rem 0 0.2rem;
    padding-top: 0.6rem;
    border-top: 1px solid var(--th-border);
    font-family: monospace;
    font-size: 0.66rem;
    line-height: 1.9;
    text-align: right;
    color: var(--th-dim);
    word-break: break-word;
  }
  .th-dev-model { color: var(--th-good); font-weight: 600; letter-spacing: 0.3px; }
  .th-dev-key   { color: var(--th-dim); }
  .th-dev-val   { color: var(--th-text); }
  .th-dev-owrt  { color: var(--th-bar-end); }
  .th-dev-sep   { color: var(--th-border); margin: 0 0.5em; }
  @media (max-width: 720px) { .th-device { text-align: left; } }
  .th-version {
    width: 100%; margin-top: 6px; font-size: 0.64rem; font-family: monospace;
    color: var(--th-dim); opacity: 0.75;
  }
  .th-version-stale { color: var(--th-warn); opacity: 1; }
  .th-rpm {
    font-size: 0.65rem;
    color: var(--th-text);
    line-height: 1.85;
    white-space: nowrap;
    font-family: monospace;
  }
  .th-rpm-icon { color: var(--th-good); }
  .th-fan-box { margin-bottom: 0.75rem; }
  .th-fan-body {
    display: flex;
    flex-wrap: wrap;
    align-items: center;
    gap: 12px;
    border: 1px solid var(--th-border);
    border-radius: 10px;
    background: rgba(128,128,128,0.04);
    padding: 0.7rem 0.9rem;
    margin-top: 0.4rem;
  }
  .th-fan-mode {
    font-size: 0.68rem;
    font-family: monospace;
    padding: 2px 8px;
    border-radius: 6px;
    border: 1px solid var(--th-border);
  }
  .th-fan-mode.th-fan-manual { color: var(--th-warn); border-color: var(--th-warn); }
  .th-fan-mode.th-fan-auto   { color: var(--th-good); border-color: var(--th-good); }
  .th-fan-slider { width: 12rem; vertical-align: middle; }
  .th-fan-pct {
    font-family: monospace;
    font-size: 0.85rem;
    min-width: 3.2rem;
    display: inline-block;
    text-align: right;
    color: var(--th-text);
  }
  .th-fan-note { font-size: 0.66rem; font-family: monospace; color: var(--th-dim); flex-basis: 100%; }
  .th-reset-minmax:hover { opacity: 1 !important; color: var(--th-warn); border-color: var(--th-warn); }

  /* Events. Monospace and one line per event, because the interesting reading
     is scanning a column of timestamps for a cluster, not any single line. */
  .th-evt-head {
    display: flex; align-items: center; gap: 0.75rem;
    flex-wrap: wrap; margin-bottom: 0.5rem;
  }
  .th-evt-note { font-size: 0.68rem; color: var(--th-dim); flex: 1 1 16rem; }
  .th-evt-body { max-height: 16rem; overflow-y: auto; }
  .th-evt-row {
    display: flex; gap: 0.6rem; align-items: baseline;
    font-family: monospace; font-size: 0.68rem;
    padding: 0.15rem 0; border-bottom: 1px solid rgba(128,128,128,0.12);
  }
  .th-evt-row:last-child { border-bottom: 0; }
  .th-evt-ts  { color: var(--th-dim); white-space: nowrap; }
  .th-evt-msg { word-break: break-word; }
  .th-evt-warn .th-evt-msg { color: var(--th-warn); }
  .th-evt-err  .th-evt-msg { color: var(--th-hot); font-weight: bold; }
  .th-evt-empty { font-size: 0.7rem; color: var(--th-dim); padding: 0.3rem 0; }

  /* Sample age. Unremarkable until it is not — the banner is what shouts,
     this is what you notice in passing. */
  .th-age-stale { color: var(--th-warn); font-weight: bold; }

  /* Current uptime, on the uptime chart's title line. Brighter than the label
     around it: the label is a caption, this is a reading. */
  .th-uptime-now { color: var(--th-good); font-weight: bold; }
`));

const MONTHS = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
const COLORS = ['#2979ff','#00c853','#ff6d00','#e040fb','#00bcd4','#ffea00','#76ff03','#ff4081'];
// CPU, memory, memory-with-cache — for the CHART LINES only. The cards use the
// theme's own card colours, like the sensors beside them; a line on a chart
// needs to be told apart from two others, a card does not.
//
// Deliberately not COLORS[0..2]: sitting directly under the temperature chart,
// reusing its first three colours would read as three more sensors rather than
// a different measurement. The cached line is the dimmest of the three because
// it is the least meaningful on its own.
// Fan lines on the temperature chart.
// Deliberately NOT drawn from COLORS above. They used to be, which meant that
// on a five-sensor router the fan came out #e040fb — the exact magenta of
// sensor 4 — so the legend showed two identical swatches for unrelated things.
// A neutral blue-grey also says "this is not a temperature" before the legend
// is read.
const FAN_COLORS = ['#b0bec5', '#8d6e63'];

// ── What the sensor names actually mean ───────────────────────────────────
// Sensor names come straight from the kernel — /sys/class/thermal/*/type, or
// an hwmon tempN_label — so they are whatever the board's device tree calls
// them. "Tunnel Offload Temp" is a perfectly good name once you know the SoC
// has a tunnel offload coprocessor, and completely opaque until then.
//
// Matched on a NORMALISED name (lower-cased, "temp"/"temperature" and every
// non-alphanumeric removed), so "Tunnel Offload Temp", "tops_thermal" and
// "TOPS-0" all land on the same entry. First match wins, so the more specific
// patterns are listed first — "cpucluster" has to be tested before "cpu".
//
// Nothing here is guessed at runtime: an unrecognised sensor gets no hint at
// all rather than a plausible-sounding wrong one. Being silent about a name
// is much cheaper than teaching somebody something untrue about their router.
const SENSOR_HINTS = [
  [/cpu(cluster|1|b)/,        'Second thermal sensor in the same CPU cluster, at the other end of the block. It should track the CPU reading closely — a persistent gap between the two means load sitting on one end of the cluster.'],
  [/^cpu|cpu0|cpua|cputop/,   'The main application cores. On most routers this is the hottest sensor and the one the fan curve follows.'],
  [/eth2p5g|25g/,             'The 2.5 Gb Ethernet PHY. It draws power whenever a 2.5 G link is up, before any traffic moves, and climbs further under sustained multi-gig transfer.'],
  [/tops|tunneloffload/,      'The tunnel offload coprocessor — it handles VPN and tunnelling protocols (WireGuard, OpenVPN DCO, IPsec, GRE, L2TP) in hardware instead of on the CPU. This is the sensor that responds to VPN throughput.'],
  [/ethwarp|wed|ethernetswitch/, 'The Wi-Fi-to-Ethernet offload engine and the built-in switch block — the part that moves packets between the radios and the wired ports without waking the CPU. Rises when wireless clients are busy.'],
  [/wcss|wifi|phy\d|radio/,   'A Wi-Fi radio. Warms with airtime rather than with throughput, so a busy 2.4 GHz band can outrun a fast but idle 6 GHz one.'],
  [/nss/,                     'The network subsystem cores that handle packet forwarding in hardware, off the main CPU.'],
  [/ddr|dram|memory/,         'The memory controller or the DRAM itself.']
];

// The explanation for a sensor name, or '' when there is nothing honest to say.
function sensorHint(name) {
  const k = String(name || '')
    .toLowerCase()
    .replace(/temperature|temp/g, '')
    .replace(/[^a-z0-9]/g, '');
  if (!k) return '';
  for (let i = 0; i < SENSOR_HINTS.length; i++)
    if (SENSOR_HINTS[i][0].test(k)) return _(SENSOR_HINTS[i][1]);
  return '';
}
const SYS_COLORS = ['#ff6d00', '#00bcd4', 'rgba(0,188,212,0.45)'];
// Thresholds are configurable (uci: temp_history.main.warn_temp / crit_temp)
// and arrive with the full payload. Mutable module state rather than consts,
// because makeChart() closes over them and must see edits without a reload.
// The values here are only the pre-first-payload defaults.
const TH = { warn: 65, crit: 80 };

// Sensor names come from /root/website/temp-sensors.conf, which is hand-edited
// by root. Not attacker-controlled in any normal setup, but the tooltip builds
// its markup as a string, so escape rather than trust the file.
function escHtml(s) {
  return String(s == null ? '' : s)
    .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
}
// RPM: -1 from the collector means "no tachometer / unreadable" and arrives
// as null. 0 is a REAL reading meaning the fan has stopped, so it must render
// as "0 rpm" and never as "—".
function fmtRpm(v) {
  if (v == null) return '—';
  const n = parseInt(v, 10);
  if (isNaN(n) || n < 0) return '—';
  return n + ' rpm';
}
// The page title's thermometer. Inline rather than a file under
// luci-static: it is eleven elements, it inherits the theme colour through
// currentColor, and an installed .svg is one more path to keep in step with
// the package (this app already had to delete a stale one on upgrade).
// innerHTML rather than E(), because E() builds HTML elements and SVG needs
// its own namespace.
function titleIcon() {
  const span = E('span', { class:'th-title-icon', 'aria-hidden':'true' });
  span.innerHTML =
    '<svg viewBox="0 0 24 24" width="24" height="24" fill="none" ' +
    'stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round">' +
    '<path d="M14.5 14.4V4.6a2.5 2.5 0 0 0-5 0v9.8a4.6 4.6 0 1 0 5 0z"/>' +
    '<path d="M12 8.6v6.2"/>' +
    '<circle cx="12" cy="17.7" r="2.1" fill="currentColor" stroke="none"/>' +
    '<path d="M17.6 5.6h3.6M17.6 9h2.4M17.6 12.4h3.6" opacity="0.55"/>' +
    '</svg>';
  return span;
}

function pageTitle(text) {
  return E('h2', { class:'th-title' }, [ titleIcon(), E('span', {}, text) ]);
}

// 0 is a real, meaningful percentage — an idle CPU — so only null and a
// negative sentinel become the em dash.
// One decimal with the unit, for the stat rows. Separate from fmtPct only in
// that it never says "0.0%" for a missing value: 0 is real here.
function pctDisp(v) {
  if (v == null) return '—';
  const n = parseFloat(v);
  if (isNaN(n) || n < 0) return '—';
  return n.toFixed(1) + '%';
}

function fmtPct(v) {
  if (v == null) return '—';
  const n = parseFloat(v);
  if (isNaN(n) || n < 0) return '—';
  return n.toFixed(1) + '%';
}
// NEVER hand E() a null child.
//
// LuCI's dom.append() walks a child array and text-nodes anything that is not
// a DOM element. Current master guards that with `children[i] !== null`, but
// the LuCI shipped on 21.02 (and on the 24.x build here) tests `children`
// — the array itself — so a null entry falls through to
// createTextNode('' + null) and the word "null" is painted onto the page.
// Leaning on the master behaviour printed three literal "null"s on
// passively cooled hardware, on a real router. Filter instead: correct on every LuCI version.
function kids(arr) { return arr.filter(c => c != null && c !== false); }

// One labelled number input. Shared by the two blocks in the Settings panel so
// they cannot drift apart visually; the id prefix keeps the labels' `for`
// attributes unique across both.
function mkField(id, label, value, min, max, hint) {
  const input = E('input', {
    type: 'number', id: 'th-set-'+id, min: String(min), max: String(max),
    step: '1', value: String(value), title: hint
  });
  return { input, node: E('div', { class:'th-field' }, [
    E('label', { for: 'th-set-'+id }, label), input
  ]) };
}

// The collector runs every 15 minutes. Two intervals plus a margin means a
// single missed run — a slow boot, a busy router — never raises the alarm,
// while a cron that has actually stopped is reported within about 40 minutes.
const CGI_URL = '/cgi-bin/get-temp-history.cgi';
const COLLECT_INTERVAL = 900;
const STALE_AFTER = COLLECT_INTERVAL * 2.5;

// Uptime as "12d 4h 7m". Shared by the chart tooltip and the line above it,
// so the two cannot drift into disagreeing about the same number.
function fmtUptimeLong(secs) {
  const s = Math.max(0, Math.floor(Number(secs) || 0));
  const days = Math.floor(s / 86400),
        hrs  = Math.floor((s % 86400) / 3600),
        mins = Math.floor((s % 3600) / 60);
  if (days > 0) return days + 'd ' + hrs + 'h ' + mins + 'm';
  if (hrs  > 0) return hrs + 'h ' + mins + 'm';
  return mins + 'm';
}

function fmtAge(secs) {
  if (secs < 5400)  return Math.round(secs / 60) + ' ' + _('minutes');
  if (secs < 172800) return Math.round(secs / 3600) + ' ' + _('hours');
  return Math.round(secs / 86400) + ' ' + _('days');
}

function tempClass(v) {
  return v >= TH.crit ? 'th-val th-c-hot' : v >= TH.warn ? 'th-val th-c-warn' : 'th-val';
}
function fmtDT(ts) {
  if (!ts) return '—';
  const d  = new Date(ts * 1000);
  const hh = String(d.getHours()).padStart(2,'0');
  const mm = String(d.getMinutes()).padStart(2,'0');
  return d.getDate() + ' ' + MONTHS[d.getMonth()] + ' ' + hh + ':' + mm;
}
// null/undefined render as an em dash — the CGI now sends null (not 0) for a
// sensor with no min/max record yet, e.g. just after a reset.
function toInt(v)  { return v != null ? String(Math.round(parseFloat(v))) : '—'; }
function toDisp(v) { return v != null ? parseFloat(v).toFixed(1) : '—'; }
function h2rgba(hex, a) {
  const r=parseInt(hex.slice(1,3),16), g=parseInt(hex.slice(3,5),16), b=parseInt(hex.slice(5,7),16);
  return `rgba(${r},${g},${b},${a})`;
}

// ── Temperature chart ─────────────────────────────────────────────────────
function makeChart(canvas, tip, resetBtn) {
  const ctx = canvas.getContext('2d');
  const PAD = { top:14, right:14, bottom:46, left:42 };
  const PAD_R_AXIS = 40;   // extra right padding when the rpm axis is drawn
  const GRID = 4;
  let _labels=[], _series=[];
  let _toX, _toY, _yMin, _yMax;
  let _zoomStart=null, _zoomEnd=null;
  let _rMax=0, _toYR=null;
  let _dragAnchorPx=null, _dragCurPx=null;
  // rAF coalescing: mousemove fires far faster than the display refreshes,
  // and a full redraw is ~450 points × N series. Without this the chart was
  // repainting dozens of times per frame while the pointer moved across it.
  let _rafId=null, _pendingHover=null;

  function resize() {
    const r = canvas.parentElement.getBoundingClientRect();
    canvas.width  = Math.max(1, r.width  * devicePixelRatio);
    canvas.height = Math.max(1, r.height * devicePixelRatio);
    ctx.setTransform(devicePixelRatio,0,0,devicePixelRatio,0,0);
  }

  function scheduleDraw(hoverIdx) {
    _pendingHover = (hoverIdx === undefined) ? null : hoverIdx;
    if (_rafId !== null) return;
    _rafId = requestAnimationFrame(()=>{
      _rafId = null;
      draw();
      if (_pendingHover !== null) drawCrosshair(_pendingHover);
    });
  }

  function viewSlice() {
    if (_zoomStart !== null && _zoomEnd !== null) {
      return { start: _zoomStart, end: _zoomEnd };
    }
    return { start: 0, end: _labels.length - 1 };
  }

  function hasRightAxis() {
    return _series.some(s => s.axis === 'right' && !s.hidden);
  }

  function computeScale() {
    const W=canvas.width/devicePixelRatio, H=canvas.height/devicePixelRatio;
    const rightPad = PAD.right + (hasRightAxis() ? PAD_R_AXIS : 0);
    const pw=W-PAD.left-rightPad, ph=H-PAD.top-PAD.bottom;
    const {start,end}=viewSlice();
    let yMin=Infinity, yMax=-Infinity, hasData=false;
    _series.forEach(s=>{
      // Right-axis series (fan rpm) have their own scale below. Letting a
      // 3500 rpm sample into this scan puts the temperature lines flat on the
      // floor of a 0-4000 "degree" axis.
      if(s.hidden||s.axis==='right') return;
      for(let i=start;i<=end;i++){
        const v=s.data[i];
        if(v!=null&&v>0){
          if(v<yMin) yMin=v;
          if(v>yMax) yMax=v;
          hasData=true;
        }
      }
    });
    if(!hasData){ yMin=20; yMax=80; }

    // A second scale for anything on the right-hand axis — fan RPM. It cannot
    // share the temperature axis: 3500 rpm on a 30-50 degree scale is not a
    // line, it is a claim that the chart is broken. Autoscaled over the
    // VISIBLE slice like the left axis, so zooming into a quiet stretch
    // fills it.
    let rMax=0, hasR=false;
    _series.forEach(s=>{
      if(s.hidden||s.axis!=='right') return;
      for(let i=start;i<=end;i++){
        const v=s.data[i];
        if(v!=null&&v>rMax){ rMax=v; }
        if(v!=null) hasR=true;
      }
    });
    _rMax = hasR ? (rMax>0 ? Math.ceil(rMax/500)*500 : 1000) : 0;
    if(TH.warn >= yMin && TH.warn <= yMax + 5) yMax=Math.max(yMax, TH.warn+2);
    if(TH.crit >= yMin && TH.crit <= yMax + 5) yMax=Math.max(yMax, TH.crit+2);
    yMin=Math.max(0,yMin-3);
    if(yMax<=yMin) yMax=yMin+10;
    const rng=yMax-yMin, mag=Math.pow(10,Math.floor(Math.log10(rng)));
    const step=rng/mag>5?mag*2:mag;
    yMax=Math.ceil(yMax/step)*step; yMin=Math.floor(yMin/step)*step;
    _yMin=yMin; _yMax=yMax;
    const vLen=end-start;
    _toX=i=>PAD.left+((i-start)/Math.max(vLen,1))*pw;
    _toY=v=>PAD.top+(1-(v-_yMin)/(_yMax-_yMin))*ph;
    _toYR=v=>PAD.top+(1-(v/(_rMax||1)))*ph;
    return {W,H,pw,ph};
  }

  function drawThresholdLine(y, color, label) {
    if(_yMin==null||_yMax==null) return;
    if(y<_yMin||y>_yMax) return;
    const W=canvas.width/devicePixelRatio;
    const rightPad = PAD.right + (hasRightAxis() ? PAD_R_AXIS : 0);
    const py=_toY(y);
    ctx.save();
    ctx.setLineDash([5,5]);
    ctx.strokeStyle=color;
    ctx.lineWidth=1;
    ctx.globalAlpha=0.5;
    ctx.beginPath();
    ctx.moveTo(PAD.left, py);
    ctx.lineTo(W-rightPad, py);
    ctx.stroke();
    ctx.setLineDash([]);
    ctx.globalAlpha=0.7;
    ctx.font='9px monospace';
    ctx.fillStyle=color;
    ctx.textAlign='left';
    ctx.fillText(label, PAD.left+3, py-3);
    ctx.restore();
  }

  function draw() {
    const {W,H,pw,ph}=computeScale();
    ctx.clearRect(0,0,W,H);
    if(!_labels.length||!_series.length) return;
    const gridC='rgba(128,128,128,0.12)', tickC='rgba(128,128,128,0.6)';

    for(let i=0;i<=GRID;i++){
      const y=PAD.top+(ph/GRID)*i, val=_yMax-((_yMax-_yMin)/GRID)*i;
      ctx.strokeStyle=gridC; ctx.lineWidth=1;
      ctx.beginPath(); ctx.moveTo(PAD.left,y); ctx.lineTo(PAD.left+pw,y); ctx.stroke();
      ctx.fillStyle=tickC; ctx.font='10px monospace'; ctx.textAlign='right';
      ctx.fillText(Math.round(val)+'°', PAD.left-5, y+3.5);
    }

    const {start,end}=viewSlice();
    const vLen=end-start+1;
    const sx=Math.max(1,Math.ceil(vLen/6));
    ctx.textAlign='center';
    for(let i=start;i<=end;i+=sx){
      const ts=_labels[i]; if(!ts) continue;
      const d=new Date(ts*1000);
      const hh=String(d.getHours()).padStart(2,'0'), mm=String(d.getMinutes()).padStart(2,'0');
      ctx.fillStyle=tickC;
      ctx.fillText(hh+':'+mm, _toX(i), H-24);
      ctx.fillStyle='rgba(128,128,128,0.38)';
      ctx.fillText(d.getDate()+' '+MONTHS[d.getMonth()], _toX(i), H-10);
    }

    drawThresholdLine(TH.warn, '#c87f0a', 'WARN '+TH.warn+'°');
    drawThresholdLine(TH.crit, '#b5261e', 'CRIT '+TH.crit+'°');

    // Right-axis series first, under the temperatures: the fan is context for
    // the temperature, not the subject. No area fill — two filled scales
    // stacked on one plot is unreadable.
    if(hasRightAxis()&&_toYR){
      _series.forEach(s=>{
        if(s.hidden||s.axis!=='right') return;
        ctx.beginPath(); let go=false;
        for(let i=start;i<=end;i++){
          const v=s.data[i];
          if(v==null){go=false;continue;}
          go?ctx.lineTo(_toX(i),_toYR(v)):(ctx.moveTo(_toX(i),_toYR(v)),go=true);
        }
        // Solid, but thinner than a sensor line. It was dashed, on the theory
        // that a different axis wants a different stroke; on a plot this dense
        // the dashes just read as a rendering fault. Weight and colour carry
        // the distinction instead, and the right-hand rpm scale states it.
        ctx.strokeStyle=s.color; ctx.lineWidth=1.4;
        ctx.stroke();
      });

      // Right-hand scale, labelled so nobody reads 3500 as degrees.
      ctx.fillStyle=tickC; ctx.font='9px monospace'; ctx.textAlign='left';
      for(let i=0;i<=2;i++){
        const frac=i/2, y=PAD.top+ph*(1-frac);
        ctx.fillText(String(Math.round(_rMax*frac)), PAD.left+pw+6, y+3);
      }
      ctx.fillStyle='rgba(128,128,128,0.5)';
      ctx.fillText('rpm', PAD.left+pw+6, PAD.top-3);
      ctx.textAlign='center';
    }

    _series.forEach(s=>{
      if(s.hidden||s.axis==='right') return;
      // Single pass to find first/last valid index — replaces two separate scans
      let fi=-1, li=-1;
      for(let i=start;i<=end;i++){
        if(s.data[i]!=null&&s.data[i]>0){ if(fi<0) fi=i; li=i; }
      }
      if(fi<0) return;

      ctx.beginPath(); let go=false;
      for(let i=start;i<=end;i++){
        const v=s.data[i];
        if(!v||v<=0){go=false;continue;}
        go?ctx.lineTo(_toX(i),_toY(v)):(ctx.moveTo(_toX(i),_toY(v)),go=true);
      }
      ctx.lineTo(_toX(li),_toY(_yMin)); ctx.lineTo(_toX(fi),_toY(_yMin)); ctx.closePath();
      const g=ctx.createLinearGradient(0,PAD.top,0,PAD.top+ph);
      g.addColorStop(0,s.rgba18); g.addColorStop(1,s.rgba01);
      ctx.fillStyle=g; ctx.fill();

      ctx.beginPath(); go=false;
      for(let i=start;i<=end;i++){
        const v=s.data[i];
        if(!v||v<=0){go=false;continue;}
        go?ctx.lineTo(_toX(i),_toY(v)):(ctx.moveTo(_toX(i),_toY(v)),go=true);
      }
      ctx.strokeStyle=s.color; ctx.lineWidth=2; ctx.stroke();
    });

    if(_dragAnchorPx!==null&&_dragCurPx!==null){
      const x0=Math.max(PAD.left,Math.min(_dragAnchorPx,_dragCurPx));
      const x1=Math.min(W-PAD.right,Math.max(_dragAnchorPx,_dragCurPx));
      ctx.save();
      ctx.fillStyle='rgba(80,130,255,0.12)';
      ctx.fillRect(x0,PAD.top,x1-x0,ph);
      ctx.strokeStyle='rgba(80,130,255,0.4)';
      ctx.lineWidth=1;
      ctx.strokeRect(x0,PAD.top,x1-x0,ph);
      ctx.restore();
    }
  }

  function drawCrosshair(idx) {
    if(!_toX||!_toY) return;
    const H=canvas.height/devicePixelRatio;
    const x=_toX(idx);
    ctx.save();
    ctx.strokeStyle='rgba(200,200,200,0.25)'; ctx.lineWidth=1;
    ctx.setLineDash([3,4]);
    ctx.beginPath(); ctx.moveTo(x,PAD.top); ctx.lineTo(x,H-PAD.bottom); ctx.stroke();
    ctx.setLineDash([]);
    _series.forEach(s=>{
      if(s.hidden) return;
      if(s.axis==='right'){
        const rv=s.data[idx];
        if(rv==null||!_toYR) return;
        ctx.beginPath(); ctx.arc(x,_toYR(rv),3.5,0,Math.PI*2);
        ctx.fillStyle=s.color; ctx.fill();
        return;
      }
      const v=s.data[idx]; if(!v||v<=0) return;
      ctx.beginPath(); ctx.arc(x,_toY(v),4,0,Math.PI*2);
      ctx.fillStyle=s.color; ctx.fill();
      ctx.strokeStyle='rgba(0,0,0,0.3)'; ctx.lineWidth=1.5; ctx.stroke();
    });
    ctx.restore();
  }

  function pxToIdx(clientX, rect) {
    const {start,end}=viewSlice();
    const pw=rect.width-PAD.left-PAD.right;
    if(!(pw>0)) return start;
    const vLen=end-start;
    const rel=clientX-rect.left-PAD.left;
    return start+Math.max(0,Math.min(vLen,Math.round(rel/pw*vLen)));
  }

  canvas.addEventListener('mousedown', e=>{
    if(e.button!==0||!_labels.length) return;
    const r=canvas.getBoundingClientRect();
    _dragAnchorPx=e.clientX-r.left;
    _dragCurPx=_dragAnchorPx;
  });

  canvas.addEventListener('mousemove', e=>{
    if(!_labels.length||!_toX) return;
    const r=canvas.getBoundingClientRect();
    const px=e.clientX-r.left;

    if(_dragAnchorPx!==null){
      _dragCurPx=px;
      scheduleDraw(pxToIdx(e.clientX,r));
      tip.style.display='none';
      return;
    }

    const idx=pxToIdx(e.clientX,r);
    scheduleDraw(idx);

    // Tooltip content/position stay synchronous — they are cheap, and
    // deferring them to the next frame makes the tooltip lag the cursor.
    let html='<div style="margin-bottom:4px;color:var(--th-dim);font-size:10.5px">'+escHtml(fmtDT(_labels[idx]))+'</div>';
    _series.forEach(s=>{
      if(s.hidden) return;
      const v=s.data[idx];
      const txt = (s.axis==='right')
        ? '<strong>'+escHtml(fmtRpm(v))+'</strong>'
        : (v&&v>0?'<strong>'+parseFloat(v).toFixed(1)+'°C</strong>':'—');
      html+='<div><span style="color:'+escHtml(s.color)+'">●</span> '
          +'<span style="color:var(--th-dim)">'+escHtml(s.label)+'</span> '
          +txt+'</div>';
    });
    tip.innerHTML=html; tip.style.display='block';
    const tw=tip.offsetWidth, th2=tip.offsetHeight;
    let tx=e.clientX+16, ty=e.clientY-th2/2;
    if(tx+tw+10>window.innerWidth) tx=e.clientX-tw-16;
    ty=Math.max(8,Math.min(ty,window.innerHeight-th2-8));
    tip.style.left=tx+'px'; tip.style.top=ty+'px';
  });

  canvas.addEventListener('mouseup', e=>{
    if(_dragAnchorPx===null) return;
    const r=canvas.getBoundingClientRect();
    const endPx=e.clientX-r.left;
    const dx=Math.abs(endPx-_dragAnchorPx);

    if(dx>12&&_labels.length>4){
      const {start,end}=viewSlice();
      const vLen=end-start;
      const pw=r.width-PAD.left-PAD.right;
      if(pw>0){
        const relA=_dragAnchorPx-PAD.left, relB=endPx-PAD.left;
        const i0=start+Math.max(0,Math.min(vLen,Math.round(Math.min(relA,relB)/pw*vLen)));
        const i1=start+Math.max(0,Math.min(vLen,Math.round(Math.max(relA,relB)/pw*vLen)));
        if(i1-i0>=2){
          _zoomStart=i0; _zoomEnd=i1;
          if(resetBtn) resetBtn.style.display='block';
        }
      }
    }
    _dragAnchorPx=null; _dragCurPx=null;
    scheduleDraw();
  });

  canvas.addEventListener('mouseleave',()=>{
    tip.style.display='none';
    if(_dragAnchorPx!==null){ _dragAnchorPx=null; _dragCurPx=null; }
    scheduleDraw();
  });

  canvas.addEventListener('dblclick',()=>{
    _zoomStart=null; _zoomEnd=null;
    if(resetBtn) resetBtn.style.display='none';
    document.querySelectorAll('.th-range-btn').forEach((b,i)=>{
      b.className='th-range-btn'+(i===2?' th-active':'');
    });
    scheduleDraw();
  });

  const _roTemp = new ResizeObserver(()=>{ resize(); scheduleDraw(); });
  _roTemp.observe(canvas.parentElement);
  resize();

  return {
    update(labels, series) {
      _labels=labels; _series=series;
      if(_zoomStart!==null){
        _zoomStart=Math.max(0,Math.min(_zoomStart,labels.length-2));
        _zoomEnd=Math.max(_zoomStart+1,Math.min(_zoomEnd,labels.length-1));
      }
      draw();
    },
    resetZoom() {
      _zoomStart=null; _zoomEnd=null;
      if(resetBtn) resetBtn.style.display='none';
      draw();
    },
    zoomTo(secsAgo) {
      if(!_labels.length) return;
      if(!secsAgo){ _zoomStart=null; _zoomEnd=null; if(resetBtn) resetBtn.style.display='none'; draw(); return; }
      const cutoff = (_labels[_labels.length-1]) - secsAgo;
      let start=0;
      for(let i=0;i<_labels.length;i++){ if(_labels[i]>=cutoff){ start=i; break; } }
      _zoomStart=start; _zoomEnd=_labels.length-1;
      if(resetBtn) resetBtn.style.display='block';
      draw();
    },
    destroy() {
      if(_rafId!==null){ cancelAnimationFrame(_rafId); _rafId=null; }
      _roTemp.disconnect();
    }
  };
}

// ── Uptime chart (simplified, no zoom) ───────────────────────────────────
function makeUptimeChart(canvas, tip) {
  const ctx = canvas.getContext('2d');
  const PAD = { top:8, right:14, bottom:36, left:52 };
  let _pts=[];
  let _toX, _toY, _yMax;

  // Uptime rises monotonically between reboots, so ANY decrease is a reboot.
  // The old test (u < prev.u * 0.5) missed every reboot where the router had
  // been up less than twice the sample gap — e.g. up 20 min, reboot, up 15 min.
  // The 60s slack absorbs clock adjustments without producing false marks.
  function isReboot(cur, prev) { return cur.u < prev.u - 60; }

  function resize() {
    const r=canvas.parentElement.getBoundingClientRect();
    canvas.width =Math.max(1, r.width *devicePixelRatio);
    canvas.height=Math.max(1, r.height*devicePixelRatio);
    ctx.setTransform(devicePixelRatio,0,0,devicePixelRatio,0,0);
  }

  function fmtUptime(secs) {
    if(secs<3600)  return Math.round(secs/60)+'m';
    if(secs<86400) return (secs/3600).toFixed(1)+'h';
    return (secs/86400).toFixed(1)+'d';
  }

  function draw() {
    const W=canvas.width/devicePixelRatio, H=canvas.height/devicePixelRatio;
    const pw=W-PAD.left-PAD.right, ph=H-PAD.top-PAD.bottom;
    ctx.clearRect(0,0,W,H);
    if(!_pts.length) return;

    // Single-pass max — avoids spread-onto-stack (stack overflow risk for
    // large arrays) and eliminates the intermediate allU array allocation.
    let uMax=3600;
    for(let j=0;j<_pts.length;j++) if(_pts[j].u>uMax) uMax=_pts[j].u;
    _yMax=uMax;

    const len=_pts.length;
    _toX=i=>PAD.left+(i/Math.max(len-1,1))*pw;
    _toY=u=>PAD.top+(1-(u/_yMax))*ph;

    const tickC='rgba(128,128,128,0.6)', gridC='rgba(128,128,128,0.10)';

    for(let i=0;i<=2;i++){
      const frac=i/2, y=PAD.top+ph*(1-frac), val=_yMax*frac;
      ctx.strokeStyle=gridC; ctx.lineWidth=1;
      ctx.beginPath(); ctx.moveTo(PAD.left,y); ctx.lineTo(PAD.left+pw,y); ctx.stroke();
      ctx.fillStyle=tickC; ctx.font='9px monospace'; ctx.textAlign='right';
      ctx.fillText(fmtUptime(val), PAD.left-4, y+3);
    }

    ctx.textAlign='center';
    const sx=Math.max(1,Math.ceil(len/4));
    for(let i=0;i<len;i+=sx){
      const d=new Date(_pts[i].ts*1000);
      const hh=String(d.getHours()).padStart(2,'0'), mm=String(d.getMinutes()).padStart(2,'0');
      ctx.fillStyle=tickC; ctx.font='9px monospace';
      ctx.fillText(hh+':'+mm, _toX(i), H-18);
      ctx.fillStyle='rgba(128,128,128,0.38)';
      ctx.fillText(d.getDate()+' '+MONTHS[d.getMonth()], _toX(i), H-6);
    }

    ctx.beginPath();
    let go=false;
    for(let i=0;i<_pts.length;i++){
      const u=_pts[i].u;
      if(i>0&&isReboot(_pts[i],_pts[i-1])){ go=false; }
      go?ctx.lineTo(_toX(i),_toY(u)):(ctx.moveTo(_toX(i),_toY(u)),go=true);
    }
    ctx.strokeStyle='#7c9cbf'; ctx.lineWidth=1.5; ctx.stroke();

    ctx.save();
    ctx.setLineDash([3,3]);
    ctx.strokeStyle='rgba(180,80,80,0.5)';
    ctx.lineWidth=1;
    for(let i=1;i<_pts.length;i++){
      if(isReboot(_pts[i],_pts[i-1])){
        ctx.beginPath();
        ctx.moveTo(_toX(i),PAD.top);
        ctx.lineTo(_toX(i),PAD.top+ph);
        ctx.stroke();
      }
    }
    ctx.setLineDash([]);
    ctx.restore();
  }

  canvas.addEventListener('mousemove', e=>{
    if(!_pts.length||!_toX) return;
    const r=canvas.getBoundingClientRect();
    const pw=r.width-PAD.left-PAD.right;
    if(!(pw>0)) return;
    const idx=Math.max(0,Math.min(_pts.length-1,
      Math.round((e.clientX-r.left-PAD.left)/pw*(_pts.length-1))));
    const pt=_pts[idx];
    if(!pt) return;
    const uStr=fmtUptimeLong(pt.u);
    tip.innerHTML='<div style="margin-bottom:2px;color:var(--th-dim);font-size:10.5px">'+escHtml(fmtDT(pt.ts))+'</div>'
      +'<div>⏱ Uptime <strong>'+escHtml(uStr)+'</strong></div>';
    tip.style.display='block';
    const tw=tip.offsetWidth, th2=tip.offsetHeight;
    let tx=e.clientX+16, ty=e.clientY-th2/2;
    if(tx+tw+10>window.innerWidth) tx=e.clientX-tw-16;
    ty=Math.max(8,Math.min(ty,window.innerHeight-th2-8));
    tip.style.left=tx+'px'; tip.style.top=ty+'px';
  });
  canvas.addEventListener('mouseleave',()=>{ tip.style.display='none'; });

  const _roUptime = new ResizeObserver(()=>{ resize(); draw(); });
  _roUptime.observe(canvas.parentElement);
  resize();

  return {
    update(pts){ _pts=pts||[]; resize(); draw(); },
    destroy() { _roUptime.disconnect(); }
  };
}

// ── Fan RPM chart ─────────────────────────────────────────────────────────
// Multi-series like the temperature chart but without zoom, and with a floor
// of 0 rather than an auto-scaled minimum: a fan dropping to zero is the
// signal you want to see, and a min-scaled axis would hide it.
// One line chart, used for both the fan RPM series and the CPU/memory series.
// They differ only in the y-axis and how a value is spelled in the tooltip, so
// those are options rather than a second near-identical 110-line copy.
//
//   fmt        how a value reads in the tooltip
//   fixedMax   pin the axis (100 for percentages); null autoscales
//   stepRound  autoscale granularity, ignored when fixedMax is set
//   ticks      how many horizontal gridlines
function makeLineChart(canvas, tip, opts) {
  const O = opts || {};
  const FMT   = O.fmt || fmtRpm;
  const STEP  = O.stepRound || 500;
  const TICKS = O.ticks || 2;
  const RESET = O.resetBtn || null;
  const ctx = canvas.getContext('2d');
  const PAD = { top:10, right:14, bottom:36, left:52 };
  let _labels=[], _series=[], _toX, _toY, _yMax=O.fixedMax || STEP*2;
  let _rafId=null, _hover=null;
  // Drag to zoom, double-click to reset — the same interaction the
  // temperature chart has. Indices into _labels, null when showing everything.
  let _zoomStart=null, _zoomEnd=null;
  let _dragAnchorPx=null, _dragCurPx=null;

  function viewSlice() {
    if (_zoomStart !== null && _zoomEnd !== null)
      return { start:_zoomStart, end:_zoomEnd };
    return { start:0, end:Math.max(0, _labels.length-1) };
  }
  function showReset(on) { if (RESET) RESET.style.display = on ? 'block' : 'none'; }
  function pxToIdx(clientX, r) {
    const { start, end } = viewSlice();
    const pw = r.width - PAD.left - PAD.right;
    if (!(pw > 0)) return start;
    const rel = clientX - r.left - PAD.left;
    return start + Math.max(0, Math.min(end-start, Math.round(rel/pw*(end-start))));
  }

  function resize() {
    const r=canvas.parentElement.getBoundingClientRect();
    canvas.width =Math.max(1, r.width *devicePixelRatio);
    canvas.height=Math.max(1, r.height*devicePixelRatio);
    ctx.setTransform(devicePixelRatio,0,0,devicePixelRatio,0,0);
  }
  function scheduleDraw(h) {
    _hover = (h === undefined) ? null : h;
    if (_rafId !== null) return;
    _rafId = requestAnimationFrame(()=>{ _rafId=null; draw(); if(_hover!==null) crosshair(_hover); });
  }

  function draw() {
    const W=canvas.width/devicePixelRatio, H=canvas.height/devicePixelRatio;
    const pw=W-PAD.left-PAD.right, ph=H-PAD.top-PAD.bottom;
    ctx.clearRect(0,0,W,H);
    if(!_labels.length||!_series.length) return;

    const {start,end}=viewSlice();
    const vLen=end-start;

    // Autoscale over the VISIBLE slice, not the whole series — zooming into a
    // quiet stretch of a fan chart should fill the axis with it, not leave it
    // flat at the bottom because of a spike somewhere off-screen. A pinned
    // axis (percentages) ignores this by design.
    let mx=0;
    _series.forEach(s=>{ if(s.hidden) return;
      for(let i=start;i<=end;i++){ const v=s.data[i]; if(v!=null&&v>mx) mx=v; } });
    _yMax = (O.fixedMax != null) ? O.fixedMax
          : (mx>0 ? Math.ceil(mx/STEP)*STEP : STEP*2);

    const len=_labels.length;
    _toX=i=>PAD.left+((i-start)/Math.max(vLen,1))*pw;
    _toY=v=>PAD.top+(1-(v/_yMax))*ph;

    const tickC='rgba(128,128,128,0.6)', gridC='rgba(128,128,128,0.10)';
    for(let i=0;i<=TICKS;i++){
      const frac=i/TICKS, y=PAD.top+ph*(1-frac);
      ctx.strokeStyle=gridC; ctx.lineWidth=1;
      ctx.beginPath(); ctx.moveTo(PAD.left,y); ctx.lineTo(PAD.left+pw,y); ctx.stroke();
      ctx.fillStyle=tickC; ctx.font='9px monospace'; ctx.textAlign='right';
      ctx.fillText(Math.round(_yMax*frac), PAD.left-4, y+3);
    }
    ctx.textAlign='center';
    const sx=Math.max(1,Math.ceil((vLen+1)/4));
    for(let i=start;i<=end;i+=sx){
      const d=new Date(_labels[i]*1000);
      const hh=String(d.getHours()).padStart(2,'0'), mm=String(d.getMinutes()).padStart(2,'0');
      ctx.fillStyle=tickC; ctx.font='9px monospace';
      ctx.fillText(hh+':'+mm, _toX(i), H-18);
      ctx.fillStyle='rgba(128,128,128,0.38)';
      ctx.fillText(d.getDate()+' '+MONTHS[d.getMonth()], _toX(i), H-6);
    }

    _series.forEach(s=>{
      if(s.hidden) return;
      ctx.beginPath(); let go=false;
      for(let i=start;i<=end;i++){
        const v=s.data[i];
        // null = no reading (no tachometer; or, for CPU, the first sample
        // after a reboot with no baseline to subtract from) — break the line.
        // 0 is a REAL value, plotted on the floor: a stopped fan and an idle
        // CPU are both exactly the thing worth being able to see.
        if(v==null){ go=false; continue; }
        go?ctx.lineTo(_toX(i),_toY(v)):(ctx.moveTo(_toX(i),_toY(v)),go=true);
      }
      ctx.strokeStyle=s.color; ctx.lineWidth=1.8; ctx.stroke();
    });

    // The drag selection, painted last so it sits over the lines.
    if(_dragAnchorPx!==null&&_dragCurPx!==null){
      const x0=Math.max(PAD.left,Math.min(_dragAnchorPx,_dragCurPx));
      const x1=Math.min(W-PAD.right,Math.max(_dragAnchorPx,_dragCurPx));
      if(x1>x0){
        ctx.fillStyle=getComputedStyle(document.documentElement)
          .getPropertyValue('--th-sel-bg')||'rgba(80,130,255,0.15)';
        ctx.fillRect(x0,PAD.top,x1-x0,ph);
        ctx.strokeStyle=getComputedStyle(document.documentElement)
          .getPropertyValue('--th-sel-bd')||'rgba(80,130,255,0.45)';
        ctx.lineWidth=1;
        ctx.strokeRect(x0+0.5,PAD.top+0.5,x1-x0-1,ph-1);
      }
    }
  }

  function crosshair(idx) {
    if(!_toX||!_toY) return;
    const sl=viewSlice();
    if(idx<sl.start||idx>sl.end) return;
    const H=canvas.height/devicePixelRatio;
    const x=_toX(idx);
    ctx.save();
    ctx.strokeStyle='rgba(200,200,200,0.25)'; ctx.lineWidth=1; ctx.setLineDash([3,4]);
    ctx.beginPath(); ctx.moveTo(x,PAD.top); ctx.lineTo(x,H-PAD.bottom); ctx.stroke();
    ctx.setLineDash([]);
    _series.forEach(s=>{
      if(s.hidden) return;
      const v=s.data[idx]; if(v==null) return;
      ctx.beginPath(); ctx.arc(x,_toY(v),3.5,0,Math.PI*2);
      ctx.fillStyle=s.color; ctx.fill();
    });
    ctx.restore();
  }

  canvas.addEventListener('mousedown', e=>{
    if(e.button!==0||!_labels.length) return;
    const r=canvas.getBoundingClientRect();
    _dragAnchorPx=e.clientX-r.left;
    _dragCurPx=_dragAnchorPx;
  });

  canvas.addEventListener('mouseup', e=>{
    if(_dragAnchorPx===null) return;
    const r=canvas.getBoundingClientRect();
    const endPx=e.clientX-r.left;
    const dx=Math.abs(endPx-_dragAnchorPx);

    // A short drag is a click, not a selection, and a selection narrower than
    // three points is not a chart.
    if(dx>12&&_labels.length>4){
      const {start,end}=viewSlice();
      const vLen=end-start;
      const pw=r.width-PAD.left-PAD.right;
      if(pw>0){
        const relA=_dragAnchorPx-PAD.left, relB=endPx-PAD.left;
        const i0=start+Math.max(0,Math.min(vLen,Math.round(Math.min(relA,relB)/pw*vLen)));
        const i1=start+Math.max(0,Math.min(vLen,Math.round(Math.max(relA,relB)/pw*vLen)));
        if(i1-i0>=2){ _zoomStart=i0; _zoomEnd=i1; showReset(true); }
      }
    }
    _dragAnchorPx=null; _dragCurPx=null;
    scheduleDraw();
  });

  canvas.addEventListener('dblclick', ()=>{
    _zoomStart=null; _zoomEnd=null; showReset(false);
    scheduleDraw();
  });

  canvas.addEventListener('mousemove', e=>{
    if(!_labels.length||!_toX) return;
    const r=canvas.getBoundingClientRect();
    const pw=r.width-PAD.left-PAD.right;
    if(!(pw>0)) return;

    if(_dragAnchorPx!==null){
      _dragCurPx=e.clientX-r.left;
      scheduleDraw(pxToIdx(e.clientX,r));
      tip.style.display='none';
      return;
    }

    const idx=pxToIdx(e.clientX,r);
    scheduleDraw(idx);
    let html='<div style="margin-bottom:4px;color:var(--th-dim);font-size:10.5px">'+escHtml(fmtDT(_labels[idx]))+'</div>';
    _series.forEach(s=>{
      if(s.hidden) return;
      html+='<div><span style="color:'+escHtml(s.color)+'">●</span> '
          +'<span style="color:var(--th-dim)">'+escHtml(s.label)+'</span> '
          +'<strong>'+escHtml(FMT(s.data[idx]))+'</strong></div>';
    });
    tip.innerHTML=html; tip.style.display='block';
    const tw=tip.offsetWidth, th2=tip.offsetHeight;
    let tx=e.clientX+16, ty=e.clientY-th2/2;
    if(tx+tw+10>window.innerWidth) tx=e.clientX-tw-16;
    ty=Math.max(8,Math.min(ty,window.innerHeight-th2-8));
    tip.style.left=tx+'px'; tip.style.top=ty+'px';
  });
  canvas.addEventListener('mouseleave',()=>{
    tip.style.display='none';
    // Abandon a drag that left the canvas, or the selection stays painted and
    // the next click zooms to somewhere the pointer never was.
    if(_dragAnchorPx!==null){ _dragAnchorPx=null; _dragCurPx=null; }
    scheduleDraw();
  });

  const _ro = new ResizeObserver(()=>{ resize(); scheduleDraw(); });
  _ro.observe(canvas.parentElement);
  resize();

  return {
    update(labels, series){
      _labels=labels||[]; _series=series||[];
      // A refresh arrives every ten minutes and the series grows. Clamp an
      // existing zoom into the new bounds rather than dropping it, or the
      // chart silently jumps back to full range while someone is reading it.
      if(_zoomStart!==null){
        if(_labels.length<4){ _zoomStart=null; _zoomEnd=null; showReset(false); }
        else {
          _zoomStart=Math.max(0,Math.min(_zoomStart,_labels.length-2));
          _zoomEnd=Math.max(_zoomStart+1,Math.min(_zoomEnd,_labels.length-1));
        }
      }
      resize(); draw();
    },
    // Driven by the 24h / 7d / 30d buttons, so one click sets every chart on
    // the page to the same window. By TIMESTAMP, not index: these series do
    // not all have the same number of points — sys-history.tsv starts the day
    // the package is upgraded, while the temperatures go back a month — so
    // sharing an index would line up two different moments.
    zoomTo(secsAgo){
      if(!_labels.length) return;
      if(!secsAgo){ _zoomStart=null; _zoomEnd=null; showReset(false); draw(); return; }
      const cutoff=(_labels[_labels.length-1]||0)-secsAgo;
      let i=0;
      while(i<_labels.length-2&&_labels[i]<cutoff) i++;
      if(i>=_labels.length-2){ _zoomStart=null; _zoomEnd=null; showReset(false); draw(); return; }
      _zoomStart=i; _zoomEnd=_labels.length-1;
      showReset(true);
      draw();
    },
    resetZoom(){ _zoomStart=null; _zoomEnd=null; showReset(false); draw(); },
    destroy(){ if(_rafId!==null){ cancelAnimationFrame(_rafId); _rafId=null; } _ro.disconnect(); }
  };
}

// Percentages, so the axis is pinned to 0-100. Autoscaling it would make a
// router idling at 3% look identical to one pinned at 100%, which is the
// opposite of what this chart is for.
function makeSysChart(canvas, tip, resetBtn) {
  return makeLineChart(canvas, tip, { fmt: fmtPct, fixedMax: 100, ticks: 4, resetBtn });
}

// ── View ──────────────────────────────────────────────────────────────────
return view.extend({
  _chart: null,
  _uptimeChart: null,
  _tip: null,
  _series: [],
  _labels: [],    // kept in sync with chart labels; used by legend click handler
  _statusEls: null,
  _flushBusy: false,
  _pollFn: null,  // the poll callback itself — poll.remove() matches on it
  _initRaf: null,
  _destroyed: false,
  _bannerEl: null,
  _sysChart: null,
  _sysEls: null,
  _fanEls: null,
  _fanBusy: false,

  fetchFull() {
    return request.get(CGI_URL, { timeout: 15000 })
      .then(r=>{ if(!r.ok) throw new Error('HTTP '+r.status); return r.json(); });
  },

  fetchLive() {
    return request.get(CGI_URL + '?live=1', { timeout: 6000 })
      .then(r=>{ if(!r.ok) throw new Error('HTTP '+r.status); return r.json(); });
  },

  // ── Mutating operations ────────────────────────────────────────────────
  // ubus first: luci.temp-status.flush / .reset are rpcd write methods, so
  // they run behind LuCI's session — the only authenticated path this package
  // has. The CGI equivalents are unauthenticated by construction and are
  // gated off automatically wherever these methods exist (see the CGI's
  // cgi_write=auto logic), so the fallback below only ever fires on routers
  // with no ucode, i.e. OpenWrt 21.02.
  callFlush: rpc.declare({
    object: 'luci.temp-status',
    method: 'flush',
    expect: { '': {} }
  }),

  callReset: rpc.declare({
    object: 'luci.temp-status',
    method: 'reset',
    params: [ 'sensor' ],
    expect: { '': {} }
  }),

  // OpenWrt 21.02 has no ucode, so luci.temp-status never registers there.
  // luci.temp-history is an rpcd SHELL plugin providing the same two mutating
  // methods; rpcd has supported those since long before ucode, so it exists on
  // every version. Same LuCI session, same ACL — this is what makes 21.02
  // authenticated rather than falling through to the unauthenticated CGI.
  callFlushCompat: rpc.declare({
    object: 'luci.temp-history',
    method: 'flush',
    expect: { '': {} }
  }),

  callResetCompat: rpc.declare({
    object: 'luci.temp-history',
    method: 'reset',
    params: [ 'sensor' ],
    expect: { '': {} }
  }),

  // Its own method and its own cutoff file: `reset` is keyed by sensor index,
  // and a system column numbered 0 would silently share sensor 0.
  callResetSys: rpc.declare({
    object: 'luci.temp-status', method: 'resetSys',
    params: [ 'col' ], expect: { '': {} }
  }),
  callResetSysCompat: rpc.declare({
    object: 'luci.temp-history', method: 'resetSys',
    params: [ 'col' ], expect: { '': {} }
  }),

  callSetFan: rpc.declare({
    object: 'luci.temp-status', method: 'setFan',
    params: [ 'percent', 'minutes' ], expect: { '': {} }
  }),
  callAutoFan: rpc.declare({
    object: 'luci.temp-status', method: 'autoFan', expect: { '': {} }
  }),
  callSetFanCompat: rpc.declare({
    object: 'luci.temp-history', method: 'setFan',
    params: [ 'percent', 'minutes' ], expect: { '': {} }
  }),
  callAutoFanCompat: rpc.declare({
    object: 'luci.temp-history', method: 'autoFan', expect: { '': {} }
  }),

  // GL.iNet thermal setpoints. getSetpoints is a READ method, but it goes
  // through the same mutate() tier ladder as the writes rather than the CGI:
  // the CGI is unauthenticated, and the answer names the router's model and
  // firmware layout, which is not something to hand out unauthenticated for
  // the sake of saving one fork.
  callGetSetpoints: rpc.declare({
    object: 'luci.temp-status', method: 'getSetpoints', expect: { '': {} }
  }),
  callSetSetpoints: rpc.declare({
    object: 'luci.temp-status', method: 'setSetpoints',
    params: [ 'min', 'max' ], expect: { '': {} }
  }),
  callResetSetpoints: rpc.declare({
    object: 'luci.temp-status', method: 'resetSetpoints', expect: { '': {} }
  }),
  callGetSetpointsCompat: rpc.declare({
    object: 'luci.temp-history', method: 'getSetpoints', expect: { '': {} }
  }),
  callSetSetpointsCompat: rpc.declare({
    object: 'luci.temp-history', method: 'setSetpoints',
    params: [ 'min', 'max' ], expect: { '': {} }
  }),
  callResetSetpointsCompat: rpc.declare({
    object: 'luci.temp-history', method: 'resetSetpoints', expect: { '': {} }
  }),

  // Model and firmware. Read-only, but ubus rather than the CGI for the same
  // reason as the setpoints: /www/cgi-bin is unauthenticated, and a firmware
  // version is the first thing worth knowing if you are looking for a router
  // with a published CVE.
  callGetDevice: rpc.declare({
    object: 'luci.temp-status', method: 'getDevice', expect: { '': {} }
  }),
  callGetDeviceCompat: rpc.declare({
    object: 'luci.temp-history', method: 'getDevice', expect: { '': {} }
  }),

  // Logged thermal events. ubus-only, and for a stronger reason than the
  // others: this returns lines from the SYSTEM LOG, which is the one place on
  // a router where unrelated daemons write text nobody audited. Putting that
  // behind an unauthenticated CGI would be handing out a window into the whole
  // machine to anyone who can reach port 80.
  callGetEvents: rpc.declare({
    object: 'luci.temp-status', method: 'getEvents',
    params: [ 'limit' ], expect: { '': {} }
  }),
  callGetEventsCompat: rpc.declare({
    object: 'luci.temp-history', method: 'getEvents',
    params: [ 'limit' ], expect: { '': {} }
  }),

  _useCompat:   false,
  _useCgiWrite: false,

  // Only an actual rejection — object not registered — switches to the CGI,
  // and it is remembered for the page session so a 21.02 router is not
  // retrying a doomed ubus call on every click. A method that answers with
  // {status:"error"} answered fine; that is a result, not a missing backend.
  // No custom request header here on purpose. uhttpd only forwards a fixed
  // allowlist of headers to CGI scripts, so a custom header never
  // reached the script and the server-side check could never pass. The CGI
  // now authenticates the LuCI session from the cookie instead — which the
  // browser sends automatically on a same-origin request, and which LuCI
  // marks SameSite=Strict so a cross-site request cannot carry it.
  cgiMutation(query, timeout) {
    return request.request(CGI_URL + '?' + query, {
      method:  'POST',
      timeout: timeout || 10000
    }).then(r=>{
      // LuCI's Response.json() is SYNCHRONOUS — it is JSON.parse(this.text()),
      // returning a plain object and throwing on bad JSON. It is not a
      // promise, so it has no .catch(). Chaining .catch() onto it, which
      // threw TypeError on every call and made a completely successful flush
      // report "Flush failed" on any router using this fallback path.
      let body;
      try {
        body = r.json();
      } catch (e) {
        return { status: 'error', error: _('bad response from the server') + ' (HTTP ' + r.status + ')' };
      }
      if (!r.ok || (body && body.error))
        return { status: 'error', error: (body && body.error) || ('HTTP ' + r.status) };
      return body;
    });
  },

  // Three tiers, tried in order and remembered once one answers:
  //   1. luci.temp-status   — ucode plugin, 22.03+, authenticated
  //   2. luci.temp-history  — rpcd shell plugin, all versions, authenticated
  //   3. the CGI            — break-glass, unauthenticated, normally refused
  // Only an actual rejection (object not registered / access denied) moves
  // down a tier. A method answering {status:"error"} answered fine.
  mutate(kind, arg, timeout) {
    const query = (kind === 'flush')    ? 'flush=1'
                : (kind === 'resetSys') ? 'reset=sys'+encodeURIComponent(arg)
                :                         'reset='+encodeURIComponent(arg);

    // Fan control exists ONLY over ubus. There is deliberately no CGI verb
    // for it: the CGI is unauthenticated, and writing pwm_enable is not
    // something an unauthenticated endpoint should ever be able to do. The
    // setpoint methods are ubus-only for the same reason — they rewrite files
    // under /lib and /www.
    const primary = () => {
      switch (kind) {
        case 'flush':          return this.callFlush();
        case 'reset':          return this.callReset(arg);
        case 'resetSys':       return this.callResetSys(arg);
        case 'setFan':         return this.callSetFan(arg.percent, arg.minutes);
        case 'autoFan':        return this.callAutoFan();
        case 'getSetpoints':   return this.callGetSetpoints();
        case 'setSetpoints':   return this.callSetSetpoints(arg.min, arg.max);
        case 'resetSetpoints': return this.callResetSetpoints();
        case 'getDevice':      return this.callGetDevice();
        case 'getEvents':      return this.callGetEvents(arg || 60);
      }
    };
    const secondary = () => {
      switch (kind) {
        case 'flush':          return this.callFlushCompat();
        case 'reset':          return this.callResetCompat(arg);
        case 'resetSys':       return this.callResetSysCompat(arg);
        case 'setFan':         return this.callSetFanCompat(arg.percent, arg.minutes);
        case 'autoFan':        return this.callAutoFanCompat();
        case 'getSetpoints':   return this.callGetSetpointsCompat();
        case 'setSetpoints':   return this.callSetSetpointsCompat(arg.min, arg.max);
        case 'resetSetpoints': return this.callResetSetpointsCompat();
        case 'getDevice':      return this.callGetDeviceCompat();
        case 'getEvents':      return this.callGetEventsCompat(arg || 60);
      }
    };
    const isFan = (kind === 'setFan' || kind === 'autoFan');
    const isSetp = (kind === 'getSetpoints' || kind === 'setSetpoints' ||
                    kind === 'resetSetpoints');
    const isDev = (kind === 'getDevice');
    const isEvt = (kind === 'getEvents');
    const ubusOnly = isFan || isSetp || isDev || isEvt;

    if (this._useCgiWrite && !ubusOnly)
      return this.cgiMutation(query, timeout);

    const compat = ()=> {
      this._useCompat = true;
      return secondary().catch(()=>{
        if (isSetp)
          // Not an error the page should shout about: a router with no ubus
          // backend at all simply has no setpoint support, which is the same
          // outcome as a router that is not GL.iNet. The section stays hidden.
          return { supported: false, reason: 'no ubus backend' };
        if (isDev)
          // Same: the footer is decoration. An empty object draws nothing.
          return {};
        if (isEvt)
          // A router with no ubus backend cannot show events, and that is not
          // a failure worth a banner — the panel says so in its own body.
          return { supported: false, reason: _('needs the ubus backend'), events: [] };
        if (isFan)
          return { status:'error',
                   error: _('fan control needs the ubus backend — check `ubus list | grep temp`') };
        this._useCgiWrite = true;
        return this.cgiMutation(query, timeout);
      });
    };

    if (this._useCompat)
      return compat();
    return primary().catch(compat);
  },

  // The setpoint state rides along with the first payload rather than being
  // fetched after render: it decides whether a whole section of the Settings
  // panel exists, and building the panel twice would make it appear a moment
  // after the page settled. It is deliberately NOT re-fetched by the 60-second
  // poller — nothing changes it except this page.
  load() {
    return Promise.all([
      this.fetchFull().catch(e=>({ error: e.message })),
      this.mutate('getSetpoints', null, 8000)
          .catch(()=>({ supported: false, reason: 'unreachable' })),
      this.mutate('getDevice', null, 8000).catch(()=>({}))
    ]).then(([data, sp, dev])=>{
      if (data && !data.error) { data.setpoints = sp; data.device = dev; }
      return data;
    });
  },

  updateCards(data) {
    // Called with the 60s live payload AND the full one, which is exactly the
    // cadence the live tiles want.
    this.updateSysNow(data);
    this.updateUptimeNow(data);
    const { sensors=[], current=[], min=[], max=[], min_ts=[], max_ts=[], avg_today=[] } = data;
    sensors.forEach((name, i) => {
      const card = document.getElementById('th-card-'+i);
      if (!card) return;
      const v = parseFloat(current[i]) || 0;
      card.className = 'th-card' + (v>=TH.crit?' th-hot':v>=TH.warn?' th-warm':'');

      const valEl = card.querySelector('.th-val');
      if (valEl) {
        valEl.className = tempClass(v);
        valEl.title     = toDisp(current[i]) + ' °C';
        const num = valEl.querySelector('.th-val-num');
        if (num) num.textContent = toInt(current[i]);
      }

      const fill = card.querySelector('.th-bar-fill');
      if (fill) fill.style.width = Math.min(100,Math.max(0,(v-20)/80*100))+'%';

      if (min.length) {
        const hi = card.querySelector('.th-hi');
        if (hi) hi.innerHTML =
          '<span class="th-arrow-hi">↑</span> <strong>'+toDisp(max[i])+'°C</strong>'+
          '<span class="th-stat-ts">'+fmtDT(max_ts[i])+'</span>';
        const lo = card.querySelector('.th-lo');
        if (lo) lo.innerHTML =
          '<span class="th-arrow-lo">↓</span> <strong>'+toDisp(min[i])+'°C</strong>'+
          '<span class="th-stat-ts">'+fmtDT(min_ts[i])+'</span>';
      }

      const rp = card.querySelector('.th-rpm');
      if (rp && data.fan_rpm && data.fan_rpm.length) {
        // Fans are a separate list from sensors, so they hang off the first
        // card rather than pretending to belong to a particular sensor.
        rp.innerHTML = (data.fans || []).map((n, k) =>
          '<span class="th-rpm-icon">✱</span> ' + escHtml(n) + ' <strong>' +
          escHtml(fmtRpm(data.fan_rpm[k])) + '</strong>').join('<br>');
      }

      if (avg_today.length) {
        const av = card.querySelector('.th-av');
        if (av) av.innerHTML =
          '<span class="th-arrow-avg">~</span> <span style="color:var(--th-dim)">avg today</span> <strong>'+toDisp(avg_today[i])+'°C</strong>';
      }
    });
  },

  updateChart(data) {
    if (!this._chart || !data.history || !data.sensors) return;
    const labels = data.history.map(r=>r.ts);
    this._labels = labels;  // keep in sync so legend click handler uses fresh labels
    const hiddenMap = {};
    this._series.forEach(s=>{ hiddenMap[s.label]=s.hidden; });
    this._series = data.sensors.map((name,i)=>{
      const color = COLORS[i%COLORS.length];
      return {
        label:  name,
        color:  color,
        rgba18: h2rgba(color, 0.18),
        rgba01: h2rgba(color, 0.01),
        data:   data.history.map(r=>r.t&&r.t[i]>0?r.t[i]:null),
        hidden: hiddenMap[name]||false
      };
    });

    // Fan RPM on the SAME chart, against a right-hand axis. It used to have a
    // chart of its own below, which meant reading "the temperature rose and
    // the fan spun up" off two plots by eye. On one plot with a shared x-axis
    // it is a single glance — which is the entire question this page exists
    // to answer. Dashed and unfilled so it never reads as another sensor.
    //
    // The fan series is indexed by timestamp, not position: fan-history.tsv
    // and temp-history.tsv are downsampled on the same buckets but a router
    // that gained a fan later has fewer fan rows, and lining them up by index
    // would plot the fan against the wrong moments.
    const fanRows = data.fan_history || [];
    if (fanRows.length && data.fans && data.fans.length) {
      const byTs = {};
      fanRows.forEach(r => { byTs[r.ts] = r.r; });
      data.fans.forEach((name, k) => {
        const color = FAN_COLORS[k % FAN_COLORS.length];
        this._series.push({
          label:  name,
          color:  color,
          rgba18: h2rgba(color, 0.18),
          rgba01: h2rgba(color, 0.01),
          axis:   'right',
          unit:   'rpm',
          data:   labels.map(ts => {
            const row = byTs[ts];
            const v = row ? row[k] : null;
            return (v == null || v < 0) ? null : v;
          }),
          hidden: hiddenMap[name]||false
        });
      });
    }

    this._chart.update(labels, this._series);
    this._series.forEach((_,i)=>{
      const dot=document.getElementById('th-ldot-'+i);
      if(dot&&this._series[i]) dot.style.background=this._series[i].color;
      const item=document.getElementById('th-litem-'+i);
      if(item){
        item.className='th-legend-item'+(this._series[i].hidden?' th-hidden':'');
        item.setAttribute('aria-pressed', this._series[i].hidden ? 'false' : 'true');
      }
    });
  },

  // Live uptime, straight from /proc/uptime in the payload rather than derived
  // from the newest recorded sample plus elapsed time. That derivation is
  // correct right up until the router reboots, and then it reports days of
  // uptime for a machine that came up two minutes ago — precisely the moment
  // somebody is looking at this number.
  updateUptimeNow(data) {
    const el = this._uptimeNowEl;
    if (!el) return;
    const u = data ? data.uptime_now : null;
    // Absent on an older CGI still being served from a browser cache mid-
    // upgrade. Say nothing rather than printing "0m" for a router that has
    // been up for a fortnight.
    el.textContent = (u == null || u === '' || !(Number(u) >= 0))
      ? '' : '  ·  ' + _('up') + ' ' + fmtUptimeLong(u);
  },

  updateUptime(data) {
    if (!this._uptimeChart || !data.uptime) return;
    this._uptimeChart.update(data.uptime);
  },

  // Thresholds ride along with the full payload rather than needing their own
  // request. Live polls do not carry them (the CGI deliberately skips the uci
  // read on that 60-second path), so the last full payload's values stand.
  applyThresholds(data) {
    const w = parseFloat(data.warn), c = parseFloat(data.crit);
    let changed = false;
    if (!isNaN(w) && w > 0 && w !== TH.warn) { TH.warn = w; changed = true; }
    if (!isNaN(c) && c > 0 && c !== TH.crit) { TH.crit = c; changed = true; }
    return changed;
  },

  showBanner(text) {
    if (!this._bannerEl) return;
    this._bannerEl.textContent = text;
    this._bannerEl.style.display = text ? 'block' : 'none';
  },

  // Every problem worth reporting, gathered in one place and shown
  // TOGETHER. The old code called showBanner() several times and the last
  // call won, so a fan fault could be silently replaced by a schema note —
  // and which one you saw depended on the order of the ifs. Severity order:
  // hardware failing, then nothing being recorded, then the data being
  // misread.
  checkSchema(data) {
    const msgs = [];

    // A fan that was told to spin and is not spinning. The collector decides
    // this over consecutive samples, so it is not a spin-up artefact.
    const stalls = (data.fan_stall || []).filter(f => f && f.name);
    if (stalls.length) {
      const names = stalls.map(f => f.name).join(', ');
      const since = stalls[0].since ? ' ' + _('since') + ' ' + fmtDT(stalls[0].since) : '';
      msgs.push(_('FAN FAULT:') + ' ' + names + ' ' +
                _('is being driven but reports no rotation') + since +
                ' — ' + _('check for a blockage or a disconnected header.'));
    }

    // Nothing being recorded looks exactly like nothing happening: the chart
    // simply stops moving. The router's own clock is used, not the browser's,
    // because a desktop a few minutes out would otherwise cry wolf.
    const stale = this.sampleAge(data);
    if (stale !== null && stale > STALE_AFTER)
      msgs.push(_('Collection appears to have stopped:') + ' ' +
                _('the newest sample is') + ' ' + fmtAge(stale) + ' ' + _('old') +
                ' — ' + _('check that the 15-minute cron entry still exists (crontab -l).'));

    if (data.fan_schema === 'unreadable')
      msgs.push(_('fan-sensors.conf could not be read by the history CGI, so the page is showing no fan even if one exists. Run /usr/libexec/temp-history/fan-control.sh status over SSH to see the fan directly, and check logread.'));
    else if (data.fan_schema === 'mismatch')
      msgs.push(!(data.fans && data.fans.length)
        ? _('fan-history.tsv holds a recorded fan series, but no fan is listed in fan-sensors.conf any more — so nothing is being collected. If the fan is still there, re-run discovery; the next flush will move the old file aside.')
        : _('The fan set in fan-sensors.conf no longer matches the columns recorded in fan-history.tsv. The next flush will move the old file aside and start a fresh series.'));

    if (data.schema === 'unreadable')
      msgs.push(_('The history files could not be read on the router — the page is showing what little arrived. Check that /root/website is intact and see logread.'));
    else if (data.schema === 'mismatch')
      msgs.push(_('The sensor layout in temp-sensors.conf no longer matches the columns recorded in temp-history.tsv. Historical rows are being read with the current layout and may be wrong. The next flush will move the old file aside and start a fresh series.'));

    this.showBanner(msgs.join('\n'));
  },

  // Seconds since the newest recorded sample, by the ROUTER's clock, or null
  // when the payload cannot say (an older CGI, or a router with no data yet).
  sampleAge(data) {
    if (!data || !data.now || !data.last_sample) return null;
    const age = data.now - data.last_sample;
    return (age >= 0) ? age : 0;
  },

  updateFanControl(data) {
    const els = this._fanEls;
    if (!els) return;
    const st = data.fan_state;
    if (!st) return;

    const manual = (st.mode === 'manual');
    // The badge names the controller too. "automatic (kernel)" was the same
    // false claim in miniature on any router where a userspace daemon owns
    // the fan.
    const badgeCtl = (st.external && st.external.name) ? st.external.name : _('kernel');
    els.mode.textContent = manual
      ? _('manual') + ' · ' + Math.max(0, Math.round((st.remaining||0)/60)) + _('m left')
      : _('automatic') + ' (' + badgeCtl + ')';
    els.mode.className = 'th-fan-mode ' + (manual ? 'th-fan-manual' : 'th-fan-auto');

    // The floor MUST be applied before the value. A range input clamps an
    // out-of-range assignment to the bound in force at that moment, so with
    // the old order — value then min — lowering fan_min_percent from 25 to 10
    // and running the fan at 10% left the slider stuck showing 25 until the
    // page was reloaded, silently disagreeing with the fan.
    if (st.min_percent != null) els.slider.min = String(st.min_percent);

    // Don't fight the user while they are dragging.
    if (!els.dragging) {
      const pct = manual ? (st.percent||0)
                         : (st.fans && st.fans[0] && st.fans[0].percent != null ? st.fans[0].percent : 0);
      els.slider.value = String(pct);
      els.pct.textContent = pct + '%';
    }
    // A driver with no pwmN_enable (the mainline pwm-fan) cannot be taken out
    // of the thermal governor's hands at all — a manual speed is written
    // straight to pwm and the governor may overwrite it whenever it next
    // acts. Say so, rather than letting a setting silently revert.
    const soft = !!(st.fans && st.fans.length && st.fans.some(f => f.has_enable === false));

    // Name whatever is ACTUALLY regulating the fan on this router, and only
    // that. This used to open with "The kernel thermal governor is managing
    // the fan" unconditionally and then append "gl_fan is also managing this
    // fan" — two claims that contradict each other, the first of them false
    // wherever the second is true. On GL.iNet firmware gl_fan is a userspace
    // daemon polling once a second, and it is frequently the ONLY controller
    // in normal operation: on that firmware the thermal zone's lowest trip
    // point is 85°C, so below that the kernel governor does not touch the fan
    // at all. "The governor is managing it" was true in the abstract and
    // wrong about the router in front of you.
    const ext     = st.external;
    const extName = (ext && ext.name) ? ext.name : null;
    const minPct  = (st.min_percent != null) ? st.min_percent : 25;

    let base;
    if (manual) {
      base = (extName
        ? _('Automatic control returns to') + ' ' + extName + ' ' + _('when the override expires, or immediately if any sensor reaches')
        : _('Kernel control returns when the override expires, or immediately if any sensor reaches')
      ) + ' ' + TH.crit + '°C.';
    } else if (extName) {
      base = extName + ' ' + _('is managing this fan');
      if (ext.threshold != null)
        base += ', ' + _('ramping it from') + ' ' + ext.threshold + '°C';
      base += '. ' + _('The kernel thermal governor does not take over until its own trip points, which are usually far higher.') +
              ' ' + _('Minimum manual speed is') + ' ' + minPct + '%.';
    } else {
      base = _('The kernel thermal governor is managing the fan.') +
             ' ' + _('Minimum manual speed is') + ' ' + minPct + '%.';
    }

    let caveat = '';
    if (extName) {
      caveat = ' ' + extName + ' ' +
               _('can overwrite a manual speed within a second of changing state.');
      if (ext.threshold != null)
        caveat += ' ' + _('Raise its threshold if you want the fan quieter all the time.');
    } else if (soft) {
      caveat = ' ' + _('This driver exposes no pwm_enable, so the governor is never disengaged and may override a manual speed at any time — treat it as a nudge, not a lock.');
    }
    els.note.textContent = base + caveat;
  },

  // ── CPU and memory ─────────────────────────────────────────────────────
  // Three series on one 0-100 axis: CPU, memory in use, and memory in use
  // counting cache. The last two are deliberately both present — on Linux
  // neither is the honest answer alone. A kernel with spare RAM fills it with
  // cache, so the cached figure sits near full on a healthy router and means
  // nothing by itself; the uncached one is what "running out" looks like.
  updateSysChart(data) {
    if (!this._sysChart) return;
    const rows = data.sys_history || [];
    const labels = rows.map(r => r.ts);
    this._sysChart.update(labels, [
      { label: _('CPU'),          color: SYS_COLORS[0], data: rows.map(r => r.c) },
      { label: _('RAM'),          color: SYS_COLORS[1], data: rows.map(r => r.m) },
      { label: _('RAM + cache'),  color: SYS_COLORS[2], data: rows.map(r => r.k) }
    ]);
  },

  // The live tiles. Driven from sys_now, which rides on BOTH payloads — so
  // this is fed by the 60-second poll as well as the 10-minute full reload,
  // and updateCards() is where both of them land.
  updateSysNow(data) {
    const els = this._sysEls;
    if (!els) return;
    const n = data && data.sys_now;
    els.forEach(t => {
      const v = (n && n[t.key] != null && n[t.key] >= 0) ? parseFloat(n[t.key]) : null;
      // One decimal is noise at card size — the sensors show whole degrees for
      // the same reason. The exact figure stays in the title attribute and in
      // the chart tooltip.
      t.num.textContent = (v == null) ? '—' : String(Math.round(v));
      t.val.title = fmtPct(n ? n[t.key] : null);
      t.fill.style.width = (v == null ? 0 : Math.max(0, Math.min(100, v))) + '%';

      // The records come from the full payload only — the 60-second live poll
      // does not read the history file. So they are left alone rather than
      // blanked when a live payload arrives, or they would flicker away and
      // back every minute.
      const mx = data.sys_max, mn = data.sys_min, av = data.sys_avg_today;
      if (mx && mn) {
        t.hi.innerHTML =
          '<span class="th-arrow-hi">↑</span> <strong>' + escHtml(pctDisp(mx[t.idx])) + '</strong>' +
          '<span class="th-stat-ts">' + escHtml(fmtDT((data.sys_max_ts||[])[t.idx])) + '</span>';
        t.lo.innerHTML =
          '<span class="th-arrow-lo">↓</span> <strong>' + escHtml(pctDisp(mn[t.idx])) + '</strong>' +
          '<span class="th-stat-ts">' + escHtml(fmtDT((data.sys_min_ts||[])[t.idx])) + '</span>';
      }
      if (av) {
        t.av.innerHTML =
          '<span class="th-arrow-avg">~</span> ' +
          '<span style="color:var(--th-dim)">avg today </span>' +
          '<strong>' + escHtml(pctDisp(av[t.idx])) + '</strong>';
      }
    });
  },

  applyFull(data) {
    if (!data || data.error) return;
    if (this.applyThresholds(data) && this._chart)
      this._chart.update(this._labels, this._series);
    this.updateCards(data);
    this.updateChart(data);
    this.updateUptime(data);
    this.updateSysChart(data);
    this.updateFanControl(data);
    this.updateStatus(data);
    this.checkSchema(data);
  },

  // The status bar's DOM is built once in render(); this only writes text.
  // The old version rebuilt it with innerHTML on every poll and re-attached
  // a click listener to the freshly created button each time.
  updateStatus(data) {
    const els = this._statusEls;
    if (!els) return;
    els.rows.textContent    = (data.total_rows||0) + ' entries';
    els.sensors.textContent = ((data.sensors||[]).length) + ' sensors';
    els.buf.textContent     = (data.buf_rows||0) + ' rows in RAM buffer';

    // Age of the newest recorded sample, from the ROUTER's clock — comparing
    // against the browser's would report a stalled collector on any desktop
    // whose time is a few minutes out, which is most of them.
    const el = this._ageEl;
    if (el) {
      const age = this.sampleAge(data);
      if (age === null) {
        // No timestamps in this payload at all: say nothing rather than
        // guessing. An empty history is not a stopped collector.
        el.textContent = '';
        el.className   = 'th-age';
      } else {
        el.textContent = ' · ' + _('last sample') + ' ' + fmtAge(age) + ' ' + _('ago');
        el.className   = 'th-age' + (age > STALE_AFTER ? ' th-age-stale' : '');
      }
    }
  },

  doFlush() {
    if(this._flushBusy) return;
    const btn = this._statusEls && this._statusEls.flushBtn;
    this._flushBusy=true;
    if(btn){ btn.textContent='Flushing…'; btn.style.opacity='0.5'; btn.disabled=true; }
    this.mutate('flush', null, 10000)
      .then(d=>{
        if(btn){
          btn.textContent = (d && d.status==='busy')  ? 'Flush already running'
                          : (d && d.status==='error') ? 'Flush failed'
                          : 'Flushed ✓ ('+((d&&d.flushed_temp)||0)+' rows)';
          btn.style.opacity='1';
        }
        if (d && d.rotated)
          this.showBanner(_('Sensor layout changed — the previous history was kept as') +
                          ' ' + d.rotated + ' ' + _('and a fresh series was started.'));
        // "Flush failed" on its own tells you nothing. Put the actual reason
        // where it can be read.
        if (d && d.status === 'error')
          this.showBanner(_('Flush failed:') + ' ' + (d.error || _('unknown error')));
        setTimeout(()=>{
          this._flushBusy=false;
          if(btn){ btn.disabled=false; btn.textContent='Flush to Flash ⬇'; }
          if(this._destroyed) return;
          this.fetchFull().then(fresh=>{
            if(this._destroyed) return;
            this.applyFull(fresh);
          }).catch(()=>{});
        }, 2000);
      })
      .catch(e=>{
        if(btn){ btn.textContent='Flush failed'; btn.style.opacity='1'; btn.disabled=false; }
        this.showBanner(_('Flush failed:') + ' ' + ((e && e.message) ? e.message : e));
        this._flushBusy=false;
      });
  },

  doResetMinMax(sensorIdx, btnEl, sensorName) {
    // Destructive and not undoable from the UI — the cutoff lands in
    // /root/website/temp-reset.conf and the old records stop being reported.
    if (!window.confirm(_('Clear the all-time min/max records for this sensor?') + '\n\n' + sensorName)) return;
    if(btnEl){ btnEl.textContent='…'; btnEl.style.opacity='0.5'; btnEl.disabled=true; }
    this.mutate('reset', sensorIdx, 8000)
      .then(d=>{
        if (d && d.status === 'error')
          this.showBanner(_('Could not reset min/max:') + ' ' + (d.error || _('unknown error')));
        if(btnEl){ btnEl.textContent='↺'; btnEl.style.opacity='1'; btnEl.disabled=false; }
        if(this._destroyed) return;
        return this.fetchFull().then(fresh=>{
          if(this._destroyed) return;
          this.applyFull(fresh);
        });
      })
      .catch(()=>{ if(btnEl){ btnEl.textContent='↺'; btnEl.style.opacity='1'; btnEl.disabled=false; } });
  },

  // Same shape as doResetMinMax, against the system series cutoff file.
  doResetSys(col, btnEl, label) {
    if (!window.confirm(_('Clear the all-time min/max records for this?') + '\n\n' + label)) return;
    if(btnEl){ btnEl.textContent='…'; btnEl.style.opacity='0.5'; btnEl.disabled=true; }
    this.mutate('resetSys', col, 8000)
      .then(d=>{
        if (d && d.status === 'error')
          this.showBanner(_('Could not reset min/max:') + ' ' + (d.error || _('unknown error')));
        if(btnEl){ btnEl.textContent='↺'; btnEl.style.opacity='1'; btnEl.disabled=false; }
        if(this._destroyed) return;
        return this.fetchFull().then(fresh=>{
          if(this._destroyed) return;
          this.applyFull(fresh);
        });
      })
      .catch(()=>{ if(btnEl){ btnEl.textContent='↺'; btnEl.style.opacity='1'; btnEl.disabled=false; } });
  },

  // Thresholds and retention live in uci (temp_history.main) so the shell
  // scripts, the ucode backend and this page all read one source of truth.
  // Written through LuCI's uci module, which means the write goes through the
  // session's ACL — the same authenticated path the mutations now use.
  // cgi_write is deliberately NOT exposed here: it is a security setting, not
  // a preference, and it should take a deliberate SSH visit to change.
  buildSettings(data) {
    const self = this;
    const mk = mkField;

    const fWarn = mk('warn', _('Warn °C'),   TH.warn, 1, 200,  _('Amber above this temperature'));
    const fCrit = mk('crit', _('Crit °C'),   TH.crit, 1, 200,  _('Red above this temperature'));
    const fRows = mk('rows', _('History rows'), data && data.max_rows ? data.max_rows : 2880,
                     10, 100000, _('Rows kept in temp-history.tsv. 2880 = 30 days at 15-minute intervals.'));

    // The manual-speed floor. Only offered where there is a fan to apply
    // it to — on passively cooled hardware it would be a setting for nothing.
    // The right value is a property of the specific fan, not a safe default:
    // a PWM fan needs more duty to START from stopped than to keep running,
    // so the number worth putting here is the lowest percent that reliably
    // restarts it, which is usually a little above the lowest that keeps it
    // turning.
    const fanSt   = data && data.fan_state;
    const showFan = !!(fanSt && fanSt.controllable && fanSt.control_enabled);
    const fFanMin = showFan
      ? mk('fanmin', _('Fan min %'), fanSt.min_percent != null ? fanSt.min_percent : 25,
           0, 100, _('Asking for less than this gets this instead, so the page cannot stall the fan. Lower it only as far as your fan will still start from a standstill. 0 removes the floor entirely.'))
      : null;

    const msg  = E('span', { class:'th-settings-msg' }, '');
    const save = E('button', { type:'button', class:'th-save' }, _('Save'));

    save.addEventListener('click', ()=>{
      const w = parseInt(fWarn.input.value, 10);
      const c = parseInt(fCrit.input.value, 10);
      const r = parseInt(fRows.input.value, 10);

      if (!(w > 0) || !(c > 0) || !(r >= 10)) {
        msg.textContent = _('Enter positive numbers (history rows ≥ 10).');
        return;
      }
      if (c <= w) {
        msg.textContent = _('Crit must be higher than Warn.');
        return;
      }

      let fm = null;
      if (fFanMin) {
        fm = parseInt(fFanMin.input.value, 10);
        if (!(fm >= 0 && fm <= 100)) {
          msg.textContent = _('Fan min % must be between 0 and 100.');
          return;
        }
      }

      save.disabled = true;
      msg.textContent = _('Saving…');

      uci.load('temp_history').then(()=>{
        uci.set('temp_history', 'main', 'warn_temp', String(w));
        uci.set('temp_history', 'main', 'crit_temp', String(c));
        uci.set('temp_history', 'main', 'max_rows',  String(r));
        if (fm !== null)
          uci.set('temp_history', 'main', 'fan_min_percent', String(fm));
        return uci.save();
      }).then(()=>{
        return uci.apply();
      }).then(()=>{
        save.disabled = false;
        msg.textContent = _('Saved.');
        // Repaint immediately rather than waiting for the next full poll.
        TH.warn = w; TH.crit = c;
        if (self._chart) self._chart.update(self._labels, self._series);
        return self.fetchFull().then(fresh=>{ if(!self._destroyed) self.applyFull(fresh); });
      }).catch(e=>{
        save.disabled = false;
        msg.textContent = _('Save failed:') + ' ' + (e && e.message ? e.message : e);
      });
    });

    // Version line. Two versions, not one: PKG_VERSION is baked into THIS
    // file, so it is whatever the browser actually loaded, while data.version
    // comes from the CGI on the router. They differ exactly when a cached copy
    // of the page is being served after an upgrade — which has cost real time
    // in this project, and which no amount of "did you hard-reload?" reliably
    // establishes.
    const routerVer = data && data.version ? data.version : null;
    const stale = !!(routerVer && PKG_VERSION !== 'dev' && routerVer !== PKG_VERSION);
    const verNode = E('div', { class:'th-version' }, [
      E('span', {}, 'luci-app-temp-history ' + PKG_VERSION),
      stale
        ? E('strong', { class:'th-version-stale' },
            '  ' + _('router has') + ' ' + routerVer + ' — ' + _('reload this page (Ctrl-Shift-R)'))
        : null
    ].filter(c => c != null));

    return E('details', { class:'th-settings' }, [
      E('summary', {}, _('Settings')),
      E('div', { class:'th-settings-body' }, kids([
        fWarn.node, fCrit.node, fRows.node,
        fFanMin ? fFanMin.node : null,
        save, msg,
        this.buildSetpoints(data),   // null on anything but GL.iNet firmware
        verNode
      ]))
    ]);
  },

  // ── GL.iNet thermal setpoints ──────────────────────────────────────────
  // Returns null unless the backend reported GL.iNet stock firmware, so on
  // every other router the section does not exist rather than existing greyed
  // out — the same rule the fan control follows on passively cooled hardware.
  //
  // These are NOT the warn/crit fields above. Those two colour this page and
  // nothing else. These change what the gl_fan daemon regulates against, by
  // rewriting its config and the library it sources, and they persist until
  // changed back or until a firmware upgrade replaces the files.
  //
  // Minimum and Maximum are the only editable values, per the shell script
  // this was ported from. Fan-On and Warning are shown read-only and carried
  // through: the backend clamps them into the new band only when the band
  // would otherwise exclude them, and says so when it did.
  buildSetpoints(data) {
    let sp = data && data.setpoints;
    if (!sp || !sp.supported) return null;

    const self  = this;
    const limit = (typeof sp.limit === 'number') ? sp.limit : 120;

    const fMin = mkField('spmin', _('Minimum °C'), sp.min, 0, limit,
      _('The temperature at which the fan starts, at its lowest duty. Raising it keeps the fan off longer.'));
    const fMax = mkField('spmax', _('Maximum °C'), sp.max, 0, limit,
      _('The top of the range the controller will accept. Stock firmware caps this at 90 °C.'));

    const ro  = E('div', { class:'th-setp-ro' }, '');
    const msg = E('span', { class:'th-settings-msg' }, '');
    const note = E('div', { class:'th-setp-note' }, '');

    // Only offered where GL's admin bundles actually exist. On a community
    // build running on GL hardware the system half still works and this half
    // would be a switch for nothing.
    const uiCheck = sp.ui_available
      ? E('input', { type:'checkbox', id:'th-set-spui' })
      : null;
    if (uiCheck) uiCheck.checked = !!sp.ui_patch;
    const uiLabel = uiCheck
      ? E('label', { class:'th-setp-check', for:'th-set-spui' }, [
          uiCheck, E('span', {}, _('Also widen the range in GL’s own admin UI'))
        ])
      : null;

    const apply = E('button', { type:'button', class:'th-save' }, _('Apply setpoints'));
    const reset = E('button', { type:'button', class:'th-save th-setp-danger' },
                    _('Restore factory defaults'));

    const paint = (s)=>{
      sp = s;
      fMin.input.value = String(s.min);
      fMax.input.value = String(s.max);
      if (uiCheck) uiCheck.checked = !!s.ui_patch;
      // Mark the ones that do not reach the daemon. Presenting Fan-On and
      // Warning identically implied they carry equal weight; on GL.iNet
      // the init script passes only Fan-On, so Warning is a stored number the
      // running fan never sees. Saying "carried through unchanged" about both
      // was true about what this page does and misleading about what it means.
      const dead = ' <em>' + _('(not passed to the daemon)') + '</em>';
      ro.innerHTML = _('Fan-On') + ' <strong>' + escHtml(String(s.fan_on)) + ' °C</strong> · ' +
                     _('Warning') + ' <strong>' + escHtml(String(s.warn)) + ' °C</strong>' +
                     (s.warn_live === 0 ? dead : '') + ' · ' +
                     _('carried through unchanged');

      const lines = [];
      // The backend reads gl_fan's init script to see which UCI options it
      // actually passes to the daemon. On GL.iNet firmware 4.9.1 it
      // passes only the fan-on target, so the minimum never reaches the
      // process. That does NOT make it useless — it is what GL's own admin
      // page uses as the lower bound of its fan slider, which is the reason
      // that slider refuses to go below 70 out of the box. Say what it does
      // control, rather than implying it controls nothing.
      if (s.min_live === 0)
        lines.push(_('The gl_fan daemon is started with the Fan-On target only, so the minimum is not passed to it. What the minimum sets is the lower bound of the fan slider on GL’s own admin page — the floor that otherwise stops you choosing a lower Fan-On there.'));
      if (!s.running)
        lines.push(_('The gl_fan daemon is not running, so these values are stored but nothing is regulating against them.'));
      // A snapshot baseline is honestly weaker than /rom, and the difference
      // matters: it was taken from whatever state the files were in the first
      // time this ran, which is only "factory" if nothing had patched them
      // before. Say so rather than letting "restore factory defaults" imply
      // more than it can deliver.
      if (s.baseline === 'snapshot')
        lines.push(_('No read-only firmware copy (/rom) on this device — "factory" here means the state these files were in when this package first touched them.'));
      lines.push(_('Restoring factory defaults also puts GL’s own admin web-UI files back, which removes any other patch applied to them.'));
      note.textContent = lines.join('\n');
    };
    paint(sp);

    const busy = (on)=>{ apply.disabled = on; reset.disabled = on; };

    // The backend may have taken a while (it gunzips and rewrites firmware
    // bundles, then restarts the daemon) and the ubus call can time out while
    // the work still completes. So every path — success, refusal and error —
    // ends by re-reading the real state rather than by trusting what was asked
    // for, and the message says what is actually configured now.
    const refresh = (okText)=>{
      return self.mutate('getSetpoints', null, 8000).then(fresh=>{
        if (self._destroyed) return;
        if (fresh && fresh.supported) paint(fresh);
        if (okText) msg.textContent = okText;
        busy(false);
      }).catch(()=>{ busy(false); });
    };

    apply.addEventListener('click', ()=>{
      const lo = parseInt(fMin.input.value, 10);
      const hi = parseInt(fMax.input.value, 10);

      if (!(lo >= 0 && lo <= limit) || !(hi >= 0 && hi <= limit)) {
        msg.textContent = _('Setpoints must be between 0 and') + ' ' + limit + ' °C.';
        return;
      }
      if (!(hi > lo)) {
        msg.textContent = _('Maximum must be above minimum.');
        return;
      }
      // 90 °C is where stock firmware stops on purpose. Past it the operator
      // is choosing to run hotter than the vendor allows for, so the choice is
      // made explicitly rather than by a slider drifting.
      if (hi > 90 && !window.confirm(
            _('A maximum above 90 °C lets the fan controller be told to tolerate temperatures the firmware normally refuses. Most silicon is rated to about 105 °C; past that you risk throttling or an emergency shutdown.') +
            '\n\n' + _('Set the maximum to') + ' ' + hi + ' °C?'))
        return;

      busy(true);
      msg.textContent = _('Applying…');

      // The web-UI opt-in is a preference, so it is written through LuCI's uci
      // module on the same authenticated path as the fields above — not passed
      // as an argument to the setpoint call. The backend reads it when it runs,
      // so it has to be committed BEFORE the call, not alongside it.
      const want = uiCheck ? (uiCheck.checked ? '1' : '0') : null;
      const pre = (want === null || want === String(sp.ui_patch ? 1 : 0))
        ? Promise.resolve()
        : uci.load('temp_history')
             .then(()=>{ uci.set('temp_history', 'main', 'glfan_ui_patch', want); return uci.save(); })
             .then(()=> uci.apply());

      pre.then(()=> self.mutate('setSetpoints', { min: lo, max: hi }, 60000))
        .then(d=>{
          if (d && d.status === 'error') {
            msg.textContent = _('Setpoints:') + ' ' + (d.error || _('unknown error'));
            return refresh(null);
          }
          // "adjusted" names the values the backend had to move to keep the
          // hierarchy intact. Silently moving someone's Fan-On target and not
          // saying so is how a fan ends up behaving differently for no visible
          // reason.
          let t = _('Applied.');
          if (d && d.adjusted)
            t += ' ' + _('Adjusted to fit the new range:') + ' ' + d.adjusted + '.';
          if (d && d.ui_patched)
            t += ' ' + _('Hard-reload GL’s admin page (Ctrl-Shift-R) to see it there.');
          return refresh(t);
        })
        .catch(e=>{
          msg.textContent = _('Setpoints:') + ' ' + ((e && e.message) ? e.message : e);
          return refresh(null);
        });
    });

    reset.addEventListener('click', ()=>{
      if (!window.confirm(
            _('Restore the firmware’s factory fan setpoints?') + '\n\n' +
            _('This puts back /lib/functions/gl_util.sh, the gl_fan config and GL’s admin web-UI files from the firmware image, removing any other patch applied to them.')))
        return;
      busy(true);
      msg.textContent = _('Restoring…');
      self.mutate('resetSetpoints', null, 60000)
        .then(d=>{
          if (d && d.status === 'error') {
            msg.textContent = _('Setpoints:') + ' ' + (d.error || _('unknown error'));
            return refresh(null);
          }
          return refresh(_('Factory defaults restored.'));
        })
        .catch(e=>{
          msg.textContent = _('Setpoints:') + ' ' + ((e && e.message) ? e.message : e);
          return refresh(null);
        });
    });

    return E('div', { class:'th-setp' }, kids([
      E('div', { class:'th-setp-head' },
        _('Thermal setpoints') + ' — gl_fan' + (sp.model ? ' (' + sp.model + ')' : '')),
      fMin.node, fMax.node, ro,
      uiLabel,
      apply, reset, msg, note
    ]));
  },

  doSetFan(pct, mins) {
    if (this._fanBusy) return;
    this._fanBusy = true;
    const els = this._fanEls;
    if (els) els.apply.disabled = true;
    this.mutate('setFan', { percent: pct, minutes: mins }, 10000)
      .then(d=>{
        this._fanBusy = false;
        if (els) els.apply.disabled = false;
        if (d && d.status === 'error') {
          this.showBanner(_('Fan control:') + ' ' + (d.error || _('unknown error')));
          return;
        }
        this.showBanner('');
        // The helper may have applied a floor rather than the exact value
        // asked for, so re-read rather than assuming what was set.
        return this.fetchFull().then(f=>{ if(!this._destroyed) this.applyFull(f); });
      })
      .catch(e=>{
        this._fanBusy = false;
        if (els) els.apply.disabled = false;
        this.showBanner(_('Fan control:') + ' ' + ((e && e.message) ? e.message : e));
      });
  },

  doAutoFan() {
    if (this._fanBusy) return;
    this._fanBusy = true;
    const els = this._fanEls;
    if (els) els.auto.disabled = true;
    this.mutate('autoFan', null, 10000)
      .then(d=>{
        this._fanBusy = false;
        if (els) els.auto.disabled = false;
        if (d && d.status === 'error') {
          this.showBanner(_('Fan control:') + ' ' + (d.error || _('unknown error')));
          return;
        }
        this.showBanner('');
        return this.fetchFull().then(f=>{ if(!this._destroyed) this.applyFull(f); });
      })
      .catch(e=>{
        this._fanBusy = false;
        if (els) els.auto.disabled = false;
        this.showBanner(_('Fan control:') + ' ' + ((e && e.message) ? e.message : e));
      });
  },

  // Returns null when there is nothing to control, so a passively cooled
  // router shows no fan UI at all rather than a dead widget.
  buildFanControl(data) {
    const st = data.fan_state;
    if (!st || !st.controllable || !st.control_enabled) return null;
    const self = this;

    const mode   = E('span', { class:'th-fan-mode th-fan-auto' }, '…');
    const slider = E('input', {
      type: 'range', class: 'th-fan-slider',
      min: String(st.min_percent != null ? st.min_percent : 25),
      max: '100', step: '5', value: '50',
      'aria-label': _('Fan speed percent')
    });
    const pct    = E('span', { class:'th-fan-pct' }, '50%');
    const apply  = E('button', { type:'button', class:'th-save' }, _('Set'));
    const auto   = E('button', { type:'button', class:'th-range-btn' }, _('Back to automatic'));
    const note   = E('div', { class:'th-fan-note' }, '');

    const els = { mode, slider, pct, apply, auto, note, dragging: false };
    this._fanEls = els;

    slider.addEventListener('input', ()=>{ els.dragging = true; pct.textContent = slider.value + '%'; });
    slider.addEventListener('change', ()=>{ els.dragging = false; });
    apply.addEventListener('click', ()=>{
      const v = parseInt(slider.value, 10);
      if (!(v >= 0 && v <= 100)) return;
      els.dragging = false;
      self.doSetFan(v, st.default_minutes || 30);
    });
    auto.addEventListener('click', ()=>{ els.dragging = false; self.doAutoFan(); });

    return E('details', { class:'th-settings th-fan-box' }, [
      E('summary', {}, _('Fan control')),
      E('div', { class:'th-fan-body' }, [
        mode, slider, pct, apply, auto, note
      ])
    ]);
  },

  // ── Events ─────────────────────────────────────────────────────────────
  // The collector has always detected threshold crossings and fan stalls and
  // written them to syslog with `logger -t temp-history`. Nobody reads syslog
  // on a router, so the app did the hard part and then hid the answer. This
  // panel is where it comes back.
  //
  // Fetched LAZILY, on first expand, rather than with the page payload. Most
  // visits are "what is it doing right now", and reading the whole ring buffer
  // for a panel nobody opened would be a fork per page load for nothing. It is
  // also deliberately not on the 60-second poller: events are read when asked
  // for, not streamed.
  buildEvents() {
    const self = this;
    const body = E('div', { class:'th-evt-body' }, [
      E('div', { class:'th-evt-empty' }, _('Loading…'))
    ]);
    this._evtBody   = body;
    this._evtLoaded = false;

    const refresh = E('button', { type:'button', class:'th-range-btn' }, _('Refresh'));
    refresh.addEventListener('click', (ev)=>{ ev.preventDefault(); self.loadEvents(); });

    const box = E('details', { class:'th-settings th-evt-box' }, [
      E('summary', {}, _('Events')),
      E('div', { class:'th-evt-head' }, [
        E('span', { class:'th-evt-note' },
          _('Threshold crossings and fan stalls, newest first. Read from the system log, which is held in RAM and cleared by a reboot.')),
        refresh
      ]),
      body
    ]);
    // <details> fires toggle on open AND close; only the first open should
    // fetch. Later opens reuse what is there, and Refresh is how you re-read.
    box.addEventListener('toggle', ()=>{
      if (box.open && !self._evtLoaded) self.loadEvents();
    });
    return box;
  },

  loadEvents() {
    const self = this;
    const body = this._evtBody;
    if (!body) return Promise.resolve();
    this._evtLoaded = true;
    return this.mutate('getEvents', 60, 8000)
      .catch(()=>({ supported:false, reason:_('unreachable'), events:[] }))
      .then(r=>{ self.renderEvents(r); })
      .catch(()=>{});
  },

  renderEvents(r) {
    const body = this._evtBody;
    if (!body) return;
    while (body.firstChild) body.removeChild(body.firstChild);

    const evts = (r && Array.isArray(r.events)) ? r.events : [];
    if (!evts.length) {
      // Three different nothings, and they are worth telling apart: a router
      // with no backend, a router with no logread, and — the good one — a
      // router that has simply never run hot.
      const why = (r && r.supported === false && r.reason)
        ? _('Events unavailable: ') + r.reason
        : _('Nothing logged. No sensor has crossed a threshold and no fan has stalled since the last reboot.');
      body.appendChild(E('div', { class:'th-evt-empty' }, why));
      return;
    }

    evts.forEach(e=>{
      // err is the crit crossings and the stalled fans; warning and notice are
      // the approach and the recovery. Colour follows the same three-way split
      // the cards use, so "red on this page" always means the same thing.
      const lvl = String(e && e.level || '').toLowerCase();
      const cls = (lvl === 'err' || lvl === 'crit' || lvl === 'alert' || lvl === 'emerg')
        ? ' th-evt-err'
        : (lvl === 'warning' || lvl === 'warn') ? ' th-evt-warn' : '';
      body.appendChild(E('div', { class:'th-evt-row'+cls }, [
        E('span', { class:'th-evt-ts' }, String(e && e.ts || '')),
        E('span', { class:'th-evt-msg' }, String(e && e.msg || ''))
      ]));
    });
  },

  // ── Device / firmware footer ───────────────────────────────────────────
  // Returns null when nothing is known, so a router that answered with an
  // empty object gets no empty bar at the foot of the page.
  //
  // Every field is independently optional: the GL block is absent on vanilla
  // OpenWrt, /tmp/sysinfo/model is absent on a few boards, and a container has
  // neither. Each piece is emitted only if it exists, rather than printing
  // "unknown" three times.
  buildDevice(data) {
    const d = data && data.device;
    if (!d) return null;

    const parts = [];
    const sep = () => E('span', { class:'th-dev-sep' }, '·');

    if (d.model)
      parts.push(E('span', { class:'th-dev-model' }, d.model));

    // GL: 4.9.1 release build 1122 (2026-01-15) — the version is the useful
    // part, so it takes the readable colour and the build metadata stays dim.
    if (d.gl_version) {
      if (parts.length) parts.push(sep());
      const gl = [ E('span', { class:'th-dev-key' }, 'GL '),
                   E('span', { class:'th-dev-val' }, d.gl_version) ];
      if (d.gl_type)  gl.push(E('span', { class:'th-dev-key' }, ' ' + d.gl_type));
      if (d.gl_build) gl.push(E('span', { class:'th-dev-key' }, ' build ' + d.gl_build));
      if (d.gl_date)  gl.push(E('span', { class:'th-dev-key' }, ' (' + d.gl_date + ')'));
      parts.push(E('span', {}, gl));
    }

    if (d.openwrt) {
      if (parts.length) parts.push(sep());
      parts.push(E('span', { class:'th-dev-owrt' }, d.openwrt));
    }

    if (d.kernel) {
      if (parts.length) parts.push(sep());
      parts.push(E('span', { class:'th-dev-key' }, 'Linux ' + d.kernel));
    }

    if (!parts.length) return null;
    return E('div', { class:'th-device' }, parts);
  },

  setRange(secsAgo, activeBtn) {
    if(!this._chart) return;
    // Every chart, not just the temperatures. Comparing "was it hot because it
    // was busy" across two charts showing two different windows is exactly the
    // question this page is meant to answer, and answering it wrongly is worse
    // than not offering the button.
    this._chart.zoomTo(secsAgo);
    if(this._sysChart) this._sysChart.zoomTo(secsAgo);
    document.querySelectorAll('.th-range-btn').forEach(b=>{
      b.className='th-range-btn'+(b===activeBtn?' th-active':'');
    });
  },

  render(data) {
    this._destroyed = false;

    if (data && data.error) {
      return E('div', {}, [
        pageTitle(_('Temperature History')),
        E('p', { style:'color:var(--th-dim);font-style:italic' }, _('Error: ') + data.error)
      ]);
    }

    if (!data || !data.sensors || !data.sensors.length) {
      return E('div', {}, [
        pageTitle(_('Temperature History')),
        E('p', { style:'color:var(--th-dim);font-style:italic' },
          _('No data yet. Run: /usr/libexec/temp-history/collect-temp-history.sh'))
      ]);
    }

    // Apply the payload's thresholds BEFORE anything reads them. The cards
    // below colour themselves through tempClass(), and buildSettings() seeds
    // its fields from TH — without this both used the compiled-in 65/80 until
    // the first full poll ten minutes later, so a router configured to 70/85
    // showed the wrong colours (and the wrong numbers in Settings) on load.
    this.applyThresholds(data);

    const { sensors, current=[], min=[], max=[], min_ts=[], max_ts=[], avg_today=[] } = data;
    const self = this;

    // ── Status bar, built once ─────────────────────────────────────────────
    const stRows    = E('span', {}, '…');
    const stSensors = E('span', {}, '…');
    const stBuf     = E('span', {}, '…');
    const flushBtn  = E('button', {
      type: 'button',
      class: 'th-flush-btn',
      id: 'th-flush-btn',
      title: _('Commit the RAM buffer to flash storage now')
    }, 'Flush to Flash ⬇');
    flushBtn.addEventListener('click', ()=>self.doFlush());

    // Raw TSV download. A plain link, not a fetch-and-blob: the browser
    // streams it straight from the CGI, so a 30-day file never has to be held
    // in memory, and the link still works if this JS is broken.
    const exportLink = E('a', {
      class: 'th-export',
      // Same absolute path the three fetches use — not L.env.cgi_base, which
      // points at LuCI's own dispatcher rather than this sibling script.
      href: CGI_URL + '?export=temp',
      title: _('Download the raw 15-minute series as TSV, for a spreadsheet'),
      download: 'temp-history.tsv'
    }, _('Export TSV'));

    // How old the newest sample is. There is already a banner for collection
    // having stopped outright, but that only fires past 2.5 intervals — and
    // until it does, a frozen history is indistinguishable from a quiet one,
    // because the live cards keep updating from a direct sensor read. This is
    // the at-a-glance version: it is always on screen, so "4 minutes ago" is
    // reassurance and "6 hours ago" is caught by eye before the chart is
    // misread as a flat afternoon.
    // The separator lives INSIDE the span, so a payload with no timestamps
    // (the 21.02 CGI on an empty history) leaves no dangling middle dot.
    const stAge = E('span', { class:'th-age' }, '');
    this._ageEl = stAge;

    const statusBar = E('div', { class:'th-status-bar' }, [
      stRows, ' · ', stSensors, ' · ',
      '15-min intervals · ',
      stBuf, stAge, ' · ', flushBtn, ' ', exportLink
    ]);

    const banner = E('div', { class:'th-banner', style:'display:none' }, '');
    this._bannerEl = banner;
    this._statusEls = { rows: stRows, sensors: stSensors, buf: stBuf, flushBtn: flushBtn };

    // The live CPU and memory readings are CARDS, in the same row as the
    // sensors — they are the same kind of thing (one number, now, with a bar)
    // and a second bespoke tile style beside them read as a different widget
    // for no reason. They carry no min/max/avg because none is recorded for
    // them, so the card is simply shorter.
    // No per-card colour. These are cards in the sensors' row, so they take
    // the theme's card styling exactly as the sensors do — the value in
    // --th-good and the bar in the theme gradient. Colouring them by series
    // made three cards shout in three different colours next to five that
    // did not, which read as a status signal none of them was carrying.
    // The series colours belong on the CHART, where they identify a line.
    const sysCardDefs = [
      { key:'cpu',        label:_('CPU Usage')   },
      { key:'mem',        label:_('RAM Used')    },
      { key:'mem_cached', label:_('RAM + Cache') }
    ];
    const sysCards = sysCardDefs.map((t, j) => {
      const num  = E('span', { class:'th-val-num' }, '—');
      const fill = E('div', { class:'th-bar-fill', style:'width:0%' });
      const val  = E('div', { class:'th-val' }, [
        num, E('span', { class:'th-unit' }, ' %')
      ]);
      // The same three stat rows the sensors carry, in the same classes, so
      // they line up across the row. There is no reset button: the min/max
      // reset writes a per-sensor cutoff and there is no equivalent for these.
      const hi = E('div', { class:'th-stat th-hi' });
      const lo = E('div', { class:'th-stat th-lo' });
      const av = E('div', { class:'th-stat th-av' });
      const resetBtn = E('button', {
        type: 'button',
        class: 'th-reset-minmax',
        title: _('Reset min/max records for this'),
        'aria-label': _('Reset min/max records for') + ' ' + t.label
      }, '↺');
      resetBtn.addEventListener('click', ()=>self.doResetSys(j, resetBtn, t.label));
      return {
        key: t.key, idx: j, num, fill, val, hi, lo, av,
        node: E('div', { class:'th-card th-card-sys' }, [
          resetBtn,
          E('div', { class:'th-label', title:t.label }, t.label),
          val,
          E('div', { class:'th-bar' }, fill),
          hi, lo, av
        ])
      };
    });
    this._sysEls = sysCards;

    const cards = E('div', { class:'th-cards' },
      sensors.map((name,i)=>{
        const v   = parseFloat(current[i])||0;
        const pct = Math.min(100,Math.max(0,(v-20)/80*100));
        const valEl = E('div', { class:tempClass(v), title:toDisp(current[i])+' °C' }, [
          E('span', { class:'th-val-num' }, toInt(current[i])),
          E('span', { class:'th-unit' }, ' °C')
        ]);
        const resetMinMaxBtn = E('button', {
          type: 'button',
          class: 'th-reset-minmax',
          title: _('Reset min/max records for this sensor'),
          'aria-label': _('Reset min/max records for') + ' ' + name
        }, '↺');
        resetMinMaxBtn.addEventListener('click', ()=>self.doResetMinMax(i, resetMinMaxBtn, name));
        return E('div', { class:'th-card'+(v>=TH.crit?' th-hot':v>=TH.warn?' th-warm':''), id:'th-card-'+i }, kids([
          resetMinMaxBtn,
          // The title carries the explanation where there is one. Falling back
          // to the name itself is not redundant: the label is ellipsised when
          // it does not fit, and hovering is the only way to read it in full.
          E('div', { class:'th-label', title:(sensorHint(name) || name) }, name),
          valEl,
          E('div', { class:'th-bar' }, E('div',{class:'th-bar-fill',style:`width:${pct}%`})),
          E('div', { class:'th-stat th-hi' }, [
            E('span',{class:'th-arrow-hi'},'↑ '),
            E('strong',{},toDisp(max[i])+'°C'),
            E('span',{class:'th-stat-ts'},'  '+fmtDT(max_ts[i]))
          ]),
          E('div', { class:'th-stat th-lo' }, [
            E('span',{class:'th-arrow-lo'},'↓ '),
            E('strong',{},toDisp(min[i])+'°C'),
            E('span',{class:'th-stat-ts'},'  '+fmtDT(min_ts[i]))
          ]),
          E('div', { class:'th-stat th-av' }, [
            E('span',{class:'th-arrow-avg'},'~ '),
            E('span',{style:'color:var(--th-dim)'},'avg today '),
            E('strong',{},toDisp(avg_today[i])+'°C')
          ]),
          // Fans are not per-sensor, so they are listed once, on the first
          // card, rather than repeated or faked onto every sensor.
          (i === 0 && data.fans && data.fans.length)
            ? E('div', { class:'th-rpm' }) : null
        ]));
      }).concat(sysCards.map(c => c.node))
    );

    const RANGES = [['24h',86400],['7d',604800],['30d',0]];
    const rangeBtns = E('div', { class:'th-range-btns' },
      RANGES.map(([label, secs])=>{
        const btn = E('button', { type:'button', class:'th-range-btn'+(label==='30d'?' th-active':'') }, label);
        btn.addEventListener('click', ()=>self.setRange(secs, btn));
        return btn;
      })
    );

    const canvas     = E('canvas');
    const resetBtn   = E('button', { type:'button', class:'th-reset-zoom' }, 'Reset Zoom ↺');
    const canvasWrap = E('div', { class:'th-canvas-wrap' }, [canvas, resetBtn]);

    // Legend — real buttons, so they are reachable by Tab and operable by
    // Enter/Space. They were plain divs with a click handler, i.e. invisible
    // to keyboard and screen-reader users.
    // Fans get legend entries as well, so they can be toggled off the chart
    // exactly like a sensor.
    const legendNames = sensors.concat(
      (data.fan_history && data.fan_history.length && data.fans) ? data.fans : []);
    const legendColor = (i) => (i < sensors.length)
      ? COLORS[i % COLORS.length]
      : FAN_COLORS[(i - sensors.length) % FAN_COLORS.length];
    const legendItems = legendNames.map((name,i)=>
      E('button', {
        type: 'button',
        class: 'th-legend-item',
        id: 'th-litem-'+i,
        'aria-pressed': 'true',
        // What the sensor IS comes first; what the button DOES second. A
        // legend entry is self-evidently clickable, so the explanation is
        // the part worth the hover.
        title: (sensorHint(name) ? sensorHint(name) + '\n\n' : '') +
               _('Show or hide this series on the chart')
      }, [
        E('span', { class:'th-legend-dot', id:'th-ldot-'+i, style:'background:'+legendColor(i) }),
        name
      ])
    );
    legendItems.forEach((item,i)=>{
      item.addEventListener('click',()=>{
        if(!self._series[i]) return;
        self._series[i].hidden=!self._series[i].hidden;
        item.className='th-legend-item'+(self._series[i].hidden?' th-hidden':'');
        item.setAttribute('aria-pressed', self._series[i].hidden ? 'false' : 'true');
        if(self._chart) self._chart.update(self._labels, self._series);
      });
    });
    const legend = E('div', { class:'th-legend' }, legendItems);

    const chartBox = E('div', { class:'th-chart-box' }, [
      E('div', { class:'th-chart-label' }, _('Temperatures — °C · fan rpm on the right  (drag to zoom · double-click to reset)')),
      rangeBtns,
      canvasWrap,
      legend
    ]);

    const fanControl = this.buildFanControl(data);

    const hasSys = !!(data.sys_now || (data.sys_history && data.sys_history.length));
    let sysCanvas = null, sysBox = null, sysReset = null;
    if (hasSys) {
      sysCanvas = E('canvas');
      sysReset  = E('button', { type:'button', class:'th-reset-zoom' }, _('Reset Zoom ↺'));
      sysBox = E('div', { class:'th-chart-box' }, [
        E('div', { class:'th-chart-label' }, _('System — CPU and memory, %  (drag to zoom · double-click to reset)')),
        E('div', { class:'th-uptime-wrap' }, [sysCanvas, sysReset])
      ]);
      sysReset.addEventListener('click', ()=>{ if(self._sysChart) self._sysChart.resetZoom(); });
    } else {
      this._sysEls = null;
    }

    const uptimeCanvas = E('canvas');
    const uptimeWrap   = E('div', { class:'th-uptime-wrap' }, uptimeCanvas);
    // Current uptime beside the chart title. The number was only ever readable
    // by hovering the far right-hand end of the plot, which is a lot of mouse
    // travel for the one value most people came to read.
    const uptimeNow    = E('span', { class:'th-uptime-now' }, '');
    this._uptimeNowEl  = uptimeNow;
    const uptimeBox    = E('div', { class:'th-chart-box' }, [
      E('div', { class:'th-chart-label' }, [
        _('Uptime — red dashes mark reboots'), uptimeNow
      ]),
      uptimeWrap
    ]);

    if (!this._tip) {
      this._tip = E('div', { class:'th-tooltip' });
      document.body.appendChild(this._tip);
    }

    resetBtn.addEventListener('click',()=>{
      if(self._chart) self._chart.resetZoom();
      document.querySelectorAll('.th-range-btn').forEach((b,i)=>{
        b.className='th-range-btn'+(i===2?' th-active':'');
      });
    });

    // Chart construction is deferred until the canvases are laid out, but the
    // old `setTimeout(..., 50)` was a race: navigating away inside that window
    // ran destroy() first, then this callback built two ResizeObservers on
    // detached nodes and re-took a reference to the already-removed tooltip —
    // both leaked for the life of the page. rAF fires on the next frame after
    // layout, and _destroyed short-circuits it if the view is already gone.
    let initTries = 0;
    const initCharts = ()=>{
      self._initRaf = null;
      if (self._destroyed) return;
      // The framework appends render()'s return value in a microtask, so the
      // canvas is normally connected by the first frame. Retry briefly rather
      // than silently never building the chart if that ever changes.
      if (!canvas.isConnected) {
        if (++initTries > 60) return;
        self._initRaf = requestAnimationFrame(initCharts);
        return;
      }
      self._chart = makeChart(canvas, self._tip, resetBtn);
      self._uptimeChart = makeUptimeChart(uptimeCanvas, self._tip);
      if (sysCanvas) self._sysChart = makeSysChart(sysCanvas, self._tip, sysReset);
      self.updateChart(data);
      self.updateUptime(data);
      self.updateSysChart(data);
      self.updateSysNow(data);
      self.updateFanControl(data);
      self.updateStatus(data);
      self.checkSchema(data);
    };
    this._initRaf = requestAnimationFrame(initCharts);

    let fullPollCounter = 0;
    // poll.add() returns a boolean, not a handle — poll.remove() matches on
    // function identity, so keep a reference to the callback itself.
    this._pollFn = ()=>{
      if (self._destroyed) return Promise.resolve();
      fullPollCounter++;
      if(fullPollCounter % 10 === 0){
        return self.fetchFull().then(fresh=>{
          if(self._destroyed) return;
          self.applyFull(fresh);
        }).catch(()=>{});
      }
      return self.fetchLive().then(live=>{
        if(self._destroyed) return;
        if(live&&!live.error) self.updateCards(live);
      }).catch(()=>{});
    };
    poll.add(this._pollFn, 60);

    return E('div', {}, kids([
      pageTitle(_('Temperature History')),
      E('p', { class:'th-desc cbi-map-descr' },
        _('Live readings with 30-day history. Drag chart to zoom. Click legend to toggle sensors.')),
      banner,
      statusBar,
      fanControl,                 // null on passively cooled hardware
      this.buildEvents(),
      this.buildSettings(data),
      cards,
      chartBox,
      sysBox,                     // null when the router reported no CPU/memory
      uptimeBox,
      this.buildDevice(data)      // null when the router told us nothing
    ]));
  },

  handleSaveApply: null,
  handleSave:      null,
  handleReset:     null,

  destroy() {
    this._destroyed = true;

    // LuCI's poll registry is global — entries added by a view are NOT
    // removed when you navigate away from it. Without this the 60s poller
    // kept hitting the CGI (forking sh + awk on the router) for the rest of
    // the browser session, and every tenth tick pulled the full history.
    if (this._pollFn) { poll.remove(this._pollFn); this._pollFn = null; }

    if (this._initRaf !== null) { cancelAnimationFrame(this._initRaf); this._initRaf = null; }
    if (this._chart)       { this._chart.destroy();       this._chart = null; }
    if (this._uptimeChart) { this._uptimeChart.destroy(); this._uptimeChart = null; }
    if (this._sysChart)    { this._sysChart.destroy();    this._sysChart = null; }
    if (this._tip && this._tip.parentNode) {
      this._tip.parentNode.removeChild(this._tip);
      this._tip = null;
    }
    this._statusEls = null;
    this._bannerEl  = null;
    this._fanEls    = null;
    this._sysEls    = null;
    this._ageEl        = null;
    this._evtBody      = null;
    this._uptimeNowEl  = null;
  },
});
