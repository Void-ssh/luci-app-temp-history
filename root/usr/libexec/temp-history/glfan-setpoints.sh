#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Void
# glfan-setpoints.sh
# Minimum / Maximum thermal setpoints for GL.iNet's gl_fan controller, and a
# restore of the factory values.
#
# NOT web-reachable. Reached from the Settings panel through ubus
# (luci.temp-status.getSetpoints / setSetpoints / resetSetpoints), which LuCI
# authenticates. Also usable directly over SSH.
#
#   glfan-setpoints.sh status            JSON: support, current setpoints, mode
#   glfan-setpoints.sh set <min> <max>   apply a new band
#   glfan-setpoints.sh reset             restore the factory defaults
#
# ── What this is, and what it is not ──────────────────────────────────────
# This is NOT the same thing as the manual fan override in fan-control.sh.
# That one writes pwmN directly for a bounded number of minutes and hands the
# fan straight back afterwards. This one changes the SETPOINTS the GL.iNet
# gl_fan daemon regulates against — a persistent configuration change, not a
# timed override. The two are independent and can both be in use.
#
# Every substitution below has been checked against real GL.iNet firmware
# rather than assumed — see the `check` action, which measures each one on the
# device before anything is written. Several are deliberately narrower than the
# obvious version, and the comment at each says which failure made it so.
#
# ── The setpoints ────────────────────────────────────────────────────────
#   Minimum   the temperature at which the fan starts, at its lowest duty.
#             Raising it keeps the fan off longer.
#   Fan-On    the target. gl_fan ramps toward 100% as this is approached and
#             passed. NOT editable here — see below.
#   Warning   what the firmware logs and colours against. NOT editable here.
#   Maximum   the top of the range. On stock firmware this is a fixed 90°C
#             ceiling baked into the web UI; raising it is what lets a
#             setpoint above 90 be expressed at all.
#
# Only Minimum and Maximum are editable from the page. Fan-On and Warning are
# read out of UCI, carried through unchanged, and clamped into the new band
# only when the band would otherwise exclude them — because the hierarchy
#
#     Minimum ≤ Fan-On ≤ Maximum,  Minimum ≤ Warning ≤ Maximum
#
# has to hold or gl_fan's own comparisons stop making sense.
#
# ── Why every change starts from the factory files ───────────────────────
# The patches below are SUBSTITUTIONS against the pristine text: `-lt 6[0-9]`
# matches a stock threshold and nothing else, and `attrs:{min:...,max:...}`
# has already been rewritten once the first patch has run. Applying them to an
# already-patched file is not idempotent — it either matches nothing (leaving
# a stale value in place, silently) or matches the wrong thing. So a `set`
# restores the baseline first and patches that, exactly as the original does.
# Without a baseline to restore, `set` refuses rather than compounding.
#
# ── System side vs web-UI side ───────────────────────────────────────────
# Two separate things happen, and only the first is on by default:
#
#   system  UCI glfan.globals.* and /lib/functions/gl_util.sh — this is what
#           gl_fan actually regulates against. Always applied.
#   web UI  GL's own admin bundles (/www/js/app.*.js.gz, the overview view,
#           the i18n strings) — cosmetic unless you also use GL's page, where
#           an unwidened slider will fight the value you set here. Applied
#           only when temp_history.main.glfan_ui_patch is 1.
#
# The web-UI half rewrites minified firmware bundles in place. That is why it
# is opt-in: it is the risky half, it is undone by any firmware upgrade, and
# it is pointless if you drive the fan from this page.

DATA_DIR="/root/website"
BASELINE_DIR="$DATA_DIR/glfan-baseline"

GL_MODEL_FILE="/proc/gl-hw-info/model"
UTIL="/lib/functions/gl_util.sh"
GLFAN_CONF="/etc/config/glfan"
VIEW_GZ="/www/views/gl-sdk4-ui-overview.common.js.gz"
I18N="/www/i18n/gl-sdk4-ui-overview.en.json"
APP_DIR="/www/js"
FAN_INIT="/etc/init.d/gl_fan"

# The read-only firmware image. Spelled out as one variable per file rather
# than pasted together from a prefix, so each is a plain assignment the test
# suite can point at a staged tree — the same way every other script here is
# made testable.
ROM_UTIL="/rom/lib/functions/gl_util.sh"
ROM_GLFAN="/rom/etc/config/glfan"
ROM_VIEW_GZ="/rom/www/views/gl-sdk4-ui-overview.common.js.gz"
ROM_I18N="/rom/www/i18n/gl-sdk4-ui-overview.en.json"
ROM_APP_DIR="/rom/www/js"

LIMIT_MAX=120        # the script's own ceiling, kept
FALLBACK_MIN=70      # stock GL values, used only when nothing else answers
FALLBACK_MAX=90
FALLBACK_CUR=75
FALLBACK_WRN=75

log() { logger -t temp-history -p daemon.notice "setpoints: $*" 2>/dev/null; }

err_json() { printf '{"status":"error","error":"%s"}\n' "$1"; }

uci_get() {  # uci_get <config.section.option>
  uci -q get "$1" 2>/dev/null
}

int_or() {  # int_or <value> <default>
  case "$1" in ''|*[!0-9]*) printf '%s' "$2" ;; *) printf '%s' "$1" ;; esac
}

ui_patch_enabled() {
  [ "$(int_or "$(uci_get temp_history.main.glfan_ui_patch)" 0)" = "1" ]
}

# The model string lands inside sed and awk addresses. Anything that is not a
# word character could change what those expressions mean, so it is dropped
# rather than escaped — GL model names are [a-z0-9-] in practice.
gl_model() {
  _gm=""
  [ -r "$GL_MODEL_FILE" ] && read -r _gm 2>/dev/null < "$GL_MODEL_FILE"
  printf '%s' "$_gm" | tr -cd 'A-Za-z0-9_-'
}

# ── Support detection ─────────────────────────────────────────────────────
# Two independent facts, because either alone is misleading: GL hardware
# running a community build has the /proc entry but no gl_fan, and a stray
# glfan config on a non-GL board would be a config for nothing.
unsupported_reason() {
  [ -n "$(gl_model)" ] || { printf 'not GL.iNet firmware (no %s)' "$GL_MODEL_FILE"; return 0; }
  [ -f "$GLFAN_CONF" ] || [ -f "$ROM_GLFAN" ] || {
    printf 'no gl_fan configuration on this device'; return 0; }
  [ -f "$UTIL" ] || { printf 'missing %s' "$UTIL"; return 0; }
  printf ''
}

# ── Baselines ─────────────────────────────────────────────────────────────
# /rom is the right source: it is the read-only firmware image, so it is
# pristine by construction however many times anything has patched /etc or
# /www. Every GL.iNet firmware has it.
#
# WHY THE FALLBACK: a device booted without an overlay has no /rom, and there
# the only baseline available is a copy taken before we first touch the file.
# It is taken ONCE and never refreshed, so a later `set` still patches
# pristine text. It is honestly weaker than /rom — if something else had
# already patched gl_util.sh before this package ever ran, that patched state
# becomes the baseline — so `status` reports which one is in use and the page
# says so.
baseline_kind() {
  if [ -f "$ROM_UTIL" ]; then printf 'rom'
  elif [ -f "$BASELINE_DIR/gl_util.sh" ]; then printf 'snapshot'
  else printf 'none'
  fi
}

