"""Regression and loopback tests; no Bluetooth/board required."""
import base64,json,socket,struct,threading,time,types,unittest,urllib.request,tempfile
from pathlib import Path
from unittest.mock import patch
import bridge

class HeldPort:
    def __init__(self):
        self.is_open=True;self.entered=threading.Event();self.release=threading.Event()
    @property
    def in_waiting(self):return 0
    def read(self,n):
        self.entered.set();self.release.wait(2)
        if not self.is_open:raise OSError('old port finished after close')
        return b''
    def close(self):self.is_open=False
    def write(self,data):return len(data)

class SerialTests(unittest.TestCase):
    def test_disconnect_does_not_wait_for_connect_or_accept_its_late_result(self):
        link=bridge.SerialLink();entered=threading.Event();release=threading.Event()
        closed=threading.Event();port=HeldPort();results=[]
        def delayed_open(*args,**kwargs):
            entered.set();release.wait(3);return port
        with patch.object(bridge,'BluetoothSerial',delayed_open):
            opener=threading.Thread(target=lambda:results.append(link.open('BT:4A1814B14943')))
            opener.start()
            try:
                self.assertTrue(entered.wait(1))
                closer=threading.Thread(target=lambda:(link.close(),closed.set()))
                closer.start()
                self.assertTrue(closed.wait(.3),'Disconnect blocked on the pending Windows connection')
                release.set();opener.join(1);closer.join(1)
                self.assertFalse(link.is_open(),'Cancelled connection came back after disconnect')
                self.assertFalse(port.is_open,'Late connection handle was leaked')
                self.assertFalse(results[0][0])
            finally:
                release.set();opener.join(2);link.alive=False;link.close();port.release.set()

    def test_reselecting_connected_target_preserves_live_connection(self):
        link=bridge.SerialLink();port=HeldPort()
        with patch.object(bridge,'BluetoothSerial',lambda *args,**kwargs:port):
            try:
                self.assertTrue(link.open('BT:4A1814B14943')[0])
                reader=link.reader
                self.assertTrue(link.open('BT:4A1814B14943')[0])
                self.assertIs(link.reader,reader,'Selecting the active device reopened its SPP link')
                self.assertTrue(port.is_open)
            finally:link.alive=False;link.close();port.release.set()

    def test_failed_connection_retries_are_spaced_and_manual_close_cancels_them(self):
        link=bridge.SerialLink();attempts=[]
        def unavailable(*args,**kwargs):
            attempts.append(time.monotonic());raise TimeoutError(10060,'device unavailable')
        with patch.object(bridge,'BluetoothSerial',unavailable):
            self.assertFalse(link.open('BT:4A1814B14943')[0])
            for _ in range(5):link.maintain()
            self.assertEqual(len(attempts),1,'Repeated maintenance immediately retried a timed-out device')
            self.assertGreater(link.status()['retry_in'],0)
            link.close();link.maintain()
            self.assertEqual(len(attempts),1)
            self.assertFalse(link.status()['retrying'])

    def test_old_reader_cannot_close_new_connection(self):
        a,b=HeldPort(),HeldPort();link=bridge.SerialLink()
        with patch.object(bridge,'HAVE_SERIAL',True),patch.object(bridge,'serial',
                   types.SimpleNamespace(Serial=lambda *args,**kwargs:a if args[0]=='OLD' else b),create=True):
            try:
                self.assertTrue(link.open('OLD')[0]);self.assertTrue(a.entered.wait(1))
                old=link.reader
                self.assertTrue(link.open('NEW')[0]);self.assertTrue(b.entered.wait(1))
                a.release.set();old.join(1)
                self.assertTrue(link.is_open(),'Old reader closed the replacement serial port')
                self.assertEqual(link.err,'','Old reader overwrote new connection error state')
            finally:
                link.alive=False;link.close();a.release.set();b.release.set()
    def test_failed_write_does_not_count_as_transmitted(self):
        link=bridge.SerialLink()
        self.assertFalse(link.write(b'\xa5\x80\x3c\xc8'))
        self.assertEqual(link.tx_count,0)
    def test_failed_old_write_cannot_close_replacement(self):
        link=bridge.SerialLink();formatting=threading.Event();replaced=threading.Event()
        class SlowError(OSError):
            def __str__(self):
                formatting.set();replaced.wait(.15);return 'old write failed'
        class BrokenPort(HeldPort):
            def write(self,data):raise SlowError()
        old,new=BrokenPort(),HeldPort();link.ser=old
        writer=threading.Thread(target=lambda:link.write(b'1234'));writer.start()
        self.assertTrue(formatting.wait(1))
        def replace():
            with link.lock:link.ser=new;link.err=''
            replaced.set()
        opener=threading.Thread(target=replace);opener.start()
        writer.join(1);opener.join(1)
        self.assertIs(link.ser,new,'Old write error closed a newly connected port')
        self.assertTrue(new.is_open);self.assertEqual(link.tx_count,0)
        link.close()

