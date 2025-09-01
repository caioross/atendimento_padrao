#!/usr/bin/env bash
# run.sh — stack Atendimento: n8n + Postgres + Redis + Ollama + Whisper + TTS + Evolution
# Projetado para Windows (Git Bash), macOS e Linux.

set -Eeuo pipefail

# ======================= ESTILO/LOG =======================
BOLD="\e[1m"; DIM="\e[2m"; RESET="\e[0m"
RED="\e[31m"; GRN="\e[32m"; YLW="\e[33m"; CYN="\e[36m"

log() {
  # Remove quaisquer "true/false" perdidos entre os argumentos (evita [INFO]false ...)
  local cleaned=()
  for t in "$@"; do [[ "$t" == "true" || "$t" == "false" ]] || cleaned+=("$t"); done
  local lvl="INFO"
  if ((${#cleaned[@]})); then lvl="${cleaned[0]}"; fi
  local msg=""
  if ((${#cleaned[@]} > 1)); then msg="${cleaned[*]:1}"; fi
  printf "%b[%s]%b %s\n" "$CYN" "$lvl" "$RESET" "$msg"
}
die(){ printf "%b[ERRO]%b %s\n" "$RED" "$RESET" "$*"; exit 1; }

cleanup(){
  local code=$?
  if [[ $code -ne 0 ]]; then
    echo -e "\n${RED}❌ Script terminou com erro ($code).${RESET}"
    echo -e "${DIM}💡 Abrindo shell interativo. Digite 'exit' para sair.${RESET}"
    exec "${SHELL:-bash}" -l
  fi
}
trap cleanup EXIT

# ======================= FLAGS =======================
COMPOSE="docker-compose.yml"
ENV_FILE=".env"; ENV_EX=".env.example"
BUILD=false; UP_ONLY=false; RESET=false; STATUS=false; NONINT=false; LOGS=false
for arg in "$@"; do case "$arg" in
  --build) BUILD=true;;
  --up)    UP_ONLY=true;;
  --reset) RESET=true;;
  --status) STATUS=true;;
  --non-interactive) NONINT=true;;
  --logs) LOGS=true;;
  *) log WARN "Flag desconhecida: $arg";;
esac; done

# ======================= PRÉ-CHECAGENS =======================
command -v docker >/dev/null || die "docker não encontrado"
docker compose version >/dev/null 2>&1 || die "'docker compose' indisponível"

[[ -f "$ENV_FILE" ]] || { [[ -f "$ENV_EX" ]] && cp "$ENV_EX" "$ENV_FILE"; }
[[ -f "$ENV_FILE" ]] || die "faltando .env (ou .env.example)"

# normaliza CRLF -> LF
if command -v dos2unix >/dev/null 2>&1; then dos2unix -q "$ENV_FILE" || true; else sed -i 's/\r$//' "$ENV_FILE"; fi

docker compose -f "$COMPOSE" config -q || die "YAML inválido"
mkdir -p ./tmp/news

# ======================= HELPERS =======================
require_env(){
  local var="$1"
  grep -qE "^${var}=" "$ENV_FILE" || die "variável $var ausente no .env"
}

load_env(){
  while IFS='=' read -r k v; do
    [[ -z "${k// }" || "${k:0:1}" == "#" ]] && continue
    export "$k=$v"
  done < "$ENV_FILE"
}

is_port_used(){
  local p="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$p$"
  else
    netstat -ano 2>/dev/null | tr -d '\r' | grep -qE "[:.]$p[[:space:]]"
  fi
}

find_free_port(){
  local start="${1:-1024}"
  [[ -z "$start" || "$start" -lt 1 ]] && start=1024
  local p="$start"
  while is_port_used "$p"; do p=$((p+1)); done
  echo "$p"
}

wait_on(){
  # Aguarda health=healthy OU state=running (quando não há healthcheck)
  local name="$1" timeout="${2:-180}" interval="${3:-5}"
  local elapsed=0 status=""
  while (( elapsed < timeout )); do
    status=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$name" 2>/dev/null || echo "unavailable")
    case "$status" in
      healthy|running) log OK "✅ $name pronto ($status)"; return 0;;
      starting) log INFO "aguardando $name ($status)";;
      *) log INFO "aguardando $name ($status)";;
    esac
    sleep "$interval"; ((elapsed+=interval))
  done
  echo
  log ERROR "⏰ timeout esperando $name ficar pronto"
  echo -e "${DIM}─ Logs recentes ($name) ─────────────────────────────────────${RESET}"
  docker logs --tail 120 "$name" 2>&1 || true
  echo -e "${DIM}─────────────────────────────────────────────────────────────${RESET}"
  return 1
}

