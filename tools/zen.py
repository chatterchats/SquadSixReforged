"""Read Zen (IoStore) packages from Zero Company (UE 5.6) and their unversioned properties.

Just enough of the format to find a property's exact bytes in a cooked package, so the Core pak
can be built by patching the game's own packages instead of cooking:

  ZenPackage(data)           summary, name map and export map; export(i) is the export's bytes
  read_properties(...)       walks an export's unversioned property stream and returns every
                             serialized property with its offset, size and decoded value

Property layouts come from a schema file derived from the game's .usmap (see schema.py). Every
walk must consume its export exactly up to the 4-byte trailer UObject writes after the
properties; anything else raises, so a misread type can't produce a wrong offset silently.
"""
import struct

# EStructFlags::STRUCT_SerializeNative. Such structs ignore the property stream format and write
# their own; the ones a mission definition can reach are handled in NATIVE_STRUCTS below.
STRUCT_SERIALIZE_NATIVE = 0x800


class FormatError(Exception):
    pass


class Reader:
    def __init__(self, data, offset=0, end=None):
        self.data, self.offset = data, offset
        self.end = len(data) if end is None else end

    def take(self, size):
        if size < 0 or self.offset + size > self.end:
            raise FormatError(f"read of {size} bytes at {self.offset} runs past {self.end}")
        start = self.offset
        self.offset += size
        return self.data[start:self.offset]

    def unpack(self, fmt):
        return struct.unpack(fmt, self.take(struct.calcsize(fmt)))

    def u8(self): return self.unpack("<B")[0]
    def u16(self): return self.unpack("<H")[0]
    def i32(self): return self.unpack("<i")[0]
    def u32(self): return self.unpack("<I")[0]
    def u64(self): return self.unpack("<Q")[0]
    def f32(self): return self.unpack("<f")[0]

    def fstring(self):
        length = self.i32()
        if length == 0:
            return ""
        if length < 0:
            return self.take(-2 * length).decode("utf-16-le").rstrip("\0")
        return self.take(length).decode("latin-1").rstrip("\0")


class ZenPackage:
    """FZenPackageSummary (UE 5.5+, with the Verse cell offsets), name batch and export map."""
    SUMMARY = struct.Struct("<II II I I 9i")
    EXPORT = struct.Struct("<QQ II QQQQ Q I B3x")

    def __init__(self, data):
        self.data = data
        (has_versioning, self.header_size, name_index, name_number, self.flags,
         self.cooked_header_size, _hashes, _imports, export_map, export_bundles,
         _dep_headers, _dep_entries, _imported_names, _cell_imports, _cell_exports) = \
            self.SUMMARY.unpack_from(data, 0)
        if has_versioning:
            raise FormatError("versioned Zen packages are not supported (cooked game data isn't)")
        self.names = self._read_names(Reader(data, self.SUMMARY.size))
        self.name = self.mapped_name(name_index, name_number)
        count, extra = divmod(export_bundles - export_map, self.EXPORT.size)
        if extra:
            raise FormatError("export map size isn't a whole number of entries")
        self.exports = []
        position = self.header_size
        for index in range(count):
            (serial_offset, serial_size, object_index, object_number, outer, class_index,
             _super, _template, _hash, _flags, _filter) = self.EXPORT.unpack_from(
                data, export_map + index * self.EXPORT.size)
            self.exports.append({
                "index": index,
                "name": self.mapped_name(object_index, object_number),
                "outer": outer,
                "class": class_index,
                "cooked_offset": serial_offset,
                "size": serial_size,
            })
        # Export data follows the header in cooked-offset order.
        for export in sorted(self.exports, key=lambda e: e["cooked_offset"]):
            export["offset"] = position
            position += export["size"]
        if position != len(data):
            raise FormatError(f"exports end at {position}, package is {len(data)} bytes")

    @staticmethod
    def _read_names(reader):
        count = reader.u32()
        if count == 0:
            return []
        reader.u32()  # string bytes
        reader.u64()  # hash algorithm
        reader.take(8 * count)  # hashes
        headers = [reader.unpack(">H")[0] for _ in range(count)]
        names = []
        for header in headers:
            wide, length = header & 0x8000, header & 0x7FFF
            names.append(reader.take(2 * length).decode("utf-16-le") if wide
                         else reader.take(length).decode("latin-1"))
        return names

    def mapped_name(self, index, number):
        name = self.names[index & 0x3FFFFFFF]
        return name if number == 0 else f"{name}_{number - 1}"

    def export_at(self, package_object_index):
        """The export an FPackageObjectIndex points at, or None if it is an import or null."""
        if package_object_index >> 62 != 0:  # Export = 0; ScriptImport, PackageImport, Null
            return None
        return self.exports[package_object_index & ((1 << 62) - 1)]

    def export(self, name):
        for export in self.exports:
            if export["name"] == name:
                return export
        raise FormatError(f"{self.name} has no export {name}")


