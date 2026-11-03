"""Windows RFCOMM SPP transport, independent of the virtual COM driver.

Layout/constants follow Microsoft's ws2bth.h (SOCKADDR_BTH is pack(1)).
The SPP service GUID resolves its RFCOMM channel through Windows SDP.
"""
import ctypes,os,re,select,socket,struct,time,uuid

def address_bytes(mac):
    compact=re.sub('[:-]','',mac)
    if not re.fullmatch('[0-9A-Fa-f]{12}',compact):raise ValueError('Invalid Bluetooth MAC')
    return struct.pack('<HQ16sL',32,int(compact,16),
                       uuid.UUID('00001101-0000-1000-8000-00805f9b34fb').bytes_le,0)

class BluetoothSerial:
    def __init__(self,mac,timeout=10,cancel=None):
        if os.name!='nt':raise OSError('Native Bluetooth SPP requires Windows')
        address=address_bytes(mac)
        ws=ctypes.WinDLL('Ws2_32.dll')
        ws.connect.argtypes=[ctypes.c_size_t,ctypes.c_void_p,ctypes.c_int]
        ws.connect.restype=ctypes.c_int;ws.WSAGetLastError.restype=ctypes.c_int
        self.sock=socket.socket(32,socket.SOCK_STREAM,3)
        self.is_open=False;self.sock.setblocking(False)
        self.last_write_count=0
        try:
            result=ws.connect(self.sock.fileno(),ctypes.create_string_buffer(address),len(address))
            error=ws.WSAGetLastError() if result else 0
            if error not in (0,10035):raise OSError(error,ctypes.FormatError(error))
            if error:
                deadline=time.monotonic()+timeout
                while True:
                    if cancel is not None and cancel.is_set():raise ConnectionAbortedError('SPP connection cancelled')
                    remaining=deadline-time.monotonic()
                    if remaining<=0:raise TimeoutError(10060,'SPP connection timed out')
                    _,ready,failed=select.select([], [self.sock], [self.sock], min(.1,remaining))
                    if not ready and not failed:continue
                    error=self.sock.getsockopt(socket.SOL_SOCKET,socket.SO_ERROR)
                    if error:raise OSError(error,ctypes.FormatError(error))
                    break
            if cancel is not None and cancel.is_set():raise ConnectionAbortedError('SPP connection cancelled')
            self.is_open=True
        except BaseException:
            self.sock.close();raise

    @property
    def in_waiting(self):
        return 4096 if select.select([self.sock],[],[],0)[0] else 0

    def read(self,n):
        if not select.select([self.sock],[],[],.05)[0]:return b''
        data=self.sock.recv(n)
        if not data:raise ConnectionError('Bluetooth SPP disconnected')
        return data

    def write(self,data):
        self.last_write_count=0
        remaining=memoryview(data);deadline=time.monotonic()+1
        while remaining:
            wait=max(0,deadline-time.monotonic())
            if not wait or not select.select([],[self.sock],[],wait)[1]:raise TimeoutError('SPP write timeout')
            try:n=self.sock.send(remaining)
            except BlockingIOError:continue
            if not n:raise ConnectionError('Bluetooth SPP disconnected during write')
            self.last_write_count+=n
            remaining=remaining[n:]
        return len(data)

    def close(self):
        self.is_open=False
        try:self.sock.shutdown(socket.SHUT_RDWR)
        except OSError:pass
        self.sock.close()
