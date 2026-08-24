#!/usr/bin/env bash
#
#  HUBTune — защита VPN-ноды от OOM, разрастания логов и нехватки дескрипторов.
#
#  Поддерживает:
#    · Remnawave node   (docker compose)
#    · 3x-ui            (docker compose)
#    · 3x-ui            (нативная установка, systemd)
#    · любой другой сервис docker compose  (--target <имя контейнера>)
#
#  Ничего не правит в чужих файлах: для docker пишет отдельный
#  *.override.yml, для systemd — drop-in. Откат = удаление одного файла.
#
#  MIT License.  https://github.com/qwe8nxtroud/HUBTune
#

set -Eeuo pipefail

VERSION="1.0.0"
PROG="${0##*/}"

MARKER="managed-by: hubtune"
BACKUP_ROOT="/var/backups/hubtune"
SYSCTL_FILE="/etc/sysctl.d/99-hubtune.conf"
LIMITS_FILE="/etc/security/limits.d/99-hubtune.conf"
SWAPFILE="/swapfile-hubtune"
FSTAB_FILE="/etc/fstab"
LOGROTATE_FILE="/etc/logrotate.d/hubtune"
DROPIN_NAME="10-hubtune.conf"

# ── настройки по умолчанию (переопределяются флагами) ────────────────────────
RESERVE_PCT=20            # сколько процентов RAM оставляем системе
RESERVE_MIN_MIB=192       # но не меньше этого
RESERVE_MAX_MIB=1024      # и не больше этого
LIMIT_FLOOR_MIB=256       # ниже такого лимита Xray просто не живёт
SWAP_TRIGGER_MIB=2048     # при RAM <= этого предлагаем swap
SWAP_MAX_MIB=2048         # максимальный размер создаваемого swap
LOG_MAX_SIZE="10m"
LOG_MAX_FILE="3"
NOFILE=65535

# ── состояние ───────────────────────────────────────────────────────────────
CMD=""
MODE="safe"               # safe | full | memory
OPT_TARGET=""
OPT_MEM=""
OPT_RESERVE=""
ASSUME_YES=0
FORCE=0

# Что включено. Значения расставляет apply_mode() по выбранному режиму,
# поверх ложатся явные --no-* (в каком бы порядке их ни написали).
DO_MEM=1
DO_LOGS=1
DO_ULIMIT=1
DO_RESTART=1
DO_SWAP=0
DO_SYSCTL=0
DO_BBR=0
DO_LIMITSD=0
EX_MEM=""; EX_LOGS=""; EX_ULIMIT=""; EX_RESTART=""
EX_SWAP=""; EX_SYSCTL=""; EX_BBR=""

BACKUP_DIR=""
MANIFEST=""
ARGC=0

# ═════════════════════════════════ утилиты ══════════════════════════════════

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    CR=$'\033[0;31m'; CG=$'\033[0;32m'; CY=$'\033[0;33m'
    CB=$'\033[0;36m'; CD=$'\033[2m';    CN=$'\033[0m';   CW=$'\033[1m'
else
    CR=''; CG=''; CY=''; CB=''; CD=''; CN=''; CW=''
fi

say()  { printf '%s\n' "$*"; }
hdr()  { printf '\n%s%s%s\n' "$CW" "$*" "$CN"; }
info() { printf '  %s·%s %s\n' "$CB" "$CN" "$*"; }
ok()   { printf '  %s✓%s %s\n' "$CG" "$CN" "$*"; }
warn() { printf '  %s!%s %s\n' "$CY" "$CN" "$*"; }
bad()  { printf '  %s✗%s %s\n' "$CR" "$CN" "$*"; }
dim()  { printf '  %s%s%s\n' "$CD" "$*" "$CN"; }
die() {
    printf '\n%s✗ %s%s\n' "$CR" "$*" "$CN" >&2
    if [ "${APPLY_STARTED:-0}" = "1" ] && [ -n "${BACKUP_DIR:-}" ]; then
        APPLY_STARTED=0
        printf '%s  Откатываю изменения...%s\n' "$CY" "$CN" >&2
        rollback_from "$BACKUP_DIR" >&2 \
            || printf '  Автооткат не удался, откати вручную: %s rollback\n' "$PROG" >&2
    fi
    exit 1
}

confirm() {
    [ "$ASSUME_YES" = "1" ] && return 0
    if [ ! -r /dev/tty ]; then
        die "Нужно подтверждение, но терминала нет. Перезапусти с --yes."
    fi
    printf '\n%s%s%s [y/N] ' "$CY" "$1" "$CN" > /dev/tty
    local ans=""
    read -r ans < /dev/tty || ans=""
    case "$ans" in [Yy]|[Yy][Ee][Ss]) return 0 ;; *) return 1 ;; esac
}

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# «512m» / «1g» / «1024» (голое число = MiB) → MiB
parse_mib() {
    local v n unit
    v="$(lower "$1")"
    if [[ "$v" =~ ^([0-9]+)(b|k|kb|kib|m|mb|mib|g|gb|gib)?$ ]]; then
        n="${BASH_REMATCH[1]}"
        unit="${BASH_REMATCH[2]}"
        [ -z "$unit" ] && unit="m"
        case "$unit" in
            b)          printf '%d' $(( n / 1048576 )) ;;
            k|kb|kib)   printf '%d' $(( n / 1024 )) ;;
            m|mb|mib)   printf '%d' "$n" ;;
            g|gb|gib)   printf '%d' $(( n * 1024 )) ;;
        esac
        return 0
    fi
    return 1
}

fmt_mib() {
    local m="${1:-0}"
    if [ "$m" -ge 1024 ]; then
        awk -v m="$m" 'BEGIN{ printf "%.1f GiB", m/1024 }'
    else
        printf '%d MiB' "$m"
    fi
}

fmt_bytes() {
    local b="${1:-0}"
    awk -v b="$b" 'BEGIN{
        if (b >= 1073741824)   printf "%.1f GiB", b/1073741824;
        else if (b >= 1048576) printf "%.0f MiB", b/1048576;
        else if (b >= 1024)    printf "%.0f KiB", b/1024;
        else                   printf "%d B", b;
    }'
}

have() { command -v "$1" >/dev/null 2>&1; }

is_uint() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

# Три режима вместо пятнадцати флагов.
#   memory — только граница по памяти, больше ничего
#   safe   — память, логи, дескрипторы, автоперезапуск: всё в пределах сервиса
#   full   — плюс swap, сетевые sysctl и BBR, то есть настройки самого хоста
apply_mode() {
    case "$MODE" in
        memory) DO_MEM=1; DO_LOGS=0; DO_ULIMIT=0; DO_RESTART=0
                DO_SWAP=0; DO_SYSCTL=0; DO_BBR=0; DO_LIMITSD=0 ;;
        safe)   DO_MEM=1; DO_LOGS=1; DO_ULIMIT=1; DO_RESTART=1
                DO_SWAP=0; DO_SYSCTL=0; DO_BBR=0; DO_LIMITSD=0 ;;
        full)   DO_MEM=1; DO_LOGS=1; DO_ULIMIT=1; DO_RESTART=1
                DO_SWAP=1; DO_SYSCTL=1; DO_BBR=1; DO_LIMITSD=1 ;;
        *)      die "Неизвестный режим «$MODE». Доступны: safe, full, memory." ;;
    esac
    [ -n "$EX_MEM" ]     && DO_MEM="$EX_MEM"
    [ -n "$EX_LOGS" ]    && DO_LOGS="$EX_LOGS"
    [ -n "$EX_ULIMIT" ]  && DO_ULIMIT="$EX_ULIMIT"
    [ -n "$EX_RESTART" ] && DO_RESTART="$EX_RESTART"
    [ -n "$EX_SWAP" ]    && DO_SWAP="$EX_SWAP"
    [ -n "$EX_SYSCTL" ]  && DO_SYSCTL="$EX_SYSCTL"
    [ -n "$EX_BBR" ]     && DO_BBR="$EX_BBR"
    return 0
}

mode_label() {
    case "$MODE" in
        memory) printf 'только лимит памяти' ;;
        safe)   printf 'безопасный — трогаем только сам сервис' ;;
        full)   printf 'полный — включая swap и настройки хоста' ;;
        *)      printf '%s' "$MODE" ;;
    esac
}

require_root() {
    [ "$(id -u)" = "0" ] || die "Нужны права root. Запусти через sudo."
}

# ═══════════════════════════ информация о хосте ═════════════════════════════

HOST_RAM_MIB=0
HOST_AVAIL_MIB=0
HOST_SWAP_MIB=0
HOST_CGROUP=0
HOST_SWAPACCT=0
HOST_VIRT="unknown"
HOST_OS="unknown"
HOST_ROOTFS="unknown"
HOST_DISK_FREE_MIB=0

detect_host() {
    HOST_RAM_MIB=$(awk '/^MemTotal:/   {printf "%d", $2/1024}' /proc/meminfo)
    HOST_AVAIL_MIB=$(awk '/^MemAvailable:/ {printf "%d", $2/1024}' /proc/meminfo)
    HOST_SWAP_MIB=$(awk '/^SwapTotal:/  {printf "%d", $2/1024}' /proc/meminfo)
    [ -z "$HOST_AVAIL_MIB" ] && HOST_AVAIL_MIB=0

    if [ -f /sys/fs/cgroup/cgroup.controllers ]; then
        HOST_CGROUP=2
        # в корневой cgroup v2 файлов memory.* нет — смотрим дочерние
        if ls /sys/fs/cgroup/*/memory.swap.max >/dev/null 2>&1; then
            HOST_SWAPACCT=1
        elif grep -qw memory /sys/fs/cgroup/cgroup.controllers 2>/dev/null; then
            HOST_SWAPACCT=1
        fi
    elif [ -d /sys/fs/cgroup/memory ]; then
        HOST_CGROUP=1
        [ -e /sys/fs/cgroup/memory/memory.memsw.limit_in_bytes ] && HOST_SWAPACCT=1
    fi

    if have systemd-detect-virt; then
        HOST_VIRT="$(systemd-detect-virt 2>/dev/null || echo none)"
    fi

    if [ -r /etc/os-release ]; then
        # shellcheck disable=SC1091
        HOST_OS="$(. /etc/os-release 2>/dev/null && printf '%s %s' "${NAME:-?}" "${VERSION_ID:-}")"
    fi

    HOST_ROOTFS="$(findmnt -no FSTYPE / 2>/dev/null || echo unknown)"
    HOST_DISK_FREE_MIB="$(df -Pm / 2>/dev/null | awk 'NR==2{print $4}')"
    [ -z "$HOST_DISK_FREE_MIB" ] && HOST_DISK_FREE_MIB=0
}

# Единственная формула лимита: оставить системе разумный запас, остальное — ноде.
#   reserve = clamp(RESERVE_MIN, RAM * RESERVE_PCT%, RESERVE_MAX)
calc_limit_mib() {
    local total="$1" reserve limit
    reserve=$(( total * RESERVE_PCT / 100 ))
    [ "$reserve" -lt "$RESERVE_MIN_MIB" ] && reserve="$RESERVE_MIN_MIB"
    [ "$reserve" -gt "$RESERVE_MAX_MIB" ] && reserve="$RESERVE_MAX_MIB"
    limit=$(( total - reserve ))
    [ "$limit" -lt "$LIMIT_FLOOR_MIB" ] && limit="$LIMIT_FLOOR_MIB"
    # на совсем крошечных VPS не даём лимиту съесть весь хост
    if [ "$limit" -gt $(( total - 64 )) ]; then
        limit=$(( total - 64 ))
    fi
    printf '%d' "$limit"
}

# ═══════════════════════════ определение цели ═══════════════════════════════

TG_MODE=""          # docker | systemd
TG_KIND=""          # remnanode | 3x-ui | panel | other
TG_LABEL=""         # человекочитаемое название
TG_CONTAINER=""
TG_IMAGE=""
TG_SERVICE=""
TG_WORKDIR=""
TG_BASEFILE=""
TG_CONFIGS=""
TG_OVERRIDE=""
TG_UNIT=""
PANEL_SEEN=0

docker_ready() { have docker && docker info >/dev/null 2>&1; }
compose_ready() { docker compose version >/dev/null 2>&1; }

classify_image() {
    local img name
    img="$(lower "$1")"; name="$(lower "${2:-}")"
    case "$img" in
        *remnawave/node*)                printf 'remnanode' ; return ;;
        *remnawave/backend*)             printf 'panel'     ; return ;;
        *remnawave/subscription*)        printf 'panel'     ; return ;;
        *remnawave/caddy*)               printf 'panel'     ; return ;;
        *3x-ui*|*3xui*|*/x-ui*)          printf '3x-ui'     ; return ;;
        *marzban*)                       printf 'marzban'   ; return ;;
    esac
    # у 3x-ui образ собирается локально (build:), имя образа непредсказуемо —
    # добиваем по точному имени контейнера, но осторожно: 3xui_postgres это не 3x-ui
    case "$name" in
        remnanode|remnawave-node)        printf 'remnanode' ; return ;;
        3x-ui|3xui|3xui_app|x-ui)        printf '3x-ui'     ; return ;;
        remnawave|remnawave-db|remnawave-redis|remnawave-valkey|remnawave-caddy|remnawave-subscription-page)
                                         printf 'panel'     ; return ;;
    esac
    printf 'other'
}

