import json
import time
from flask import Flask, render_template, request, jsonify, Response
import kafka_consumer as kc
from kafka_admin import ensure_topics, get_brokers, APP_TOPICS

app = Flask(__name__, template_folder="templates")


@app.route("/")
def index():
    kc.start_consumer_manager()
    return render_template("consumer.html")


@app.route("/api/broker")
def api_broker():
    return jsonify(get_brokers())


@app.route("/api/app-topics")
def api_app_topics():
    with kc.subscription_lock:
        current = list(kc.active_subscription)
    return jsonify({"ok": True, "topics": APP_TOPICS, "active": current})


@app.route("/api/subscription", methods=["POST"])
def api_set_subscription():
    data = request.json or {}
    topic = data.get("topic", "all")
    if topic == "all":
        kc.set_subscription(APP_TOPICS)
    elif topic in APP_TOPICS:
        kc.set_subscription([topic])
    else:
        return jsonify({"ok": False, "error": "Topic inconnu"}), 400
    return jsonify({"ok": True, "active": kc.active_subscription})


@app.route("/api/messages")
def api_messages():
    topic = request.args.get("topic", "all")
    msgs = kc.get_messages(topic)
    return jsonify({"ok": True, "messages": msgs[:100]})


@app.route("/api/stream")
def api_stream():
    def generate():
        seen = set()
        while True:
            with kc.messages_lock:
                with kc.subscription_lock:
                    current_sub = list(kc.active_subscription)
                new_msgs = []
                for t in current_sub:
                    for m in kc.messages_store.get(t, []):
                        if m["id"] not in seen:
                            new_msgs.append(m)
                            seen.add(m["id"])
            for m in reversed(new_msgs):
                yield f"data: {json.dumps(m)}\n\n"
            time.sleep(0.8)

    return Response(
        generate(),
        mimetype="text/event-stream",
        headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"}
    )


if __name__ == "__main__":
    print("[Init] Vérification/création des topics Kafka...")
    try:
        ensure_topics()
    except Exception as e:
        print(f"[Init] Kafka pas encore disponible : {e}")
    kc.start_consumer_manager()
    app.run(debug=True, port=5003, use_reloader=False)
