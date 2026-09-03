// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Void
'use strict';
'require baseclass';
'require rpc';

document.head.append(E('style', { type: 'text/css' }, `
  :root {
    --ts-good:   #46a3d1;
    --ts-warn:   #c87f0a;
    --ts-hot:    #b5261e;
    --ts-label:  #222;
    --ts-text:   #222;
    --ts-bar-start: #46a3d1;
    --ts-bar-end:   #4fc3c7;
    --ts-border: rgba(0,0,0,0.12);
  }
  /* Themes that signal dark mode explicitly (Bootstrap, Material, Aurora)
     set data-darkmode. Themes that do not are covered by the media query,
     scoped so an explicit data-darkmode="false" still wins over the OS. */
  @media (prefers-color-scheme: dark) {
    :root:not([data-darkmode="false"]) {
      --ts-good:   #009890;
      --ts-warn:   #e67e22;
      --ts-hot:    #e74c3c;
      --ts-label:  #e8e8e8;
      --ts-text:   #e8e8e8;
      --ts-bar-start: #00a199;
      --ts-bar-end:   #065f46;
      --ts-border: rgba(255,255,255,0.08);
    }
  }
  :root[data-darkmode="true"] {
    --ts-good:   #009890;
    --ts-warn:   #e67e22;
    --ts-hot:    #e74c3c;
    --ts-label:  #e8e8e8;
    --ts-text:   #e8e8e8;
    --ts-bar-start: #00a199;
    --ts-bar-end:   #065f46;
    --ts-border: rgba(255,255,255,0.08);
  }
  .ts-grid {
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(155px, 1fr));
    gap: 0.5rem;
    margin: 0.5rem 0 0.25rem;
  }
  .ts-card {
    border: 1px solid var(--ts-border);
    border-radius: 10px;
    padding: 0.75rem 0.9rem 0.6rem;
    transition: border-color 0.3s;
    background: rgba(128,128,128,0.04);
  }
  .ts-card.ts-warm { border-color: rgba(200,127,10,0.45); }
  .ts-card.ts-hot  { border-color: rgba(231,76,60,0.55); box-shadow: 0 0 8px rgba(231,76,60,0.12); }
  .ts-name {
    font-size: 0.6rem;
    text-transform: uppercase;
    letter-spacing: 1.4px;
    color: var(--ts-label);
    margin-bottom: 0.3rem;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }
  .ts-val {
    font-size: 1.6rem;
    font-weight: 700;
    line-height: 1.1;
    font-family: monospace;
    /* --ts-accent is set at runtime from the active theme, same source as the
       bar below the number, so the two always agree. */
    color: var(--ts-accent, var(--ts-good));
    transition: color 0.3s;
  }
  .ts-val.ts-c-warn { color: var(--ts-warn); }
  .ts-val.ts-c-hot  { color: var(--ts-hot);  }
  .ts-unit {
    font-size: 0.78rem;
    font-weight: 400;
    color: var(--ts-label);
    margin-left: 2px;
  }
  .ts-bar {
    height: 3px;
    background: rgba(128,128,128,0.12);
    border-radius: 99px;
    overflow: hidden;
    margin-top: 0.4rem;
  }
  .ts-bar-fill {
    height: 100%;
    border-radius: 99px;
    transition: width 0.6s ease, background 0.3s;
    /* --ts-bar is set at runtime from the active theme; the gradient below is
       only the fallback for a theme that paints nothing we can read. */
    background: var(--ts-bar, linear-gradient(to right, var(--ts-bar-start), var(--ts-bar-end)));
  }
`));

// ── Borrow the theme's own accent for the bars and the readings ───────────
// The bars sit directly above LuCI's memory bars on the Overview page, and a
// colour that is right in one theme is wrong in the next — this widget is
// used on 21.02 and on 24/25, with different themes on each. So do not pick a
// colour: render a REAL LuCI progressbar off-screen, read whatever the active
// theme paints it with, and use that for both the bar and the number above it.
// Any theme, no per-theme special cases.
//
// The state colours (warm, hot) are deliberately NOT taken from the theme:
// they carry meaning, and a theme accent for "too hot" would lose it.
let themeAccentProbed = false;
function adoptThemeAccent() {
	if (themeAccentProbed) return;
	themeAccentProbed = true;
	try {
		const probe = E('div', {
			class: 'cbi-progressbar',
			style: 'position:absolute;left:-9999px;top:-9999px;width:100px;height:8px'
		}, E('div', { style: 'width:100%;height:100%' }));
		document.body.appendChild(probe);

		const inner = probe.firstElementChild;
		const cs = window.getComputedStyle(inner);
		const img = cs.backgroundImage;
		const col = cs.backgroundColor;

		const flat = (col && !/^rgba\(0, ?0, ?0, ?0\)$|^transparent$/.test(col))
			? col : null;

		let fill = null;
		if (img && img !== 'none' && img !== '')
			fill = img;                       // a themed gradient
		else if (flat)
			fill = flat;                      // a flat themed colour

		// The reading itself is text, so it needs a COLOUR — a gradient cannot
		// paint it. Take the flat background if there is one, otherwise lift
		// the first colour stop out of the gradient.
		let accent = flat;
		if (!accent && img) {
			const m = img.match(/rgba?\([^)]*\)|#[0-9a-f]{3,8}/i);
			if (m) accent = m[0];
		}

		probe.remove();

		if (fill)
			document.documentElement.style.setProperty('--ts-bar', fill);
		if (accent)
			document.documentElement.style.setProperty('--ts-accent', accent);
	} catch (e) {
		// Any failure just leaves the built-in palette in place.
	}
}

