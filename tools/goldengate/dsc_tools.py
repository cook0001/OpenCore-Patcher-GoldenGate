import mmap
import os
import struct
import subprocess
import tempfile

TAHOE_DSC = "/System/Volumes/Preboot/Cryptexes/OS/System/Library/dyld/dyld_shared_cache_x86_64"
GG_DSC = "/tmp/gg_os_cryptex_ro/System/Library/dyld/dyld_shared_cache_x86_64"


class DSCReader:
    def __init__(self, base_path):
        self.base_path = base_path
        self.files = []
        self.mappings = []
        self.images = {}
        self.cache_base = None
        self._load_header()

    def close(self):
        for fd, mm in self.files:
            mm.close()
            os.close(fd)
        self.files.clear()

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, tb):
        self.close()

    def _open_subcache(self, path):
        fd = os.open(path, os.O_RDONLY)
        mm = mmap.mmap(fd, 0, access=mmap.ACCESS_READ)
        self.files.append((fd, mm))
        return mm

    def _parse_mappings(self, mm):
        m_off, m_cnt = struct.unpack_from("<II", mm, 0x10)
        for i in range(m_cnt):
            addr, size, foff, _maxp, _initp = struct.unpack_from("<QQQII", mm, m_off + i * 32)
            self.mappings.append((addr, addr + size, foff, mm))
            if self.cache_base is None or addr < self.cache_base:
                self.cache_base = addr

    def _load_header(self):
        mm0 = self._open_subcache(self.base_path)
        self._parse_mappings(mm0)
        idx_sc = 1
        while True:
            p = f"{self.base_path}.{idx_sc:02d}"
            if not os.path.exists(p):
                break
            mm = self._open_subcache(p)
            self._parse_mappings(mm)
            idx_sc += 1
        sym_p = f"{self.base_path}.symbols"
        if os.path.exists(sym_p):
            mm = self._open_subcache(sym_p)
            self._parse_mappings(mm)

        img_off, img_cnt = struct.unpack_from("<II", mm0, 0x18)
        if img_cnt == 0:
            img_off, img_cnt = struct.unpack_from("<II", mm0, 0x1C0)
        for idx in range(img_cnt):
            addr, _mtime, _inode, path_off, _pad = struct.unpack_from("<QQQII", mm0, img_off + idx * 32)
            end = mm0.find(b"\x00", path_off)
            path = mm0[path_off:end].decode("utf-8", errors="replace")
            self.images[path] = addr

    def read(self, va, size):
        for start, end, foff, mm in self.mappings:
            if start <= va and va + size <= end:
                off = foff + (va - start)
                return mm[off : off + size]
        return None

    def read_cstr(self, va, maxlen=512):
        for start, end, foff, mm in self.mappings:
            if start <= va < end:
                off = foff + (va - start)
                nul = mm.find(b"\x00", off, min(off + maxlen, len(mm)))
                if nul == -1:
                    nul = min(off + maxlen, len(mm))
                return mm[off:nul].decode("utf-8", errors="replace")
        return None

    def decode_ptr(self, val):
        if val == 0:
            return 0
        if 0x7FF800000000 <= val < 0x800000000000:
            return val
        return self.cache_base + (val & 0xFFFFFFFFF)

    def find_image(self, substr):
        for path, addr in self.images.items():
            if substr in path:
                return path, addr
        return None, None

    def parse_macho(self, img_addr):
        hdr = self.read(img_addr, 32)
        _magic, _cpu, _sub, _ft, ncmds, sizeofcmds, _flags, _res = struct.unpack("<IIIIIIII", hdr)
        cmds_raw = self.read(img_addr + 32, sizeofcmds)
        off = 0
        segments = []
        sections = {}
        dylibs = []
        symtab = None
        for _ in range(ncmds):
            cmd, cmdsize = struct.unpack_from("<II", cmds_raw, off)
            if cmd == 0x19:
                segname = cmds_raw[off + 8 : off + 24].split(b"\x00", 1)[0].decode()
                vmaddr, vmsize, fileoff, filesize, _maxp, _initp, nsects, _sf = struct.unpack_from(
                    "<QQQQIIII", cmds_raw, off + 24
                )
                segments.append((segname, vmaddr, vmsize, fileoff, filesize))
                soff = off + 72
                for _s in range(nsects):
                    sectname = cmds_raw[soff : soff + 16].split(b"\x00", 1)[0].decode()
                    ssegname = cmds_raw[soff + 16 : soff + 32].split(b"\x00", 1)[0].decode()
                    saddr, ssize = struct.unpack_from("<QQ", cmds_raw, soff + 32)
                    sections[f"{ssegname},{sectname}"] = (saddr, ssize)
                    soff += 80
            elif cmd in (0x0C, 0x80000018, 0x8000001F, 0x80000023):
                str_off = struct.unpack_from("<I", cmds_raw, off + 8)[0]
                dname = cmds_raw[off + str_off : off + cmdsize].split(b"\x00", 1)[0].decode("utf-8", errors="replace")
                dylibs.append(dname)
            elif cmd == 0x02:
                symoff, nsyms, stroff, strsize = struct.unpack_from("<IIII", cmds_raw, off + 8)
                symtab = (symoff, nsyms, stroff, strsize)
            off += cmdsize
        return {"segments": segments, "sections": sections, "dylibs": dylibs, "symtab": symtab}

    def get_symbols(self, img_addr):
        info = self.parse_macho(img_addr)
        symtab = info["symtab"]
        if not symtab:
            return {}
        symoff, nsyms, stroff, _strsize = symtab
        linkedit_mm = None
        linkedit_delta = None
        for segname, vmaddr, _vmsize, fileoff, _filesize in info["segments"]:
            if segname == "__LINKEDIT":
                for start, end, foff, mm in self.mappings:
                    if start <= vmaddr < end:
                        linkedit_mm = mm
                        linkedit_delta = (foff + (vmaddr - start)) - fileoff
                        break
                break
        if linkedit_mm is None:
            return {}
        syms = {}
        base_sym = symoff + linkedit_delta
        base_str = stroff + linkedit_delta
        for i in range(nsyms):
            n_strx, _n_type, _n_sect, _n_desc, n_value = struct.unpack_from("<IBBHQ", linkedit_mm, base_sym + i * 16)
            if n_value == 0:
                continue
            s_off = base_str + n_strx
            end = linkedit_mm.find(b"\x00", s_off)
            name = linkedit_mm[s_off:end].decode("utf-8", errors="replace")
            syms[name] = n_value
        return syms

    def get_objc_selrefs(self, img_addr):
        info = self.parse_macho(img_addr)
        res = {}
        for k in ("__DATA_CONST,__objc_selrefs", "__DATA,__objc_selrefs"):
            if k in info["sections"]:
                addr, size = info["sections"][k]
                raw = self.read(addr, size)
                for off in range(0, size, 8):
                    ptr = struct.unpack_from("<Q", raw, off)[0]
                    va = self.decode_ptr(ptr)
                    sel = self.read_cstr(va)
                    if sel:
                        res[addr + off] = sel
        return res

    def disasm(self, va, size):
        data = self.read(va, size)
        if not data:
            return f"<unmapped 0x{va:x}>"
        hdr_sz = 32 + 72 + 80
        mh = struct.pack("<IIIIIIII", 0xFEEDFACF, 0x01000007, 3, 1, 1, 72 + 80, 0, 0)
        seg = struct.pack("<II16sQQQQIIII", 0x19, 72 + 80, b"__TEXT", va, len(data), hdr_sz, len(data), 7, 5, 1, 0)
        sec = struct.pack("<16s16sQQIIIIIIII", b"__text", b"__TEXT", va, len(data), hdr_sz, 0, 0, 0, 0x80000400, 0, 0, 0)
        with tempfile.NamedTemporaryFile(suffix=".o", delete=False) as tf:
            tf.write(mh + seg + sec + data)
            tmp_path = tf.name
        try:
            return subprocess.check_output(
                ["objdump", "-d", "--no-show-raw-insn", tmp_path],
                stderr=subprocess.DEVNULL,
                text=True,
            )
        finally:
            os.unlink(tmp_path)
