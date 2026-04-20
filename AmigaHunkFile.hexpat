#pragma author Karsten Bock
#pragma description Parse Amiga Hunk files

#pragma magic [ 00 00 03 F3 ] @ 0x00
#pragma magic [ 00 00 03 E7 ] @ 0x00
#pragma magic [ 00 00 03 FA ] @ 0x00

#pragma endian big

import std.io;
import std.mem;
import std.sys;
import std.core;
import std.string;

// *** basic types ***
enum HunkType: u32 {
    // undocumented
    HUNK_RESLIB       = 0x3e6,
    // main types
    HUNK_UNIT         = 0x3e7,
    HUNK_NAME         = 0x3e8,
    HUNK_CODE         = 0x3e9,
    HUNK_DATA         = 0x3ea,
    HUNK_BSS          = 0x3eb,
    HUNK_RELOC32      = 0x3ec,
    HUNK_RELOC16      = 0x3ed,
    HUNK_RELOC8       = 0x3ee,
    HUNK_EXT          = 0x3ef,
    HUNK_SYMBOL       = 0x3f0,
    HUNK_DEBUG        = 0x3f1,
    HUNK_END          = 0x3f2,
    HUNK_HEADER       = 0x3f3,
    HUNK_OVERLAY      = 0x3f5,
    HUNK_BREAK        = 0x3f6,
    HUNK_DREL32       = 0x3f7,
    HUNK_DREL16       = 0x3f8,
    HUNK_DREL8        = 0x3f9,
    HUNK_LIB          = 0x3fa,
    HUNK_INDEX        = 0x3fb,
    HUNK_RELOC32SHORT = 0x3fc,
    HUNK_RELRELOC32   = 0x3fd,
    HUNK_ABSRELOC16   = 0x3fe,
    // Extended Hunk Format
    HUNK_PPC_CODE     = 0x4e9,
    HUNK_RELRELOC26   = 0x4ec
};

enum SymbolType: u8 {
    EXT_SYMB        = 0x00,
    EXT_DEF         = 0x01,
    EXT_ABS         = 0x02,
    EXT_RES         = 0x03,
    EXT_REF32       = 0x81,
    EXT_COMMON      = 0x82,
    EXT_REF16       = 0x83,
    EXT_REF8        = 0x84,
    EXT_DREF32      = 0x85,
    EXT_DREF16      = 0x86,
    EXT_DREF8       = 0x87,
    EXT_RELREF32    = 0x88,
    EXT_RELCOMMON   = 0x89,
    EXT_ABSREF16    = 0x8a,
    EXT_ABSREF8     = 0x8b,
    // Extended Hunk Format
    EXT_RELREF26    = 0xe5,
};

enum MemoryType: u8 {
    HUNKF_ANY   = 0,
    HUNKF_CHIP  = 1,
    HUNKF_FAST  = 2,
    HUNKF_OTHER = 3
};

// *** constants ***
const s64 MAX_COUNT_UNLIMITED = -1;

// RGB format
const str COLOR_HUNK = "4F7FAF";
const str COLOR_TYPE = "AF7F4F";

const str NAME_RESIDENT = "Resident";
const str NAME_MAIN_HUNK_DATA = "Main Hunk Data";
const str NAME_OFFSET_DATA = "Offset Data";
const str NAME_UNIT_SEGMENT_INDEX = "Unit Segment Index";
const str NAME_REFERENCE = "Reference";
const str NAME_DEFINITION = "Definition";

// *** variables ***
HunkType root_hunk_type = 0;
HunkType current_hunk_type = 0;

// padding is a reserved name
using pad<T> = T [[name("padding")]];

// *** forward declarations ***
// * logical groups *
using Segment;
using Node;
using Unit<auto max_segment_count>;
// * hunk templates *
using HunkTemplate_Type;
using HunkTemplate_Name;
using HunkTemplate_RelocLong;
using HunkTemplate_RelocWord;
using HunkTemplate_Symbol;
// * root hunks *
using HunkHeader;
using HunkOverlay;
using HunkUnit;
using HunkLib;
using HunkIndex;
using HunkBreak;
// * additional hunks *
using HunkCode;
using HunkPPCCode;
using HunkData;
using HunkBSS;
using HunkReloc32;
using HunkReloc16;
using HunkReloc8;
using HunkDRel32;
using HunkDRel32Exe;
using HunkDRel16;
using HunkDRel8;
using HunkReloc32Short;
using HunkRelReloc32;
using HunkAbsReloc16;
using HunkRelReloc26;
using HunkName;
using HunkExt;
using HunkSymbol;
using HunkDebug;
using HunkEnd;
using HunkResLib;
// * helper *
using Resident;
using MainHunkData;
using Offset<T>;
using OffsetLong;
using OffsetWord;
using String;
using StringTable<auto size>;
using UnitIndex;
using UnitSegmentIndex;
using Reference;
using Definition;
using Symbol;
using UnitGroup;
using LibGroup;
using ReadUnitGroup;
using MainHunkDataValue;
using HunkTypeValue;
using HunkTypeValueShort;
using SymbolTypeValueShort;
// * reader *
using ReadSegments<auto max_segment_count>;
using ReadUnit<auto max_segment_count>;
using ReadHunks;

