#!/usr/bin/env bash
# Прогон всех наборов. Возвращает ненулевой код, если хоть один упал.
cd "$(dirname "$0")" || exit 1
rc=0
for t in test-logic.sh test-detect.sh test-safety.sh test-modes.sh; do
    printf '\n\033[1m--- %s ---\033[0m\n' "$t"
    bash "$t" || rc=1
done
printf '\n'
if [ "$rc" -eq 0 ]; then printf '\033[0;32mвсе наборы пройдены\033[0m\n'
else printf '\033[0;31mесть провалы\033[0m\n'; fi
exit "$rc"