class PortTests(unittest.TestCase):
    def test_native_idle_keepalive_and_retry_but_manual_close_stays_closed(self):
        link=bridge.SerialLink();a,b=HeldPort(),HeldPort();writes=[]
        a.write=lambda data:(writes.append(data) or len(data))
        ports=iter([a,b])
        with patch.object(bridge,'BluetoothSerial',lambda mac,**kwargs:next(ports)):
            try:
                self.assertTrue(link.open('BT:4A1814B14943')[0])
                link.last_write=0;link.maintain()
                self.assertEqual(writes,[b'\x00'],'Keepalive must be a protocol no-op')
                self.assertEqual(link.tx_count,0,'Keepalive is not a user frame')
                link.write(b'\xa5\x80\x3c');link.last_write=0;link.maintain()
                self.assertEqual(writes[-1],b'\xa5\x80\x3c','Keepalive must not complete a partial raw frame')
                link.write(b'\xc8');link.last_write=0;link.maintain()
                self.assertEqual(writes[-1],b'\x00','Keepalive may resume after the frame is complete')
                link.close(expected=a);link.maintain()
                self.assertIs(link.ser,b,'Unexpected SPP loss should reconnect')
                link.close();link.maintain();self.assertIsNone(link.ser,'Manual close must disable retry')
            finally:link.alive=False;link.close();a.release.set();b.release.set()
    def test_outgoing_jdy_preferred_over_incoming_and_usb(self):
        ports=[types.SimpleNamespace(device='COM14',description='Bluetooth',hwid='BTHENUM\\000000000000_00000006'),
               types.SimpleNamespace(device='COM11',description='USB Debugger',hwid='USB VID:PID=0403:6010'),
               types.SimpleNamespace(device='COM15',description='Bluetooth',hwid='BTHENUM\\4A1814B14943_C00000000')]
        with patch.object(bridge,'HAVE_SERIAL',True),patch.object(bridge,'list_ports',
                           types.SimpleNamespace(comports=lambda:ports),create=True):
            self.assertEqual(bridge.preferred_port(),'BT:4A1814B14943' if bridge.os.name=='nt' else 'COM15')
    def test_incoming_port_is_not_an_auto_connection_candidate(self):
        port=types.SimpleNamespace(device='COM14',description='Bluetooth',hwid='BTHENUM\\000000000000_00000006')
        with patch.object(bridge,'HAVE_SERIAL',True),patch.object(bridge,'list_ports',
                           types.SimpleNamespace(comports=lambda:[port]),create=True):
            self.assertEqual(bridge.preferred_port(),'')
    def test_native_spp_can_open_without_pyserial(self):
        link=bridge.SerialLink();port=HeldPort()
        with patch.object(bridge,'HAVE_SERIAL',False),patch.object(bridge,'BluetoothSerial',lambda mac,**kwargs:port,create=True):
            try:
                self.assertTrue(link.open('BT:4A1814B14943')[0])
                self.assertTrue(link.is_open());self.assertTrue(link.write(b'1234'))
            finally:link.alive=False;link.close();port.release.set()

