from flask import Flask, render_template, request, jsonify
from kafka_producer import send_message, APP_TOPICS
from kafka_admin import ensure_topics, get_brokers

app = Flask(__name__, template_folder="templates")


@app.route("/")
def index():
    return render_template("producer.html")


@app.route("/api/broker")
def api_broker():
    return jsonify(get_brokers())


@app.route("/api/app-topics")
def api_app_topics():
    return jsonify({"ok": True, "topics": APP_TOPICS})


@app.route("/api/produce", methods=["POST"])
def api_produce():
    data = request.json or {}
    topic = data.get("topic", "").strip()
    payload = data.get("payload", "")

    if not topic:
        return jsonify({"ok": False, "error": "Topic requis"}), 400

    result = send_message(topic, payload)
    if result["ok"]:
        return jsonify(result)
    return jsonify(result), 500


if __name__ == "__main__":
    print("[Init] Vérification/création des topics Kafka...")
    try:
        ensure_topics()
    except Exception as e:
        print(f"[Init] Kafka pas encore disponible : {e}")
    app.run(debug=True, port=5002, use_reloader=False)