return baseclass.extend({
  title: _('Temperature'),
  viewName: 'temp-status',

  callStatus: rpc.declare({
    object: 'luci.temp-status',
    method: 'getStatus',
    expect: { '': {} }
  }),

  _useCgi: false,

  load() {
    // Prefer ubus: rpcd's ucode plugin keeps the script compiled and
    // resident, so this costs no fork at all. Falls back to the CGI's
    // ?live=1 endpoint (same shape, same temp-sensors.conf ordering)
    // when ubus is unavailable — e.g. OpenWrt 21.02, where ucode isn't
    // present until 22.03+ and luci.temp-status never registers.
    //
    // The ubus-vs-CGI choice is cached after the first *rejection*
    // (object truly not found) so a 21.02 router isn't retrying a
    // failing ubus call every poll. A successful-but-empty response
    // (e.g. temp-sensors.conf not written yet on first boot) does NOT
    // flip the cache — it just renders nothing this frame and tries
    // ubus again next poll, same as before.
    if (this._useCgi) {
      return fetch('/cgi-bin/get-temp-history.cgi?live=1')
        .then(r => r.ok ? r.json() : null)
        .catch(() => null);
    }
    return this.callStatus().catch(() => {
      this._useCgi = true;
      return fetch('/cgi-bin/get-temp-history.cgi?live=1')
        .then(r => r.ok ? r.json() : null)
        .catch(() => null);
    });
  },

  render(data) {
    if (!data || !data.sensors || !data.sensors.length) return;

    adoptThemeAccent();

    // Thresholds come from uci (temp_history.main) via the ubus backend.
    // The CGI's ?live=1 fallback does not carry them — that endpoint runs
    // every 60s and deliberately skips the uci read — so 21.02 routers keep
    // the compiled-in defaults here.
    const num  = (v, d) => { const n = parseFloat(v); return (n > 0) ? n : d; };
    const HOT  = num(data.warn, 65);
    const CRIT = Math.max(num(data.crit, 80), HOT + 1);
    const sensors = data.sensors.map((name, i) => {
      const v = data.current ? parseFloat(data.current[i]) : NaN;
      const tempF = (v > 0) ? v : null;
      const tempDisp = tempF != null ? tempF.toFixed(1) : null;
      return { name, tempF, tempDisp };
    });

    // Fans are not sensors, so they get their own compact cards rather
    // than being forced into the per-sensor grid. -1/null means no
    // tachometer; 0 means the fan has stopped, which must not read as "—".
    const fanCards = (data.fans || []).map((name, k) => {
      const raw = data.fan_rpm ? data.fan_rpm[k] : null;
      const n = (raw == null) ? null : parseInt(raw, 10);
      const disp = (n == null || isNaN(n) || n < 0) ? '—' : String(n);
      return E('div', { class: 'ts-card' }, [
        E('div', { class: 'ts-name', title: name }, name),
        E('div', { class: 'ts-val', title: disp + ' rpm' }, [
          disp,
          E('span', { class: 'ts-unit' }, ' rpm')
        ])
      ]);
    });

    // CPU and memory, from sys_now — the same three numbers the Temperature
    // page shows, but WITHOUT the min/max/avg rows: this widget is a glance at
    // the current state, and the records live on the page that keeps them.
    //
    // cpu is null until a baseline exists (the first poll after a reboot, or
    // the first ever), and 0 is a real reading — an idle router — so only null
    // and a negative become the em dash.
    const sysCards = [];
    const sn = data.sys_now;
    if (sn) {
      [ { key: 'cpu',        label: _('CPU Usage') },
        { key: 'mem',        label: _('RAM Used') },
        { key: 'mem_cached', label: _('RAM + Cache') } ].forEach(t => {
        const raw = sn[t.key];
        const n = (raw == null) ? NaN : parseFloat(raw);
        const have = !isNaN(n) && n >= 0;
        const pct = have ? Math.min(100, Math.max(0, n)) : 0;
        sysCards.push(E('div', { class: 'ts-card' }, [
          E('div', { class: 'ts-name', title: t.label }, t.label),
          E('div', { class: 'ts-val', title: have ? n.toFixed(1) + ' %' : '' }, [
            have ? String(Math.round(n)) : '—',
            E('span', { class: 'ts-unit' }, ' %')
          ]),
          E('div', { class: 'ts-bar' },
            E('div', { class: 'ts-bar-fill', style: `width:${pct}%` })
          )
        ]));
      });
    }

    const grid = E('div', { class: 'ts-grid' },
      sensors.map(({ name, tempF, tempDisp }) => {
        const v      = tempF || 0;
        const pct    = tempF != null ? Math.min(100, Math.max(0, (v - 20) / 80 * 100)) : 0;
        const isHot  = tempF != null && v >= CRIT;
        const isWarm = tempF != null && v >= HOT;
        const barClr = isHot  ? 'var(--ts-hot)'
                     : isWarm ? 'var(--ts-warn)'
                     :          'var(--ts-good)';
        return E('div', { class: 'ts-card' + (isHot ? ' ts-hot' : isWarm ? ' ts-warm' : '') }, [
          E('div', { class: 'ts-name', title: name }, name),
          E('div', { class: 'ts-val' + (isHot ? ' ts-c-hot' : isWarm ? ' ts-c-warn' : ''), title: tempF != null ? tempF.toFixed(1) + ' °C' : '' }, [
            tempF != null ? String(Math.round(tempF)) : '—',
            E('span', { class: 'ts-unit' }, ' °C')
          ]),
          E('div', { class: 'ts-bar' },
            E('div', { class: 'ts-bar-fill', style: `width:${pct}%` })
          )
        ]);
      }).concat(fanCards).concat(sysCards)
    );

    const existing = document.querySelector('.ts-grid');
    if (existing) { existing.replaceWith(grid); return; }
    return E('div', { class: 'cbi-section' }, grid);
  }
});