// *** general functions ***
fn read_unsigned32() {
    return std::mem::read_unsigned($, 4, std::mem::Endian::Big);
};

fn read_unsigned16() {
    return std::mem::read_unsigned($, 2, std::mem::Endian::Big);
};

fn get_indexed_name(str name) {
    return std::format("{}[{:0d}]", name, std::core::array_index());
};

fn cleanup_indexed_name(ref auto value) {
    if (std::core::member_count(value) != 1)
        return;
    str name = std::core::get_attribute_argument(value[0], "name");
    std::core::set_display_name(value[0], std::string::replace(name, "[0]", ""));
};

fn get_count_name(str name, ref auto entry) {
    return std::format("{}[{:0d}]", name, std::core::member_count(entry));
};

// *** memory functions ***
fn is_other_memory(MemoryType value) {
    return value == MemoryType::HUNKF_OTHER;
};

// *** hunk functions ***
fn get_hunk_type(ref u32 value) {
    HunkTypeValue hunk_type @ addressof(value);
    if (hunk_type.type == HunkType::HUNK_CODE || hunk_type.type == HunkType::HUNK_PPC_CODE || hunk_type.type == HunkType::HUNK_DATA || hunk_type.type == HunkType::HUNK_BSS) {
        return hunk_type.type;
    }
    return value;
};

fn get_hunk_name(ref auto value) {
    return std::string::replace(std::string::to_string(value), "HunkType::", "");
};

fn warn_unknown_hunk(HunkType hunk_type, s64 offset) {
    std::warning(std::format("Unknown/invalid hunk type 0x{:0x} at offset 0x{:0x}", u32(hunk_type), offset));
};

fn assert_hunk_type(auto hunk_type, auto reference_hunk_type) {
    // if you pass an enum value directly it is 128bits in ImHex currently even if setting argument type to HunkType
    HunkType reference_hunk_type_value = reference_hunk_type;
    if (hunk_type == reference_hunk_type_value)
        return true;
    warn_unknown_hunk(hunk_type, $ - 4);
    return false;
};

fn get_remaining_segment_count(u32 total_segment_count, u32 root_segment_count, u32 resident_count) {
    return total_segment_count - root_segment_count - resident_count;
};

// *** file types ***
struct LoadFile {
    HunkHeader hunk_header;
    ReadSegments<MAX_COUNT_UNLIMITED> read_segments;
    if (!std::mem::eof() && read_unsigned32() == HunkType::HUNK_OVERLAY) {
        bool has_overlay = true;
        HunkOverlay hunk_overlay;
    }
} [[name("Type: Load File")]];

struct ObjectFile {
    UnitGroup unit_group[while(!std::mem::eof())] [[inline]];
} [[name("Type: Object File or Link Library File (old style)")]];

struct LinkLibraryFile {
    LibGroup lib_group[while(!std::mem::eof())] [[inline]];
} [[name("Type: Link Library File (new style)")]];

struct Segment {
    ReadHunks read_hunks[while (!std::mem::eof())] [[inline]];
    HunkType next_hunk_type = 0;
    match (current_hunk_type) {
        (HunkType::HUNK_END): {
            next_hunk_type = read_unsigned32();
            if (next_hunk_type == HunkType::HUNK_UNIT || next_hunk_type == HunkType::HUNK_INDEX || next_hunk_type == HunkType::HUNK_OVERLAY)
                break;
        }
        (HunkType::HUNK_BREAK): {
            break;
        }
    }
} [[name(get_indexed_name("Segment"))]];

struct Node {
    HunkHeader hunk_header;
    ReadSegments<MAX_COUNT_UNLIMITED> read_segments;
    HunkBreak hunk_break;
} [[name(get_indexed_name("Node"))]];

struct Unit<auto max_segment_count> {
    ReadSegments<max_segment_count> read_segments;
} [[name(get_indexed_name("Unit"))]];