http_ok(){
  local url="$1"
  if command -v curl >/dev/null 2>&1; then
    curl -fsS -o /dev/null "$url"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO- "$url" >/dev/null
  else
    return 2   # nenhum cliente HTTP disponível
  fi
}

wait_http(){
  local timeout="${1:-60}" interval="${2:-3}"; shift 2 || true
  local urls=("$@")
  local elapsed=0
  while (( elapsed < timeout )); do
    for u in "${urls[@]}"; do
      if http_ok "$u"; then
        log OK "✅ HTTP OK: $u"
        return 0
      fi
    done
    log INFO "aguardando HTTP ${urls[*]}"
    sleep "$interval"; ((elapsed+=interval))
  done
  return 1
}

wait_tcp(){
  # Aguarda o socket TCP ficar disponível (sem exigir HTTP)
  local host="$1" port="$2" timeout="${3:-60}" interval="${4:-2}"
  local elapsed=0 ok=1
  while (( elapsed < timeout )); do
    if command -v nc >/dev/null 2>&1; then
      nc -z "$host" "$port" >/dev/null 2>&1 && ok=0 || ok=$?
    elif bash -lc 'true' >/dev/null 2>&1; then
      # /dev/tcp do bash
      (echo >/dev/tcp/"$host"/"$port") >/dev/null 2>&1 && ok=0 || ok=$?
    elif command -v powershell.exe >/dev/null 2>&1; then
      powershell.exe -NoLogo -NoProfile -Command "exit ((Test-NetConnection -ComputerName '$host' -Port $port -WarningAction SilentlyContinue).TcpTestSucceeded -eq \$true ? 0 : 1)" && ok=0 || ok=$?
    else
      ok=1
    fi
    if [[ $ok -eq 0 ]]; then
      log OK "✅ TCP OK: $host:$port"
      return 0
    fi
    log INFO "aguardando TCP $host:$port"
    sleep "$interval"; ((elapsed+=interval))
  done
  return 1
}

update_env_value(){
  local var="$1" val="$2"
  if grep -qE "^${var}=" "$ENV_FILE"; then
    sed -e "s|^${var}=.*|${var}=${val}|" -i.bak "$ENV_FILE" && rm -f "${ENV_FILE}.bak"
  else
    echo "${var}=${val}" >> "$ENV_FILE"
  fi
}

# ======================= AÇÕES RÁPIDAS =======================
if $RESET; then
  log INFO "Derrubando stack e volumes..."
  docker compose -f "$COMPOSE" down -v --remove-orphans
  exit 0
fi

if $STATUS; then
  docker compose -f "$COMPOSE" ps || true
  exit 0
fi

# ======================= VALIDA ENV & CHAVES =======================
require_env POSTGRES_USER
require_env POSTGRES_PASSWORD
require_env POSTGRES_DB
require_env N8N_BASIC_AUTH_USER
require_env N8N_BASIC_AUTH_PASSWORD

if ! grep -q '^N8N_ENCRYPTION_KEY=' "$ENV_FILE"; then
  log INFO "Gerando N8N_ENCRYPTION_KEY no .env..."
  if command -v openssl >/dev/null 2>&1; then
    echo "N8N_ENCRYPTION_KEY=$(openssl rand -hex 32)" >> "$ENV_FILE"
  else
    echo "N8N_ENCRYPTION_KEY=$(python - <<'PY' 2>/dev/null
import os, binascii; print(binascii.hexlify(os.urandom(32)).decode())
PY
    )" >> "$ENV_FILE"
  fi
fi

load_env

# ======================= PORT-MAP INTELIGENTE =======================
PORT_N8N_DEF=5678;      CPORT_N8N=5678
PORT_OLLAMA_DEF=11434;  CPORT_OLLAMA=11434
PORT_WHISPER_DEF=9000;  CPORT_WHISPER=9000
PORT_TTS_DEF=5000;      CPORT_TTS=5000
PORT_EVO_DEF=8085;      CPORT_EVO=8080
PORT_PG_DEF=5432;       CPORT_PG=5432
PORT_REDIS_DEF=6379;    CPORT_REDIS=6379

OVR=".compose-override.auto.yml"
: > "$OVR"
OVR_CHANGED=false
OVR_INIT=false

ensure_ovr_header(){ if ! $OVR_INIT; then echo "services:" >> "$OVR"; OVR_INIT=true; fi; }

