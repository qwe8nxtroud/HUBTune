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
STATE_DIR="/var/lib/hubtune"
FW_DIR="/etc/hubtune"
FW_FILE="/etc/hubtune/firewall.nft"
FW_UNIT="hubtune-firewall.service"
FW_REVERT="hubtune-fw-revert"
FW_TABLE="hubtune"
FW_PENDING="/var/lib/hubtune/firewall-pending"
DROPIN_NAME="10-hubtune.conf"

# ── настройки по умолчанию (переопределяются флагами) ────────────────────────
RESERVE_PCT=20            # сколько процентов RAM оставляем системе
RESERVE_MIN_MIB=192       # но не меньше этого
RESERVE_MAX_MIB=1024      # и не больше этого
LIMIT_FLOOR_MIB=256       # ниже такого лимита Xray просто не живёт
SWAP_TRIGGER_MIB=2048     # при RAM <= этого предлагаем swap
FW_GRACE=300              # секунд до автоотката правил, если не подтвердить
FW_ALLOW_TCP=""           # дополнительные tcp-порты, через запятую
FW_ALLOW_UDP=""           # то же для udp
FW_NODE_PORT=""           # порт связи ноды с панелью (читается из .env)
FW_PANEL_IP=""            # с какого адреса пускать на NODE_PORT
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
FW_CONFIRM=0

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
    # Проверять [ -r /dev/tty ] мало: по ssh без -t файл существует, но не
    # открывается, и редирект падает с «No such device or address».
    if ! { : < /dev/tty; } 2>/dev/null; then
        die "Нужно подтверждение, но управляющего терминала нет.
   Так бывает при ssh без -t, в cron и в пайпе. Перезапусти с --yes."
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

# На свежем VPS списки пакетов часто пустые, и install падает с «Unable to
# locate package» даже для пакета из основного репозитория. Обновляем только
# если кандидата действительно нет: лишний apt-get update на ноде не нужен.
apt_install() {
    have apt-get || return 1
    if ! apt-cache policy "$1" 2>/dev/null | grep -q 'Candidate: [^(]'; then
        apt-get update >/dev/null 2>&1 || true
    fi
    DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" >/dev/null 2>&1
}

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
    # Без этого return функция вернёт код теста выше: диск непустой -> 1 -> set -e
    # убивает скрипт молча. На bash 3.2 не воспроизводится, на 5.1 воспроизводится.
    return 0
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
#   pkg       — установленные нами пакеты; откат делает purge, но никогда
#               не трогает ядро, на котором система работает сейчас
#   nfttable  — наша таблица nft; откат её удаляет, чужие не трогает
#   unit      — созданный нами systemd-юнит; откат выключает и удаляет
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
    local dir="$1" kind path saved n=0 bad=0 pk list running
    running="$(uname -r)"
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
            pkg)
                if have apt-get; then
                    list=""
                    while IFS= read -r pk; do
                        [ -n "$pk" ] || continue
                        # Ядро, на котором система работает прямо сейчас, сносить
                        # нельзя: следующей перезагрузке будет нечем грузиться.
                        case "$pk" in
                            *"$running"*)
                                warn "пропускаю $pk — на этом ядре система работает сейчас"
                                dim  "  чтобы его удалить, сперва загрузись в другое"
                                continue ;;
                        esac
                        list="$list $pk"
                    done <<EOF
$(printf '%s' "$path" | tr ' ' '\n')
EOF
                    if [ -n "$list" ]; then
                        # shellcheck disable=SC2086
                        if DEBIAN_FRONTEND=noninteractive apt-get purge -y $list >/dev/null 2>&1; then
                            info "удалены пакеты:$list"; n=$(( n + 1 ))
                        else
                            warn "не удалось удалить:$list"; bad=$(( bad + 1 ))
                        fi
                    fi
                fi ;;
            nfttable)
                if have nft && nft list table inet "$path" >/dev/null 2>&1; then
                    if nft delete table inet "$path"; then
                        info "снята таблица nft inet $path"; n=$(( n + 1 ))
                    else warn "не снялась таблица nft inet $path"; bad=$(( bad + 1 )); fi
                fi ;;
            unit)
                if have systemctl; then
                    systemctl disable --now "$path" >/dev/null 2>&1 || true
                    rm -f "/etc/systemd/system/$path" || true
                    systemctl daemon-reload >/dev/null 2>&1 || true
                    info "снят юнит $path"; n=$(( n + 1 ))
                fi ;;
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

# ══════════════════════════════ файрвол ═════════════════════════════════════
#
# Три вещи, из-за которых теряют доступ к серверу, и что с ними здесь сделано:
#
#  1. Правила применили и проверили в той же SSH-сессии. Она живёт за счёт
#     `ct state established` и продолжает работать, даже если новые подключения
#     уже дропаются. Поэтому подтверждение принимается ТОЛЬКО из нового
#     соединения — сверяем клиентский порт с записанным при применении.
#  2. Не было плана Б. Здесь до применения правил ставится systemd-таймер,
#     который снесёт нашу таблицу через FW_GRACE секунд. Не подтвердил —
#     доступ вернулся сам. Если таймер зарегистрировать не удалось, правила
#     не применяются вообще.
#  3. Смешали backend. ufw пишет через iptables-совместимость, firewalld — свой
#     менеджер; поверх них наши nft-правила дают «правило есть, а трафик идёт
#     не туда». При активном ufw/firewalld отказываемся работать.
#
# Работаем только в своей таблице `inet hubtune` и не трогаем чужие: у Docker
# свои цепочки, и flush ruleset посреди рабочего дня оторвал бы контейнерам сеть.

fw_available() { have nft; }

fw_conflicting_manager() {
    if systemctl is-active --quiet ufw 2>/dev/null; then printf 'ufw'; return 0; fi
    if systemctl is-active --quiet firewalld 2>/dev/null; then printf 'firewalld'; return 0; fi
    printf ''
}

# Реальные порты sshd: sshd -T учитывает Include и все директивы Port.
fw_ssh_ports() {
    local out=""
    out="$(sshd -T 2>/dev/null | awk '/^port /{print $2}' || true)"
    if [ -z "$out" ]; then
        out="$(ss -tlnpH 2>/dev/null | awk '/sshd/{n=split($4,a,":"); print a[n]}' || true)"
    fi
    [ -z "$out" ] && out="22"
    printf '%s\n' "$out" | sort -un
}

# Адрес и порт того пира, которого реально видит файрвол.
fw_session_peer() {   # печатает: <ip клиента> <порт клиента> <порт сервера>
    local cip="" cport="" sport=""
    if [ -n "${SSH_CONNECTION:-}" ]; then
        read -r cip cport _ sport <<EOF
${SSH_CONNECTION}
EOF
    else
        read -r cip cport <<EOF
$(ss -tnpH state established 2>/dev/null | awk '/sshd/{peer=$5; port=peer; sub(/.*:/,"",port); addr=peer; sub(/:[^:]*$/,"",addr); print addr" "port; exit}' || true)
EOF
    fi
    printf '%s %s %s\n' "${cip:-}" "${cport:-}" "${sport:-}"
    return 0
}

fw_listening_tcp() {
    ss -tlnH 2>/dev/null | awk '{n=split($4,a,":"); print a[n]}' | sort -un || true
}
fw_listening_udp() {
    ss -ulnH 2>/dev/null | awk '{n=split($4,a,":"); print a[n]}' | sort -un || true
}

fw_node_port() {
    local f
    for f in /opt/remnanode/.env /opt/remnawave/node/.env; do
        [ -r "$f" ] || continue
        awk -F= '/^[[:space:]]*(NODE_PORT|APP_PORT)[[:space:]]*=/{gsub(/[^0-9]/,"",$2); if($2!="") print $2; exit}' "$f"
        return 0
    done
    printf ''
}

# Собираем правила. Идиома `table; delete table; table {...}` — атомарная
# замена одной таблицы: create-if-absent, снести, положить новую.
fw_build_ruleset() {   # $1 — файл назначения
    local out="$1" p ssh_ports
    ssh_ports="$(fw_ssh_ports)"
    {
        printf '#!/usr/sbin/nft -f\n'
        printf '# %s %s\n' "$MARKER" "$VERSION"
        printf '# Только своя таблица. Чужие (в том числе Docker) не трогаем.\n'
        printf 'table inet %s\n' "$FW_TABLE"
        printf 'delete table inet %s\n\n' "$FW_TABLE"
        printf 'table inet %s {\n' "$FW_TABLE"
        printf '  chain input {\n'
        printf '    type filter hook input priority 0; policy drop;\n\n'
        printf '    ct state established,related accept\n'
        printf '    ct state invalid drop\n'
        printf '    iif lo accept\n\n'
        printf '    # без icmp сеть ведёт себя необъяснимо: ломается path MTU discovery\n'
        printf '    ip protocol icmp icmp type { echo-request, destination-unreachable, time-exceeded, parameter-problem } accept\n'
        printf '    ip6 nexthdr icmpv6 accept\n\n'
        printf '    # SSH: все порты, на которых слушает sshd\n'
        while IFS= read -r p; do
            [ -n "$p" ] && printf '    tcp dport %s accept\n' "$p"
        done <<EOFP
$ssh_ports
EOFP
        if [ -n "$FW_ALLOW_TCP" ]; then
            printf '\n    # порты сервиса\n'
            while IFS= read -r p; do
                [ -n "$p" ] && printf '    tcp dport %s accept\n' "$p"
            done <<EOFT
$(printf '%s' "$FW_ALLOW_TCP" | tr ', ' '\n\n')
EOFT
        fi
        if [ -n "$FW_ALLOW_UDP" ]; then
            while IFS= read -r p; do
                [ -n "$p" ] && printf '    udp dport %s accept\n' "$p"
            done <<EOFU
$(printf '%s' "$FW_ALLOW_UDP" | tr ', ' '\n\n')
EOFU
        fi
        if [ -n "$FW_NODE_PORT" ]; then
            printf '\n    # порт связи с панелью — только с её адреса\n'
            if [ -n "$FW_PANEL_IP" ]; then
                printf '    ip saddr %s tcp dport %s accept\n' "$FW_PANEL_IP" "$FW_NODE_PORT"
            else
                printf '    tcp dport %s accept\n' "$FW_NODE_PORT"
            fi
        fi
        printf '  }\n'
        printf '  # output и forward не описываем: Reality и VLESS ходят наружу сами,\n'
        printf '  # а закрытый output ломает VPN тихо, в отличие от закрытого input.\n'
        printf '}\n'
    } > "$out"
}
fw_guard() {
    if ! fw_available; then
        have apt-get || die "nft не установлен, и apt-get тоже нет. Поставь nftables вручную."
        warn "nft не установлен — в минимальной Ubuntu его нет из коробки"
        confirm "Поставить пакет nftables?" || die "Без nft правила писать нечем."
        apt_install nftables || die "Не удалось поставить nftables."
        record pkg "nftables"
        fw_available || die "nftables поставился, но команда nft не появилась."
        ok "nftables установлен"
    fi
    have systemd-run || die "нет systemd-run — без него не поставить страховочный таймер,
   а применять правила файрвола на удалённой машине без страховки нельзя."
    local m; m="$(fw_conflicting_manager)"
    if [ -n "$m" ]; then
        die "На сервере активен $m, а он держит правила через свой backend.
   Наши nft-правила поверх него дадут «правило есть, а трафик идёт мимо».
   Выключи его (systemctl disable --now $m) либо настраивай файрвол только им."
    fi
    return 0
}