# Take the one-time snapshot. Never overwrites: a second call after we have
# patched would capture our own patches as "factory".
snapshot_baseline() {
  [ -f "$ROM_UTIL" ] && return 0
  [ -f "$BASELINE_DIR/gl_util.sh" ] && return 0
  [ -f "$UTIL" ] || return 1
  mkdir -p "$BASELINE_DIR" 2>/dev/null || return 1
  cp "$UTIL" "$BASELINE_DIR/gl_util.sh" 2>/dev/null || return 1
  [ -f "$GLFAN_CONF" ] && cp "$GLFAN_CONF" "$BASELINE_DIR/glfan"     2>/dev/null
  [ -f "$VIEW_GZ" ]    && cp "$VIEW_GZ"    "$BASELINE_DIR/view.js.gz" 2>/dev/null
  [ -f "$I18N" ]       && cp "$I18N"       "$BASELINE_DIR/i18n.json"  2>/dev/null
  _sb_app=$(find "$APP_DIR" -name 'app.*.js.gz' -type f 2>/dev/null | head -n 1)
  [ -n "$_sb_app" ] && cp "$_sb_app" "$BASELINE_DIR/$(basename "$_sb_app")" 2>/dev/null
  log "took a one-time baseline snapshot (no /rom on this device)"
  return 0
}

# baseline_file <what> -> a readable pristine copy, or nothing.
# Keyed by a short name rather than by the installed path, because the two
# sources lay their files out differently and matching on the path would tie
# this to /rom mirroring the live tree exactly.
baseline_file() {
  case "$(baseline_kind)" in
    rom)
      case "$1" in
        util)  [ -f "$ROM_UTIL" ]     && printf '%s' "$ROM_UTIL" ;;
        glfan) [ -f "$ROM_GLFAN" ]    && printf '%s' "$ROM_GLFAN" ;;
        view)  [ -f "$ROM_VIEW_GZ" ]  && printf '%s' "$ROM_VIEW_GZ" ;;
        i18n)  [ -f "$ROM_I18N" ]     && printf '%s' "$ROM_I18N" ;;
      esac
      ;;
    snapshot)
      case "$1" in
        util)  [ -f "$BASELINE_DIR/gl_util.sh" ] && printf '%s' "$BASELINE_DIR/gl_util.sh" ;;
        glfan) [ -f "$BASELINE_DIR/glfan" ]      && printf '%s' "$BASELINE_DIR/glfan" ;;
        view)  [ -f "$BASELINE_DIR/view.js.gz" ] && printf '%s' "$BASELINE_DIR/view.js.gz" ;;
        i18n)  [ -f "$BASELINE_DIR/i18n.json" ]  && printf '%s' "$BASELINE_DIR/i18n.json" ;;
      esac
      ;;
  esac
}

# ── Restore ───────────────────────────────────────────────────────────────
# The system half: the library gl_fan sources and the config it reads. This is
# what actually changes cooling behaviour, so it is restored on every path.
restore_system() {
  restore_util_file
  restore_glfan_config
  run_fan_init
  return 0
}

# Just the library this package patches, put back to pristine so the
# substitutions have stock text to match. This is ALL that `set` needs, and it
# is deliberately the whole of what `set` does — see do_set.
restore_util_file() {
  _ruf=$(baseline_file util)
  [ -n "$_ruf" ] && cp "$_ruf" "$UTIL"
  return 0
}

# The shipped glfan config is a TEMPLATE, not a running configuration. On a
# GL.iNet firmware 4.9.1 /rom's copy carries only enabled, sysfs and div —
# temperature, warn_temperature and minimum_temperature are absent, because
# fan_init writes them at runtime. So copying it over live config DESTROYS the
# running setpoints, and is only safe when fan_init runs immediately after to
# put them back. The two belong together, and only on the reset path.
restore_glfan_config() {
  _rgc=$(baseline_file glfan)
  [ -n "$_rgc" ] && cp "$_rgc" "$GLFAN_CONF"
  return 0
}

# gl_util.sh's own provisioner, which repopulates UCI with the real factory
# values for THIS model — which is why the config above is not hand-written.
# Sourced in a subshell: it defines a large number of functions and we want
# none of them surviving into ours.
run_fan_init() {
  [ -f "$UTIL" ] || return 0
  (
    # shellcheck source=/dev/null
    . "$UTIL" 2>/dev/null
    command -v fan_init >/dev/null 2>&1 && fan_init >/dev/null 2>&1
    uci -q commit glfan
  ) >/dev/null 2>&1
  return 0
}

# The web-UI half. Separate because it is separately optional, and because a
# device with no GL admin bundles (a community build on GL hardware) must not
# have a failure here stop the system half from being restored.
#
# NOTE: this puts back the FIRMWARE bundles. Anything else that has modified
# them — a third-party tool injecting a button into GL's admin UI, say — is
# removed by this restore and has to be re-applied by whatever put it there.
# The page says so before you press the button.
# Each destination is checked for an existing directory first. A GL device
# running a community build has gl_fan and gl_util.sh but no GL admin bundles,
# and a `cp` into a directory that is not there would put an error on rpcd's
# stderr on every single call while the system half worked perfectly.
restore_ui() {
  _ru_v=$(baseline_file view)
  [ -n "$_ru_v" ] && [ -d "$(dirname "$VIEW_GZ")" ] && cp "$_ru_v" "$VIEW_GZ" 2>/dev/null

  _ru_i=$(baseline_file i18n)
  [ -n "$_ru_i" ] && [ -d "$(dirname "$I18N")" ] && cp "$_ru_i" "$I18N" 2>/dev/null

  [ -d "$APP_DIR" ] || return 0
  case "$(baseline_kind)" in
    rom)
      _ru_a=$(find "$ROM_APP_DIR" -name 'app.*.js.gz' -type f 2>/dev/null | head -n 1)
      [ -n "$_ru_a" ] && cp "$_ru_a" "$APP_DIR/$(basename "$_ru_a")" 2>/dev/null
      ;;
    snapshot)
      for _ru_b in "$BASELINE_DIR"/app.*.js.gz; do
        [ -f "$_ru_b" ] || continue
        cp "$_ru_b" "$APP_DIR/$(basename "$_ru_b")" 2>/dev/null
      done
      ;;
  esac
  return 0
}

fan_restart() { [ -x "$FAN_INIT" ] && "$FAN_INIT" restart >/dev/null 2>&1; return 0; }

# ── Reading the current state ─────────────────────────────────────────────
# UCI is the source of truth for min / fan-on / warning: gl_fan reads it, and
# it is correct whether or not the web UI was ever patched.
#
# The MAXIMUM has no UCI home — on stock firmware it exists only as a literal
# inside the web-UI bundle, which is exactly why the original script had to go
# and grep it back out. Since the UI half is optional here, that grep would
# report a stale 90 on a router configured system-only. So the applied ceiling
# is recorded in temp_history.main.glfan_max, and the bundle is consulted only
# as a fallback for a router patched by something else.
view_attr_max() {
  [ -f "$VIEW_GZ" ] || return 1
  _vam=$(gzip -dc "$VIEW_GZ" 2>/dev/null | grep -oE 'attrs:\{min:[-0-9]+,max:[0-9]+' | head -n 1)
  if [ -n "$_vam" ]; then
    _vam=$(printf '%s' "$_vam" | cut -d: -f4)
    case "$_vam" in ''|*[!0-9]*) ;; *) printf '%s' $(( _vam - 1 )); return 0 ;; esac
  fi
  _vam=$(gzip -dc "$VIEW_GZ" 2>/dev/null | grep -oE 'maximumTemperature:[^}]*' | grep -oE '[0-9]{2,3}' | head -n 1)
  case "$_vam" in ''|*[!0-9]*) return 1 ;; *) printf '%s' "$_vam" ;; esac
}

# ── Does a setpoint reach the daemon at all? ──────────────────────────────
# gl_fan is started by an init script that builds its command line out of UCI,
# and it only reads the options it names. On GL.iNet firmware 4.9.1
# get_fan_config reads enabled, sysfs, div, temperature, proportion,
# integration, differential and debug — `minimum_temperature` and
# `warn_temperature` appear nowhere, and the running daemon is
#
#     /usr/bin/gl_fan -T <zone> -D 1000 -t 75
#
# So on that board the minimum is a WEB-UI DISPLAY VALUE and nothing else:
# changing it cannot change when the fan starts. That is not a defect to fix
# here — it is how the firmware works — but presenting a control that silently
# does nothing would be. It is reported, and the page says so.
init_reads() {  # init_reads <uci option name>
  [ -f "$FAN_INIT" ] || return 1
  grep -q "$1" "$FAN_INIT" 2>/dev/null
}

