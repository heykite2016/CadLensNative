#!/usr/bin/env python3
"""Generates a realistic floor-plan DXF (AC1015) for the native renderer tests.

Exercises layered LINE / LWPOLYLINE (with bulges) / ARC / CIRCLE / TEXT /
SOLID, Chinese text, dimensions and a title block.
"""
import math
import os

OUT = os.path.join(os.path.dirname(__file__), "..", "Samples", "plan.dxf")

LAYERS = [
    ("WALL", 7, 50),
    ("DOOR", 3, 25),
    ("WINDOW", 4, 25),
    ("FURN", 8, 18),
    ("TEXT", 2, 18),
    ("DIM", 1, 13),
    ("HATCH", 9, 13),
    ("AXIS", 6, 13),
]

out = []
handle = [100]


def w(code, value):
    out.append(str(code))
    out.append(str(value))


def next_handle():
    handle[0] += 1
    return handle[0]


def start(kind, layer):
    w(0, kind)
    w(5, next_handle())
    w(330, 1)
    w(100, "AcDbEntity")
    w(8, layer)


def line(layer, x1, y1, x2, y2):
    start("LINE", layer)
    w(100, "AcDbLine")
    w(10, f"{x1:.4f}"); w(20, f"{y1:.4f}"); w(30, "0.0")
    w(11, f"{x2:.4f}"); w(21, f"{y2:.4f}"); w(31, "0.0")


def poly(layer, points, closed=True, bulges=None, width=None):
    start("LWPOLYLINE", layer)
    w(100, "AcDbPolyline")
    w(90, len(points))
    w(70, 1 if closed else 0)
    w(43, "0.0")
    if width:
        w(40, f"{width:.4f}"); w(41, f"{width:.4f}")
    for i, (x, y) in enumerate(points):
        w(10, f"{x:.4f}"); w(20, f"{y:.4f}")
        if bulges and i < len(bulges) and bulges[i]:
            w(42, f"{bulges[i]:.6f}")


def arc(layer, cx, cy, r, a0, a1):
    start("ARC", layer)
    w(100, "AcDbCircle")
    w(10, f"{cx:.4f}"); w(20, f"{cy:.4f}"); w(30, "0.0"); w(40, f"{r:.4f}")
    w(100, "AcDbArc")
    w(50, f"{a0:.4f}"); w(51, f"{a1:.4f}")


def circle(layer, cx, cy, r):
    start("CIRCLE", layer)
    w(100, "AcDbCircle")
    w(10, f"{cx:.4f}"); w(20, f"{cy:.4f}"); w(30, "0.0"); w(40, f"{r:.4f}")


def text(layer, x, y, h, value, align=0):
    start("TEXT", layer)
    w(100, "AcDbText")
    w(10, f"{x:.4f}"); w(20, f"{y:.4f}"); w(30, "0.0")
    w(40, f"{h:.3f}")
    w(1, value)
    w(50, "0.0")
    w(7, "STANDARD")
    w(72, align)
    if align:
        w(11, f"{x:.4f}"); w(21, f"{y:.4f}"); w(31, "0.0")
        w(100, "AcDbText")


def solid(layer, points):
    start("SOLID", layer)
    w(100, "AcDbTrace")
    coords = points[:3]
    if len(points) > 3:
        coords = [points[0], points[1], points[3], points[2]]
    for i, (x, y) in enumerate(coords):
        w(10 + i, f"{x:.4f}"); w(20 + i, f"{y:.4f}"); w(30 + i, "0.0")


def dim_horizontal(layer, x1, x2, y, offset=0.0):
    yy = y - offset
    line(layer, x1, y, x1, yy - 0.3)
    line(layer, x2, y, x2, yy - 0.3)
    line(layer, x1, yy, x2, yy)
    for x in (x1, x2):
        line(layer, x - 0.12, yy - 0.12, x + 0.12, yy + 0.12)
    text(layer, (x1 + x2) / 2, yy + 0.12, 0.3,
         f"{abs(x2 - x1) * 1000:.0f}", align=1)