fw_render_plan() {
    local p peer
    [ -n "$FW_NODE_PORT" ] || FW_NODE_PORT="$(fw_node_port)"

    hdr "Файрвол"
    info "таблица inet $FW_TABLE, политика input drop; output и forward не трогаем"
    say ""
    ok "SSH — все порты, на которых реально слушает sshd:"
    while IFS= read -r p; do
        [ -n "$p" ] && dim "  tcp/$p"
    done <<EOF
$(fw_ssh_ports)
EOF
    peer="$(fw_session_peer)"
    [ -n "${peer%% *}" ] && dim "  текущая сессия с ${peer%% *} — именно этот адрес видит файрвол"

    if [ -n "$FW_NODE_PORT" ]; then
        if [ -n "$FW_PANEL_IP" ]; then
            ok "порт связи с панелью tcp/$FW_NODE_PORT — только с $FW_PANEL_IP"
        else
            ok "порт связи с панелью tcp/$FW_NODE_PORT — со всех адресов"
            dim "  документация Remnawave советует пускать только с IP панели: --panel-ip A.B.C.D"
        fi
    fi
    [ -n "$FW_ALLOW_TCP" ] && ok "дополнительно tcp: $FW_ALLOW_TCP"
    [ -n "$FW_ALLOW_UDP" ] && ok "дополнительно udp: $FW_ALLOW_UDP"

    say ""
    warn "Порты инбаундов Xray задаются в панели, и файрвол о них не знает."
    dim "  сейчас слушают tcp: $(fw_listening_tcp | tr '\n' ' ')"
    dim "  всё, чего нет выше, будет закрыто — добавляй через --allow-tcp"
    say ""
    dim "После применения правила снимутся сами через $FW_GRACE секунд, если не"
    dim "подтвердить их ИЗ НОВОГО ssh-подключения."
    say ""
}

fw_apply() {
    fw_guard
    [ -n "$FW_NODE_PORT" ] || FW_NODE_PORT="$(fw_node_port)"

    local cand; cand="$(mktemp)"
    fw_build_ruleset "$cand"
    if ! nft -c -f "$cand" 2>/dev/null; then
        nft -c -f "$cand" 2>&1 | head -10
        rm -f "$cand"; die "nft не принял правила — ничего не применяю."
    fi
    ok "синтаксис правил проверен"

    mkdir -p "$STATE_DIR"
    nft list ruleset > "$BACKUP_DIR/nft-before.rules" 2>/dev/null || true

    # Страховка ставится ДО правил. Не встала — не применяем вовсе.
    systemctl stop "${FW_REVERT}.timer" "${FW_REVERT}.service" >/dev/null 2>&1 || true
    systemd-run --on-active="$FW_GRACE" --unit="$FW_REVERT" --collect \
        nft delete table inet "$FW_TABLE" >/dev/null 2>&1 || true
    if ! systemctl is-active --quiet "${FW_REVERT}.timer" 2>/dev/null; then
        rm -f "$cand"
        die "Не удалось поставить таймер автоотката. Правила НЕ применены —
   без страховки на машине без консоли это игра в рулетку."
    fi
    ok "страховка поставлена: через $FW_GRACE с правила снимутся сами"

    install -m 0644 "$cand" "$STATE_DIR/firewall.candidate.nft"
    rm -f "$cand"

    if ! nft -f "$STATE_DIR/firewall.candidate.nft"; then
        systemctl stop "${FW_REVERT}.timer" >/dev/null 2>&1 || true
        die "Применить правила не удалось."
    fi
    record nfttable "$FW_TABLE"
    ok "правила применены"

    # Запоминаем клиентский порт этой сессии: подтверждение должно прийти
    # с другого, иначе это та же сессия, которая живёт на established.
    local peer; peer="$(fw_session_peer)"
    { printf 'client_port=%s\n' "$(printf '%s' "$peer" | awk '{print $2}')"
      printf 'backup=%s\n' "$BACKUP_DIR"
    } > "$FW_PENDING"

    say ""
    printf '%s  ─── НЕ ЗАКРЫВАЙ ЭТУ СЕССИЮ ───%s\n' "$CW" "$CN"
    say ""
    dim "Открой ВТОРОЕ ssh-подключение к серверу и выполни там:"
    printf '\n    %ssudo %s firewall confirm%s\n\n' "$CW" "$PROG" "$CN"
    dim "Проверять в этой же сессии бесполезно: она работает по established и"
    dim "продолжит работать, даже если новые подключения уже отбиваются."
    dim "Не подтвердишь за $FW_GRACE секунд — правила снимутся, доступ вернётся."
    say ""
}

fw_persist() {
    mkdir -p "$FW_DIR"
    save_or_new "$FW_FILE"
    install -m 0644 "$STATE_DIR/firewall.candidate.nft" "$FW_FILE"

    local unit="/etc/systemd/system/$FW_UNIT"
    save_or_new "$unit"
    {
        printf '# %s %s\n' "$MARKER" "$VERSION"
        printf '[Unit]\n'
        printf 'Description=HUBTune firewall (nftables, table inet %s)\n' "$FW_TABLE"
        printf '# после штатного nftables.service: если у него в конфиге flush ruleset,\n'
        printf '# он не должен снести нашу таблицу уже после нас\n'
        printf 'After=nftables.service network-pre.target\n'
        printf 'Wants=network-pre.target\n\n'
        printf '[Service]\n'
        printf 'Type=oneshot\n'
        printf 'RemainAfterExit=yes\n'
        printf 'ExecStart=/usr/sbin/nft -f %s\n' "$FW_FILE"
        printf 'ExecStop=/usr/sbin/nft delete table inet %s\n\n' "$FW_TABLE"
        printf '[Install]\n'
        printf 'WantedBy=multi-user.target\n'
    } > "$unit"
    chmod 0644 "$unit"
    systemctl daemon-reload
    systemctl enable "$FW_UNIT" >/dev/null 2>&1 \
        || warn "не удалось включить $FW_UNIT в автозагрузку"
    record unit "$FW_UNIT"
    ok "правила закреплены и переживут перезагрузку: $FW_FILE"
}

cmd_firewall() {
    require_root
    detect_host
    TG_MODE="server"
    fw_render_plan
    confirm "Применить правила файрвола?" || { dim "Отменено."; say ""; return 0; }
    backup_init
    trap on_error ERR
    APPLY_STARTED=1
    fw_apply
    trap - ERR
    APPLY_STARTED=0
    return 0
}

cmd_fw_confirm() {
    require_root
    [ -f "$FW_PENDING" ] \
        || die "Нечего подтверждать: нет правил, ожидающих подтверждения."

    local saved_port cur_port peer
    saved_port="$(awk -F= '$1=="client_port"{print $2; exit}' "$FW_PENDING" 2>/dev/null || true)"
    BACKUP_DIR="$(awk -F= '$1=="backup"{print $2; exit}' "$FW_PENDING" 2>/dev/null || true)"
    MANIFEST="$BACKUP_DIR/manifest.tsv"
    peer="$(fw_session_peer)"
    cur_port="$(printf '%s' "$peer" | awk '{print $2}')"

    if [ -n "$saved_port" ] && [ "$saved_port" = "$cur_port" ]; then
        die "Это та же сессия, из которой правила применялись.
   Она живёт по established и ничего не доказывает. Открой новое подключение."
    fi
    ok "подтверждение пришло из нового подключения"

    systemctl stop "${FW_REVERT}.timer" "${FW_REVERT}.service" >/dev/null 2>&1 || true
    if systemctl is-active --quiet "${FW_REVERT}.timer" 2>/dev/null; then
        die "Таймер автоотката не остановился — не рискую закреплять правила."
    fi
    ok "автооткат отменён"

    fw_persist
    rm -f "$FW_PENDING"
    say ""; ok "Файрвол включён и закреплён."
    dim "снять: $PROG rollback"; say ""
}

# ══════════════════════════ ядро XanMod и BBRv3 ═════════════════════════════
# ══════════════════════════ ядро XanMod (BBRv3) ═════════════════════════════
# shellcheck shell=bash
#
#  Фрагмент для вставки в hubtune.sh. Не самостоятельный скрипт: рассчитан на
#  общий контекст hubtune.sh (set -Eeuo pipefail, root, готовые helper'ы
#  ok/warn/bad/info/dim/die/hdr/say/have/is_uint/confirm/fmt_mib/record/
#  save_or_new/require_root и переменные $MARKER/$VERSION/$PROG/$BACKUP_DIR/
#  $HOST_VIRT/$HOST_DISK_FREE_MIB/$FORCE).
#
#  BBRv3 не входит в mainline: в стоковом ядре есть только BBR v1, ради v3
#  нужно стороннее ядро XanMod. Имя "bbr3" в tcp_available_congestion_control
#  может вообще не появиться — часть сборок v3 использует то же имя "bbr",
#  что и v1/v2, поэтому единственная достоверная проверка — версия модуля
#  tcp_bbr (см. krn_bbr_module_version).
#
#  Порядок вызова: krn_detect → krn_blockers/krn_render_plan → krn_apply.
#  confirm(), backup_init и trap on_error ERR — забота вызывающей стороны,
#  как у hyg_render_plan()/hyg_apply(). Откат "pkg" уже умеет rollback_from()
#  (кейс pkg защищает от удаления кернела, на котором система работает прямо
#  сейчас) — доделывать не нужно. apt-mark hold на старое ядро откатом
#  сознательно не снимается: это постоянная страховка, а не временное
#  состояние apply.

KRN_KEYRING="/etc/apt/keyrings/xanmod-archive-keyring.gpg"
KRN_LIST_FILE="/etc/apt/sources.list.d/xanmod-release.list"
KRN_KEY_URL="https://dl.xanmod.org/archive.key"
KRN_APT_URL="http://deb.xanmod.org"
# у XanMod один общий репозиторий на все Debian/Ubuntu разом, а не codename
# конкретного дистрибутива — "releases" тут ровно то же самое, что codename
# в примере из задания, просто зафиксированное значение, а не lsb_release
KRN_APT_SUITE=""          # кодовое имя дистрибутива; заполняет krn_detect
KRN_BOOT_MIN_MIB=300          # меньше — initramfs не соберётся (известный отказ на Oracle Cloud)

# Заполняет krn_detect(), см. интерфейс ниже.
KRN_VIRT=""                   # результат systemd-detect-virt
KRN_SB="unknown"              # off | on | unknown — состояние Secure Boot
KRN_PSABI=""                  # x64v1..x64v4 — максимальный уровень psABI по флагам CPU
KRN_BOOT_FREE_MIB=0           # свободно в /boot, МиБ
KRN_HAS_GRUB=0                # 1 — есть grub.cfg и update-grub/grub-mkconfig
KRN_CURRENT=""                # uname -r на момент детекта (это ядро остаётся запасным)
KRN_BBR_VER=""                # modinfo tcp_bbr | version; пусто — модуль не найден

