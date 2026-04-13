# gunicorn_config.py
# Configuration Gunicorn pour le consumer Kafka
# Le SSE (Server-Sent Events) nécessite des connexions longues et persistantes.
# On utilise 1 seul worker avec plusieurs threads pour que tout partage
# le même messages_store en mémoire.

import kafka_consumer as kc
from kafka_admin import ensure_topics

# ── Workers ───────────────────────────────────────────────────
# 1 seul worker OBLIGATOIRE pour le consumer :
# plusieurs workers = plusieurs processus = plusieurs messages_store
# séparés en mémoire = les messages ne sont pas vus par le bon worker.
workers = 1
worker_class = "gthread"
threads = 8
timeout = 120
keepalive = 65          # > proxy_read_timeout Nginx pour le SSE

# ── Binding ───────────────────────────────────────────────────
bind = "0.0.0.0:5003"

# ── Logs ──────────────────────────────────────────────────────
accesslog = "-"
errorlog = "-"
loglevel = "info"


# ── Hook post_fork ────────────────────────────────────────────
# Appelé après que Gunicorn a forké chaque worker.
# Démarre le thread Kafka dans le process worker (pas dans le master).
def post_fork(server, worker):
    try:
        ensure_topics()
    except Exception as e:
        server.log.warning(f"[Kafka] Topics non vérifiés : {e}")
    kc.start_consumer_manager()
    server.log.info("[Kafka] Consumer manager démarré dans le worker")
