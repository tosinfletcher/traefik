#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# out.sh LEVEL MESSAGE... — uniform, color-aware, user-friendly CLI output.
#
# Every level REPORTS ONLY: it always exits 0; the *caller* decides whether to
# abort. Colors are emitted only when a terminal is attached (or FORCE_COLOR=1)
# and NO_COLOR is unset — so piped/redirected output stays byte-clean.
#
# STREAMS (deliberate, mirrors the current contract derive.sh depends on):
#   * stdout : title, hr, step, cmd, ok, info, sub, note, dim, done, warned
#   * stderr : warn, err/fail, hint                     ← keeps `derive.sh`
#                                                       stdout pure (it is the
#                                                       eval-able export bundle)
#
# Levels
#   title TEXT   banner:  "  ▲ TEXT"  (bold)          [stdout]
#   hr           a thin separator rule                [stdout]
#   step TEXT    section label "  ▸ TEXT" (bold)      [stdout]
#   group TEXT   group heading "  ▸" + TEXT (bold)    [stdout]   (== step)
#   cmd L|D      aligned two-column line              [stdout]
#   ok TEXT      green     "✓ TEXT"                   [stdout]   success
#   warn TEXT    yellow    "⚠ TEXT"                   [stderr]   warning
#   err TEXT     red       "✗ TEXT"  (alias fail)      [stderr]   failure
#   info TEXT    cyan      "· TEXT"                   [stdout]   note/detail
#   sub TEXT     cyan, indented detail                [stdout]
#   note TEXT    gray  "note: TEXT"                   [stdout]
#   dim TEXT     gray  text                           [stdout]
#   hint TEXT    gray  actionable follow-up "↳ TEXT"  [stderr]
#   done TEXT    GREEN VERDICT footer (success)       [stdout]
#   warned TEXT  YELLOW VERDICT footer (warnings only)[stdout]
#   bad TEXT     RED VERDICT footer (failure)          [stderr]
# ---------------------------------------------------------------------------
set -uo pipefail

level="${1:-info}"
shift 2>/dev/null || true
msg="$*"

# ---- palette (empty when color is disabled) --------------------------------
if [ "${FORCE_COLOR:-0}" = "1" ]; then c=1
elif { [ -t 1 ] || [ -t 2 ]; } && [ -z "${NO_COLOR:-}" ]; then c=1
else c=0; fi

if [ "$c" -eq 1 ]; then
  bold=$'\033[1m';  green=$'\033[1;32m'; red=$'\033[1;31m'
  yellow=$'\033[1;33m'; cyan=$'\033[36m'; gray=$'\033[90m'
  reset=$'\033[0m'
else
  bold=""; green=""; red=""; yellow=""; cyan=""; gray=""; reset=""
fi

# ---- rule width (2-space content gutter) ------------------------------------
w="${COLUMNS:-60}"
case "$w" in ''|*[!0-9]*) w=60 ;; esac
[ "$w" -lt 18 ] && w=44
dash_n=$((w - 2))
_d=""
for ((i = 0; i < dash_n; i++)); do _d="${_d}─"; done

out() { printf '%b\n' "$1"; }                  # stdout
errp() { printf '%b\n' "$1" >&2; }             # stderr

case "$level" in
  title)
    out "   ${bold}▲ ${msg}${reset}"
    ;;
  hr)
    out "   ${_d}"
    ;;
  step|group)
    out "   ${bold}▸${reset} ${msg}"
    ;;
  cmd)
    # "LABEL|DESC" — aligned two-column list (label cyan, desc plain).
    # Pad the RAW label first (fixed visible width), then wrap in color so
    # %-padding still lines up whether or not color is active.
    label="${msg%%|*}"; desc="${msg#*|}"
    if [ "$c" -eq 1 ]; then printf '     %s %s\n' "${cyan}$(printf '%-15s' "$label")${reset}" "$desc"
    else                    printf '     %-15s  %s\n'              "$label" "$desc"; fi
    ;;
  ok)
    out "     ${green}✓ ${msg}${reset}"
    ;;
  warn)
    errp "   ${yellow}⚠ ${msg}${reset}"
    ;;
  err|fail)
    errp "   ${red}✗ ${msg}${reset}"
    ;;
  info)
    out "     ${cyan}· ${msg}${reset}"
    ;;
  sub)
    out "        ${cyan}${msg}${reset}"
    ;;
  note)
    out "     ${gray}note: ${msg}${reset}"
    ;;
  dim)
    out "     ${gray}${msg}${reset}"
    ;;
  hint)
    errp "        ${gray}↳ ${msg}${reset}"
    ;;
  done)
    out "   ${_d}"
    out "     ${green}✔ ${msg}${reset}"
    ;;
  warned)
    out "   ${_d}"
    out "     ${yellow}⚠${reset} ${bold}${msg}${reset}"
    ;;
  bad)  # verdict → stdout so the RED failure line stays visible even if stderr is redirected away
    out "   ${_d}"
    out "   ${red}✗ ${msg}${reset}"
    ;;
  *)
    # Unknown level → pass straight through, plain.
    out "${msg}"
    ;;
esac
exit 0
