#!/usr/bin/env bash
# Режимы и их взаимодействие с точечными --no-*.
HUBTUNE_LIB=1 . "$(dirname "$0")/../hubtune.sh"

PASS=0; FAIL=0
eq() { if [ "$2" = "$3" ]; then PASS=$((PASS+1))
       else FAIL=$((FAIL+1)); printf '  FAIL  %s\n        ожидал [%s]\n        получил[%s]\n' "$1" "$2" "$3"; fi; }

# mem logs ulimit restart swap sysctl bbr limitsd
flags() ( parse_args "$@" >/dev/null 2>&1; apply_mode >/dev/null 2>&1
          printf '%s%s%s%s%s%s%s%s' "$DO_MEM" "$DO_LOGS" "$DO_ULIMIT" "$DO_RESTART" \
                 "$DO_SWAP" "$DO_SYSCTL" "$DO_BBR" "$DO_LIMITSD" )
cmd_of() ( parse_args "$@" >/dev/null 2>&1; printf '%s' "$CMD" )

echo "== режимы =="
eq "по умолчанию = safe"  "11110000" "$(flags apply)"
eq "--safe"               "11110000" "$(flags apply --safe)"
eq "--mode safe"          "11110000" "$(flags apply --mode safe)"
eq "--full"               "11111111" "$(flags apply --full)"
eq "--mode=full"          "11111111" "$(flags apply --mode=full)"
eq "--memory"             "10000000" "$(flags apply --memory)"

echo "== точечные --no-* перекрывают режим в любом порядке =="
eq "--full --no-swap"     "11110111" "$(flags apply --full --no-swap)"
eq "--no-swap --full"     "11110111" "$(flags apply --no-swap --full)"
eq "--full --no-sysctl"   "11111011" "$(flags apply --full --no-sysctl)"
eq "--no-bbr --full"      "11111101" "$(flags apply --no-bbr --full)"
eq "--memory --no-mem"    "00000000" "$(flags apply --memory --no-mem)"
eq "--safe --no-logs"     "10110000" "$(flags apply --safe --no-logs)"

echo "== неизвестный режим отвергается =="
rc=0; ( parse_args apply --mode turbo >/dev/null 2>&1; apply_mode ) >/dev/null 2>&1 || rc=$?
eq "выход с ошибкой" "1" "$rc"

echo "== выбор команды по умолчанию =="
eq "без аргументов вне терминала = plan" "plan"     "$(cmd_of)"
eq "явный status"                        "status"   "$(cmd_of status)"
eq "явный apply"                         "apply"    "$(cmd_of apply)"
eq "только опции = plan"                 "plan"     "$(cmd_of --full)"
eq "menu доступен явно"                  "menu"     "$(cmd_of menu)"

echo "== без аргументов в терминале = меню =="
if [ -c /dev/tty ] && ( : < /dev/tty ) 2>/dev/null; then
    eq "menu при tty" "menu" "$( ( parse_args </dev/tty >/dev/tty 2>&1; printf '%s' "$CMD" ) 2>/dev/null )"
else
    PASS=$((PASS+1)); echo "  (пропуск: терминал недоступен)"
fi

printf '\n%s пройдено, %s провалено\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