cur_min() { int_or "$(uci_get glfan.globals.minimum_temperature)" "$FALLBACK_MIN"; }
cur_fanon() { int_or "$(uci_get glfan.globals.temperature)" "$FALLBACK_CUR"; }
cur_warn() { int_or "$(uci_get glfan.globals.warn_temperature)" "$FALLBACK_WRN"; }

cur_max() {
  _cm=$(uci_get temp_history.main.glfan_max)
  case "$_cm" in ''|*[!0-9]*) ;; *) printf '%s' "$_cm"; return 0 ;; esac
  _cm=$(view_attr_max) && { printf '%s' "$_cm"; return 0; }
  printf '%s' "$FALLBACK_MAX"
}

do_status() {
  _reason=$(unsupported_reason)
  if [ -n "$_reason" ]; then
    printf '{"supported":false,"reason":"%s"}\n' "$_reason"
    return 0
  fi

  _running=0
  pgrep -f '/usr/bin/gl_fan' >/dev/null 2>&1 && _running=1

  _uiavail=0
  [ -f "$VIEW_GZ" ] && _uiavail=1

  _uip=0; ui_patch_enabled && _uip=1

  _minlive=0; init_reads minimum_temperature && _minlive=1
  _warnlive=0; init_reads warn_temperature && _warnlive=1

  printf '{"supported":true,"model":"%s","min":%s,"fan_on":%s,"warn":%s,"max":%s,"limit":%s,"ui_patch":%s,"ui_available":%s,"baseline":"%s","running":%s,"min_live":%s,"warn_live":%s}\n' \
    "$(gl_model)" "$(cur_min)" "$(cur_fanon)" "$(cur_warn)" "$(cur_max)" \
    "$LIMIT_MAX" "$_uip" "$_uiavail" "$(baseline_kind)" "$_running" \
    "$_minlive" "$_warnlive"
}

# ── The system patch ──────────────────────────────────────────────────────
# Ported from sync_system_and_ui, sections 1 and 2. Runs against restored
# text, so every expression here is matching stock firmware content.
#
# The target file is a PARAMETER, not the constant, so that `check` can run
# this exact function against a scratch copy. A dry run that reimplements the
# expressions it is meant to be verifying would verify nothing.
patch_system_file() {  # patch_system_file <file> <min> <fan_on> <warn>
  _ps_f="$1"; _ps_min="$2"; _ps_cur="$3"; _ps_wrn="$4"
  _ps_model=$(gl_model)

  # The hardware floor comparisons. Stock firmwares use a 60s or a 70s
  # literal depending on the board, hence both.
  sed -i "s/-lt 6[0-9]/-lt $_ps_min/g" "$_ps_f" 2>/dev/null
  sed -i "s/-lt 7[0-9]/-lt $_ps_min/g" "$_ps_f" 2>/dev/null

  # Newer firmwares carry a per-model case block; older ones a single pair of
  # locals. Target whichever this device has, so a model block is not edited
  # on a firmware that has none (which would rewrite another model's values).
  #
  # [0-9][0-9]* — at least ONE digit, not the original's [0-9]*. An empty match
  # is what makes `minimum_temperature=` match the `uci set ...
  # minimum_temperature="$minimum_temperature"` line further down the same
  # file, turning it into `minimum_temperature=55"$minimum_temperature"`. These
  # substitutions are only ever meant to hit a numeric default.
  if [ -n "$_ps_model" ] && \
     awk "/$_ps_model[)]/,/;;/" "$_ps_f" 2>/dev/null | grep -q "temperature="; then
    sed -i "/$_ps_model[)]/,/;;/ s/\(minimum_temperature=\)[0-9][0-9]*/\1$_ps_min/" "$_ps_f" 2>/dev/null
    sed -i "/$_ps_model[)]/,/;;/ s/\([[:space:]]temperature=\)[0-9][0-9]*/\1$_ps_cur/" "$_ps_f" 2>/dev/null
  else
    sed -i "s/\(local minimum_temperature=\)[0-9][0-9]*/\1$_ps_min/" "$_ps_f" 2>/dev/null
    sed -i "s/\(local temperature=\)[0-9][0-9]*/\1$_ps_cur/" "$_ps_f" 2>/dev/null
  fi

  # Anchored to the start of a line, which the original was not.
  #
  # On GL.iNet firmware 4.9.1 the unanchored version's ONLY match in the
  # whole file was
  #
  #     uci set glfan.@globals[0].warn_temperature="$temperature"
  #
  # inside fan_init — the firmware's own provisioning, where warn is DERIVED
  # from the fan-on target. Rewriting it to a literal breaks that derivation
  # permanently: every later fan_init writes the frozen number regardless of
  # what the target is. Anchoring means a firmware that derives warn rather
  # than defaulting it simply gets no edit, which is the correct outcome.
  sed -i "s/^\([[:space:]]*\)local warn_temperature=.*\$/\1local warn_temperature=\"$_ps_wrn\"/" "$_ps_f" 2>/dev/null
  sed -i "s/^\([[:space:]]*\)warn_temperature=.*\$/\1warn_temperature=\"$_ps_wrn\"/" "$_ps_f" 2>/dev/null
}

# The UCI half is separate from the file half so the dry run can exercise the
# file half without writing anything anywhere real.
patch_system_uci() {  # patch_system_uci <min> <fan_on> <warn>
  uci -q set "glfan.globals.minimum_temperature=$1"
  uci -q set "glfan.globals.temperature=$2"
  uci -q set "glfan.globals.warn_temperature=$3"
  uci -q commit glfan
}

