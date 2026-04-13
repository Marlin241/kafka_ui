import json
import os
import uuid
import threading
import time
from datetime import datetime
from confluent_kafka import Consumer, KafkaError

BOOTSTRAP_SERVERS = os.getenv("KAFKA_BOOTSTRAP_SERVERS", "kafka:9092")
APP_TOPICS = ["nourriture", "electronique", "vetements", "cosmetique"]

# ── Store partagé ─────────────────────────────────────────────
messages_store = {t: [] for t in APP_TOPICS}
messages_lock = threading.Lock()

# ── État souscription ─────────────────────────────────────────
active_subscription = list(APP_TOPICS)
subscription_lock = threading.Lock()
consumer_running = False
consumer_thread = None


def set_subscription(topics: list):
    global active_subscription
    with subscription_lock:
        active_subscription = list(topics)
    print(f"[Consumer] Nouvelle souscription : {topics}")


def _consumer_loop(topics_to_listen: list):
    cfg = {
        "bootstrap.servers": BOOTSTRAP_SERVERS,
        "group.id": f"kafka-ui-{uuid.uuid4()}",
        "auto.offset.reset": "latest",
        "enable.auto.commit": True,
    }
    consumer = Consumer(cfg)
    consumer.subscribe(topics_to_listen)
    print(f"[Consumer] Écoute sur : {topics_to_listen}")

    global consumer_running
    try:
        while consumer_running:
            with subscription_lock:
                current_sub = list(active_subscription)
            if set(current_sub) != set(topics_to_listen):
                break

            msg = consumer.poll(0.8)
            if msg is None:
                continue
            if msg.error():
                if msg.error().code() != KafkaError._PARTITION_EOF:
                    print(f"[Consumer] Erreur : {msg.error()}")
                continue

            try:
                raw = msg.value().decode("utf-8")
                try:
                    value = json.loads(raw)
                except Exception:
                    value = raw

                record = {
                    "id": str(uuid.uuid4()),
                    "topic": msg.topic(),
                    "partition": msg.partition(),
                    "offset": msg.offset(),
                    "timestamp": datetime.now().strftime("%H:%M:%S"),
                    "value": value,
                    "raw": raw,
                }
                with messages_lock:
                    bucket = messages_store.setdefault(msg.topic(), [])
                    bucket.insert(0, record)
                    if len(bucket) > 200:
                        bucket.pop()
            except Exception as e:
                print(f"[Consumer] Erreur traitement : {e}")
    finally:
        consumer.close()
        print(f"[Consumer] Fermé (était sur : {topics_to_listen})")


def _consumer_manager():
    global consumer_running
    while consumer_running:
        with subscription_lock:
            topics = list(active_subscription)
        if not topics:
            time.sleep(1)
            continue
        _consumer_loop(topics)
        time.sleep(0.5)


def start_consumer_manager():
    global consumer_thread, consumer_running
    if consumer_thread and consumer_thread.is_alive():
        return
    consumer_running = True
    consumer_thread = threading.Thread(target=_consumer_manager, daemon=True)
    consumer_thread.start()


def stop_consumer_manager():
    global consumer_running
    consumer_running = False


def get_messages(topic: str = "all") -> list:
    with messages_lock:
        if topic and topic in messages_store:
            return list(messages_store[topic])
        else:
            all_msgs = []
            for bucket in messages_store.values():
                all_msgs.extend(bucket)
            return sorted(all_msgs, key=lambda m: m["id"], reverse=True)[:100]