# Выбираем контейнер, читая compose-метки самого Docker,
# а не угадывая путь к каталогу.
detect_docker_target() {
    local name image project service workdir configs state kind rank
    local n=0 i=0 best_rank=99 ties=0 chosen=-1
    local c_name c_image c_project c_service c_workdir c_configs c_kind c_rank c_state
    # bash 3.2-совместимые массивы объявляем без -A
    c_name=(); c_image=(); c_project=(); c_service=(); c_workdir=()
    c_configs=(); c_kind=(); c_rank=(); c_state=()

    while IFS=$'\t' read -r name image project service workdir configs state; do
        [ -z "$name" ] && continue
        kind="$(classify_image "$image" "$name")"
        if [ "$kind" = "panel" ]; then PANEL_SEEN=1; fi

        if [ -n "$OPT_TARGET" ]; then
            case "$OPT_TARGET" in
                remnanode|3x-ui|panel|marzban)
                    [ "$kind" = "$OPT_TARGET" ] || continue ;;
                *)  [ "$name" = "$OPT_TARGET" ] || continue ;;
            esac
            rank=0
        else
            case "$kind" in
                remnanode) rank=1 ;;
                3x-ui)     rank=2 ;;
                marzban)   rank=3 ;;
                *)         continue ;;
            esac
        fi
        # мёртвый контейнер от неудачной установки не должен побеждать живой
        if [ "$state" != "running" ]; then rank=$(( rank + 10 )); fi

        c_name[$n]="$name";       c_image[$n]="$image"
        c_project[$n]="$project"; c_service[$n]="$service"
        c_workdir[$n]="$workdir"
        c_configs[$n]="$configs"; c_kind[$n]="$kind"
        c_rank[$n]="$rank";       c_state[$n]="$state"
        if [ "$rank" -lt "$best_rank" ]; then best_rank="$rank"; fi
        n=$(( n + 1 ))
    done < <(docker ps -a --format \
        '{{.Names}}	{{.Image}}	{{.Label "com.docker.compose.project"}}	{{.Label "com.docker.compose.service"}}	{{.Label "com.docker.compose.project.working_dir"}}	{{.Label "com.docker.compose.project.config_files"}}	{{.State}}' \
        2>/dev/null)

    [ "$n" -eq 0 ] && return 1

    i=0
    while [ "$i" -lt "$n" ]; do
        if [ "${c_rank[$i]}" = "$best_rank" ]; then
            ties=$(( ties + 1 ))
            if [ "$chosen" -lt 0 ]; then chosen="$i"; fi
        fi
        i=$(( i + 1 ))
    done

    # Молча выбрать один из нескольких — верный способ оставить вторую ноду
    # без лимита и не сказать об этом.
    if [ "$ties" -gt 1 ]; then
        say ""
        printf '  %s!%s Подходит больше одного контейнера. Выбери явно:\n' "$CY" "$CN"
        i=0
        while [ "$i" -lt "$n" ]; do
            if [ "${c_rank[$i]}" = "$best_rank" ]; then
                dim "  $PROG $CMD --target ${c_name[$i]}   (${c_image[$i]}, ${c_state[$i]})"
            fi
            i=$(( i + 1 ))
        done
        die "Цель неоднозначна."
    fi

    TG_MODE="docker"
    TG_KIND="${c_kind[$chosen]}"
    TG_CONTAINER="${c_name[$chosen]}"
    TG_IMAGE="${c_image[$chosen]}"
    TG_PROJECT="${c_project[$chosen]}"
    TG_SERVICE="${c_service[$chosen]}"
    TG_WORKDIR="${c_workdir[$chosen]}"
    TG_CONFIGS="${c_configs[$chosen]}"
    TG_BASEFILE="${TG_CONFIGS%%,*}"

    case "$TG_KIND" in
        remnanode) TG_LABEL="Remnawave node (docker compose)" ;;
        3x-ui)     TG_LABEL="3x-ui (docker compose)" ;;
        marzban)   TG_LABEL="Marzban (docker compose)" ;;
        panel)     TG_LABEL="Remnawave panel (docker compose)" ;;
        *)         TG_LABEL="контейнер $TG_CONTAINER (docker compose)" ;;
    esac
    return 0
}

# Нативная 3x-ui: systemd-юнит без docker.
detect_systemd_target() {
    local unit
    for unit in x-ui xray; do
        if systemctl cat "${unit}.service" >/dev/null 2>&1; then
            TG_MODE="systemd"
            TG_UNIT="${unit}.service"
            if [ "$unit" = "x-ui" ]; then
                TG_KIND="3x-ui"; TG_LABEL="3x-ui (нативная установка, systemd)"
            else
                TG_KIND="other"; TG_LABEL="xray.service (нативная установка, systemd)"
            fi
            return 0
        fi
    done
    return 1
}

detect_target() {
    if [ -n "$OPT_TARGET" ] && [[ "$OPT_TARGET" == *.service ]]; then
        systemctl cat "$OPT_TARGET" >/dev/null 2>&1 \
            || die "Юнит $OPT_TARGET не найден."
        TG_MODE="systemd"; TG_UNIT="$OPT_TARGET"; TG_KIND="other"
        TG_LABEL="$OPT_TARGET (systemd)"
        return 0
    fi

    if docker_ready; then
        compose_ready || warn "docker compose v2 не найден — команды up/down будут недоступны."
        detect_docker_target && return 0
    fi
    detect_systemd_target && return 0
    return 1
}

# compose ищет override с тем же «диалектом» имени, что и базовый файл
override_path_for() {
    local base="$1" dir file
    dir="$(dirname "$base")"; file="$(basename "$base")"
    case "$file" in
        docker-compose.yml)  printf '%s/docker-compose.override.yml'  "$dir" ;;
        docker-compose.yaml) printf '%s/docker-compose.override.yaml' "$dir" ;;
        compose.yml)         printf '%s/compose.override.yml'         "$dir" ;;
        compose.yaml)        printf '%s/compose.override.yaml'        "$dir" ;;
        *)                   printf '%s/docker-compose.override.yml'  "$dir" ;;
    esac
}

resolve_compose_paths() {
    [ "$TG_MODE" = "docker" ] || return 0

    if [ -z "$TG_WORKDIR" ] || [ ! -d "$TG_WORKDIR" ]; then
        die "У контейнера $TG_CONTAINER нет compose-меток (запущен через docker run?).
   HUBTune управляет только сервисами docker compose."
    fi
    if [ -z "$TG_BASEFILE" ] || [ ! -f "$TG_BASEFILE" ]; then
        local f
        for f in docker-compose.yml docker-compose.yaml compose.yml compose.yaml; do
            [ -f "$TG_WORKDIR/$f" ] && { TG_BASEFILE="$TG_WORKDIR/$f"; break; }
        done
    fi
    [ -f "$TG_BASEFILE" ] || die "Не нашёл compose-файл в $TG_WORKDIR."
    [ -z "$TG_SERVICE" ] && TG_SERVICE="$TG_CONTAINER"
    [ -z "$TG_CONFIGS" ] && TG_CONFIGS="$TG_BASEFILE"
    TG_OVERRIDE="$(override_path_for "$TG_BASEFILE")"

    # На повторном запуске compose уже сам подхватил наш override и вписал его
    # в config_files. В список «родных» файлов проекта он попасть не должен.
    local f keep=""
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        [ "$f" = "$TG_OVERRIDE" ] && continue
        keep="$keep,$f"
    done < <(printf '%s' "$TG_CONFIGS" | tr ',' '\n')
    TG_CONFIGS="${keep#,}"
    [ -z "$TG_CONFIGS" ] && TG_CONFIGS="$TG_BASEFILE"
    return 0
}

die_no_target() {
    if [ "$PANEL_SEEN" = "1" ]; then
        die "Похоже, это хост ПАНЕЛИ Remnawave, а не ноды — ноды здесь нет.
   Запускай HUBTune на серверах с remnanode или 3x-ui.
   Если всё же нужно ограничить контейнер панели, укажи его явно и осознанно:
     $PROG plan --target <имя-контейнера> --force
   Только не вешай жёсткий лимит на remnawave-db: Postgres не умеет ужиматься
   по требованию ядра и будет убит вместе с базой."
    fi
    die "Не нашёл ни Remnawave node, ни 3x-ui, ни другой compose-сервис.
   Проверь, что сервис запущен, и при необходимости укажи цель явно:
     $PROG status --target <имя-контейнера>
     $PROG status --target x-ui.service"
}

panel_guard() {
    if [ "$TG_KIND" = "panel" ] && [ "$FORCE" != "1" ]; then
        die "Целью выбрана ПАНЕЛЬ Remnawave, а не нода.
   Лимит памяти на backend/postgres панели требует отдельного расчёта:
   у Postgres свой shared_buffers, жёсткий cgroup-лимит его роняет.
   Если действительно нужно — повтори с --force и --mem-limit <значение>."
    fi
    if [ "$PANEL_SEEN" = "1" ] && [ "$TG_KIND" != "panel" ]; then
        warn "На этом хосте рядом крутится панель Remnawave — трогаем только $TG_CONTAINER."
    fi
}