# ═══════════════════════════════ разведка ═══════════════════════════════════

# off | on | unknown. mokutil — основной путь; если его нет, читаем EFI-
# переменную напрямую. Секьюрбут не даёт грузиться неподписанному ядру
# XanMod, поэтому "не смогли определить" и "точно выключен" разводим отдельно.
krn_secure_boot_state() {
    local out var_file

    if have mokutil; then
        out="$(mokutil --sb-state 2>/dev/null || true)"
        case "$out" in
            *"SecureBoot enabled"*)  printf 'on';  return 0 ;;
            *"SecureBoot disabled"*) printf 'off'; return 0 ;;
        esac
    fi

    if [ ! -d /sys/firmware/efi ]; then
        # легаси-BIOS: EFI нет вообще, Secure Boot архитектурно невозможен
        printf 'off'
        return 0
    fi

    if have efivar; then
        out="$(efivar -n 8be4df61-93ca-11d2-aa0d-00e098032b8c-SecureBoot -p 2>/dev/null || true)"
        case "$out" in
            *[Ee]nabled*)  printf 'on';  return 0 ;;
            *[Dd]isabled*) printf 'off'; return 0 ;;
        esac
    fi

    # ни mokutil, ни efivar: читаем efivarfs сырьём. Первые 4 байта файла —
    # атрибуты EFI-переменной, пятый байт — само значение SecureBoot (0/1)
    var_file="$(find /sys/firmware/efi/efivars -maxdepth 1 -iname 'SecureBoot-*' 2>/dev/null | head -n1)"
    if [ -n "$var_file" ] && [ -r "$var_file" ]; then
        out="$(od -An -tu1 "$var_file" 2>/dev/null | awk '{print $5}')"
        case "$out" in
            1) printf 'on';  return 0 ;;
            0) printf 'off'; return 0 ;;
        esac
    fi

    printf 'unknown'
    return 1
}

# Флаги CPU из /proc/cpuinfo первого ядра: на VDS/выделенных серверах у всех
# vCPU один и тот же набор, гетерогенные конфигурации сюда не целимся.
krn_cpu_has_flags() {
    local flags="$1" f
    shift
    for f in "$@"; do
        case " $flags " in
            *" $f "*) ;;
            *) return 1 ;;
        esac
    done
    return 0
}

# Максимальный поддерживаемый уровень x86-64 psABI. Неверный уровень —
# illegal instruction прямо при старте ядра, поэтому смотрим факт наличия
# флагов локально, а не модель CPU и не сторонний скрипт из интернета.
krn_psabi_level() {
    local flags
    flags="$(awk -F: '/^flags/{print $2; exit}' /proc/cpuinfo)"

    local v2=(cx16 lahf_lm popcnt sse4_1 sse4_2 ssse3)
    local v3=(avx avx2 bmi1 bmi2 f16c fma movbe xsave)
    local v4=(avx512f avx512bw avx512cd avx512dq avx512vl)

    if krn_cpu_has_flags "$flags" "${v2[@]}" "${v3[@]}" "${v4[@]}"; then
        printf 'x64v4'
    elif krn_cpu_has_flags "$flags" "${v2[@]}" "${v3[@]}"; then
        printf 'x64v3'
    elif krn_cpu_has_flags "$flags" "${v2[@]}"; then
        printf 'x64v2'
    else
        printf 'x64v1'
    fi
}

# Версия модуля tcp_bbr — единственный надёжный признак BBRv3: часть сборок
# v3 называет congestion control в /proc так же, как v1/v2, — просто "bbr".
krn_bbr_module_version() {
    have modinfo || return 0
    modinfo tcp_bbr 2>/dev/null | awk '/^version:/{print $2; exit}'
}

krn_detect() {
    KRN_VIRT="${HOST_VIRT:-unknown}"
    if [ "$KRN_VIRT" = "unknown" ] && have systemd-detect-virt; then
        KRN_VIRT="$(systemd-detect-virt 2>/dev/null || echo none)"
    fi

    KRN_SB="$(krn_secure_boot_state)" || true
    KRN_PSABI="$(krn_psabi_level)"

    KRN_BOOT_FREE_MIB="$(df -Pm /boot 2>/dev/null | awk 'NR==2{print $4}')"
    is_uint "$KRN_BOOT_FREE_MIB" || KRN_BOOT_FREE_MIB="$HOST_DISK_FREE_MIB"

    KRN_HAS_GRUB=0
    if [ -f /boot/grub/grub.cfg ] && { have update-grub || have grub-mkconfig; }; then
        KRN_HAS_GRUB=1
    fi

    KRN_CURRENT="$(uname -r)"
    KRN_BBR_VER="$(krn_bbr_module_version)"
    KRN_APT_SUITE="$(. /etc/os-release 2>/dev/null && printf '%s' "${VERSION_CODENAME:-}")"

    return 0
}

# ═══════════════════════════════ блокеры ════════════════════════════════════

# По строке на каждую причину отказа. Возврат 0 — блокеров нет, 1 — есть.
krn_blockers() {
    local n=0

    if ! have apt-get; then
        bad "нет apt-get — репозиторий XanMod есть только для Debian/Ubuntu-подобных систем"
        n=$(( n + 1 ))
    fi

    case "$KRN_VIRT" in
        openvz|lxc|lxc-libvirt)
            bad "виртуализация $KRN_VIRT — своё ядро физически невозможно, ядро общее с хостом"
            n=$(( n + 1 )) ;;
    esac

    case "$KRN_SB" in
        on)
            bad "Secure Boot включён — ядро XanMod не подписано и не загрузится, выключи Secure Boot в прошивке"
            n=$(( n + 1 )) ;;
        unknown)
            if [ "$FORCE" = "1" ]; then
                warn "состояние Secure Boot не определилось (нет mokutil/efivar) — продолжаю из-за --force"
            else
                bad "состояние Secure Boot не определилось (нет mokutil/efivar) — повтори с --force, если точно знаешь, что он выключен"
                n=$(( n + 1 ))
            fi ;;
    esac

    if [ "$KRN_HAS_GRUB" != "1" ]; then
        bad "не найден GRUB (/boot/grub/grub.cfg и update-grub/grub-mkconfig) — новое ядро некуда прописать"
        n=$(( n + 1 ))
    fi

    if [ "$KRN_BOOT_FREE_MIB" -lt "$KRN_BOOT_MIN_MIB" ] 2>/dev/null; then
        if [ "$FORCE" = "1" ]; then
            warn "в /boot свободно $(fmt_mib "$KRN_BOOT_FREE_MIB") из требуемых $(fmt_mib "$KRN_BOOT_MIN_MIB") — продолжаю из-за --force"
        else
            bad "в /boot свободно $(fmt_mib "$KRN_BOOT_FREE_MIB"), нужно минимум $(fmt_mib "$KRN_BOOT_MIN_MIB") — иначе не соберётся initramfs"
            n=$(( n + 1 ))
        fi
    fi

    if [ -z "$KRN_APT_SUITE" ]; then
        bad "не удалось определить кодовое имя дистрибутива (VERSION_CODENAME)"
        n=$(( n + 1 ))
    elif ! krn_suite_published "$KRN_APT_SUITE"; then
        bad "XanMod не публикует пакеты для «$KRN_APT_SUITE»"
        dim "  каталога $KRN_APT_URL/dists/$KRN_APT_SUITE нет."
        dim "  Поддерживаются свежие выпуски (noble, bookworm, trixie и новее)."
        dim "  Вариантов два: обновить дистрибутив либо остаться на BBR v1,"
        dim "  который включается одним sysctl и уже делается пунктом «Сеть»."
        n=$(( n + 1 ))
    fi

    [ "$n" -eq 0 ]
}

# ═══════════════════════════════════ план ═══════════════════════════════════

# Suite у XanMod — кодовое имя дистрибутива, и публикуют они не для всех.
# Для jammy (Ubuntu 22.04) каталога уже нет. Проверяем ДО того, как трогать
# apt: иначе пользователь получит «does not have a Release file» и гадание.
krn_suite_published() {
    local suite="$1" code=""
    have curl || return 0
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 \
        "$KRN_APT_URL/dists/$suite/InRelease" 2>/dev/null || echo 000)"
    [ "$code" = "200" ]
}

krn_render_plan() {
    local pkg blockers_out
    pkg="linux-xanmod-${KRN_PSABI:-x64v1}"

    hdr "Ядро XanMod (BBRv3)"
    info "сейчас              $KRN_CURRENT"
    case "$KRN_CURRENT" in
        *xanmod*) dim "уже загружено ядро XanMod — переустановка/обновление пакета ничего не сломает" ;;
    esac
    if [ -n "$KRN_BBR_VER" ]; then
        if [ "$KRN_BBR_VER" = "3" ]; then
            info "версия tcp_bbr      $KRN_BBR_VER (это уже BBRv3)"
        else
            info "версия tcp_bbr      $KRN_BBR_VER"
        fi
    else
        info "версия tcp_bbr      модуль не загружен"
    fi
    info "уровень CPU         $KRN_PSABI"
    ok   "пакет к установке: $pkg  (репозиторий deb.xanmod.org)"
    dim  "ключ:    $KRN_KEYRING"
    dim  "список:  $KRN_LIST_FILE"
    ok   "$KRN_CURRENT останется в GRUB как запасной пункт"
    dim  "пакеты текущего ядра получат apt-mark hold — иначе autoremove снесёт"
    dim  "их вместе с запасным вариантом, если новое ядро не загрузится"

    say ""
    if blockers_out="$(krn_blockers)"; then
        dim "Ничего не изменено."
        return 0
    fi
    warn "установка заблокирована:"
    printf '%s\n' "$blockers_out"
    say ""
    return 1
}

# ═══════════════════════════════════ apply ══════════════════════════════════

# Пакеты, которые дают текущее ядро, — их нужно закрепить, чтобы apt
# autoremove (в том числе автоматический, из unattended-upgrades) не снёс
# запасной вариант вместе с только что поставленным новым ядром.
krn_current_kernel_pkgs() {
    dpkg-query -W -f='${Package}\n' 'linux-image-*' 'linux-headers-*' 'linux-modules-*' 2>/dev/null \
        | grep -F -- "$KRN_CURRENT" || true
}

