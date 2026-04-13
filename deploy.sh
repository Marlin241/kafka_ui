#!/bin/bash
# =============================================================================
#  deploy.sh — Déploiement / mise à jour Kafka UI sur VPS
#
#  Ce script est auto-suffisant :
#    - 1er run  : clone le repo depuis GitHub et déploie tout
#    - Runs suivants : pull les changements et redémarre si nécessaire
#
#  Usage : sudo bash deploy.sh
# =============================================================================

set -e

# ── Couleurs ──────────────────────────────────────────────────
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

# ── Config ────────────────────────────────────────────────────
REPO_URL="https://github.com/Marlin241/kafka_ui.git"
APP_DIR="/opt/kafka-ui"
PRODUCER_DOMAIN="producer.digitalko.space"
CONSUMER_DOMAIN="consumer.digitalko.space"
PRODUCER_PORT="5002"
CONSUMER_PORT="5003"
NGINX_AVAILABLE="/etc/nginx/sites-available"
NGINX_ENABLED="/etc/nginx/sites-enabled"
CERTBOT_EMAIL="admin@digitalko.space"

# ── Détection Docker Compose ──────────────────────────────────
if docker compose version >/dev/null 2>&1; then
  COMPOSE="docker compose"
elif docker-compose version >/dev/null 2>&1; then
  COMPOSE="docker-compose"
else
  err "Docker Compose introuvable. Installez-le avec : apt install docker-compose-plugin"
fi

# =============================================================================
#  ÉTAPE 1 — Prérequis
# =============================================================================
log "Vérification des prérequis..."

command -v docker  >/dev/null 2>&1 || err "Docker n'est pas installé."
command -v git     >/dev/null 2>&1 || err "Git n'est pas installé. Lancez : apt install git"
command -v nginx   >/dev/null 2>&1 || err "Nginx n'est pas installé."
command -v certbot >/dev/null 2>&1 || err "Certbot n'est pas installé. Lancez : apt install certbot python3-certbot-nginx"

ok "Prérequis OK"

# =============================================================================
#  ÉTAPE 2 — Récupération du code (clone ou pull)
# =============================================================================

if [ ! -d "$APP_DIR/.git" ]; then
  # ── Premier déploiement : clone complet ──────────────────────
  log "Dossier $APP_DIR absent ou non initialisé, clonage du repo..."
  rm -rf "$APP_DIR"
  git clone "$REPO_URL" "$APP_DIR"
  ok "Repo cloné dans $APP_DIR"
  CODE_CHANGED=true
else
  # ── Déploiements suivants : pull et détection de changements ─
  log "Repo existant détecté, vérification des mises à jour..."
  cd "$APP_DIR"

  # Récupère les infos distantes sans merger
  git fetch origin main 2>/dev/null || git fetch origin master 2>/dev/null || git fetch origin

  LOCAL=$(git rev-parse HEAD)
  REMOTE=$(git rev-parse '@{u}' 2>/dev/null || echo "unknown")

  if [ "$LOCAL" = "$REMOTE" ]; then
    info "Code déjà à jour (commit : ${LOCAL:0:8})"
    CODE_CHANGED=false
  else
    info "Nouveau(x) commit(s) détecté(s)"
    info "  Local  : ${LOCAL:0:8}"
    info "  Remote : ${REMOTE:0:8}"
    git pull --rebase origin main 2>/dev/null || git pull --rebase origin master 2>/dev/null || git pull
    ok "Code mis à jour → commit ${REMOTE:0:8}"
    CODE_CHANGED=true
  fi
fi

cd "$APP_DIR"

# =============================================================================
#  ÉTAPE 3 — Build et redémarrage Docker
# =============================================================================

if [ "$CODE_CHANGED" = true ]; then
  log "Reconstruction des images Docker..."
  $COMPOSE down --remove-orphans 2>/dev/null || true
  $COMPOSE build --no-cache
  $COMPOSE up -d
  ok "Conteneurs redémarrés avec la nouvelle version"
else
  # Vérifie quand même que les conteneurs tournent
  RUNNING=$($COMPOSE ps --services --filter "status=running" 2>/dev/null | wc -l)
  if [ "$RUNNING" -lt 3 ]; then
    warn "Conteneurs non actifs malgré code à jour, redémarrage..."
    $COMPOSE up -d
    ok "Conteneurs démarrés"
  else
    ok "Conteneurs déjà actifs, rien à faire"
  fi
fi

# =============================================================================
#  ÉTAPE 4 — Attente que les apps répondent
# =============================================================================
log "Attente du démarrage des apps (max 60s)..."

READY_P=false
READY_C=false