add_override_ports(){
  local svc="$1"; shift
  ensure_ovr_header
  echo "  $svc:" >> "$OVR"
  echo "    ports:" >> "$OVR"
  while read -r line; do [[ -z "$line" ]] && continue; echo "      - \"$line\"" >> "$OVR"; done <<< "$*"
  OVR_CHANGED=true
}
remove_override_ports(){
  local svc="$1"
  ensure_ovr_header
  { echo "  $svc:"; echo "    ports: []"; } >> "$OVR"
  OVR_CHANGED=true
}

PG_EXPOSED=true
REDIS_EXPOSED=true

PORT_N8N="$PORT_N8N_DEF"
if is_port_used "$PORT_N8N_DEF"; then
  PORT_N8N="$(find_free_port $((PORT_N8N_DEF+1)))"
  log WARN "Porta $PORT_N8N_DEF ocupada; n8n em $PORT_N8N -> $CPORT_N8N"
  add_override_ports "atendimento-core" "$PORT_N8N:$CPORT_N8N"
  if grep -qE '^WEBHOOK_URL=http://localhost:' "$ENV_FILE"; then
    update_env_value WEBHOOK_URL "http://localhost:${PORT_N8N}/webhook-test/whatsapp-input"
  fi
fi

PORT_EVO="$PORT_EVO_DEF"
if is_port_used "$PORT_EVO_DEF"; then
  PORT_EVO="$(find_free_port $((PORT_EVO_DEF+1)))"
  log WARN "Porta $PORT_EVO_DEF ocupada; Evolution em $PORT_EVO -> $CPORT_EVO"
  add_override_ports "evolution-api" "$PORT_EVO:$CPORT_EVO"
fi

PORT_OLLAMA="$PORT_OLLAMA_DEF"
if is_port_used "$PORT_OLLAMA_DEF"; then
  PORT_OLLAMA="$(find_free_port $((PORT_OLLAMA_DEF+1)))"
  log WARN "Porta $PORT_OLLAMA_DEF ocupada; Ollama em $PORT_OLLAMA -> $CPORT_OLLAMA"
  add_override_ports "llm-ollama" "$PORT_OLLAMA:$CPORT_OLLAMA"
fi

PORT_WHISPER="$PORT_WHISPER_DEF"
if is_port_used "$PORT_WHISPER_DEF"; then
  PORT_WHISPER="$(find_free_port $((PORT_WHISPER_DEF+1)))"
  log WARN "Porta $PORT_WHISPER_DEF ocupada; Whisper em $PORT_WHISPER -> $CPORT_WHISPER"
  add_override_ports "whisper" "$PORT_WHISPER:$CPORT_WHISPER"
fi

PORT_TTS="$PORT_TTS_DEF"
if is_port_used "$PORT_TTS_DEF"; then
  PORT_TTS="$(find_free_port $((PORT_TTS_DEF+1)))"
  log WARN "Porta $PORT_TTS_DEF ocupada; TTS em $PORT_TTS -> $CPORT_TTS"
  add_override_ports "tts" "$PORT_TTS:$CPORT_TTS"
fi

# Postgres/Redis – se conflito, não expõe (rede Docker resolve)
if is_port_used "$PORT_PG_DEF"; then
  log WARN "Porta $PORT_PG_DEF ocupada; removendo exposição externa do Postgres"
  remove_override_ports "postgree"; PG_EXPOSED=false
fi
if is_port_used "$PORT_REDIS_DEF"; then
  log WARN "Porta $PORT_REDIS_DEF ocupada; removendo exposição externa do Redis"
  remove_override_ports "redis"; REDIS_EXPOSED=false
fi

COMPOSE_ARGS=( -f "$COMPOSE" )
$OVR_CHANGED && COMPOSE_ARGS+=( -f "$OVR" )

# ======================= PULL/BUILD =======================
if ! $UP_ONLY; then
  if $BUILD; then
    log INFO "Build das imagens locais (--build)"
    docker compose "${COMPOSE_ARGS[@]}" build
  else
    log INFO "Pull das imagens"
    docker compose "${COMPOSE_ARGS[@]}" pull || log WARN "pull falhou; seguindo com imagens locais"
  fi
else
  log INFO "--up: pulando pull/build"
fi

# ======================= SUBIR DEPENDÊNCIAS =======================
log INFO "Subindo dependências: Postgres, Redis, Ollama, Whisper e TTS..."
docker compose "${COMPOSE_ARGS[@]}" up -d postgree redis llm-ollama whisper tts --remove-orphans

