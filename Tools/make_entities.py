#!/usr/bin/env python3
"""Writes an R2000 DXF that exercises every entity branch of the importer.

    python3 Tools/make_entities.py [out.dxf]

The plain sample plan only contains lines, polylines, circles, arcs, text and
solids. This file adds the branches that plan.dxf does not reach: closed
LW polylines with bulges, solid and patterned HATCH, MTEXT with an attachment
point, rotated TEXT placed by its second alignment point, an INSERT carrying an
ATTRIB, ELLIPSE and SPLINE.

Table records carry handles, subclass markers and owners, because libdxfrw
validates table entries strictly and rejects a bare R12-style layout.

    python3 Tools/make_entities.py /tmp/entities.dxf
    ./build/cadtool /tmp/entities.dxf
    CADCORE_NO_DXFRW=1 ./build/cadtool /tmp/entities.dxf
"""
import sys

out_path = sys.argv[1] if len(sys.argv) > 1 else "Samples/entities.dxf"
out = []
handle = [0x30]


def next_handle():
    handle[0] += 1
    return f"{handle[0]:X}"


def w(code, value):
    out.append(str(code))
    out.append(str(value))


def section(name):
    w(0, "SECTION")
    w(2, name)


def table(name, count, table_handle):
    w(0, "TABLE")
    w(2, name)
    w(5, table_handle)
    w(330, 0)
    w(100, "AcDbSymbolTable")
    w(70, count)


def record(kind, name, subclass):
    entry = next_handle()
    w(0, kind)
    w(5, entry)
    w(330, 1)
    w(100, "AcDbSymbolTableRecord")
    w(100, subclass)
    w(2, name)
    return entry


def header():
    section("HEADER")
    w(9, "$ACADVER")
    w(1, "AC1015")
    w(9, "$INSUNITS")
    w(70, 4)
    w(9, "$HANDSEED")
    w(5, "FFFF")
    w(0, "ENDSEC")


def tables():
    section("TABLES")

    table("LTYPE", 1, "10")
    record("LTYPE", "CONTINUOUS", "AcDbLinetypeTableRecord")
    w(70, 0)
    w(3, "Solid line")
    w(72, 65)
    w(73, 0)
    w(40, 0.0)
    w(0, "ENDTAB")

    table("LAYER", 5, "11")
    for name, aci, weight in (("0", 7, 25), ("WALL", 7, 50), ("FILL", 1, 13),
                              ("NOTE", 3, 18), ("SYM", 5, 25)):
        record("LAYER", name, "AcDbLayerTableRecord")
        w(70, 0)
        w(62, aci)
        w(6, "CONTINUOUS")
        w(370, weight)
    w(0, "ENDTAB")

    table("STYLE", 1, "12")
    record("STYLE", "STANDARD", "AcDbTextStyleTableRecord")
    w(70, 0)
    w(40, 0.0)
    w(41, 1.0)
    w(50, 0.0)
    w(71, 0)
    w(42, 2.5)
    w(3, "txt")
    w(4, "")
    w(0, "ENDTAB")

    table("BLOCK_RECORD", 2, "13")
    block_record_handles["*Model_Space"] = record(
        "BLOCK_RECORD", "*Model_Space", "AcDbBlockTableRecord")
    block_record_handles["DOORTAG"] = record(
        "BLOCK_RECORD", "DOORTAG", "AcDbBlockTableRecord")
    w(0, "ENDTAB")

    w(0, "ENDSEC")


def begin_block(name, owner):
    w(0, "BLOCK")
    w(5, next_handle())
    w(330, owner)
    w(100, "AcDbEntity")
    w(8, "0")
    w(100, "AcDbBlockBegin")
    w(2, name)
    w(70, 0)
    w(10, 0.0)
    w(20, 0.0)
    w(30, 0.0)
    w(3, name)
    w(1, "")


def end_block(owner):
    w(0, "ENDBLK")
    w(5, next_handle())
    w(330, owner)
    w(100, "AcDbEntity")
    w(8, "0")
    w(100, "AcDbBlockEnd")


def blocks():
    section("BLOCKS")

    owner = block_record_handles["*Model_Space"]
    begin_block("*Model_Space", owner)
    end_block(owner)

    owner = block_record_handles["DOORTAG"]
    begin_block("DOORTAG", owner)
    for a, b in (((0, 0), (1, 0)), ((0, 0), (0, 1))):
        w(0, "LINE")
        w(5, next_handle())
        w(330, owner)
        w(100, "AcDbEntity")
        w(8, "SYM")
        w(100, "AcDbLine")
        w(10, float(a[0]))
        w(20, float(a[1]))
        w(30, 0.0)
        w(11, float(b[0]))
        w(21, float(b[1]))
        w(31, 0.0)
    w(0, "ATTDEF")
    w(5, next_handle())
    w(330, owner)
    w(100, "AcDbEntity")
    w(8, "SYM")
    w(100, "AcDbText")
    w(10, 0.2)
    w(20, 1.2)
    w(30, 0.0)
    w(40, 0.25)
    w(1, "TAG")
    w(100, "AcDbAttributeDefinition")
    w(3, "prompt")
    w(2, "TAG")
    w(70, 0)
    end_block(owner)

    w(0, "ENDSEC")


def entity_begin(kind, layer, subclass):
    w(0, kind)
    w(5, next_handle())
    w(330, block_record_handles["*Model_Space"])
    w(100, "AcDbEntity")
    w(8, layer)
    w(100, subclass)