# ═════════════════════════ текущее состояние цели ═══════════════════════════

CUR_RUNNING=0
CUR_MEM_LIMIT=0        # байт, 0 = не задан
CUR_MEMSW_LIMIT=0
CUR_USAGE=0
CUR_PEAK=0
CUR_OOM_KILLS=-1       # -1 = не удалось прочитать
CUR_OOM_LAST=0
CUR_RESTARTS=0
CUR_RESTART_POLICY=""
CUR_LOG_DRIVER=""
CUR_LOG_ROTATED=0
CUR_LOG_BYTES=0
CUR_NOFILE_SOFT=0
CUR_NOFILE_HARD=0
CUR_IMAGE_ID=""
CUR_STATUS=""
CUR_MAIN_PID=0

dockerf() { docker inspect --format "$1" "$TG_CONTAINER" 2>/dev/null || printf ''; }

read_cgroup_file() {
    local f="$1"
    [ -r "$f" ] || return 1
    head -c 128 "$f" 2>/dev/null | tr -d '\n'
}

# Путь cgroup процесса — надёжнее, чем угадывать systemd/cgroupfs драйвер
cgroup_dir_for_pid() {
    local pid="$1" rel=""
    [ "$pid" -gt 0 ] 2>/dev/null || return 1
    [ -r "/proc/$pid/cgroup" ] || return 1
    if [ "$HOST_CGROUP" = "2" ]; then
        rel="$(awk -F: '$1=="0"{print $3; exit}' "/proc/$pid/cgroup")"
        [ -n "$rel" ] && [ -d "/sys/fs/cgroup$rel" ] && { printf '/sys/fs/cgroup%s' "$rel"; return 0; }
    else
        rel="$(awk -F: '$2 ~ /(^|,)memory(,|$)/ {print $3; exit}' "/proc/$pid/cgroup")"
        [ -n "$rel" ] && [ -d "/sys/fs/cgroup/memory$rel" ] && { printf '/sys/fs/cgroup/memory%s' "$rel"; return 0; }
    fi
    return 1
}

read_oom_and_peak() {
    local dir v
    dir="$(cgroup_dir_for_pid "$CUR_MAIN_PID")" || return 0
    if [ "$HOST_CGROUP" = "2" ]; then
        if [ -r "$dir/memory.events" ]; then
            v="$(awk '$1=="oom_kill"{print $2; exit}' "$dir/memory.events")"
            [ -n "$v" ] && CUR_OOM_KILLS="$v"
        fi
        v="$(read_cgroup_file "$dir/memory.peak")" && [ -n "$v" ] && CUR_PEAK="$v"
        [ "$CUR_USAGE" = "0" ] && { v="$(read_cgroup_file "$dir/memory.current")" && CUR_USAGE="${v:-0}"; }
    else
        v="$(read_cgroup_file "$dir/memory.failcnt")" && [ -n "$v" ] && CUR_OOM_KILLS="$v"
        v="$(read_cgroup_file "$dir/memory.max_usage_in_bytes")" && [ -n "$v" ] && CUR_PEAK="$v"
        [ "$CUR_USAGE" = "0" ] && { v="$(read_cgroup_file "$dir/memory.usage_in_bytes")" && CUR_USAGE="${v:-0}"; }
    fi
    return 0
}

read_state_docker() {
    local v logpath
    [ "$(dockerf '{{.State.Running}}')" = "true" ] && CUR_RUNNING=1
    CUR_STATUS="$(dockerf '{{.State.Status}}')"
    CUR_MAIN_PID="$(dockerf '{{.State.Pid}}')"; [ -z "$CUR_MAIN_PID" ] && CUR_MAIN_PID=0
    CUR_MEM_LIMIT="$(dockerf '{{.HostConfig.Memory}}')";      [ -z "$CUR_MEM_LIMIT" ] && CUR_MEM_LIMIT=0
    CUR_MEMSW_LIMIT="$(dockerf '{{.HostConfig.MemorySwap}}')";[ -z "$CUR_MEMSW_LIMIT" ] && CUR_MEMSW_LIMIT=0
    CUR_RESTARTS="$(dockerf '{{.RestartCount}}')";            [ -z "$CUR_RESTARTS" ] && CUR_RESTARTS=0
    CUR_RESTART_POLICY="$(dockerf '{{.HostConfig.RestartPolicy.Name}}')"
    CUR_IMAGE_ID="$(dockerf '{{.Image}}')"
    [ "$(dockerf '{{.State.OOMKilled}}')" = "true" ] && CUR_OOM_LAST=1

    CUR_LOG_DRIVER="$(dockerf '{{.HostConfig.LogConfig.Type}}')"
    v="$(dockerf '{{index .HostConfig.LogConfig.Config "max-size"}}')"
    [ -n "$v" ] && [ "$v" != "<no value>" ] && CUR_LOG_ROTATED=1

    logpath="$(dockerf '{{.LogPath}}')"
    if [ -n "$logpath" ] && [ -f "$logpath" ]; then
        # ротации ещё нет -> файлов *.log.1 нет -> glob не раскроется -> du вернёт 1.
        # Под pipefail это молча убивало бы весь скрипт, поэтому || true обязателен.
        CUR_LOG_BYTES="$(du -cb "$logpath" "$logpath".* 2>/dev/null \
                          | awk '$2=="total"{print $1; exit}' || true)"
        case "$CUR_LOG_BYTES" in ''|*[!0-9]*) CUR_LOG_BYTES=0 ;; esac
    fi

    if [ "$CUR_RUNNING" = "1" ] && [ "$CUR_MAIN_PID" -gt 0 ] 2>/dev/null; then
        if [ -r "/proc/$CUR_MAIN_PID/limits" ]; then
            CUR_NOFILE_SOFT="$(awk '/Max open files/{print $4; exit}' "/proc/$CUR_MAIN_PID/limits")"
            CUR_NOFILE_HARD="$(awk '/Max open files/{print $5; exit}' "/proc/$CUR_MAIN_PID/limits")"
        fi
        read_oom_and_peak
    fi
    return 0
}

read_state_systemd() {
    local v
    systemctl is-active --quiet "$TG_UNIT" && CUR_RUNNING=1
    CUR_STATUS="$(systemctl is-active "$TG_UNIT" 2>/dev/null || true)"
    CUR_MAIN_PID="$(systemctl show -p MainPID --value "$TG_UNIT" 2>/dev/null || echo 0)"
    [ -z "$CUR_MAIN_PID" ] && CUR_MAIN_PID=0

    v="$(systemctl show -p MemoryMax --value "$TG_UNIT" 2>/dev/null || true)"
    case "$v" in ''|infinity|18446744073709551615) CUR_MEM_LIMIT=0 ;; *) CUR_MEM_LIMIT="$v" ;; esac
    v="$(systemctl show -p MemoryCurrent --value "$TG_UNIT" 2>/dev/null || true)"
    case "$v" in ''|'[not set]'|18446744073709551615) CUR_USAGE=0 ;; *) CUR_USAGE="$v" ;; esac
    v="$(systemctl show -p LimitNOFILE --value "$TG_UNIT" 2>/dev/null || true)"
    [ -n "$v" ] && CUR_NOFILE_SOFT="$v" && CUR_NOFILE_HARD="$v"
    CUR_RESTART_POLICY="$(systemctl show -p Restart --value "$TG_UNIT" 2>/dev/null || true)"
    CUR_RESTARTS="$(systemctl show -p NRestarts --value "$TG_UNIT" 2>/dev/null || echo 0)"
    if [ "${CUR_MAIN_PID:-0}" -gt 0 ] 2>/dev/null; then read_oom_and_peak; fi
    return 0
}

read_current_state() {
    case "$TG_MODE" in
        docker)  read_state_docker ;;
        systemd) read_state_systemd ;;
    esac
    return 0
}

boot_autostart_status() {
    if [ "$TG_MODE" = "docker" ]; then
        local dockeren="нет"
        systemctl is-enabled --quiet docker 2>/dev/null && dockeren="да"
        case "$CUR_RESTART_POLICY" in
            always|unless-stopped) printf 'restart=%s, docker.service в автозагрузке: %s' "$CUR_RESTART_POLICY" "$dockeren" ;;
            *)                     printf 'restart=%s — контейнер НЕ поднимется после ребута' "${CUR_RESTART_POLICY:-no}" ;;
        esac
    else
        local en="нет"
        systemctl is-enabled --quiet "$TG_UNIT" 2>/dev/null && en="да"
        printf 'Restart=%s, юнит в автозагрузке: %s' "${CUR_RESTART_POLICY:-no}" "$en"
    fi
}

# ═════════════════════════════ команда status ═══════════════════════════════

ISSUES=0
issue() { ISSUES=$(( ISSUES + 1 )); bad "$*"; }