# DB e Redis com healthcheck
wait_on "atendimento-DB" 180    || die "Postgres não ficou pronto"
wait_on "atendimento-redis" 120 || die "Redis não ficou pronto"

# Ollama por HTTP (tem endpoint)
if ! wait_http 120 3 \
  "http://localhost:${PORT_OLLAMA}/api/tags" \
  "http://127.0.0.1:${PORT_OLLAMA}/api/tags"
then
  # fallback CLI
  docker exec atendimento-Ollama ollama list >/dev/null 2>&1 || die "Ollama não respondeu em HTTP nem via CLI"
  log OK "✅ Ollama OK via CLI"
fi

# Whisper (STT) e TTS podem não responder GET; verificar apenas o socket TCP
wait_tcp "127.0.0.1" "${PORT_WHISPER}" 120 2 || die "Whisper (STT) não abriu a porta ${PORT_WHISPER}"
wait_tcp "127.0.0.1" "${PORT_TTS}"     120 2 || die "TTS não abriu a porta ${PORT_TTS}"

# ======================= GARANTIR DB =======================
DB_CONT="atendimento-DB"
log INFO "Conferindo banco '${POSTGRES_DB}'..."
EXISTS=$(docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" "$DB_CONT" \
  psql -U "$POSTGRES_USER" -tAc "SELECT 1 FROM pg_database WHERE datname='${POSTGRES_DB}';" || echo "")
if [[ "$EXISTS" != "1" ]]; then
  log INFO "Criando banco '${POSTGRES_DB}'..."
  docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" "$DB_CONT" \
    psql -U "$POSTGRES_USER" -c "CREATE DATABASE \"${POSTGRES_DB}\";"
  log OK "Banco '${POSTGRES_DB}' criado."
else
  log OK "Banco '${POSTGRES_DB}' já existe."
fi

# ======================= OLLAMA: MODELOS =======================
OLLAMA_CONT="atendimento-Ollama"
MODELS=("${MODEL_NAME:-llama3}" "llama3.1:8b" "llama3.2")
log INFO "Checando modelos no Ollama..."
for m in "${MODELS[@]}"; do
  [[ -z "$m" ]] && continue
  if docker exec "$OLLAMA_CONT" ollama list | awk '{print $1}' | grep -qx "$m"; then
    log OK "modelo '$m' já disponível"
  else
    log INFO "baixando modelo '$m'..."
    docker exec "$OLLAMA_CONT" ollama pull "$m"
    log OK "modelo '$m' disponível"
  fi
done

# ======================= SOBE n8n + EVOLUTION =======================
log INFO "Subindo n8n e Evolution API..."
docker compose "${COMPOSE_ARGS[@]}" up -d atendimento-core evolution-api

wait_on "atendimento-n8n" 180 || die "n8n não ficou pronto"
wait_on "atendimento-EvolutionAPI" 180 || die "Evolution API não ficou pronta"

# ======================= RESUMO / LOGS =======================
echo -e "\n📊 ${BOLD}RESUMO${RESET}"
if ! docker compose "${COMPOSE_ARGS[@]}" ps --format "table {{.Name}}\t{{.State}}\t{{.Ports}}" 2>/dev/null; then
  docker compose "${COMPOSE_ARGS[@]}" ps
fi

PG_STATUS=$($PG_EXPOSED && echo "localhost:${PORT_PG_DEF}" || echo "não exposto")
REDIS_STATUS=$($REDIS_EXPOSED && echo "localhost:${PORT_REDIS_DEF}" || echo "não exposto")

cat <<EOF

🌐 ENDPOINTS (host → container)
  n8n           → http://localhost:${PORT_N8N}        (-> 5678)
  Evolution API → http://localhost:${PORT_EVO}        (-> 8080)
  Whisper (STT) → tcp://localhost:${PORT_WHISPER}     (-> 9000)
  TTS           → tcp://localhost:${PORT_TTS}         (-> 5000)
  Ollama        → http://localhost:${PORT_OLLAMA}     (-> 11434)
  Postgres      → ${PG_STATUS}
  Redis         → ${REDIS_STATUS}

Dicas:
  • Serviços internos usam DNS do Compose: http://redis:6379, http://postgree:5432, http://atendimento-core:5678.
  • Se alterei a porta do n8n, atualizei WEBHOOK_URL no .env.
  • Ver logs: ./run.sh --logs
EOF

if $LOGS; then
  echo -e "\n${DIM}▸ Ctrl+C para sair dos logs.${RESET}"
  docker compose "${COMPOSE_ARGS[@]}" logs -f --tail=200
fi

$NONINT && exit 0 || true
