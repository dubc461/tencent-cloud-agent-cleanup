#!/bin/bash
# tencent-cloud-agent-cleanup.sh — remove the Tencent Cloud agents from a CVM in one run.
#
# Usage (as root on the CVM):
#   ./tencent-cloud-agent-cleanup.sh --dry-run      # report only, change nothing
#   ./tencent-cloud-agent-cleanup.sh                # remove everything below
#   ./tencent-cloud-agent-cleanup.sh --keep-tat     # keep the TAT automation agent
#
# Options:
#   --dry-run            report what would change; nothing is changed
#   --keep-tat           keep the TAT automation agent and its units
#   --keep-python        keep /usr/local/qcloud/python
#   --kill-fd-holders    also kill processes that merely hold YunJing/sgdaemon files open
#                        (by default they are only reported, e.g. an admin's tail -f)
#   --wait SECONDS       wait before the final check for respawns (default 90)
#   --backup-dir DIR     where configuration files are copied before they change
#   --force              run even if this does not look like a Tencent Cloud image
#
# From the controller without copying the script anywhere permanent:
#   ansible <host> -b -m ansible.builtin.script -a "tencent-cloud-agent-cleanup.sh --dry-run"
#
# Removed, in this order (order matters):
#   0. the hidden YunJing uninstall monitor: a Go program running inside a shell process
#      disguised as "/bin/sh -c sleep 100". It re-downloads YunJing seconds after removal,
#      so it must die first. Killed: shells with more than one thread and processes that
#      map YunJing code. Processes that only hold YunJing files open are reported.
#   1. onion: /etc/ld.so.preload entry for libonion (preloaded into every new process)
#   2. stargate (sgagent): /etc/cron.d/sgagenttask, root crontab line
#   3. barad cloud monitor (launched by stargate)
#   4. YunJing host security (YDLive, YDService, YDEdr): /etc/cron.d/yunjing, /var/cache/ydeyes
#  4b. older images' security components, only when present: /usr/local/sa (secu-tcs-agent)
#      and /usr/local/agenttools, with their processes, cron and rc.local lines
#   5. TAT automation agent: tat_agent.service and tat_install.service (the latter reinstalls
#      TAT at every boot and is not removed by TAT's own uninstall.sh)
#   6. leftovers: libonion*, onion_check*, /usr/local/qcloud/python, /tmp download artifacts
# Kept: the image's tuning scripts (/usr/local/qcloud/{irq,rps,xps,cpuidle,gpu,scripts,
#   udev_run,action,drivers}), their /etc/rc.local lines, /etc/udev/rules.d/80-qcloud-nic.rules
#   and /etc/qcloudzone.
#
# Backups: configuration the run edits or deletes (files under /etc such as cron entries,
# ld.so.preload, rc.local and init scripts, every systemd unit file, and the root crontab) is
# copied to --backup-dir first; the directory is created only when something is copied.
# Agent program directories, libraries, the python runtime, lock/pid files and anything the
# vendors' own uninstallers delete are removed without a copy.
#
# Exit status: 0 clean; 2 something is still present, came back after --wait seconds, or
# could not be deleted (e.g. an immutable file); 1 usage or environment error.
# The final check re-tests every path the run removes, plus processes, cron, crontab,
# ld.so.preload, rc.local, systemd units and their wants links.
# Processes that loaded libonion before the run keep it mapped until they restart; a reboot
# clears it. The run ends with a reminder to turn off automatic agent installation in the
# Tencent Cloud console, which can otherwise install the agents again.

set -u
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/sbin:/usr/bin:/bin
unset LD_PRELOAD

Q=/usr/local/qcloud
DRY_RUN=0
KEEP_TAT=0
KEEP_PYTHON=0
KILL_FD_HOLDERS=0
WAIT=90
FORCE=0
BACKUP_DIR="/root/tencent-agent-cleanup-$(date +%Y%m%d-%H%M%S)"
FAILED=""

usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --keep-tat) KEEP_TAT=1 ;;
    --keep-python) KEEP_PYTHON=1 ;;
    --kill-fd-holders) KILL_FD_HOLDERS=1 ;;
    --wait)
      case "${2:-}" in
        ''|*[!0-9]*) echo "--wait needs a whole number of seconds, got '${2:-}'" >&2; exit 1 ;;
      esac
      WAIT=$2; shift ;;
    --backup-dir) BACKUP_DIR="${2:?--backup-dir needs a path}"; shift ;;
    --force) FORCE=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
  shift
done

log() { echo "[tc-cleanup] $*"; }
run() {
  if [ "$DRY_RUN" = 1 ]; then
    log "would: $*"
  else
    "$@"
  fi
}
backup() {  # copy existing files into BACKUP_DIR, creating it only when needed
  local b
  [ "$DRY_RUN" = 1 ] && return 0
  for b in "$@"; do
    [ -e "$b" ] || [ -L "$b" ] || continue
    mkdir -p "$BACKUP_DIR" && cp -a --parents "$b" "$BACKUP_DIR/" 2>/dev/null
  done
  return 0
}
save_backup() {  # name content: write generated text (crontab, process list) into BACKUP_DIR
  [ "$DRY_RUN" = 1 ] && return 0
  mkdir -p "$BACKUP_DIR" && printf '%s\n' "$2" > "$BACKUP_DIR/$1"
}

[ "$(id -u)" = 0 ] || { echo "must run as root" >&2; exit 1; }
if [ ! -d "$Q" ] && [ ! -e /etc/qcloudzone ] && [ "$FORCE" = 0 ]; then
  echo "no $Q or /etc/qcloudzone: not a Tencent Cloud image? (--force to continue)" >&2
  exit 1
fi
[ "$DRY_RUN" = 1 ] && log "dry run: nothing will be changed"

LEGACY_DIRS="/usr/local/sa /usr/local/agenttools"
AGENT_DIRS="$Q/stargate $Q/monitor $Q/YunJing $LEGACY_DIRS"
AGENT_NAMES='sgagent|barad_agent|YDLive|YDService|YDEdr|secu-tcs-agent'
UNIT_NAME_RE='stargate|yunjing|YD|barad|secu-tcs'  # unit names whose wants links are agent links
if [ "$KEEP_TAT" = 0 ]; then
  AGENT_DIRS="$AGENT_DIRS $Q/tat_agent"
  AGENT_NAMES="$AGENT_NAMES|tat_agent"
  UNIT_NAME_RE="$UNIT_NAME_RE|tat_"
fi
# Each directory with a trailing slash: matches /usr/local/sa/... but not /usr/local/sbin.
AGENT_PATH_RE="$(echo "$AGENT_DIRS" | sed 's#$#/#; s# #/|#g')"