cmd_status() {
    detect_host
    detect_target || die_no_target
    resolve_compose_paths
    read_current_state

    local want_mem_mib
    if [ -n "$OPT_MEM" ]; then want_mem_mib="$(parse_mib "$OPT_MEM")"
    else want_mem_mib="$(calc_limit_mib "$HOST_RAM_MIB")"; fi

    hdr "Хост"
    info "ОС              $HOST_OS ($(uname -m)), виртуализация: $HOST_VIRT"
    info "RAM             $(fmt_mib "$HOST_RAM_MIB")   доступно $(fmt_mib "$HOST_AVAIL_MIB")"
    if [ "$HOST_SWAP_MIB" -gt 0 ]; then
        info "Swap            $(fmt_mib "$HOST_SWAP_MIB")"
    elif [ "$HOST_RAM_MIB" -le "$SWAP_TRIGGER_MIB" ]; then
        issue "Swap            нет — на $(fmt_mib "$HOST_RAM_MIB") это почти гарантированный OOM в пике"
    else
        info "Swap            нет"
    fi
    info "cgroup          v$HOST_CGROUP, учёт swap: $([ "$HOST_SWAPACCT" = 1 ] && echo да || echo нет)"
    info "Диск /          свободно $(fmt_mib "$HOST_DISK_FREE_MIB") ($HOST_ROOTFS)"

    hdr "Цель"
    info "Тип             $TG_LABEL"
    if [ "$TG_MODE" = "docker" ]; then
        info "Контейнер       $TG_CONTAINER  ($CUR_STATUS, перезапусков: $CUR_RESTARTS)"
        info "Образ           $TG_IMAGE  ${CUR_IMAGE_ID:0:19}"
        info "Compose         $TG_BASEFILE"
    else
        info "Юнит            $TG_UNIT  ($CUR_STATUS, перезапусков: $CUR_RESTARTS)"
    fi
    info "Автозапуск      $(boot_autostart_status)"
    case "$CUR_RESTART_POLICY" in
        always|unless-stopped|on-failure) ;;
        *) issue "Политика перезапуска не задана — после падения или ребута сервис не вернётся" ;;
    esac

    hdr "Память"
    if [ "$CUR_MEM_LIMIT" -gt 0 ] 2>/dev/null; then
        info "Лимит           $(fmt_bytes "$CUR_MEM_LIMIT")"
    else
        issue "Лимит           не задан — при утечке ядро будет выбирать жертву на всём хосте"
        dim   "                рекомендуется $(fmt_mib "$want_mem_mib") (системе останется $(fmt_mib $(( HOST_RAM_MIB - want_mem_mib ))))"
    fi
    [ "$CUR_USAGE" -gt 0 ] 2>/dev/null && info "Сейчас          $(fmt_bytes "$CUR_USAGE")"
    [ "$CUR_PEAK"  -gt 0 ] 2>/dev/null && info "Пик             $(fmt_bytes "$CUR_PEAK")"
    if [ "$CUR_OOM_KILLS" -gt 0 ] 2>/dev/null; then
        if [ "$HOST_CGROUP" = "2" ]; then
            issue "OOM-kill        $CUR_OOM_KILLS раз — сервис уже убивали по памяти"
        else
            warn "Отказов по лимиту (failcnt): $CUR_OOM_KILLS"
        fi
    fi
    [ "$CUR_OOM_LAST" = "1" ] && issue "Последняя остановка — именно OOM-kill"

    if [ "$TG_MODE" = "docker" ]; then
        hdr "Логи Docker"
        info "Драйвер         ${CUR_LOG_DRIVER:-?}"
        if [ "$CUR_LOG_DRIVER" = "json-file" ] && [ "$CUR_LOG_ROTATED" = "0" ]; then
            issue "Ротация         не настроена — лог растёт до заполнения диска"
        else
            info "Ротация         настроена"
        fi
        [ "$CUR_LOG_BYTES" -gt 0 ] 2>/dev/null && info "Размер сейчас   $(fmt_bytes "$CUR_LOG_BYTES")"
        if [ "$CUR_LOG_BYTES" -gt 1073741824 ] 2>/dev/null; then
            issue "Логи занимают больше гигабайта"
        fi
    fi

    hdr "Дескрипторы"
    if [ "$CUR_NOFILE_SOFT" -gt 0 ] 2>/dev/null; then
        info "nofile          soft $CUR_NOFILE_SOFT / hard $CUR_NOFILE_HARD"
        if [ "$CUR_NOFILE_SOFT" -lt 10240 ] 2>/dev/null; then
            issue "Мягкий лимит меньше 10240 — под нагрузкой будет «too many open files»"
        fi
    else
        dim "nofile          не удалось прочитать (сервис не запущен?)"
    fi

    hdr "Сеть"
    local cc qd
    cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '?')"
    qd="$(sysctl -n net.core.default_qdisc 2>/dev/null || echo '?')"
    info "Контроль пере-  $cc / qdisc $qd"
    if [ "$cc" != "bbr" ]; then
        warn "BBR не включён — на дальних маршрутах это заметная потеря скорости"
    fi

    say ""
    if [ "$ISSUES" -eq 0 ]; then
        ok "Замечаний нет."
    else
        printf '%s%d замечани%s.%s Что именно будет изменено — покажет:  %s%s plan%s\n' \
            "$CY" "$ISSUES" "$([ "$ISSUES" = 1 ] && echo 'е' || echo 'я')" "$CN" "$CW" "$PROG" "$CN"
    fi
    say ""
}

# ═════════════════════════════════ план ═════════════════════════════════════

TG_PROJECT=""
PLAN_MEM_MIB=0
PLAN_MEMSW=0
PLAN_LOGS=0
PLAN_NOFILE=0
PLAN_RESTART=0
PLAN_SWAP_MIB=0
PLAN_LOGROTATE=""
PLAN_SYSCTL=0
PLAN_SYSCTL_BODY=""
PLAN_MEM_NOTE=""
PLAN_STEPS=0

bbr_available() {
    grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null && return 0
    modprobe tcp_bbr 2>/dev/null || true
    grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null
}

build_sysctl_body() {
    local body
    body="# $MARKER $VERSION
# Файл создан HUBTune. Откат: hubtune.sh rollback (или rm этого файла).

# больше дескрипторов на весь хост
fs.file-max = 1048576

# очереди приёма: иначе всплески соединений теряются ещё до Xray
net.core.somaxconn = 8192
net.core.netdev_max_backlog = 16384
net.ipv4.tcp_max_syn_backlog = 8192

# держим соединения живыми и не сбрасываем окно на паузах
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1

# swap только как страховка от OOM, не как рабочая память
vm.swappiness = 10
vm.vfs_cache_pressure = 50"

    if [ "$DO_BBR" = "1" ] && bbr_available; then
        body="$body

# BBR заметно поднимает скорость на длинных маршрутах с потерями
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr"
    fi

    if [ -e /proc/sys/net/netfilter/nf_conntrack_max ]; then
        body="$body

# таблица conntrack: при переполнении пакеты молча дропаются
net.netfilter.nf_conntrack_max = 262144"
    fi

    printf '%s\n' "$body"
}

# Xray пишет access.log сам и ротации у него нет — issue MHSanaei/3x-ui#1234.
# Файл держится открытым, поэтому единственный безопасный режим — copytruncate.
find_unrotated_logs() {
    local f out=""
    for f in /usr/local/x-ui/access.log /usr/local/x-ui/error.log \
             /var/log/xray/access.log /var/log/xray/error.log; do
        [ -f "$f" ] || continue
        # правило может быть записано и маской: /var/log/xray/*.log
        grep -rlF "$f" /etc/logrotate.d /etc/logrotate.conf >/dev/null 2>&1 && continue
        grep -rlF "$(dirname "$f")/*" /etc/logrotate.d /etc/logrotate.conf >/dev/null 2>&1 && continue
        out="$out $f"
    done
    printf '%s' "${out# }"
}

swap_blocked_reason() {
    [ "$HOST_SWAP_MIB" -gt 0 ] && { printf 'swap уже есть'; return; }
    [ "$HOST_RAM_MIB" -gt "$SWAP_TRIGGER_MIB" ] && { printf 'RAM больше %s, swap не нужен' "$(fmt_mib "$SWAP_TRIGGER_MIB")"; return; }
    case "$HOST_VIRT" in
        openvz|lxc|lxc-libvirt|docker|podman) printf 'контейнерная виртуализация (%s) — swapfile недоступен' "$HOST_VIRT"; return ;;
    esac
    case "$HOST_ROOTFS" in
        btrfs|zfs) printf 'корень на %s — swapfile требует ручной подготовки' "$HOST_ROOTFS"; return ;;
    esac
    local need=$(( HOST_RAM_MIB < SWAP_MAX_MIB ? HOST_RAM_MIB : SWAP_MAX_MIB ))
    if [ "$HOST_DISK_FREE_MIB" -lt $(( need + 1024 )) ]; then
        printf 'на диске мало места (нужно %s + запас)' "$(fmt_mib "$need")"; return
    fi
    printf ''
}

build_plan() {
    local want reason

    if [ "$DO_MEM" = "1" ]; then
        if [ -n "$OPT_MEM" ]; then
            want="$(parse_mib "$OPT_MEM")" || die "Не понял значение --mem-limit «$OPT_MEM». Примеры: 768m, 1g, 1536m"
        elif [ -n "$OPT_RESERVE" ]; then
            local res; res="$(parse_mib "$OPT_RESERVE")" || die "Не понял значение --reserve «$OPT_RESERVE»."
            want=$(( HOST_RAM_MIB - res ))
            [ "$want" -lt "$LIMIT_FLOOR_MIB" ] && want="$LIMIT_FLOOR_MIB"
        elif [ "$HOST_RAM_MIB" -lt 512 ]; then
            # Ниже 512 MiB формула даёт лимит, при котором Xray просто не живёт.
            # Молча выставить его — значит устроить цикл перезапусков.
            PLAN_MEM_NOTE="на $(fmt_mib "$HOST_RAM_MIB") автоматический лимит не считаем — задай --mem-limit вручную"
            want=0
        else
            want="$(calc_limit_mib "$HOST_RAM_MIB")"
        fi
        if [ "$want" -gt 0 ] && [ "$(( want * 1048576 ))" != "$CUR_MEM_LIMIT" ]; then
            PLAN_MEM_MIB="$want"; PLAN_STEPS=$(( PLAN_STEPS + 1 ))
        fi
        [ "$HOST_SWAPACCT" = "1" ] && PLAN_MEMSW=1
    fi

    if [ "$TG_MODE" = "docker" ]; then
        if [ "$DO_LOGS" = "1" ] && [ "$CUR_LOG_DRIVER" = "json-file" ] && [ "$CUR_LOG_ROTATED" = "0" ]; then
            PLAN_LOGS=1; PLAN_STEPS=$(( PLAN_STEPS + 1 ))
        fi
    fi

    if [ "$DO_ULIMIT" = "1" ] && [ "${CUR_NOFILE_SOFT:-0}" -lt "$NOFILE" ] 2>/dev/null; then
        PLAN_NOFILE=1; PLAN_STEPS=$(( PLAN_STEPS + 1 ))
    fi

    if [ "$DO_RESTART" = "1" ]; then
        case "$CUR_RESTART_POLICY" in
            always|unless-stopped|on-failure) ;;
            *) PLAN_RESTART=1; PLAN_STEPS=$(( PLAN_STEPS + 1 )) ;;
        esac
    fi

    if [ "$DO_SWAP" = "1" ]; then
        reason="$(swap_blocked_reason)"
        if [ -z "$reason" ]; then
            PLAN_SWAP_MIB=$(( HOST_RAM_MIB < SWAP_MAX_MIB ? HOST_RAM_MIB : SWAP_MAX_MIB ))
            PLAN_STEPS=$(( PLAN_STEPS + 1 ))
        fi
    fi

    if [ "$DO_LOGS" = "1" ] && [ "$TG_MODE" = "systemd" ]; then
        PLAN_LOGROTATE="$(find_unrotated_logs)"
        [ -n "$PLAN_LOGROTATE" ] && PLAN_STEPS=$(( PLAN_STEPS + 1 ))
    fi

    if [ "$DO_SYSCTL" = "1" ]; then
        PLAN_SYSCTL_BODY="$(build_sysctl_body)"
        if [ ! -f "$SYSCTL_FILE" ] || ! printf '%s\n' "$PLAN_SYSCTL_BODY" | cmp -s - "$SYSCTL_FILE"; then
            PLAN_SYSCTL=1; PLAN_STEPS=$(( PLAN_STEPS + 1 ))
        fi
    fi
}

