#!/bin/bash
# =============================================================================
# deploy.sh - Deploiement / mise a jour Kafka UI sur VPS
#
# Ce script :
#   - clone le repo au premier lancement dans /opt/kafka_ui
#   - recupere les mises a jour aux lancements suivants
#   - rebuild et redemarre les conteneurs si necessaire
#   - prepare Nginx en HTTP uniquement
# =============================================================================

set -e

# Couleurs
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${BLUE}[deploy]${NC} $1"; }
ok()   { echo -e "${GREEN}[ok]${NC}     $1"; }
warn() { echo -e "${YELLOW}[warn]${NC}   $1"; }
err()  { echo -e "${RED}[erreur]${NC} $1"; exit 1; }
info() { echo -e "${CYAN}[info]${NC}   $1"; }

# Config
REPO_URL="https://github.com/Marlin241/kafka_ui.git"
APP_DIR="/opt/kafka_ui"
PRODUCER_DOMAIN="producer.digitalko.space"
CONSUMER_DOMAIN="consumer.digitalko.space"
PRODUCER_PORT="5002"
CONSUMER_PORT="5003"
NGINX_AVAILABLE="/etc/nginx/sites-available"
NGINX_ENABLED="/etc/nginx/sites-enabled"

# Detection Docker Compose
if docker compose version >/dev/null 2>&1; then
  COMPOSE="docker compose"
elif docker-compose version >/dev/null 2>&1; then
  COMPOSE="docker-compose"
else
  err "Docker Compose introuvable. Lancez : apt install docker-compose-plugin"
fi

# =============================================================================
# ETAPE 1 - Prerequis
# =============================================================================
log "Verification des prerequis..."

command -v docker >/dev/null 2>&1 || err "Docker n'est pas installe."
command -v git    >/dev/null 2>&1 || err "Git n'est pas installe. Lancez : apt install git"
command -v nginx  >/dev/null 2>&1 || err "Nginx n'est pas installe."

ok "Prerequis OK"

# =============================================================================
# ETAPE 2 - Recuperation du code (clone ou pull)
# =============================================================================
if [ ! -d "$APP_DIR/.git" ]; then
  log "Dossier $APP_DIR absent ou non initialise, clonage du repo..."
  rm -rf "$APP_DIR"
  git clone "$REPO_URL" "$APP_DIR"
  ok "Repo clone dans $APP_DIR"
  CODE_CHANGED=true
else
  log "Repo existant detecte, verification des mises a jour..."
  cd "$APP_DIR"

  git fetch origin 2>/dev/null

  LOCAL=$(git rev-parse HEAD)
  REMOTE=$(git rev-parse '@{u}' 2>/dev/null || echo "unknown")

  if [ "$LOCAL" = "$REMOTE" ]; then
    info "Code deja a jour (commit : ${LOCAL:0:8})"
    CODE_CHANGED=false
  else
    info "Nouveau(x) commit(s) detecte(s)"
    info "  Local  : ${LOCAL:0:8}"
    info "  Remote : ${REMOTE:0:8}"
    git pull --rebase
    ok "Code mis a jour -> commit ${REMOTE:0:8}"
    CODE_CHANGED=true
  fi
fi

cd "$APP_DIR"

# =============================================================================
# ETAPE 3 - Build et redemarrage Docker
# =============================================================================
if [ "$CODE_CHANGED" = true ]; then
  log "Reconstruction des images Docker..."
  $COMPOSE down --remove-orphans 2>/dev/null || true
  $COMPOSE build --no-cache
  $COMPOSE up -d
  ok "Conteneurs redemarres avec la nouvelle version"
else
  RUNNING=$($COMPOSE ps --services --filter "status=running" 2>/dev/null | wc -l)
  if [ "$RUNNING" -lt 3 ]; then
    warn "Conteneurs non actifs malgre code a jour, redemarrage..."
    $COMPOSE up -d
    ok "Conteneurs demarres"
  else
    ok "Conteneurs deja actifs, rien a faire"
  fi
fi

# =============================================================================
# ETAPE 4 - Attente que les apps repondent
# =============================================================================
log "Attente du demarrage des apps (max 60s)..."

READY_P=false
READY_C=false
STATUS_P="000"
STATUS_C="000"

