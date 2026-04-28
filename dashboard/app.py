#!/usr/bin/env python3
"""Ghostlink Dashboard — Flask + flask-sock."""

import os
import sys

sys.path.insert(0, "/opt/ghostlink")

from flask import Flask, render_template
from flask_sock import Sock

from dashboard.api import system, network, identity, pentest, terminal

app = Flask(__name__, template_folder="templates", static_folder="static")
app.config["SECRET_KEY"] = os.urandom(32)
app.config["SOCK_SERVER_OPTIONS"] = {"ping_interval": 25}

sock = Sock(app)

# Register blueprints
for bp in (system.bp, network.bp, identity.bp, pentest.bp, terminal.bp):
    app.register_blueprint(bp)

# Register WebSocket terminal
terminal.init_sock(sock)


@app.get("/")
def index():
    return render_template("index.html")


if __name__ == "__main__":
    port = int(os.environ.get("GHOSTLINK_PORT", 8080))
    app.run(host="0.0.0.0", port=port, debug=False)
