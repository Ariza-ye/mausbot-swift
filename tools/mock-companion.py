#!/usr/bin/env python3
"""A tiny stand-in for the OpenMausBot companion API.

It speaks the routes the macOS client uses so pairing, transcripts, approvals,
sending and the event stream can be exercised without a real desktop:

    python3 tools/mock-companion.py --port 8799
    ./build/Build/Products/Debug/MausBot.app/Contents/MacOS/MausBot \
        --selfcheck all --url http://127.0.0.1:8799 --credential 123456
"""

import argparse
import json
import queue
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

TOKEN = "dev_mock_token"
PAIR_CODE = "123456"
PAIR_TOKEN = "omb_pair_" + "a" * 43
DEVICE_TOKEN_PREFIX = "dev_"

PNG = bytes.fromhex(
    "89504e470d0a1a0a0000000d49484452000000080000000808020000004b6d29dc"
    "0000001149444154789c63d058108515310c2d090047ec488162d77959000000"
    "0049454e44ae426082"
)

state_lock = threading.Lock()
subscribers = []
frame_id = 0
state = {
    "messages": {
        "thread-main": [
            {
                "id": "msg-1",
                "role": "bot",
                "kind": "text",
                "text": "早上好。要我检查构建吗？",
                "createdAt": 1_700_000_000_000,
            },
            {
                "id": "msg-card",
                "role": "bot",
                "kind": "options",
                "text": "",
                "createdAt": 1_700_000_050_000,
                "card": {
                    "title": "运行 rm -rf build？",
                    "subtitle": "这个操作会删除构建目录。",
                    "options": ["允许", "拒绝"],
                    "requestId": "req-1",
                    "requestType": "permission",
                    "tool": "Bash",
                    "allowKey": "bash:rm",
                },
            },
        ],
        "thread-room": [
            {
                "id": "msg-room-1",
                "role": "bot",
                "kind": "text",
                "text": "房间在线。",
                "createdAt": 1_700_000_100_000,
                "from": {"name": "Builder", "color": "blue"},
            }
        ],
    },
    "counter": 100,
    "model": {"instanceId": "claude", "model": "claude-sonnet-4-5"},
    "card": {
        "title": "运行 rm -rf build？",
        "subtitle": "这个操作会删除构架目录。",
        "options": ["允许", "拒绝"],
        "requestId": "req-1",
        "requestType": "permission",
        "tool": "Bash",
        "allowKey": "bash:rm",
    },
}


def next_id(prefix):
    with state_lock:
        state["counter"] += 1
        return f"{prefix}-{state['counter']}"


def now_ms():
    return int(time.time() * 1000)


def broadcast(kind, **fields):
    global frame_id
    with state_lock:
        frame_id += 1
        frame = {"kind": kind, **fields}
        dead = []
        for channel in subscribers:
            try:
                channel.put_nowait((frame_id, frame))
            except queue.Full:
                dead.append(channel)
        for channel in dead:
            subscribers.remove(channel)


def bot_payload(port):
    with state_lock:
        messages = list(state["messages"]["thread-main"])
    return {
        "id": "bot-1",
        "name": "Maus",
        "title": "主管",
        "description": "Mock computer",
        "color": "green",
        "avatarUrl": None,
        "threadId": "thread-main",
        "mainThreadId": "thread-main",
        "tasks": [
            {"threadId": "thread-main", "title": "主线", "unread": False, "busy": False, "pinned": True},
        ],
        "unread": False,
        "pinned": True,
        "hidden": False,
        "busy": False,
        "activity": "idle",
        "modelSelection": dict(state["model"]),
        "notifications": True,
        "messages": messages[-50:],
        "hasMore": False,
        "activeLeafId": messages[-1]["id"] if messages else None,
    }


def room_payload():
    with state_lock:
        messages = list(state["messages"]["thread-room"])
    return {
        "id": "room-1",
        "name": "工作间",
        "description": "两个 Bot 的房间",
        "threadId": "thread-room",
        "memberIds": ["bot-1", "bot-2"],
        "unread": True,
        "messages": messages[-50:],
        "hasMore": False,
    }


