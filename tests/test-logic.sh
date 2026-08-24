#!/usr/bin/env bash
# Юнит-тесты чистой логики hubtune.sh (без /proc, docker и systemd).
HUBTUNE_LIB=1 . "$(dirname "$0")/../hubtune.sh"

PASS=0; FAIL=0
eq() { # eq <описание> <ожидаемое> <фактическое>
    if [ "$2" = "$3" ]; then PASS=$((PASS+1))
    else FAIL=$((FAIL+1)); printf '  FAIL  %s\n        ожидал [%s]\n        получил[%s]\n' "$1" "$2" "$3"; fi
}

echo "== parse_mib =="
eq "512m"  512   "$(parse_mib 512m)"
eq "1g"    1024  "$(parse_mib 1g)"
eq "2G"    2048  "$(parse_mib 2G)"
eq "1536"  1536  "$(parse_mib 1536)"
eq "768mb" 768   "$(parse_mib 768mb)"
eq "1gib"  1024  "$(parse_mib 1gib)"
eq "мусор отвергнут" "1" "$(parse_mib 'ой' >/dev/null 2>&1; echo $?)"
eq "1.5g отвергнут"  "1" "$(parse_mib '1.5g' >/dev/null 2>&1; echo $?)"

echo "== calc_limit_mib (RAM -> лимит) =="
eq "256M"   192   "$(calc_limit_mib 256)"
eq "384M"   256   "$(calc_limit_mib 384)"
eq "512M"   320   "$(calc_limit_mib 512)"
eq "1G"     820   "$(calc_limit_mib 1024)"
eq "2G"     1639  "$(calc_limit_mib 2048)"
eq "4G"     3277  "$(calc_limit_mib 4096)"
eq "8G"     7168  "$(calc_limit_mib 8192)"
eq "16G"    15360 "$(calc_limit_mib 16384)"
eq "32G"    31744 "$(calc_limit_mib 32768)"
# монотонность и «лимит всегда меньше RAM»
for ram in 256 384 512 768 1024 1536 2048 3072 4096 8192 16384 32768 65536; do
  l="$(calc_limit_mib "$ram")"
  [ "$l" -lt "$ram" ] || { FAIL=$((FAIL+1)); echo "  FAIL  лимит $l >= RAM $ram"; }
  [ "$l" -gt 0 ]      || { FAIL=$((FAIL+1)); echo "  FAIL  лимит <= 0 при RAM $ram"; }
done
PASS=$((PASS+1))

echo "== classify_image =="
eq "remnawave/node"        remnanode "$(classify_image 'remnawave/node:latest' 'remnanode')"
eq "панель backend"        panel     "$(classify_image 'remnawave/backend:3' 'remnawave')"
eq "панель postgres"       panel     "$(classify_image 'postgres:18.4' 'remnawave-db')"
eq "панель valkey"         panel     "$(classify_image 'valkey/valkey:9-alpine' 'remnawave-redis')"
eq "панель caddy"          panel     "$(classify_image 'remnawave/caddy-with-auth:latest' 'remnawave-caddy')"
eq "панель sub-page"       panel     "$(classify_image 'remnawave/subscription-page:latest' 'remnawave-subscription-page')"
eq "3x-ui из ghcr"         3x-ui     "$(classify_image 'ghcr.io/mhsanaei/3x-ui:latest' '3xui_app')"
eq "3x-ui собранный"       3x-ui     "$(classify_image '3x-ui-3xui' '3xui_app')"
eq "3x-ui собранный (xui)" 3x-ui     "$(classify_image 'xui-3xui' '3xui_app')"
eq "postgres профиля 3xui" other     "$(classify_image 'postgres:16-alpine' '3xui_postgres')"
eq "marzban"               marzban   "$(classify_image 'gozargah/marzban:latest' 'marzban')"
eq "посторонний nginx"     other     "$(classify_image 'nginx:alpine' 'web')"

echo "== override_path_for =="
eq "docker-compose.yml"  /opt/remnanode/docker-compose.override.yml  "$(override_path_for /opt/remnanode/docker-compose.yml)"
eq "compose.yaml"        /srv/x/compose.override.yaml                "$(override_path_for /srv/x/compose.yaml)"
eq "compose.yml"         /srv/x/compose.override.yml                 "$(override_path_for /srv/x/compose.yml)"
eq "нестандартное имя"   /srv/x/docker-compose.override.yml          "$(override_path_for /srv/x/stack.yml)"

echo "== форматирование =="
eq "fmt_mib 512"   "512 MiB" "$(fmt_mib 512)"
eq "fmt_mib 1024"  "1.0 GiB" "$(fmt_mib 1024)"
eq "fmt_mib 1639"  "1.6 GiB" "$(fmt_mib 1639)"
eq "fmt_bytes 0"   "0 B"     "$(fmt_bytes 0)"
eq "fmt_bytes 1MiB" "1 MiB"  "$(fmt_bytes 1048576)"
eq "fmt_bytes 2GiB" "2.0 GiB" "$(fmt_bytes 2147483648)"

echo "== sysctl-тело =="
body="$(DO_BBR=0 build_sysctl_body)"
eq "есть маркер"     "1" "$(printf '%s' "$body" | grep -c "$MARKER")"
eq "без bbr при --no-bbr" "0" "$(printf '%s' "$body" | grep -c 'congestion_control')"
eq "есть somaxconn"  "1" "$(printf '%s' "$body" | grep -c '^net.core.somaxconn')"
eq "есть swappiness" "1" "$(printf '%s' "$body" | grep -c '^vm.swappiness')"

printf '\n%s пройдено, %s провалено\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
