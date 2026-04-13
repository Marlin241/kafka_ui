# Déploiement Kafka UI sur VPS

## Vue d'ensemble

```
Internet
    │
    ▼
Nginx (VPS host)  —  ports 80 / 443
    │
    ├── producer.digitalko.space  ──►  conteneur Flask Producer  (:5001)
    │
    └── consumer.digitalko.space  ──►  conteneur Flask Consumer  (:5002)
                                              │
                                              ▼
                                    conteneur Kafka  (:9092 interne)
```

Nginx reçoit les requêtes publiques et les redirige vers les apps Flask.
Les apps communiquent avec Kafka via le réseau Docker interne — Kafka n'est pas exposé sur internet.

Le script `deploy.sh` est **idempotent** : il peut être relancé à chaque modification du code. Il détecte automatiquement s'il y a des nouveaux commits sur GitHub et ne reconstruit les images Docker que si nécessaire.

---

## Prérequis sur le VPS

```bash
# Docker
curl -fsSL https://get.docker.com | sh
systemctl enable docker && systemctl start docker

# Docker Compose (plugin v2)
apt install docker-compose-plugin

# Git, Nginx, Certbot
apt install git nginx certbot python3-certbot-nginx
systemctl enable nginx && systemctl start nginx
```

---

## Vérification DNS

Les sous-domaines doivent pointer vers l'IP du VPS. Vérifiez :

```bash
nslookup producer.digitalko.space
nslookup consumer.digitalko.space
```

Les deux doivent retourner l'IP du VPS. Si ce n'est pas encore le cas, attendez la propagation DNS avant de continuer (quelques minutes à quelques heures selon le registrar).

---

## Premier déploiement

Connectez-vous au VPS puis lancez directement :

```bash
curl -fsSL https://raw.githubusercontent.com/Marlin241/kafka_ui/main/deploy.sh | sudo bash
```

Ou si vous avez déjà cloné le repo :

```bash
sudo bash deploy.sh
```

C'est tout. Le script fait le reste.

---

## Ce que fait le script à chaque exécution

### Logique de mise à jour automatique

```
deploy.sh
    │
    ├── /opt/kafka-ui/.git absent ?
    │       └── git clone  (premier déploiement)
    │
    └── /opt/kafka-ui/.git présent ?
            ├── git fetch
            ├── commit local == commit distant ?
            │       └── rien à faire (conteneurs déjà actifs → skip build)
            └── nouveau(x) commit(s) ?
                    └── git pull → docker compose build → docker compose up -d
```

### Nginx (idempotent)

Les configs Nginx ne sont (ré)écrites que si Certbot ne les a pas encore enrichies avec le SSL. Après le premier déploiement, les fichiers Nginx ne sont jamais écrasés — ce qui préserve la config HTTPS générée par Certbot.

### Certbot (une seule fois)

Les certificats SSL ne sont générés qu'au premier déploiement. Les runs suivants détectent leur présence et ne relancent pas Certbot. Le renouvellement automatique est géré par le timer systemd installé par Certbot.

---

## Déployer une mise à jour du code

1. Faites vos modifications en local
2. `git push` vers GitHub
3. Sur le VPS :

```bash
sudo bash /opt/kafka-ui/deploy.sh
```

Le script détecte le nouveau commit, pull, rebuild les images et redémarre les conteneurs.

---

## Commandes utiles après déploiement

```bash
cd /opt/kafka-ui

# Logs en temps réel (tous les services)
docker compose logs -f

# Logs d'un seul service
docker compose logs -f producer
docker compose logs -f consumer
docker compose logs -f kafka

# État des conteneurs
docker compose ps

# Redémarrer un service sans rebuild
docker compose restart producer
docker compose restart consumer

# Tout arrêter
docker compose down

# Tout arrêter + supprimer les volumes (repart de zéro)
docker compose down -v
```

---

## Dépannage

### Les messages n'arrivent pas en temps réel (SSE)

Vérifiez que la config Nginx du consumer contient bien :
```nginx
proxy_buffering    off;
proxy_http_version 1.1;
proxy_set_header   Connection '';
```
C'est la cause la plus fréquente de stream SSE cassé derrière un reverse proxy.

### Erreur "Connection refused" au démarrage

Kafka met ~15-20s à être prêt. Le healthcheck dans le docker-compose retarde le démarrage des apps Flask. Si ça persiste :
```bash
docker compose logs kafka
```

### Certbot échoue

Causes possibles :
- Les DNS ne pointent pas encore vers le VPS
- Le port 80 est bloqué par un firewall

```bash
# Vérifier le firewall
ufw status
ufw allow 80
ufw allow 443

# Relancer Certbot manuellement
certbot --nginx -d producer.digitalko.space -d consumer.digitalko.space
```

### Voir les erreurs Nginx

```bash
tail -f /var/log/nginx/error.log
journalctl -u nginx -f
```
