#!/usr/bin/env python3
"""Generates a large DXF used to benchmark parsing and rendering.

  python3 Tools/make_stress.py 50000 [out.dxf]

Produces a grid of LINE entities spread over four layers with different
colours and line weights, so the renderer's style batching is exercised too.
"""
import os
import sys

N = int(sys.argv[1]) if len(sys.argv) > 1 else 20000
out_path = sys.argv[2] if len(sys.argv) > 2 else f"Samples/stress-{N}.dxf"

out = []


def w(code, value):
    out.append(str(code))
    out.append(str(value))


w(0, "SECTION"); w(2, "HEADER"); w(9, "$ACADVER"); w(1, "AC1015")
w(9, "$INSUNITS"); w(70, 4); w(9, "$HANDSEED"); w(5, "FFFF"); w(0, "ENDSEC")

w(0, "SECTION"); w(2, "TABLES")
w(0, "TABLE"); w(2, "LAYER"); w(5, 2); w(330, 0)
w(100, "AcDbSymbolTable"); w(70, 4)
for i, (name, color, weight) in enumerate([("A", 1, 13), ("B", 3, 25),
                                           ("C", 5, 35), ("D", 7, 50)]):
    w(0, "LAYER"); w(5, 20 + i); w(330, 2)
    w(100, "AcDbSymbolTableRecord"); w(100, "AcDbLayerTableRecord")
    w(2, name); w(70, 0); w(62, color); w(6, "CONTINUOUS"); w(370, weight)
w(0, "ENDTAB")

w(0, "TABLE"); w(2, "BLOCK_RECORD"); w(5, 3); w(330, 0)
w(100, "AcDbSymbolTable"); w(70, 2)
for handle, name in ((1, "*Model_Space"), (4, "*Paper_Space")):
    w(0, "BLOCK_RECORD"); w(5, handle); w(330, 3)
    w(100, "AcDbSymbolTableRecord"); w(100, "AcDbBlockTableRecord")
    w(2, name); w(70, 0)
w(0, "ENDTAB"); w(0, "ENDSEC")

w(0, "SECTION"); w(2, "BLOCKS")
for owner, begin, end, name in ((1, 5, 6, "*Model_Space"),
                                (4, 7, 8, "*Paper_Space")):
    w(0, "BLOCK"); w(5, begin); w(330, owner); w(100, "AcDbEntity"); w(8, "0")
    w(100, "AcDbBlockBegin"); w(2, name); w(70, 0)
    w(10, "0.0"); w(20, "0.0"); w(30, "0.0"); w(3, name); w(1, "")
    w(0, "ENDBLK"); w(5, end); w(330, owner); w(100, "AcDbEntity"); w(8, "0")
    w(100, "AcDbBlockEnd")
w(0, "ENDSEC")

w(0, "SECTION"); w(2, "ENTITIES")
handle = 100
columns = 250
for i in range(N):
    handle += 1
    x = (i % columns) * 2.5
    y = (i // columns) * 2.5
    w(0, "LINE"); w(5, handle); w(330, 1); w(100, "AcDbEntity")
    w(8, "ABCD"[i % 4]); w(100, "AcDbLine")
    w(10, f"{x:.3f}"); w(20, f"{y:.3f}"); w(30, "0.0")
    w(11, f"{x + 2.0:.3f}"); w(21, f"{y + 1.2:.3f}"); w(31, "0.0")
w(0, "ENDSEC"); w(0, "EOF")

os.makedirs(os.path.dirname(os.path.abspath(out_path)), exist_ok=True)
with open(out_path, "w", encoding="utf-8") as handle_out:
    handle_out.write("\n".join(out) + "\n")
print("wrote", out_path, os.path.getsize(out_path) // 1024, "KB", N, "entities")