def frame():
    poly("AXIS", [(0, 0), (59.4, 0), (59.4, 42), (0, 42)], closed=True)
    poly("AXIS", [(2, 2), (57.4, 2), (57.4, 40), (2, 40)], closed=True)
    poly("AXIS", [(37, 2), (57.4, 2), (57.4, 10), (37, 10)], closed=True)
    line("AXIS", 37, 6.4, 57.4, 6.4)
    line("AXIS", 47.2, 2, 47.2, 10)
    text("TEXT", 38, 7.6, 0.9, "阳光里 3# 楼 A 户型 施工图")
    text("TEXT", 38, 4.2, 0.55, "比例 1:100     图号 A-101     日期 2026-11-14")
    text("TEXT", 47.8, 7.6, 0.7, "一室两厅")
    text("TEXT", 47.8, 4.2, 0.55, "建筑面积 89.6 m²")


def plan(ox, oy):
    t = 0.24
    walls = [
        (ox, oy, ox + 10.2, oy + t),
        (ox, oy + 7.8, ox + 10.2, oy + 7.8 + t),
        (ox, oy, ox + t, oy + 7.8 + t),
        (ox + 10.2 - t, oy, ox + 10.2, oy + 7.8 + t),
    ]
    for x1, y1, x2, y2 in walls:
        solid("WALL", [(x1, y1), (x2, y1), (x1, y2), (x2, y2)])

    solid("WALL", [(ox + 6.4, oy + t), (ox + 6.4 + t, oy + t),
                   (ox + 6.4, oy + 3.2), (ox + 6.4 + t, oy + 3.2)])
    solid("WALL", [(ox + 6.4, oy + 4.1), (ox + 6.4 + t, oy + 4.1),
                   (ox + 6.4, oy + 7.8), (ox + 6.4 + t, oy + 7.8)])
    solid("WALL", [(ox + 3.6, oy + t), (ox + 3.6 + t, oy + t),
                   (ox + 3.6, oy + 2.6), (ox + 3.6 + t, oy + 2.6)])
    solid("WALL", [(ox + t, oy + 2.6), (ox + t, oy + 2.6 + t),
                   (ox + 3.84, oy + 2.6), (ox + 3.84, oy + 2.6 + t)])

    for x, y, width, a0, a1 in [(ox + 6.4, oy + 3.2, 0.9, 0, 90),
                                (ox + 3.6, oy + 2.6, 0.8, 270, 360),
                                (ox + 9.1, oy + 7.8, 1.0, 180, 270)]:
        arc("DOOR", x, y, width, a0, a1)
        rad = math.radians(a0)
        line("DOOR", x, y, x + width * math.cos(rad), y + width * math.sin(rad))

    for wx in (ox + 1.2, ox + 4.6, ox + 7.4):
        line("WINDOW", wx, oy + 0.02, wx, oy + t - 0.02)
        line("WINDOW", wx + 1.4, oy + 0.02, wx + 1.4, oy + t - 0.02)
        line("WINDOW", wx, oy + t / 2, wx + 1.4, oy + t / 2)

    poly("FURN", [(ox + 7.0, oy + 4.9), (ox + 9.6, oy + 4.9),
                  (ox + 9.6, oy + 7.4), (ox + 7.0, oy + 7.4)])
    poly("FURN", [(ox + 7.15, oy + 5.05), (ox + 8.1, oy + 5.05),
                  (ox + 8.1, oy + 5.7), (ox + 7.15, oy + 5.7)])
    poly("FURN", [(ox + 8.2, oy + 5.05), (ox + 9.4, oy + 5.05),
                  (ox + 9.4, oy + 5.7), (ox + 8.2, oy + 5.7)])
    poly("FURN", [(ox + 0.6, oy + 4.4), (ox + 3.2, oy + 4.4),
                  (ox + 3.2, oy + 5.5), (ox + 0.6, oy + 5.5)])
    poly("FURN", [(ox + 1.2, oy + 6.0), (ox + 3.0, oy + 6.0),
                  (ox + 3.0, oy + 7.0), (ox + 1.2, oy + 7.0)])

    circle("FURN", ox + 4.2, oy + 5.4, 0.65)
    for angle in range(0, 360, 90):
        circle("FURN", ox + 4.2 + 0.95 * math.cos(math.radians(angle)),
               oy + 5.4 + 0.95 * math.sin(math.radians(angle)), 0.22)

    poly("FURN", [(ox + 4.0, oy + 0.3), (ox + 6.3, oy + 0.3),
                  (ox + 6.3, oy + 0.9), (ox + 4.0, oy + 0.9)])
    circle("FURN", ox + 4.5, oy + 0.6, 0.18)
    circle("FURN", ox + 5.2, oy + 0.6, 0.18)
    poly("FURN", [(ox + 0.35, oy + 0.35), (ox + 1.2, oy + 0.35),
                  (ox + 1.2, oy + 1.0), (ox + 0.35, oy + 1.0)])
    circle("FURN", ox + 2.9, oy + 0.7, 0.28)
    poly("FURN", [(ox + 1.6, oy + 1.7), (ox + 2.2, oy + 1.7),
                  (ox + 2.2, oy + 2.4), (ox + 1.6, oy + 2.4)])

    text("TEXT", ox + 1.4, oy + 5.9, 0.42, "客厅 3.6m × 4.6m")
    text("TEXT", ox + 7.6, oy + 6.4, 0.42, "卧室 3.6m × 2.9m", align=1)
    text("TEXT", ox + 1.9, oy + 1.3, 0.36, "卫生间")
    text("TEXT", ox + 5.0, oy + 1.35, 0.36, "厨房")
    text("TEXT", ox + 4.4, oy + 3.5, 0.32, "餐厅")

    dim_horizontal("DIM", ox, ox + 10.2, oy + 7.8, offset=-1.2)
    dim_horizontal("DIM", ox, ox + 3.84, oy + 2.6, offset=0.9)
    dim_horizontal("DIM", ox + 6.4, ox + 10.2, oy + 7.8, offset=-2.6)

    for i, x in enumerate([ox, ox + 6.4, ox + 10.2]):
        line("AXIS", x, oy - 1.6, x, oy + 9.6)
        circle("AXIS", x, oy + 10.0, 0.42)
        text("AXIS", x, oy + 9.86, 0.4, chr(65 + i), align=1)


