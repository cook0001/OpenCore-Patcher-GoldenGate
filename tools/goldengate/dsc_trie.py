"""Mach-O LC_DYLD_EXPORTS_TRIE parser/serializer and 16 KB CodeDirectory slot rehasher."""

import hashlib
import struct

CS_MAGIC_EMBEDDED_SIGNATURE = 0xFADE0CC0
CS_MAGIC_CODEDIRECTORY = 0xFADE0C02
CS_PAGE_SIZE_16K = 16384


def parse_uleb(buf: bytes, pos: int) -> tuple[int, int]:
    val = 0
    shift = 0
    while True:
        b = buf[pos]
        pos += 1
        val |= (b & 0x7F) << shift
        if (b & 0x80) == 0:
            break
        shift += 7
    return val, pos


def encode_uleb(val: int) -> bytes:
    if val < 0:
        raise ValueError(f"ULEB128 value must be non-negative, got {val}")
    out = bytearray()
    while True:
        b = val & 0x7F
        val >>= 7
        if val:
            out.append(b | 0x80)
        else:
            out.append(b)
            break
    return bytes(out)


def parse_exports_trie(buf: bytes) -> dict[bytes, tuple]:
    exports: dict[bytes, tuple] = {}

    def walk(off: int, prefix: bytes) -> None:
        term_sz, p = parse_uleb(buf, off)
        if term_sz:
            end = p + term_sz
            flags, q = parse_uleb(buf, p)
            if flags & 0x08:
                ordinal, q = parse_uleb(buf, q)
                z = buf.index(0, q)
                exports[prefix] = ("reexp", flags, ordinal, buf[q:z])
            elif flags & 0x10:
                stub, q = parse_uleb(buf, q)
                resolver, q = parse_uleb(buf, q)
                exports[prefix] = ("stub", flags, stub, resolver)
            else:
                addr, q = parse_uleb(buf, q)
                exports[prefix] = ("val", flags, addr)
            p = end
        nchild = buf[p]
        p += 1
        for _ in range(nchild):
            z = buf.index(0, p)
            edge = buf[p:z]
            child_off, p = parse_uleb(buf, z + 1)
            walk(child_off, prefix + edge)

    if buf:
        walk(0, b"")
    return exports


class _TrieNode:
    __slots__ = ("children", "terminal", "offset")

    def __init__(self) -> None:
        self.children: list[tuple[bytes, _TrieNode]] = []
        self.terminal: tuple | None = None
        self.offset = 0


def _encode_terminal(entry: tuple) -> bytes:
    kind = entry[0]
    if kind == "reexp":
        _, flags, ordinal, import_name = entry
        return encode_uleb(flags) + encode_uleb(ordinal) + import_name + b"\x00"
    if kind == "stub":
        _, flags, stub, resolver = entry
        return encode_uleb(flags) + encode_uleb(stub) + encode_uleb(resolver)
    if kind == "val":
        _, flags, addr = entry
        return encode_uleb(flags) + encode_uleb(addr)
    raise ValueError(f"Unknown trie terminal kind: {kind}")


def build_exports_trie(exports: dict[bytes, tuple]) -> bytes:
    root = _TrieNode()
    for name, entry in sorted(exports.items()):
        node = root
        rem = name
        while rem:
            matched = False
            for idx, (edge, child) in enumerate(node.children):
                common = 0
                limit = min(len(edge), len(rem))
                while common < limit and edge[common] == rem[common]:
                    common += 1
                if common == 0:
                    continue
                if common == len(edge):
                    node = child
                    rem = rem[common:]
                else:
                    mid = _TrieNode()
                    mid.children.append((edge[common:], child))
                    node.children[idx] = (edge[:common], mid)
                    node = mid
                    rem = rem[common:]
                matched = True
                break
            if not matched:
                leaf = _TrieNode()
                node.children.append((rem, leaf))
                node = leaf
                rem = b""
        node.terminal = entry

    nodes: list[_TrieNode] = []

    def collect(node: _TrieNode) -> None:
        nodes.append(node)
        for _, child in node.children:
            collect(child)

    collect(root)
    term_bytes = [_encode_terminal(n.terminal) if n.terminal is not None else b"" for n in nodes]

    for _ in range(32):
        changed = False
        cur = 0
        for node, tbuf in zip(nodes, term_bytes):
            if node.offset != cur:
                node.offset = cur
                changed = True
            if tbuf:
                cur += len(encode_uleb(len(tbuf))) + len(tbuf)
            else:
                cur += 1
            cur += 1
            for edge, child in node.children:
                cur += len(edge) + 1 + len(encode_uleb(child.offset))
        if not changed:
            break

    out = bytearray()
    for node, tbuf in zip(nodes, term_bytes):
        if tbuf:
            out += encode_uleb(len(tbuf)) + tbuf
        else:
            out.append(0)
        out.append(len(node.children))
        for edge, child in node.children:
            out += edge + b"\x00" + encode_uleb(child.offset)
    while len(out) & 7:
        out.append(0)
    return bytes(out)


def parse_codedirectory_header(superblob: bytes) -> dict[str, int]:
    magic, _, count = struct.unpack_from(">III", superblob, 0)
    if magic != CS_MAGIC_EMBEDDED_SIGNATURE:
        raise ValueError(f"Unexpected SuperBlob magic: {magic:#x}")
    cd_off = None
    for i in range(count):
        _, blob_off = struct.unpack_from(">II", superblob, 12 + i * 8)
        b_magic = struct.unpack_from(">I", superblob, blob_off)[0]
        if b_magic == CS_MAGIC_CODEDIRECTORY:
            cd_off = blob_off
            break
    if cd_off is None:
        raise ValueError("No CodeDirectory blob found in SuperBlob")
    _, length, version, flags, hash_offset, ident_offset, n_special, n_code, code_limit = struct.unpack_from(
        ">IIIIIIIII", superblob, cd_off
    )
    hash_size, hash_type, platform, page_shift = struct.unpack_from(">BBBB", superblob, cd_off + 36)
    return {
        "cd_offset": cd_off,
        "length": length,
        "version": version,
        "flags": flags,
        "hash_table_offset": cd_off + hash_offset,
        "ident_offset": cd_off + ident_offset,
        "n_special_slots": n_special,
        "n_code_slots": n_code,
        "code_limit": code_limit,
        "hash_size": hash_size,
        "hash_type": hash_type,
        "platform": platform,
        "page_size": 1 << page_shift,
    }


def rehash_codedirectory_slots(superblob: bytearray, slot_buffers: dict[int, bytes]) -> dict[int, bytes]:
    info = parse_codedirectory_header(bytes(superblob))
    if info["hash_size"] != 32 or info["page_size"] != CS_PAGE_SIZE_16K:
        raise ValueError(f"Unsupported CodeDirectory parameters: hash_size={info['hash_size']} page_size={info['page_size']}")
    updated: dict[int, bytes] = {}
    for slot, page_bytes in sorted(slot_buffers.items()):
        if not (0 <= slot < info["n_code_slots"]):
            raise IndexError(f"CodeDirectory slot {slot} out of range [0, {info['n_code_slots']})")
        if len(page_bytes) != CS_PAGE_SIZE_16K:
            raise ValueError(f"Slot {slot} buffer must be {CS_PAGE_SIZE_16K} bytes, got {len(page_bytes)}")
        digest = hashlib.sha256(page_bytes).digest()
        off = info["hash_table_offset"] + slot * 32
        superblob[off : off + 32] = digest
        updated[slot] = digest
    return updated