for i in $(seq 1 20); do
  sleep 3
  if [ "$READY_P" = false ]; then
    STATUS_P=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:${PRODUCER_PORT}/ 2>/dev/null || echo "000")
    [ "$STATUS_P" = "200" ] && READY_P=true && ok "Producer (${PRODUCER_PORT}) : HTTP 200"
  fi
  if [ "$READY_C" = false ]; then
    STATUS_C=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:${CONSUMER_PORT}/ 2>/dev/null || echo "000")
    [ "$STATUS_C" = "200" ] && READY_C=true && ok "Consumer (${CONSUMER_PORT}) : HTTP 200"
  fi
  [ "$READY_P" = true ] && [ "$READY_C" = true ] && break
  log "Tentative $i/20 - Producer: ${STATUS_P} | Consumer: ${STATUS_C}"
done

[ "$READY_P" = false ] && warn "Producer ne repond pas sur le port ${PRODUCER_PORT} - verifiez : $COMPOSE logs producer"
[ "$READY_C" = false ] && warn "Consumer ne repond pas sur le port ${CONSUMER_PORT} - verifiez : $COMPOSE logs consumer"

# =============================================================================
# ETAPE 5 - Config Nginx
# =============================================================================

# N'ecrit la config Nginx que lors de la premiere execution.
# Les changements ulterieurs restent manuels.
write_nginx_if_needed() {
  local FILE="$1"
  local CONTENT="$2"

  if [ -f "$FILE" ]; then
    info "Config $FILE deja presente, non modifiee"
  else
    printf '%s\n' "$CONTENT" > "$FILE"
    ok "Config Nginx ecrite : $FILE"
  fi
}

log "Configuration Nginx..."

PRODUCER_CONF="server {
    listen 80;
    server_name ${PRODUCER_DOMAIN};

    location / {
        proxy_pass         http://127.0.0.1:${PRODUCER_PORT};
        proxy_set_header   Host \$host;
        proxy_set_header   X-Real-IP \$remote_addr;
        proxy_set_header   X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto \$scheme;
        proxy_buffering    off;
        proxy_read_timeout 120s;
    }
}"

CONSUMER_CONF="server {
    listen 80;
    server_name ${CONSUMER_DOMAIN};

    location / {
        proxy_pass                 http://127.0.0.1:${CONSUMER_PORT};
        proxy_set_header           Host \$host;
        proxy_set_header           X-Real-IP \$remote_addr;
        proxy_set_header           X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header           X-Forwarded-Proto \$scheme;
        proxy_buffering            off;
        proxy_cache                off;
        proxy_read_timeout         3600s;
        proxy_http_version         1.1;
        proxy_set_header           Connection '';
        chunked_transfer_encoding  on;
    }
}"

write_nginx_if_needed "$NGINX_AVAILABLE/$PRODUCER_DOMAIN" "$PRODUCER_CONF"
write_nginx_if_needed "$NGINX_AVAILABLE/$CONSUMER_DOMAIN" "$CONSUMER_CONF"

ln -sf "$NGINX_AVAILABLE/$PRODUCER_DOMAIN" "$NGINX_ENABLED/$PRODUCER_DOMAIN"
ln -sf "$NGINX_AVAILABLE/$CONSUMER_DOMAIN" "$NGINX_ENABLED/$CONSUMER_DOMAIN"

nginx -t || err "Config Nginx invalide - verifiez les fichiers dans $NGINX_AVAILABLE"
systemctl reload nginx
ok "Nginx recharge"

# =============================================================================
# RESUME
# =============================================================================
echo ""
echo -e "${GREEN}==========================================${NC}"
echo -e "${GREEN}  Deploiement termine${NC}"
if [ "$CODE_CHANGED" = true ]; then
  echo -e "${GREEN}  Mise a jour appliquee${NC}"
else
  echo -e "${GREEN}  Aucune modification de code${NC}"
fi
echo -e "${GREEN}==========================================${NC}"
echo ""
echo -e "  Producer  ->  http://${PRODUCER_DOMAIN}"
echo -e "  Consumer  ->  http://${CONSUMER_DOMAIN}"
echo ""
echo -e "Commandes utiles :"
echo -e "  ${CYAN}cd $APP_DIR && $COMPOSE logs -f${NC}"
echo -e "  ${CYAN}cd $APP_DIR && $COMPOSE ps${NC}"
echo -e "  ${CYAN}cd $APP_DIR && $COMPOSE restart producer${NC}"
echo ""
