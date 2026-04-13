from confluent_kafka.admin import AdminClient, NewTopic

import os
BOOTSTRAP_SERVERS = os.getenv("KAFKA_BOOTSTRAP_SERVERS", "kafka:9092")
APP_TOPICS = ["nourriture", "electronique", "vetements", "cosmetique"]


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
    try:
        admin = get_admin_client()
        meta = admin.list_topics(timeout=5)
        brokers = [{"id": b.id, "host": b.host, "port": b.port}
                   for b in meta.brokers.values()]
        return {"ok": True, "brokers": brokers, "connected": True}
    except Exception as e:
        return {"ok": False, "connected": False, "error": str(e)}