class Schema:
    """Classes and structs from the game's .usmap: name -> {super, flags, properties}."""

    def __init__(self, schemas):
        self.schemas = schemas
        self._flat = {}

    def properties(self, name):
        """Every property by unversioned index: the class's own first, then its super's (the
        index runs on into the super chain), static arrays expanded."""
        if name not in self._flat:
            entry = self.schemas.get(name)
            if entry is None:
                raise FormatError(f"no schema for {name}")
            flat = []
            for prop in entry["properties"]:
                flat.extend([prop] * prop.get("array_dim", 1))
            if entry["super"]:
                flat.extend(self.properties(entry["super"]))
            self._flat[name] = flat
        return self._flat[name]

    def is_native(self, name):
        return bool(self.schemas[name]["flags"] & STRUCT_SERIALIZE_NATIVE)


def read_text(reader):
    """FText as cooked: flags, history type, then that history's payload."""
    reader.u32()  # flags
    history = reader.unpack("<b")[0]
    if history == -1:  # None
        return {"invariant": reader.fstring()} if reader.u32() else {"invariant": None}
    if history == 0:  # Base
        return {"namespace": reader.fstring(), "key": reader.fstring(), "source": reader.fstring()}
    if history == 11:  # StringTableEntry
        return {"table": read_name(reader), "key": reader.fstring()}
    raise FormatError(f"FText history type {history} is not supported")


def read_name(reader):
    return reader.unpack("<II")  # name-map index and number; the caller can map it


def read_gameplay_tag_container(reader, schema, package):
    # FGameplayTagContainer::Serialize writes its tags as a plain FName array.
    return [package.mapped_name(*read_name(reader)) for _ in range(reader.i32())]


def read_vector(reader, schema, package):
    # UE5 large world coordinates: doubles.
    x, y, z = reader.unpack("<ddd")
    return {"X": x, "Y": y, "Z": z}


def read_rotator(reader, schema, package):
    pitch, yaw, roll = reader.unpack("<ddd")
    return {"Pitch": pitch, "Yaw": yaw, "Roll": roll}


def read_color(reader, schema, package):
    b, g, r, a = reader.unpack("<BBBB")
    return {"R": r, "G": g, "B": b, "A": a}


NATIVE_STRUCTS = {
    "GameplayTagContainer": read_gameplay_tag_container,
    "Vector": read_vector,
    "Rotator": read_rotator,
    "Color": read_color,
}


def read_value(reader, type_info, schema, package):
    kind = type_info["type"]
    if kind == "BoolProperty" or kind == "ByteProperty":
        return reader.u8()
    if kind == "EnumProperty":
        return read_value(reader, type_info["inner"], schema, package)
    if kind == "IntProperty":
        return reader.i32()
    if kind == "UInt32Property":
        return reader.u32()
    if kind == "Int64Property":
        return reader.unpack("<q")[0]
    if kind == "FloatProperty":
        return reader.f32()
    if kind == "DoubleProperty":
        return reader.unpack("<d")[0]
    if kind == "NameProperty":
        return package.mapped_name(*read_name(reader))
    if kind == "StrProperty":
        return reader.fstring()
    if kind == "TextProperty":
        return read_text(reader)
    if kind == "ObjectProperty" or kind == "ClassProperty" or kind == "InterfaceProperty":
        return reader.i32()  # FPackageIndex
    if kind == "SoftObjectProperty" or kind == "SoftClassProperty":
        # FSoftObjectPath: FTopLevelAssetPath (package + asset FNames) and a sub-path string.
        package_name = package.mapped_name(*read_name(reader))
        asset_name = package.mapped_name(*read_name(reader))
        sub_path = reader.fstring()
        return f"{package_name}.{asset_name}" + (f":{sub_path}" if sub_path else "")
    if kind == "StructProperty":
        return read_struct(reader, type_info["struct"], schema, package)
    if kind == "ArrayProperty":
        return [read_value(reader, type_info["inner"], schema, package) for _ in range(reader.i32())]
    if kind == "SetProperty":
        if reader.i32():
            raise FormatError("set with removed elements")
        return [read_value(reader, type_info["inner"], schema, package) for _ in range(reader.i32())]
    if kind == "MapProperty":
        if reader.i32():
            raise FormatError("map with removed elements")
        return [(read_value(reader, type_info["key"], schema, package),
                 read_value(reader, type_info["value"], schema, package)) for _ in range(reader.i32())]
    raise FormatError(f"{kind} is not supported")


