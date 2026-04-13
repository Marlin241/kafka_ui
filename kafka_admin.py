import os
import threading
import time
from confluent_kafka.admin import AdminClient, NewTopic

BOOTSTRAP_SERVERS = os.getenv("KAFKA_BOOTSTRAP_SERVERS", "kafka:9092")
APP_TOPICS = ["nourriture", "electronique", "vetements", "cosmetique"]
BROKER_METADATA_TIMEOUT_SECONDS = float(os.getenv("KAFKA_METADATA_TIMEOUT_SECONDS", "3"))
BROKER_CACHE_TTL_SECONDS = float(os.getenv("BROKER_CACHE_TTL_SECONDS", "8"))

_broker_cache_lock = threading.Lock()
_broker_fetch_lock = threading.Lock()
_broker_cache_value = None
_broker_cache_expires_at = 0.0


def get_admin_client():
    return AdminClient({"bootstrap.servers": BOOTSTRAP_SERVERS})


def ensure_topics():
    """Crée les topics applicatifs s'ils n'existent pas encore."""
    admin = get_admin_client()
    meta = admin.list_topics(timeout=5)
    existing = set(meta.topics.keys())
    to_create = [
        NewTopic(t, num_partitions=1, replication_factor=1)
        for t in APP_TOPICS if t not in existing
    ]
    if to_create:
        fs = admin.create_topics(to_create)
        for topic, f in fs.items():
            try:
                f.result()
                print(f"[Kafka] Topic créé : {topic}")
            except Exception as e:
                print(f"[Kafka] Topic '{topic}' : {e}")


def list_topics() -> list:
    admin = get_admin_client()
    metadata = admin.list_topics(timeout=5)
    topics = []
    for name, meta in metadata.topics.items():
        if name.startswith("__"):
            continue
        topics.append({
            "name": name,
            "partitions": len(meta.partitions),
            "is_app_topic": name in APP_TOPICS,
        })
    return sorted(topics, key=lambda t: t["name"])


def get_brokers() -> dict:
    global _broker_cache_value, _broker_cache_expires_at
    now = time.monotonic()
    cached = None
    with _broker_cache_lock:
        if _broker_cache_value is not None:
            cached = dict(_broker_cache_value)
            if now < _broker_cache_expires_at:
                return cached

    # Avoid piling up concurrent metadata lookups when the broker is slow.
    if not _broker_fetch_lock.acquire(blocking=False):
        if cached is not None:
            return cached
        return {
            "ok": False,
            "connected": False,
            "error": "Vérification du broker déjà en cours"
        }

    try:
        admin = get_admin_client()
        meta = admin.list_topics(timeout=BROKER_METADATA_TIMEOUT_SECONDS)
        brokers = [{"id": b.id, "host": b.host, "port": b.port}
                   for b in meta.brokers.values()]
        result = {"ok": True, "brokers": brokers, "connected": True}
    except Exception as e:
        result = {"ok": False, "connected": False, "error": str(e)}
    finally:
        _broker_fetch_lock.release()

    with _broker_cache_lock:
        _broker_cache_value = dict(result)
        _broker_cache_expires_at = time.monotonic() + BROKER_CACHE_TTL_SECONDS
    return result
