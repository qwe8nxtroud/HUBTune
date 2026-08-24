#!/usr/bin/env bash
# Проверки безопасности: бэкап/откат, валидация опций, санитарный контроль лимита.
#
# SC2034: переменные ниже не «неиспользуемые» — их читают функции из hubtune.sh,
# подключённого следующей строкой. Связь через `.` shellcheck не отслеживает.
# shellcheck disable=SC2034
HUBTUNE_LIB=1 . "$(dirname "$0")/../hubtune.sh"

PASS=0; FAIL=0
eq() { if [ "$2" = "$3" ]; then PASS=$((PASS+1))
       else FAIL=$((FAIL+1)); printf '  FAIL  %s\n        ожидал [%s]\n        получил[%s]\n' "$1" "$2" "$3"; fi; }
yes_() { if "$@" >/dev/null 2>&1; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "  FAIL  ожидал успех: $*"; fi; }
no_()  { if "$@" >/dev/null 2>&1; then FAIL=$((FAIL+1)); echo "  FAIL  ожидал отказ: $*"; else PASS=$((PASS+1)); fi; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
BACKUP_DIR="$WORK/bk"; mkdir -p "$BACKUP_DIR/files"
MANIFEST="$BACKUP_DIR/manifest.tsv"; : > "$MANIFEST"; : > "$BACKUP_DIR/about.txt"

echo "== save_or_new различает чужой файл и наш =="
absent="$WORK/absent.conf"
foreign="$WORK/foreign.conf"; echo "чужие настройки" > "$foreign"
mine="$WORK/mine.conf";       printf '# %s 1.0.0\nx=1\n' "$MARKER" > "$mine"
save_or_new "$absent";  save_or_new "$foreign";  save_or_new "$mine"
eq "нет файла -> newfile"        "newfile"   "$(awk -v p="$absent"  '$2==p{print $1}' "$MANIFEST")"
eq "чужой файл -> savedfile"     "savedfile" "$(awk -v p="$foreign" '$2==p{print $1}' "$MANIFEST")"
eq "наш файл -> newfile"         "newfile"   "$(awk -v p="$mine"    '$2==p{print $1}' "$MANIFEST")"
eq "копия чужого сохранена"      "чужие настройки" "$(cat "$BACKUP_DIR/files/$(printf '%s' "$foreign" | tr '/' '_')")"

echo "== rollback_from возвращает состояние =="
echo "изменено" > "$foreign"; echo "новое" > "$absent"
rc=0; out="$(rollback_from "$BACKUP_DIR" 2>&1)" || rc=$?
eq "успех"                    "0"                "$rc"
eq "созданный файл удалён"    "нет"              "$([ -e "$absent" ] && echo есть || echo нет)"
eq "чужой файл восстановлен"  "чужие настройки"  "$(cat "$foreign")"
eq "наш файл удалён"          "нет"              "$([ -e "$mine" ] && echo есть || echo нет)"

echo "== откат не обрывается на первой ошибке =="
: > "$MANIFEST"
a="$WORK/a"; b="$WORK/b"; echo A > "$a"; echo B > "$b"
printf 'savedfile\t%s\t%s\n' "$a" "нет_такой_копии" >> "$MANIFEST"   # заведомо сломанная запись
printf 'newfile\t%s\t\n' "$b" >> "$MANIFEST"
rc=0; out="$(rollback_from "$BACKUP_DIR" 2>&1)" || rc=$?
eq "сообщает о неполноте"       "1"   "$rc"
eq "но следующий шаг сделан"    "нет" "$([ -e "$b" ] && echo есть || echo нет)"
eq "и жалуется вслух"           "1"   "$(printf '%s' "$out" | grep -c 'не полностью')"

echo "== fstab: снимается только наша строка =="
FSTAB_FILE="$WORK/fstab"
printf 'UUID=aaa / ext4 defaults 0 1\n/swapfile-hubtune none swap sw 0 0  # %s\n/dev/sdb1 /data ext4 defaults 0 2\n' "$MARKER" > "$FSTAB_FILE"
fstab_drop_marker /swapfile-hubtune >/dev/null 2>&1
eq "наша строка убрана"   "0" "$(grep -c "$MARKER" "$FSTAB_FILE")"
eq "чужие строки целы"    "2" "$(grep -c . "$FSTAB_FILE")"

echo "== validate_opts отсекает мусор =="
v() ( RESERVE_PCT=20; LOG_MAX_FILE=3; LOG_MAX_SIZE=10m; NOFILE=65535; OPT_MEM=""; OPT_RESERVE=""
      eval "$1"; validate_opts )
yes_ v 'true'
no_  v 'RESERVE_PCT=abc'
no_  v 'RESERVE_PCT=0'
no_  v 'RESERVE_PCT=95'
no_  v 'LOG_MAX_FILE=-1'
no_  v 'LOG_MAX_SIZE=10x'
no_  v 'NOFILE=abc'
no_  v 'NOFILE=100'
no_  v 'OPT_MEM=1.5g'
no_  v 'OPT_RESERVE=немного'
yes_ v 'OPT_MEM=1g; OPT_RESERVE=512m; LOG_MAX_SIZE=50m'

echo "== лимит ниже реального потребления не пропускается =="
m() ( PLAN_MEM_MIB=$1; CUR_PEAK=$2; CUR_USAGE=$3; mem_sanity_check )
yes_ m 820 0 0                                  # фактов нет — не мешаем
yes_ m 820 $((700*1048576)) $((400*1048576))    # лимит выше пика
no_  m 820 $((900*1048576)) $((400*1048576))    # лимит ниже пика
no_  m 820 0 $((900*1048576))                   # лимит ниже текущего
yes_ m 0   $((900*1048576)) 0                   # лимит не меняем — проверять нечего

echo "== swapoff_is_safe не падает без /proc =="
yes_ swapoff_is_safe

printf '\n%s пройдено, %s провалено\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