# ── The web-UI patch ──────────────────────────────────────────────────────
# Ported from sync_system_and_ui, sections 3 and 4. Cosmetic to this package;
# it only matters if you also drive the fan from GL's own admin page, where an
# un-widened slider snaps a value above 90 back down.
patch_ui() {  # patch_ui <view.gz> <i18n> <app-dir> <min> <fan_on> <max>
  _pu_view="$1"; _pu_i18n="$2"; _pu_appdir="$3"
  _pu_min="$4"; _pu_cur="$5"; _pu_max="$6"
  [ -f "$_pu_view" ] || return 0

  _pu_bmin=$(( _pu_min - 1 ))
  _pu_bmax=$(( _pu_max + 1 ))

  gunzip -f "$_pu_view" 2>/dev/null || return 0
  v="${_pu_view%.gz}"
  [ -f "$v" ] || return 0

  # Every guard below is judged on this untouched copy, never on the file being
  # edited — see sed_guarded. Kept in /tmp so nothing extra is ever left inside
  # /www, even if this is interrupted.
  # Deliberately NOT a trap. Traps are per-shell, not per-function: setting one
  # here and clearing it with `trap - EXIT` on the way out also removed the
  # cleanup that do_check had installed, and the check action started leaving
  # its own scratch directories behind. There is no early return past this
  # point, so one removal at the end is enough.
  _pu_ctx="/tmp/th-ui-context.$$"
  cp "$v" "$_pu_ctx" 2>/dev/null

  # A: computed-property overrides
  sed_guarded "$v" "$_pu_ctx" 'minimum_temperature:t' \
    "s/minimum_temperature:t/minimum_temperature:ignore,t=$_pu_min/g" "minimum_temperature:t"
  sed_guarded "$v" "$_pu_ctx" 'maximum_temperature:t' \
    "s/maximum_temperature:t/maximum_temperature:ignore,t=$_pu_max/g" "maximum_temperature:t"
  sed_guarded "$v" "$_pu_ctx" 'maximumTemperature:\(\)=>[0-9]+' \
    "s/maximumTemperature:()=>[0-9][0-9]*/maximumTemperature:()=>$_pu_max/g" "maximumTemperature"

  # B: literal logic guards.
  #
  # `t<70` and `t>90` are SUBSTRINGS with no boundary. On GL.iNet firmware
  # 4.9.1 `t>90` matched exactly one thing in the bundle:
  #
  #     t.exports=function(t){if(t>9007199254740991)throw r("Maximum allowed...
  #
  # the Number.MAX_SAFE_INTEGER check in a core-js polyfill, which the original
  # silently rewrote to 10007199254740991. Two defences, both needed: a
  # trailing non-digit so the literal cannot be a prefix of a longer number,
  # and the temperature-context guard for whatever still matches.
  sed_guarded "$v" "$_pu_ctx" 't<70[^0-9]' "s/t<70\\([^0-9]\\)/t<$_pu_min\\1/g" "t<70"
  sed_guarded "$v" "$_pu_ctx" 't>90[^0-9]' "s/t>90\\([^0-9]\\)/t>$_pu_max\\1/g" "t>90"
  sed_guarded "$v" "$_pu_ctx" 'ature=70[^0-9]' "s/ature=70\\([^0-9]\\)/ature=$_pu_min\\1/g" "ature=70"
  sed_guarded "$v" "$_pu_ctx" 'ature=90[^0-9]' "s/ature=90\\([^0-9]\\)/ature=$_pu_max\\1/g" "ature=90"

  # C: snap-back prevention. These name the properties outright, so the guard
  # is a formality — but it costs nothing and keeps one rule for the file.
  sed_guarded "$v" "$_pu_ctx" 't<this\.minimumTemperature' \
    "s/t<this.minimumTemperature/t<$_pu_min/g" "t<this.minimumTemperature"
  sed_guarded "$v" "$_pu_ctx" 't>this\.maximumTemperature' \
    "s/t>this.maximumTemperature/t>$_pu_max/g" "t>this.maximumTemperature"
  sed_guarded "$v" "$_pu_ctx" 'this\.temperature=this\.minimumTemperature' \
    "s/this.temperature=this.minimumTemperature/this.temperature=$_pu_min/g" "snap-back min"
  sed_guarded "$v" "$_pu_ctx" 'this\.temperature=this\.maximumTemperature' \
    "s/this.temperature=this.maximumTemperature/this.temperature=$_pu_max/g" "snap-back max"

  # D: the slider's own bounds, one degree wide either side so the endpoints
  # are selectable rather than sitting exactly on the limit. Guarded because a
  # page may well have more than one slider, and this expression does not say
  # which one it means.
  sed_guarded "$v" "$_pu_ctx" 'attrs:\{min:[^,]+,max:[^,}]+' \
    "s/attrs:{min:[^,]*[0-9a-zA-Z.-]*,max:[0-9a-zA-Z.+-]*/attrs:{min:$_pu_bmin,max:$_pu_bmax/g" \
    "slider bounds"

  # E: the scale labels
  _pu_marks="${_pu_min}:'${_pu_min}°C'"
  _pu_span=$(( _pu_max - _pu_min ))
  _pu_step=10
  [ "$_pu_span" -le 50 ] && _pu_step=5
  _pu_i=$(( _pu_min + _pu_step ))
  _pu_last="$_pu_min"
  while [ "$_pu_i" -le "$_pu_max" ]; do
    _pu_marks="$_pu_marks,$_pu_i:'$_pu_i°C'"
    _pu_last="$_pu_i"
    _pu_i=$(( _pu_i + _pu_step ))
  done
  # DEVIATION from the original, on purpose: it stepped from the minimum and
  # stopped, so a band whose width is not a multiple of the step left the
  # scale ending short of its own maximum — 50–105 labelled up to 100, with
  # the last five degrees unlabelled but selectable. Label the endpoint.
  [ "$_pu_last" = "$_pu_max" ] || _pu_marks="$_pu_marks,$_pu_max:'$_pu_max°C'"
  sed_guarded "$v" "$_pu_ctx" 'marks:t.tMarks' "s/marks:t.tMarks/marks:{$_pu_marks}/g" "scale marks"

  # F: the info string. It is a template on stock firmware, so replacing it
  # with literals is what pins the displayed range. The view copy matches
  # nothing on every firmware we have seen and the i18n copy matches once;
  # both are attempted because that has not been true of every release.
  _pu_pat="fan start is [^.]*"
  _pu_rep="fan start is $_pu_min °C ~ $_pu_max °C "
  sed -i "s/$_pu_pat/$_pu_rep/g" "$v"
  [ -f "$_pu_i18n" ] && sed -i "s/$_pu_pat/$_pu_rep/g" "$_pu_i18n"

  gzip -f "$v"

  # The global validator in the app bundle, which rejects out-of-range values
  # before the view ever sees them.
  #
  # ── THE GUARD, AND WHY IT IS NOT OPTIONAL ────────────────────────────
  # `[0-9]{1,3}||i<[0-9]{2,3}` is a SHAPE, not a name. It describes any pair of
  # small integers on either side of `||i<`, and the original applies it
  # globally with no check on what it hit.
  #
  # On GL.iNet firmware 4.9.1 the only thing it matches in the whole
  # bundle is
  #
  #     ===i||270===i?t-=e/2:(i>270||i<90)&&(t-=e)
  #
  # which is text-rotation maths — 270 and 90 DEGREES, nothing to do with
  # temperature. Rewriting it to `55||i<101` corrupts unrelated rendering in
  # GL's admin UI, silently, and the two neighbouring `temperature:NN`
  # expressions match nothing there at all: on that firmware the whole
  # app-bundle patch has no upside and one real downside.
  #
  # So: apply it only when EVERY match sits next to the word "temperature".
  # Per-file, not per-occurrence — rewriting some matches and not others would
  # need awk over a single multi-megabyte minified line, and a partial rewrite
  # is a worse failure than none. If any match does not qualify, the app bundle
  # is left alone and the reason is logged. `check` reports the same verdict
  # before anything is written.
  _pu_app=$(find "$_pu_appdir" -name 'app.*.js.gz' -type f 2>/dev/null | head -n 1)
  if [ -n "$_pu_app" ]; then
    gunzip -f "$_pu_app" 2>/dev/null
    _pu_appf="${_pu_app%.gz}"
    if [ -f "$_pu_appf" ]; then
      if app_validator_safe "$_pu_appf"; then
        sed -i "s/[0-9]\{1,3\}||i<[0-9]\{2,3\}/${_pu_min}||i<$(( _pu_max + 1 ))/g" "$_pu_appf"
        # Stop the initial state snapping back on page load.
        sed -i "s/temperature:6[90]/temperature:$_pu_cur/g" "$_pu_appf"
        sed -i "s/temperature:76/temperature:$_pu_cur/g" "$_pu_appf"
      else
        log "app bundle left alone: the validator expression matches code that is not a temperature range"
      fi
      gzip -f "$_pu_appf"
    fi
  fi
  rm -f "$_pu_ctx"
  return 0
}

# ── The context guard ─────────────────────────────────────────────────────
# True only when <ere> matches at least once in <file> and EVERY match has the
# word "temperature" within 40 characters either side.
#
# This is the rule that stopped three separate false positives on real GL
# firmware: `t>90` hitting a Number.MAX_SAFE_INTEGER polyfill, the app
# bundle's validator hitting text-rotation maths, and — with the digit
# boundary — `t<70` being a prefix of a longer literal. Every one of them was
# silent: a wrong match rewrites cleanly and exits 0.
#
# Per file, not per occurrence: rewriting some matches and not others needs awk
# over a single multi-megabyte minified line, and a partial rewrite is a worse
# failure than none.
all_matches_temperature() {  # all_matches_temperature <file> <ere>
  [ -f "$1" ] || return 1
  _amt_all=$(grep -oE -- "$2" "$1" 2>/dev/null | wc -l | tr -d ' \t')
  [ "${_amt_all:-0}" -gt 0 ] || return 1
  _amt_ok=$(grep -oE -- ".{0,40}$2.{0,40}" "$1" 2>/dev/null | grep -ci 'emperature')
  [ "${_amt_ok:-0}" = "${_amt_all:-0}" ]
}