krn_apply() {
    require_root
    krn_detect

    local blockers_out
    if ! blockers_out="$(krn_blockers)"; then
        printf '%s\n' "$blockers_out" >&2
        die "установка ядра XanMod заблокирована, причины выше"
    fi

    local pkg="linux-xanmod-${KRN_PSABI:-x64v1}"
    hdr "Установка ядра XanMod"

    # curl и gpg нужны только для подключения репозитория — на минимальных
    # облачных образах их может не быть по умолчанию
    local need_pkgs=""
    have curl || need_pkgs="curl"
    have gpg  || need_pkgs="${need_pkgs:+$need_pkgs }gnupg"
    if [ -n "$need_pkgs" ]; then
        # shellcheck disable=SC2086
        DEBIAN_FRONTEND=noninteractive apt-get install -y $need_pkgs >/dev/null \
            || die "не поставились зависимости для подключения репозитория: $need_pkgs"
    fi

    mkdir -p "$(dirname "$KRN_KEYRING")"
    local key_tmp; key_tmp="$(mktemp)"
    if ! curl -fsSL "$KRN_KEY_URL" -o "$key_tmp"; then
        rm -f "$key_tmp"
        die "не скачался ключ репозитория: $KRN_KEY_URL"
    fi
    save_or_new "$KRN_KEYRING"
    gpg --batch --yes --dearmor -o "$KRN_KEYRING" "$key_tmp"
    rm -f "$key_tmp"
    chmod 0644 "$KRN_KEYRING"
    ok "ключ репозитория: $KRN_KEYRING"

    save_or_new "$KRN_LIST_FILE"
    {
        printf '# %s %s\n' "$MARKER" "$VERSION"
        printf 'deb [signed-by=%s] %s %s main\n' "$KRN_KEYRING" "$KRN_APT_URL" "$KRN_APT_SUITE"
    } > "$KRN_LIST_FILE"
    chmod 0644 "$KRN_LIST_FILE"
    ok "репозиторий: $KRN_LIST_FILE"

    apt-get update >/dev/null || die "apt-get update не прошёл после добавления репозитория XanMod"

    # У XanMod один общий репозиторий на все Debian и Ubuntu, но какой именно
    # suite он ждёт, проверить отсюда нельзя. Если пакета в «releases» нет,
    # пробуем кодовое имя дистрибутива, а не падаем с невнятной ошибкой apt.
    if ! apt-cache policy "$pkg" 2>/dev/null | grep -q 'Candidate: [^(]'; then
        local codename=""
        codename="$(. /etc/os-release 2>/dev/null && printf '%s' "${VERSION_CODENAME:-}")"
        if [ -n "$codename" ] && [ "$codename" != "$KRN_APT_SUITE" ]; then
            warn "в suite «$KRN_APT_SUITE» пакета $pkg нет, пробую «$codename»"
            printf 'deb [signed-by=%s] %s %s main\n' "$KRN_KEYRING" "$KRN_APT_URL" "$codename" > "$KRN_APT_LIST"
            apt-get update >/dev/null || true
        fi
    fi
    apt-cache policy "$pkg" 2>/dev/null | grep -q 'Candidate: [^(]' \
        || die "Репозиторий XanMod не отдаёт пакет $pkg.
   Проверь https://xanmod.org — формат репозитория мог измениться."
    ok "пакет $pkg доступен в репозитории"

    local hold_pkgs; hold_pkgs="$(krn_current_kernel_pkgs)"
    if [ -n "$hold_pkgs" ]; then
        # shellcheck disable=SC2086
        apt-mark hold $hold_pkgs >/dev/null
        ok "закреплены пакеты текущего ядра (apt-mark hold):"
        dim "  $(printf '%s' "$hold_pkgs" | tr '\n' ' ')"
    else
        warn "не нашёл пакет текущего ядра ($KRN_CURRENT) по имени — hold не поставлен"
        dim  "  после установки проверь вручную: dpkg -l | grep $KRN_CURRENT"
    fi

    if ! dpkg -s "$pkg" >/dev/null 2>&1; then
        if ! DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg" >/dev/null 2>&1; then
            # свежий VPS часто отдаётся с пустым или просроченным кэшем индексов
            apt-get update >/dev/null 2>&1 || true
            DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg" >/dev/null \
                || die "не удалось установить пакет $pkg"
        fi
        record pkg "$pkg"
    fi
    ok "пакет $pkg установлен"

    if ! dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q '^install ok installed$'; then
        die "пакет $pkg установлен не полностью (проверь: dpkg -s $pkg) — не продолжаю"
    fi

    local vmlinuz krelease initrd f
    vmlinuz="$(dpkg-query -L "$pkg" 2>/dev/null | grep -E '^/boot/vmlinuz-' | head -n1)"
    [ -n "$vmlinuz" ] || die "пакет $pkg установлен, но /boot/vmlinuz для него не нашёлся"
    krelease="${vmlinuz#/boot/vmlinuz-}"
    initrd="/boot/initrd.img-$krelease"
    for f in "$vmlinuz" "$initrd"; do
        [ -s "$f" ] || die "файл $f отсутствует или пустой — установка ядра не завершена"
    done

    local vmlinuz_mib initrd_mib
    vmlinuz_mib=$(( $(stat -c%s "$vmlinuz" 2>/dev/null || echo 0) / 1048576 ))
    initrd_mib=$(( $(stat -c%s "$initrd" 2>/dev/null || echo 0) / 1048576 ))
    ok "$(basename "$vmlinuz")  ($(fmt_mib "$vmlinuz_mib"))"
    ok "$(basename "$initrd")  ($(fmt_mib "$initrd_mib"))"

    # postinst kernel-пакета обычно сам вызывает update-grub через
    # /etc/kernel/postinst.d — перевызываем явно, чтобы не зависеть от того,
    # доехал ли этот хук в стороннем репозитории
    if have update-grub; then
        update-grub >/dev/null || die "update-grub не прошёл"
    elif have grub-mkconfig; then
        grub-mkconfig -o /boot/grub/grub.cfg >/dev/null || die "grub-mkconfig не прошёл"
    fi

    grep -qF "$krelease" /boot/grub/grub.cfg \
        || die "новое ядро не появилось в /boot/grub/grub.cfg"
    grep -qF "$KRN_CURRENT" /boot/grub/grub.cfg \
        || die "старое ядро $KRN_CURRENT пропало из /boot/grub/grub.cfg — без запасного варианта не продолжаю"
    ok "новое ядро есть в grub.cfg, $KRN_CURRENT остался запасным пунктом"

    say ""
    hdr "Готово, но перезагрузку делает человек"
    warn "скрипт НЕ перезагружает сервер автоматически и не будет этого делать"
    warn "перед перезагрузкой убедись, что есть доступ к консоли провайдера (VNC/serial/KVM):"
    dim  "известный класс отказа — ядро загружается, но сеть не поднимается"
    dim  "если что-то пойдёт не так — на экране GRUB выбери прежнее ядро: $KRN_CURRENT"
    say ""
    return 0
}

# ══════════════════════════════════ status ══════════════════════════════════

krn_status() {
    local krelease bbr_ver cc
    krelease="$(uname -r)"
    bbr_ver="$(krn_bbr_module_version)"
    cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '?')"

    hdr "Ядро и BBR"
    info "ядро                $krelease"
    if [ -z "$bbr_ver" ]; then
        warn "модуль tcp_bbr не загружен"
    elif [ "$bbr_ver" = "3" ]; then
        ok "версия tcp_bbr      $bbr_ver (это BBRv3)"
    else
        info "версия tcp_bbr      $bbr_ver (BBRv3 нет, для неё нужно ядро XanMod)"
    fi
    info "congestion control  $cc"
    if [ "$cc" = "bbr" ] && [ "$bbr_ver" != "3" ]; then
        dim "control «bbr» включён, но по имени не отличить v1/v2 от v3 — смотри версию модуля выше"
    fi
    return 0
}

cmd_kernel() {
    require_root
    detect_host
    TG_MODE="server"
    krn_detect
    krn_render_plan
    if ! krn_blockers; then
        say ""
        die "Установка ядра на этой машине небезопасна. Причины выше."
    fi
    say ""
    warn "Это единственный модуль, который меняет то, чем сервер загружается."
    dim  "Убедись, что у провайдера есть консоль (VNC, serial, rescue): известный"
    dim  "отказ — ядро грузится, но пропадает сеть, и SSH уже не поможет."
    confirm "Ставить ядро XanMod?" || { dim "Отменено."; say ""; return 0; }
    backup_init
    trap on_error ERR
    APPLY_STARTED=1
    krn_apply
    trap - ERR
    APPLY_STARTED=0
    return 0
}

# ═════════════════════ сетевой тюнинг и гигиена VPS ═════════════════════════
# shellcheck shell=bash
#
#  Фрагмент для вставки в hubtune.sh. Не самостоятельный скрипт: рассчитан на
#  общий контекст hubtune.sh (set -Eeuo pipefail, root, готовые helper'ы
#  ok/warn/bad/info/dim/die/hdr/say/have/is_uint/confirm/fmt_mib/record/
#  save_or_new/require_root и переменные $MARKER/$VERSION/$PROG/$BACKUP_DIR/
#  $SYSCTL_FILE/$HOST_RAM_MIB/$HOST_VIRT).
#
#  Модуль 1 (build_sysctl_body_server) логично воткнуть сразу после
#  build_sysctl_body() — она вызывается той же apply_sysctl() и пишется в тот
#  же $SYSCTL_FILE, второй файл в /etc/sysctl.d не заводится.
#
#  Модуль 2 (hyg_render_plan/hyg_apply) самостоятельный: набор независимых
#  пунктов гигиены VPS, каждый со своим тумблером HYG_DO_*. В --mode/--no-*
#  основного скрипта пока не встроен — это отдельная зона ответственности,
#  вызывающая сторона решает, откуда их дёргать (например, новая команда
#  hygiene). Откат pkg/unit уже умеет rollback_from(), доделывать его не нужно.

# ═════════════════ модуль 1: расширенный сетевой sysctl (сервер) ═══════════
#
# Второй файл в /etc/sysctl.d не заводим: два файла на одни и те же ключи
# дерутся за порядок применения, а он зависит от имени файла и неочевиден на
# глаз. build_sysctl_body_server() — НАДМНОЖЕСТВО обычного тела: дергает
# build_sysctl_body() и дописывает поверх. Результат по-прежнему уходит в
# один и тот же $SYSCTL_FILE через существующую apply_sysctl().

SYSCTL_BUF_MIN_MIB=4                     # нижняя граница буфера сокета (совсем маленькие VPS)
SYSCTL_BUF_MAX_MIB=64                    # верхняя граница — иначе буферы вытеснят из RAM сам Xray
SYSCTL_BUF_MIB_PER_GIB=4                 # столько МиБ буфера добавляем на каждый ГиБ RAM хоста
NETDEV_BUDGET=600                        # дефолтные 300 не успевают вычерпывать очередь при потоке мелких пакетов
NETDEV_BUDGET_USECS=8000                 # дефолт ядра 2000 мкс расчитан на budget=300, при 600 его мало
NF_CONNTRACK_MAX_SERVER=1048576          # заметно выше базовых 262144 из build_sysctl_body
NF_CONNTRACK_TIMEOUT_ESTABLISHED=3600    # короче дефолта ядра 432000 (5 суток) — прокси плодит много сессий