# Every path the run removes. The final check re-tests exactly this list, so cleanup and
# verification cannot drift apart. Unmatched globs stay literal and simply do not exist.
removal_targets() {
  # shellcheck disable=SC2086  # space-separated lists of paths without spaces
  printf '%s\n' $AGENT_DIRS \
    /var/cache/ydeyes /var/log/YunJing /usr/bin/cagent_tools /var/run/barad_agent.lock \
    /tmp/stargate.lock /etc/cron.d/sgagenttask /etc/cron.d/yunjing \
    /lib/x86_64-linux-gnu/libonion* /lib64/libonion* /usr/lib64/libonion* \
    "$Q/onion_check" "$Q/onion_check.tgz" "$Q/onion.log" \
    /tmp/*ydeyes* /tmp/ydeye_install.log /tmp/sgdaemon.log
  [ "$KEEP_PYTHON" = 0 ] && echo "$Q/python"
  if [ "$KEEP_TAT" = 0 ]; then
    printf '%s\n' /usr/sbin/tat_agent /var/run/tat_agent.pid /run/tat_agent.pid \
      /etc/init.d/tat_agent_service /etc/init/tat_agent_service.conf
  fi
  return 0
}

ancestors() {  # pids of this script and its parents, never killed
  local p=$$
  while [ -n "$p" ] && [ "$p" != 0 ]; do
    echo "$p"
    p=$(awk '/^PPid/{print $2}' "/proc/$p/status" 2>/dev/null)
  done
}
SELF="$(ancestors | tr '\n' ' ')"

# One pass over /proc, sorting processes into three groups:
#   SCAN_AGENTS    agent processes, by executable path or exact process name
#   SCAN_MONITORS  hidden monitor: a shell with threads, or a process mapping YunJing code
#   SCAN_HOLDERS   any other process holding a YunJing/sgdaemon file open (report only)
scan_procs() {
  local d p exe comm threads fd target reason cmd
  SCAN_AGENTS=""
  SCAN_MONITORS=""
  SCAN_HOLDERS=""
  for d in /proc/[0-9]*; do
    p=${d#/proc/}
    case " $SELF " in *" $p "*) continue ;; esac
    exe=$(readlink "$d/exe" 2>/dev/null) || continue
    comm=$(cat "$d/comm" 2>/dev/null)
    if echo "$exe" | grep -q -E "^($AGENT_PATH_RE)" || echo "$comm" | grep -q -x -E "$AGENT_NAMES"; then
      SCAN_AGENTS="$SCAN_AGENTS $p"
      continue
    fi
    cmd="$(tr '\0' ' ' < "$d/cmdline" 2>/dev/null | cut -c1-60)"
    reason=""
    case "$(basename "${exe% (deleted)}")" in
      dash|bash|sh|busybox)
        threads=$(find "$d/task" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l)
        [ "$threads" -gt 1 ] && reason="shell with $threads threads"
        ;;
    esac
    if [ -z "$reason" ] && grep -q -E 'ydeyes|/YunJing/|sgdaemon' "$d/maps" 2>/dev/null; then
      reason="maps YunJing code"
    fi
    if [ -n "$reason" ]; then
      SCAN_MONITORS="${SCAN_MONITORS}$p $reason: $cmd (exe $exe)
"
      continue
    fi
    for fd in "$d"/fd/*; do
      target="$(readlink "$fd" 2>/dev/null)"
      case "$target" in
        *sgdaemon.log*|*ydeyes*|*/YunJing/*)
          SCAN_HOLDERS="${SCAN_HOLDERS}$p holds $target: $cmd
"
          break ;;
      esac
    done
  done
  SCAN_MONITORS="${SCAN_MONITORS%
}"
  SCAN_HOLDERS="${SCAN_HOLDERS%
}"
}

first_fields() { echo "$1" | awk 'NF {print $1}' | tr '\n' ' '; }

remove_paths() {  # delete what exists; config under /etc is backed up; failures are recorded
  local f
  for f in "$@"; do
    [ -e "$f" ] || [ -L "$f" ] || continue
    case "$f" in /etc/*) backup "$f" ;; esac
    log "   remove $f"
    run rm -rf "$f"
    if [ "$DRY_RUN" = 0 ] && { [ -e "$f" ] || [ -L "$f" ]; }; then
      log "   FAILED to remove $f (immutable attribute? check lsattr)"
      FAILED="$FAILED $f"
    fi
  done
}

kill_pids() {
  local pids="$*"
  [ -n "${pids// /}" ] || return 0
  # shellcheck disable=SC2086  # numeric pids, split on purpose
  run kill -9 $pids 2>/dev/null
}

agent_units() {  # unit files whose content starts or installs a removed agent
  local f
  for f in /etc/systemd/system/*.service /lib/systemd/system/*.service /usr/lib/systemd/system/*.service; do
    [ -f "$f" ] && grep -q -E "$AGENT_PATH_RE" "$f" 2>/dev/null && basename "$f"
  done | sort -u
}

agent_wants_links() {  # wants links of agent units (tat_* only when TAT is being removed)
  local w
  for w in /etc/systemd/system/*.wants/*; do
    [ -L "$w" ] || continue
    basename "$w" | grep -q -E "^($UNIT_NAME_RE)" && echo "$w"
  done
  return 0
}

HAVE_SYSTEMCTL=0
command -v systemctl >/dev/null 2>&1 && HAVE_SYSTEMCTL=1
HANDLED_UNITS=" "
remove_unit() {  # stop, disable and delete every copy of a unit and its wants links
  local u=$1 f files="" c wants
  case "$HANDLED_UNITS" in *" $u "*) return 0 ;; esac
  HANDLED_UNITS="$HANDLED_UNITS$u "
  f=""
  if [ "$HAVE_SYSTEMCTL" = 1 ]; then
    f=$(systemctl show -p FragmentPath --value "$u" 2>/dev/null)
  fi
  # systemctl may be missing or not know the file; look in the unit directories as well.
  for c in "$f" "/etc/systemd/system/$u" "/lib/systemd/system/$u" "/usr/lib/systemd/system/$u"; do
    if [ -z "$c" ] || [ ! -f "$c" ]; then continue; fi
    case " $files " in *" $(readlink -f "$c") "*) ;; *) files="$files $(readlink -f "$c")" ;; esac
  done
  wants=""
  for c in /etc/systemd/system/*.wants/"$u"; do
    [ -L "$c" ] && wants="$wants $c"
  done
  [ -n "$files$wants" ] || return 0
  log "systemd unit $u (files:${files:- none}; wants:${wants:- none})"
  # Back up before stop/disable: `systemctl disable` deletes the wants links by itself.
  # shellcheck disable=SC2086  # path lists without spaces
  backup $files $wants
  if [ "$HAVE_SYSTEMCTL" = 1 ]; then
    run systemctl stop "$u" 2>/dev/null
    run systemctl disable "$u" 2>/dev/null
  fi
  # shellcheck disable=SC2086
  remove_paths $files $wants
}

official_uninstall() {  # name path: run a vendor uninstaller the way its file type needs
  local name=$1 script=$2 dir kind
  [ -f "$script" ] || return 0
  dir=$(dirname "$script")
  if [ "$(head -c 4 "$script" | od -An -c | tr -d ' \n')" = '177ELF' ]; then
    kind="ELF"
  else
    case "$(head -n 1 "$script")" in
      *bash*) kind="bash" ;;
      *) kind="sh" ;;
    esac
  fi
  log "   official uninstaller for $name ($kind): $script"
  if [ "$DRY_RUN" = 1 ]; then
    log "would: run $script"
    return 0
  fi
  case "$kind" in
    ELF)
      if [ ! -x "$script" ]; then
        log "   not executable, skipped; leftover cleanup below removes it"
        return 0
      fi
      (cd "$dir" && timeout 120 "$script") >/dev/null 2>&1 ;;
    bash) (cd "$dir" && timeout 120 bash "$script") >/dev/null 2>&1 ;;
    sh) (cd "$dir" && timeout 120 sh "$script") >/dev/null 2>&1 ;;
  esac
  log "   exit=$?"
}

# ---------------------------------------------------------------- 0. hidden monitor
log "0. hidden YunJing uninstall monitor"
scan_procs
if [ -n "$SCAN_MONITORS" ]; then
  echo "$SCAN_MONITORS" | sed 's/^/[tc-cleanup]    kill: /'
  save_backup hidden-monitors.txt "$SCAN_MONITORS"
  kill_pids "$(first_fields "$SCAN_MONITORS")"
else
  log "   none found"
fi
if [ -n "$SCAN_HOLDERS" ]; then
  if [ "$KILL_FD_HOLDERS" = 1 ]; then
    echo "$SCAN_HOLDERS" | sed 's/^/[tc-cleanup]    kill (--kill-fd-holders): /'
    kill_pids "$(first_fields "$SCAN_HOLDERS")"
  else
    echo "$SCAN_HOLDERS" | sed 's/^/[tc-cleanup]    report only (--kill-fd-holders to kill): /'
  fi
fi

# ---------------------------------------------------------------- 1. onion preload
log "1. onion preload"
if grep -q libonion /etc/ld.so.preload 2>/dev/null; then
  backup /etc/ld.so.preload
  if [ "$DRY_RUN" = 1 ]; then
    log "would: drop libonion from /etc/ld.so.preload"
  else
    sed -i '\#libonion#d' /etc/ld.so.preload
    # Already backed up above; a second copy would overwrite the original with the edit.
    grep -q '[^[:space:]]' /etc/ld.so.preload || rm -f /etc/ld.so.preload
  fi
else
  log "   not preloaded"
fi
for f in /etc/ld.so.preload_bak /etc/ld.so.preload.bak; do
  grep -q libonion "$f" 2>/dev/null && remove_paths "$f"
done

# ---------------------------------------------------------------- 2-5. agents
log "2. stargate"
official_uninstall stargate "$Q/stargate/admin/uninstall.sh"
remove_paths /etc/cron.d/sgagenttask /tmp/stargate.lock
remove_unit stargate.service

log "3. barad"
official_uninstall barad "$Q/monitor/barad/admin/uninstall.sh"
remove_paths /usr/bin/cagent_tools /var/run/barad_agent.lock

log "4. YunJing"
official_uninstall YunJing "$Q/YunJing/uninst.sh"
remove_paths /etc/cron.d/yunjing

log "4b. legacy security components"
legacy=""
for d in $LEGACY_DIRS; do
  [ -d "$d" ] && legacy="$legacy $d"
done
if [ -n "$legacy" ]; then
  for d in $legacy; do
    log "   found $d ($(du -sh "$d" 2>/dev/null | cut -f1)); its processes, cron and rc.local lines are removed below"
  done
else
  log "   not present"
fi

if [ "$KEEP_TAT" = 0 ]; then
  log "5. TAT"
  remove_unit tat_install.service
  remove_unit tat_agent.service
  official_uninstall tat "$Q/tat_agent/install/pkg/uninstall.sh"
else
  log "5. TAT kept (--keep-tat)"
fi
# Any other unit that still points at a removed agent (e.g. stargate.service on CoreOS).
for u in $(agent_units); do
  remove_unit "$u"
done

# Root crontab, cron.d and rc.local lines that start removed agents (tuning lines stay).
if crontab -u root -l 2>/dev/null | grep -q -E "$AGENT_PATH_RE"; then
  log "   root crontab: removing agent lines"
  if [ "$DRY_RUN" = 0 ]; then
    save_backup root.crontab "$(crontab -u root -l 2>/dev/null)"
    crontab -u root -l | grep -v -E "$AGENT_PATH_RE" | crontab -u root -
    [ -z "$(crontab -u root -l 2>/dev/null | grep -v -E '^\s*(#|$)')" ] && crontab -u root -r 2>/dev/null
  else
    log "would: drop $(crontab -u root -l | grep -c -E "$AGENT_PATH_RE") line(s) from the root crontab"
  fi
fi
agent_cron_files() {  # /etc/cron.d files with a line that starts a removed agent
  grep -l -E "$AGENT_PATH_RE" /etc/cron.d/* 2>/dev/null
}
for f in $(agent_cron_files); do
  # Remove the whole file when every job in it is an agent job; otherwise only those lines.
  if [ -z "$(grep -v -E '^\s*(#|$)' "$f" | grep -v -E '^[A-Za-z_]+=' | grep -v -E "$AGENT_PATH_RE")" ]; then
    log "   $f: only agent jobs, removing the file"
    remove_paths "$f"
  else
    log "   $f: removing agent lines, other jobs stay"
    backup "$f"
    run sed -i -E "\#($AGENT_PATH_RE)#d" "$f"
  fi
done
if grep -q -E "$AGENT_PATH_RE" /etc/rc.local 2>/dev/null; then
  log "   /etc/rc.local: removing agent lines, tuning lines stay"
  backup /etc/rc.local
  run sed -i -E "\#($AGENT_PATH_RE)#d" /etc/rc.local
fi

# Anything still running after the uninstallers, then every removal target.
scan_procs
if [ -n "${SCAN_AGENTS// /}$SCAN_MONITORS" ]; then
  log "   killing leftover agent processes:$SCAN_AGENTS $(first_fields "$SCAN_MONITORS")"
  kill_pids "$SCAN_AGENTS $(first_fields "$SCAN_MONITORS")"
fi
for d in $AGENT_DIRS; do
  [ -e "$d" ] && log "   $d is $(du -sh "$d" 2>/dev/null | cut -f1)"
done
log "6. leftovers"
# shellcheck disable=SC2046  # one path per line, no spaces
remove_paths $(removal_targets)
run ldconfig
[ "$HAVE_SYSTEMCTL" = 1 ] && run systemctl daemon-reload

# ---------------------------------------------------------------- verify
check() {  # sets CHECK_LEFT; one /proc scan
  local f u
  CHECK_LEFT=""
  scan_procs
  [ -n "${SCAN_AGENTS// /}" ] && CHECK_LEFT="$CHECK_LEFT processes:[${SCAN_AGENTS# }]"
  [ -n "$SCAN_MONITORS" ] && CHECK_LEFT="$CHECK_LEFT hidden-monitor:[$(first_fields "$SCAN_MONITORS")]"
  for f in $(removal_targets); do
    { [ -e "$f" ] || [ -L "$f" ]; } && CHECK_LEFT="$CHECK_LEFT $f"
  done
  for f in $(agent_cron_files); do CHECK_LEFT="$CHECK_LEFT cron:$f"; done
  crontab -u root -l 2>/dev/null | grep -q -E "$AGENT_PATH_RE" && CHECK_LEFT="$CHECK_LEFT root-crontab"
  for f in /etc/ld.so.preload /etc/ld.so.preload_bak /etc/ld.so.preload.bak; do
    grep -q libonion "$f" 2>/dev/null && CHECK_LEFT="$CHECK_LEFT $f"
  done
  grep -q -E "$AGENT_PATH_RE" /etc/rc.local 2>/dev/null && CHECK_LEFT="$CHECK_LEFT rc.local"
  for u in $(agent_units); do CHECK_LEFT="$CHECK_LEFT unit:$u"; done
  for u in $(agent_wants_links); do CHECK_LEFT="$CHECK_LEFT wants:$u"; done
  return 0
}

console_reminder() {
  log "提醒：腾讯云控制台可能把这些组件装回来，请在控制台关闭自动安装："
  log "  - 主机安全（云镜）：关闭对新增 / 现有主机自动安装客户端的设置"
  log "  - 云监控：关闭自动安装监控 agent 的设置"
  log "  - 购买或重装系统时取消勾选「云安全」「云监控」，镜像就不会自带这些组件"
  if [ "$KEEP_TAT" = 1 ]; then
    log "  - TAT 已保留：控制台仍可通过它在本机执行安装命令"
  fi
}

if [ "$DRY_RUN" = 1 ]; then
  check
  log "present now:${CHECK_LEFT:- nothing}"
  [ -n "$SCAN_HOLDERS" ] && log "note: processes holding YunJing files open (not counted):
$SCAN_HOLDERS"
  console_reminder
  exit 0
fi

log "waiting ${WAIT}s for any respawn"
sleep "$WAIT"
check
mapped=$(grep -l libonion /proc/[0-9]*/maps 2>/dev/null | wc -l)
log "still mapping deleted libonion: $mapped process(es) (cleared by a reboot)"
log "kept: $(find "$Q" -mindepth 1 -maxdepth 1 -printf '%f ' 2>/dev/null)"
if [ -d "$BACKUP_DIR" ]; then
  log "backup: $BACKUP_DIR"
else
  log "backup: nothing needed a copy"
fi
[ -n "$SCAN_HOLDERS" ] && log "note: processes holding YunJing files open (not counted):
$SCAN_HOLDERS"
[ -n "$FAILED" ] && log "could not delete:$FAILED"
console_reminder
if [ -n "$CHECK_LEFT" ]; then
  log "NOT CLEAN:$CHECK_LEFT"
  exit 2
fi
log "clean"
exit 0