# The guard is evaluated against PRISTINE text, held separately, not against
# the file being edited. Earlier substitutions rewrite the neighbourhood later
# ones are judged on: patching the slider replaces
# `min:t.minimumTemperature-1,max:t.maximumTemperature+1` with `min:49,max:106`
# and takes the word "Temperature" out of the 40 characters preceding
# `marks:t.tMarks`, so the scale patch — which had qualified a moment earlier —
# was then refused. A guard whose answer depends on what has already run is not
# a guard.
sed_guarded() {  # sed_guarded <target> <context-file> <count-ere> <sed-expr> <label>
  if all_matches_temperature "$2" "$3"; then
    sed -i "$4" "$1" 2>/dev/null
  else
    _sg_n=$(grep -oE -- "$3" "$2" 2>/dev/null | wc -l | tr -d ' \t')
    [ "${_sg_n:-0}" -gt 0 ] && \
      log "web UI: skipped '$5' — $_sg_n match(es), not all in temperature context"
  fi
  return 0
}

app_validator_safe() {  # app_validator_safe <unpacked-app.js>
  all_matches_temperature "$1" '[0-9]{1,3}\|\|i<[0-9]{2,3}'
}

# ── Actions ───────────────────────────────────────────────────────────────
do_set() {  # do_set <min> <max>
  _reason=$(unsupported_reason)
  [ -n "$_reason" ] && { err_json "$_reason"; return 0; }

  _min="$1"; _max="$2"
  case "$_min" in ''|*[!0-9]*) err_json "minimum must be a whole number of degrees"; return 0 ;; esac
  case "$_max" in ''|*[!0-9]*) err_json "maximum must be a whole number of degrees"; return 0 ;; esac
  [ "$_min" -le "$LIMIT_MAX" ] || { err_json "minimum must be 0-$LIMIT_MAX °C"; return 0; }
  [ "$_max" -le "$LIMIT_MAX" ] || { err_json "maximum must not exceed $LIMIT_MAX °C"; return 0; }
  [ "$_max" -gt "$_min" ] || { err_json "maximum must be above minimum"; return 0; }

  snapshot_baseline
  [ "$(baseline_kind)" = "none" ] && {
    err_json "no factory copy of $UTIL to patch from — refusing, because these edits are not repeatable against an already-patched file"
    return 0; }

  # Fan-On and Warning are carried through, not edited here. They are clamped
  # only when the new band would leave them outside it — an unclamped Fan-On
  # above the new Maximum is a controller regulating toward a target the UI
  # says is unreachable, which is worse than a value the user did not choose.
  _cur=$(cur_fanon); _wrn=$(cur_warn)
  _adj=""
  if [ "$_cur" -lt "$_min" ]; then _cur="$_min"; _adj="fan_on"
  elif [ "$_cur" -gt "$_max" ]; then _cur="$_max"; _adj="fan_on"; fi
  if [ "$_wrn" -lt "$_min" ]; then _wrn="$_min"; _adj="${_adj:+$_adj,}warn"
  elif [ "$_wrn" -gt "$_max" ]; then _wrn="$_max"; _adj="${_adj:+$_adj,}warn"; fi

  _dui=0; ui_patch_enabled && _dui=1

  # Baseline first, then patch — see the note at the top of this file. But only
  # the FILE that is about to be patched.
  #
  # `set` used to call restore_system, which also overwrote /etc/config/glfan
  # from the firmware template and then ran fan_init to repopulate it. That was
  # a lot of blast radius for a setpoint change: on that firmware the template
  # has no `temperature` at all, so the live fan-on target was destroyed and
  # then re-provisioned on every call, and a 2000-line firmware library was
  # sourced each time to do it. Nothing here needs any of that — the three
  # values are written directly below, and the ones not being changed should be
  # left exactly as they are rather than round-tripped through factory defaults.
  # Provisioning belongs to `reset`, which is the operation that actually wants
  # the firmware's own values back.
  restore_util_file
  [ "$_dui" = "1" ] && restore_ui

  patch_system_file "$UTIL" "$_min" "$_cur" "$_wrn"
  patch_system_uci "$_min" "$_cur" "$_wrn"
  [ "$_dui" = "1" ] && patch_ui "$VIEW_GZ" "$I18N" "$APP_DIR" "$_min" "$_cur" "$_max"

  # The ceiling has no UCI home in glfan, so this package keeps it.
  uci -q set "temp_history.main.glfan_max=$_max"
  uci -q set "temp_history.main.glfan_min=$_min"
  uci -q commit temp_history

  fan_restart
  log "min=$_min max=$_max fan_on=$_cur warn=$_wrn ui_patch=$_dui${_adj:+ adjusted=$_adj}"

  printf '{"status":"ok","min":%s,"max":%s,"fan_on":%s,"warn":%s,"ui_patched":%s,"adjusted":"%s"}\n' \
    "$_min" "$_max" "$_cur" "$_wrn" "$_dui" "$_adj"
}

do_reset() {
  _reason=$(unsupported_reason)
  [ -n "$_reason" ] && { err_json "$_reason"; return 0; }

  [ "$(baseline_kind)" = "none" ] && {
    err_json "no factory copy to restore from on this device"; return 0; }

  # Both halves, unconditionally. Someone pressing "restore factory defaults"
  # wants the firmware's state back, not the firmware's state except for the
  # part they had switched off in a checkbox — and the web-UI bundles may well
  # have been patched by the shell script this feature was ported from.
  restore_system
  restore_ui

  uci -q delete temp_history.main.glfan_max
  uci -q delete temp_history.main.glfan_min
  uci -q commit temp_history

  fan_restart
  log "restored factory defaults"

  printf '{"status":"ok","reset":true,"min":%s,"fan_on":%s,"warn":%s,"max":%s}\n' \
    "$(cur_min)" "$(cur_fanon)" "$(cur_warn)" "$(cur_max)"
}

# ── Pre-flight ────────────────────────────────────────────────────────────
# `check` writes nothing outside a scratch directory in /tmp: no uci, no
# gl_fan restart, nothing under /lib, /etc or /www. Everything it reports is
# measured on THIS device's firmware.
#
# Why it exists. Every substitution in this file was written against one
# person's firmware and is a bet that yours has the same text. A bet that
# loses is not loud: a `sed` that matches nothing exits 0 and changes nothing,
# so a setpoint would appear to be applied while the daemon kept its old
# value. Counting the matches BEFORE writing is the only way to know, and it
# is worth doing on every firmware release, not once.
#
# Output is human-readable text, deliberately — this is a diagnostic to read,
# not a payload to parse, and it is the one action not exposed over ubus.
CHECK_DIR="/tmp/th-setpoint-check.$$"

# grep -c counts LINES. Minified JavaScript is one enormous line, so it would
# report 1 for twenty occurrences. Count matches, not lines.
# `--` matters: several of these patterns start with a dash, and without it
# grep reads the pattern as options. (This function was written without it and
# reported 0 matches for the two hardware-floor expressions — the exact
# false negative the whole action exists to catch, which is a good argument
# for the action.)
n_of() {  # n_of <ERE> <file>
  [ -f "$2" ] || { printf '0'; return; }
  grep -oE -- "$1" "$2" 2>/dev/null | wc -l | tr -d ' \t'
}