build_sysctl_body_server() {
    local body extra ram_mib scaled_mib rmem_max wmem_max

    body="$(build_sysctl_body)"

    ram_mib="$HOST_RAM_MIB"
    is_uint "$ram_mib" || ram_mib=0
    [ "$ram_mib" -gt 0 ] || ram_mib=1024    # детект хоста не отработал — считаем от 1 ГиБ, не от нуля

    scaled_mib=$(( ram_mib * SYSCTL_BUF_MIB_PER_GIB / 1024 ))
    [ "$scaled_mib" -lt "$SYSCTL_BUF_MIN_MIB" ] && scaled_mib="$SYSCTL_BUF_MIN_MIB"
    [ "$scaled_mib" -gt "$SYSCTL_BUF_MAX_MIB" ] && scaled_mib="$SYSCTL_BUF_MAX_MIB"
    rmem_max=$(( scaled_mib * 1024 * 1024 ))
    wmem_max=$(( rmem_max / 2 ))

    extra="
# ── build_sysctl_body_server: надмножество для выделенных/крупных нод ───────

# буфер на сокет растёт вместе с RAM хоста (сейчас ${ram_mib} МиБ → ${scaled_mib} МиБ
# на буфер чтения): на маленькой VPS большие буферы просто заберут память у
# Xray, на большой — старые фиксированные значения станут тесными для long-fat
# соединений
net.core.rmem_max = $rmem_max
net.core.wmem_max = $wmem_max
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.ipv4.tcp_rmem = 4096 87380 $rmem_max
net.ipv4.tcp_wmem = 4096 16384 $wmem_max
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384

# не будим процесс на каждый мелкий пакет, пока в очереди на отправку меньше
# этого порога — меньше переключений контекста при большом числе сессий разом
net.ipv4.tcp_notsent_lowat = 131072

# NAPI/softirq: дефолтные 300 пакетов за проход не успевают вычерпываться,
# когда через ноду идёт поток мелких TCP/UDP-пакетов множества сессий сразу
net.core.netdev_budget = $NETDEV_BUDGET
net.core.netdev_budget_usecs = $NETDEV_BUDGET_USECS

# ── типовые пункты security-чеклистов (CIS/lynis) ───────────────────────────
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
kernel.dmesg_restrict = 1
kernel.kptr_restrict = 1

# rp_filter НЕ переводим в strict (1): нода проксирует/маршрутизирует чужой
# трафик, и при асимметричной маршрутизации (ответ уходит не через тот же
# интерфейс/путь, каким пришёл запрос) strict-режим молча дропает легитимные
# пакеты. loose (2) всё ещё режет очевидный спуфинг, но не трогает асимметрию.
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2"

    if [ -e /proc/sys/net/netfilter/nf_conntrack_max ]; then
        extra="$extra

# conntrack трогаем, только если модуль реально загружен: на части урезанных
# ядер (некоторые контейнерные виртуалки) его нет вовсе, а sysctl -p на
# отсутствующий ключ просто шумит предупреждением внутри apply_sysctl()
net.netfilter.nf_conntrack_max = $NF_CONNTRACK_MAX_SERVER
net.netfilter.nf_conntrack_tcp_timeout_established = $NF_CONNTRACK_TIMEOUT_ESTABLISHED"
    fi

    printf '%s\n%s\n' "$body" "$extra"
}

# ══════════════════════ модуль 2: гигиена VPS ═══════════════════════════════
#
# Пять независимых пунктов, у каждого свой тумблер HYG_DO_* (по умолчанию
# включены). Всё создаваемое проходит save_or_new() перед записью; пакеты и
# юниты фиксируются через record pkg/record unit — ветку отката для них уже
# знает rollback_from().

HYG_DO_UNATTENDED=1        # unattended-upgrades: только security, без авторебута
HYG_DO_JOURNALD=1          # journald: сохраняем логи между перезагрузками, с потолком
HYG_DO_TIMESYNC=1          # systemd-timesyncd, если время не синхронизирует что-то ещё
HYG_DO_THP=1               # transparent hugepages → madvise
HYG_DO_GOVERNOR=1          # cpu governor → performance, если это вообще видно системе

HYG_UNATTENDED_DROPIN="/etc/apt/apt.conf.d/52-hubtune-unattended"
HYG_JOURNALD_DROPIN_DIR="/etc/systemd/journald.conf.d"
HYG_JOURNALD_DROPIN="$HYG_JOURNALD_DROPIN_DIR/10-hubtune-journald.conf"
HYG_JOURNALD_MAX_USE="512M"
HYG_JOURNALD_MAX_FILE_SIZE="64M"
HYG_THP_UNIT="hubtune-thp.service"
HYG_THP_MODE="madvise"
HYG_THP_PATH="/sys/kernel/mm/transparent_hugepage/enabled"
HYG_GOVERNOR="performance"
HYG_GOVERNOR_UNIT="hubtune-governor.service"

# /sys/kernel/mm/* и /sys/devices/system/cpu/*/cpufreq не привязаны к cgroup
# и не namespace'ятся: в контейнерных виртуалках с общим ядром (OpenVZ/LXC)
# запись туда меняет настройку хоста и всех соседей разом, а не только этой
# гостевой системы. На полноценных VM (kvm/qemu/xen/...) и на железе это её
# собственное ядро — там трогать можно.
hyg_is_shared_kernel_virt() {
    case "$HOST_VIRT" in
        openvz|lxc|lxc-libvirt|systemd-nspawn|docker|podman|wsl) return 0 ;;
        *) return 1 ;;
    esac
}

hyg_cpufreq_present() {
    local f
    for f in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_governor; do
        [ -e "$f" ] && return 0
    done
    return 1
}

hyg_other_timesync_active() {
    local svc
    for svc in chrony chronyd ntp ntpd ntpsec openntpd; do
        systemctl is-active --quiet "$svc" 2>/dev/null && return 0
    done
    return 1
}

# ── unattended-upgrades: только security, без автоперезагрузки ──────────────
hyg_apply_unattended() {
    [ "$HYG_DO_UNATTENDED" = "1" ] || { dim "unattended-upgrades: пропущено настройкой"; return 0; }
    if ! have apt-get; then
        dim "unattended-upgrades: нужен apt (Debian/Ubuntu) — на этой системе его нет"
        return 0
    fi

    if ! dpkg -s unattended-upgrades >/dev/null 2>&1; then
        if ! DEBIAN_FRONTEND=noninteractive apt-get install -y unattended-upgrades >/dev/null 2>&1; then
            # свежий VPS часто отдаётся с пустым или просроченным кэшем индексов
            apt-get update >/dev/null 2>&1 || true
            if ! DEBIAN_FRONTEND=noninteractive apt-get install -y unattended-upgrades >/dev/null 2>&1; then
                warn "unattended-upgrades не установился — пропускаю настройку"
                return 0
            fi
        fi
        record pkg "unattended-upgrades"
    fi

    save_or_new "$HYG_UNATTENDED_DROPIN"
    local tmp; tmp="$(mktemp)"
    {
        # apt.conf понимает только "//"-комментарии; "#" зарезервирован под
        # директивы #include/#clear — обычная решётка тут же ломает apt целиком
        printf '// %s %s\n' "$MARKER" "$VERSION"
        # 52 — специально позже штатного 50unattended-upgrades: #clear должен
        # сначала увидеть уже загруженный вендорный Origins-Pattern, чтобы
        # было что чистить, а не просто добавлять свои строки поверх пустоты
        printf '#clear Unattended-Upgrade::Origins-Pattern;\n'
        printf 'Unattended-Upgrade::Origins-Pattern {\n'
        # ${distro_id}/${distro_codename} — не переменные apt, а плейсхолдеры,
        # которые сама unattended-upgrades подставит по фактической ОС; Debian
        # и Ubuntu матчат security-репозиторий по-разному (label vs archive),
        # поэтому держим варианты под обе — на "чужой" ветке они просто ни на
        # что не сматчатся
        printf '    "origin=Debian,codename=${distro_codename},label=Debian-Security";\n'
        printf '    "origin=Debian,codename=${distro_codename}-security,label=Debian-Security";\n'
        printf '    "origin=Ubuntu,archive=${distro_codename}-security";\n'
        printf '    "origin=Ubuntu,archive=${distro_codename}-security,label=Ubuntu";\n'
        printf '};\n'
        printf 'APT::Periodic::Update-Package-Lists "1";\n'
        # без этой пары ключей пакет стоит установленным, но по факту не
        # запускается ни по таймеру, ни по крону — типичная причина, почему
        # "автообновления включены", а на деле не сработали ни разу
        printf 'APT::Periodic::Unattended-Upgrade "1";\n'
        # автоперезагрузка в 4 утра по умолчанию — это разрыв разом у всех
        # клиентов VPN-ноды; обновление ядра/openssl и так требует отдельного
        # контролируемого ребута руками
        printf 'Unattended-Upgrade::Automatic-Reboot "false";\n'
    } > "$tmp"
    install -m 0644 "$tmp" "$HYG_UNATTENDED_DROPIN"
    rm -f "$tmp"
    ok "записан $HYG_UNATTENDED_DROPIN (только security, автоперезагрузка выключена)"
}

# ── journald: логи переживают перезагрузку, но не разрастаются ──────────────
hyg_apply_journald() {
    [ "$HYG_DO_JOURNALD" = "1" ] || { dim "journald: пропущено настройкой"; return 0; }

    mkdir -p "$HYG_JOURNALD_DROPIN_DIR"
    save_or_new "$HYG_JOURNALD_DROPIN"
    local tmp; tmp="$(mktemp)"
    {
        printf '# %s %s\n' "$MARKER" "$VERSION"
        printf '[Journal]\n'
        # без persistent лог живёт в tmpfs и пропадает при перезагрузке — а
        # именно после OOM-килла или краша ноды это первое, что нужно смотреть
        printf 'Storage=persistent\n'
        printf 'SystemMaxUse=%s\n' "$HYG_JOURNALD_MAX_USE"
        printf 'SystemMaxFileSize=%s\n' "$HYG_JOURNALD_MAX_FILE_SIZE"
    } > "$tmp"
    install -m 0644 "$tmp" "$HYG_JOURNALD_DROPIN"
    rm -f "$tmp"

    # у systemd-journald нет ExecReload — штатный способ применить конфиг
    # именно restart; сокет активируется systemd'ом, короткий рестарт запись
    # не роняет
    if systemctl restart systemd-journald >/dev/null 2>&1; then
        ok "записан $HYG_JOURNALD_DROPIN, journald перезапущен"
    else
        warn "записан $HYG_JOURNALD_DROPIN, но перезапустить journald не удалось — применится после ребута"
    fi
}

# ── синхронизация времени: включаем свою, только если нет чужой ─────────────
hyg_apply_timesync() {
    [ "$HYG_DO_TIMESYNC" = "1" ] || { dim "синхронизация времени: пропущено настройкой"; return 0; }

    if hyg_other_timesync_active; then
        dim "синхронизация времени уже обеспечена другой службой (chrony/ntpd) — не трогаю"
        return 0
    fi

    # в манифест ничего не пишем: это включение штатного вендорного юнита, а
    # не наш файл, и откатывать синхронизацию времени нельзя — без неё
    # посыплется проверка TLS-сертификатов у всех клиентов ноды
    if systemctl enable --now systemd-timesyncd >/dev/null 2>&1; then
        ok "включена синхронизация времени: systemd-timesyncd"
    else
        warn "не удалось включить systemd-timesyncd"
    fi
}

