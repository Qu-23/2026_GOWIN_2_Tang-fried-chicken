#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
bridge.py —— 手机网页 ↔ 60K 串口 桥 (2026-11-02)

为什么需要它
------------
安卓 Chrome 既没有 Web Serial，Web Bluetooth 也只认 BLE，
而 JDY-31 是经典蓝牙 SPP —— 手机浏览器**无法**直接连它。
所以用笔记本做中继：

    手机 App(浏览器)  --Wi-Fi/HTTP+WebSocket-->  笔记本 bridge.py  --串口-->  60K

演示时观众只看得到"手机 App 在弹琴"，笔记本在包里也无所谓。

串口可以选：
  * USB 串口 (BL616, uart_rx 脚 V14)  —— 只能写，收不到板子回传
  * 蓝牙 SPP 虚拟串口 (JDY-31 配对后 Windows 会给一个 COMx)
    —— 能收到心跳 A5 55 xx 和演奏事件回传 E60,200,000

用法
----
    python tools/bridge.py                       # 默认 0.0.0.0:8080，串口未连接
    python tools/bridge.py --serial COM5         # 启动即连
    python tools/bridge.py --mock                # 无硬件：写出去的字节原样回显
    python tools/bridge.py --port 8080 --baud 115200

打开手机浏览器访问   http://<笔记本局域网IP>:8080/
（bridge 会把 web/ 目录当静态站点，所以 app.html 与接口同源，不用配 CORS）

协议
----
WS 客户端 → 服务端（JSON 文本帧）：
    {"t":"note","n":60,"on":1,"v":200,"w":0,"ep":0,"vib":0}
    {"t":"fx","sel":1,"mix":2,"rev":0,"dly":60}
    {"t":"expr","glide":0,"vib":2}
    {"t":"tst","on":1}
    {"t":"raw","hex":"a5 80 3c c8"}
    {"t":"text","s":"N60\\n"}              # 给 bt_text / bt_song 的文本命令
    {"t":"port","port":"COM5","baud":115200}
服务端 → 客户端：
    {"t":"status", ...}                   # 串口状态 / 客户端数
    {"t":"rx","hex":"...","ascii":"..."}  # 板子回传（心跳 / 事件）
    {"t":"log","msg":"..."}

HTTP 接口：
    GET  /api/ports      串口列表
    GET  /api/status     状态
    POST /api/connect    {"port":"COM5","baud":115200}
    POST /api/disconnect
    POST /api/send       {"hex":"..."}
    POST /api/save       {"name":"...","data":{...}}   录音/曲谱落盘
    GET  /api/files      已落盘的录音与曲谱