# A count of 0 means the expression is inert on this firmware — the setting it
# was meant to carry would silently not be applied. That is the finding this
# whole action exists to surface, so it is called out rather than printed as
# just another number.
report() {  # report <label> <count> <expected-min>
  if [ "$2" -ge "$3" ]; then printf '   ok    %-46s %s\n' "$1" "$2"
  else                       printf '   MISS  %-46s %s   <-- matches nothing\n' "$1" "$2"; fi
}

same_file() {  # same_file <a> <b>
  [ -f "$1" ] && [ -f "$2" ] && cmp -s "$1" "$2"
}

do_check() {  # do_check <min> <max>
  _c_min=$(int_or "$1" 55)
  _c_max=$(int_or "$2" 100)

  printf '== luci-app-temp-history: gl_fan setpoint pre-flight ==\n'
  printf 'date          %s\n' "$(date 2>/dev/null)"
  printf 'dry run for   minimum=%s  maximum=%s\n' "$_c_min" "$_c_max"
  printf 'writes        nothing outside %s\n\n' "$CHECK_DIR"

  printf -- '-- device --------------------------------------------------\n'
  printf '   model            %s\n' "$(gl_model)"
  printf '   model file       %s\n' "$([ -r "$GL_MODEL_FILE" ] && echo present || echo MISSING)"
  printf '   gl_fan running   %s\n' "$(pgrep -f '/usr/bin/gl_fan' >/dev/null 2>&1 && echo yes || echo no)"
  printf '   gl_fan cmdline   %s\n' "$(cat /proc/$(pgrep -f '/usr/bin/gl_fan' 2>/dev/null | head -n1)/cmdline 2>/dev/null | tr '\0' ' ')"
  printf '   init script      %s\n' "$([ -x "$FAN_INIT" ] && echo "$FAN_INIT" || echo absent)"
  printf '   firmware ver     %s\n' "$(cat /etc/glversion 2>/dev/null || echo unknown)"
  printf '   openwrt          %s\n' \
    "$(sed -n 's/^DISTRIB_RELEASE=.\(.*\).$/\1/p' /etc/openwrt_release 2>/dev/null | head -n1)"
  printf '   /proc/gl-hw-info:\n'
  for _c_hw in /proc/gl-hw-info/*; do
    [ -f "$_c_hw" ] || continue
    printf '     %-14s %s\n' "$(basename "$_c_hw")" "$(head -c 120 "$_c_hw" 2>/dev/null | tr -d '\n')"
  done
  printf '\n'

  _c_reason=$(unsupported_reason)
  if [ -n "$_c_reason" ]; then
    printf '   UNSUPPORTED: %s\n' "$_c_reason"
    printf '   Nothing below would run on this device.\n\n'
  fi

  printf -- '-- baseline ------------------------------------------------\n'
  printf '   kind             %s\n' "$(baseline_kind)"
  printf '   %-16s %s\n' "$ROM_UTIL" "$([ -f "$ROM_UTIL" ] && echo present || echo absent)"
  printf '   %-16s %s\n' "$ROM_VIEW_GZ" "$([ -f "$ROM_VIEW_GZ" ] && echo present || echo absent)"
  printf '   rom app bundle   %s\n' "$(find "$ROM_APP_DIR" -name 'app.*.js.gz' 2>/dev/null | head -n1)"
  printf '\n'

  # Residue check. If the live files already differ from /rom, something has
  # patched them and not put them back — which matters both for judging what
  # "factory" means here and for knowing whether an earlier tool's restore
  # actually restored.
  printf -- '-- live files vs the firmware image ------------------------\n'
  for _c_pair in "gl_util.sh|$UTIL|$ROM_UTIL" \
                 "glfan config|$GLFAN_CONF|$ROM_GLFAN" \
                 "overview view|$VIEW_GZ|$ROM_VIEW_GZ" \
                 "i18n strings|$I18N|$ROM_I18N"; do
    _c_lbl="${_c_pair%%|*}"; _c_rest="${_c_pair#*|}"
    _c_live="${_c_rest%%|*}"; _c_rom="${_c_rest#*|}"
    if [ ! -f "$_c_live" ]; then printf '   %-16s live file absent\n' "$_c_lbl"
    elif [ ! -f "$_c_rom" ]; then printf '   %-16s no firmware copy to compare\n' "$_c_lbl"
    elif same_file "$_c_live" "$_c_rom"; then printf '   %-16s identical to firmware\n' "$_c_lbl"
    else printf '   %-16s DIFFERS from firmware  <-- something patched this\n' "$_c_lbl"; fi
  done
  _c_liveapp=$(find "$APP_DIR" -name 'app.*.js.gz' -type f 2>/dev/null | head -n 1)
  _c_romapp=$(find "$ROM_APP_DIR" -name 'app.*.js.gz' -type f 2>/dev/null | head -n 1)
  if [ -n "$_c_liveapp" ] && [ -n "$_c_romapp" ]; then
    if same_file "$_c_liveapp" "$_c_romapp"; then printf '   %-16s identical to firmware\n' "app bundle"
    else printf '   %-16s DIFFERS from firmware  <-- something patched this\n' "app bundle"; fi
    printf '   live name        %s\n' "$(basename "$_c_liveapp")"
    printf '   rom name         %s\n' "$(basename "$_c_romapp")"
  fi
  printf '\n'

  # A trap, not a tidy-up line at the end. This report is long and will be read
  # through `less` or cut short with `head`, and a closed pipe kills the script
  # where it stands — which left the scratch directory behind every time.
  trap 'rm -rf "$CHECK_DIR"' EXIT INT TERM HUP PIPE
  mkdir -p "$CHECK_DIR" 2>/dev/null || { printf '   cannot create %s — stopping\n' "$CHECK_DIR"; return 0; }

  # Resolved once, up here, because the web-UI dry run needs all three.
  _c_vbase0=$(baseline_file view);  [ -n "$_c_vbase0" ]    || _c_vbase0="$VIEW_GZ"
  _c_i18nbase0=$(baseline_file i18n); [ -n "$_c_i18nbase0" ] || _c_i18nbase0="$I18N"
  _c_appsrc0="$_c_romapp"; [ -n "$_c_appsrc0" ] || _c_appsrc0="$_c_liveapp"

  # ── The system half ────────────────────────────────────────────────
  _c_base=$(baseline_file util)
  [ -n "$_c_base" ] || _c_base="$UTIL"
  printf -- '-- system half: expressions against %s\n' "$_c_base"
  if [ -f "$_c_base" ]; then
    cp "$_c_base" "$CHECK_DIR/util.orig"
    _c_f6=$(n_of '-lt 6[0-9]' "$CHECK_DIR/util.orig")
    _c_f7=$(n_of '-lt 7[0-9]' "$CHECK_DIR/util.orig")
    printf '   %-53s %s\n' '-lt 6[0-9]  (hardware floor)' "$_c_f6"
    printf '   %-53s %s\n' '-lt 7[0-9]  (hardware floor)' "$_c_f7"
    # Either expression alone matching nothing is normal — a board uses 60s or
    # 70s literals, not both. Neither matching means the floor comparison is
    # written some other way here and would not be moved at all.
    [ "$(( _c_f6 + _c_f7 ))" -eq 0 ] && \
      printf '   MISS  neither floor expression matches — the comparison gl_fan\n         actually uses is written differently on this firmware\n'

    _c_model=$(gl_model)
    _c_blk=0
    [ -n "$_c_model" ] && awk "/$_c_model[)]/,/;;/" "$CHECK_DIR/util.orig" 2>/dev/null \
      | grep -q 'temperature=' && _c_blk=1
    printf '   %-53s %s\n' "per-model case block for $_c_model" \
      "$([ "$_c_blk" = 1 ] && echo 'present -> model-block path' || echo 'absent  -> local-variable path')"
    if [ "$_c_blk" = 1 ]; then
      awk "/$_c_model[)]/,/;;/" "$CHECK_DIR/util.orig" > "$CHECK_DIR/util.blk" 2>/dev/null
      report "  minimum_temperature= in that block" "$(n_of 'minimum_temperature=[0-9]*' "$CHECK_DIR/util.blk")" 1
      report "  <space>temperature=  in that block" "$(n_of '[[:space:]]temperature=[0-9]*' "$CHECK_DIR/util.blk")" 1
    else
      _c_lm=$(n_of 'local minimum_temperature=[0-9]*' "$CHECK_DIR/util.orig")
      report "  local minimum_temperature=" "$_c_lm" 1
      report "  local temperature=" "$(n_of 'local temperature=[0-9]*' "$CHECK_DIR/util.orig")" 1
      # The fallback has no model scope: it rewrites EVERY such assignment in
      # the file. On a firmware that does carry per-model blocks, taking this
      # path means the model match failed — and then the values land in every
      # branch, including ones that never run on this board, while the branch
      # that does run may not be the one intended.
      if [ "${_c_lm:-0}" -gt 1 ]; then
        printf '   WARN  %s assignments, no model scope — all of them get rewritten:\n' "$_c_lm"
        grep -n 'local minimum_temperature=\|local temperature=' "$CHECK_DIR/util.orig" \
          | head -n 12 | sed 's/^/           /'
        printf '         Check the model name above appears in the case labels below.\n'
        grep -n ')' "$CHECK_DIR/util.orig" | grep -i 'gl-\|glinet' | head -n 12 | sed 's/^/           /'
      fi
    fi
    report "warn_temperature=" "$(n_of 'warn_temperature=' "$CHECK_DIR/util.orig")" 1

    # The real dry run: the same function that would write, against a copy.
    cp "$CHECK_DIR/util.orig" "$CHECK_DIR/util.new"
    patch_system_file "$CHECK_DIR/util.new" "$_c_min" "$(cur_fanon)" "$(cur_warn)"
    printf '\n   what it would change in %s:\n' "$UTIL"
    if cmp -s "$CHECK_DIR/util.orig" "$CHECK_DIR/util.new"; then
      printf '     NOTHING — every expression missed.\n'
    elif command -v diff >/dev/null 2>&1; then
      diff -u "$CHECK_DIR/util.orig" "$CHECK_DIR/util.new" | sed -n '3,60p' | sed 's/^/     /'
    else
      # BusyBox is often built without diff, and the first version of this
      # fallback grepped for the new NUMBERS — which on a real router matched
      # "ar750", "x750" and twenty LED lines, and showed nothing about the
      # change. Compare the files line by line instead and print only the lines
      # that actually differ, with both versions.
      printf '     (no diff on this device — changed lines, before and after)\n'
      _c_ln=0
      while IFS= read -r _c_a <&3 && IFS= read -r _c_b <&4; do
        _c_ln=$(( _c_ln + 1 ))
        [ "$_c_a" = "$_c_b" ] && continue
        printf '     %s- %s\n' "$_c_ln" "$_c_a"
        printf '     %s+ %s\n' "$_c_ln" "$_c_b"
      done 3< "$CHECK_DIR/util.orig" 4< "$CHECK_DIR/util.new"
    fi
  else
    printf '   no gl_util.sh to inspect\n'
  fi
  printf '\n'

  # ── The web-UI half ────────────────────────────────────────────────
  _c_vbase="$_c_vbase0"
  printf -- '-- web-UI half: expressions against %s\n' "$_c_vbase"
  if [ -f "$_c_vbase" ]; then
    cp "$_c_vbase" "$CHECK_DIR/view.js.gz"
    gzip -dc "$CHECK_DIR/view.js.gz" > "$CHECK_DIR/view.js" 2>/dev/null
    report "minimum_temperature:t"                "$(n_of 'minimum_temperature:t' "$CHECK_DIR/view.js")" 1
    report "maximum_temperature:t"                "$(n_of 'maximum_temperature:t' "$CHECK_DIR/view.js")" 1
    report "maximumTemperature:()=>NN"            "$(n_of 'maximumTemperature:\(\)=>[0-9]*' "$CHECK_DIR/view.js")" 1
    report "t<70"                                 "$(n_of 't<70' "$CHECK_DIR/view.js")" 1
    report "t>90"                                 "$(n_of 't>90' "$CHECK_DIR/view.js")" 1
    report "ature=70"                             "$(n_of 'ature=70' "$CHECK_DIR/view.js")" 0
    report "ature=90"                             "$(n_of 'ature=90' "$CHECK_DIR/view.js")" 0
    report "t<this.minimumTemperature"            "$(n_of 't<this\.minimumTemperature' "$CHECK_DIR/view.js")" 0
    report "t>this.maximumTemperature"            "$(n_of 't>this\.maximumTemperature' "$CHECK_DIR/view.js")" 0
    report "attrs:{min:..,max:..}  (slider)"      "$(n_of 'attrs:\{min:[^,]+,max:[^,}]+' "$CHECK_DIR/view.js")" 1
    report "marks:t.tMarks         (scale)"       "$(n_of 'marks:t.tMarks' "$CHECK_DIR/view.js")" 1
    report "fan start is ...       (info text)"   "$(n_of 'fan start is [^.]*' "$CHECK_DIR/view.js")" 0
    # Counts are not enough for the view. These substitutions splice text into
    # minified JavaScript, and whether the result still PARSES depends entirely
    # on what surrounds the match — `minimum_temperature:t` becomes
    # `minimum_temperature:ignore,t=50`, which is fine inside an argument list
    # and a syntax error inside an object literal. Print the neighbourhood of
    # every match, before and after, so it can be judged rather than assumed.
    cp "$CHECK_DIR/view.js.gz" "$CHECK_DIR/after.js.gz"
    cp "$CHECK_DIR/view.js"    "$CHECK_DIR/before.js"
    _c_i18ncopy="$CHECK_DIR/i18n.json"
    [ -f "$_c_i18nbase0" ] && cp "$_c_i18nbase0" "$_c_i18ncopy"
    mkdir -p "$CHECK_DIR/appdir"
    [ -n "$_c_appsrc0" ] && cp "$_c_appsrc0" "$CHECK_DIR/appdir/"
    patch_ui "$CHECK_DIR/after.js.gz" "$_c_i18ncopy" "$CHECK_DIR/appdir" \
             "$_c_min" "$(cur_fanon)" "$_c_max"
    gzip -dc "$CHECK_DIR/after.js.gz" > "$CHECK_DIR/after.js" 2>/dev/null

    printf '\n   each match in context — BEFORE, then AFTER the same region:\n'
    for _c_pat in 'minimum_temperature:t' 'maximum_temperature:t' \
                  'maximumTemperature:\(\)=>[0-9]*' 't<70' 't>90' \
                  't<this\.minimumTemperature' 't>this\.maximumTemperature' \
                  'attrs:\{min:[^,]+,max:[^,}]+' 'marks:t.tMarks'; do
      _c_hit=$(grep -oE ".{0,34}$_c_pat.{0,34}" "$CHECK_DIR/before.js" 2>/dev/null | head -n 2)
      [ -n "$_c_hit" ] || continue
      printf '     [%s]\n' "$_c_pat"
      printf '%s\n' "$_c_hit" | sed 's/^/       - /'
    done
    printf '     [the same regions after patching]\n'
    for _c_pat in "minimum_temperature:ignore" "maximumTemperature:\(\)=>$_c_max" \
                  "t<$_c_min" "t>$_c_max" "attrs:\{min:" "marks:\{"; do
      _c_hit=$(grep -oE ".{0,34}$_c_pat.{0,34}" "$CHECK_DIR/after.js" 2>/dev/null | head -n 1)
      [ -n "$_c_hit" ] && printf '%s\n' "$_c_hit" | sed 's/^/       + /'
    done

    # The above only shows the changes that were EXPECTED — it greps for what
    # the patch was aiming at. This catches the other kind: a long numeric
    # literal is never a temperature, so if the multiset of them differs before
    # and after, something was hit that should not have been. It is exactly the
    # `t>90` inside `t>9007199254740991` class of fault, stated generally
    # instead of one pattern at a time.
    printf '\n   long numeric literals (6+ digits) altered — expected: NONE\n'
    grep -oE '[0-9]{6,}' "$CHECK_DIR/before.js" 2>/dev/null | sort > "$CHECK_DIR/n.before"
    grep -oE '[0-9]{6,}' "$CHECK_DIR/after.js"  2>/dev/null | sort > "$CHECK_DIR/n.after"
    if cmp -s "$CHECK_DIR/n.before" "$CHECK_DIR/n.after"; then
      printf '     none — every long constant in the bundle survived intact\n'
    else
      printf '     ALTERED. Constants present before but not after:\n'
      grep -vxF -f "$CHECK_DIR/n.after" "$CHECK_DIR/n.before" 2>/dev/null | head -n 8 | sed 's/^/       - /'
      printf '     and present after but not before:\n'
      grep -vxF -f "$CHECK_DIR/n.before" "$CHECK_DIR/n.after" 2>/dev/null | head -n 8 | sed 's/^/       + /'
    fi
  else
    printf '   no overview view bundle on this device (community build?)\n'
  fi

  [ -f "$_c_i18nbase0" ] && \
    report "fan start is ...       (i18n)" "$(n_of 'fan start is [^.]*' "$_c_i18nbase0")" 0
  printf '\n'

  # ── The app bundle ─────────────────────────────────────────────────
  # This is the expression to be most suspicious of. `[0-9]{1,3}||i<[0-9]{2,3}`
  # is a shape, not a name: it can match unrelated minified code, and every
  # match is rewritten. One is expected. Several means it is hitting things it
  # was never aimed at, and the matches are printed so they can be judged.
  printf -- '-- app bundle: the validator range -------------------------\n'
  _c_appsrc="$_c_appsrc0"
  if [ -n "$_c_appsrc" ] && [ -f "$_c_appsrc" ]; then
    gzip -dc "$_c_appsrc" > "$CHECK_DIR/app.js" 2>/dev/null
    _c_n=$(n_of '[0-9]{1,3}\|\|i<[0-9]{2,3}' "$CHECK_DIR/app.js")
    _c_nt=$(grep -oE -- '.{0,40}[0-9]{1,3}\|\|i<[0-9]{2,3}.{0,40}' "$CHECK_DIR/app.js" 2>/dev/null \
            | grep -ci 'emperature')
    printf '   %-53s %s\n' 'NN||i<NN  (validator range)' "$_c_n"
    printf '   %-53s %s\n' 'of those, next to the word "temperature"' "${_c_nt:-0}"
    if [ "${_c_n:-0}" -gt 0 ]; then
      printf '   every match, with context:\n'
      grep -oE -- '.{0,34}[0-9]{1,3}\|\|i<[0-9]{2,3}.{0,34}' "$CHECK_DIR/app.js" 2>/dev/null \
        | head -n 12 | sed 's/^/     /'
    fi
    if app_validator_safe "$CHECK_DIR/app.js"; then
      printf '   VERDICT: every match looks like a temperature range — it WILL be patched.\n'
    else
      printf '   VERDICT: SKIPPED. The expression is a shape, not a name, and at least one\n'
      printf '            match is not a temperature range — patching it would corrupt\n'
      printf '            unrelated code. The app bundle will be left alone.\n'
    fi
    report "temperature:69 / :70"  "$(n_of 'temperature:6[90]' "$CHECK_DIR/app.js")" 0
    report "temperature:76"        "$(n_of 'temperature:76' "$CHECK_DIR/app.js")" 0
  else
    printf '   no app bundle found\n'
  fi
  printf '\n'

  # ── Does the minimum setpoint reach the daemon at all? ─────────────
  # gl_fan is started from an init script that builds its command line out of
  # UCI. Whichever options that script does NOT pass are, as far as the running
  # daemon is concerned, decoration — so this is what decides whether changing
  # the minimum changes any behaviour or only what the web UI displays.
  printf -- '-- how gl_fan is actually started --------------------------\n'
  if [ -f "$FAN_INIT" ]; then
    printf '   VERDICT  minimum_temperature reaches the daemon: %s\n' \
      "$(init_reads minimum_temperature && echo yes || echo 'NO — display value only')"
    printf '   VERDICT  warn_temperature reaches the daemon:    %s\n' \
      "$(init_reads warn_temperature && echo yes || echo 'NO — display value only')"
    printf '   VERDICT  temperature (fan-on) reaches it:        %s\n' \
      "$(init_reads '[^_]temperature' && echo yes || echo NO)"
    printf '   %s in full:\n' "$FAN_INIT"
    sed -n '1,80p' "$FAN_INIT" 2>/dev/null | sed 's/^/     /'
  else
    printf '   no init script at %s\n' "$FAN_INIT"
  fi
  printf '   live /etc/config/glfan vs the firmware copy:\n'
  if [ -f "$GLFAN_CONF" ] && [ -f "$ROM_GLFAN" ] && ! same_file "$GLFAN_CONF" "$ROM_GLFAN"; then
    printf '     (differing is EXPECTED here — fan_init provisions this file at runtime,\n'
    printf '      so the firmware copy is a template, not the running configuration)\n'
    printf '     --- firmware ---\n'; sed 's/^/       /' "$ROM_GLFAN" 2>/dev/null | head -n 20
    printf '     --- live ---\n';     sed 's/^/       /' "$GLFAN_CONF" 2>/dev/null | head -n 20
  else
    printf '     identical, or one of them is missing\n'
  fi
  printf '\n'

  printf -- '-- current configuration -----------------------------------\n'
  printf '   uci glfan.globals:\n'
  uci -q show glfan 2>/dev/null | sed 's/^/     /' || printf '     (none)\n'
  printf '   recorded by this package:\n'
  printf '     glfan_min=%s glfan_max=%s ui_patch=%s\n' \
    "$(uci_get temp_history.main.glfan_min)" \
    "$(uci_get temp_history.main.glfan_max)" \
    "$(uci_get temp_history.main.glfan_ui_patch)"
  printf '\n'

  printf -- '-- thermal hardware ----------------------------------------\n'
  for _c_tz in /sys/class/thermal/thermal_zone*; do
    [ -d "$_c_tz" ] || continue
    printf '   %s type=%s temp=%s\n' "$(basename "$_c_tz")" \
      "$(cat "$_c_tz/type" 2>/dev/null)" "$(cat "$_c_tz/temp" 2>/dev/null)"
    for _c_tp in "$_c_tz"/trip_point_*_temp; do
      [ -f "$_c_tp" ] || continue
      printf '     %s = %s\n' "$(basename "$_c_tp")" "$(cat "$_c_tp" 2>/dev/null)"
    done
  done
  for _c_cd in /sys/class/thermal/cooling_device*; do
    [ -d "$_c_cd" ] || continue
    printf '   %s type=%s cur=%s max=%s\n' "$(basename "$_c_cd")" \
      "$(cat "$_c_cd/type" 2>/dev/null)" "$(cat "$_c_cd/cur_state" 2>/dev/null)" \
      "$(cat "$_c_cd/max_state" 2>/dev/null)"
  done
  printf '\n'

  printf '== end. Nothing was changed. ==\n'
}

case "$1" in
  status) do_status ;;
  set)    do_set "$2" "$3" ;;
  reset)  do_reset ;;
  check)  do_check "$2" "$3" ;;
  *)
    printf 'usage: %s {status|set <min> <max>|reset|check [min] [max]}\n' "${0##*/}" >&2
    printf '  check is READ-ONLY: it reports what set would match, and changes nothing.\n' >&2
    exit 1
    ;;
esac
exit 0