# ── Transparent Huge Pages → madvise (sysctl этим не управляет) ─────────────
hyg_apply_thp() {
    [ "$HYG_DO_THP" = "1" ] || { dim "THP: пропущено настройкой"; return 0; }
    if hyg_is_shared_kernel_virt; then
        dim "THP: ядро общее с другими гостями ($HOST_VIRT) — не трогаю"
        return 0
    fi
    if [ ! -e "$HYG_THP_PATH" ]; then
        dim "THP: $HYG_THP_PATH в системе нет — пропускаю"
        return 0
    fi

    local unit="/etc/systemd/system/$HYG_THP_UNIT" tmp
    save_or_new "$unit"
    tmp="$(mktemp)"
    {
        printf '# %s %s\n' "$MARKER" "$VERSION"
        printf '[Unit]\n'
        printf 'Description=HUBTune: transparent hugepage = %s\n' "$HYG_THP_MODE"
        printf 'DefaultDependencies=no\n'
        printf 'After=sysinit.target\n'
        printf 'Before=basic.target\n\n'
        printf '[Service]\n'
        printf 'Type=oneshot\n'
        printf 'RemainAfterExit=yes\n'
        # madvise, а не always/never: always провоцирует паузы на compaction
        # под нагрузкой (что бьёт по латентности прокси-трафика), never просто
        # выключает THP всем подряд; madvise даёт huge pages только тем, кто
        # сам попросил через MADV_HUGEPAGE
        printf "ExecStart=/bin/sh -c 'echo %s > %s'\n" "$HYG_THP_MODE" "$HYG_THP_PATH"
        printf '\n[Install]\n'
        printf 'WantedBy=basic.target\n'
    } > "$tmp"
    install -m 0644 "$tmp" "$unit"
    rm -f "$tmp"

    systemctl daemon-reload
    if systemctl enable --now "$HYG_THP_UNIT" >/dev/null 2>&1; then
        ok "THP → $HYG_THP_MODE (юнит $HYG_THP_UNIT)"
    else
        warn "юнит $HYG_THP_UNIT не запустился — проверь systemctl status $HYG_THP_UNIT"
    fi
    record unit "$HYG_THP_UNIT"
}

# ── CPU governor → performance, если система вообще это показывает ──────────
hyg_apply_governor() {
    [ "$HYG_DO_GOVERNOR" = "1" ] || { dim "governor: пропущено настройкой"; return 0; }
    if hyg_is_shared_kernel_virt; then
        dim "governor: ядро общее с другими гостями ($HOST_VIRT) — не трогаю"
        return 0
    fi
    if ! hyg_cpufreq_present; then
        # на подавляющем большинстве VPS (KVM без passthrough) хосту не видно
        # реального железа CPU — путей cpufreq просто нет, это норма, не сбой
        dim "governor: cpufreq не выведен в систему — пропускаю"
        return 0
    fi

    if have cpupower && cpupower frequency-set -g "$HYG_GOVERNOR" >/dev/null 2>&1; then
        ok "governor → $HYG_GOVERNOR прямо сейчас (cpupower)"
    elif printf '%s' "$HYG_GOVERNOR" | tee /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_governor >/dev/null 2>&1; then
        ok "governor → $HYG_GOVERNOR прямо сейчас (sysfs)"
    else
        warn "не получилось переключить governor прямо сейчас"
    fi

    # значение в sysfs слетает при каждой перезагрузке независимо от того,
    # чем его выставляли; закрепляем отдельным юнитом, не полагаясь на то,
    # есть ли в дистрибутиве штатный cpupower.service (в одних есть, в других
    # нет, и его поведение по умолчанию не одинаковое)
    local unit="/etc/systemd/system/$HYG_GOVERNOR_UNIT" tmp
    save_or_new "$unit"
    tmp="$(mktemp)"
    {
        printf '# %s %s\n' "$MARKER" "$VERSION"
        printf '[Unit]\n'
        printf 'Description=HUBTune: cpu governor = %s\n' "$HYG_GOVERNOR"
        printf 'After=multi-user.target\n\n'
        printf '[Service]\n'
        printf 'Type=oneshot\n'
        printf 'RemainAfterExit=yes\n'
        printf "ExecStart=/bin/sh -c 'echo %s | tee /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_governor >/dev/null'\n" "$HYG_GOVERNOR"
        printf '\n[Install]\n'
        printf 'WantedBy=multi-user.target\n'
    } > "$tmp"
    install -m 0644 "$tmp" "$unit"
    rm -f "$tmp"

    systemctl daemon-reload
    systemctl enable "$HYG_GOVERNOR_UNIT" >/dev/null 2>&1 \
        || warn "не удалось включить $HYG_GOVERNOR_UNIT в автозагрузку"
    record unit "$HYG_GOVERNOR_UNIT"
    ok "записан юнит $HYG_GOVERNOR_UNIT (закрепляет governor после ребута)"
}

hyg_render_plan() {
    hdr "Гигиена VPS"

    if [ "$HYG_DO_UNATTENDED" = "1" ]; then
        if have apt-get; then
            ok "unattended-upgrades: только security, без автоперезагрузки"
        else
            dim "unattended-upgrades: нужен apt (Debian/Ubuntu) — пропускаю"
        fi
    else
        dim "unattended-upgrades: выключено"
    fi

    if [ "$HYG_DO_JOURNALD" = "1" ]; then
        ok "journald: Storage=persistent, лимит $HYG_JOURNALD_MAX_USE"
    else
        dim "journald: выключено"
    fi

    if [ "$HYG_DO_TIMESYNC" = "1" ]; then
        if hyg_other_timesync_active; then
            dim "синхронизация времени: уже обеспечена другой службой — не трогаю"
        else
            ok "синхронизация времени: включаю systemd-timesyncd"
        fi
    else
        dim "синхронизация времени: выключено"
    fi

    if [ "$HYG_DO_THP" = "1" ]; then
        if hyg_is_shared_kernel_virt; then
            dim "THP: хост общий с другими гостями ($HOST_VIRT) — не трогаю"
        elif [ ! -e "$HYG_THP_PATH" ]; then
            dim "THP: в системе не поддерживается — пропускаю"
        else
            ok "THP → $HYG_THP_MODE"
        fi
    else
        dim "THP: выключено"
    fi

    if [ "$HYG_DO_GOVERNOR" = "1" ]; then
        if hyg_is_shared_kernel_virt; then
            dim "governor: хост общий с другими гостями ($HOST_VIRT) — не трогаю"
        elif ! hyg_cpufreq_present; then
            dim "governor: cpufreq не выведен в систему — пропускаю"
        else
            ok "governor → $HYG_GOVERNOR"
        fi
    else
        dim "governor: выключено"
    fi
    say ""
}

hyg_apply() {
    hdr "Гигиена VPS"
    hyg_apply_unattended
    hyg_apply_journald
    hyg_apply_timesync
    hyg_apply_thp
    hyg_apply_governor
    say ""
}

cmd_hygiene() {
    require_root
    detect_host
    TG_MODE="server"

    # Команда наследует режим safe, где DO_BBR=0. Но это и есть модуль сетевого
    # тюнинга: молча не включить BBR тут — то же самое, что не сделать работу.
    # Явный --no-bbr по-прежнему сильнее.
    [ -z "$EX_BBR" ] && DO_BBR=1

    # Серверный набор — надмножество узлового, и уходит в тот же файл.
    # Два файла в /etc/sysctl.d с близкими именами дрались бы за одни ключи.
    PLAN_SYSCTL_BODY="$(build_sysctl_body_server)"
    PLAN_SYSCTL=1
    if [ -f "$SYSCTL_FILE" ] && printf '%s\n' "$PLAN_SYSCTL_BODY" | cmp -s - "$SYSCTL_FILE"; then
        PLAN_SYSCTL=0
    fi

    hdr "Сетевой тюнинг"
    if [ "$PLAN_SYSCTL" = "1" ]; then
        ok "параметры ядра → $SYSCTL_FILE"
        dim "буферы посчитаны от $(fmt_mib "$HOST_RAM_MIB") RAM; rp_filter оставлен loose,"
        dim "потому что strict молча роняет асимметричную маршрутизацию на ноде"
    else
        dim "параметры ядра уже выставлены как нужно"
    fi
    hyg_render_plan

    confirm "Применить?" || { dim "Отменено."; say ""; return 0; }
    backup_init
    trap on_error ERR
    APPLY_STARTED=1
    apply_sysctl
    hyg_apply
    trap - ERR
    APPLY_STARTED=0
    say ""; ok "Готово."; dim "откат: $PROG rollback"; say ""
    return 0
}

# ══════════════════════════ SSH и fail2ban ══════════════════════════════════
# shellcheck shell=bash
#
# Модуль SSH + fail2ban для hubtune.sh. Вставляется как есть, отдельно не
# запускается. Использует готовые из основного скрипта: ok warn bad info dim
# die hdr say have is_uint confirm record save_or_new require_root,
# а также MARKER VERSION PROG BACKUP_DIR и fw_ssh_ports/fw_session_peer.
#
# Главное правило модуля: типовое ужесточение (запрет root и паролей) на
# ноде без второго пользователя — это самозапирание. Поэтому вход всегда
# проверяется ДО того, как что-то отключается, а не после.

# ── SSH: параметры по умолчанию ──────────────────────────────────────────────
SSH_DROPIN_DIR="/etc/ssh/sshd_config.d"
SSH_DROPIN_FILE="$SSH_DROPIN_DIR/60-hubtune-ssh.conf"
SSH_MAIN_CONFIG="/etc/ssh/sshd_config"
SSH_UNIT="ssh"                    # имя юнита по умолчанию (Debian/Ubuntu)
SSH_MAX_AUTH_TRIES=3
SSH_LOGIN_GRACE_TIME=30
SSH_CLIENT_ALIVE_INTERVAL=300
SSH_CLIENT_ALIVE_COUNT_MAX=2

# Заполняются ssh_detect()/ssh_can_lock_out(), см. интерфейс ниже.
SSH_HAS_ESCAPE=0                  # 1 — есть подтверждённый способ войти без пароля root
SSH_ESCAPE_WHO=""                 # человекочитаемое объяснение, для вывода
SSH_ESCAPE_KIND="none"            # none | user | root — от кого именно выход
SSH_ROOT_LOGIN="unknown"          # текущее PermitRootLogin (sshd -T)
SSH_PASSWORD_AUTH="unknown"       # текущее PasswordAuthentication (sshd -T)

# ── fail2ban: параметры по умолчанию ─────────────────────────────────────────
F2B_JAIL_FILE="/etc/fail2ban/jail.d/hubtune.local"
F2B_MAXRETRY=5
F2B_FINDTIME="10m"
F2B_BANTIME="1h"
F2B_IGNOREIP_EXTRA=""             # доп. адреса в ignoreip через пробел (задел под флаг)

# ═══════════════════════════════ SSH: разведка ══════════════════════════════

