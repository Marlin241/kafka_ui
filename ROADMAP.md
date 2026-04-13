# Kafka UI — Roadmap & État du projet

## Contexte

Projet pédagogique Kafka avec interface Flask.  
Objectif du TP : comprendre les concepts de **producer**, **consumer**, et **broker** Kafka via des interfaces web séparées.

---

## Architecture actuelle

```
Kafka_UI/
├── producer_app.py         ✅ App Flask — interface d'envoi uniquement (port 5001)
├── consumer_app.py         ✅ App Flask — interface de réception uniquement (port 5002)
├── kafka_producer.py       ✅ Module producer réutilisable
├── kafka_consumer.py       ✅ Module consumer réutilisable (thread + store)
├── kafka_admin.py          ✅ Module admin (création topics, listing, broker info)
├── docker-compose.yaml
├── requirements.txt
├── ROADMAP.md
└── templates/
    ├── producer.html       ✅ UI send-only (amber theme)
    └── consumer.html       ✅ UI receive-only (green theme, SSE live)
```

---
Bonjour à tous, je vous propose encore une autre version du projet, avec deux app consumer et producer
## Lancer le projet

```bash
# Terminal 1 — Kafka broker
docker-compose up -d

# Terminal 2 — App Producer (envoi)
python producer_app.py

# Terminal 3 — App Consumer (réception)
python consumer_app.py
```

Accès :
- **Producer UI** http://localhost:5001
- **Consumer UI** http://localhost:5002

---

## État des tâches

| Tâche | Statut |
|---|---|
| Identifier producer.py / consumer.py comme obsolètes | ✅ Fait |
| Fix bug SSE (render inconditionnel dans es.onmessage) | ✅ Fait |
| Fix bug panel (render dans showPanel) | ✅ Fait |
| Extraire logique producer dans kafka_producer.py | ✅ Fait |
| Extraire logique consumer dans kafka_consumer.py | ✅ Fait |
| Extraire logique admin dans kafka_admin.py | ✅ Fait |
| Créer producer_app.py (Flask send-only, port 5001) | ✅ Fait |
| Créer consumer_app.py (Flask receive-only, port 5002) | ✅ Fait |
| Créer templates/producer.html | ✅ Fait |
| Créer templates/consumer.html | ✅ Fait |
| Supprimer app.py, producer.py, consumer.py obsolètes | ✅ Fait |
| Supprimer templates/index.html obsolète | ✅ Fait |
