# Déploiement Kafka UI sur VPS

## Vue d'ensemble

L'application est composée de trois conteneurs Docker qui communiquent sur un réseau interne :

```
Internet
    │
    ▼
Nginx (VPS host)  —  ports 80 / 443
    │
    ├── producer.digitalko.space  ──►  conteneur Flask Producer  (5001)
    │
    └── consumer.digitalko.space  ──►  conteneur Flask Consumer  (5002)
                                              │
                                              ▼
                                    conteneur Kafka  (9092 interne)
```

Nginx sur le VPS reçoit les requêtes publiques et les redirige vers les deux apps Flask. Les apps Flask communiquent avec Kafka via le réseau Docker interne — Kafka n'est **pas** exposé sur l'internet.

---

## Prérequis sur le VPS

Avant de lancer le script, assurez-vous que les éléments suivants sont installés :

### Docker
```bash
curl -fsSL https://get.docker.com | sh
systemctl enable docker
systemctl start docker
```

### Docker Compose (plugin v2)
```bash
apt install docker-compose-plugin
# Vérification
docker compose version
```

### Nginx
```bash
apt install nginx
systemctl enable nginx
systemctl start nginx
```

### Certbot
```bash
apt install certbot python3-certbot-nginx
```

---

## Vérification DNS (à faire avant tout)

Les deux sous-domaines doivent pointer vers l'IP de votre VPS. Vérifiez depuis votre machine locale :

```bash
nslookup producer.digitalko.space
nslookup consumer.digitalko.space
```

Les deux doivent retourner l'IP de votre VPS. Si ce n'est pas encore le cas, attendez la propagation DNS avant de continuer.

---

## Structure du projet

```
Kafka_UI/
├── Dockerfile
├── docker-compose.yaml
├── requirements.txt
├── deploy.sh
├── producer_app.py
├── consumer_app.py
├── kafka_admin.py
├── kafka_producer.py
├── kafka_consumer.py
└── templates/
    ├── producer.html
    └── consumer.html
```

---

## Déploiement

### 1. Transférer le projet sur le VPS

Depuis votre machine locale (dans le dossier du projet) :

```bash
scp -r . user@IP_VPS:/tmp/kafka-ui
```

Ou avec rsync (plus rapide si vous redéployez) :

```bash
rsync -av --exclude='.venv' --exclude='__pycache__' \
  ./ user@IP_VPS:/tmp/kafka-ui/
```

### 2. Se connecter au VPS

```bash
ssh user@IP_VPS
cd /tmp/kafka-ui
```

### 3. Rendre le script exécutable et le lancer

```bash
chmod +x deploy.sh
sudo bash deploy.sh
```

Le script fait automatiquement les étapes suivantes :
- Vérifie que Docker, Nginx et Certbot sont installés
- Copie le projet dans `/opt/kafka-ui`
- Build les images Docker et démarre les 3 conteneurs
- Attend que les apps soient disponibles
- Crée et active les configs Nginx pour les deux domaines
- Génère les certificats SSL via Certbot
- Recharge Nginx

À la fin, vous verrez :

```
========================================
  Déploiement terminé
========================================

  Producer  →  https://producer.digitalko.space
  Consumer  →  https://consumer.digitalko.space
```

---

## Ce que fait le script en détail

### Conteneurs Docker

Trois conteneurs sont créés :

| Conteneur | Image | Port interne | Description |
|---|---|---|---|
| `kafka` | confluentinc/cp-kafka:7.8.3 | 9092 (interne) | Broker Kafka en mode KRaft |
| `kafka_producer` | image locale (Dockerfile) | 5001 | App Flask Producer |
| `kafka_consumer` | image locale (Dockerfile) | 5002 | App Flask Consumer |

Le producer et le consumer attendent que Kafka soit `healthy` avant de démarrer (healthcheck configuré dans le docker-compose).

### Configs Nginx générées

**`/etc/nginx/sites-available/producer.digitalko.space`**
```nginx
server {
    listen 80;
    server_name producer.digitalko.space;

    location / {
        proxy_pass         http://127.0.0.1:5001;
        proxy_set_header   Host $host;
        proxy_buffering    off;
        proxy_read_timeout 120s;
    }
}
```

**`/etc/nginx/sites-available/consumer.digitalko.space`**
```nginx
server {
    listen 80;
    server_name consumer.digitalko.space;

    location / {
        proxy_pass         http://127.0.0.1:5002;
        proxy_buffering    off;
        proxy_cache        off;
        proxy_read_timeout 3600s;
        proxy_http_version 1.1;
        proxy_set_header   Connection '';
    }
}
```

> La config du consumer a des paramètres spéciaux (`proxy_buffering off`, `proxy_http_version 1.1`, `Connection ''`) indispensables pour que le **Server-Sent Events** (SSE) du stream de messages fonctionne correctement. Sans ça, les messages n'arrivent pas en temps réel.

Certbot modifie ensuite ces fichiers pour ajouter les blocs HTTPS (port 443) et la redirection automatique de HTTP vers HTTPS.

---

## Commandes utiles après déploiement

### Voir les logs en temps réel
```bash
cd /opt/kafka-ui
docker compose logs -f
# Ou par service spécifique
docker compose logs -f producer
docker compose logs -f consumer
docker compose logs -f kafka
```

### Voir l'état des conteneurs
```bash
docker compose ps
```

### Redémarrer un service
```bash
docker compose restart producer
docker compose restart consumer
```

### Arrêter tout
```bash
docker compose down
```

### Redéployer après une modification du code
```bash
cd /opt/kafka-ui
# Copiez les nouveaux fichiers depuis votre machine locale, puis :
docker compose build --no-cache
docker compose up -d
```

### Renouveler les certificats SSL (Certbot le fait automatiquement, mais si besoin manuellement)
```bash
certbot renew
```

---

## Dépannage

### Les messages ne s'affichent pas en temps réel sur le consumer

Vérifiez que `proxy_buffering off` est bien présent dans la config Nginx du consumer. C'est la cause la plus fréquente.

### Erreur "Connection refused" au démarrage

Kafka met quelques secondes à être prêt. Le docker-compose est configuré avec un `healthcheck` et les apps Flask attendent que Kafka soit disponible. Si ça persiste :
```bash
docker compose logs kafka
```

### Certbot échoue

Causes possibles :
- Les DNS ne pointent pas encore vers le VPS (attendez la propagation)
- Le port 80 est bloqué par un firewall

Vérifiez le firewall :
```bash
ufw status
# Si actif, ouvrez les ports :
ufw allow 80
ufw allow 443
```

Relancez Certbot manuellement :
```bash
certbot --nginx -d producer.digitalko.space -d consumer.digitalko.space
```

### Voir les erreurs Nginx
```bash
tail -f /var/log/nginx/error.log
```
