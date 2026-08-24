#!/usr/bin/env bash
# Проверка выбора цели и генерации override на подставном `docker`.
HUBTUNE_LIB=1 . "$(dirname "$0")/../hubtune.sh"

PASS=0; FAIL=0
eq() { if [ "$2" = "$3" ]; then PASS=$((PASS+1))
       else FAIL=$((FAIL+1)); printf '  FAIL  %s\n        ожидал [%s]\n        получил[%s]\n' "$1" "$2" "$3"; fi; }

TAB=$'\t'
FAKE_PS=""
docker() {                      # подставляем docker целиком
    case "$1 $2" in
        "ps -a") printf '%s\n' "$FAKE_PS" ;;
        *) return 1 ;;
    esac
}
reset() {
    TG_MODE=""; TG_KIND=""; TG_LABEL=""; TG_CONTAINER=""; TG_IMAGE=""
    TG_SERVICE=""; TG_WORKDIR=""; TG_BASEFILE=""; TG_CONFIGS=""; TG_OVERRIDE=""; PANEL_SEEN=0
    OPT_TARGET=""
}

echo "== хост ноды Remnawave =="
reset
FAKE_PS="remnanode${TAB}remnawave/node:latest${TAB}remnanode${TAB}remnanode${TAB}/opt/remnanode${TAB}/opt/remnanode/docker-compose.yml${TAB}running"
if detect_docker_target; then rc=0; else rc=$?; fi
eq "цель найдена"    "0"          "$rc"
eq "kind"            "remnanode"  "$TG_KIND"
eq "контейнер"       "remnanode"  "$TG_CONTAINER"
eq "сервис"          "remnanode"  "$TG_SERVICE"
eq "панель не видна" "0"          "$PANEL_SEEN"

echo "== хост панели Remnawave (ноды нет) =="
reset
FAKE_PS="remnawave${TAB}remnawave/backend:3${TAB}remnawave${TAB}backend${TAB}/opt/remnawave${TAB}/opt/remnawave/docker-compose.yml${TAB}running
remnawave-db${TAB}postgres:18.4${TAB}remnawave${TAB}db${TAB}/opt/remnawave${TAB}/opt/remnawave/docker-compose.yml${TAB}running
remnawave-redis${TAB}valkey/valkey:9-alpine${TAB}remnawave${TAB}redis${TAB}/opt/remnawave${TAB}/opt/remnawave/docker-compose.yml${TAB}running
remnawave-caddy${TAB}remnawave/caddy-with-auth:latest${TAB}remnawave${TAB}caddy${TAB}/opt/remnawave${TAB}/opt/remnawave/docker-compose.yml${TAB}running"
if detect_docker_target; then rc=0; else rc=$?; fi
eq "цель НЕ выбрана автоматически" "1" "$rc"
eq "панель распознана"             "1" "$PANEL_SEEN"

echo "== панель и нода на одном хосте: выбирается нода =="
reset
FAKE_PS="remnawave${TAB}remnawave/backend:3${TAB}remnawave${TAB}backend${TAB}/opt/remnawave${TAB}/opt/remnawave/docker-compose.yml${TAB}running
remnawave-db${TAB}postgres:18.4${TAB}remnawave${TAB}db${TAB}/opt/remnawave${TAB}/opt/remnawave/docker-compose.yml${TAB}running
remnanode${TAB}remnawave/node:latest${TAB}remnanode${TAB}remnanode${TAB}/opt/remnanode${TAB}/opt/remnanode/docker-compose.yml${TAB}running"
detect_docker_target
eq "выбрана нода"        "remnanode" "$TG_CONTAINER"
eq "панель замечена"     "1"         "$PANEL_SEEN"

echo "== 3x-ui в docker (локальная сборка + postgres из профиля) =="
reset
FAKE_PS="3xui_app${TAB}3x-ui-3xui${TAB}3x-ui${TAB}3xui${TAB}/root/3x-ui${TAB}/root/3x-ui/docker-compose.yml${TAB}running
3xui_postgres${TAB}postgres:16-alpine${TAB}3x-ui${TAB}postgres${TAB}/root/3x-ui${TAB}/root/3x-ui/docker-compose.yml${TAB}running"
detect_docker_target
eq "выбран 3x-ui, не postgres" "3xui_app" "$TG_CONTAINER"
eq "kind"                      "3x-ui"    "$TG_KIND"
eq "имя сервиса из метки"      "3xui"     "$TG_SERVICE"

echo "== посторонние контейнеры игнорируются =="
reset
FAKE_PS="web${TAB}nginx:alpine${TAB}site${TAB}web${TAB}/srv/site${TAB}/srv/site/compose.yaml${TAB}running
cache${TAB}redis:7${TAB}site${TAB}cache${TAB}/srv/site${TAB}/srv/site/compose.yaml${TAB}running"
if detect_docker_target; then rc=0; else rc=$?; fi
eq "ничего не выбрано" "1" "$rc"