# На Debian/Ubuntu юнит называется ssh.service, но на части пересборок и
# других семейств остаётся классическое sshd.service — не гадаем по имени
# дистрибутива, а спрашиваем сам systemd, что у него реально загружено.
_ssh_unit_name() {
    if systemctl cat ssh.service >/dev/null 2>&1; then
        printf 'ssh'
    elif systemctl cat sshd.service >/dev/null 2>&1; then
        printf 'sshd'
    else
        printf '%s' "$SSH_UNIT"
    fi
}

# sshd_config.d подхватывается, только если основной файл его подключает.
# Раз штатный файл трогать нельзя, при отсутствии Include честно отказываемся,
# а не тихо пишем дроп-ин, который никогда не прочитается.
_ssh_dropin_supported() {
    grep -qiE '^[[:space:]]*Include[[:space:]]+.*sshd_config\.d' "$SSH_MAIN_CONFIG" 2>/dev/null
}

# Строка вида "command=...,no-pty ssh-ed25519 AAAA..." — тип ключа может
# стоять не в начале строки, поэтому ищем подстроку, а не якорим ^.
_ssh_has_real_key() {
    local f="$1"
    [ -s "$f" ] || return 1
    grep -vE '^[[:space:]]*(#|$)' "$f" 2>/dev/null \
        | grep -qE 'ssh-(ed25519|rsa|dss)|ecdsa-sha2-|sk-(ssh-ed25519|ecdsa-sha2-)'
}

# sudo проверяем и по членству в группе, и по прямой записи в sudoers —
# второе бывает у ролей, которым sudo выдан без отдельной группы.
_ssh_user_has_sudo() {
    local u="$1" grp
    for grp in sudo wheel admin; do
        getent group "$grp" 2>/dev/null \
            | awk -F: -v u="$u" '{n=split($4,a,","); for (i=1;i<=n;i++) if (a[i]==u) f=1} END{exit !f}' \
            && return 0
    done
    grep -RhsqE "^[[:space:]]*${u}[[:space:]]" /etc/sudoers /etc/sudoers.d/ 2>/dev/null && return 0
    return 1
}

# root: домашний каталог берём из passwd, а не хардкодим /root — на части
# образов он переопределён.
_ssh_root_has_key() {
    local home=""
    home="$(getent passwd root 2>/dev/null | awk -F: '{print $6; exit}' || true)"
    [ -n "$home" ] || home="/root"
    _ssh_has_real_key "$home/.ssh/authorized_keys"
}

# Первый попавшийся не-root пользователь: оболочка не nologin/false,
# настоящий ключ в authorized_keys и права sudo. Только локальные записи
# (getent passwd, не LDAP/AD) — для одиночной VPN-ноды этого достаточно.
_ssh_find_escape_user() {
    local login uid home shell
    while IFS=: read -r login _ uid _ _ home shell; do
        [ "$uid" != "0" ] || continue
        case "$shell" in */nologin|*/false|'') continue ;; esac
        [ -d "$home" ] || continue
        _ssh_has_real_key "$home/.ssh/authorized_keys" || continue
        _ssh_user_has_sudo "$login" || continue
        printf '%s\n' "$login"
        return 0
    done < <(getent passwd)
    return 1
}

# Есть ли путь войти, если пароль root и/или root-логин отключить.
# Возврат 0 значит "да, можем себя запереть" (выхода нет) — так короче
# читаются вызовы вида `ssh_can_lock_out && warn ...`. Побочный эффект —
# заполняет SSH_HAS_ESCAPE/SSH_ESCAPE_WHO/SSH_ESCAPE_KIND для остальных
# функций модуля.
ssh_can_lock_out() {
    SSH_HAS_ESCAPE=0
    SSH_ESCAPE_KIND="none"
    SSH_ESCAPE_WHO="нет ни пользователя с ключом и sudo, ни ключа у root"

    local u=""
    u="$(_ssh_find_escape_user || true)"
    if [ -n "$u" ]; then
        SSH_HAS_ESCAPE=1
        SSH_ESCAPE_KIND="user"
        SSH_ESCAPE_WHO="пользователь «$u»: есть shell, ключ в authorized_keys и sudo"
        return 1
    fi

    if _ssh_root_has_key; then
        SSH_HAS_ESCAPE=1
        SSH_ESCAPE_KIND="root"
        SSH_ESCAPE_WHO="root по ключу — пароль root отключим, вход по ключу оставим разрешённым"
        return 1
    fi

    return 0
}

# ssh_detect — только сбор состояния, ничего не печатает и не решает.
ssh_detect() {
    SSH_ROOT_LOGIN="$(sshd -T 2>/dev/null | awk '/^permitrootlogin /{print $2; exit}' || true)"
    SSH_PASSWORD_AUTH="$(sshd -T 2>/dev/null | awk '/^passwordauthentication /{print $2; exit}' || true)"
    [ -n "$SSH_ROOT_LOGIN" ] || SSH_ROOT_LOGIN="unknown"
    [ -n "$SSH_PASSWORD_AUTH" ] || SSH_PASSWORD_AUTH="unknown"

    ssh_can_lock_out || true
    return 0
}

ssh_render_plan() {
    local peer cip

    ssh_detect
    hdr "SSH"
    info "сейчас: PermitRootLogin=$SSH_ROOT_LOGIN, PasswordAuthentication=$SSH_PASSWORD_AUTH"

    peer="$(fw_session_peer)"
    cip="${peer%% *}"
    [ -n "$cip" ] && dim "  текущая сессия: $cip"

    if _ssh_dropin_supported; then
        dim "  $SSH_MAIN_CONFIG подключает $SSH_DROPIN_DIR — дроп-ин сработает"
    else
        bad "$SSH_MAIN_CONFIG не подключает $SSH_DROPIN_DIR (нет строки Include)"
        dim "  без неё дроп-ин будет лежать мёртвым грузом, apply откажется работать"
        dim "  почини вручную: Include $SSH_DROPIN_DIR/*.conf"
    fi

    say ""
    if [ "$SSH_HAS_ESCAPE" = "1" ]; then
        ok "запасной вход есть: $SSH_ESCAPE_WHO"
        if [ "$SSH_ESCAPE_KIND" = "user" ]; then
            ok "будет: PermitRootLogin no, PasswordAuthentication no"
        else
            ok "будет: PermitRootLogin prohibit-password, PasswordAuthentication no"
        fi
    else
        bad "запасного входа нет — единственный путь внутрь сейчас: пароль root"
        warn "PermitRootLogin и PasswordAuthentication НЕ трогаю — это и есть защита от самозапирания"
        dim "  сначала одно из двух:"
        dim "  · заведи пользователя, добавь его в sudo, положи его публичный ключ"
        dim "    в ~/.ssh/authorized_keys — тогда разрешим полное отключение root"
        dim "  · либо просто положи свой публичный ключ в /root/.ssh/authorized_keys —"
        dim "    тогда отключим только пароль, вход по ключу для root останется"
        if [ "$SSH_PASSWORD_AUTH" = "no" ] && { [ "$SSH_ROOT_LOGIN" = "no" ] || [ "$SSH_ROOT_LOGIN" = "prohibit-password" ]; }; then
            bad "похоже, сервер и так уже заперт без нашего участия — если это не ты настраивал,"
            dim "  проверь доступ прямо сейчас, пока сессия открыта"
        fi
    fi

    ok "всегда: MaxAuthTries $SSH_MAX_AUTH_TRIES, LoginGraceTime $SSH_LOGIN_GRACE_TIME, PermitEmptyPasswords no"
    ok "всегда: X11Forwarding no, ClientAliveInterval $SSH_CLIENT_ALIVE_INTERVAL, ClientAliveCountMax $SSH_CLIENT_ALIVE_COUNT_MAX, UseDNS no"

    say ""
    dim "правка только через $SSH_DROPIN_FILE, $SSH_MAIN_CONFIG не трогается"
    dim "перед применением — sshd -t, применение — systemctl reload (не restart)"
    say ""
}

# Сверяем не текст конфига, а то, что реально видит sshd: sshd -T учитывает
# все Include и порядок first-match-wins сам, без наших догадок про то, чей
# файл в sshd_config.d прочитается раньше.
_ssh_verify_effective() {
    local key="$1" want="$2" got=""
    got="$(sshd -T 2>/dev/null | awk -v k="$key" '$1==k{print $2; exit}' || true)"
    [ "$got" = "$want" ]
}

ssh_apply() {
    local want_root="" want_pass="" tmp errfile unit

    ssh_can_lock_out || true

    if [ "$SSH_HAS_ESCAPE" = "1" ]; then
        if [ "$SSH_ESCAPE_KIND" = "user" ]; then
            want_root="no"
        else
            want_root="prohibit-password"
        fi
        want_pass="no"
    else
        warn "запасного входа нет — PermitRootLogin и PasswordAuthentication не трогаю"
    fi

    _ssh_dropin_supported \
        || die "В $SSH_MAIN_CONFIG нет Include $SSH_DROPIN_DIR/*.conf — дроп-ин не подхватится.
   Файл не трогаю (по правилам модуля), добавь строку Include туда вручную и повтори apply."

    mkdir -p "$SSH_DROPIN_DIR"
    sshd -T > "$BACKUP_DIR/sshd-effective-before.txt" 2>/dev/null || true

    tmp="$(mktemp)"
    {
        printf '# %s %s\n' "$MARKER" "$VERSION"
        printf '# Сгенерировано %s. %s не изменялся, правь только этот файл.\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$SSH_MAIN_CONFIG"
        [ -n "$want_root" ] && printf 'PermitRootLogin %s\n' "$want_root"
        [ -n "$want_pass" ] && printf 'PasswordAuthentication %s\n' "$want_pass"
        printf 'MaxAuthTries %s\n' "$SSH_MAX_AUTH_TRIES"
        printf 'LoginGraceTime %s\n' "$SSH_LOGIN_GRACE_TIME"
        printf 'PermitEmptyPasswords no\n'
        printf 'X11Forwarding no\n'
        printf 'ClientAliveInterval %s\n' "$SSH_CLIENT_ALIVE_INTERVAL"
        printf 'ClientAliveCountMax %s\n' "$SSH_CLIENT_ALIVE_COUNT_MAX"
        printf 'UseDNS no\n'
    } > "$tmp"

    save_or_new "$SSH_DROPIN_FILE"
    install -m 0644 "$tmp" "$SSH_DROPIN_FILE"
    rm -f "$tmp"

    errfile="$(mktemp)"
    if ! sshd -t 2>"$errfile"; then
        sed 's/^/    /' "$errfile" >&2
        rm -f "$errfile"
        die "sshd -t отверг новый конфиг. $SSH_DROPIN_FILE записан, но не применён —
   поправь его руками или сделай $PROG rollback."
    fi
    rm -f "$errfile"
    ok "sshd -t принял конфигурацию"

    if [ -n "$want_root" ] && ! _ssh_verify_effective permitrootlogin "$want_root"; then
        die "PermitRootLogin по факту не стал «$want_root» — перебивает другой файл в
   $SSH_DROPIN_DIR или сам $SSH_MAIN_CONFIG. Reload НЕ делаю, разбирайся руками."
    fi
    if [ -n "$want_pass" ] && ! _ssh_verify_effective passwordauthentication "$want_pass"; then
        die "PasswordAuthentication по факту не стал «$want_pass» — перебито другим файлом.
   Reload НЕ делаю, разбирайся руками."
    fi

    unit="$(_ssh_unit_name)"
    errfile="$(mktemp)"
    if ! systemctl reload "$unit" 2>"$errfile"; then
        sed 's/^/    /' "$errfile" >&2
        rm -f "$errfile"
        die "systemctl reload $unit не прошёл — конфиг валиден, но служба его не приняла."
    fi
    rm -f "$errfile"
    ok "применено через systemctl reload $unit — текущие сессии не разорваны"

    say ""
    hdr "не закрывай эту сессию"
    dim "открой ВТОРОЕ подключение и проверь вход им же способом, каким входишь обычно"
    say ""
    ok "если новое подключение работает — всё в порядке, эту сессию можно закрывать"
    warn "если не работает — из ЭТОЙ, ещё открытой сессии:"
    dim "    rm -f $SSH_DROPIN_FILE && sshd -t && systemctl reload $unit"
    dim "  или: $PROG rollback"
    say ""
}

