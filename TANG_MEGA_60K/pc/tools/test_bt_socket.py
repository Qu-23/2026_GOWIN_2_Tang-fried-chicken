import socket,struct,unittest,uuid,threading,types
from unittest.mock import patch
import bt_socket
from bt_socket import address_bytes,BluetoothSerial

class BluetoothTransportTests(unittest.TestCase):
    @unittest.skipUnless(bt_socket.os.name=='nt','Windows Winsock cancellation')
    def test_cancelled_pending_connect_releases_its_socket(self):
        cancelled=threading.Event()
        class Socket:
            closed=False
            def fileno(self):return 123
            def setblocking(self,value):pass
            def close(self):self.closed=True
        pending=Socket()
        def connect(*args):return -1
        def get_error():return 10035
        ws=types.SimpleNamespace(connect=connect,WSAGetLastError=get_error)
        def wait(*args):
            cancelled.set();return [],[],[]
        with patch.object(bt_socket.ctypes,'WinDLL',return_value=ws),\
             patch.object(bt_socket.socket,'socket',return_value=pending),\
             patch.object(bt_socket.select,'select',side_effect=wait):
            with self.assertRaises(ConnectionAbortedError):
                BluetoothSerial('4A1814B14943',cancel=cancelled)
        self.assertTrue(pending.closed,'Cancelled Winsock attempt leaked its socket')

    def test_sdp_address_layout_and_mac(self):
        raw=address_bytes('4A:18:14:B1:49:43')
        self.assertEqual(len(raw),30)
        family,mac,service,channel=struct.unpack('<HQ16sL',raw)
        self.assertEqual(family,32);self.assertEqual(mac,0x4A1814B14943)
        self.assertEqual(uuid.UUID(bytes_le=service),uuid.UUID('00001101-0000-1000-8000-00805f9b34fb'))
        self.assertEqual(channel,0)
        with self.assertRaises(ValueError):address_bytes('not a MAC')
    def test_real_stream_read_write_eof_and_idle(self):
        left,right=socket.socketpair();link=BluetoothSerial.__new__(BluetoothSerial)
        link.sock=left;left.setblocking(False);link.is_open=True
        try:
            self.assertEqual(link.read(1),b'')
            self.assertEqual(link.write(b'\xa5\x80\x3c\xc8'),4)
            self.assertEqual(right.recv(4),b'\xa5\x80\x3c\xc8')
            right.sendall(b'E60,200,000\r\n')
            self.assertEqual(link.read(link.in_waiting),b'E60,200,000\r\n')
            right.close()
            with self.assertRaises(ConnectionError):link.read(1)
        finally:link.close();right.close()
        self.assertFalse(link.is_open)

if __name__=='__main__':unittest.main()