def hatch(loops, solid, pattern=None):
    entity_begin("HATCH", "FILL", "AcDbHatch")
    w(10, 0.0)
    w(20, 0.0)
    w(30, 0.0)
    w(210, 0.0)
    w(220, 0.0)
    w(230, 1.0)
    w(2, "SOLID" if solid else "ANSI31")
    w(70, 1 if solid else 0)
    w(71, 0)
    w(91, len(loops))
    for loop in loops:
        w(92, 1)
        w(93, len(loop))
        for i in range(len(loop)):
            a = loop[i]
            b = loop[(i + 1) % len(loop)]
            w(72, 1)
            w(10, float(a[0]))
            w(20, float(a[1]))
            w(11, float(b[0]))
            w(21, float(b[1]))
        w(97, 0)
    w(75, 0)
    w(76, 1)
    if pattern:
        w(52, 0.0)
        w(41, 1.0)
        w(77, 0)
        w(78, 1)
        w(53, pattern["angle"])
        w(43, 0.0)
        w(44, 0.0)
        w(45, float(pattern["dx"]))
        w(46, float(pattern["dy"]))
        w(79, len(pattern["dashes"]))
        for dash in pattern["dashes"]:
            w(49, float(dash))
    w(98, 0)


def entities():
    section("ENTITIES")

    # Closed LW polyline with a bulge on one side.
    entity_begin("LWPOLYLINE", "WALL", "AcDbPolyline")
    w(90, 5)
    w(70, 1)
    for x, y, bulge in ((0, 0, 0), (8, 0, 0), (8, 5, 0), (4, 5, 0.6), (0, 5, 0)):
        w(10, float(x))
        w(20, float(y))
        if bulge:
            w(42, bulge)

    # Open polyline with two arcs.
    entity_begin("LWPOLYLINE", "WALL", "AcDbPolyline")
    w(90, 3)
    w(70, 0)
    for x, y, bulge in ((10, 0, 0.4), (14, 0, -0.4), (18, 0, 0)):
        w(10, float(x))
        w(20, float(y))
        if bulge:
            w(42, bulge)

    hatch([[(0, 8), (6, 8), (3, 13)]], solid=True)
    hatch([[(10, 8), (16, 8), (13, 13)]], solid=False,
          pattern={"angle": 45.0, "dx": -0.5, "dy": 0.5, "dashes": [0.75, -0.25]})

    # MTEXT with an attachment point.
    entity_begin("MTEXT", "NOTE", "AcDbMText")
    w(10, 20.0)
    w(20, 10.0)
    w(30, 0.0)
    w(40, 0.8)
    w(41, 20.0)
    w(71, 1)
    w(72, 5)
    w(1, "MTEXT value")
    w(50, 15.0)

    # Rotated TEXT positioned by its second alignment point.
    entity_begin("TEXT", "NOTE", "AcDbText")
    w(10, 20.0)
    w(20, 6.0)
    w(30, 0.0)
    w(40, 0.7)
    w(1, "rotated text")
    w(50, 30.0)
    w(72, 1)
    w(11, 22.0)
    w(21, 7.0)
    w(31, 0.0)

    # INSERT with one attribute value.
    entity_begin("INSERT", "SYM", "AcDbBlockReference")
    w(2, "DOORTAG")
    w(10, 24.0)
    w(20, 0.0)
    w(30, 0.0)
    w(41, 2.0)
    w(42, 3.0)
    w(43, 1.0)
    w(50, 20.0)
    w(66, 1)
    entity_begin("ATTRIB", "SYM", "AcDbText")
    w(10, 24.4)
    w(20, 3.2)
    w(30, 0.0)
    w(40, 0.5)
    w(1, "D-01")
    w(100, "AcDbAttribute")
    w(2, "TAG")
    w(70, 0)
    w(0, "SEQEND")
    w(5, next_handle())
    w(330, block_record_handles["*Model_Space"])
    w(100, "AcDbEntity")
    w(8, "SYM")

    # Half ellipse.
    entity_begin("ELLIPSE", "SYM", "AcDbEllipse")
    w(10, 32.0)
    w(20, 4.0)
    w(30, 0.0)
    w(11, 4.0)
    w(21, 0.0)
    w(31, 0.0)
    w(210, 0.0)
    w(220, 0.0)
    w(230, 1.0)
    w(40, 0.5)
    w(41, 0.0)
    w(42, 3.141592653589793)

    # Cubic spline through four control points.
    entity_begin("SPLINE", "SYM", "AcDbSpline")
    w(70, 8)
    w(71, 3)
    w(72, 8)
    w(73, 4)
    w(74, 0)
    for knot in (0, 0, 0, 0, 1, 1, 1, 1):
        w(40, float(knot))
    for x, y in ((30, 10), (32, 14), (36, 10), (38, 14)):
        w(10, float(x))
        w(20, float(y))
        w(30, 0.0)

    # Filled SOLID quad. The third and fourth corners are swapped in DXF, so a
    # natural p1-2-3-4 rectangle is written as p1, p2, p4, p3.
    entity_begin("SOLID", "FILL", "AcDbTrace")
    for code, (x, y) in zip((10, 11, 12, 13), ((30, 0), (33, 0), (30, 2), (33, 2))):
        w(code, float(x))
        w(code + 10, float(y))
        w(code + 20, 0.0)

    w(0, "ENDSEC")


block_record_handles = {}

header()
# BLOCK_RECORD handles have to exist before the table is written, so reserve the
# model space handle up front and let the table writer reuse it.
block_record_handles["*Model_Space"] = "20"
tables()
blocks()
entities()
w(0, "EOF")

with open(out_path, "w", encoding="utf-8") as handle_out:
    handle_out.write("\n".join(out) + "\n")
print(f"wrote {out_path}")