# Лимит ниже реального потребления — это не защита от OOM, а гарантированный
# цикл перезапусков. Проверяем до того, как что-то трогать.
mem_sanity_check() {
    [ "$PLAN_MEM_MIB" -gt 0 ] || return 0
    local want ref=0 what=""
    want=$(( PLAN_MEM_MIB * 1048576 ))
    if is_uint "${CUR_PEAK:-}" && [ "${CUR_PEAK:-0}" -gt "$ref" ]; then
        ref="$CUR_PEAK"; what="пика потребления"
    fi
    if is_uint "${CUR_USAGE:-}" && [ "${CUR_USAGE:-0}" -gt "$ref" ]; then
        ref="$CUR_USAGE"; what="текущего потребления"
    fi
    [ "$ref" -gt 0 ] || return 0
    [ "$want" -ge "$ref" ] && return 0

    say ""
    bad "Лимит $(fmt_mib "$PLAN_MEM_MIB") МЕНЬШЕ $what ($(fmt_bytes "$ref"))."
    dim "  Сервис уйдёт в цикл перезапусков, а не защитится от OOM."
    dim "  Варианты: увеличить RAM, задать лимит вручную (--mem-limit) выше пика,"
    dim "  либо сначала разобраться с утечкой (для XHTTP — параметры xmux)."
    say ""
    return 1
}

render_plan() {
    local sys_left reason
    hdr "Что будет сделано"

    if [ -n "$PLAN_MEM_NOTE" ]; then
        warn "$PLAN_MEM_NOTE"
    fi

    if [ "$PLAN_MEM_MIB" -gt 0 ]; then
        sys_left=$(( HOST_RAM_MIB - PLAN_MEM_MIB ))
        if [ "$TG_MODE" = "docker" ]; then
            ok "лимит памяти контейнера → $(fmt_mib "$PLAN_MEM_MIB")  (системе остаётся $(fmt_mib "$sys_left"))"
            [ "$PLAN_MEMSW" = "1" ] && dim "memswap_limit = mem_limit, то есть контейнеру swap запрещён"
        else
            ok "MemoryMax юнита → $(fmt_mib "$PLAN_MEM_MIB")  (системе остаётся $(fmt_mib "$sys_left"))"
        fi
        if [ "$CUR_MEM_LIMIT" -gt 0 ] 2>/dev/null; then
            dim "было: $(fmt_bytes "$CUR_MEM_LIMIT")"
        else
            dim "было: без лимита"
        fi
        if [ "$TG_KIND" = "3x-ui" ]; then
            dim "3x-ui сам прочитает cgroup-лимит и выставит GOMEMLIMIT в 90% от него,"
            dim "то есть сборщик мусора Go начнёт работать ДО того, как сработает OOM"
        fi
    elif [ "$DO_MEM" = "1" ]; then
        dim "лимит памяти уже выставлен как нужно — пропускаем"
    fi

    [ "$PLAN_LOGS" = "1" ] && \
        ok "ротация логов → json-file, max-size=$LOG_MAX_SIZE × $LOG_MAX_FILE файла (сейчас: без ограничения)"
    if [ "$PLAN_NOFILE" = "1" ]; then
        ok "nofile → $NOFILE (сейчас: ${CUR_NOFILE_SOFT:-?})"
        [ "$TG_MODE" = "systemd" ] && [ "$DO_LIMITSD" = "1" ] \
            && dim "и глобально для сессий: $LIMITS_FILE"
    fi
    [ "$PLAN_RESTART" = "1" ] && \
        ok "политика перезапуска → always (сейчас: ${CUR_RESTART_POLICY:-no})"

    if [ "$PLAN_SWAP_MIB" -gt 0 ]; then
        ok "swap-файл $SWAPFILE на $(fmt_mib "$PLAN_SWAP_MIB") + запись в /etc/fstab"
    elif [ "$DO_SWAP" = "1" ]; then
        reason="$(swap_blocked_reason)"
        [ -n "$reason" ] && dim "swap не трогаем: $reason"
    fi

    if [ -n "$PLAN_LOGROTATE" ]; then
        ok "ротация логов Xray → $LOGROTATE_FILE (copytruncate)"
        dim "файлы:$( printf ' %s' $PLAN_LOGROTATE )"
    fi

    [ "$PLAN_SYSCTL" = "1" ] && \
        ok "сетевые параметры ядра → $SYSCTL_FILE"

    if [ "$PLAN_STEPS" -eq 0 ]; then
        say ""; ok "Всё уже настроено, менять нечего."; say ""
        return 1
    fi

    hdr "Как это применяется"
    if [ "$TG_MODE" = "docker" ]; then
        dim "$TG_BASEFILE не меняется. Все настройки уходят в отдельный файл:"
        dim "  $TG_OVERRIDE"
        dim "Пересоздаётся только сервис $TG_SERVICE (up -d --no-deps) — перерыв 2–5 секунд."
    else
        dim "Вендорный юнит не меняется. Настройки уходят в drop-in:"
        dim "  /etc/systemd/system/$TG_UNIT.d/$DROPIN_NAME"
        dim "Сервис будет перезапущен — перерыв 1–3 секунды."
    fi
    dim "Бэкап и манифест отката: $BACKUP_ROOT/<метка времени>/"
    say ""
    return 0
}

cmd_plan() {
    detect_host
    detect_target || die_no_target
    resolve_compose_paths
    panel_guard
    read_current_state
    build_plan

    hdr "Цель"
    info "$TG_LABEL"
    if [ "$TG_MODE" = "docker" ]; then
        info "контейнер $TG_CONTAINER, сервис $TG_SERVICE, каталог $TG_WORKDIR"
    else
        info "юнит $TG_UNIT"
    fi
    info "RAM хоста $(fmt_mib "$HOST_RAM_MIB"), cgroup v$HOST_CGROUP"
    info "Режим: $(mode_label)"

    render_plan || return 0
    if ! mem_sanity_check; then
        dim "apply откажется применять такой лимит без --force."
        say ""
    fi
    printf '%sНичего не изменено.%s Применить:  %s%s apply%s\n\n' "$CD" "$CN" "$CW" "$PROG" "$CN"
}

# ═══════════════════════════ бэкап и манифест ═══════════════════════════════

about_set() { printf '%s=%s\n' "$1" "$2" >> "$BACKUP_DIR/about.txt"; }
about_get() {
    awk -F= -v k="$1" '$1==k{sub(/^[^=]*=/,""); print; exit}' "$2/about.txt" 2>/dev/null || true
}

backup_init() {
    # $$ в имени: два apply в одну секунду не должны делить каталог и затирать
    # манифест друг друга
    BACKUP_DIR="$BACKUP_ROOT/$(date -u +%Y%m%d-%H%M%S)-$$"
    mkdir -p "$BACKUP_DIR/files"
    MANIFEST="$BACKUP_DIR/manifest.tsv"
    : > "$MANIFEST"
    : > "$BACKUP_DIR/about.txt"
    about_set version   "$VERSION"
    about_set host      "$(hostname 2>/dev/null || echo '?')"
    about_set mode      "$TG_MODE"
    about_set kind      "$TG_KIND"
    about_set container "${TG_CONTAINER:-}"
    about_set service   "${TG_SERVICE:-}"
    about_set project   "${TG_PROJECT:-}"
    about_set workdir   "${TG_WORKDIR:-}"
    about_set configs   "${TG_CONFIGS:-}"
    about_set unit      "${TG_UNIT:-}"
    ln -sfn "$BACKUP_DIR" "$BACKUP_ROOT/latest"
}

# record <kind> <path>
#   newfile   — файла не было, откат его удалит
#   savedfile — файл был, откат вернёт сохранённую копию
#   copy      — копия только для справки, откат её НЕ восстанавливает
#   sysctl    — файл с прежними значениями ядра, откат применит его обратно
#   swapfile  — откат сделает swapoff (если это безопасно) и удалит файл
#   fstab     — служебная отметка, чинится записью savedfile для /etc/fstab
record() {
    local kind="$1" path="$2" saved=""
    if [ "$kind" = "savedfile" ] || [ "$kind" = "copy" ]; then
        saved="$(printf '%s' "$path" | tr '/' '_')"
        cp -a "$path" "$BACKUP_DIR/files/$saved"
    fi
    printf '%s\t%s\t%s\n' "$kind" "$path" "$saved" >> "$MANIFEST"
}

save_or_new() {
    local path="$1"
    if [ ! -e "$path" ]; then record newfile "$path"; return 0; fi
    # Файл с нашим маркером остался от прошлого прогона. Возвращать ЕГО на откате
    # неправильно: пользователь ждёт состояния до HUBTune, а не до прошлого
    # apply. Поэтому помечаем как newfile — откат его удалит.
    if grep -q "$MARKER" "$path" 2>/dev/null; then
        record newfile "$path"
    else
        record savedfile "$path"
    fi
    return 0
}

APPLY_STARTED=0
on_error() {
    local rc=$?
    trap - ERR
    printf '\n%s✗ Ошибка (код %s).%s\n' "$CR" "$rc" "$CN" >&2
    if [ "$APPLY_STARTED" = "1" ] && [ -n "$BACKUP_DIR" ]; then
        APPLY_STARTED=0
        warn "Откатываю изменения из $BACKUP_DIR ..."
        rollback_from "$BACKUP_DIR" || warn "Автооткат не удался, откати вручную: $PROG rollback"
    fi
    exit "$rc"
}

# ══════════════════════════════ docker compose ══════════════════════════════

# Проект может быть собран из нескольких файлов (-f base -f prod). Взять только
# первый и пересоздать контейнер — значит молча выкинуть половину конфигурации.
dc() {
    local -a args
    local f
    args=(compose)
    if [ -n "$TG_PROJECT" ]; then args+=(-p "$TG_PROJECT"); fi
    args+=(--project-directory "$TG_WORKDIR")
    while IFS= read -r f; do
        if [ -n "$f" ] && [ -f "$f" ]; then args+=(-f "$f"); fi
    done < <(printf '%s' "${TG_CONFIGS:-$TG_BASEFILE}" | tr ',' '\n')
    if [ -f "$TG_OVERRIDE" ]; then args+=(-f "$TG_OVERRIDE"); fi
    docker "${args[@]}" "$@"
}

write_override() {
    local mem="" tmp
    [ "$PLAN_MEM_MIB" -gt 0 ] && mem="${PLAN_MEM_MIB}m"
    tmp="$(mktemp)"
    {
        printf '# %s %s\n' "$MARKER" "$VERSION"
        printf '# Сгенерировано %s. Файлом целиком управляет HUBTune.\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf '# Базовый %s НЕ изменялся.\n' "$(basename "$TG_BASEFILE")"
        printf '# Откат:  %s rollback   (или просто удалить этот файл и сделать docker compose up -d)\n' "$PROG"
        printf 'services:\n'
        printf '  %s:\n' "$TG_SERVICE"
        if [ -n "$mem" ]; then
            printf '    mem_limit: %s\n' "$mem"
            [ "$PLAN_MEMSW" = "1" ] && printf '    memswap_limit: %s\n' "$mem"
        elif [ "$CUR_MEM_LIMIT" -gt 0 ] 2>/dev/null; then
            printf '    mem_limit: %s\n' "$(( CUR_MEM_LIMIT / 1048576 ))m"
            [ "$PLAN_MEMSW" = "1" ] && printf '    memswap_limit: %s\n' "$(( CUR_MEM_LIMIT / 1048576 ))m"
        fi
        if [ "$PLAN_LOGS" = "1" ]; then
            printf '    logging:\n'
            printf '      driver: json-file\n'
            printf '      options:\n'
            printf '        max-size: "%s"\n' "$LOG_MAX_SIZE"
            printf '        max-file: "%s"\n' "$LOG_MAX_FILE"
        fi
        if [ "$PLAN_NOFILE" = "1" ]; then
            printf '    ulimits:\n'
            printf '      nofile:\n'
            printf '        soft: %s\n' "$NOFILE"
            printf '        hard: %s\n' "$NOFILE"
        fi
        [ "$PLAN_RESTART" = "1" ] && printf '    restart: always\n'
    } > "$tmp"
    install -m 0644 "$tmp" "$TG_OVERRIDE"
    rm -f "$tmp"
}