struct HunkTemplate_Type {
    HunkType hunk_type [[color(COLOR_TYPE)]];
} [[name(get_hunk_name(hunk_type))]];

struct HunkTemplate_TypeWithFlags {
    HunkTypeValue hunk_type [[color(COLOR_TYPE)]];
    if (is_other_memory(hunk_type.memory_type))
        u32 memory_type;
} [[name(get_hunk_name(hunk_type.type))]];

struct HunkTemplate_Name: HunkTemplate_Type {
    u32 name_length;
    if (name_length > 0)
        char hunk_name[name_length * 4];
};

struct HunkTemplate_RelocLong: HunkTemplate_Type {
    OffsetLong offset[while(read_unsigned32() != 0)] [[inline]];
    u32 offset_end;
};

struct HunkTemplate_RelocWord: HunkTemplate_Type {
    OffsetWord offset[while(read_unsigned16() != 0)] [[inline]];
    u16 offset_end;
    if ($ % 4 != 0)
        pad<u16> _padding;
};

struct HunkTemplate_Symbol: HunkTemplate_Type {
    Symbol symbol[while(read_unsigned32() != 0)] [[inline]];
    cleanup_indexed_name(symbol);
    u32 symbol_end;
};

// *** root hunks ***
struct HunkHeader: HunkTemplate_Type {
    if (!assert_hunk_type(hunk_type, HunkType::HUNK_HEADER))
        return;
    Resident resident[while(read_unsigned32() != 0)] [[name(get_count_name(NAME_RESIDENT, this)), inline]];
    u32 resident_count = std::core::member_count(resident);
    cleanup_indexed_name(resident);
    u32 resident_end;
    u32 segment_count;
    u32 first_segment;
    u32 last_segment;
    u32 root_segment_count = last_segment - first_segment + 1;
    if (root_segment_count > 0) {
        MainHunkData main_hunk_data[root_segment_count] [[name(get_count_name(NAME_MAIN_HUNK_DATA, this))]];
        cleanup_indexed_name(main_hunk_data);
    }
};

struct HunkOverlay: HunkTemplate_Type {
    if (!assert_hunk_type(hunk_type, HunkType::HUNK_OVERLAY))
        return;
    u32 remaining_segment_count = get_remaining_segment_count(parent.hunk_header.segment_count, parent.hunk_header.root_segment_count, parent.hunk_header.resident_count);
    u32 overlay_table_size;
    if (overlay_table_size > 0) {
        if (remaining_segment_count > 0)
            u32 number_levels;
        u32 overlay_table[overlay_table_size];
    }
    if (remaining_segment_count > 0) {
        Node node[while(!std::mem::eof())] [[inline]];
        cleanup_indexed_name(node);
    } else if (!std::mem::eof()) {
        HunkType probable_hunk_type = get_hunk_type(read_unsigned32());
        if (std::core::is_valid_enum(probable_hunk_type)) {
            ReadHunks read_hunks;
        }
        u32 data_size = std::mem::size() - $;
        if (data_size > 0)
            u8 data[data_size];
    }
};

struct HunkUnit: HunkTemplate_Name {
    if (!assert_hunk_type(hunk_type, HunkType::HUNK_UNIT))
        return;
};

struct HunkLib: HunkTemplate_Type {
    if (!assert_hunk_type(hunk_type, HunkType::HUNK_LIB))
        return;
    u32 lib_size;
};

struct HunkIndex: HunkTemplate_Type {
    if (!assert_hunk_type(hunk_type, HunkType::HUNK_INDEX))
        return;
    u32 index_size;
    u16 string_table_size;
    StringTable<string_table_size> string_table;
    s64 hunk_end_offset = addressof(this) + index_size * 4 + sizeof(hunk_type) + sizeof(index_size);
    UnitIndex unit_index[while(!std::mem::eof() && $ < hunk_end_offset && read_unsigned16() != 0)] [[inline]];
    cleanup_indexed_name(unit_index);
    if ($ % 4 != 0) {
        pad<u16> _padding;
    }
    u32 unit_count = std::core::member_count(unit_index);
};

struct HunkBreak: HunkTemplate_Type {
    if (!assert_hunk_type(hunk_type, HunkType::HUNK_BREAK))
        return;
};

struct HunkCode: HunkTemplate_TypeWithFlags {
    u32 code_size;
    if (code_size > 0)
        u8 code[code_size * 4];
};

struct HunkPPCCode: HunkCode {
};