def read_struct(reader, name, schema, package):
    # A struct derived from a natively serialized one (Vector_NetQuantize100 from Vector)
    # serializes as its parent does.
    native = name
    while native is not None and native not in NATIVE_STRUCTS:
        native = schema.schemas.get(native, {}).get("super")
    if native is not None:
        return NATIVE_STRUCTS[native](reader, schema, package)
    if schema.is_native(name):
        raise FormatError(f"{name} serializes natively and has no reader")
    return {prop["name"]: value for prop, _, _, value in read_unversioned(reader, name, schema, package)}


def read_unversioned(reader, class_name, schema, package):
    """FUnversionedHeader, then the serialized values: [(property, offset, size, value)].

    Fragments are u16: SkipNum (7 bits), HasAnyZeroes (bit 7), IsLast (bit 8), ValueNum (7 bits).
    Zero-masked values aren't serialized; they are reported with size 0 and value None.
    """
    fragments = []
    while True:
        packed = reader.u16()
        fragments.append((packed & 0x7F, bool(packed & 0x80), packed >> 9))
        if packed & 0x100:
            break
    mask_bits = sum(count for _, zeroes, count in fragments if zeroes)
    if mask_bits == 0:
        mask = 0
    elif mask_bits <= 8:
        mask = reader.u8()
    elif mask_bits <= 16:
        mask = reader.u16()
    else:
        mask = 0
        for word in range((mask_bits + 31) // 32):
            mask |= reader.u32() << (32 * word)
    properties = schema.properties(class_name)
    results, index, mask_index = [], 0, 0
    for skip, zeroes, count in fragments:
        index += skip
        for _ in range(count):
            if index >= len(properties):
                raise FormatError(f"{class_name} property index {index} is out of range")
            prop = properties[index]
            zero = zeroes and (mask >> mask_index) & 1
            if zeroes:
                mask_index += 1
            if zero:
                results.append((prop, reader.offset, 0, None))
            else:
                start = reader.offset
                value = read_value(reader, prop["type"], schema, package)
                results.append((prop, start, reader.offset - start, value))
            index += 1
    return results


def read_properties(package, export, class_name, schema, trailer="object"):
    """The export's top-level properties. Raises unless the stream ends exactly at the trailer
    its kind of object writes after the properties:
      object     4 bytes: UObject's has-GUID flag, 0 in cooked data
      component  8 zero bytes (scene components, as cooked in levels)
    Actors use read_actor, whose trailer carries the actor's label.
    """
    reader = Reader(package.data, export["offset"], export["offset"] + export["size"])
    results = read_unversioned(reader, class_name, schema, package)
    size = {"object": 4, "component": 8}[trailer]
    rest = package.data[reader.offset:reader.end]
    if rest != bytes(size):
        raise FormatError(f"{package.name}: {export['name']} has {len(rest)} bytes after its properties, "
                          f"expected {size} zero bytes; a type was misread")
    return results


def read_actor(package, export, class_name, schema):
    """An actor's properties and its label. After the properties a cooked level actor writes the
    has-GUID flag (0), a label flag (0 or 1), the label as an FString when present, and two
    16-byte GUIDs."""
    reader = Reader(package.data, export["offset"], export["offset"] + export["size"])
    results = read_unversioned(reader, class_name, schema, package)
    try:
        has_guid, has_label = reader.u32(), reader.u32()
        label = reader.fstring() if has_label == 1 else None
        reader.take(32)
    except FormatError:
        has_guid = has_label = None
    if has_guid != 0 or has_label not in (0, 1) or reader.offset != reader.end:
        raise FormatError(f"{package.name}: {export['name']} doesn't end in the actor trailer; "
                          f"a type was misread")
    return results, label