check_image_drift() {
    local tagged current
    current="$(docker inspect --format '{{.Image}}' "$TG_CONTAINER" 2>/dev/null || true)"
    tagged="$(docker image inspect --format '{{.Id}}' "$TG_IMAGE" 2>/dev/null || true)"
    if [ -n "$tagged" ] && [ -n "$current" ] && [ "$tagged" != "$current" ]; then
        warn "Локальный образ $TG_IMAGE новее того, на котором работает контейнер."
        dim  "  сейчас:  ${current:0:19}"
        dim  "  станет:  ${tagged:0:19}"
        dim  "  docker compose up -d поднимет ноду уже на новом образе."
        confirm "Всё равно продолжить пересоздание контейнера?" \
            || die "Отменено. Сначала разберись с версией образа."
    fi
}

service_has_changes() {
    [ "$PLAN_MEM_MIB" -gt 0 ] && return 0
    [ "$PLAN_LOGS"    = "1" ] && return 0
    [ "$PLAN_NOFILE"  = "1" ] && return 0
    [ "$PLAN_RESTART" = "1" ] && return 0
    return 1
}

apply_docker() {
    if ! service_has_changes; then
        dim "по контейнеру менять нечего — compose не трогаю"
        return 0
    fi
    if [ -f "$TG_OVERRIDE" ] && ! grep -q "$MARKER" "$TG_OVERRIDE" 2>/dev/null; then
        if [ "$FORCE" != "1" ]; then
            die "В проекте уже есть свой $(basename "$TG_OVERRIDE") — не мой.
   Перезаписывать чужой файл без спроса не буду.
   Перенеси нужное вручную и повтори с --force (старый файл уйдёт в бэкап)."
        fi
        warn "Перезаписываю чужой $(basename "$TG_OVERRIDE") (копия — в бэкапе)."
    fi

    # Базовый compose мы не меняем, копия — только чтобы было с чем сравнить.
    # Восстанавливать его на откате НЕЛЬЗЯ: между apply и rollback ноду могли
    # обновить, и мы бы откатили заодно и обновление.
    record copy "$TG_BASEFILE"
    save_or_new "$TG_OVERRIDE"

    write_override
    ok "записан $TG_OVERRIDE"

    if compose_ready; then
        dc config -q >/dev/null 2>&1 \
            || { dc config 2>&1 | tail -20; die "compose не принял конфигурацию — откатываюсь."; }
        ok "конфигурация compose валидна"
    else
        warn "docker compose v2 недоступен — файл записан, но контейнер не пересоздан."
        return 0
    fi

    check_image_drift
    info "пересоздаю контейнер..."
    # именно --no-deps и только свой сервис: иначе поднимутся соседи, которые
    # админ намеренно остановил, и накатятся чужие правки базового compose
    dc up -d --no-deps "$TG_SERVICE"
    sleep 2

    local got want
    got="$(docker inspect --format '{{.HostConfig.Memory}}' "$TG_CONTAINER" 2>/dev/null || echo 0)"
    if [ "$PLAN_MEM_MIB" -gt 0 ]; then
        want=$(( PLAN_MEM_MIB * 1048576 ))
        if [ "$got" = "$want" ]; then
            ok "лимит применён: $(fmt_bytes "$got")"
        else
            die "Лимит не применился (ожидал $want, в контейнере $got)."
        fi
    fi
    if [ "$(docker inspect --format '{{.State.Running}}' "$TG_CONTAINER" 2>/dev/null)" != "true" ]; then
        die "Контейнер не поднялся. Логи: docker logs --tail 50 $TG_CONTAINER"
    fi
    ok "контейнер $TG_CONTAINER работает"
}

# ═══════════════════════════════ systemd drop-in ════════════════════════════

apply_systemd() {
    local dir="/etc/systemd/system/$TG_UNIT.d" file tmp memkey
    if ! service_has_changes; then
        dim "по юниту менять нечего — drop-in не создаю"
        return 0
    fi
    file="$dir/$DROPIN_NAME"
    mkdir -p "$dir"
    save_or_new "$file"

    if [ "$HOST_CGROUP" = "2" ]; then memkey="MemoryMax"; else memkey="MemoryLimit"; fi

    tmp="$(mktemp)"
    {
        printf '# %s %s\n' "$MARKER" "$VERSION"
        printf '# drop-in к %s. Вендорный юнит не изменялся.\n' "$TG_UNIT"
        printf '# Откат: %s rollback\n' "$PROG"
        printf '[Service]\n'
        if [ "$PLAN_MEM_MIB" -gt 0 ]; then
            printf '%s=%sM\n' "$memkey" "$PLAN_MEM_MIB"
            [ "$HOST_CGROUP" = "2" ] && [ "$HOST_SWAPACCT" = "1" ] && printf 'MemorySwapMax=0\n'
        fi
        [ "$PLAN_NOFILE" = "1" ] && printf 'LimitNOFILE=%s\n' "$NOFILE"
        if [ "$PLAN_RESTART" = "1" ]; then
            printf 'Restart=always\n'
            printf 'RestartSec=5\n'
        fi
    } > "$tmp"
    install -m 0644 "$tmp" "$file"
    rm -f "$tmp"
    ok "записан $file"

    systemctl daemon-reload
    # Раньше этот файл писался всегда — то есть менял глобальные лимиты всех
    # пользователей, даже когда с nofile всё было в порядке, и не показывался
    # в плане. Теперь только если nofile реально поднимаем.
    if [ "$PLAN_NOFILE" = "1" ] && [ "$DO_LIMITSD" = "1" ]; then
        save_or_new "$LIMITS_FILE"
        tmp="$(mktemp)"
        {
            printf '# %s %s\n' "$MARKER" "$VERSION"
            printf '*    soft nofile %s\n*    hard nofile %s\n' "$NOFILE" "$NOFILE"
            printf 'root soft nofile %s\nroot hard nofile %s\n' "$NOFILE" "$NOFILE"
        } > "$tmp"
        install -m 0644 "$tmp" "$LIMITS_FILE"
        rm -f "$tmp"
        ok "записан $LIMITS_FILE"
    fi

    info "перезапускаю $TG_UNIT ..."
    systemctl restart "$TG_UNIT"
    sleep 2
    systemctl is-active --quiet "$TG_UNIT" \
        || die "$TG_UNIT не поднялся. Логи: journalctl -u $TG_UNIT -n 50 --no-pager"

    if [ "$PLAN_MEM_MIB" -gt 0 ]; then
        local got; got="$(systemctl show -p "$memkey" --value "$TG_UNIT" 2>/dev/null || echo 0)"
        ok "$memkey применён: $(fmt_bytes "${got:-0}")"
    fi
    ok "$TG_UNIT работает"

    # x-ui.service приезжает со StartLimitBurst=10 / StartLimitIntervalSec=180:
    # если сервис начнёт падать по памяти чаще, systemd просто перестанет его поднимать.
    local burst interval
    burst="$(systemctl show -p StartLimitBurst --value "$TG_UNIT" 2>/dev/null || echo 0)"
    interval="$(systemctl show -p StartLimitIntervalUSec --value "$TG_UNIT" 2>/dev/null || echo 0)"
    if [ "${burst:-0}" -gt 0 ] 2>/dev/null && [ "${interval:-0}" != "0" ]; then
        warn "у юнита StartLimitBurst=$burst за $interval: при частых падениях systemd"
        dim  "  перестанет его поднимать. Снять запрет: systemctl reset-failed $TG_UNIT"
    fi
}

# ══════════════════════════════════ swap ════════════════════════════════════

apply_swap() {
    local mb="$PLAN_SWAP_MIB"
    [ "$mb" -gt 0 ] || return 0
    [ -e "$SWAPFILE" ] && { warn "$SWAPFILE уже существует — пропускаю."; return 0; }

    info "создаю swap-файл $(fmt_mib "$mb") ..."
    # Записываем в манифест СРАЗУ после создания файла: если упадёт mkswap или
    # swapon, откат должен знать, что на диске лежит гигабайт мусора.
    if ! fallocate -l "${mb}M" "$SWAPFILE" 2>/dev/null; then
        dd if=/dev/zero of="$SWAPFILE" bs=1M count="$mb" status=none
    fi
    record swapfile "$SWAPFILE"
    chmod 600 "$SWAPFILE"
    mkswap "$SWAPFILE" >/dev/null
    swapon "$SWAPFILE"

    if ! grep -qF "$SWAPFILE" "$FSTAB_FILE" 2>/dev/null; then
        record savedfile "$FSTAB_FILE"
        printf '%s none swap sw 0 0  # %s\n' "$SWAPFILE" "$MARKER" >> "$FSTAB_FILE"
    fi
    ok "swap включён: $(fmt_mib "$mb") (и добавлен в /etc/fstab)"
}

# ════════════════════════════════ logrotate ═════════════════════════════════

apply_logrotate() {
    [ -n "$PLAN_LOGROTATE" ] || return 0
    save_or_new "$LOGROTATE_FILE"
    {
        printf '# %s %s\n' "$MARKER" "$VERSION"
        printf '%s {\n' "$PLAN_LOGROTATE"
        printf '    daily\n    rotate 3\n    size 20M\n    missingok\n    notifempty\n'
        printf '    compress\n    delaycompress\n'
        printf '    # Xray держит файл открытым и не переоткрывает его по сигналу,\n'
        printf '    # поэтому только copytruncate — иначе запись уйдёт в никуда.\n'
        printf '    copytruncate\n'
        printf '}\n'
    } > "$LOGROTATE_FILE"
    chmod 0644 "$LOGROTATE_FILE"
    if have logrotate; then
        logrotate -d "$LOGROTATE_FILE" >/dev/null 2>&1 \
            || warn "logrotate не принял конфигурацию — проверь $LOGROTATE_FILE"
    else
        warn "logrotate в системе не установлен — файл записан, но работать не будет"
    fi
    ok "записан $LOGROTATE_FILE"
}

# ═════════════════════════════════ sysctl ═══════════════════════════════════

