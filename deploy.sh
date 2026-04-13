#!/bin/bash
# =============================================================================
#  deploy.sh — Déploiement Kafka UI sur VPS
#  Usage : bash deploy.sh
# =============================================================================

set -e  # stoppe le script dès qu'une commande échoue

# ── Couleurs ──────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log()  { echo -e "${BLUE}[deploy]${NC} $1"; }
ok()   { echo -e "${GREEN}[ok]${NC} $1"; }
warn() { echo -e "${YELLOW}[warn]${NC} $1"; }
err()  { echo -e "${RED}[erreur]${NC} $1"; exit 1; }

# ── Config ────────────────────────────────────────────────────
PRODUCER_DOMAIN="producer.digitalko.space"
CONSUMER_DOMAIN="consumer.digitalko.space"
APP_DIR="/opt/kafka-ui"
NGINX_AVAILABLE="/etc/nginx/sites-available"
NGINX_ENABLED="/etc/nginx/sites-enabled"

# ── 1. Vérification des prérequis ─────────────────────────────
log "Vérification des prérequis..."

command -v docker   >/dev/null 2>&1 || err "Docker n'est pas installé. Installez-le d'abord."
command -v docker compose version >/dev/null 2>&1 || \
  docker-compose version >/dev/null 2>&1 || \
  err "Docker Compose n'est pas installé."
command -v nginx    >/dev/null 2>&1 || err "Nginx n'est pas installé."
command -v certbot  >/dev/null 2>&1 || err "Certbot n'est pas installé. Lancez : apt install certbot python3-certbot-nginx"

ok "Prérequis OK"

# ── 2. Copie des fichiers du projet ───────────────────────────
log "Copie des fichiers vers $APP_DIR..."

mkdir -p "$APP_DIR"
rsync -av --exclude='.venv' --exclude='__pycache__' --exclude='*.pyc' \
  ./ "$APP_DIR/"

ok "Fichiers copiés"

# ── 3. Build et démarrage des conteneurs ──────────────────────
log "Build et démarrage des conteneurs Docker..."

cd "$APP_DIR"

# Docker Compose v2 ou v1
if docker compose version >/dev/null 2>&1; then
  COMPOSE="docker compose"
else
  COMPOSE="docker-compose"
fi

$COMPOSE down --remove-orphans 2>/dev/null || true
$COMPOSE build --no-cache
$COMPOSE up -d

ok "Conteneurs démarrés"

# ── 4. Attendre que les apps soient prêtes ────────────────────
log "Attente du démarrage des apps (30s max)..."

for i in $(seq 1 15); do
  sleep 2
  STATUS_P=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:5002/ 2>/dev/null || echo "000")
  STATUS_C=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:5003/ 2>/dev/null || echo "000")
  if [ "$STATUS_P" = "200" ] && [ "$STATUS_C" = "200" ]; then
    ok "Producer (5002) : HTTP $STATUS_P"
    ok "Consumer (5003) : HTTP $STATUS_C"
    break
  fi
  log "Tentative $i/15 — Producer: $STATUS_P | Consumer: $STATUS_C"
done

# ── 5. Config Nginx — Producer ────────────────────────────────
log "Écriture config Nginx pour $PRODUCER_DOMAIN..."

cat > "$NGINX_AVAILABLE/$PRODUCER_DOMAIN" <<EOF
server {
    listen 80;
    server_name $PRODUCER_DOMAIN;

    location / {
        proxy_pass         http://127.0.0.1:5002;
        proxy_set_header   Host \$host;
        proxy_set_header   X-Real-IP \$remote_addr;
        proxy_set_header   X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto \$scheme;
        proxy_buffering    off;
        proxy_read_timeout 120s;
    }
}
EOF

ok "Config producer créée"

# ── 6. Config Nginx — Consumer ────────────────────────────────
log "Écriture config Nginx pour $CONSUMER_DOMAIN..."

cat > "$NGINX_AVAILABLE/$CONSUMER_DOMAIN" <<EOF
server {
    listen 80;
    server_name $CONSUMER_DOMAIN;

    location / {
        proxy_pass            http://127.0.0.1:5003;
        proxy_set_header      Host \$host;
        proxy_set_header      X-Real-IP \$remote_addr;
        proxy_set_header      X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header      X-Forwarded-Proto \$scheme;

        # SSE — obligatoire pour que le stream fonctionne
        proxy_buffering       off;
        proxy_cache           off;
        proxy_read_timeout    3600s;
        proxy_http_version    1.1;
        proxy_set_header      Connection '';
        chunked_transfer_encoding on;
    }
}
EOF

ok "Config consumer créée"

# ── 7. Activation des sites ───────────────────────────────────
log "Activation des sites Nginx..."

ln -sf "$NGINX_AVAILABLE/$PRODUCER_DOMAIN" "$NGINX_ENABLED/$PRODUCER_DOMAIN"
ln -sf "$NGINX_AVAILABLE/$CONSUMER_DOMAIN" "$NGINX_ENABLED/$CONSUMER_DOMAIN"

nginx -t || err "Erreur dans la config Nginx, vérifiez les fichiers."
systemctl reload nginx

ok "Nginx rechargé"

# ── 8. Certificats SSL avec Certbot ───────────────────────────
log "Génération des certificats SSL..."

certbot --nginx \
  -d "$PRODUCER_DOMAIN" \
  -d "$CONSUMER_DOMAIN" \
  --non-interactive \
  --agree-tos \
  --redirect \
  --email "admin@digitalko.space" \
  || warn "Certbot a échoué. Vérifiez que les DNS pointent bien vers ce VPS et relancez manuellement : sudo certbot --nginx -d $PRODUCER_DOMAIN -d $CONSUMER_DOMAIN"

# ── 9. Résumé ─────────────────────────────────────────────────
echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  Déploiement terminé${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "  Producer  →  https://$PRODUCER_DOMAIN"
echo -e "  Consumer  →  https://$CONSUMER_DOMAIN"
echo ""
echo -e "Commandes utiles :"
echo -e "  $COMPOSE -f $APP_DIR/docker-compose.yaml logs -f"
echo -e "  $COMPOSE -f $APP_DIR/docker-compose.yaml ps"
echo -e "  $COMPOSE -f $APP_DIR/docker-compose.yaml down"
echo ""