struct HunkData: HunkTemplate_TypeWithFlags {
    u32 data_size;
    if (data_size > 0)
        u8 data[data_size * 4];
};

struct HunkBSS: HunkTemplate_TypeWithFlags {
    u32 bss_size;
};

struct HunkReloc32: HunkTemplate_RelocLong {
};

struct HunkReloc16: HunkTemplate_RelocLong {
};

struct HunkReloc8: HunkTemplate_RelocLong {
};

struct HunkDRel32: HunkTemplate_RelocLong {
};

struct HunkDRel32Exe: HunkTemplate_RelocWord {
};

struct HunkDRel16: HunkTemplate_RelocLong {
};

struct HunkDRel8: HunkTemplate_RelocLong {
};

struct HunkReloc32Short: HunkTemplate_RelocWord {
};

struct HunkRelReloc32: HunkTemplate_RelocLong {
};

struct HunkAbsReloc16: HunkTemplate_RelocWord {
};

struct HunkRelReloc26: HunkTemplate_RelocLong {
};

struct HunkName: HunkTemplate_Name {
};

struct HunkExt: HunkTemplate_Symbol {
};

struct HunkSymbol: HunkTemplate_Symbol {
};

struct HunkDebug: HunkTemplate_Type {
    u32 debug_size;
    if (debug_size > 0)
        u8 data[debug_size * 4];
};

struct HunkEnd: HunkTemplate_Type {
};

struct HunkResLib: HunkTemplate_Type {
};

struct MainHunkData {
    MainHunkDataValue data;
    if (is_other_memory(data.memory_type))
        u32 memory_type;
} [[name(get_indexed_name(NAME_MAIN_HUNK_DATA))]];

struct Resident {
    u32 resident_name_length;
    if (resident_name_length > 0)
        char resident_name[resident_name_length * 4];
} [[name(get_indexed_name(NAME_RESIDENT))]];

struct Offset<T> {
    T offset_count;
    if (offset_count == 0)
        break;
    T hunk_number;
    T offset[offset_count];
} [[name(get_indexed_name(NAME_OFFSET_DATA))]];

struct OffsetLong: Offset<u32> {
};

struct OffsetWord: Offset<u16> {
};

struct String {
    char value[];
} [[name(get_indexed_name("String"))]];

struct StringTable<auto size> {
    String string_entry[while($ - addressof(this) < size)] [[inline]];
} [[name("String Table")]];

struct UnitIndex {
    u16 unit_name_offset;
    u16 first_segment_offset;
    u16 segment_count;
    UnitSegmentIndex unit_segment_index[segment_count] [[name(get_count_name(NAME_UNIT_SEGMENT_INDEX, this))]];
    cleanup_indexed_name(unit_segment_index);
} [[name(get_indexed_name("Unit Index"))]];

struct UnitSegmentIndex {
    u16 segment_name_offset;
    u16 main_hunk_size;
    HunkTypeValueShort main_hunk_type_short;
    u16 reference_count;
    if (reference_count > 0) {
        Reference reference[reference_count] [[name(get_count_name(NAME_REFERENCE, this))]];
        cleanup_indexed_name(reference);
    }
    u16 definition_count;
    if (definition_count > 0) {
        Definition definition[definition_count] [[name(get_count_name(NAME_DEFINITION, this))]];
        cleanup_indexed_name(definition);
    }
} [[name(get_indexed_name(NAME_UNIT_SEGMENT_INDEX))]];

struct Reference {
    u16 reference_name_offset;
} [[name(get_indexed_name(NAME_REFERENCE))]];

struct Definition {
    u16 definition_name_offset;
    u16 symbol_value_short;
    u8 bits_ext_abs;
    SymbolTypeValueShort symbol_type_short;
} [[name(get_indexed_name(NAME_DEFINITION))]];

struct Symbol {
    u8 symbol_type;
    u24 symbol_length;
    if (symbol_length > 0) {
        char symbol_name[symbol_length * 4];
        if (symbol_type < 0x80) {
            u32 symbol_value;
        } else {
            if (symbol_type == SymbolType::EXT_COMMON || symbol_type == SymbolType::EXT_RELCOMMON) {
                u32 common_hunk_size;
            }
            u32 reference_count;
            if (reference_count > 0)
                u32 reference_offset[reference_count];
        }
    }
} [[name(get_indexed_name("Symbol"))]];

struct UnitGroup {
    HunkUnit hunk_unit;
    ReadUnit<MAX_COUNT_UNLIMITED> read_unit;
} [[inline]];

