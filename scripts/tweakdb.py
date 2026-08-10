"""Offline reader for REDengine's tweakdb.bin.

Lets us answer "what does this record actually contain" without launching the
game. Every field size below was derived by checking that each type's region
tiles exactly between its declared start and the next one; the parser
re-verifies that on load and raises if a region does not consume cleanly.

Layout, per flat type:
    u32 valueCount
    values[valueCount]              # size per TYPE_SIZES / variable readers
    u32 keyCount
    keys[keyCount] { u64 tweakDbId; u32 valueIndex }
"""

import struct
import zlib


def fnv1a64(s):
    h = 0xCBF29CE484222325
    for c in s.encode():
        h ^= c
        h = (h * 0x100000001B3) & 0xFFFFFFFFFFFFFFFF
    return h


def tweak_id(name):
    """TweakDBID = crc32(name) in the low 32 bits, name length in bits 32-39."""
    return (zlib.crc32(name.encode()) & 0xFFFFFFFF) | ((len(name) & 0xFF) << 32)


def child_id(parent_id, field):
    """TweakDBID of '<parent>.<field>' given only the parent's id.

    CRC32 is a running checksum, so appending to the name is the same as
    continuing the CRC from the parent's stored low 32 bits. The length lives
    in bits 32-39. This lets us read fields off records whose names we never
    recovered - the attack arrays are full of those.
    """
    suffix = ("." + field).encode()
    crc = zlib.crc32(suffix, parent_id & 0xFFFFFFFF) & 0xFFFFFFFF
    length = ((parent_id >> 32) & 0xFF) + len(suffix)
    return crc | ((length & 0xFF) << 32)


TYPE_NAMES = [
    "Int32", "Float", "Bool", "String", "CName", "TweakDBID",
    "gamedataLocKeyWrapper", "Vector2", "Vector3", "EulerAngles", "Quaternion",
    "Color", "CColor", "raRef:CResource",
    "array:Int32", "array:Float", "array:Bool", "array:String", "array:CName",
    "array:TweakDBID", "array:gamedataLocKeyWrapper", "array:Vector2",
    "array:Vector3", "array:EulerAngles", "array:Quaternion", "array:Color",
    "array:CColor", "array:raRef:CResource",
]
HASH_TO_TYPE = {fnv1a64(n): n for n in TYPE_NAMES}

FIXED = {
    "Bool": 1, "Int32": 4, "Float": 4, "TweakDBID": 8, "raRef:CResource": 8,
    "gamedataLocKeyWrapper": 8, "Vector2": 8, "Vector3": 12, "EulerAngles": 12,
    "Quaternion": 16, "Color": 4, "CColor": 4,
}


class Reader:
    def __init__(self, data, pos=0):
        self.d = data
        self.p = pos

    def u8(self):
        v = self.d[self.p]
        self.p += 1
        return v

    def u32(self):
        v = struct.unpack_from("<I", self.d, self.p)[0]
        self.p += 4
        return v

    def u64(self):
        v = struct.unpack_from("<Q", self.d, self.p)[0]
        self.p += 8
        return v

    def f32(self):
        v = struct.unpack_from("<f", self.d, self.p)[0]
        self.p += 4
        return v

    def packed(self):
        """RED4 packed count: low 6 bits, bit6 = continuation, bit7 = ascii flag."""
        b = self.u8()
        n = b & 0x3F
        shift = 6
        while b & 0x40:
            b = self.u8()
            n |= (b & 0x7F) << shift
            shift += 7
        return n

    def string(self):
        n = self.packed()
        s = self.d[self.p:self.p + n].decode("utf-8", "replace")
        self.p += n
        return s