class HttpTests(unittest.TestCase):
    def setUp(self):
        bridge.LINK=bridge.SerialLink(mock=True)
        bridge.LINK.on_rx=lambda data:bridge.broadcast({'t':'rx','hex':data.hex()})
        self.server=bridge.ThreadingHTTPServer(('127.0.0.1',0),bridge.Handler)
        self.server.daemon_threads=True
        self.thread=threading.Thread(target=self.server.serve_forever,daemon=True);self.thread.start()
        self.port=self.server.server_port;self.url='http://127.0.0.1:%d'%self.port
    def tearDown(self):
        self.server.shutdown();self.server.server_close();self.thread.join(1)
        bridge.LINK.alive=False;bridge.LINK.close()
    def test_http_page_still_served_when_serial_open_fails(self):
        bridge.LINK=bridge.SerialLink()
        with patch.object(bridge,'HAVE_SERIAL',False):
            self.assertFalse(bridge.LINK.open('NOT_A_PORT')[0])
        with urllib.request.urlopen(self.url+'/') as r:self.assertIn(b'<html',r.read().lower())
        with urllib.request.urlopen(self.url+'/api/status') as r:status=json.load(r)
        self.assertFalse(status['open']);self.assertTrue(status['error'])
    def test_second_server_cannot_share_the_listening_port(self):
        duplicate=None
        try:
            with self.assertRaises(OSError):
                duplicate=bridge.ThreadingHTTPServer(('127.0.0.1',self.port),bridge.Handler)
        finally:
            if duplicate:duplicate.server_close()
    def test_recommended_native_target_exists_in_ports_response(self):
        ports=[{'device':'COM15','kind':'bt_outgoing','address':'4A1814B14943','desc':'JDY','hwid':'BTHENUM'}]
        with patch.object(bridge,'available_ports',lambda:ports),patch.object(bridge,'preferred_port',lambda:'BT:4A1814B14943'):
            with urllib.request.urlopen(self.url+'/api/ports') as r:response=json.load(r)
        if bridge.os.name=='nt':
            self.assertIn(response['recommended'],[p['device'] for p in response['ports']])
    def test_websocket_note_off_and_score_are_exact_bytes(self):
        s=socket.create_connection(('127.0.0.1',self.port),timeout=2);f=s.makefile('rb')
        key=base64.b64encode(b'1234567890123456').decode()
        s.sendall(('GET /ws HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: '+key+'\r\nSec-WebSocket-Version: 13\r\n\r\n').encode())
        self.assertIn(b'101',f.readline())
        while f.readline()!=b'\r\n':pass
        def receive():
            a,b=f.read(2);n=b&127
            if n==126:n=struct.unpack('!H',f.read(2))[0]
            elif n==127:n=struct.unpack('!Q',f.read(8))[0]
            return json.loads(f.read(n))
        def send(msg):
            data=json.dumps(msg).encode();mask=b'abcd'
            s.sendall(bytes([0x81,0x80|len(data)])+mask+bytes(v^mask[i%4] for i,v in enumerate(data)))
        try:
            cases=[({'t':'note','n':60,'on':1,'v':200,'w':0},'a5803cc8'),
                   ({'t':'note','n':60,'on':0,'v':0,'w':0},'a5003c00'),
                   ({'t':'text','s':'S120\nK60,1\nP\nX\n'},b'S120\nK60,1\nP\nX\n'.hex())]
            for msg,expected in cases:
                send(msg)
                while True:
                    reply=receive()
                    if reply.get('t')=='rx':break
                self.assertEqual(reply['hex'],expected)
        finally:
            s.shutdown(socket.SHUT_RDWR);f.close();s.close()

class LeaseTests(unittest.TestCase):
    def test_only_one_relay_can_own_runtime_even_on_different_http_ports(self):
        with tempfile.TemporaryDirectory() as temp:
            path=Path(temp)/'relay.lock'
            first=bridge.RuntimeLease(path)
            first.acquire()
            try:
                second=bridge.RuntimeLease(path)
                with self.assertRaises(RuntimeError):second.acquire()
            finally:first.release()
            second.acquire();second.release()

if __name__=='__main__':unittest.main()