apply_sysctl() {
    [ "$PLAN_SYSCTL" = "1" ] || return 0

    # Удалить файл из sysctl.d недостаточно: значения остаются в ядре до ребута.
    # Поэтому запоминаем, что было, и откат вернёт их поимённо.
    local before="$BACKUP_DIR/sysctl-before.conf" key val
    : > "$before"
    while IFS= read -r key; do
        [ -n "$key" ] || continue
        val="$(sysctl -n "$key" 2>/dev/null || true)"
        [ -n "$val" ] && printf '%s = %s\n' "$key" "$val" >> "$before"
    done < <(printf '%s\n' "$PLAN_SYSCTL_BODY" | awk -F= '/^[a-z]/{gsub(/[ \t]/,"",$1); print $1}')
    record sysctl "$before"

    save_or_new "$SYSCTL_FILE"
    printf '%s\n' "$PLAN_SYSCTL_BODY" > "$SYSCTL_FILE"
    chmod 0644 "$SYSCTL_FILE"

    local out
    out="$(sysctl -p "$SYSCTL_FILE" 2>&1 || true)"
    if printf '%s' "$out" | grep -qi 'cannot stat\|unknown key\|permission denied'; then
        warn "часть параметров ядро не приняло:"
        printf '%s' "$out" | grep -i 'cannot stat\|unknown key\|permission denied' | sed 's/^/      /'
    fi
    ok "записан $SYSCTL_FILE"
}

# ═════════════════════════════════ apply ════════════════════════════════════

cmd_apply() {
    require_root
    detect_host
    detect_target || die_no_target
    resolve_compose_paths
    panel_guard
    read_current_state
    build_plan

    hdr "Цель"
    info "$TG_LABEL"
    if [ "$TG_MODE" = "docker" ]; then
        info "контейнер $TG_CONTAINER, сервис $TG_SERVICE, каталог $TG_WORKDIR"
    else
        info "юнит $TG_UNIT"
    fi
    info "RAM хоста $(fmt_mib "$HOST_RAM_MIB"), cgroup v$HOST_CGROUP"
    info "Режим: $(mode_label)"

    render_plan || return 0
    if ! mem_sanity_check; then
        [ "$FORCE" = "1" ] \
            || die "Отменено ради ноды. Если это осознанное решение — повтори с --force."
        warn "--force: применяю лимит ниже потребления под твою ответственность."
    fi
    confirm "Применить?" || { say ""; dim "Отменено, ничего не изменено."; say ""; return 0; }

    backup_init
    trap on_error ERR
    APPLY_STARTED=1
    hdr "Применение"

    apply_swap
    apply_sysctl
    apply_logrotate
    case "$TG_MODE" in
        docker)  apply_docker ;;
        systemd) apply_systemd ;;
    esac

    trap - ERR
    APPLY_STARTED=0

    hdr "Готово"
    ok "бэкап и манифест отката: $BACKUP_DIR"
    dim "полный откат одной командой:  $PROG rollback"
    dim "проверить результат:          $PROG status"
    say ""
}

# ════════════════════════════════ rollback ══════════════════════════════════

# Выключать swap опасно ровно тогда, когда откат и происходит: ядро втянет
# выгруженные страницы обратно в RAM и может убить ноду по OOM.
swapoff_is_safe() {
    local used avail
    used="$(awk '/^SwapTotal:/{t=$2} /^SwapFree:/{f=$2} END{print t-f}' /proc/meminfo 2>/dev/null || echo 0)"
    avail="$(awk '/^MemAvailable:/{print $2}' /proc/meminfo 2>/dev/null || echo 0)"
    case "$used$avail" in ''|*[!0-9]*) return 1 ;; esac
    [ "$used" -eq 0 ] && return 0          # своп пуст — выключать нечего
    [ "$avail" -gt 0 ] || return 1         # не смогли прочитать — не рискуем
    [ "$used" -lt $(( avail * 80 / 100 )) ]
}

fstab_drop_marker() {
    local path="$1" tmp
    grep -qF "$MARKER" "$FSTAB_FILE" 2>/dev/null || return 0
    tmp="$(mktemp)"
    awk -v m="$MARKER" -v p="$path" '!(index($0,m) && index($0,p))' "$FSTAB_FILE" > "$tmp" \
        && cat "$tmp" > "$FSTAB_FILE" && info "убрана строка из $FSTAB_FILE"
    rm -f "$tmp"
    return 0
}

# Поднять сервис в исходном виде. Все данные берём из about.txt, а не из живого
# контейнера: к моменту отката его может уже не существовать.
restore_service() {
    local dir="$1" mode svc proj wd cfgs unit f
    mode="$(about_get mode "$dir")"
    case "$mode" in
        docker)
            have docker || { warn "docker недоступен — подними сервис вручную"; return 0; }
            svc="$(about_get service "$dir")";  proj="$(about_get project "$dir")"
            wd="$(about_get workdir "$dir")";   cfgs="$(about_get configs "$dir")"
            if [ -z "$wd" ] || [ ! -d "$wd" ]; then
                warn "каталог проекта не найден — подними вручную: docker compose up -d"
                return 0
            fi
            local -a up; up=(compose)
            if [ -n "$proj" ]; then up+=(-p "$proj"); fi
            up+=(--project-directory "$wd")
            while IFS= read -r f; do
                if [ -n "$f" ] && [ -f "$f" ]; then up+=(-f "$f"); fi
            done < <(printf '%s' "$cfgs" | tr ',' '\n')
            if [ -n "$svc" ]; then up+=(up -d --no-deps "$svc"); else up+=(up -d); fi
            if docker "${up[@]}"; then ok "сервис поднят из исходной конфигурации"
            else warn "поднять сервис не удалось — смотри docker compose logs"; fi ;;
        systemd)
            unit="$(about_get unit "$dir")"
            [ -n "$unit" ] || return 0
            # daemon-reload обязателен: без него systemd поднимет юнит из кэша
            # с уже удалённым, но всё ещё «действующим» drop-in
            systemctl daemon-reload || true
            if systemctl restart "$unit"; then ok "$unit перезапущен"
            else warn "$unit не поднялся — journalctl -u $unit -n 50"; fi ;;
    esac
    return 0
}

# tac есть не в каждой системе (busybox, спасательные образы). Если бы его не
# было, цикл отката получил бы пустой вход и молча отрапортовал успех.
manifest_reversed() {
    awk '!/^#/ && NF { a[++n]=$0 } END { for (i=n; i>0; i--) print a[i] }' "$1" 2>/dev/null || true
}

rollback_from() {
    local dir="$1" kind path saved n=0 bad=0
    [ -f "$dir/manifest.tsv" ] || { warn "Нет манифеста в $dir"; return 1; }

    # Идём в обратном порядке и НЕ падаем на первой ошибке: недоделанный откат
    # хуже, чем откат с жалобами.
    while IFS=$'\t' read -r kind path saved; do
        [ -z "$kind" ] && continue
        case "$kind" in
            newfile)
                if [ -e "$path" ]; then
                    if rm -f "$path"; then info "удалён $path"; n=$(( n + 1 ))
                    else warn "не удалось удалить $path"; bad=$(( bad + 1 )); fi
                fi ;;
            copy)
                : ;;   # справочная копия, восстанавливать нечего
            savedfile)
                if [ -f "$dir/files/$saved" ]; then
                    if cp -a "$dir/files/$saved" "$path"; then
                        info "восстановлен $path"; n=$(( n + 1 ))
                    else warn "не удалось восстановить $path"; bad=$(( bad + 1 )); fi
                else
                    warn "нет копии для $path в бэкапе — оставляю как есть"; bad=$(( bad + 1 ))
                fi ;;
            sysctl)
                if [ -f "$path" ]; then
                    sysctl -p "$path" >/dev/null 2>&1 || true
                    info "значения sysctl возвращены из $path"; n=$(( n + 1 ))
                fi ;;
            swapfile)
                if swapoff_is_safe; then
                    swapoff "$path" 2>/dev/null || true
                    rm -f "$path" || true
                    info "swap выключен и удалён: $path"; n=$(( n + 1 ))
                else
                    warn "swap занят больше, чем влезет в свободную RAM — не выключаю,"
                    dim  "  иначе ядро убьёт ноду. Файл $path останется до перезагрузки."
                    bad=$(( bad + 1 ))
                fi
                fstab_drop_marker "$path" ;;
            fstab)
                : ;;   # снимается в ветке swapfile через fstab_drop_marker
        esac
    done < <(manifest_reversed "$dir/manifest.tsv")

    restore_service "$dir"

    if [ "$bad" -gt 0 ]; then
        warn "откат прошёл не полностью: $n шагов вернулось, $bad с проблемами"
        return 1
    fi
    return 0
}

cmd_rollback() {
    require_root
    local dir="${OPT_TARGET:-}"
    if [ -n "$dir" ] && [ -d "$dir" ]; then :; else dir="$BACKUP_ROOT/latest"; fi
    [ -d "$dir" ] || die "Бэкапов не найдено в $BACKUP_ROOT — откатывать нечего."

    detect_host
    hdr "Откат"
    info "из $(readlink -f "$dir")"
    [ -f "$dir/about.txt" ] && sed 's/^/  /' "$dir/about.txt"

    confirm "Откатить все изменения из этого бэкапа?" || { dim "Отменено."; return 0; }

    if rollback_from "$dir"; then
        say ""; ok "Откат завершён."; say ""
    else
        say ""; warn "Откат завершён с замечаниями — смотри строки выше."; say ""
        return 1
    fi
}

# ═══════════════════════════════════ меню ═══════════════════════════════════

# Запуск без аргументов в терминале: короткая сводка и четыре пункта.
# В пайпе, cron и по ssh с командой меню не показывается — там остаётся plan.
cmd_menu() {
    # menu можно позвать и явно — тогда терминала может не оказаться
    if [ ! -r /dev/tty ]; then
        warn "Терминала нет — показываю план вместо меню."
        cmd_plan
        return 0
    fi
    detect_host
    detect_target || die_no_target
    resolve_compose_paths
    read_current_state

    hdr "HUBTune $VERSION"
    info "$TG_LABEL"
    if [ "$TG_MODE" = "docker" ]; then
        info "контейнер $TG_CONTAINER ($CUR_STATUS, перезапусков: $CUR_RESTARTS)"
    else
        info "юнит $TG_UNIT ($CUR_STATUS)"
    fi
    if [ "$HOST_SWAP_MIB" -gt 0 ]; then
        info "RAM $(fmt_mib "$HOST_RAM_MIB"), swap $(fmt_mib "$HOST_SWAP_MIB")"
    else
        info "RAM $(fmt_mib "$HOST_RAM_MIB"), swap отсутствует"
    fi
    if [ "${CUR_MEM_LIMIT:-0}" -gt 0 ] 2>/dev/null; then
        info "лимит памяти $(fmt_bytes "$CUR_MEM_LIMIT")"
    else
        bad "лимит памяти не задан"
    fi
    if [ "${CUR_OOM_KILLS:-0}" -gt 0 ] 2>/dev/null && [ "$HOST_CGROUP" = "2" ]; then
        bad "сервис уже убивали по памяти: $CUR_OOM_KILLS раз"
    fi
    if [ "$TG_MODE" = "docker" ] && [ "$CUR_LOG_DRIVER" = "json-file" ] && [ "$CUR_LOG_ROTATED" = "0" ]; then
        bad "ротация логов не настроена"
    fi
    [ "$(id -u)" = "0" ] || warn "запущено не от root — менять что-либо не выйдет, нужен sudo"

    say ""
    printf '  %s1%s) Безопасно   лимит памяти, ротация логов, дескрипторы.
' "$CW" "$CN"
    printf '                  %sТрогаем только сам сервис, хост не задеваем.%s
' "$CD" "$CN"
    printf '  %s2%s) Полностью   то же плюс swap, сетевые sysctl и BBR.
' "$CW" "$CN"
    printf '                  %sМеняет настройки хоста — смотри план перед подтверждением.%s
' "$CD" "$CN"
    printf '  %s3%s) Посмотреть  подробный отчёт, ничего не менять.
' "$CW" "$CN"
    printf '  %s4%s) Откатить    вернуть то, что сделал прошлый запуск.
' "$CW" "$CN"
    printf '  %s0%s) Выход
' "$CW" "$CN"
    printf '
Номер: '

    local choice=""
    read -r choice < /dev/tty || choice="0"
    say ""
    case "$choice" in
        1) MODE="safe"; apply_mode; CMD="apply";    cmd_apply ;;
        2) MODE="full"; apply_mode; CMD="apply";    cmd_apply ;;
        3) CMD="status";   cmd_status ;;
        4) CMD="rollback"; cmd_rollback ;;
        0|"") dim "Выход."; say "" ;;
        *) die "Не понял «$choice». Ожидались 0-4." ;;
    esac
    return 0
}