def main():
    w(0, "SECTION"); w(2, "HEADER")
    w(9, "$ACADVER"); w(1, "AC1015")
    w(9, "$INSUNITS"); w(70, 6)
    w(9, "$HANDSEED"); w(5, "FFFF")
    w(0, "ENDSEC")

    w(0, "SECTION"); w(2, "TABLES")
    w(0, "TABLE"); w(2, "LAYER"); w(5, 2); w(330, 0)
    w(100, "AcDbSymbolTable"); w(70, len(LAYERS))
    for index, (name, color, weight) in enumerate(LAYERS):
        w(0, "LAYER"); w(5, 20 + index); w(330, 2)
        w(100, "AcDbSymbolTableRecord"); w(100, "AcDbLayerTableRecord")
        w(2, name); w(70, 0); w(62, color); w(6, "CONTINUOUS")
        w(370, weight)
    w(0, "ENDTAB")
    w(0, "TABLE"); w(2, "BLOCK_RECORD"); w(5, 3); w(330, 0)
    w(100, "AcDbSymbolTable"); w(70, 2)
    for blockhandle, name in ((1, "*Model_Space"), (4, "*Paper_Space")):
        w(0, "BLOCK_RECORD"); w(5, blockhandle); w(330, 3)
        w(100, "AcDbSymbolTableRecord"); w(100, "AcDbBlockTableRecord")
        w(2, name); w(70, 0)
    w(0, "ENDTAB")
    w(0, "ENDSEC")

    w(0, "SECTION"); w(2, "BLOCKS")
    for owner, begin, end, name in ((1, 5, 6, "*Model_Space"),
                                    (4, 7, 8, "*Paper_Space")):
        w(0, "BLOCK"); w(5, begin); w(330, owner)
        w(100, "AcDbEntity"); w(8, "0")
        w(100, "AcDbBlockBegin"); w(2, name); w(70, 0)
        w(10, "0.0"); w(20, "0.0"); w(30, "0.0")
        w(3, name); w(1, "")
        w(0, "ENDBLK"); w(5, end); w(330, owner)
        w(100, "AcDbEntity"); w(8, "0"); w(100, "AcDbBlockEnd")
    w(0, "ENDSEC")

    w(0, "SECTION"); w(2, "ENTITIES")
    frame()
    plan(6.0, 6.0)
    plan(6.0, 22.0)
    w(0, "ENDSEC")
    w(0, "EOF")

    os.makedirs(os.path.dirname(os.path.abspath(OUT)), exist_ok=True)
    with open(OUT, "w", encoding="utf-8") as handle_out:
        handle_out.write("\n".join(out) + "\n")
    print("wrote", os.path.abspath(OUT), len(out) // 2, "group pairs")


if __name__ == "__main__":
    main()
