#!/usr/bin/env python3
import logging
import os
import threading

try:
    from flask import Flask, send_from_directory
except ImportError:  # pragma: no cover
    class _FakeFlask:
        def __init__(self, *args, **kwargs):
            pass

        def route(self, *args, **kwargs):
            return lambda f: f

    def send_from_directory(*args, **kwargs):
        pass

    Flask = _FakeFlask

from config import NUTWATCH_HOST, NUTWATCH_PORT, NUTWATCH_SECRET_KEY, NUTWATCH_SESSION_COOKIE_SECURE
from routes import ups_bp, users_bp, upsmon_bp, hooks_bp, system_bp, logs_bp, wol_bp, history_bp, auth_bp
from services.auth_db import get_or_create_secret_key
from services.history import start_collector

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
logger = logging.getLogger("nutwatch")


def create_app():
    app = Flask(__name__)

    app.secret_key = NUTWATCH_SECRET_KEY or get_or_create_secret_key()
    app.config["SESSION_COOKIE_HTTPONLY"] = True
    app.config["SESSION_COOKIE_SAMESITE"] = "Lax"
    app.config["SESSION_COOKIE_SECURE"] = NUTWATCH_SESSION_COOKIE_SECURE

    app.register_blueprint(ups_bp)
    app.register_blueprint(users_bp)
    app.register_blueprint(upsmon_bp)
    app.register_blueprint(hooks_bp)
    app.register_blueprint(system_bp)
    app.register_blueprint(logs_bp)
    app.register_blueprint(wol_bp)
    app.register_blueprint(history_bp)
    app.register_blueprint(auth_bp)

    try:
        interval = int(os.environ.get("NUTWATCH_HISTORY_INTERVAL", "60"))
        if interval <= 0:
            raise ValueError
    except ValueError:
        logger.warning("Invalid NUTWATCH_HISTORY_INTERVAL; falling back to 60s")
        interval = 60
    thread = threading.Thread(
        target=start_collector, args=(app, interval), daemon=True
    )
    thread.start()

    @app.route("/")
    def index():
        return send_from_directory(
            os.path.join(os.path.dirname(__file__), "static"), "index.html"
        )

    return app


app = create_app()


if __name__ == "__main__":
    app.run(host=NUTWATCH_HOST, port=NUTWATCH_PORT)