echo "== --target по имени поднимает посторонний контейнер =="
reset; OPT_TARGET="web"
FAKE_PS="web${TAB}nginx:alpine${TAB}site${TAB}web${TAB}/srv/site${TAB}/srv/site/compose.yaml${TAB}running
cache${TAB}redis:7${TAB}site${TAB}cache${TAB}/srv/site${TAB}/srv/site/compose.yaml${TAB}running"
detect_docker_target
eq "выбран web"        "web"  "$TG_CONTAINER"
eq "сервис web"        "web"  "$TG_SERVICE"

echo "== --target по ключевому слову =="
reset; OPT_TARGET="3x-ui"
FAKE_PS="remnanode${TAB}remnawave/node:latest${TAB}remnanode${TAB}remnanode${TAB}/opt/remnanode${TAB}/opt/remnanode/docker-compose.yml${TAB}running
3xui_app${TAB}ghcr.io/mhsanaei/3x-ui:latest${TAB}xui${TAB}3xui${TAB}/root/xui${TAB}/root/xui/compose.yml${TAB}running"
detect_docker_target
eq "выбран 3x-ui несмотря на ноду" "3xui_app" "$TG_CONTAINER"

echo "== генерация override =="
tmp="$(mktemp -d)"
reset
TG_SERVICE="remnanode"; TG_BASEFILE="$tmp/docker-compose.yml"; TG_OVERRIDE="$tmp/docker-compose.override.yml"
PLAN_MEM_MIB=1639; PLAN_MEMSW=1; PLAN_LOGS=1; PLAN_NOFILE=0; PLAN_RESTART=0; CUR_MEM_LIMIT=0
: > "$TG_BASEFILE"
write_override
eq "маркер на месте"   "1"       "$(grep -c "$MARKER" "$TG_OVERRIDE")"
eq "mem_limit"         "1639m"   "$(awk '/mem_limit:/{print $2; exit}' "$TG_OVERRIDE")"
eq "memswap_limit"     "1639m"   "$(awk '/memswap_limit:/{print $2; exit}' "$TG_OVERRIDE")"
eq "сервис из метки"   "1"       "$(grep -c '^  remnanode:$' "$TG_OVERRIDE")"
eq "ротация логов"     "1"       "$(grep -c 'max-size: "10m"' "$TG_OVERRIDE")"
eq "restart не лезет"  "0"       "$(grep -c 'restart:' "$TG_OVERRIDE")"
eq "ulimits не лезут"  "0"       "$(grep -c 'nofile' "$TG_OVERRIDE")"

# только логи: существующий лимит должен сохраниться, а не пропасть
PLAN_MEM_MIB=0; PLAN_LOGS=1; CUR_MEM_LIMIT=$((512*1048576))
write_override
eq "старый лимит сохранён" "512m" "$(awk '/mem_limit:/{print $2; exit}' "$TG_OVERRIDE")"

# менять нечего -> пустой блок сервиса не пишется
PLAN_MEM_MIB=0; PLAN_LOGS=0; PLAN_NOFILE=0; PLAN_RESTART=0
if service_has_changes; then FAIL=$((FAIL+1)); echo "  FAIL  service_has_changes вернул да на пустом плане"
else PASS=$((PASS+1)); fi
rm -rf "$tmp"

echo "== живой контейнер выигрывает у мёртвого =="
reset
FAKE_PS="remnanode-old${TAB}remnawave/node:latest${TAB}old${TAB}remnanode${TAB}/opt/old${TAB}/opt/old/docker-compose.yml${TAB}exited
remnanode${TAB}remnawave/node:latest${TAB}remnanode${TAB}remnanode${TAB}/opt/remnanode${TAB}/opt/remnanode/docker-compose.yml${TAB}running"
detect_docker_target
eq "выбран запущенный" "remnanode" "$TG_CONTAINER"

echo "== две живые ноды: молча выбирать нельзя =="
out="$( reset
        FAKE_PS="node-a${TAB}remnawave/node:latest${TAB}a${TAB}remnanode${TAB}/opt/a${TAB}/opt/a/docker-compose.yml${TAB}running
node-b${TAB}remnawave/node:latest${TAB}b${TAB}remnanode${TAB}/opt/b${TAB}/opt/b/docker-compose.yml${TAB}running"
        detect_docker_target 2>&1 )" && rc=0 || rc=$?
eq "скрипт остановился"      "1" "$rc"
eq "обе ноды перечислены"    "2" "$(printf '%s' "$out" | grep -c -- '--target node-')"

echo "== многофайловый проект: сохраняются все файлы =="
reset
FAKE_PS="remnanode${TAB}remnawave/node:latest${TAB}remnanode${TAB}remnanode${TAB}/opt/remnanode${TAB}/opt/remnanode/docker-compose.yml,/opt/remnanode/docker-compose.prod.yml${TAB}running"
detect_docker_target
eq "базовый файл — первый" "/opt/remnanode/docker-compose.yml" "$TG_BASEFILE"
eq "список файлов целиком" "/opt/remnanode/docker-compose.yml,/opt/remnanode/docker-compose.prod.yml" "$TG_CONFIGS"

printf '\n%s пройдено, %s провалено\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