# ═══════════════════════════════ fail2ban ═══════════════════════════════════

# Автоопределение backend'а у fail2ban не заслуживает доверия, если на
# машине есть и nftables, и iptables разом — берём nftables явно и сами.
_f2b_backend() {
    if have nft; then
        printf 'nftables[type=multiport]'
    elif have iptables; then
        printf 'iptables-multiport'
    else
        printf ''
    fi
}

f2b_render_plan() {
    local ports peer cip backend

    hdr "fail2ban"

    if have fail2ban-client; then
        ok "fail2ban уже установлен"
    else
        info "будет поставлен пакет fail2ban"
    fi

    backend="$(_f2b_backend)"
    case "$backend" in
        nftables*) ok "banaction: $backend — задаю явно, не отдаю на автоопределение" ;;
        iptables*) warn "nft не найден, banaction будет: $backend" ;;
        *)         bad "нет ни nft, ни iptables — банить будет нечем" ;;
    esac

    ports="$(fw_ssh_ports | tr '\n' ',')"
    ports="${ports%,}"
    [ -n "$ports" ] || ports=22
    ok "джейл sshd на реальных портах sshd: $ports (не жёстко 22)"

    peer="$(fw_session_peer)"
    cip="${peer%% *}"
    if [ -n "$cip" ]; then
        ok "ignoreip получит адрес текущей сессии: $cip"
    else
        bad "IP текущей сессии не определяется — в ignoreip попадёт только 127.0.0.1/8 ::1"
        dim "  впиши свой адрес в $F2B_JAIL_FILE вручную после apply"
    fi
    case "$cip" in
        *:*) warn "сессия по IPv6 — из коробки fail2ban с ним дружит не всегда"
             dim "  проверь allowipv6 в /etc/fail2ban/fail2ban.conf" ;;
    esac

    say ""
    dim "пишу только $F2B_JAIL_FILE, jail.conf и jail.local не трогаю"
    say ""
}

f2b_apply() {
    local ports backend peer cip tmp errfile ignoreip

    backend="$(_f2b_backend)"
    [ -n "$backend" ] \
        || die "нет ни nft, ни iptables — fail2ban банить не сможет, поставь один из них."

    if ! have fail2ban-client; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y fail2ban >/dev/null \
            || die "не удалось установить пакет fail2ban"
        record pkg "fail2ban"
        ok "пакет fail2ban установлен"
    fi

    ports="$(fw_ssh_ports | tr '\n' ',')"
    ports="${ports%,}"
    [ -n "$ports" ] || ports=22

    peer="$(fw_session_peer)"
    cip="${peer%% *}"
    ignoreip="127.0.0.1/8 ::1"
    [ -n "$cip" ] && ignoreip="$ignoreip $cip"
    [ -n "$F2B_IGNOREIP_EXTRA" ] && ignoreip="$ignoreip $F2B_IGNOREIP_EXTRA"

    mkdir -p /etc/fail2ban/jail.d
    fail2ban-client -d > "$BACKUP_DIR/fail2ban-before.txt" 2>/dev/null || true

    tmp="$(mktemp)"
    {
        printf '# %s %s\n' "$MARKER" "$VERSION"
        printf '# Сгенерировано %s. jail.conf и jail.local не изменялись.\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf '\n[DEFAULT]\n'
        printf 'banaction = %s\n' "$backend"
        printf 'ignoreip = %s\n' "$ignoreip"
        printf '\n[sshd]\n'
        printf 'enabled = true\n'
        printf 'port = %s\n' "$ports"
        printf 'maxretry = %s\n' "$F2B_MAXRETRY"
        printf 'findtime = %s\n' "$F2B_FINDTIME"
        printf 'bantime = %s\n' "$F2B_BANTIME"
    } > "$tmp"

    # Не свой юнит, а системный демон пакета — при откате его нельзя
    # "снимать" как unit (это выключило бы и удалило чужой сервис), поэтому
    # в манифест идёт только сам файл джейла и, если ставили, пакет.
    save_or_new "$F2B_JAIL_FILE"
    install -m 0644 "$tmp" "$F2B_JAIL_FILE"
    rm -f "$tmp"

    errfile="$(mktemp)"
    if ! fail2ban-client -d >"$errfile" 2>&1; then
        sed 's/^/    /' "$errfile" >&2
        rm -f "$errfile"
        die "fail2ban не принял $F2B_JAIL_FILE — правь руками или сделай $PROG rollback."
    fi
    rm -f "$errfile"
    ok "конфигурация fail2ban проверена (fail2ban-client -d)"

    systemctl enable fail2ban >/dev/null 2>&1 || true
    errfile="$(mktemp)"
    if ! systemctl restart fail2ban 2>"$errfile"; then
        sed 's/^/    /' "$errfile" >&2
        rm -f "$errfile"
        die "systemctl restart fail2ban не прошёл — конфиг проверен, но служба не поднялась."
    fi
    rm -f "$errfile"
    ok "fail2ban перезапущен, джейл sshd активен на портах: $ports"

    if [ -z "$cip" ]; then
        warn "IP текущей сессии не определён — если fail2ban всё же забанит тебя самого:"
        dim "    fail2ban-client set sshd unbanip <твой IP>"
    fi
    case "$cip" in
        *:*) warn "сессия была по IPv6 — если словишь бан несмотря на ignoreip, проверь allowipv6" ;;
    esac
}

cmd_ssh() {
    require_root
    detect_host
    TG_MODE="server"
    ssh_detect
    ssh_render_plan
    confirm "Применить настройки SSH?" || { dim "Отменено."; say ""; return 0; }
    backup_init
    trap on_error ERR
    APPLY_STARTED=1
    ssh_apply
    say ""
    f2b_render_plan
    if confirm "Поставить fail2ban для SSH?"; then
        f2b_apply
    else
        dim "fail2ban пропущен."
    fi
    trap - ERR
    APPLY_STARTED=0
    return 0
}

# ═══════════════════════════════════ меню ═══════════════════════════════════

# Запуск без аргументов в терминале: короткая сводка и четыре пункта.
# В пайпе, cron и по ssh с командой меню не показывается — там остаётся plan.
cmd_menu() {
    # menu можно позвать и явно — тогда терминала может не оказаться
    if ! { : < /dev/tty; } 2>/dev/null; then
        warn "Управляющего терминала нет — показываю план вместо меню."
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
    printf '  %s3%s) Файрвол     nftables с автооткатом: не подтвердил из нового\n' "$CW" "$CN"
    printf '                  %sподключения — правила снимаются сами.%s\n' "$CD" "$CN"
    printf '  %s4%s) SSH         защита входа и fail2ban. Отключать пароли откажется,\n' "$CW" "$CN"
    printf '                  %sпока не увидит другого способа войти.%s\n' "$CD" "$CN"
    printf '  %s5%s) Сеть        буферы, очереди, conntrack, автообновления, журнал.\n' "$CW" "$CN"
    printf '  %s6%s) Ядро        XanMod ради BBRv3. Требует перезагрузки и консоли\n' "$CW" "$CN"
    printf '                  %sу провайдера — самый рискованный пункт.%s\n' "$CD" "$CN"
    printf '  %s7%s) Посмотреть  подробный отчёт, ничего не менять.\n' "$CW" "$CN"
    printf '  %s8%s) Откатить    вернуть то, что сделал прошлый запуск.\n' "$CW" "$CN"
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
        3) CMD="firewall"; cmd_firewall ;;
        4) CMD="ssh";      cmd_ssh ;;
        5) CMD="hygiene";  cmd_hygiene ;;
        6) CMD="kernel";   cmd_kernel ;;
        7) CMD="status";   cmd_status ;;
        8) CMD="rollback"; cmd_rollback ;;
        0|"") dim "Выход."; say "" ;;
        *) die "Не понял «$choice». Ожидались 0-8." ;;
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
            firewall|fw)    [ -z "$CMD" ] && CMD="firewall" ;;
            ssh|sshd)       [ -z "$CMD" ] && CMD="ssh" ;;
            tune|hygiene)   [ -z "$CMD" ] && CMD="hygiene" ;;
            kernel|xanmod)  [ -z "$CMD" ] && CMD="kernel" ;;
            confirm)        FW_CONFIRM=1 ;;
            --allow-tcp)    [ $# -ge 2 ] || die "Опция --allow-tcp требует значение."; FW_ALLOW_TCP="$2"; shift ;;
            --allow-tcp=*)  FW_ALLOW_TCP="${1#*=}" ;;
            --allow-udp)    [ $# -ge 2 ] || die "Опция --allow-udp требует значение."; FW_ALLOW_UDP="$2"; shift ;;
            --allow-udp=*)  FW_ALLOW_UDP="${1#*=}" ;;
            --panel-ip)     [ $# -ge 2 ] || die "Опция --panel-ip требует значение."; FW_PANEL_IP="$2"; shift ;;
            --panel-ip=*)   FW_PANEL_IP="${1#*=}" ;;
            --grace)        [ $# -ge 2 ] || die "Опция --grace требует значение."; FW_GRACE="$2"; shift ;;
            --grace=*)      FW_GRACE="${1#*=}" ;;
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
    is_uint "$FW_GRACE" && [ "$FW_GRACE" -ge 30 ] && [ "$FW_GRACE" -le 3600 ] \
        || die "--grace: нужно целое от 30 до 3600 секунд, получено «$FW_GRACE».
   Меньше 30 не хватит, чтобы успеть открыть второе подключение."
    local port
    while IFS= read -r port; do
        [ -n "$port" ] || continue
        is_uint "$port" && [ "$port" -ge 1 ] && [ "$port" -le 65535 ] \
            || die "Порт «$port» — не число от 1 до 65535."
    done <<EOF
$(printf '%s,%s' "$FW_ALLOW_TCP" "$FW_ALLOW_UDP" | tr ',' '\n')
EOF
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
        firewall) if [ "$FW_CONFIRM" = "1" ]; then cmd_fw_confirm; else cmd_firewall; fi ;;
        ssh)      cmd_ssh ;;
        hygiene)  cmd_hygiene ;;
        kernel)   cmd_kernel ;;
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