"""

import argparse
import base64
import hashlib
import json
import logging
from logging.handlers import RotatingFileHandler
import math
import os
import re
import socket
import struct
import sys
import tempfile
import threading
import time
import traceback
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer as BaseHTTPServer
from urllib.parse import urlparse, unquote
from bt_socket import BluetoothSerial

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
WEB_ROOT = os.path.join(ROOT, "web")
DATA_DIR = os.path.join(HERE, "captures")
LOG = logging.getLogger('mega60k.bridge')


class RuntimeLease:
    """One relay per Windows user, shared by root, demo and copied packages.

    The OS releases the byte lock when a process exits, including a forced
    console close. Keep the file in place so deleting it cannot split ownership.
    """
    def __init__(self, path=None):
        self.path = path or os.path.join(tempfile.gettempdir(), 'mega60k-relay.lock')
        self.file = None

    def acquire(self):
        handle = open(self.path, 'a+b')
        handle.seek(0, os.SEEK_END)
        if not handle.tell():
            handle.write(b' ');handle.flush()
        handle.seek(0)
        try:
            if os.name == 'nt':
                import msvcrt
                msvcrt.locking(handle.fileno(), msvcrt.LK_NBLCK, 1)
            else:
                import fcntl
                fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError as error:
            handle.close()
            raise RuntimeError('Another Mega60K relay is running. Close its window or run stop_app.cmd first.') from error
        self.file = handle

    def release(self):
        if self.file is not None:
            self.file.close();self.file = None


class ThreadingHTTPServer(BaseHTTPServer):
    # SO_REUSEADDR permits two Windows servers to bind the same port. This can
    # leave a second Bluetooth owner invisible behind the first webpage.
    allow_reuse_address = False
    allow_reuse_port = False

    def server_bind(self):
        if os.name == 'nt':
            self.socket.setsockopt(socket.SOL_SOCKET, socket.SO_EXCLUSIVEADDRUSE, 1)
        super().server_bind()

try:
    import serial
    from serial.tools import list_ports
    HAVE_SERIAL = True
except Exception:                                    # pragma: no cover
    HAVE_SERIAL = False


# ==============================================================
#  串口
# ==============================================================
class SerialLink:
    def __init__(self, mock=False):
        self.mock = mock
        self.port = None
        self.baud = 115200
        self.ser = None
        self.lock = threading.RLock()
        self.connect_lock = threading.Lock()
        self.connect_cancel = None
        self.connecting = False
        self.attempts = 0
        self.failures = 0
        self.next_retry = 0
        self.err = ""
        self.reader = None
        self.alive = True
        self.on_rx = None                            # callback(bytes)
        self.tx_count = 0
        self.rx_count = 0
        self.retry_port = None
        self.last_write = time.monotonic()
        self.keepalive_count = 0
        self.binary_left = 0

    # ---------- 连接 ----------
    def open(self, port, baud=115200):
        with self.lock:
            if self.is_open() and self.port == port and self.baud == baud:
                return True, 'already connected'
            if self.connecting:
                return False, 'Connection in progress; wait or disconnect first.'
            self.retry_port = port if port.upper().startswith('BT:') else None
        return self._open(port, baud)

    def _open(self, port, baud, retry=False):
        if not self.connect_lock.acquire(blocking=False):
            return False, 'Connection in progress; wait or disconnect first.'
        cancel = threading.Event()
        connection = None
        try:
            with self.lock:
                if not self.alive or (retry and self.retry_port != port):
                    return False, 'Connection cancelled'
                self.close(preserve_retry=True)
                self.connect_cancel = cancel
                self.port, self.baud = port, baud
                self.connecting = True
                self.attempts += 1
            self._emit_status()
            LOG.info('Connecting target=%s attempt=%d', port, self.attempts)
            native_bt = port.upper().startswith('BT:')
            if not self.mock:
                if not native_bt and not HAVE_SERIAL:
                    raise RuntimeError('没有 pyserial，请先 python -m pip install pyserial')
                # A Windows COM open may block. Do not hold the state lock:
                # disconnect/exit must cancel it and reject any late handle.
                connection = (BluetoothSerial(port[3:], cancel=cancel) if native_bt else
                              serial.Serial(port, baud, timeout=0.05, write_timeout=1.0))
            with self.lock:
                if cancel.is_set() or not self.alive:
                    if connection is not None:connection.close()
                    return False, 'Connection cancelled'
                self.ser = connection
                self.err = ''
                self.failures = 0
                self.next_retry = 0
                self.last_write = time.monotonic()
                if connection is not None:
                    self.reader = threading.Thread(target=self._read_loop, args=(connection,), daemon=True)
                    self.reader.start()
            LOG.info('Connected target=%s transport=%s', port, 'rfcomm' if native_bt else 'serial')
            return True, 'mock' if self.mock else 'ok'
        except Exception as error:
            with self.lock:
                if cancel.is_set() or not self.alive:
                    return False, 'Connection cancelled'
                self.err = '%s: %s' % (type(error).__name__, error)
                self.failures += 1
                self.next_retry = time.monotonic() + min(30, 2 ** min(self.failures, 5))
            LOG.warning('Connect failed target=%s error=%s', port, self.err)
            return False, self.err
        finally:
            with self.lock:
                self.connecting = False
                if self.connect_cancel is cancel:self.connect_cancel = None
            self.connect_lock.release()
            self._emit_status()

    def close(self, expected=None, preserve_retry=False):
        with self.lock:
            if expected is not None and self.ser is not expected:
                return
            if expected is None and not preserve_retry:
                self.retry_port = None
            if expected is None and self.connect_cancel is not None:
                self.connect_cancel.set()
            s, self.ser = self.ser, None
            if s is not None:
                try:
                    s.close()
                except Exception:
                    pass
        self._emit_status()

    def is_open(self):
        return self.mock or (self.ser is not None and self.ser.is_open)

    # ---------- 收发 ----------
    def write(self, data):
        if not data:
            return False
        if self.mock:
            self.tx_count += len(data)
            threading.Timer(0.02, lambda: self._rx(data)).start()
            return True
        with self.lock:
            if self.ser is None or not self.ser.is_open:
                return False
            connection = self.ser
            written = None
            try:
                written = self.ser.write(data)
                self.tx_count += written
                self._track_binary(data[:written])
                if written != len(data):
                    raise OSError('Incomplete serial write: %d/%d' % (written,len(data)))
                self.last_write = time.monotonic()
                return True
            except Exception as e:
                if written is None and hasattr(connection,'last_write_count'):
                    progress=connection.last_write_count
                    self.tx_count+=progress;self._track_binary(data[:progress])
                self.err = "%s: %s" % (type(e).__name__, e)
                self.close(expected=connection)
                return False

    def _track_binary(self, data):
        # Payload A5 is data. Preserve partial frame state across reconnects.
        for value in data:
            if self.binary_left:self.binary_left-=1
            elif value==0xA5:self.binary_left=3

    def maintain(self):
        """One pending connection, spaced retries, and frame-safe idle keepalive."""
        reconnect = None
        with self.lock:
            if not self.alive or not self.retry_port or self.connecting:
                return
            if not self.is_open():
                if time.monotonic() >= self.next_retry:
                    reconnect = (self.retry_port, self.baud)
            elif not self.binary_left and time.monotonic()-self.last_write >= 2:
                connection=self.ser
                try:
                    # NUL has no command meaning in UART/bt_text/bt_song idle.
                    # This is transport keepalive, never a note or FX change.
                    if connection.write(b'\x00') != 1:raise OSError('SPP keepalive incomplete')
                    self.last_write=time.monotonic();self.keepalive_count+=1
                except Exception as e:
                    self.err='%s: %s'%(type(e).__name__,e)
                    LOG.warning('Keepalive failed target=%s error=%s', self.port, self.err)
                    self.close(expected=connection)
        if reconnect:self._open(*reconnect, retry=True)

    def _read_loop(self, connection):
        buf = bytearray()
        last = time.time()
        while self.alive and self.ser is connection:
            try:
                n = connection.in_waiting
                chunk = connection.read(n if n else 1)
            except Exception as e:
                with self.lock:
                    if self.ser is connection:
                        self.err = "%s: %s" % (type(e).__name__, e)
                        LOG.warning('Read failed target=%s error=%s', self.port, self.err)
                break
            if self.ser is not connection:
                break
            if chunk:
                buf += chunk
                last = time.time()
            # 攒 30ms 或者攒够 64 字节再上报，避免一帧字节被拆成好几条消息
            if buf and (len(buf) >= 64 or time.time() - last > 0.03):
                self._rx(bytes(buf))
                buf.clear()
        if buf and self.ser is connection:
            self._rx(bytes(buf))
        self.close(expected=connection)

    def _rx(self, data):
        self.rx_count += len(data)
        if self.on_rx:
            try:
                self.on_rx(data)
            except Exception:
                traceback.print_exc()

    def _emit_status(self):
        if self.on_status:
            try:
                self.on_status()
            except Exception:
                pass

    on_status = None

    def status(self):
        return {
            "open": self.is_open(),
            "port": self.port,
            "transport": "rfcomm" if str(self.port).upper().startswith('BT:') else "serial",
            "baud": self.baud,
            "mock": self.mock,
            "error": self.err,
            "tx": self.tx_count,
            "rx": self.rx_count,
            "keepalive": self.keepalive_count,
            "connecting": self.connecting,
            "attempts": self.attempts,
            "retrying": bool(self.retry_port),
            "retry_in": max(0, math.ceil(self.next_retry-time.monotonic())) if self.retry_port and not self.is_open() else 0,
        }


# ==============================================================
def available_ports():
    """Describe Windows COM identity; incoming SPP is not the remote module."""
    ports=[]
    if HAVE_SERIAL:
        for p in list_ports.comports():
            hwid=p.hwid.upper()
            kind=('bt_incoming' if '000000000000_' in hwid else 'bt_outgoing') if 'BTHENUM' in hwid else 'serial'
            address=re.search(r'([0-9A-F]{12})_',hwid) if kind=='bt_outgoing' else None
            ports.append({'device':p.device,'desc':p.description,'hwid':p.hwid,
                          'kind':kind,'address':address[1] if address else ''})
    return sorted(ports,key=lambda p:({'bt_outgoing':0,'serial':1,'bt_incoming':2}[p['kind']],p['device']))

def preferred_port():
    ports=[p for p in available_ports() if p['kind']=='bt_outgoing']
    if len(ports)==1:
        p=ports[0]
        return 'BT:'+p['address'] if os.name=='nt' and p['address'] else p['device']
    # Never guess among multiple remote modules or silently pick an incoming port.
    if ports:return ''
    usb=[p for p in available_ports() if 'VID:PID=0403:6010' in p['hwid'].upper()]
    return usb[0]['device'] if len(usb)==1 else ''

#  最小 WebSocket 服务端（只用标准库，不依赖 websockets 包）
# ==============================================================
WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


class WSClient:
    def __init__(self, handler):
        self.h = handler
        self.rfile = handler.rfile
        self.wfile = handler.wfile
        self.wlock = threading.Lock()
        self.open = True

    def send(self, obj):
        if not self.open:
            return
        try:
            self.send_text(json.dumps(obj, ensure_ascii=False))
        except Exception:
            self.open = False

    def send_text(self, s):
        data = s.encode("utf-8")
        n = len(data)
        if n < 126:
            hdr = struct.pack("!BB", 0x81, n)
        elif n < 65536:
            hdr = struct.pack("!BBH", 0x81, 126, n)
        else:
            hdr = struct.pack("!BBQ", 0x81, 127, n)
        with self.wlock:
            if not self.open:
                return
            self.wfile.write(hdr + data)
            self.wfile.flush()

    def _recv_exact(self, n):
        buf = b""
        while len(buf) < n:
            chunk = self.rfile.read(n - len(buf))
            if not chunk:
                raise ConnectionError("eof")
            buf += chunk
        return buf

    def recv(self):
        """返回 (opcode, payload)；连接断开返回 (None, None)"""
        try:
            b = self._recv_exact(2)
        except Exception:
            return None, None
        op = b[0] & 0x0F
        masked = b[1] & 0x80
        n = b[1] & 0x7F
        if n == 126:
            n = struct.unpack("!H", self._recv_exact(2))[0]
        elif n == 127:
            n = struct.unpack("!Q", self._recv_exact(8))[0]
        mask = self._recv_exact(4) if masked else b"\0\0\0\0"
        payload = self._recv_exact(n) if n else b""
        if masked:
            payload = bytes(payload[i] ^ mask[i & 3] for i in range(n))
        return op, payload

    def pong(self, payload=b""):
        with self.wlock:
            if self.open:
                self.wfile.write(struct.pack("!BB", 0x8A, len(payload)) + payload)
                self.wfile.flush()

    def close(self):
        self.open = False


# ==============================================================
#  全局状态
# ==============================================================
CLIENTS = set()
CLIENTS_LOCK = threading.Lock()
LINK = None


def broadcast(obj):
    with CLIENTS_LOCK:
        dead = []
        for c in CLIENTS:
            try:
                c.send(obj)
            except Exception:
                dead.append(c)
        for c in dead:
            CLIENTS.discard(c)


def push_status():
    if LINK is None:
        return
    st = LINK.status()
    st["t"] = "status"
    st["clients"] = len(CLIENTS)
    broadcast(st)


def build_note(msg):
    n = int(msg.get("n", 60))
    on = 1 if msg.get("on") else 0
    v = int(msg.get("v", 200)) & 0xFF
    w = int(msg.get("w", 0)) & 3
    ep = int(msg.get("ep", 0)) & 3
    vib = int(msg.get("vib", 0)) & 3
    cmd = (0x80 if on else 0x00) | w | (ep << 2) | (vib << 4)
    return bytes([0xA5, cmd, n & 0x7F, v])


def build_fx(msg):
    sel = int(msg.get("sel", 0)) & 3
    mix = int(msg.get("mix", 0)) & 3
    rev = int(msg.get("rev", 0)) & 3
    dly = int(msg.get("dly", 60)) & 0xFF
    return bytes([0xA5, 0x40, sel | (mix << 2) | (rev << 4), dly])


def build_expr(msg):
    g = int(msg.get("glide", 0)) & 3
    v = int(msg.get("vib", 0)) & 3
    return bytes([0xA5, 0x40, 0x80 | g | (v << 2), 0x00])


def build_tst(msg):
    return bytes([0xA5, 0x40, 0x40 | (1 if msg.get("on") else 0), 0x00])


def hex2bytes(s):
    s = "".join(ch for ch in str(s) if ch in "0123456789abcdefABCDEF")
    if len(s) % 2:
        s = s[:-1]
    return bytes.fromhex(s)


# ==============================================================
#  HTTP / WS 处理
# ==============================================================
MIME = {
    ".html": "text/html; charset=utf-8",
    ".js": "application/javascript; charset=utf-8",
    ".css": "text/css; charset=utf-8",
    ".json": "application/json; charset=utf-8",
    ".png": "image/png",
    ".svg": "image/svg+xml",
    ".ico": "image/x-icon",
    ".wav": "audio/wav",
    ".mid": "audio/midi",
}


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "m60k-bridge/1.0"

    def log_message(self, fmt, *args):
        if os.environ.get("BRIDGE_VERBOSE"):
            sys.stderr.write("  %s\n" % (fmt % args))

    # ---------------- 工具 ----------------
    def _send(self, code, body, ctype="application/json; charset=utf-8", extra=None):
        if isinstance(body, (dict, list)):
            body = json.dumps(body, ensure_ascii=False).encode("utf-8")
        elif isinstance(body, str):
            body = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Access-Control-Allow-Origin", "*")
        if extra:
            for k, v in extra.items():
                self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _json_body(self):
        n = int(self.headers.get("Content-Length") or 0)
        if not n:
            return {}
        try:
            return json.loads(self.rfile.read(n).decode("utf-8"))
        except Exception:
            return {}

    # ---------------- GET ----------------
    def do_GET(self):
        path = unquote(urlparse(self.path).path)
        if path == "/ws":
            return self._ws()
        if path.startswith("/api/"):
            return self._api_get(path)
        return self._static(path)

    def do_HEAD(self):
        self.do_GET()

    # ---------------- POST ----------------
    def do_POST(self):
        path = unquote(urlparse(self.path).path)
        body = self._json_body()
        if path == "/api/connect":
            port = body.get("port") or ""
            baud = int(body.get("baud") or 115200)
            ok, msg = LINK.open(port, baud) if port else (False, "没给串口")
            push_status()
            return self._send(200, {"ok": ok, "msg": msg, "status": LINK.status()})
        if path == "/api/disconnect":
            LINK.close()
            push_status()
            return self._send(200, {"ok": True, "status": LINK.status()})
        if path == "/api/send":
            data = hex2bytes(body.get("hex", ""))
            ok = LINK.write(data)
            return self._send(200, {"ok": ok, "n": len(data)})
        if path == "/api/save":
            return self._save(body)
        return self._send(404, {"ok": False, "msg": "no such api"})

    # ---------------- API ----------------
    def _api_get(self, path):
        if path == "/api/ports":
            ports = available_ports()
            if os.name=='nt':
                native=[dict(p,device='BT:'+p['address'],desc='SPP 直连 · '+p['desc'])
                        for p in ports if p['kind']=='bt_outgoing' and p['address']]
                ports=native+ports
            return self._send(200, {"ok": True, "ports": ports,
                                    "recommended":preferred_port(),"have_serial": HAVE_SERIAL})
        if path == "/api/status":
            st = LINK.status()
            st["ok"] = True
            st["clients"] = len(CLIENTS)
            st["hostname"] = socket.gethostname()
            st["lan_ip"] = lan_ip()
            return self._send(200, st)
        if path == "/api/files":
            out = []
            if os.path.isdir(DATA_DIR):
                for fn in sorted(os.listdir(DATA_DIR)):
                    if fn.endswith(".json"):
                        fp = os.path.join(DATA_DIR, fn)
                        out.append({"name": fn, "size": os.path.getsize(fp),
                                    "mtime": int(os.path.getmtime(fp))})
            return self._send(200, {"ok": True, "files": out})
        return self._send(404, {"ok": False, "msg": "no such api"})

    def _save(self, body):
        os.makedirs(DATA_DIR, exist_ok=True)
        name = str(body.get("name") or "capture")
        name = "".join(ch for ch in name if ch.isalnum() or ch in "-_. ")
        name = name.strip() or "capture"
        if not name.endswith(".json"):
            name += ".json"
        fp = os.path.join(DATA_DIR, name)
        with open(fp, "w", encoding="utf-8") as f:
            json.dump(body.get("data"), f, ensure_ascii=False, indent=1)
        return self._send(200, {"ok": True, "path": fp, "name": name})

    # ---------------- 静态文件 ----------------
    def _static(self, path):
        if path in ("/", ""):
            path = "/app.html"
        fp = os.path.normpath(os.path.join(WEB_ROOT, path.lstrip("/")))
        if not fp.startswith(WEB_ROOT) or not os.path.isfile(fp):
            return self._send(404, "<h1>404</h1>", "text/html; charset=utf-8")
        ext = os.path.splitext(fp)[1].lower()
        with open(fp, "rb") as f:
            data = f.read()
        self._send(200, data, MIME.get(ext, "application/octet-stream"))

    # ---------------- WebSocket ----------------
    def _ws(self):
        # An upgraded socket cannot return to HTTP keep-alive parsing on exit.
        self.close_connection = True
        key = self.headers.get("Sec-WebSocket-Key")
        if not key:
            return self._send(400, {"ok": False, "msg": "not a websocket"})
        acc = base64.b64encode(
            hashlib.sha1((key + WS_GUID).encode()).digest()).decode()
        self.send_response(101, "Switching Protocols")
        self.send_header("Upgrade", "websocket")
        self.send_header("Connection", "Upgrade")
        self.send_header("Sec-WebSocket-Accept", acc)
        self.end_headers()
        self.wfile.flush()

        cli = WSClient(self)
        with CLIENTS_LOCK:
            CLIENTS.add(cli)
        push_status()

        try:
            while cli.open:
                op, payload = cli.recv()
                if op is None:
                    break
                if op == 0x8:
                    break
                if op == 0x9:
                    cli.pong(payload)
                    continue
                if op not in (0x1, 0x2):
                    continue
                try:
                    msg = json.loads(payload.decode("utf-8"))
                except Exception:
                    continue
                self._handle_ws_msg(msg)
        except Exception:
            pass
        finally:
            cli.close()
            with CLIENTS_LOCK:
                CLIENTS.discard(cli)
            push_status()

    def _handle_ws_msg(self, msg):
        t = msg.get("t")
        if t == "port":
            LINK.open(msg.get("port") or "", int(msg.get("baud") or 115200))
            push_status()
            return
        if t == "note":
            data = build_note(msg)
        elif t == "fx":
            data = build_fx(msg)
        elif t == "expr":
            data = build_expr(msg)
        elif t == "tst":
            data = build_tst(msg)
        elif t == "raw":
            data = hex2bytes(msg.get("hex", ""))
        elif t == "text":
            data = str(msg.get("s", "")).encode("utf-8")
        elif t == "ping":
            broadcast({"t": "pong", "ts": msg.get("ts")})
            return
        else:
            return
        ok = LINK.write(data)
        if not ok and not LINK.is_open():
            broadcast({"t": "log", "msg": "串口未连接，指令被丢弃"})


def lan_ip():
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except Exception:
        return "127.0.0.1"


def qr_to_file(url, open_image=True):
    """Write a QR PNG next to this script and open it.

    Printing an ASCII QR in the console is fragile on Chinese Windows: the
    console code page is GBK and the half-block glyphs are not encodable, so
    qrcode's print_ascii() raises UnicodeEncodeError.  A PNG + the OS viewer
    is more reliable, and the phone just scans the screen.

    Optional dependency (qrcode + Pillow).  Silently skipped when missing.
    """
    try:
        import qrcode
    except Exception:
        return
    try:
        path = os.path.abspath(os.path.join(DATA_DIR, os.pardir, "phone_qr.png"))
        qrcode.make(url).save(path)
        print("   扫码  %s" % path)
        if os.name == "nt" and open_image:
            try:
                os.startfile(path)   # noqa: S606 - demo convenience
            except Exception:
                pass
    except Exception as e:
        print("   (二维码生成失败: %s)" % e)


# ==============================================================
def main():
    ap = argparse.ArgumentParser(description="手机网页 ↔ 60K 串口桥")
    ap.add_argument("--port", type=int, default=8080, help="HTTP 端口")
    ap.add_argument("--serial", default="", help="启动就连接的串口，如 COM5")
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--mock", action="store_true", help="无硬件：写出去的数据原样回显")
    ap.add_argument("--bind", default="0.0.0.0")
    ap.add_argument("--auto", action="store_true", help="优先连接唯一的出站蓝牙 COM")
    ap.add_argument("--host-ip", default="", help="指定手机可访问的 Wi-Fi IPv4 地址")
    ap.add_argument("--no-open", action="store_true", help="生成二维码但不弹出图片")
    args = ap.parse_args()

    lease = RuntimeLease()
    try:
        lease.acquire()
    except RuntimeError as error:
        print(str(error), file=sys.stderr, flush=True)
        return 2
    try:
        return run_server(args)
    except OSError as error:
        LOG.error('Relay could not start: %s', error)
        return 2
    finally:
        if LINK is not None:
            LINK.alive = False
            LINK.close()
        lease.release()


def run_server(args):
    global LINK
    log_dir = os.path.join(HERE, 'logs')
    os.makedirs(log_dir, exist_ok=True)
    log_path = os.path.join(log_dir, 'bridge.log')
    LOG.setLevel(logging.INFO)
    formatter = logging.Formatter('%(asctime)s [%(process)d] %(levelname)s %(message)s')
    for handler in (logging.StreamHandler(sys.stdout),
                    RotatingFileHandler(log_path, maxBytes=2_000_000, backupCount=2, encoding='utf-8')):
        handler.setFormatter(formatter);LOG.addHandler(handler)
    LOG.info('Relay starting script=%s target=%s', __file__, args.serial or 'auto' if args.auto else args.serial)

    LINK = SerialLink(mock=args.mock)
    LINK.on_status = push_status

    def on_rx(data):
        broadcast({"t": "rx", "hex": data.hex(),
                   "ascii": "".join(chr(b) if 32 <= b < 127 else "." for b in data)})
    LINK.on_rx = on_rx

    srv = ThreadingHTTPServer((args.bind, args.port), Handler)
    srv.daemon_threads = True
    ip = args.host_ip or lan_ip()
    selected=args.serial or (preferred_port() if args.auto else '')
    # COM opening can wait on a remote Bluetooth device. HTTP remains usable
    # throughout, and a failed serial connection never prevents loading the app.
    if selected:
        def connect_initial():
            ok,msg=LINK.open(selected,args.baud)
            print('串口 %s: %s' % (selected,msg),flush=True)
        threading.Thread(target=connect_initial,daemon=True).start()
    def maintain_native():
        while LINK.alive:
            time.sleep(2)
            LINK.maintain()
    threading.Thread(target=maintain_native,daemon=True).start()
    print("=" * 62)
    print(" 60K 乐器桥 已启动")
    print("   进程  %d    日志  %s" % (os.getpid(), log_path))
    print("   本机  http://127.0.0.1:%d/" % args.port)
    print("   手机  http://%s:%d/    <- 手机浏览器打开这个" % (ip, args.port))
    print("   串口  %s" % (("mock 模式" if args.mock else
                           (selected or "未连接，在网页里选串口"))))
    if HAVE_SERIAL:
        ps = list_ports.comports()
        if ps:
            print("   可用串口:")
            for p in ps:
                print("        %-8s %s" % (p.device, p.description))
        else:
            print("   可用串口: 没找到（板子插上了吗？蓝牙要先配对）")
    else:
        print("   !! 没有 pyserial: python -m pip install pyserial")
    _qr = "http://%s:%d/" % (ip, args.port)
    print("=" * 62)
    qr_to_file(_qr,open_image=not args.no_open)
    print("  Ctrl+C 退出；也可运行 stop_app.cmd。关闭后不再重连。")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        print("\n再见")
    finally:
        LINK.alive = False
        LINK.close()
        srv.server_close()
        LOG.info('Relay stopped; Bluetooth released')


if __name__ == "__main__":
    sys.exit(main())