for i in $(seq 1 20); do
  sleep 3
  if ! $READY_P; then
    STATUS_P=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:${PRODUCER_PORT}/ 2>/dev/null || echo "000")
    [ "$STATUS_P" = "200" ] && READY_P=true && ok "Producer (${PRODUCER_PORT}) : HTTP 200"
  fi
  if ! $READY_C; then
    STATUS_C=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:${CONSUMER_PORT}/ 2>/dev/null || echo "000")
    [ "$STATUS_C" = "200" ] && READY_C=true && ok "Consumer (${CONSUMER_PORT}) : HTTP 200"
  fi
  $READY_P && $READY_C && break
  log "Tentative $i/20 — Producer: ${STATUS_P:-...} | Consumer: ${STATUS_C:-...}"
done

$READY_P || warn "Producer ne répond pas sur le port ${PRODUCER_PORT}"
$READY_C || warn "Consumer ne répond pas sur le port ${CONSUMER_PORT}"

# =============================================================================
#  ÉTAPE 5 — Config Nginx (idempotente : ne réécrit que si pas de SSL en place)
# =============================================================================

# Fonction qui écrit une config Nginx seulement si elle n'a pas encore été
# enrichie par Certbot (on détecte la présence de "ssl_certificate")
write_nginx_if_needed() {
  local FILE="$1"
  local CONTENT="$2"

  if [ -f "$FILE" ] && grep -q "ssl_certificate" "$FILE"; then
    info "Config $FILE déjà enrichie par Certbot, non modifiée"
  else
    echo "$CONTENT" > "$FILE"
    ok "Config Nginx écrite : $FILE"
  fi
}

log "Configuration Nginx..."

PRODUCER_CONF=$(cat <<EOF
server {
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
}
EOF
)

CONSUMER_CONF=$(cat <<EOF
server {
    listen 80;
    server_name ${CONSUMER_DOMAIN};

    location / {
        proxy_pass              http://127.0.0.1:${CONSUMER_PORT};
        proxy_set_header        Host \$host;
        proxy_set_header        X-Real-IP \$remote_addr;
        proxy_set_header        X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header        X-Forwarded-Proto \$scheme;
        proxy_buffering         off;
        proxy_cache             off;
        proxy_read_timeout      3600s;
        proxy_http_version      1.1;
        proxy_set_header        Connection '';
        chunked_transfer_encoding on;
    }
}
EOF
)

write_nginx_if_needed "$NGINX_AVAILABLE/$PRODUCER_DOMAIN" "$PRODUCER_CONF"
write_nginx_if_needed "$NGINX_AVAILABLE/$CONSUMER_DOMAIN" "$CONSUMER_CONF"

# Activation (ln -sf est idempotent)
ln -sf "$NGINX_AVAILABLE/$PRODUCER_DOMAIN" "$NGINX_ENABLED/$PRODUCER_DOMAIN"
ln -sf "$NGINX_AVAILABLE/$CONSUMER_DOMAIN" "$NGINX_ENABLED/$CONSUMER_DOMAIN"

nginx -t || err "Config Nginx invalide, vérifiez les fichiers dans $NGINX_AVAILABLE"
systemctl reload nginx
ok "Nginx rechargé"

# =============================================================================
#  ÉTAPE 6 — SSL Certbot (seulement au premier déploiement)
# =============================================================================

CERT_PRODUCER="/etc/letsencrypt/live/${PRODUCER_DOMAIN}/fullchain.pem"
CERT_CONSUMER="/etc/letsencrypt/live/${CONSUMER_DOMAIN}/fullchain.pem"

if [ -f "$CERT_PRODUCER" ] && [ -f "$CERT_CONSUMER" ]; then
  info "Certificats SSL déjà présents, renouvellement automatique actif"
else
  log "Génération des certificats SSL via Certbot..."
  certbot --nginx \
    -d "$PRODUCER_DOMAIN" \
    -d "$CONSUMER_DOMAIN" \
    --non-interactive \
    --agree-tos \
    --redirect \
    --email "$CERTBOT_EMAIL" \
    && ok "Certificats SSL générés" \
    || warn "Certbot a échoué — relancez manuellement :
    sudo certbot --nginx -d $PRODUCER_DOMAIN -d $CONSUMER_DOMAIN"
fi

# =============================================================================
#  RÉSUMÉ
# =============================================================================
echo ""
echo -e "${GREEN}══════════════════════════════════════════${NC}"
echo -e "${GREEN}  Déploiement terminé${NC}"
if [ "$CODE_CHANGED" = true ]; then
  echo -e "${GREEN}  Mise à jour appliquée${NC}"
else
  echo -e "${GREEN}  Aucune modification de code${NC}"
fi
echo -e "${GREEN}══════════════════════════════════════════${NC}"
echo ""
echo -e "  Producer  →  https://${PRODUCER_DOMAIN}"
echo -e "  Consumer  →  https://${CONSUMER_DOMAIN}"
echo ""
echo -e "Commandes utiles :"
echo -e "  ${CYAN}$COMPOSE -f $APP_DIR/docker-compose.yaml logs -f${NC}"
echo -e "  ${CYAN}$COMPOSE -f $APP_DIR/docker-compose.yaml ps${NC}"
echo -e "  ${CYAN}$COMPOSE -f $APP_DIR/docker-compose.yaml restart producer${NC}"
echo ""