class TweakDB:
    def __init__(self, path):
        self.d = open(path, "rb").read()
        magic, self.blob_version, self.parser_version, _chk = struct.unpack_from("<4I", self.d, 0)
        if magic != 0x0BB1DB47:
            raise ValueError("not a tweakdb.bin (magic %08X)" % magic)
        self.flats_off, self.records_off, self.queries_off, self.grouptags_off = \
            struct.unpack_from("<4I", self.d, 0x10)

        self.flats = {}      # tweakDbId -> value
        self.flat_type = {}  # tweakDbId -> type name
        self._parse_flats()

        self.names = {}      # tweakDbId -> name, for ids we can resolve
        self.strings = []

    def _read_values(self, r, type_name, count):
        out = []
        if type_name in FIXED:
            size = FIXED[type_name]
            for _ in range(count):
                raw = self.d[r.p:r.p + size]
                r.p += size
                if type_name == "Bool":
                    out.append(bool(raw[0]))
                elif type_name == "Int32":
                    out.append(struct.unpack("<i", raw)[0])
                elif type_name == "Float":
                    out.append(struct.unpack("<f", raw)[0])
                elif type_name in ("TweakDBID", "raRef:CResource", "gamedataLocKeyWrapper"):
                    out.append(struct.unpack("<Q", raw)[0])
                elif type_name == "Vector2":
                    out.append(struct.unpack("<2f", raw))
                elif type_name in ("Vector3", "EulerAngles"):
                    out.append(struct.unpack("<3f", raw))
                elif type_name == "Quaternion":
                    out.append(struct.unpack("<4f", raw))
                else:
                    out.append(struct.unpack("<I", raw)[0])
            return out

        if type_name in ("String", "CName"):
            for _ in range(count):
                out.append(r.string())
            return out

        if type_name.startswith("array:"):
            inner = type_name[6:]
            for _ in range(count):
                out.append(self._read_values(r, inner, r.packed()))
            return out

        raise ValueError("no reader for type %s" % type_name)

    def _parse_flats(self):
        n_types = struct.unpack_from("<I", self.d, self.flats_off)[0]
        ents = []
        for i in range(n_types):
            h, vcount, kcount, off = struct.unpack_from("<QIII", self.d, self.flats_off + 4 + i * 20)
            ents.append((HASH_TO_TYPE.get(h, "?%016X" % h), vcount, kcount, off))
        ents.sort(key=lambda e: e[3])

        for i, (tname, vcount, kcount, off) in enumerate(ents):
            end = ents[i + 1][3] if i + 1 < len(ents) else self.records_off
            # The type table's value count runs high for array types; the count
            # written at the head of the region is the one that parses, and the
            # exact region-end check below is what proves it.
            r = Reader(self.d, off)
            got_v = r.u32()
            values = self._read_values(r, tname, got_v)
            kcount = r.u32()
            for _ in range(kcount):
                tid = r.u64()
                vidx = r.u32()
                self.flats[tid] = values[vidx]
                self.flat_type[tid] = tname
            if r.p != end:
                raise ValueError("%s: region ended at 0x%X, expected 0x%X (drift %d)"
                                 % (tname, r.p, end, r.p - end))

    # ---- name resolution -------------------------------------------------

    def add_names(self, names):
        for n in names:
            self.names[tweak_id(n)] = n

    def resolve(self, tid):
        return self.names.get(tid, "<%016X>" % tid)

    def get(self, name):
        return self.flats.get(tweak_id(name))

    def type_of(self, name):
        return self.flat_type.get(tweak_id(name))

    def fields_of(self, record):
        """Every flat whose id matches '<record>.<field>' for a known field name."""
        out = {}
        prefix = record + "."
        for tid, nm in self.names.items():
            if nm.startswith(prefix) and tid in self.flats:
                out[nm[len(prefix):]] = self.flats[tid]
        return out


def harvest_strings(path, min_len=3):
    """Every printable run in the file. Record and field names live in here, so
    hashing these back gives us a reverse dictionary for TweakDBIDs."""
    import re
    data = open(path, "rb").read()
    return sorted({m.group().decode("ascii")
                   for m in re.finditer(rb"[ -~]{%d,}" % min_len, data)})
