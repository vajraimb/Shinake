#!/usr/bin/env python3
"""Mock OpenAI-compatible chat endpoint for testing the snake3d LLM worker."""
import json
from http.server import BaseHTTPRequestHandler, HTTPServer

RECIPE = {
    "hue": 725,                # out of range on purpose -> must wrap to 5
    "shape": 3,
    "rarity": 2,
    "flavor": "闻着上头，吃着真香",
    "fx": {
        "speed_mult": 1.7,
        "speed_secs": 4,
        "growth": 2,
        "score": 60,
        "shake": 0.2,
        "confuse": 0,
        "bursts": 3,
        "tint": [150, 220, 60],
    },
}

class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(n)
        req = json.loads(body)
        # verify the request shape the worker sends
        assert req["model"], "model missing"
        assert req["messages"][0]["role"] == "system"
        assert req["messages"][1]["role"] == "user"
        print("mock got auth:", self.headers.get("Authorization", "<none>")[:20] + "...")
        print("mock got word:", req["messages"][1]["content"])
        resp = {"choices": [{"message": {"content":
                "```json\n" + json.dumps(RECIPE, ensure_ascii=False) + "\n```"}}]}
        data = json.dumps(resp).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *a):
        pass

HTTPServer(("127.0.0.1", 8931), Handler).serve_forever()