class Handler(BaseHTTPRequestHandler):
    server_version = "MockCompanion/1.0"
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        if self.path != "/api/events":
            print("[mock]", fmt % args, flush=True)

    def send_json(self, status, payload):
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def authed(self):
        header = self.headers.get("Authorization", "")
        return header == f"Bearer {TOKEN}" or header == f"Bearer {PAIR_CODE}"

    def read_json(self):
        length = int(self.headers.get("Content-Length") or 0)
        if not length:
            return {}
        raw = self.rfile.read(length)
        try:
            return json.loads(raw)
        except json.JSONDecodeError:
            return {}

    def denied(self):
        self.send_json(401, {"error": "device token required"})

    def do_GET(self):
        url = urlparse(self.path)
        path = url.path
        if path == "/api/health":
            return self.send_json(200, {"app": "openmausbot", "name": "Mock Studio", "version": "1.0.0"})
        if not self.authed():
            return self.denied()
        if path == "/api/bots":
            return self.send_json(200, {
                "bots": [bot_payload(self.server.server_port)],
                "groups": [room_payload()],
                "sections": [],
                "botQueuedMessages": {},
                "computerControl": {},
            })
        if path == "/api/config":
            return self.send_json(200, {"name": "Mock Studio", "capabilities": {"queueing": True}})
        if path == "/api/instances":
            return self.send_json(200, {"instances": [{
                "instanceId": "claude",
                "driverKind": "claude",
                "displayName": "Claude",
                "enabled": True,
                "models": {"default": "claude-sonnet-4-5", "options": [
                    {"id": "claude-sonnet-4-5", "label": "Sonnet 4.5"},
                    {"id": "claude-opus-4-1", "label": "Opus 4.1"},
                ]},
            }]})
        if path.startswith("/api/threads/") and path.endswith("/messages"):
            thread_id = path.split("/")[3]
            with state_lock:
                messages = list(state["messages"].get(thread_id, []))
            params = parse_qs(url.query)
            before = (params.get("before") or [None])[0]
            if before:
                index = next((i for i, m in enumerate(messages) if m["id"] == before), len(messages))
                messages = messages[max(0, index - 2):index]
            return self.send_json(200, {"messages": messages[-50:], "hasMore": False})
        if path == "/api/search":
            query = (parse_qs(url.query).get("q") or [""])[0].lower()
            hits = []
            with state_lock:
                for thread_id, messages in state["messages"].items():
                    for message in messages:
                        if query and query in (message.get("text") or "").lower():
                            hits.append({
                                "threadId": thread_id,
                                "messageId": message["id"],
                                "text": message.get("text", ""),
                                "name": "Maus" if thread_id == "thread-main" else "工作间",
                                "task": "主线" if thread_id == "thread-main" else None,
                                "botId": "bot-1" if thread_id == "thread-main" else None,
                                "groupId": None if thread_id == "thread-main" else "room-1",
                            })
            return self.send_json(200, {"hits": hits})
        if path == "/api/companion/endpoints":
            return self.send_json(200, {
                "serverName": "Mock Studio",
                "hosts": ["127.0.0.1"],
                "endpoints": [{"url": f"http://127.0.0.1:{self.server.server_port}", "kind": "lan", "priority": 0}],
            })
        if path.startswith("/api/attachments/"):
            self.send_response(200)
            self.send_header("Content-Type", "image/png")
            self.send_header("Content-Length", str(len(PNG)))
            self.end_headers()
            return self.wfile.write(PNG)
        if path == "/api/events":
            return self.event_stream()
        self.send_json(404, {"error": f"no route {path}"})

    def do_POST(self):
        path = urlparse(self.path).path
        # Always consume the body, even on branches that ignore it: an unread
        # body would prefix the next request on this keep-alive connection.
        body = self.read_json()
        if path == "/api/pair":
            credential = body.get("credential") or body.get("code")
            if credential not in (PAIR_CODE, PAIR_TOKEN):
                return self.send_json(401, {"error": "配对码无效或已过期"})
            port = self.server.server_port
            print("[mock] paired", body.get("deviceName"), flush=True)
            return self.send_json(200, {
                "token": TOKEN,
                "device": {"id": "dev-1", "name": body.get("deviceName")},
                "serverName": "Mock Studio",
                "hosts": ["127.0.0.1"],
                "endpoints": [{"url": f"http://127.0.0.1:{port}", "kind": "lan", "priority": 0}],
            })
        if path == "/api/attachments":
            return self.send_json(200, {"path": "mock.png", "url": "/api/attachments/mock.png"})
        if not self.authed():
            return self.denied()
        if path in ("/api/bots",):
            return self.send_json(201, {"bot": bot_payload(self.server.server_port)})
        if path.startswith("/api/bots/") and path.endswith("/messages"):
            return self.accept_message(body)
        if path.startswith("/api/groups/") and path.endswith("/messages"):
            return self.accept_message(body, room=True)
        if path == "/api/threads/thread-main/respond" or (path.startswith("/api/threads/") and path.endswith("/respond")):
            with state_lock:
                card = dict(state["card"])
                card["answered"] = body.get("behavior")
                if body.get("message"):
                    card["answeredText"] = body["message"]
                state["card"] = card
            thread_id = path.split("/")[3]
            broadcast("message.patch", threadId=thread_id, message={
                "id": "msg-card",
                "role": "bot",
                "kind": "options",
                "text": "",
                "createdAt": now_ms(),
                "card": card,
            })
            return self.send_json(200, {"ok": True})
        if path.startswith("/api/bots/") and path.endswith("/read"):
            return self.send_json(200, {"ok": True})
        if path.startswith("/api/bots/") and path.endswith("/interrupt"):
            return self.send_json(200, {"ok": True})
        if path.startswith("/api/bots/") and path.endswith("/always-allow"):
            return self.send_json(200, {"ok": True})
        if path.endswith("/tasks"):
            thread_id = next_id("thread")
            with state_lock:
                state["messages"][thread_id] = []
            return self.send_json(201, {"task": {"threadId": thread_id, "title": body.get("title", "新对话")}, "bot": bot_payload(self.server.server_port)})
        self.send_json(404, {"error": f"no route {path}"})

    def do_PATCH(self):
        path = urlparse(self.path).path
        if not self.authed():
            return self.denied()
        body = self.read_json()
        if path.endswith("/model"):
            selection = body.get("modelSelection") if isinstance(body.get("modelSelection"), dict) else body
            if selection.get("instanceId") and selection.get("model"):
                with state_lock:
                    state["model"] = {"instanceId": selection["instanceId"], "model": selection["model"]}
            print("[mock] model", state["model"], flush=True)
            return self.send_json(200, {"bot": bot_payload(self.server.server_port)})
        if path.startswith("/api/bots/"):
            print("[mock] patch", body, flush=True)
            bot = bot_payload(self.server.server_port)
            bot.update({k: v for k, v in body.items() if k in ("name", "pinned", "hidden", "notifications")})
            return self.send_json(200, {"bot": bot})
        self.send_json(404, {"error": f"no route {path}"})

    def accept_message(self, body, room=False):
        thread_id = body.get("threadId") or ("thread-room" if room else "thread-main")
        message = {
            "id": next_id("msg"),
            "role": "user",
            "kind": "text",
            "text": body.get("text", ""),
            "createdAt": now_ms(),
            "clientId": body.get("clientId"),
        }
        if body.get("attachments"):
            message["attachments"] = body["attachments"]
        with state_lock:
            state["messages"].setdefault(thread_id, []).append(message)
        broadcast("message", threadId=thread_id, message=message)
        if not room:
            threading.Timer(0.4, self.reply, args=(thread_id, body.get("text", ""))).start()
        return self.send_json(202, {"ok": True, "message": message})

    def reply(self, thread_id, text):
        message = {
            "id": next_id("msg"),
            "role": "bot",
            "kind": "text",
            "text": f"收到：{text}" if text else "收到。",
            "createdAt": now_ms(),
        }
        with state_lock:
            state["messages"].setdefault(thread_id, []).append(message)
        broadcast("message", threadId=thread_id, message=message)

    def event_stream(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "keep-alive")
        self.end_headers()
        channel = queue.Queue(maxsize=256)
        with state_lock:
            subscribers.append(channel)
        try:
            self.write_frame(1, {"kind": "hello", "resumed": False})
            while True:
                try:
                    ident, frame = channel.get(timeout=5)
                except queue.Empty:
                    self.wfile.write(b": keepalive\n\n")
                    self.wfile.flush()
                    continue
                self.write_frame(ident, frame)
        except (BrokenPipeError, ConnectionResetError):
            pass
        finally:
            with state_lock:
                if channel in subscribers:
                    subscribers.remove(channel)

    def write_frame(self, ident, frame):
        payload = f"id: {ident}\ndata: {json.dumps(frame)}\n\n".encode()
        self.wfile.write(payload)
        self.wfile.flush()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=8799)
    args = parser.parse_args()
    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    server.daemon_threads = True
    print(f"mock companion on http://127.0.0.1:{args.port} (code {PAIR_CODE})", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