# ══════════════════════════════════ CLI ═════════════════════════════════════

usage() {
cat <<USAGE
HUBTune $VERSION — защита VPN-ноды от OOM, разрастания логов и нехватки дескрипторов.

  $PROG                       без аргументов в терминале — меню из четырёх пунктов
  $PROG <команда> [опции]

Команды
  menu                меню (по умолчанию, если запущено в терминале без аргументов)
  status              показать состояние: лимиты, OOM-счётчик, пик памяти, логи, nofile
  plan                показать, что будет изменено (по умолчанию в скриптах и пайпах)
  apply               применить
  rollback            откатить последний apply
  version             версия
  help                эта справка

Режимы  (--mode или короткие --safe / --full / --memory)
  safe    по умолчанию. Лимит памяти, ротация логов, дескрипторы, автоперезапуск.
          Меняет только сам сервис: override-файл рядом с compose либо drop-in.
  full    то же плюс swap-файл, сетевые sysctl и BBR — то есть настройки хоста.
  memory  только граница по памяти, больше ничего.

Что настраивается
  · лимит памяти сервиса   → docker mem_limit  либо systemd MemoryMax
  · ротация логов Docker   → json-file, max-size × max-file
  · nofile                 → ulimits в compose либо LimitNOFILE в юните
  · политика перезапуска   → always, если её не было
  · swap-файл              → только если RAM <= $(fmt_mib "$SWAP_TRIGGER_MIB") и swap отсутствует
  · сетевые sysctl + BBR   → отдельный файл в /etc/sysctl.d

Опции
  --mode NAME         safe (по умолчанию) | full | memory
  --safe --full --memory   то же короче
  --target NAME       имя контейнера, ключевое слово (remnanode | 3x-ui | marzban)
                      или юнит вида x-ui.service. По умолчанию — автоопределение
  --mem-limit SIZE    лимит вручную: 768m, 1g, 1536m
  --reserve SIZE      сколько оставить системе; лимит = RAM - SIZE
  --reserve-pct N     доля RAM для системы в процентах (по умолчанию $RESERVE_PCT)
  --log-size SIZE     размер одного файла лога (по умолчанию $LOG_MAX_SIZE)
  --log-files N       сколько файлов хранить (по умолчанию $LOG_MAX_FILE)
  --nofile N          значение nofile (по умолчанию $NOFILE)
  --no-mem            не трогать лимит памяти
  --no-logs           не трогать логи
  --no-ulimit         не трогать nofile
  --no-restart        не трогать политику перезапуска
  --no-swap           не создавать swap
  --no-sysctl         не трогать sysctl
  --no-bbr            sysctl настроить, но BBR не включать
  -y, --yes           не спрашивать подтверждений
  --force             разрешить рискованное: чужой override-файл, цель-панель
  --no-color          без цвета

Как считается лимит памяти
  Системе оставляется $RESERVE_PCT% RAM, но не меньше $(fmt_mib "$RESERVE_MIN_MIB") и не больше $(fmt_mib "$RESERVE_MAX_MIB").
  Остальное отдаётся сервису:

      RAM хоста     лимит сервиса    остаётся системе
        512 MiB        320 MiB           192 MiB
          1 GiB        820 MiB           204 MiB
          2 GiB       1.6 GiB            409 MiB
          4 GiB       3.2 GiB            819 MiB
          8 GiB       7.0 GiB              1 GiB
         16 GiB        15 GiB              1 GiB

Примеры
  sudo $PROG                        меню: выбрать пункт и всё
  $PROG status                      что не так прямо сейчас
  $PROG plan --full                 что изменит полный режим
  sudo $PROG apply                  безопасный режим, с подтверждением
  sudo $PROG apply --full -y        полный режим, без вопросов (для раскатки на парк)
  sudo $PROG apply --mem-limit 700m лимит вручную
  sudo $PROG apply --target x-ui.service
  sudo $PROG rollback               вернуть как было

Отдельные --no-* перекрывают режим независимо от порядка:
  sudo $PROG apply --full --no-swap   всё из полного режима, кроме swap
USAGE
}

parse_args() {
    CMD=""
    ARGC=$#
    while [ $# -gt 0 ]; do
        case "$1" in
            status|plan|apply|rollback|version|help|menu) [ -z "$CMD" ] && CMD="$1" ;;
            --target)        [ $# -ge 2 ] || die "Опция --target требует значение."; OPT_TARGET="$2"; shift ;;
            --target=*)     OPT_TARGET="${1#*=}" ;;
            --mem-limit)     [ $# -ge 2 ] || die "Опция --mem-limit требует значение."; OPT_MEM="$2"; shift ;;
            --mem-limit=*)  OPT_MEM="${1#*=}" ;;
            --reserve)       [ $# -ge 2 ] || die "Опция --reserve требует значение."; OPT_RESERVE="$2"; shift ;;
            --reserve=*)    OPT_RESERVE="${1#*=}" ;;
            --reserve-pct)   [ $# -ge 2 ] || die "Опция --reserve-pct требует значение."; RESERVE_PCT="$2"; shift ;;
            --reserve-pct=*) RESERVE_PCT="${1#*=}" ;;
            --log-size)      [ $# -ge 2 ] || die "Опция --log-size требует значение."; LOG_MAX_SIZE="$2"; shift ;;
            --log-size=*)   LOG_MAX_SIZE="${1#*=}" ;;
            --log-files)     [ $# -ge 2 ] || die "Опция --log-files требует значение."; LOG_MAX_FILE="$2"; shift ;;
            --log-files=*)  LOG_MAX_FILE="${1#*=}" ;;
            --nofile)        [ $# -ge 2 ] || die "Опция --nofile требует значение."; NOFILE="$2"; shift ;;
            --nofile=*)     NOFILE="${1#*=}" ;;
            --mode)         [ $# -ge 2 ] || die "Опция --mode требует значение."; MODE="$2"; shift ;;
            --mode=*)       MODE="${1#*=}" ;;
            --safe)         MODE="safe" ;;
            --full)         MODE="full" ;;
            --memory)       MODE="memory" ;;
            --no-mem)       EX_MEM=0 ;;
            --no-logs)      EX_LOGS=0 ;;
            --no-ulimit)    EX_ULIMIT=0 ;;
            --no-restart)   EX_RESTART=0 ;;
            --no-swap)      EX_SWAP=0 ;;
            --no-sysctl)    EX_SYSCTL=0 ;;
            --no-bbr)       EX_BBR=0 ;;
            -y|--yes)       ASSUME_YES=1 ;;
            --force)        FORCE=1 ;;
            --no-color)     CR=''; CG=''; CY=''; CB=''; CD=''; CN=''; CW='' ;;
            -h|--help)      CMD="help" ;;
            -V|--version)   CMD="version" ;;
            *) die "Неизвестный аргумент: $1   (см. $PROG help)" ;;
        esac
        shift
    done
    if [ -z "$CMD" ]; then
        if [ "$ARGC" -eq 0 ] && [ -t 0 ] && [ -t 1 ]; then CMD="menu"; else CMD="plan"; fi
    fi
    return 0
}

validate_opts() {
    is_uint "$RESERVE_PCT" && [ "$RESERVE_PCT" -ge 1 ] && [ "$RESERVE_PCT" -le 90 ] \
        || die "--reserve-pct: нужно целое от 1 до 90, получено «$RESERVE_PCT»."
    is_uint "$LOG_MAX_FILE" && [ "$LOG_MAX_FILE" -ge 1 ] && [ "$LOG_MAX_FILE" -le 100 ] \
        || die "--log-files: нужно целое от 1 до 100, получено «$LOG_MAX_FILE»."
    parse_mib "$LOG_MAX_SIZE" >/dev/null 2>&1 \
        || die "--log-size: нужен размер вида 10m, 50m, 1g; получено «$LOG_MAX_SIZE»."
    is_uint "$NOFILE" || die "--nofile: нужно целое число, получено «$NOFILE»."
    local nr_open=1048576
    if [ -r /proc/sys/fs/nr_open ]; then nr_open="$(cat /proc/sys/fs/nr_open)"; fi
    is_uint "$nr_open" || nr_open=1048576
    [ "$NOFILE" -ge 1024 ] || die "--nofile $NOFILE меньше 1024 — это сломает сервис."
    [ "$NOFILE" -le "$nr_open" ] \
        || die "--nofile $NOFILE больше fs.nr_open ($nr_open): systemd и pam его не примут."
    if [ -n "$OPT_MEM" ]; then
        parse_mib "$OPT_MEM" >/dev/null 2>&1 \
            || die "--mem-limit: не понял «$OPT_MEM». Примеры: 768m, 1g, 1536m"
    fi
    if [ -n "$OPT_RESERVE" ]; then
        parse_mib "$OPT_RESERVE" >/dev/null 2>&1 \
            || die "--reserve: не понял «$OPT_RESERVE». Примеры: 256m, 512m, 1g"
    fi
    return 0
}

main() {
    parse_args "$@"
    validate_opts
    apply_mode

    case "$CMD" in
        help)    usage; exit 0 ;;
        version) printf 'HUBTune %s\n' "$VERSION"; exit 0 ;;
    esac

    [ "$(uname -s)" = "Linux" ] || die "Скрипт рассчитан на Linux-сервер."
    [ -r /proc/meminfo ] || die "Нет доступа к /proc/meminfo."
    case "${BASH_VERSINFO[0]:-0}" in 0|1|2|3) die "Нужен bash 4 или новее." ;; esac

    printf '%s╭─ HUBTune %s%s\n' "$CW" "$VERSION" "$CN"

    case "$CMD" in
        menu)     cmd_menu ;;
        status)   cmd_status ;;
        plan)     cmd_plan ;;
        apply)    cmd_apply ;;
        rollback) cmd_rollback ;;
    esac
}

# позволяет подключить файл как библиотеку в тестах:  HUBTUNE_LIB=1 . hubtune.sh
if [ "${HUBTUNE_LIB:-0}" != "1" ]; then
    main "$@"
fi