struct LibGroup {
    HunkLib hunk_lib;
    HunkIndex hunk_index_preread @ (addressof(hunk_lib) + hunk_lib.lib_size * 4 + 8) [[no_unique_address, hidden]];
    ReadUnitGroup read_unit_group[hunk_index_preread.unit_count] [[inline]];
    HunkIndex hunk_index;
} [[inline]];

struct ReadUnitGroup<auto hunk_index> {
    u32 segment_count = parent.hunk_index_preread.unit_index[std::core::array_index()].segment_count;
    ReadUnit<segment_count> read_unit;
} [[inline]];

bitfield MainHunkDataValue {
    MemoryType memory_type : 2;
    size                   : 30;
};

bitfield HunkTypeValue {
    MemoryType memory_type : 2;
    HUNKF_ADVISORY         : 1;
    HunkType type          : 29;
};

bitfield HunkTypeValueShort {
    MemoryType memory_type : 2;
    HunkType type          : 14;
};

bitfield SymbolTypeValueShort {
    zero                   : 1;
    upper_bits_ext_abs     : 1;
    SymbolType symbol_type : 6;
};

// *** reader ***
struct ReadSegments<auto max_segment_count> {
    current_hunk_type = 0;
    if (max_segment_count == MAX_COUNT_UNLIMITED)
        Segment segment[while(!std::mem::eof())] [[inline]];
    else
        Segment segment[max_segment_count] [[inline]];
    cleanup_indexed_name(segment);
} [[inline]];

struct ReadUnit<auto max_segment_count> {
    HunkType next_hunk_type = read_unsigned32();
    if (next_hunk_type != HunkType::HUNK_UNIT) {
        Unit<max_segment_count> unit;
    }
} [[inline]];

struct ReadHunks {
    u32 hunk_type = read_unsigned32();
    current_hunk_type = get_hunk_type(hunk_type);
    match (current_hunk_type) {
        (HunkType::HUNK_RESLIB): HunkResLib hunk_reslib;
        (HunkType::HUNK_NAME): HunkName hunk_name;
        (HunkType::HUNK_CODE): HunkCode hunk_code;
        (HunkType::HUNK_DATA): HunkData hunk_data;
        (HunkType::HUNK_BSS): HunkBSS hunk_bss;
        (HunkType::HUNK_RELOC32): HunkReloc32 hunk_reloc32;
        (HunkType::HUNK_RELOC16): HunkReloc16 hunk_reloc16;
        (HunkType::HUNK_RELOC8): HunkReloc8 hunk_reloc8;
        (HunkType::HUNK_END): {
            HunkEnd hunk_end;
            if (std::mem::eof() || read_unsigned32() != HunkType::HUNK_BREAK)
                break;
        }
        (HunkType::HUNK_EXT): HunkExt hunk_ext;
        (HunkType::HUNK_SYMBOL): HunkSymbol hunk_symbol;
        (HunkType::HUNK_DEBUG): HunkDebug hunk_debug;
        (HunkType::HUNK_DREL32): {
            if (root_hunk_type == HunkType::HUNK_HEADER)
                HunkDRel32Exe hunk_drel32;
            else
                HunkDRel32 hunk_drel32;
        }
        (HunkType::HUNK_DREL16): HunkDRel16 hunk_drel16;
        (HunkType::HUNK_DREL8): HunkDRel8 hunk_drel8;
        (HunkType::HUNK_RELOC32SHORT): HunkReloc32Short hunk_reloc32short;
        (HunkType::HUNK_RELRELOC32): HunkRelReloc32 hunk_relreloc32;
        (HunkType::HUNK_ABSRELOC16): HunkAbsReloc16 hunk_absreloc16;
        (HunkType::HUNK_BREAK): {
            try {
                bool has_overlay = parent.parent.has_overlay;
            } catch {
                break;
            }
            HunkBreak hunk_break;
        }
        (HunkType::HUNK_PPC_CODE): HunkPPCCode hunk_ppc_code;
        (HunkType::HUNK_RELRELOC26): HunkRelReloc26 hunk_relreloc26;
        (_): { warn_unknown_hunk(hunk_type, $); return; }
    }
} [[inline]];

// *** main ***
struct File {
    root_hunk_type = read_unsigned32();
    match (root_hunk_type) {
        (HunkType::HUNK_HEADER): LoadFile load_file;
        (HunkType::HUNK_UNIT): ObjectFile object_file;
        (HunkType::HUNK_LIB): LinkLibraryFile link_library_file;
        (_): warn_unknown_hunk(root_hunk_type, $);
    }
} [[color(COLOR_HUNK)]];

File file @ 0 [[inline]];