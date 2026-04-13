import json
import os
import threading
from confluent_kafka import Producer

BOOTSTRAP_SERVERS = os.getenv("KAFKA_BOOTSTRAP_SERVERS", "kafka:9092")
APP_TOPICS = ["nourriture", "electronique", "vetements", "cosmetique"]


def get_producer():
    return Producer({"bootstrap.servers": BOOTSTRAP_SERVERS})


def send_message(topic: str, payload) -> dict:
    """
    Envoie un message sur le topic Kafka donné.
    payload : dict ou str — sera sérialisé en JSON si dict.
    Retourne {"ok": True} ou {"ok": False, "error": "..."}.
    """
    if topic not in APP_TOPICS:
        return {"ok": False, "error": f"Topic '{topic}' non autorisé"}

    results = {"delivered": False, "error": None}
    event = threading.Event()

    def cb(err, msg):
        if err:
            results["error"] = str(err)
        else:
            results["delivered"] = True
        event.set()

    try:
        if isinstance(payload, dict):
            value = json.dumps(payload).encode("utf-8")
        else:
            try:
                parsed = json.loads(str(payload))
                value = json.dumps(parsed).encode("utf-8")
            except Exception:
                value = str(payload).encode("utf-8")

        producer = get_producer()
        producer.produce(topic=topic, value=value, callback=cb)
        producer.flush(timeout=5)
        event.wait(timeout=6)

        if results["error"]:
            return {"ok": False, "error": results["error"]}
        return {"ok": True}

    except Exception as e:
        return {"ok": False, "error": str(e)}
