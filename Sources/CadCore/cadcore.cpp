// CadCore implementation — reads DWG and DXF through LibreDWG and flattens
// the drawing into plain arrays that Swift can consume without bridging cost.
#include "cadcore.h"

#include "dwg.h"
#include "dwg_api.h"

#include "drw_interface.h"
#include "libdxfrw.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cctype>
#include <dirent.h>
#include <iconv.h>
#include <map>
#include <string>
#include <sys/stat.h>
#include <unordered_map>
#include <unordered_set>
#include <vector>

namespace {

constexpr double kPi = 3.14159265358979323846;
constexpr double kTwoPi = 6.28318530717958647692;
// The reference reader nests INSERTs up to 32 deep before giving up; 12 cut
// off furniture/detail blocks that sit inside room-plan blocks.
constexpr int kMaxDepth = 32;
constexpr size_t kMaxEntities = 900000;

// ---------------------------------------------------------------- palette

const uint32_t kAciPalette[256] = {
    0x000000, 0xFF0000, 0xFFFF00, 0x00FF00, 0x00FFFF, 0x0000FF, 0xFF00FF, 0xFFFFFF,
    0x414141, 0x808080, 0xFF0000, 0xFFAAAA, 0xBD0000, 0xBD7E7E, 0x810000, 0x815656,
    0x680000, 0x684545, 0x4F0000, 0x4F3535, 0xFF3F00, 0xFFBFAA, 0xBD2E00, 0xBD8D7E,
    0x811F00, 0x816056, 0x681900, 0x684E45, 0x4F1300, 0x4F3B35, 0xFF7F00, 0xFFD4AA,
    0xBD5E00, 0xBD9D7E, 0x814000, 0x816B56, 0x683400, 0x685645, 0x4F2700, 0x4F4235,
    0xFFBF00, 0xFFEAAA, 0xBD8D00, 0xBDAD7E, 0x816000, 0x817656, 0x684E00, 0x685F45,
    0x4F3B00, 0x4F4935, 0xFFFF00, 0xFFFFAA, 0xBDBD00, 0xBDBD7E, 0x818100, 0x818156,
    0x686800, 0x686845, 0x4F4F00, 0x4F4F35, 0xBFFF00, 0xEAFFAA, 0x8DBD00, 0xADBD7E,
    0x608100, 0x768156, 0x4E6800, 0x5F6845, 0x3B4F00, 0x494F35, 0x7FFF00, 0xD4FFAA,
    0x5EBD00, 0x9DBD7E, 0x408100, 0x6B8156, 0x346800, 0x566845, 0x274F00, 0x424F35,
    0x3FFF00, 0xBFFFAA, 0x2EBD00, 0x8DBD7E, 0x1F8100, 0x608156, 0x196800, 0x4E6845,
    0x134F00, 0x3B4F35, 0x00FF00, 0xAAFFAA, 0x00BD00, 0x7EBD7E, 0x008100, 0x568156,
    0x006800, 0x456845, 0x004F00, 0x354F35, 0x00FF3F, 0xAAFFBF, 0x00BD2E, 0x7EBD8D,
    0x00811F, 0x568160, 0x006819, 0x45684E, 0x004F13, 0x354F3B, 0x00FF7F, 0xAAFFD4,
    0x00BD5E, 0x7EBD9D, 0x008140, 0x56816B, 0x006834, 0x456856, 0x004F27, 0x354F42,
    0x00FFBF, 0xAAFFEA, 0x00BD8D, 0x7EBDAD, 0x008160, 0x568176, 0x00684E, 0x45685F,
    0x004F3B, 0x354F49, 0x00FFFF, 0xAAFFFF, 0x00BDBD, 0x7EBDBD, 0x008181, 0x568181,
    0x006868, 0x456868, 0x004F4F, 0x354F4F, 0x00BFFF, 0xAAEAFF, 0x008DBD, 0x7EADBD,
    0x006081, 0x567681, 0x004E68, 0x455F68, 0x003B4F, 0x35494F, 0x007FFF, 0xAAD4FF,
    0x005EBD, 0x7E9DBD, 0x004081, 0x566B81, 0x003468, 0x455668, 0x00274F, 0x35424F,
    0x003FFF, 0xAABFFF, 0x002EBD, 0x7E8DBD, 0x001F81, 0x566081, 0x001968, 0x454E68,
    0x00134F, 0x353B4F, 0x0000FF, 0xAAAAFF, 0x0000BD, 0x7E7EBD, 0x000081, 0x565681,
    0x000068, 0x454568, 0x00004F, 0x35354F, 0x3F00FF, 0xBFAAFF, 0x2E00BD, 0x8D7EBD,
    0x1F0081, 0x605681, 0x190068, 0x4E4568, 0x13004F, 0x3B354F, 0x7F00FF, 0xD4AAFF,
    0x5E00BD, 0x9D7EBD, 0x400081, 0x6B5681, 0x340068, 0x564568, 0x27004F, 0x42354F,
    0xBF00FF, 0xEAAAFF, 0x8D00BD, 0xAD7EBD, 0x600081, 0x765681, 0x4E0068, 0x5F4568,
    0x3B004F, 0x49354F, 0xFF00FF, 0xFFAAFF, 0xBD00BD, 0xBD7EBD, 0x810081, 0x815681,
    0x680068, 0x684568, 0x4F004F, 0x4F354F, 0xFF00BF, 0xFFAAEA, 0xBD008D, 0xBD7EAD,
    0x810060, 0x815676, 0x68004E, 0x68455F, 0x4F003B, 0x4F3549, 0xFF007F, 0xFFAAD4,
    0xBD005E, 0xBD7E9D, 0x810040, 0x81566B, 0x680034, 0x684556, 0x4F0027, 0x4F3542,
    0xFF003F, 0xFFAABF, 0xBD002E, 0xBD7E8D, 0x81001F, 0x815660, 0x680019, 0x68454E,
    0x4F0013, 0x4F353B, 0x333333, 0x505050, 0x696969, 0x828282, 0xBEBEBE, 0xFFFFFF,
};

struct CmcColor {
    uint32_t rgb;
    uint8_t aci;
};

// Port of the reference's LibreDwgReader.cpp::cmcColor(), with one correction.
// LibreDWG packs the colour METHOD into the top byte of `rgb`, and an ACI-only
// colour is written as method 0xC3 with the index in the 24-bit payload while
// `index` stays 256. Deciding on `index` alone therefore read every ordinary
// layer as "no colour" and repainted the whole sheet white.
//
// Precedence, most specific first:
//   1. payload above 0xFF  — an unambiguous 24-bit colour (in this drawing the
//      ACI-coded layers carry payloads of 0x03…0xFA, never above 0xFF).
//   2. `index` in 1…255   — the file said so explicitly. Layer TK is exactly
//      this case: index 5 (blue) while the payload holds 0x0000FF; reading the
//      payload first would turn a blue frame layer white.
//   3. small non-zero payload — the ACI index, which is how the remaining
//      layers (WALL 0xA0, STAIR 0x1E, WINDOW 0x0C…) are written.
CmcColor cmcColor(const Dwg_Color &source) {
    const uint32_t payload = uint32_t(source.rgb & 0xFFFFFF);
    const int index = int(source.index);
    if (payload > 0xFF) return { payload, 255 };
    if (index > 0 && index < 256) {
        return { kAciPalette[index], uint8_t(index) };
    }
    if (payload > 0) {
        const int aci = int(payload & 0xFF);
        return { kAciPalette[aci], uint8_t(aci) };
    }
    return { 0xFFFFFF, 7 };
}

const float kLineweightMm[24] = {0.00f, 0.05f, 0.09f, 0.13f, 0.15f, 0.18f,
                                 0.20f, 0.25f, 0.30f, 0.35f, 0.40f, 0.50f,
                                 0.53f, 0.60f, 0.70f, 0.80f, 0.90f, 1.00f,
                                 1.06f, 1.20f, 1.40f, 1.58f, 2.00f, 2.11f};

// 29 = BYLAYER, 30 = BYBLOCK, 31 = BYDEFAULT all land here: AutoCAD draws
// those at the 0.25 mm default rather than at zero width.
float lineweightMm(int raw) {
    if (raw < 0 || raw > 23) return 0.25f;
    return kLineweightMm[raw];
}

// $INSUNITS → metres per drawing unit. Anything unknown is treated as
// millimetres, which is what metric architectural drawings use.
double unitMetersFor(int units) {
    switch (units) {
    case 1: return 0.0254;        // inch
    case 2: return 0.3048;        // foot
    case 3: return 1609.344;      // mile
    case 4: return 0.001;         // millimetre
    case 5: return 0.01;          // centimetre
    case 6: return 1.0;           // metre
    case 7: return 1000.0;        // kilometre
    case 8: return 2.54e-8;       // microinch
    case 9: return 2.54e-5;       // mil
    case 10: return 0.9144;       // yard
    case 11: return 1e-10;        // angstrom
    case 12: return 1e-9;         // nanometre
    case 13: return 1e-6;         // micron
    case 14: return 0.1;          // decimetre
    case 15: return 10.0;         // decametre
    case 16: return 100.0;        // hectometre
    case 17: return 1e9;          // gigametre
    default: return 0.001;
    }
}

struct Affine {
    double m11 = 1, m12 = 0, m21 = 0, m22 = 1, dx = 0, dy = 0;

    cad_point map(double x, double y) const {
        return {m11 * x + m21 * y + dx, m12 * x + m22 * y + dy};
    }
    double scaleX() const { return std::hypot(m11, m12); }
    double scaleY() const { return std::hypot(m21, m22); }
    double meanScale() const { return (scaleX() + scaleY()) * 0.5; }
    double rotation() const { return std::atan2(m12, m11); }
};

Affine compose(const Affine &inner, const Affine &outer) {
    Affine r;
    r.m11 = outer.m11 * inner.m11 + outer.m21 * inner.m12;
    r.m21 = outer.m11 * inner.m21 + outer.m21 * inner.m22;
    r.dx = outer.m11 * inner.dx + outer.m21 * inner.dy + outer.dx;
    r.m12 = outer.m12 * inner.m11 + outer.m22 * inner.m12;
    r.m22 = outer.m12 * inner.m21 + outer.m22 * inner.m22;
    r.dy = outer.m12 * inner.dx + outer.m22 * inner.dy + outer.dy;
    return r;
}

// ---------------------------------------------------------------- ocs
//
// LWPOLYLINE, POLYLINE_2D, CIRCLE, ARC, TEXT and INSERT store their geometry
// in the object coordinate system: a 2D plane given by the entity's extrusion
// vector plus an elevation along the normal. Ignoring it slides every entity
// sitting at a non-zero elevation and mirrors every entity whose normal points
// at −Z — which is what exploded plan details are full of. The basis below is
// AutoCAD's arbitrary axis algorithm, the same one the reference reader uses.

struct Ocs {
    Affine plane;                // OCS (x, y) → WCS (x, y), no elevation
    double elevationDx = 0.0;    // normal.xy * elevation
    double elevationDy = 0.0;
    bool identity = true;
    bool mirrored = false;       // the plane flips handedness (normal.z < 0)
    double angle = 0.0;          // angle of the OCS x axis in the WCS xy plane
    double twoBeta = 0.0;        // mirror axis, as 2β, when `mirrored`

    Affine affine() const {
        Affine r = plane;
        r.dx += elevationDx;
        r.dy += elevationDy;
        return r;
    }
    cad_point map(double x, double y) const {
        return {plane.m11 * x + plane.m21 * y + elevationDx,
                plane.m12 * x + plane.m22 * y + elevationDy};
    }
    // Maps an angle measured in the OCS onto the WCS. A mirrored plane reverses
    // the sweep, so the caller has to swap start and end.
    void mapAngles(double &a0, double &a1) const {
        if (!mirrored) {
            a0 += angle;
            a1 += angle;
            return;
        }
        const double start = twoBeta - a1;
        a1 = twoBeta - a0;
        a0 = start;
    }
};

Ocs ocsFor(const BITCODE_BE &normal, double elevation) {
    Ocs ocs;
    const double nx = normal.x, ny = normal.y, nz = normal.z;
    if (std::abs(nx) < 1e-12 && std::abs(ny) < 1e-12 && nz >= 0.0) {
        // WCS-aligned: only the elevation offset can differ, and its xy part is
        // zero because the normal is (0, 0, +1).
        return ocs;
    }
    cad_point xAxis;
    if (std::abs(nx) < 0.015625 && std::abs(ny) < 0.015625) {
        xAxis = {nz, 0.0};
    } else {
        xAxis = {-ny, nx};
    }
    const double length = std::hypot(xAxis.x, xAxis.y);
    if (length < 1e-12) return ocs;
    xAxis.x /= length;
    xAxis.y /= length;
    const cad_point yAxis{-xAxis.y * nz, nz * xAxis.x};

    ocs.identity = false;
    ocs.plane.m11 = xAxis.x;
    ocs.plane.m12 = xAxis.y;
    ocs.plane.m21 = yAxis.x;
    ocs.plane.m22 = yAxis.y;
    ocs.mirrored = (xAxis.x * yAxis.y - yAxis.x * xAxis.y) < 0.0;
    ocs.angle = std::atan2(xAxis.y, xAxis.x);
    ocs.twoBeta = std::atan2(yAxis.x, xAxis.x);
    ocs.elevationDx = nx * elevation;
    ocs.elevationDy = ny * elevation;
    return ocs;
}

// ---------------------------------------------------------------- text

void appendUtf8(std::string &out, uint32_t cp) {
    if (cp < 0x80) {
        out.push_back(char(cp));
    } else if (cp < 0x800) {
        out.push_back(char(0xC0 | (cp >> 6)));
        out.push_back(char(0x80 | (cp & 0x3F)));
    } else if (cp < 0x10000) {
        out.push_back(char(0xE0 | (cp >> 12)));
        out.push_back(char(0x80 | ((cp >> 6) & 0x3F)));
        out.push_back(char(0x80 | (cp & 0x3F)));
    } else {
        out.push_back(char(0xF0 | (cp >> 18)));
        out.push_back(char(0x80 | ((cp >> 12) & 0x3F)));
        out.push_back(char(0x80 | ((cp >> 6) & 0x3F)));
        out.push_back(char(0x80 | (cp & 0x3F)));
    }
}

bool wideStrings(Dwg_Data *dwg) {
    return dwg->header.version >= R_2007;
}

// Drawings older than R2007 store text in the ANSI code page declared by the
// file ($DWGCODEPAGE). Passing those bytes through as if they were UTF-8 turns
// every Chinese layer, layout and label name into mojibake.
std::string codepageToUtf8(Dwg_Data *dwg, const char *text) {
    if (!text || !text[0]) return {};
    const char *declared = dwg->header_vars.DWGCODEPAGE;
    // Byte streams that are already valid UTF-8 need no conversion; older files
    // written on a Chinese Windows box are GBK, which is invalid UTF-8 and is
    // the common case for drawings from mainland design offices.
    auto validUtf8 = [](const char *s) {
        const unsigned char *p = reinterpret_cast<const unsigned char *>(s);
        while (*p) {
            int extra = 0;
            if (*p < 0x80) { ++p; continue; }
            if ((*p & 0xE0) == 0xC0) extra = 1;
            else if ((*p & 0xF0) == 0xE0) extra = 2;
            else if ((*p & 0xF8) == 0xF0) extra = 3;
            else return false;
            ++p;
            for (int i = 0; i < extra; ++i, ++p) {
                if ((*p & 0xC0) != 0x80) return false;
            }
        }
        return true;
    };
    if (validUtf8(text)) return std::string(text);
    const char *from = "GBK";
    if (declared && declared[0]) {
        if (strstr(declared, "936")) from = "GBK";
        else if (strstr(declared, "950")) from = "BIG5";
        else if (strstr(declared, "932")) from = "SHIFT_JIS";
        else if (strstr(declared, "949")) from = "EUC-KR";
        else if (strstr(declared, "1251")) from = "CP1251";
        else if (strstr(declared, "1252")) from = "CP1252";
        else if (strstr(declared, "UTF-8") || strstr(declared, "UTF8")) from = "UTF-8";
    }
    if (strcmp(from, "UTF-8") == 0) return std::string(text);

    static std::string cachedFrom;
    static iconv_t handle = (iconv_t) -1;
    if (cachedFrom != from) {
        if (handle != (iconv_t) -1) iconv_close(handle);
        handle = iconv_open("UTF-8", from);
        cachedFrom = from;
    }
    if (handle == (iconv_t) -1) return std::string(text);

    size_t inLength = strlen(text);
    size_t outCapacity = inLength * 4 + 8;
    std::string out(outCapacity, '\0');
    char *inPtr = const_cast<char *>(text);
    char *outPtr = &out[0];
    size_t inLeft = inLength;
    size_t outLeft = outCapacity;
    iconv(handle, nullptr, nullptr, nullptr, nullptr);
    size_t converted = iconv(handle, &inPtr, &inLeft, &outPtr, &outLeft);
    if (converted == (size_t) -1) {
        // Unknown byte: fall back to the raw text rather than losing the label.
        return std::string(text);
    }
    out.resize(outCapacity - outLeft);
    return out;
}

std::string toUtf8(Dwg_Data *dwg, const void *value) {
    if (!value) return {};
    std::string out;
    if (wideStrings(dwg)) {
        const uint16_t *s = static_cast<const uint16_t *>(value);
        for (size_t i = 0; s[i]; ++i) {
            uint32_t cp = s[i];
            if (cp >= 0xD800 && cp <= 0xDBFF && s[i + 1] >= 0xDC00
                && s[i + 1] <= 0xDFFF) {
                cp = 0x10000 + ((cp - 0xD800) << 10) + (s[i + 1] - 0xDC00);
                ++i;
            } else if (cp >= 0xD800 && cp <= 0xDFFF) {
                cp = 0xFFFD;
            }
            appendUtf8(out, cp);
        }
    } else {
        out = codepageToUtf8(dwg, static_cast<const char *>(value));
    }
    return out;
}

// LibreDWG stores text fields differently across DWG versions (TV char* for
// r2004, TU UTF-16 for r2007+) and some entities expose the string only
// through the dynapi layer. Reading the struct field directly silently drops
// those entities; the reference reader uses dwg_dynapi_entity_utf8text.
std::string entityText(Dwg_Data *dwg, void *entity, const char *type,
                       const char *field) {
    char *text = nullptr;
    int isNew = 0;
    if (!entity
        || !dwg_dynapi_entity_utf8text(entity, type, field, &text, &isNew, nullptr)
        || !text) {
        return {};
    }
    std::string out = text;
    if (isNew) std::free(text);
    // Despite its name, dynapi_entity_utf8text hands back the raw struct bytes
    // for r2004 and older, where TEXT/MTEXT is a TV (char*) in $DWGCODEPAGE.
    // A Chinese title block therefore arrived as GBK, Swift decoded it as UTF-8,
    // and every character became U+FFFD — the row of "?" that made the sheet
    // look like its font was missing. codepageToUtf8() is a no-op on streams
    // that are already valid UTF-8, so r2007+ (TU/UTF-16) is unaffected.
    if (dwg) out = codepageToUtf8(dwg, out.c_str());
    return out;
}

void replaceAll(std::string &s, const std::string &from, const std::string &to) {
    size_t pos = 0;
    while ((pos = s.find(from, pos)) != std::string::npos) {
        s.replace(pos, from.size(), to);
        pos += to.size();
    }
}

// Strips MTEXT inline formatting, keeping the visible characters.
//
// 这里每个字符都要按 AutoCAD 的富文本语法处理，不能"猜"：
//   \P 才是换行；\p 是段落属性（\pi5.25,l1.2; 之类），早先把 "\p" 也换成
//   换行，结果 \pi5.25; 被劈成 "\n" + "i5.25;{"——整段施工说明从第一个段
//   落属性开始就变成"i5.25;{..."的乱码，而且只剩半行。
std::string cleanMText(const std::string &raw) {
    std::string out;
    out.reserve(raw.size());
    const size_t n = raw.size();
    auto hexValue = [](char c, int &value) -> bool {
        if (c >= '0' && c <= '9') { value = c - '0'; return true; }
        if (c >= 'A' && c <= 'F') { value = c - 'A' + 10; return true; }
        if (c >= 'a' && c <= 'f') { value = c - 'a' + 10; return true; }
        return false;
    };
    size_t i = 0;
    while (i < n) {
        const char c = raw[i];
        if (c == '{' || c == '}') { ++i; continue; }   // 格式分组大括号
        if (c != '\\') { out.push_back(c); ++i; continue; }
        if (i + 1 >= n) break;
        const char code = raw[i + 1];
        if (code == 'P') { out.push_back('\n'); i += 2; continue; }
        if (code == '~') { out.push_back(' '); i += 2; continue; }
        if (code == '\\' || code == '{' || code == '}') {
            out.push_back(code); i += 2; continue;
        }
        if (code == 'U' && i + 2 < n && raw[i + 2] == '+') {
            // \U+XXXX：BMP 的 Unicode 转义，中文图纸里非常常见。
            if (i + 6 < n) {
                int digits[4];
                bool ok = true;
                for (int k = 0; k < 4; ++k) {
                    if (!hexValue(raw[i + 3 + size_t(k)], digits[k])) { ok = false; break; }
                }
                if (ok) {
                    const uint32_t cp = uint32_t(digits[0] << 12 | digits[1] << 8
                                                 | digits[2] << 4 | digits[3]);
                    if (cp) appendUtf8(out, cp);
                    i += 7;
                    continue;
                }
            }
            i += 2;
            continue;
        }
        if (code == 'M' && i + 2 < n && raw[i + 2] == '+') {
            // \M+XXXXXX：1~6 位十六进制码位（可超出 BMP）。
            size_t j = i + 3;
            uint32_t cp = 0;
            int count = 0;
            while (j < n && count < 6) {
                int digit = 0;
                if (!hexValue(raw[j], digit)) break;
                cp = (cp << 4) | uint32_t(digit);
                ++j;
                ++count;
            }
            if (count > 0 && cp > 0) {
                appendUtf8(out, cp);
                i = j;
            } else {
                i += 2;
            }
            continue;
        }
        if (code == 'S') {
            // \Sa^b; 分式：压成 a/b。分段上下标 \S1^2; 同理。
            const size_t end = raw.find(';', i + 2);
            const std::string body = end == std::string::npos
                                         ? raw.substr(i + 2)
                                         : raw.substr(i + 2, end - i - 2);
            const size_t caret = body.find('^');
            if (caret != std::string::npos) {
                out += body.substr(0, caret);
                out += "/";
                out += body.substr(caret + 1);
            } else {
                out += body;
            }
            i = end == std::string::npos ? n : end + 1;
            continue;
        }
        // 其余都是 \X....; 形式的控制码（字体、字高、颜色、对齐、段落…），
        // 一律跳到分号；没有分号的（开关码）只吃掉字母本身。
        const size_t end = raw.find(';', i + 2);
        if (end == std::string::npos) { i += 2; continue; }
        i = end + 1;
    }
    replaceAll(out, "%%d", "\xC2\xB0");
    replaceAll(out, "%%D", "\xC2\xB0");
    replaceAll(out, "%%c", "\xC3\x98");
    replaceAll(out, "%%C", "\xC3\x98");
    replaceAll(out, "%%p", "\xC2\xB1");
    replaceAll(out, "%%P", "\xC2\xB1");
    replaceAll(out, "%%%", "%");
    return out;
}

std::string cleanText(const std::string &raw) {
    std::string out = raw;
    replaceAll(out, "%%d", "\xC2\xB0");
    replaceAll(out, "%%D", "\xC2\xB0");
    replaceAll(out, "%%c", "\xC3\x98");
    replaceAll(out, "%%C", "\xC3\x98");
    replaceAll(out, "%%p", "\xC2\xB1");
    replaceAll(out, "%%P", "\xC2\xB1");
    replaceAll(out, "%%%", "%");
    return out;
}

}  // namespace

// ---------------------------------------------------------------- document

struct cad_doc {
    std::vector<cad_entity> entities;
    std::vector<cad_point> points;
    std::vector<cad_ring> rings;
    std::vector<cad_hatch> hatches;
    std::vector<cad_layer> layers;
    std::vector<cad_space> spaces;
    std::vector<cad_viewport> viewports;
    std::vector<int32_t> frozenLayers;  // VPLAYER indices, sliced per viewport
    std::vector<int32_t> blockLayers;   // per-entity INSERT ancestor layers
    cad_saved_view savedView{};         // VPORT *Active camera, if any
    // EXTMIN/EXTMAX as stored in the DWG header. This is the extent AutoCAD
    // last saved with the drawing — the designer's own "how big is this
    // drawing" answer, and the box the reference viewer centres its first
    // camera on (CadModel.cpp::finalize prefers declaredBounds over a computed
    // entity union). It is smaller than the union whenever stray construction
    // geometry lives far away, which is precisely when the union is useless as
    // a framing hint. Invalid when minx > maxx.
    cad_bbox declaredBox{1.0, 1.0, -1.0, -1.0};
    std::string text;
    std::string version;
    std::string backend;
    double loadMs = 0;
    double unitMeters = 0.001;
    int calibrated = 0;
    int skipped = 0;
    // Set when the 900k safety ceiling dropped entities. Silent truncation is
    // unacceptable for a viewer: the sheet would look complete but miss walls.
    int truncated = 0;
    // (start, length) slices into `text` for each distinct XREF this drawing
    // needs but cannot supply — see noteXref() below.
    std::vector<std::pair<int32_t, int32_t>> xrefs;

    /// One INSERT of an external reference, with the placement it was drawn at.
    /// The geometry is in another file, but the *transform* is in this one, so
    /// recording both lets the app load the missing file later and drop it in
    /// exactly where the author put it. Without the transform an attached xref
    /// would land at the origin, which looks like "the xref didn't load".
    struct xref_insert {
        int32_t nameStart = 0, nameLen = 0;
        int32_t pathStart = 0, pathLen = 0;
        int32_t space = 0;
        int32_t layer = -1;
        double m[6] = {1, 0, 0, 1, 0, 0};
    };
    std::vector<xref_insert> xrefInserts;

    int32_t noteText(const std::string &value) {
        const int32_t start = int32_t(text.size());
        text += value;
        return start;
    }

    /// Records one external reference the file inserts. Only the name is kept,
    /// de-duplicated: a sheet that drops the same sofa 13 times is still one
    /// missing file. The string is appended to `text` so the existing text blob
    /// carries it across the C boundary.
    void noteXref(Dwg_Data *dwg, const char *name) {
        std::string utf8 = codepageToUtf8(dwg, (name && name[0]) ? name : "");
        if (utf8.empty()) return;
        for (const auto &known : xrefs) {
            if (text.compare(size_t(known.first), size_t(known.second), utf8) == 0) {
                return;
            }
        }
        xrefs.emplace_back(int32_t(text.size()), int32_t(utf8.size()));
        text += utf8;
    }
};

namespace {

struct Builder {
    cad_doc *doc = nullptr;
    Dwg_Data *dwg = nullptr;
    std::unordered_map<std::string, int> layerByName;
    std::unordered_map<uint64_t, std::string> layerByHandle;
    std::unordered_map<uint64_t, int> layerIndexByHandle;
    std::unordered_map<uint64_t, Dwg_Object *> objectByHandle;
    std::unordered_set<uint64_t> expandedBlocks;
    // LibreDWG only resolves first_attrib/attribs for a subset of DWG
    // versions. The reference reader indexes every ATTRIB once by its
    // ownerhandle and looks the list up from the owning INSERT instead, so
    // attribute text that has no usable handle chain is still emitted.
    std::unordered_map<uint64_t, std::vector<Dwg_Object *>> attributesByOwner;
    // XCLIP: an INSERT (or any entity) can carry a SPATIAL_FILTER through its
    // extension dictionary. AutoCAD shows only the geometry inside the filter
    // boundary; skipping it leaves the whole block definition on screen, which
    // is exactly how furniture ends up drawn over the walls. Polygons are in
    // the clipped entity's own block coordinates.
    std::unordered_map<uint64_t, std::vector<cad_point>> clipsByHandle;
    int clipsIndexed = 0;
    int clipDropped = 0;
    // ATTMODE: 0 = hide every attribute, 1 = honour each ATTRIB flag,
    // 2 = show every attribute. Matches the reference reader.
    int attributeMode = 1;
    int attrSource = 0, attrVisible = 0, attrRendered = 0, attrSuppressed = 0;
    std::unordered_map<int, int> typeCount;  // raw DWG fixedtype → visits
    // Loss audit: every place that can throw geometry away increments one of
    // these, so `CADCORE_TYPES=1` can show *where* entities disappear instead
    // of only how many reached the renderer.
    int dropEmpty = 0, dropInvisible = 0, dropDepth = 0, dropBudget = 0;
    std::unordered_map<int, int> dropByKind;
    int dimTotal = 0, dimExpanded = 0, dimNoBlock = 0, dimBlockChildren = 0;
    int dimInvisibleChildren = 0;
    int blockChainVisits = 0, blockArrayVisits = 0;
    std::unordered_map<int, int> dimChildKinds;
    // Layers of the INSERTs currently being expanded. A viewport freeze must
    // also hide geometry whose ancestor block lives on that layer, even if the
    // geometry itself resolved to layer 0 / another layer.
    std::vector<int32_t> blockLayerStack;
    // 外部参照：本图的路径（用来找同目录的参照文件），以及已解析的参照文件。
    // 参照内容不另开渲染通道，直接按 INSERT 的变换并进本图图元表——参照和
    // 图纸是同一张纸上的一批线，分开渲染只会多一层同步成本。
    std::string sourcePath;
    std::unordered_map<std::string, cad_doc *> xrefDocs;
    std::unordered_set<std::string> xrefTried;
    int xrefBound = 0;

    void freeXrefs() {
        for (auto &entry : xrefDocs) delete entry.second;
        xrefDocs.clear();
    }
    // Drawing diagonal from the DWG header (EXTMIN/EXTMAX). Infinite entities
    // (XLINE/RAY) and MLINE offsets are clamped to this so construction lines
    // span the sheet instead of running to infinity or collapsing to a dot.
    double referenceExtent = 1000.0;

    int textStart(const std::string &s) {
        int start = int(doc->text.size());
        doc->text += s;
        doc->text.push_back('\0');
        return start;
    }

    int addPoint(double x, double y) {
        doc->points.push_back({x, y});
        return int(doc->points.size()) - 1;
    }

    int layerIndexFor(Dwg_Object_Ref *ref) {
        if (!ref) return -1;
        auto it = layerIndexByHandle.find(ref->absolute_ref);
        if (it != layerIndexByHandle.end()) return it->second;
        Dwg_Object *obj = dwg_ref_object(dwg, ref);
        if (!obj || !obj->tio.object) return -1;
        Dwg_Object_LAYER *layer = obj->tio.object->tio.LAYER;
        if (!layer) return -1;
        std::string name = toUtf8(dwg, layer->name);
        auto found = layerByName.find(name);
        if (found != layerByName.end()) {
            layerIndexByHandle[ref->absolute_ref] = found->second;
            return found->second;
        }
        return -1;
    }

    int layerAci(int index) {
        if (index < 0 || index >= int(doc->layers.size())) return 7;
        return int((doc->layers[index].rgb >> 24) & 0xFF);
    }
};

// Text height from a text style is not resolved; drawing unit height is used.
std::string layerName(const cad_doc *doc, int index) {
    if (!doc || index < 0 || index >= int(doc->layers.size())) return {};
    const cad_layer &layer = doc->layers[size_t(index)];
    if (layer.name_start < 0 || layer.name_len <= 0) return {};
    const size_t at = size_t(layer.name_start);
    if (at + size_t(layer.name_len) > doc->text.size()) return {};
    return doc->text.substr(at, size_t(layer.name_len));
}

void addEntityCommon(Builder &b, Dwg_Object *obj, int space, int layer,
                     uint32_t rgb, uint8_t aci, float lineweight, int flags,
                     cad_entity *out) {
    Dwg_Object_Entity *ent = obj->tio.entity;
    out->space = space;
    out->layer = layer;
    out->handle = obj->handle.value;
    out->rgb = rgb;
    out->aci = aci;
    out->lineweight = lineweight;
    out->flags = flags;
    out->hatch = -1;
    out->tstart = -1;
    out->tlen = 0;
    out->box = {1e300, 1e300, -1e300, -1e300};
    if (ent && (ent->invisible & 1)) out->flags |= CAD_FLAG_INVISIBLE;
    // Reference: CadEntity::blockLayerIndices. VPLAYER freezes every layer in
    // the INSERT chain, not just the entity's effective layer.
    out->block_layer_start = int32_t(b.doc->blockLayers.size());
    out->block_layer_count = int32_t(b.blockLayerStack.size());
    b.doc->blockLayers.insert(b.doc->blockLayers.end(),
                              b.blockLayerStack.begin(), b.blockLayerStack.end());
}

/// Conservative typographic box for a text entity.
///
/// Reference: CadModel.cpp::updateBounds(). Text and curves both carry exact
/// sampled points, and the bbox is never inflated by an analytic frame,
/// otherwise spatial queries and LOD disagree with what the renderer strokes.
/// Kept separate from pushEntity() because the GB height pass in finishSpace()
/// rewrites `h` after the fact and has to rebuild the box.
void updateTextBox(const cad_doc *doc, cad_entity &e) {
    double h = e.h > 0 ? e.h : 1.0;
    int lines = 1;
    if (e.tstart >= 0 && e.tlen > 0
        && size_t(e.tstart) + size_t(e.tlen) <= doc->text.size()) {
        const char *base = doc->text.data() + e.tstart;
        for (int i = 0; i < e.tlen; ++i) if (base[i] == '\n') ++lines;
    }
    const double w = h * std::max<size_t>(1, size_t(e.tlen)) * 0.62
                     * std::max(0.05, e.ws);
    const double height = h * double(lines) * 1.2;
    double left = e.cx;
    double top = e.cy - height * 0.2;
    if (e.halign == 1 || e.halign == 4) left -= w * 0.5;
    else if (e.halign == 2) left -= w;
    if (e.halign == 4 || e.valign == 2) top = e.cy - height * 0.5;
    else if (e.valign == 3) top = e.cy - height;
    else if (e.valign == 1) top = e.cy;
    e.box.minx = left;
    e.box.maxx = left + w;
    e.box.miny = top;
    e.box.maxy = top + height;
}

void pushEntity(Builder &b, cad_entity &e) {
    cad_doc *doc = b.doc;
    e.box = {1e300, 1e300, -1e300, -1e300};
    for (int i = 0; i < e.pcount; ++i) {
        const cad_point &p = doc->points[size_t(e.pstart) + size_t(i)];
        e.box.minx = std::min(e.box.minx, p.x);
        e.box.miny = std::min(e.box.miny, p.y);
        e.box.maxx = std::max(e.box.maxx, p.x);
        e.box.maxy = std::max(e.box.maxy, p.y);
    }
    if (e.kind == CAD_TEXT) {
        updateTextBox(doc, e);
    } else if (e.kind == CAD_POINT) {
        // A point has no vertices of its own; without a degenerate box it would
        // be discarded by the check below and never drawn.
        e.box.minx = e.box.maxx = e.cx;
        e.box.miny = e.box.maxy = e.cy;
    } else if (e.kind == CAD_HATCH) {
        // A hatch carries no points of its own: its extent comes from the
        // boundary rings, otherwise the entity is dropped as empty and the
        // fill never renders.
        if (e.hatch >= 0 && e.hatch < int(doc->hatches.size())) {
            const cad_hatch &hatch = doc->hatches[size_t(e.hatch)];
            for (int r = 0; r < hatch.ringcount; ++r) {
                const cad_ring &ring = doc->rings[size_t(hatch.ringstart) + size_t(r)];
                for (int i = 0; i < ring.pcount; ++i) {
                    const cad_point &p = doc->points[size_t(ring.pstart) + size_t(i)];
                    e.box.minx = std::min(e.box.minx, p.x);
                    e.box.miny = std::min(e.box.miny, p.y);
                    e.box.maxx = std::max(e.box.maxx, p.x);
                    e.box.maxy = std::max(e.box.maxy, p.y);
                }
            }
        }
    }
    if (e.box.minx > e.box.maxx) {
        b.dropEmpty += 1;
        b.dropByKind[e.kind] += 1;
        return;
    }
    doc->entities.push_back(e);
}

// ------------------------------------------------------------ external refs
//
// 外部参照（XREF）的几何在另一个文件里，图纸里只留一条 INSERT。参照项目的
// 做法值得照搬：用 BLOCK_HEADER.blkisxref 认出参照块，在同目录里按块名找到
// 对应文件，把那份图解析成图元后按 INSERT 的变换并进来——参照内容和本图
// 图元走同一条渲染路径，不需要第二套坐标系，也不需要单独的图层。
//
// 为什么不能只信 xref_pname：LibreDWG 给普通块的 xref_pname 也填了块名，
// 按"指针非空"判断会把所有块插入当成参照丢掉（本机一张图纸上就误判了 376 处）。

namespace {
/// 参照链深度：A 参照 B、B 又参照 A 的文件不能无限展开。
thread_local int g_xrefDepth = 0;
constexpr int kMaxXrefDepth = 2;

std::string xrefKey(std::string value) {
    const size_t slash = value.find_last_of("/\\");
    if (slash != std::string::npos) value = value.substr(slash + 1);
    const size_t dot = value.find_last_of('.');
    if (dot != std::string::npos) value = value.substr(0, dot);
    while (!value.empty() && value.front() == '_') value.erase(value.begin());
    for (char &c : value) c = char(std::tolower(static_cast<unsigned char>(c)));
    return value;
}

std::string xrefFolder(const std::string &path) {
    const size_t slash = path.find_last_of("/\\");
    return slash == std::string::npos ? std::string(".") : path.substr(0, slash);
}

void listSiblingDrawings(const std::string &folder, std::vector<std::string> &out) {
    DIR *dir = opendir(folder.c_str());
    if (!dir) return;
    while (dirent *entry = readdir(dir)) {
        std::string name = entry->d_name;
        std::string lower = name;
        for (char &c : lower) c = char(std::tolower(static_cast<unsigned char>(c)));
        if (lower.size() > 4
            && (lower.compare(lower.size() - 4, 4, ".dwg") == 0
                || lower.compare(lower.size() - 4, 4, ".dxf") == 0)) {
            out.push_back(folder + "/" + name);
        }
    }
    closedir(dir);
}

/// 参照文件里同名图层直接复用本图的图层：图层开关、颜色覆盖才能一起管住
/// 参照内容。没有同名图层就照参照文件的样子建一个。
int32_t xrefLayer(Builder &b, const cad_doc *child, int32_t childLayer) {
    const std::string name = layerName(child, childLayer);
    if (name.empty()) return -1;
    auto found = b.layerByName.find(name);
    if (found != b.layerByName.end()) return found->second;
    cad_layer layer{};
    if (childLayer >= 0 && childLayer < int32_t(child->layers.size()))
        layer = child->layers[size_t(childLayer)];
    layer.name_start = b.textStart(name);
    layer.name_len = int32_t(name.size());
    layer.count = 0;
    const int32_t index = int32_t(b.doc->layers.size());
    b.doc->layers.push_back(layer);
    b.layerByName[name] = int(index);
    return index;
}

void emitXref(Builder &b, const cad_doc *child, const Affine &xf,
              int32_t space, int32_t insertLayer, const char *prefix) {
    const double determinant = xf.m11 * xf.m22 - xf.m12 * xf.m21;
    const double scale = std::sqrt(std::abs(determinant));
    const double angle = std::atan2(xf.m12, xf.m11);
    const int32_t pointBase = int32_t(b.doc->points.size());
    const int32_t ringBase = int32_t(b.doc->rings.size());
    const int32_t hatchBase = int32_t(b.doc->hatches.size());

    for (const cad_point &point : child->points) {
        cad_point mapped = xf.map(point.x, point.y);
        b.doc->points.push_back(mapped);
    }
    for (const cad_ring &ring : child->rings) {
        cad_ring copy = ring;
        copy.pstart += pointBase;
        b.doc->rings.push_back(copy);
    }
    for (const cad_hatch &hatch : child->hatches) {
        cad_hatch copy = hatch;
        copy.ringstart += ringBase;
        b.doc->hatches.push_back(copy);
    }

    for (const cad_entity &source : child->entities) {
        if (source.space != 0) continue;   // 参照只用模型空间
        cad_entity e = source;
        e.space = space;
        if (e.pcount > 0) e.pstart += pointBase;
        if (e.hatch >= 0) e.hatch += hatchBase;
        int32_t layer = xrefLayer(b, child, source.layer);
        // 参照图层加"参照名|"前缀只在新建时用，复用同名图层就不再重复。
        if (layer < 0) layer = insertLayer;
        e.layer = layer;
        e.block_layer_start = int32_t(b.doc->blockLayers.size());
        e.block_layer_count = 1;
        b.doc->blockLayers.push_back(layer);

        const cad_point centre = xf.map(e.cx, e.cy);
        e.cx = centre.x;
        e.cy = centre.y;
        if (e.r != 0) e.r *= scale;
        if (determinant < 0) {
            const double a0 = e.a0, a1 = e.a1;
            e.a0 = angle - a1;
            e.a1 = angle - a0;
        } else {
            e.a0 += angle;
            e.a1 += angle;
        }
        if (e.major_x != 0 || e.major_y != 0) {
            const cad_point major = xf.map(e.major_x, e.major_y);
            e.major_x = major.x - xf.dx;
            e.major_y = major.y - xf.dy;
        }
        e.rot += angle;
        if (e.h != 0) e.h *= scale;
        if (e.tlen > 0 && e.tstart >= 0
            && size_t(e.tstart) + size_t(e.tlen) <= child->text.size()) {
            const std::string text = child->text.substr(size_t(e.tstart), size_t(e.tlen));
            e.tstart = b.textStart(text);
            e.tlen = int32_t(text.size());
        }
        // 参照内容不属于本图的尺寸标注，标记清掉，捕捉可以照常吸。
        e.flags &= ~CAD_FLAG_DIMENSION;
        // 视口裁剪框是参照文件纸空间里的坐标，搬进本图后只剩误导。
        e.clip = {0, 0, 0, 0};
        (void)prefix;
        pushEntity(b, e);
    }
}

/// 找参照文件：先按块名在同目录匹配，再按图纸里存的路径里的文件名匹配。
/// 都找不到就返回 nullptr——这时才轮到界面去问用户要文件。
cad_doc *xrefDocumentFor(Builder &b, const char *blockName, const char *pathHint) {
    if (!blockName || !blockName[0]) return nullptr;
    const std::string key = xrefKey(blockName);
    auto cached = b.xrefDocs.find(key);
    if (cached != b.xrefDocs.end()) return cached->second;
    if (!b.xrefTried.insert(key).second) return nullptr;
    if (g_xrefDepth >= kMaxXrefDepth || b.sourcePath.empty()) return nullptr;

    std::vector<std::string> siblings;
    listSiblingDrawings(xrefFolder(b.sourcePath), siblings);
    std::string pick;
    for (const std::string &candidate : siblings) {
        if (xrefKey(candidate) == key) { pick = candidate; break; }
    }
    if (pick.empty() && pathHint && pathHint[0]) {
        const std::string want = xrefKey(pathHint);
        for (const std::string &candidate : siblings) {
            if (xrefKey(candidate) == want) { pick = candidate; break; }
        }
    }
    if (pick.empty()) return nullptr;
    if (xrefKey(pick) == xrefKey(b.sourcePath)) return nullptr;   // 参照了自己

    ++g_xrefDepth;
    cad_doc *child = cad_doc_load(pick.c_str(), nullptr);
    --g_xrefDepth;
    if (!child) return nullptr;
    if (child->entities.empty()) {
        delete child;
        return nullptr;
    }
    if (getenv("CADCORE_XREF_LOG")) {
        fprintf(stderr, "[corexref] bind key=%s -> %s (entities=%zu)\n",
                key.c_str(), pick.c_str(), child->entities.size());
    }
    b.xrefDocs[key] = child;
    return child;
}
}  // namespace

// ------------------------------------------------------------ curve flattening
//
// The reference reader (LibreDwgReader.cpp::sampleArc at 375 and
// CadModel.cpp::sampleArc at 296) flattens CIRCLE / ARC / ELLIPSE into WCS
// point lists *at import time*: π/48 per segment, at least 36 segments for a
// whole circle (8 for an arc), at most 512. Every sample is projected through
// the OCS plane and then through the full INSERT affine. drawCadEntities()
// consequently only ever strokes a polyline — the CG renderer, the GPU
// renderer and the layout viewport projection all consume the very same
// geometry, so a mirrored insert, a −Z OCS plane or a twisted viewport can
// never make them disagree about where an endpoint is.
//
// The analytic fields (centre, radius, angles, major axis) are kept on the
// entity for snapping/measurement, but never used for drawing.

void setCurvePoints(Builder &b, cad_entity &e,
                    const std::vector<cad_point> &samples) {
    if (samples.size() < 2) return;
    e.pstart = int(b.doc->points.size());
    e.pcount = int(samples.size());
    b.doc->points.insert(b.doc->points.end(), samples.begin(), samples.end());
}

std::vector<cad_point> sampleArcOcs(const Affine &xf, const Ocs &ocs,
                                    double cx, double cy, double radius,
                                    double start, double sweep,
                                    bool fullCircle) {
    std::vector<cad_point> out;
    if (!(radius > 0.0) || !std::isfinite(sweep) || std::abs(sweep) < 1e-12) {
        return out;
    }
    constexpr double kPi = 3.14159265358979323846;
    const int steps = std::clamp(
        int(std::ceil(std::abs(sweep) / (kPi / 48.0))),
        fullCircle ? 36 : 8, 512);
    const int count = fullCircle ? steps : steps + 1;
    out.reserve(size_t(count));
    for (int i = 0; i < count; ++i) {
        const double a = start + sweep * double(i) / double(steps);
        const cad_point local{cx + radius * std::cos(a),
                              cy + radius * std::sin(a)};
        const cad_point wcs = ocs.map(local.x, local.y);
        out.push_back(xf.map(wcs.x, wcs.y));
    }
    return out;
}

std::vector<cad_point> sampleEllipseOcs(const Affine &xf, const Ocs &ocs,
                                        double cx, double cy,
                                        double majorX, double majorY,
                                        double minorX, double minorY,
                                        double start, double sweep,
                                        bool fullCircle) {
    std::vector<cad_point> out;
    if (!std::isfinite(sweep) || std::abs(sweep) < 1e-12) return out;
    constexpr double kPi = 3.14159265358979323846;
    const int steps = std::clamp(
        int(std::ceil(std::abs(sweep) / (kPi / 48.0))), 16, 384);
    const int count = fullCircle ? steps : steps + 1;
    out.reserve(size_t(count));
    for (int i = 0; i < count; ++i) {
        const double t = start + sweep * double(i) / double(steps);
        const double ct = std::cos(t), st = std::sin(t);
        const cad_point local{cx + majorX * ct + minorX * st,
                              cy + majorY * ct + minorY * st};
        const cad_point wcs = ocs.map(local.x, local.y);
        out.push_back(xf.map(wcs.x, wcs.y));
    }
    return out;
}

void appendArcPoints(Builder &b, std::vector<int> &idx, double cx, double cy,
                     double r, double a0, double a1, bool ccw) {
    double sweep = a1 - a0;
    if (ccw) {
        while (sweep <= 0) sweep += kTwoPi;
    } else {
        while (sweep >= 0) sweep -= kTwoPi;
    }
    double length = std::abs(sweep) * r;
    int segments = int(std::ceil(length / std::max(0.01, r * 0.12)));
    segments = std::clamp(segments, 2, 180);
    for (int i = 0; i <= segments; ++i) {
        double a = a0 + sweep * (double(i) / double(segments));
        idx.push_back(b.addPoint(cx + r * std::cos(a), cy + r * std::sin(a)));
    }
}

// Converts a bulge segment into an arc approximation. Copied verbatim from
// the reference reader (LibreDwgReader.cpp::appendBulge): the sweep is
// `theta = 4*atan(bulge)` sampled with its sign intact, so negative bulges run
// clockwise. Deriving the centre from `chord/(2*sin(theta/2))` instead makes
// the radius negative for clockwise arcs, which silently puts the centre on
// the wrong side and leaves the closing vertex short of the start point.
void sampleBulge(std::vector<cad_point> &out, cad_point p0, cad_point p1,
                 double bulge) {
    constexpr double kPi = 3.14159265358979323846;
    if (std::abs(bulge) < 1.0e-10) {
        out.push_back(p1);
        return;
    }
    const double dx = p1.x - p0.x, dy = p1.y - p0.y;
    const double chord = std::hypot(dx, dy);
    if (chord < 1.0e-12) {
        out.push_back(p1);
        return;
    }
    const double theta = 4.0 * std::atan(bulge);
    const double nx = -dy / chord, ny = dx / chord;
    const double offset = chord * 0.5 / std::tan(theta * 0.5);
    const double cx = (p0.x + p1.x) * 0.5 + nx * offset;
    const double cy = (p0.y + p1.y) * 0.5 + ny * offset;
    const double radius = std::hypot(p0.x - cx, p0.y - cy);
    const double start = std::atan2(p0.y - cy, p0.x - cx);
    const int count = std::clamp(int(std::ceil(std::abs(theta) / (kPi / 24.0))),
                                 4, 256);
    for (int i = 1; i <= count; ++i) {
        const double angle = start + theta * double(i) / double(count);
        out.push_back({cx + std::cos(angle) * radius,
                       cy + std::sin(angle) * radius});
    }
}

void appendBulge(Builder &b, std::vector<int> &idx, cad_point p0, cad_point p1,
                 double bulge) {
    std::vector<cad_point> sampled;
    sampleBulge(sampled, p0, p1, bulge);
    for (const cad_point &p : sampled) idx.push_back(b.addPoint(p.x, p.y));
}

// Port of CadModel.cpp::appendConnectedPolylinePiece. Hatch boundary segments
// arrive in drawing order but are not guaranteed to be stored head-to-tail, and
// an arc that misses its neighbour by even a hair breaks the loop. Appending
// every segment to one flat point list (the previous behaviour) then draws a
// long chord across the whole boundary and the fill covers the wrong region.
// Here each segment either extends the current chain at whichever end it
// touches, or starts a new chain — and every chain becomes its own loop.
void appendConnectedPiece(std::vector<std::vector<cad_point>> &chains,
                          std::vector<cad_point> piece, double tolerance) {
    if (piece.empty()) return;
    const auto same = [tolerance](const cad_point &a, const cad_point &b) {
        return std::hypot(a.x - b.x, a.y - b.y) <= tolerance;
    };
    if (chains.empty()) {
        chains.push_back(std::move(piece));
        return;
    }
    std::vector<cad_point> &path = chains.back();
    if (!path.empty() && same(path.back(), piece.front())) {
        path.insert(path.end(), piece.begin() + 1, piece.end());
        return;
    }
    if (!path.empty() && same(path.back(), piece.back())) {
        for (int i = int(piece.size()) - 2; i >= 0; --i) path.push_back(piece[size_t(i)]);
        return;
    }
    chains.push_back(std::move(piece));
}

// Rational De Boor evaluation. Splines carry per-control-point weights (DXF
// group 41), and ignoring them misplaces the exact circles/arcs that AutoCAD
// exports as weighted splines.
//
// Sampling is done per knot span (12 samples each), never at the far end of the
// knot vector. A uniform u0..u1 sweep that evaluates exactly at u1 falls off
// the last span: the span lookup then returns the *first* span, alpha becomes a
// huge extrapolating ratio and the final sample flies millions of units away,
// drawing a stray line right across the drawing. The reference reader uses
// `nextafter(end, start)` for that last sample; we do the same.
std::vector<cad_point> sampleSpline(int degree, const std::vector<cad_point> &cps,
                                    const std::vector<double> &knots,
                                    const std::vector<double> &weights,
                                    bool fitPoints) {
    const size_t count = cps.size();
    if (count < 2) return cps;
    const int deg = std::clamp(degree, 1, int(count) - 1);
    const bool hasNurbs = knots.size() >= count + size_t(deg) + 1;
    std::vector<cad_point> out;

    if (hasNurbs) {
        struct Homogeneous { double x, y, w; };
        const auto evaluate = [&](double u, int span) {
            std::vector<Homogeneous> work(size_t(deg) + 1);
            for (int j = 0; j <= deg; ++j) {
                const int index = std::clamp(span - deg + j, 0, int(count) - 1);
                double w = size_t(index) < weights.size()
                               ? weights[size_t(index)] : 1.0;
                if (!std::isfinite(w) || std::abs(w) < 1e-12) w = 1.0;
                work[size_t(j)] = {cps[size_t(index)].x * w,
                                   cps[size_t(index)].y * w, w};
            }
            for (int r = 1; r <= deg; ++r) {
                for (int j = deg; j >= r; --j) {
                    const size_t lowerIndex = size_t(std::clamp(
                        span - deg + j, 0, int(knots.size()) - 1));
                    const size_t upperIndex = size_t(std::clamp(
                        span + 1 + j - r, 0, int(knots.size()) - 1));
                    const double lower = knots[lowerIndex];
                    const double denom = knots[upperIndex] - lower;
                    // Clamping guards against malformed/non-monotonic knot
                    // vectors: an out-of-range alpha would extrapolate wildly.
                    const double alpha = std::clamp(
                        std::abs(denom) > 1e-12 ? (u - lower) / denom : 0.0,
                        0.0, 1.0);
                    work[size_t(j)].x = (1 - alpha) * work[size_t(j) - 1].x
                                        + alpha * work[size_t(j)].x;
                    work[size_t(j)].y = (1 - alpha) * work[size_t(j) - 1].y
                                        + alpha * work[size_t(j)].y;
                    work[size_t(j)].w = (1 - alpha) * work[size_t(j) - 1].w
                                        + alpha * work[size_t(j)].w;
                }
            }
            const Homogeneous &p = work[size_t(deg)];
            const double w = std::abs(p.w) > 1e-12 ? p.w : 1.0;
            return cad_point{p.x / w, p.y / w};
        };
        // Sample each non-degenerate span. `count` here is the number of
        // control points; valid spans are [deg, count).
        for (int span = deg; span < int(count) && span + 1 < int(knots.size()); ++span) {
            const double start = knots[size_t(span)];
            const double end = knots[size_t(span + 1)];
            if (!std::isfinite(start) || !std::isfinite(end) || end <= start) continue;
            constexpr int samplesPerSpan = 12;
            const int first = out.empty() ? 0 : 1;  // avoid duplicating the join
            for (int sample = first; sample <= samplesPerSpan; ++sample) {
                double u = start + (end - start)
                           * (double(sample) / double(samplesPerSpan));
                if (sample == samplesPerSpan) u = std::nextafter(end, start);
                out.push_back(evaluate(u, span));
            }
        }
        if (out.size() < 2) out = cps;
    } else if (fitPoints && count > 2) {
        // Fit points are interpolation samples, so a Catmull-Rom pass through
        // them is much closer to the authored curve than a control polygon.
        constexpr int samplesPerSpan = 10;
        for (size_t i = 0; i + 1 < count; ++i) {
            const cad_point &p0 = cps[std::max<size_t>(1, i) - 1];
            const cad_point &p1 = cps[i];
            const cad_point &p2 = cps[i + 1];
            const cad_point &p3 = cps[std::min(count - 1, i + 2)];
            const int first = out.empty() ? 0 : 1;
            for (int sample = first; sample <= samplesPerSpan; ++sample) {
                const double t = double(sample) / double(samplesPerSpan);
                const double t2 = t * t, t3 = t2 * t;
                out.push_back({
                    0.5 * (2 * p1.x + (-p0.x + p2.x) * t
                           + (2 * p0.x - 5 * p1.x + 4 * p2.x - p3.x) * t2
                           + (-p0.x + 3 * p1.x - 3 * p2.x + p3.x) * t3),
                    0.5 * (2 * p1.y + (-p0.y + p2.y) * t
                           + (2 * p0.y - 5 * p1.y + 4 * p2.y - p3.y) * t2
                           + (-p0.y + 3 * p1.y - 3 * p2.y + p3.y) * t3)});
            }
        }
    } else {
        // No knot vector and no fit points: the control polygon is all we have.
        out = cps;
    }
    // Closed curves carry CAD_FLAG_CLOSED; the renderer closes the path. Do
    // not duplicate the first point here (a duplicate also breaks decimation).
    return out;
}

void convertEntity(Builder &b, Dwg_Object *obj, int space, const Affine &xf,
                   int layer, uint32_t rgb, uint8_t aci, float lw, int depth);

// DXF horizontal justification is 0 left, 1 centre, 2 right, 3 aligned,
// 4 middle, 5 fit. The renderer only knows the first three, and the stretch
// modes anchor on the left point, so fold them together instead of exporting
// values it would silently treat as "left".
int textHAlign(int horizAlignment) {
    switch (horizAlignment) {
    case 1: return 1;
    case 2: return 2;
    case 4: return 1;   // middle → centre horizontally
    default: return 0;
    }
}

// DXF vertical justification is 0 baseline, 1 bottom, 2 middle, 3 top, which is
// also the order the renderer expects.
int textVAlign(int vertAlignment) {
    if (vertAlignment < 0 || vertAlignment > 3) return 0;
    return vertAlignment;
}

// Anonymous dimension blocks are named `*D1`, `*D2`, … by every producer that
// writes them (AutoCAD, 中望, 浩辰, BricsCAD). The name is the only marker that
// survives into the flattened entity list, so it is what tells object snap to
// ignore the geometry the dimension drew for itself.
bool isDimensionBlockName(const char *name) {
    if (!name || name[0] != '*' || !name[1]) return false;
    const char c = name[1];
    return c == 'D' || c == 'd';
}

void expandBlock(Builder &b, Dwg_Object *blockHeader, int space,
                 const Affine &xf, int layer, uint32_t rgb, uint8_t aci,
                 float lw, int depth) {
    if (!blockHeader || depth > kMaxDepth) return;
    if (!blockHeader->tio.object) return;
    Dwg_Object_BLOCK_HEADER *bh = blockHeader->tio.object->tio.BLOCK_HEADER;
    if (!bh) return;
    if (b.doc->entities.size() > kMaxEntities) return;
    const uint64_t key = blockHeader->handle.value;
    if (b.expandedBlocks.count(key) && depth > 0) {
        // A block may legitimately be re-used many times, so only guard
        // against cycles along the current path.
    }
    b.expandedBlocks.insert(key);
    // Reference: LibreDwgReader.cpp::commonEntity() keeps a stack of the
    // INSERT layers above each entity. Depth 0 is the model/layout block
    // header, not an INSERT, so it contributes no layer.
    const bool pushed = depth > 0 && layer >= 0;
    if (pushed) b.blockLayerStack.push_back(int32_t(layer));
    struct StackGuard {
        Builder &builder;
        bool active;
        ~StackGuard() { if (active) builder.blockLayerStack.pop_back(); }
    } stackGuard{b, pushed};

    auto visit = [&](Dwg_Object_Ref *ref) {
        Dwg_Object *child = ref ? dwg_ref_object(b.dwg, ref) : nullptr;
        if (!child || !child->tio.entity) return;
        convertEntity(b, child, space, xf, layer, rgb, aci, lw, depth + 1);
    };

    // A block's geometry reaches us through two parallel structures: the
    // first_entity/next_entity owner chain and the entities[] array. Neither is
    // complete for every producer — anonymous dimension blocks in particular
    // can list only part of their contents in entities[] — so walk BOTH and
    // de-duplicate by handle. Walking only one of them is why dimension lines
    // and block detail were silently missing.
    std::unordered_set<uint64_t> seen;
    if (bh->first_entity) {
        Dwg_Object_Ref *ref = bh->first_entity;
        int guard = 0;
        while (ref && guard++ < 200000) {
            Dwg_Object *child = dwg_ref_object(b.dwg, ref);
            if (!child || !child->tio.entity) break;
            if (seen.insert(child->handle.value).second) {
                b.blockChainVisits += 1;
                visit(ref);
            }
            ref = child->tio.entity->next_entity;
        }
    }
    if (bh->num_owned > 0 && bh->entities) {
        for (BITCODE_BL i = 0; i < bh->num_owned; ++i) {
            Dwg_Object *child = bh->entities[i]
                ? dwg_ref_object(b.dwg, bh->entities[i]) : nullptr;
            if (!child || !child->tio.entity) continue;
            if (!seen.insert(child->handle.value).second) continue;
            b.blockArrayVisits += 1;
            visit(bh->entities[i]);
        }
    }
    b.expandedBlocks.erase(key);
}

void convertHatch(Builder &b, Dwg_Object *obj, int space, const Affine &xfParent,
                  int layer, uint32_t rgb, uint8_t aci, float lw) {
    Dwg_Entity_HATCH *h = obj->tio.entity->tio.HATCH;
    if (!h) return;
    // HATCH boundary paths and pattern definitions are stored in the OCS of
    // the hatch plane, not in WCS: a hatch drawn on a −Z normal is otherwise
    // mirrored away from the geometry it fills.
    const Ocs hatchOcs = ocsFor(h->extrusion, h->elevation);
    const Affine xf = hatchOcs.identity ? xfParent
                                        : compose(hatchOcs.affine(), xfParent);
    cad_hatch out{};
    out.ringstart = int(b.doc->rings.size());
    out.ringcount = 0;
    out.solid = h->is_solid_fill ? 1 : 0;
    out.style = h->style;
    out.angle = h->angle + (hatchOcs.mirrored ? 0.0 : hatchOcs.angle);
    out.scale = h->scale_spacing > 0 ? h->scale_spacing : 1.0;
    out.defcount = 0;
    if (!out.solid && h->num_deflines > 0 && h->deflines) {
        int count = std::min<int>(h->num_deflines, 8);
        int dashPool = 0;
        for (int d = 0; d < count; ++d) {
            const Dwg_HATCH_DefLine &def = h->deflines[d];
            // A pattern family is defined in the hatch's own plane: pt0 is an
            // OCS point, angle/offset are OCS vectors. All three have to travel
            // through the plane *and* the enclosing block affine. Leaving them
            // in definition space (the previous code) kept the spacing and
            // angle of the pattern definition, so every hatch inside a scaled
            // or rotated INSERT rendered at the wrong density and direction.
            const cad_point origin = xf.map(def.pt0.x, def.pt0.y);
            const double ca = std::cos(def.angle), sa = std::sin(def.angle);
            const double dirX = xf.m11 * ca + xf.m21 * sa;
            const double dirY = xf.m12 * ca + xf.m22 * sa;
            const double offX = xf.m11 * def.offset.x + xf.m21 * def.offset.y;
            const double offY = xf.m12 * def.offset.x + xf.m22 * def.offset.y;
            out.def_angle[d] = std::atan2(dirY, dirX);
            out.def_x[d] = origin.x;
            out.def_y[d] = origin.y;
            out.def_dx[d] = offX;
            out.def_dy[d] = offY;
            // Dash lengths run along the (already transformed) direction, so
            // they scale with its length. Without this a block scaled by 1000
            // produced dashes 1000x too short and the fill read as solid.
            const double dirLength = std::hypot(dirX, dirY);
            out.def_ndashes[d] = 0;
            out.def_dash_start[d] = dashPool;
            if (def.num_dashes > 0 && def.dashes) {
                const int nd = std::min<int>(def.num_dashes, 16);
                for (int k = 0; k < nd && dashPool < 128; ++k) {
                    out.dashes[dashPool++] = def.dashes[k] * dirLength;
                }
                out.def_ndashes[d] = nd;
            }
        }
        out.defcount = count;
    }
    if (out.defcount == 0 && !out.solid) {
        out.defcount = 1;
        const double ca = std::cos(kPi / 4.0), sa = std::sin(kPi / 4.0);
        out.def_angle[0] = std::atan2(xf.m12 * ca + xf.m22 * sa,
                                      xf.m11 * ca + xf.m21 * sa);
        out.def_x[0] = xf.dx;
        out.def_y[0] = xf.dy;
        out.def_dx[0] = xf.m11 * 3.0;
        out.def_dy[0] = xf.m12 * 3.0;
        out.def_ndashes[0] = 0;
        out.def_dash_start[0] = 0;
    }

    for (BITCODE_BL p = 0; p < h->num_paths && h->paths; ++p) {
        Dwg_HATCH_Path &path = h->paths[p];
        const bool openPath = (path.flag & 0x20) != 0;
        const bool closedPath = !openPath && (path.flag & 2 ? path.closed != 0 : true);
        // Chains are built in OCS coordinates and mapped point by point. Mapping
        // an already-projected arc centre + angles (the previous code) silently
        // ignores the extrusion, so any hatch on a non-WCS plane was rotated
        // wrong and its boundary no longer matched the wall outlines.
        std::vector<std::vector<cad_point>> chains;
        // Endpoints of adjacent boundary segments agree to within a few
        // microns; 1e-3 is far below any real gap yet comfortably above the
        // rounding drift in a 1e5-unit drawing.
        constexpr double joinTolerance = 1e-3;

        if (path.flag & 2) {  // polyline path: vertices carry a bulge
            std::vector<Dwg_HATCH_PolylinePath> verts;
            verts.reserve(size_t(path.num_segs_or_paths));
            for (int i = 0; i < path.num_segs_or_paths; ++i) {
                verts.push_back(path.polyline_paths[i]);
            }
            if (!verts.empty()) {
                std::vector<cad_point> pts;
                pts.push_back({verts.front().point.x, verts.front().point.y});
                for (size_t i = 1; i < verts.size(); ++i) {
                    cad_point a{verts[i - 1].point.x, verts[i - 1].point.y};
                    cad_point c{verts[i].point.x, verts[i].point.y};
                    sampleBulge(pts, a, c, verts[i - 1].bulge);
                }
                // The closing edge is described by the LAST vertex's bulge. It
                // was skipped before, so every rounded hatch border fell back
                // to a straight closeSubpath and the fill was clipped by a
                // chamfer instead of the arc — the "fill does not follow the
                // arcs" defect.
                if (closedPath && std::abs(verts.back().bulge) > 1.0e-10) {
                    cad_point a{verts.back().point.x, verts.back().point.y};
                    sampleBulge(pts, a, pts.front(), verts.back().bulge);
                }
                if (pts.size() >= 2) chains.push_back(std::move(pts));
            }
        } else {
            for (int i = 0; i < path.num_segs_or_paths && path.segs; ++i) {
                Dwg_HATCH_PathSeg &seg = path.segs[i];
                std::vector<cad_point> piece;
                if (seg.curve_type == 1) {
                    piece.push_back({seg.first_endpoint.x, seg.first_endpoint.y});
                    piece.push_back({seg.second_endpoint.x, seg.second_endpoint.y});
                } else if (seg.curve_type == 2 && seg.radius > 0.0) {
                    // AutoCAD stores the start/end angles of CLOCKWISE hatch
                    // boundary arcs measured in the clockwise direction.
                    // Negating them for is_ccw == 0 is what makes the sampled
                    // endpoints meet the neighbouring straight edges; without
                    // it a single boundary shatters into dozens of disconnected
                    // chains and the fill degrades into blobs (same fix and
                    // reasoning as LibreDwgReader::visitHatch).
                    const bool arcCcw = seg.is_ccw != 0;
                    const double a0 = arcCcw ? seg.start_angle : -seg.start_angle;
                    const double a1 = arcCcw ? seg.end_angle : -seg.end_angle;
                    double sweep = a1 - a0;
                    if (arcCcw) {
                        while (sweep <= 0.0) sweep += kTwoPi;
                    } else {
                        while (sweep >= 0.0) sweep -= kTwoPi;
                    }
                    const int steps = std::clamp(
                        int(std::ceil(std::abs(sweep) / kTwoPi * 36.0)), 2, 100);
                    piece.reserve(size_t(steps) + 1);
                    for (int k = 0; k <= steps; ++k) {
                        const double angle = a0 + sweep * double(k) / double(steps);
                        piece.push_back({seg.center.x + std::cos(angle) * seg.radius,
                                         seg.center.y + std::sin(angle) * seg.radius});
                    }
                } else if (seg.curve_type == 3) {
                    // Elliptic arc boundary, sampled parametrically in OCS.
                    const double ratio = seg.minor_major_ratio;
                    const double major = std::hypot(seg.endpoint.x, seg.endpoint.y);
                    const double rotation = std::atan2(seg.endpoint.y, seg.endpoint.x);
                    const bool arcCcw = seg.is_ccw != 0;
                    double a0 = arcCcw ? seg.start_angle : -seg.start_angle;
                    double a1 = arcCcw ? seg.end_angle : -seg.end_angle;
                    double sweep = a1 - a0;
                    if (arcCcw) {
                        while (sweep <= 0.0) sweep += kTwoPi;
                    } else {
                        while (sweep >= 0.0) sweep -= kTwoPi;
                    }
                    const int steps = std::clamp(
                        int(std::ceil(std::abs(sweep) / kTwoPi * 64.0)), 2, 128);
                    const double cs = std::cos(rotation), sn = std::sin(rotation);
                    piece.reserve(size_t(steps) + 1);
                    for (int k = 0; k <= steps; ++k) {
                        const double t = a0 + sweep * double(k) / double(steps);
                        const double ex = std::cos(t) * major;
                        const double ey = std::sin(t) * major * ratio;
                        piece.push_back({seg.center.x + ex * cs - ey * sn,
                                         seg.center.y + ex * sn + ey * cs});
                    }
                } else if (seg.curve_type == 4) {
                    // Spline boundary. The reference prefers fit points and
                    // only falls back to control points; using fit points
                    // alone dropped every spline boundary that stores no fit
                    // data, which left holes in the hatch outline.
                    if (seg.fitpts && seg.num_fitpts > 1) {
                        piece.reserve(size_t(seg.num_fitpts));
                        for (BITCODE_BL k = 0; k < seg.num_fitpts; ++k) {
                            piece.push_back({seg.fitpts[k].x, seg.fitpts[k].y});
                        }
                    } else if (seg.control_points && seg.num_control_points > 1) {
                        piece.reserve(size_t(seg.num_control_points));
                        for (BITCODE_BL k = 0; k < seg.num_control_points; ++k) {
                            piece.push_back({seg.control_points[k].point.x,
                                             seg.control_points[k].point.y});
                        }
                    }
                }
                if (!piece.empty()) {
                    appendConnectedPiece(chains, std::move(piece), joinTolerance);
                }
            }
        }

        // DXF group 92 path flag 0x20 marks an OPEN boundary. The reference
        // (LibreDwgReader::visitHatch) keeps open paths out of the fill group
        // entirely: closing one turns an unclosed outline into an extra filled
        // blob. Only closed loops — which include island loops — join the ring
        // list, and odd-even fill then cuts the islands out.
        if (openPath) continue;

        for (std::vector<cad_point> &chain : chains) {
            if (chain.size() < 2) continue;
            std::vector<int> pts;
            pts.reserve(chain.size());
            for (const cad_point &q : chain) {
                const cad_point m = xf.map(q.x, q.y);
                pts.push_back(b.addPoint(m.x, m.y));
            }
            cad_ring ring{};
            ring.pstart = pts.front();
            ring.pcount = int(pts.size());
            ring.closed = 1;
            b.doc->rings.push_back(ring);
            out.ringcount += 1;
        }
    }
    if (out.ringcount == 0) return;
    b.doc->hatches.push_back(out);
    cad_entity e{};
    addEntityCommon(b, obj, space, layer, rgb, aci, lw, CAD_FLAG_FILLED, &e);
    e.kind = CAD_HATCH;
    e.pcount = 0;
    e.hatch = int(b.doc->hatches.size()) - 1;
    e.cx = xf.map(0, 0).x;
    e.cy = xf.map(0, 0).y;
    pushEntity(b, e);
}

// ---------------------------------------------------------------- XCLIP
//
// Reference: LibreDwgReader::indexSpatialFilters / applyClipToRange. The clip
// boundary is stored in the clipped entity's block space; `inverse_transform`
// maps world → that space, so a mirrored insert keeps its clip in the right
// place. The reference then clips against the boundary's bounding box, which is
// what AutoCAD's rectangular clip produces anyway.

void indexSpatialFilters(Builder &b) {
    Dwg_Data *dwg = b.dwg;
    if (!dwg) return;
    for (BITCODE_BL i = 0; i < dwg->num_objects; ++i) {
        Dwg_Object *obj = &dwg->object[i];
        if (obj->fixedtype != DWG_TYPE_SPATIAL_FILTER || !obj->tio.object) continue;
        Dwg_Object_SPATIAL_FILTER *filter = obj->tio.object->tio.SPATIAL_FILTER;
        if (!filter || filter->num_clip_verts < 2 || !filter->clip_verts) continue;
        Dwg_Object *owner = nullptr;
        if (obj->tio.object->ownerhandle) {
            owner = dwg_ref_object(dwg, obj->tio.object->ownerhandle);
        }
        int guard = 0;
        while (owner && owner->fixedtype == DWG_TYPE_DICTIONARY && guard++ < 8) {
            owner = owner->tio.object && owner->tio.object->ownerhandle
                ? dwg_ref_object(dwg, owner->tio.object->ownerhandle) : nullptr;
        }
        if (!owner || owner->supertype != DWG_SUPERTYPE_ENTITY) continue;
        std::vector<cad_point> polygon;
        polygon.reserve(size_t(filter->num_clip_verts));
        for (BITCODE_BL k = 0; k < filter->num_clip_verts; ++k) {
            const BITCODE_2RD &vertex = filter->clip_verts[k];
            double x = vertex.x, y = vertex.y;
            if (filter->inverse_transform) {
                const double *t = filter->inverse_transform;
                x = t[0] * vertex.x + t[1] * vertex.y + t[3];
                y = t[4] * vertex.x + t[5] * vertex.y + t[7];
            }
            polygon.push_back({x, y});
        }
        if (polygon.size() == 2) {
            // Two opposite corners mean a rectangle.
            const cad_point a = polygon.front();
            const cad_point c = polygon.back();
            polygon = {a, {c.x, a.y}, c, {a.x, c.y}};
        }
        if (polygon.size() < 3) continue;
        b.clipsByHandle[owner->handle.value] = std::move(polygon);
        b.clipsIndexed += 1;
    }
}

// Liang–Barsky clip of one segment against an axis-aligned box.
bool clipSegmentToBox(cad_point &a, cad_point &b,
                      double minx, double miny, double maxx, double maxy) {
    double t0 = 0.0, t1 = 1.0;
    const double dx = b.x - a.x, dy = b.y - a.y;
    const double p[4] = {-dx, dx, -dy, dy};
    const double q[4] = {a.x - minx, maxx - a.x, a.y - miny, maxy - a.y};
    for (int k = 0; k < 4; ++k) {
        if (std::abs(p[k]) < 1e-12) {
            if (q[k] < 0) return false;
            continue;
        }
        const double r = q[k] / p[k];
        if (p[k] < 0) {
            if (r > t1) return false;
            if (r > t0) t0 = r;
        } else {
            if (r < t0) return false;
            if (r < t1) t1 = r;
        }
    }
    const double x0 = a.x + t0 * dx, y0 = a.y + t0 * dy;
    const double x1 = a.x + t1 * dx, y1 = a.y + t1 * dy;
    a = {x0, y0};
    b = {x1, y1};
    return true;
}

// Drops or trims the geometry an INSERT added after `begin` so only what lies
// inside the clip window survives.
void applyClipRange(Builder &b, size_t begin,
                    const std::vector<cad_point> &polygon, const Affine &xf) {
    if (polygon.size() < 3) return;
    double minx = 1e300, miny = 1e300, maxx = -1e300, maxy = -1e300;
    for (const cad_point &p : polygon) {
        const cad_point w = xf.map(p.x, p.y);
        minx = std::min(minx, w.x);
        miny = std::min(miny, w.y);
        maxx = std::max(maxx, w.x);
        maxy = std::max(maxy, w.y);
    }
    if (!(maxx > minx)) return;
    std::vector<cad_entity> kept;
    kept.reserve(b.doc->entities.size() - begin);
    for (size_t i = begin; i < b.doc->entities.size(); ++i) {
        cad_entity e = b.doc->entities[i];
        const bool outside = e.box.maxx < minx || e.box.minx > maxx
            || e.box.maxy < miny || e.box.miny > maxy;
        if (outside) {
            b.clipDropped += 1;
            continue;
        }
        const bool inside = e.box.minx >= minx && e.box.maxx <= maxx
            && e.box.miny >= miny && e.box.maxy <= maxy;
        if (inside || e.pcount < 2
            || (e.kind != CAD_LINE && e.kind != CAD_POLYLINE)) {
            kept.push_back(e);
            continue;
        }
        // Straddles the window: trim the run, keeping each surviving piece.
        std::vector<cad_point> run;
        run.reserve(size_t(e.pcount) + 2);
        for (int k = 0; k + 1 < e.pcount; ++k) {
            cad_point p = b.doc->points[size_t(e.pstart) + size_t(k)];
            cad_point q = b.doc->points[size_t(e.pstart) + size_t(k) + 1];
            if (!clipSegmentToBox(p, q, minx, miny, maxx, maxy)) continue;
            if (run.empty()
                || std::hypot(run.back().x - p.x, run.back().y - p.y) > 1e-9) {
                run.push_back(p);
            }
            run.push_back(q);
        }
        if (run.size() < 2) {
            b.clipDropped += 1;
            continue;
        }
        cad_entity trimmed = e;
        trimmed.pstart = int(b.doc->points.size());
        trimmed.pcount = int(run.size());
        trimmed.box = {1e300, 1e300, -1e300, -1e300};
        for (const cad_point &p : run) {
            b.doc->points.push_back(p);
            trimmed.box.minx = std::min(trimmed.box.minx, p.x);
            trimmed.box.miny = std::min(trimmed.box.miny, p.y);
            trimmed.box.maxx = std::max(trimmed.box.maxx, p.x);
            trimmed.box.maxy = std::max(trimmed.box.maxy, p.y);
        }
        kept.push_back(trimmed);
    }
    b.doc->entities.resize(begin);
    b.doc->entities.insert(b.doc->entities.end(), kept.begin(), kept.end());
}

void convertEntity(Builder &b, Dwg_Object *obj, int space, const Affine &xf,
                   int parentLayer, uint32_t parentRgb, uint8_t parentAci,
                   float parentLw, int depth) {
    Dwg_Object_Entity *ent = obj->tio.entity;
    if (!ent) return;
    if (b.doc->entities.size() > kMaxEntities) { b.dropBudget += 1; return; }
    if (!b.typeCount.empty() || getenv("CADCORE_TYPES")) {
        b.typeCount[obj->fixedtype] += 1;
    }

    // DXF group 60 / the DWG entity flag is a short: only bit 0 means
    // invisible. ATTMODE then overrides that decision for ATTRIB entities.
    // The reference reader drops hidden entities before expanding anything,
    // so a hidden INSERT never leaks its block contents either.
    const bool isAttribute = obj->fixedtype == DWG_TYPE_ATTRIB;
    bool visible = (ent->invisible & 1) == 0;
    if (isAttribute) {
        if (b.attributeMode == 0) {
            visible = false;
        } else if (b.attributeMode == 2) {
            visible = true;
        }
    }
    if (isAttribute) {
        if (visible) ++b.attrRendered;
        else ++b.attrSuppressed;
    }
    if (!visible) { b.dropInvisible += 1; return; }

    int layer = b.layerIndexFor(ent->layer);
    // DXF reference rule: geometry drawn on layer "0" inside a block adopts the
    // layer of the INSERT that placed it. Without this every block detail kept
    // layer 0's colour and line weight instead of inheriting the wall/furniture
    // layer it actually belongs to (reference: commonEntity + insertLayer).
    if (layer >= 0 && parentLayer >= 0 && depth > 0
        && layerName(b.doc, layer) == "0") {
        layer = parentLayer;
    } else if (layer < 0) {
        layer = parentLayer;
    }

    uint32_t rgb = parentRgb;
    uint8_t aci = parentAci;
    const int colorIndex = ent->color.index;
    const int colorMethod = int((ent->color.rgb >> 24) & 0xFF);
    const uint32_t colorPayload = ent->color.rgb & 0xFFFFFF;
    if (colorMethod == DWG_COLOR_METHOD_TRUECOLOR && colorPayload > 0xFF) {
        // A real 24-bit colour. The low byte of CMC payloads carries the ACI
        // index instead (R2004+ writes 0xC3 for both), so only values above
        // 0xFF are genuine RGB — otherwise a red 0x00FF0000 stays, but an
        // index of 5 is not mistaken for RGB(0, 0, 5).
        rgb = colorPayload;
        aci = 255;
    } else if (colorIndex == 256) {
        // BYLAYER: the layer's own colour, which is now resolved through the
        // same cmcColor() rule it was built with.
        if (layer >= 0) {
            const uint32_t packed = b.doc->layers[size_t(layer)].rgb;
            aci = uint8_t((packed >> 24) & 0xFF);
            rgb = packed & 0xFFFFFF;
        }
    } else if (colorIndex != 0) {
        // An explicit colour on the entity itself. This used to consult
        // `index` alone, so an entity written as method 0xC3 with the ACI in
        // the payload fell through to white.
        const CmcColor resolved = cmcColor(ent->color);
        rgb = resolved.rgb;
        aci = resolved.aci;
    }
    // colorIndex == 0 is BYBLOCK: keep whatever the enclosing insert resolved.

    float lw = parentLw;
    if (ent->linewt > 0 && ent->linewt < 24) lw = lineweightMm(ent->linewt);

    const int flags = (ent->invisible & 1) ? CAD_FLAG_INVISIBLE : 0;
    const double sx = xf.meanScale();

    switch (obj->fixedtype) {
    case DWG_TYPE_LINE: {
        Dwg_Entity_LINE *line = ent->tio.LINE;
        if (!line) break;
        cad_entity e{};
        addEntityCommon(b, obj, space, layer, rgb, aci, lw, flags, &e);
        e.kind = CAD_LINE;
        e.pstart = int(b.doc->points.size());
        cad_point a = xf.map(line->start.x, line->start.y);
        cad_point c = xf.map(line->end.x, line->end.y);
        b.addPoint(a.x, a.y);
        b.addPoint(c.x, c.y);
        e.pcount = 2;
        pushEntity(b, e);
        break;
    }
    case DWG_TYPE_LWPOLYLINE: {
        Dwg_Entity_LWPOLYLINE *pl = ent->tio.LWPOLYLINE;
        if (!pl || pl->num_points == 0) break;
        // Sample bulges in the entity's OCS plane and project the finished
        // samples once, exactly like the reference reader. Sampling in WCS
        // mirrors the arc normal on -Z extrusion planes and leaves the arc
        // bulging to the wrong side.
        const bool closed = (pl->flag & 512) != 0;
        const Ocs ocs = ocsFor(pl->extrusion, pl->elevation);
        const Affine eff = ocs.identity ? xf : compose(ocs.affine(), xf);
        std::vector<int> pts;
        pts.reserve(size_t(pl->num_points) * 4);
        auto emit = [&](const cad_point &p) {
            const cad_point w = eff.map(p.x, p.y);
            pts.push_back(b.addPoint(w.x, w.y));
        };
        cad_point previous{pl->points[0].x, pl->points[0].y};
        emit(previous);
        for (BITCODE_BL i = 1; i < pl->num_points; ++i) {
            const cad_point current{pl->points[i].x, pl->points[i].y};
            const double bulge =
                (i - 1 < pl->num_bulges && pl->bulges)
                    ? double(pl->bulges[size_t(i) - 1]) : 0.0;
            std::vector<cad_point> local;
            sampleBulge(local, previous, current, bulge);
            for (const cad_point &p : local) emit(p);
            previous = current;
        }
        if (closed && pl->bulges && pl->num_bulges >= pl->num_points) {
            const double closing = double(pl->bulges[size_t(pl->num_points) - 1]);
            if (std::abs(closing) > 1.0e-10) {
                const cad_point first{pl->points[0].x, pl->points[0].y};
                std::vector<cad_point> local;
                sampleBulge(local, previous, first, closing);
                for (const cad_point &p : local) emit(p);
            }
        }
        cad_entity e{};
        addEntityCommon(b, obj, space, layer, rgb, aci, lw,
                        flags | (closed ? CAD_FLAG_CLOSED : 0), &e);
        e.kind = CAD_POLYLINE;
        e.pstart = pts.front();
        e.pcount = int(pts.size());
        pushEntity(b, e);
        break;
    }
    case DWG_TYPE_POLYLINE_2D:
    case DWG_TYPE_POLYLINE_3D: {
        Dwg_Entity_POLYLINE_2D *pl = ent->tio.POLYLINE_2D;
        if (!pl) break;
        // Legacy polylines carry the elevation and normal on the header, the
        // vertices only 2D points. POLYLINE_3D stores real WCS vertices, but
        // its elevation/extrusion are zeroed out, which makes the OCS
        // identity and keeps one code path for both.
        const bool is3D = obj->fixedtype == DWG_TYPE_POLYLINE_3D;
        const Ocs ocs = is3D ? Ocs() : ocsFor(pl->extrusion, pl->elevation);
        const Affine eff = ocs.identity ? xf : compose(ocs.affine(), xf);
        std::vector<int> pts;
        cad_point previous{};
        bool havePrevious = false;
        auto emit = [&](const cad_point &p) {
            const cad_point w = eff.map(p.x, p.y);
            pts.push_back(b.addPoint(w.x, w.y));
        };
        auto visitVertex = [&](Dwg_Object *vobj) -> bool {
            if (!vobj || !vobj->tio.entity) return true;
            if (vobj->fixedtype != DWG_TYPE_VERTEX_2D
                && vobj->fixedtype != DWG_TYPE_VERTEX_3D) {
                return true;
            }
            Dwg_Entity_VERTEX_2D *v = vobj->tio.entity->tio.VERTEX_2D;
            if (!v) return true;
            const cad_point current{v->point.x, v->point.y};
            // VERTEX_3D is a shorter struct: reading `bulge` from it walks past
            // the end of the allocation, so only 2D vertices contribute arcs.
            const double bulge =
                vobj->fixedtype == DWG_TYPE_VERTEX_2D ? double(v->bulge) : 0.0;
            if (!havePrevious) {
                emit(current);
            } else {
                std::vector<cad_point> local;
                sampleBulge(local, previous, current, bulge);
                for (const cad_point &p : local) emit(p);
            }
            previous = current;
            havePrevious = true;
            return true;
        };
        if (pl->num_owned > 0 && pl->vertex) {
            for (BITCODE_BL i = 0; i < pl->num_owned; ++i) {
                visitVertex(dwg_ref_object(b.dwg, pl->vertex[i]));
            }
        } else {
            Dwg_Object_Ref *ref = pl->first_vertex;
            int guard = 0;
            while (ref && guard++ < 100000) {
                Dwg_Object *v = dwg_ref_object(b.dwg, ref);
                if (!v || !v->tio.entity) break;
                if (v->fixedtype != DWG_TYPE_VERTEX_2D
                    && v->fixedtype != DWG_TYPE_VERTEX_3D) {
                    break;
                }
                visitVertex(v);
                ref = v->tio.entity->next_entity;
            }
        }
        if (pts.size() < 2) break;
        const bool closed = (pl->flag & 1) != 0;
        cad_entity e{};
        addEntityCommon(b, obj, space, layer, rgb, aci, lw,
                        flags | (closed ? CAD_FLAG_CLOSED : 0), &e);
        e.kind = CAD_POLYLINE;
        e.pstart = pts.front();
        e.pcount = int(pts.size());
        pushEntity(b, e);
        break;
    }
    case DWG_TYPE_CIRCLE: {
        Dwg_Entity_CIRCLE *c = ent->tio.CIRCLE;
        if (!c) break;
        cad_entity e{};
        addEntityCommon(b, obj, space, layer, rgb, aci, lw, flags, &e);
        e.kind = CAD_CIRCLE;
        // Circle centre is an OCS point; the extrusion only decides which plane
        // it lives in, so a mirrored plane still yields a plain circle.
        const Ocs ocs = ocsFor(c->extrusion, 0.0);
        cad_point local = ocs.map(c->center.x, c->center.y);
        cad_point p = xf.map(local.x, local.y);
        e.cx = p.x;
        e.cy = p.y;
        e.r = c->radius * sx;
        // Reference: sampleArc() in OCS coordinates, then ocsPoint() and the
        // full block affine for every sample. The analytic radius above is
        // only kept for snapping; drawing uses this point list.
        const auto samples = sampleArcOcs(xf, ocs, c->center.x, c->center.y,
                                          double(c->radius), 0.0, kTwoPi, true);
        setCurvePoints(b, e, samples);
        e.flags |= CAD_FLAG_CLOSED;
        pushEntity(b, e);
        break;
    }
    case DWG_TYPE_ARC: {
        Dwg_Entity_ARC *c = ent->tio.ARC;
        if (!c) break;
        cad_entity e{};
        addEntityCommon(b, obj, space, layer, rgb, aci, lw, flags, &e);
        e.kind = CAD_ARC;
        const Ocs ocs = ocsFor(c->extrusion, 0.0);
        const cad_point centreWcs = ocs.map(c->center.x, c->center.y);
        cad_point p = xf.map(centreWcs.x, centreWcs.y);
        e.cx = p.x;
        e.cy = p.y;
        const double radius = double(c->radius);
        e.r = radius * sx;
        // The reference reader samples the arc in the OCS and projects every
        // sample with ocsPoint(); it never rotates the angles by a scalar. On
        // a mirrored plane that reflects the angles about the mirror axis and
        // reverses the sweep, so derive the WCS angles from the projected end
        // points and swap them when the plane flips handedness.
        const double sa = double(c->start_angle), ea = double(c->end_angle);
        const cad_point sOcs = ocs.map(c->center.x + radius * std::cos(sa),
                                       c->center.y + radius * std::sin(sa));
        const cad_point eOcs = ocs.map(c->center.x + radius * std::cos(ea),
                                       c->center.y + radius * std::sin(ea));
        // The insert transform may mirror the block. A scalar rotation cannot
        // express that: mirror maps an angle to 2β−a and reverses the sweep.
        // Project both ends through the *full* affine chain, exactly like the
        // reference's append() which maps every sampled point.
        const cad_point sFinal = xf.map(sOcs.x, sOcs.y);
        const cad_point eFinal = xf.map(eOcs.x, eOcs.y);
        double w0 = std::atan2(sFinal.y - p.y, sFinal.x - p.x);
        double w1 = std::atan2(eFinal.y - p.y, eFinal.x - p.x);
        const double detOcs = ocs.plane.m11 * ocs.plane.m22
                              - ocs.plane.m21 * ocs.plane.m12;
        const double detXf = xf.m11 * xf.m22 - xf.m21 * xf.m12;
        if (detOcs * detXf < 0.0) std::swap(w0, w1);
        e.a0 = w0;
        e.a1 = w1;
        // Same flattened geometry the reference stores in `points`. Keeping
        // the sampling in OCS space (not WCS angles) is what fixes arcs under
        // a mirrored INSERT: the whole affine, including reflection, is
        // applied to every vertex.
        double sweep = ea - sa;
        while (sweep <= 0.0) sweep += kTwoPi;
        const auto samples = sampleArcOcs(xf, ocs, c->center.x, c->center.y,
                                          radius, sa, sweep, false);
        setCurvePoints(b, e, samples);
        pushEntity(b, e);
        break;
    }
    case DWG_TYPE_ELLIPSE: {
        Dwg_Entity_ELLIPSE *el = ent->tio.ELLIPSE;
        if (!el) break;
        // The reference reader samples the parametric ellipse into WCS points
        // and pushes each sample through the insert affine. A parameterised
        // major/ratio/angle form cannot express a mirrored insert, so sample
        // the same way: minor = (normal × major) * ratio, π/48 steps.
        const double ratio = el->axis_ratio > 0 ? el->axis_ratio : 1.0;
        const double minorX = -el->extrusion.z * el->sm_axis.y * ratio;
        const double minorY = el->extrusion.z * el->sm_axis.x * ratio;
        double start = double(el->start_angle);
        double sweep = double(el->end_angle) - start;
        const bool full = std::isfinite(sweep)
                          && std::abs(sweep) >= kTwoPi - 1.0e-9;
        if (full) {
            start = 0.0;
            sweep = kTwoPi;
        } else {
            while (sweep <= 0.0) sweep += kTwoPi;
        }
        // The normal's sign is already folded into the minor axis above, so
        // the ellipse is sampled in its own 2D plane (identity OCS) and every
        // vertex goes through the full insert affine. Reference: ELLIPSE case
        // in LibreDwgReader.cpp, π/48 steps, min 16 / max 384 samples.
        const Ocs plane;
        const auto samples = sampleEllipseOcs(
            xf, plane, el->center.x, el->center.y,
            el->sm_axis.x, el->sm_axis.y, minorX, minorY,
            start, sweep, full);
        cad_entity e{};
        addEntityCommon(b, obj, space, layer, rgb, aci, lw, flags, &e);
        e.kind = CAD_ELLIPSE;
        setCurvePoints(b, e, samples);
        if (e.pcount < 2) break;
        const cad_point centre = xf.map(el->center.x, el->center.y);
        e.cx = centre.x;
        e.cy = centre.y;
        e.major_x = xf.m11 * el->sm_axis.x + xf.m21 * el->sm_axis.y;
        e.major_y = xf.m12 * el->sm_axis.x + xf.m22 * el->sm_axis.y;
        e.ratio = ratio;
        e.a0 = start;
        e.a1 = start + sweep;
        if (full) e.flags |= CAD_FLAG_CLOSED;
        pushEntity(b, e);
        break;
    }
    case DWG_TYPE_TEXT: {
        Dwg_Entity_TEXT *t = ent->tio.TEXT;
        if (!t) break;
        std::string value = cleanText(entityText(b.dwg, t, "TEXT", "text_value"));
        if (value.empty()) value = cleanText(toUtf8(b.dwg, t->text_value));
        if (value.empty()) break;
        cad_entity e{};
        addEntityCommon(b, obj, space, layer, rgb, aci, lw, flags, &e);
        e.kind = CAD_TEXT;
        const Ocs ocs = ocsFor(t->extrusion, t->elevation);
        // DXF 72/73: any justification other than "left/baseline" moves the
        // meaning of the insertion point to the alignment point. Middle (4) and
        // every non-baseline vertical mode anchor on alignment_pt even when the
        // horizontal mode is 0, which the naive "72 or 73" test misses.
        const bool useAlignmentPoint = t->horiz_alignment == 4
            || t->vert_alignment > 0;
        cad_point raw = useAlignmentPoint && (t->dataflags & 2)
                            ? cad_point{t->alignment_pt.x, t->alignment_pt.y}
                            : cad_point{t->ins_pt.x, t->ins_pt.y};
        cad_point local = ocs.map(raw.x, raw.y);
        cad_point p = xf.map(local.x, local.y);
        e.cx = p.x;
        e.cy = p.y;
        e.h = std::max(0.1, double(t->height)) * sx;
        e.rot = t->rotation + (ocs.mirrored ? 0.0 : ocs.angle) + xf.rotation();
        if (t->horiz_alignment == 3 || t->horiz_alignment == 5) {
            // Aligned/Fit text spans the two points; rotate along that span
            // instead of trusting the (usually zero) rotation field.
            const double dx = t->alignment_pt.x - t->ins_pt.x;
            const double dy = t->alignment_pt.y - t->ins_pt.y;
            if (std::hypot(dx, dy) > 1e-9) {
                e.rot = std::atan2(dy, dx)
                        + (ocs.mirrored ? 0.0 : ocs.angle) + xf.rotation();
            }
        }
        e.ws = std::clamp(double(t->width_factor), 0.05, 100.0);
        e.halign = textHAlign(t->horiz_alignment);
        // horiz=4 (middle) is centred in both directions; the vertical field
        // is normally 0, so textVAlign alone leaves the label sitting on its
        // baseline and the letters appear a few pixels low.
        e.valign = t->horiz_alignment == 4 ? 2 : textVAlign(t->vert_alignment);
        e.tstart = b.textStart(value);
        e.tlen = int(value.size());
        pushEntity(b, e);
        break;
    }
    case DWG_TYPE_MTEXT: {
        Dwg_Entity_MTEXT *t = ent->tio.MTEXT;
        if (!t) break;
        const std::string rawText = entityText(b.dwg, t, "MTEXT", "text");
        std::string value = cleanMText(rawText);
        if (value.empty()) value = cleanMText(toUtf8(b.dwg, t->text));
        if (getenv("CADCORE_TEXT_LOG")) {
            fprintf(stderr, "[mtext] raw=%s\n        clean=%s\n",
                    rawText.c_str(), value.c_str());
        }
        while (!value.empty() && (value.back() == '\n' || value.back() == ' ')) {
            value.pop_back();
        }
        if (value.empty()) break;
        cad_entity e{};
        addEntityCommon(b, obj, space, layer, rgb, aci, lw,
                        flags | CAD_FLAG_MTEXT, &e);
        e.kind = CAD_TEXT;
        // MTEXT insertion point and X-axis direction are WCS vectors: applying
        // the OCS a second time mirrors text across drawings that were exploded
        // from a −Z normal.
        cad_point p = xf.map(t->ins_pt.x, t->ins_pt.y);
        e.cx = p.x;
        e.cy = p.y;
        e.h = std::max(0.1, double(t->text_height)) * sx;
        double angle = std::atan2(t->x_axis_dir.y, t->x_axis_dir.x);
        if (std::abs(t->x_axis_dir.x) < 1e-12 && std::abs(t->x_axis_dir.y) < 1e-12) {
            angle = 0;
        }
        e.rot = angle + xf.rotation();
        e.ws = 1.0;
        // Attachment 1…9 runs top→bottom, while the renderer's valign counts
        // baseline/bottom/middle/top; passing the raw row through flipped every
        // MTEXT block upside down on its anchor.
        const int attachment = (t->attachment >= 1 && t->attachment <= 9)
                                   ? int(t->attachment) : 1;
        e.halign = (attachment - 1) % 3;
        const int row = (attachment - 1) / 3;
        e.valign = row == 0 ? 3 : (row == 1 ? 2 : 1);
        e.tstart = b.textStart(value);
        e.tlen = int(value.size());
        pushEntity(b, e);
        break;
    }
    case DWG_TYPE_ATTRIB:
    case DWG_TYPE_ATTDEF: {
        // An ATTDEF is the template stored inside the block definition: the
        // insert supplies the matching ATTRIB that actually carries the value.
        // Drawing both piles the placeholder text on top of the real label.
        if (obj->fixedtype == DWG_TYPE_ATTDEF && depth > 0) break;
        Dwg_Entity_ATTRIB *t = ent->tio.ATTRIB;
        if (!t) break;
        const char *attribType = obj->fixedtype == DWG_TYPE_ATTDEF
                                     ? "ATTDEF" : "ATTRIB";
        std::string value = cleanText(entityText(b.dwg, t, attribType, "text_value"));
        if (value.empty()) value = cleanText(toUtf8(b.dwg, t->text_value));
        if (value.empty()) break;
        cad_entity e{};
        // Visibility was decided once above through entity->invisible and
        // ATTMODE, exactly like the reference reader. dwg_dynapi's ATTRIB
        // `flags` is not an additional visibility source.
        addEntityCommon(b, obj, space, layer, rgb, aci, lw, flags, &e);
        e.kind = CAD_TEXT;
        const Ocs ocs = ocsFor(t->extrusion, t->elevation);
        const bool useAlignmentPoint = t->horiz_alignment == 4
            || t->vert_alignment > 0;
        cad_point raw = useAlignmentPoint && (t->dataflags & 2)
                            ? cad_point{t->alignment_pt.x, t->alignment_pt.y}
                            : cad_point{t->ins_pt.x, t->ins_pt.y};
        cad_point local = ocs.map(raw.x, raw.y);
        cad_point p = xf.map(local.x, local.y);
        e.cx = p.x;
        e.cy = p.y;
        e.h = std::max(0.1, double(t->height)) * sx;
        e.rot = t->rotation + (ocs.mirrored ? 0.0 : ocs.angle) + xf.rotation();
        if (t->horiz_alignment == 3 || t->horiz_alignment == 5) {
            const double dx = t->alignment_pt.x - t->ins_pt.x;
            const double dy = t->alignment_pt.y - t->ins_pt.y;
            if (std::hypot(dx, dy) > 1e-9) {
                e.rot = std::atan2(dy, dx)
                        + (ocs.mirrored ? 0.0 : ocs.angle) + xf.rotation();
            }
        }
        e.ws = std::clamp(double(t->width_factor), 0.05, 100.0);
        e.halign = textHAlign(t->horiz_alignment);
        // horiz=4 (middle) is centred in both directions; the vertical field
        // is normally 0, so textVAlign alone leaves the label sitting on its
        // baseline and the letters appear a few pixels low.
        e.valign = t->horiz_alignment == 4 ? 2 : textVAlign(t->vert_alignment);
        e.tstart = b.textStart(value);
        e.tlen = int(value.size());
        pushEntity(b, e);
        break;
    }
    case DWG_TYPE_SPLINE: {
        Dwg_Entity_SPLINE *sp = ent->tio.SPLINE;
        if (!sp) break;
        // Prefer the NURBS definition: control points plus knots reproduce the
        // curve exactly, while the fit points are only interpolation samples
        // and joining them with straight lines leaves every spline faceted.
        const bool closed = sp->closed_b != 0 || sp->periodic != 0;
        std::vector<cad_point> cps;
        std::vector<double> weights;
        std::vector<double> knots;
        const bool hasNurbs = sp->num_ctrl_pts > 1 && sp->ctrl_pts
            && sp->num_knots > 0 && sp->knots
            && int(sp->num_knots) >= int(sp->num_ctrl_pts) + int(sp->degree) + 1;
        bool usingFitPoints = false;
        if (hasNurbs) {
            for (BITCODE_BL i = 0; i < sp->num_ctrl_pts; ++i) {
                cps.push_back(xf.map(sp->ctrl_pts[i].x, sp->ctrl_pts[i].y));
                const double w = (sp->weighted && std::abs(sp->ctrl_pts[i].w) > 1e-12)
                                     ? double(sp->ctrl_pts[i].w) : 1.0;
                weights.push_back(w);
            }
            for (BITCODE_BL i = 0; i < sp->num_knots; ++i) {
                knots.push_back(sp->knots[i]);
            }
        } else if (sp->num_fit_pts > 1 && sp->fit_pts) {
            usingFitPoints = true;
            for (BITCODE_BS i = 0; i < sp->num_fit_pts; ++i) {
                cps.push_back(xf.map(sp->fit_pts[i].x, sp->fit_pts[i].y));
            }
        } else if (sp->num_ctrl_pts > 1 && sp->ctrl_pts) {
            for (BITCODE_BL i = 0; i < sp->num_ctrl_pts; ++i) {
                cps.push_back(xf.map(sp->ctrl_pts[i].x, sp->ctrl_pts[i].y));
            }
        }
        if (cps.size() < 2) break;
        const int degree = std::clamp(int(sp->degree), 1, std::max(1, int(cps.size()) - 1));
        std::vector<cad_point> sampled =
            sampleSpline(degree, cps, knots, weights, usingFitPoints && !hasNurbs);
        if (sampled.size() < 2) break;
        cad_entity e{};
        addEntityCommon(b, obj, space, layer, rgb, aci, lw,
                        flags | (closed ? CAD_FLAG_CLOSED : 0), &e);
        e.kind = CAD_POLYLINE;
        e.pstart = int(b.doc->points.size());
        for (const cad_point &p : sampled) b.addPoint(p.x, p.y);
        e.pcount = int(sampled.size());
        pushEntity(b, e);
        break;
    }
    case DWG_TYPE_SOLID:
    case DWG_TYPE_TRACE: {
        // SOLID and TRACE share an identical layout, so one cast covers both.
        // Corners are OCS points and the quad is wound 1-2-4-3: AutoCAD stores
        // them in "Z" order, so drawing 1-2-3-4 produces a bow tie.
        Dwg_Entity_SOLID *s = ent->tio.SOLID;
        if (!s) break;
        const Ocs ocs = ocsFor(s->extrusion, s->elevation);
        const Affine eff = ocs.identity ? xf : compose(ocs.affine(), xf);
        cad_entity e{};
        addEntityCommon(b, obj, space, layer, rgb, aci, lw, flags | CAD_FLAG_FILLED, &e);
        e.kind = CAD_SOLID;
        e.pstart = int(b.doc->points.size());
        cad_point c1 = eff.map(s->corner1.x, s->corner1.y);
        cad_point c2 = eff.map(s->corner2.x, s->corner2.y);
        cad_point c3 = eff.map(s->corner3.x, s->corner3.y);
        cad_point c4 = eff.map(s->corner4.x, s->corner4.y);
        b.addPoint(c1.x, c1.y);
        b.addPoint(c2.x, c2.y);
        b.addPoint(c4.x, c4.y);
        b.addPoint(c3.x, c3.y);
        e.pcount = 4;
        e.flags |= CAD_FLAG_CLOSED;
        pushEntity(b, e);
        break;
    }
    case DWG_TYPE__3DFACE: {
        // 3DFACE is *not* SOLID: it starts with two flag bits before the
        // corners, so casting it to SOLID reads shifted coordinates. It is an
        // outline too — filling it turns every terrain face into a blob.
        Dwg_Entity__3DFACE *f = ent->tio._3DFACE;
        if (!f) break;
        std::vector<cad_point> corners = {
            xf.map(f->corner1.x, f->corner1.y),
            xf.map(f->corner2.x, f->corner2.y),
            xf.map(f->corner3.x, f->corner3.y),
            xf.map(f->corner4.x, f->corner4.y)};
        // A triangular face repeats the third corner as the fourth one.
        if (std::hypot(corners[3].x - corners[2].x, corners[3].y - corners[2].y)
            <= 1e-9) {
            corners.pop_back();
        }
        cad_entity e{};
        addEntityCommon(b, obj, space, layer, rgb, aci, lw, flags, &e);
        e.kind = CAD_POLYLINE;
        const int edgeCount = int(corners.size());
        bool allVisible = true;
        for (int i = 0; i < edgeCount; ++i) {
            if (f->invis_flags & (1 << i)) { allVisible = false; break; }
        }
        if (allVisible) {
            e.pstart = int(b.doc->points.size());
            for (const cad_point &c : corners) b.addPoint(c.x, c.y);
            e.pcount = edgeCount;
            e.flags |= CAD_FLAG_CLOSED;
            pushEntity(b, e);
            break;
        }
        // invis_flags holds one bit per edge, starting at corner1→corner2, so
        // hidden edges have to be emitted as separate runs — a single polyline
        // would draw the skipped edge back in.
        for (int i = 0; i < edgeCount; ++i) {
            if (f->invis_flags & (1 << i)) continue;
            const cad_point &a = corners[size_t(i)];
            const cad_point &bpt = corners[size_t((i + 1) % edgeCount)];
            cad_entity edge = e;
            edge.pstart = int(b.doc->points.size());
            b.addPoint(a.x, a.y);
            b.addPoint(bpt.x, bpt.y);
            edge.pcount = 2;
            pushEntity(b, edge);
        }
        break;
    }
    case DWG_TYPE_POINT: {
        Dwg_Entity_POINT *p = ent->tio.POINT;
        if (!p) break;
        cad_entity e{};
        addEntityCommon(b, obj, space, layer, rgb, aci, lw, flags, &e);
        e.kind = CAD_POINT;
        cad_point m = xf.map(p->x, p->y);
        e.cx = m.x;
        e.cy = m.y;
        pushEntity(b, e);
        break;
    }
    case DWG_TYPE_HATCH:
    case DWG_TYPE_MPOLYGON: {
        // An MPOLYGON is a HATCH read from a newer class: same struct, same
        // boundary model, so it fills identically instead of vanishing.
        convertHatch(b, obj, space, xf, layer, rgb, aci, lw);
        break;
    }
    case DWG_TYPE_INSERT:
    case DWG_TYPE_MINSERT: {
        // INSERT and MINSERT are separate structs: MINSERT carries the array
        // rows/columns *before* block_header, so reading an MINSERT through the
        // INSERT layout resolves a garbage block handle and drops the whole
        // array. Normalise the shared fields first, then read the array ones
        // from the type that actually owns them.
        Dwg_Entity_INSERT *ins = ent->tio.INSERT;
        if (!ins) break;
        Dwg_Object_Ref *blockRef = nullptr;
        int columns = 1, rows = 1;
        double colSpacing = 0, rowSpacing = 0;
        if (obj->fixedtype == DWG_TYPE_MINSERT) {
            Dwg_Entity_MINSERT *mi = ent->tio.MINSERT;
            if (!mi) break;
            blockRef = mi->block_header;
            columns = std::clamp(int(mi->num_cols), 1, 256);
            rows = std::clamp(int(mi->num_rows), 1, 256);
            colSpacing = mi->col_spacing;
            rowSpacing = mi->row_spacing;
        } else {
            blockRef = ins->block_header;
            columns = std::clamp(int(ins->num_cols), 1, 256);
            rows = std::clamp(int(ins->num_rows), 1, 256);
            colSpacing = ins->col_spacing;
            rowSpacing = ins->row_spacing;
        }
        Dwg_Object *bh = dwg_ref_object(b.dwg, blockRef);
        if (!bh || !bh->tio.object) break;
        Dwg_Object_BLOCK_HEADER *bhs = bh->tio.object->tio.BLOCK_HEADER;
        if (!bhs) break;
        // 只认 BLOCK_HEADER.blkisxref。LibreDWG 给普通块的 xref_pname 也填了
        // 块名（实测一张二层平面图上有 376 处普通块被误判成参照、整块消失），
        // 所以"pname 非空"不能当判据。
        const bool isXref = bhs->blkisxref != 0;
        if (depth > kMaxDepth) break;
        const double sxScale = std::abs(ins->scale.x) > 1e-12 ? ins->scale.x : 1.0;
        const double syScale = std::abs(ins->scale.y) > 1e-12 ? ins->scale.y : 1.0;
        const double cosine = std::cos(ins->rotation);
        const double sine = std::sin(ins->rotation);
        // The insertion point lives in the OCS of the insert, so the block has
        // to be placed through that plane before the parent transform.
        const Ocs ocs = ocsFor(ins->extrusion, 0.0);
        const Affine outer = ocs.identity ? xf : compose(ocs.affine(), xf);

        Affine local;
        local.m11 = cosine * sxScale;
        local.m12 = sine * sxScale;
        local.m21 = -sine * syScale;
        local.m22 = cosine * syScale;
        local.dx = ins->ins_pt.x - (local.m11 * bhs->base_pt.x + local.m21 * bhs->base_pt.y);
        local.dy = ins->ins_pt.y - (local.m12 * bhs->base_pt.x + local.m22 * bhs->base_pt.y);

        if (isXref) {
            // r2007+ 的块名是 UTF-16（TU），直接当 char* 用会读成 "0" 之类，
            // 必须过 toUtf8 才能拿到真正的参照文件名。
            const std::string xrefName = toUtf8(b.dwg, bhs->name);
            const std::string xrefPath = toUtf8(b.dwg, bhs->xref_pname);
            // 先把参照内容并进来再谈"缺"：找得到文件时用户不该看到任何提示。
            if (cad_doc *child = xrefDocumentFor(b, xrefName.c_str(),
                                                 xrefPath.c_str())) {
                emitXref(b, child, compose(local, outer), space, layer,
                         xrefName.c_str());
                b.xrefBound += 1;
                break;
            }
            if (getenv("CADCORE_XREF_LOG")) {
                fprintf(stderr, "[corexref] missing name=%s pname=%s\n",
                        xrefName.empty() ? "(empty)" : xrefName.c_str(),
                        xrefPath.empty() ? "(empty)" : xrefPath.c_str());
            }
            b.doc->skipped += 1;
            const std::string file = !xrefPath.empty() ? xrefPath : xrefName;
            b.doc->noteXref(b.dwg, file.c_str());
            // Record where it was inserted. The app resolves the file, loads it
            // and merges the geometry through this matrix (cad_doc_xref_insert_*).
            const Affine world = compose(local, outer);
            cad_doc::xref_insert record;
            record.nameStart = b.doc->noteText(xrefName);
            record.nameLen = int32_t(xrefName.size());
            record.pathStart = b.doc->noteText(file);
            record.pathLen = int32_t(file.size());
            record.space = space;
            record.layer = layer;
            record.m[0] = world.m11;
            record.m[1] = world.m12;
            record.m[2] = world.m21;
            record.m[3] = world.m22;
            record.m[4] = world.dx;
            record.m[5] = world.dy;
            b.doc->xrefInserts.push_back(record);
            break;
        }

        for (int row = 0; row < rows; ++row) {
            for (int column = 0; column < columns; ++column) {
                // Array offsets are measured along the rotated insert axes, not
                // along the world axes.
                const double ox = column * colSpacing;
                const double oy = row * rowSpacing;
                Affine cell = local;
                cell.dx += cosine * ox - sine * oy;
                cell.dy += sine * ox + cosine * oy;
                const Affine combined = compose(cell, outer);
                const size_t clipBegin = b.doc->entities.size();
                expandBlock(b, bh, space, combined, layer, rgb, aci,
                            lw, depth + 1);
                // An INSERT of an anonymous dimension block (`*D1`) is how
                // several producers store a dimension: the geometry arrives
                // through the insert chain, not through the DIMENSION object.
                // It has to carry the same "this is annotation ink" flag, or
                // snap happily targets the far end of a witness line.
                if (isDimensionBlockName(bhs->name)) {
                    for (size_t k = clipBegin; k < b.doc->entities.size(); ++k) {
                        b.doc->entities[k].flags |= CAD_FLAG_DIMENSION;
                    }
                }
                // XCLIP: AutoCAD only shows the part of the block inside the
                // spatial filter. Without this the whole block definition is
                // drawn, which is how furniture blocks paint over the walls.
                auto clip = b.clipsByHandle.find(obj->handle.value);
                if (clip != b.clipsByHandle.end()) {
                    applyClipRange(b, clipBegin, clip->second, combined);
                }
            }
        }

        // Attribute values ride along with the insert, in the parent space
        // (their points are already WCS, they are not transformed by the
        // block matrix). Prefer the ownerhandle index: first_attrib is often
        // null and the seqend chain is often broken in real DWG files.
        auto owned = b.attributesByOwner.find(obj->handle.value);
        if (owned != b.attributesByOwner.end() && !owned->second.empty()) {
            for (Dwg_Object *attribute : owned->second) {
                if (!attribute || !attribute->tio.entity) continue;
                convertEntity(b, attribute, space, xf, layer, rgb, aci, lw,
                              depth + 1);
            }
        } else {
            BITCODE_BL attributeCount = 0;
            Dwg_Object_Ref **attribs = nullptr;
            Dwg_Object_Ref *aref = nullptr;
            if (obj->fixedtype == DWG_TYPE_MINSERT) {
                Dwg_Entity_MINSERT *mi = ent->tio.MINSERT;
                if (mi) {
                    attributeCount = mi->num_owned;
                    attribs = mi->attribs;
                    aref = mi->first_attrib;
                }
            } else {
                attributeCount = ins->num_owned;
                attribs = ins->attribs;
                aref = ins->first_attrib;
            }
            if (attribs && attributeCount > 0) {
                for (BITCODE_BL i = 0; i < attributeCount; ++i) {
                    Dwg_Object *aobj = dwg_ref_object(b.dwg, attribs[i]);
                    if (!aobj || !aobj->tio.entity) continue;
                    convertEntity(b, aobj, space, xf, layer, rgb, aci, lw,
                                  depth + 1);
                }
            } else {
                int guard = 0;
                while (aref && guard++ < 4096) {
                    Dwg_Object *aobj = dwg_ref_object(b.dwg, aref);
                    if (!aobj || !aobj->tio.entity) break;
                    convertEntity(b, aobj, space, xf, layer, rgb, aci, lw,
                                  depth + 1);
                    aref = aobj->tio.entity->next_entity;
                }
            }
        }
        break;
    }
    case DWG_TYPE_LEADER: {
        Dwg_Entity_LEADER *ld = ent->tio.LEADER;
        if (!ld || !ld->points || ld->num_points < 2) break;
        // LEADER vertices are WCS already; only the arrow sits in the OCS.
        cad_entity e{};
        addEntityCommon(b, obj, space, layer, rgb, aci, lw, flags, &e);
        e.kind = CAD_POLYLINE;
        e.pstart = int(b.doc->points.size());
        for (BITCODE_BL i = 0; i < ld->num_points; ++i) {
            cad_point p = xf.map(ld->points[i].x, ld->points[i].y);
            b.addPoint(p.x, p.y);
        }
        e.pcount = int(ld->num_points);
        pushEntity(b, e);
        break;
    }
    case DWG_TYPE_MLINE: {
        // A real MLINE is a ribbon of parallel offsets: every vertex stores the
        // definition point plus one offset per style line (segparms[0]) along
        // the vertex's miter direction. Stroking only the centreline (the
        // previous behaviour) turned every double-line wall into a single thin
        // line — one of the reasons walls looked like they were missing.
        Dwg_Entity_MLINE *ml = ent->tio.MLINE;
        if (!ml || !ml->verts || ml->num_verts < 2) break;
        const int lineCount = std::clamp(int(ml->num_lines), 1, 16);
        std::vector<cad_point> line;
        for (int li = 0; li < lineCount; ++li) {
            line.clear();
            line.reserve(size_t(ml->num_verts));
            for (BITCODE_BS i = 0; i < ml->num_verts; ++i) {
                const Dwg_MLINE_vertex &vertex = ml->verts[i];
                double px = vertex.vertex.x, py = vertex.vertex.y;
                if (vertex.lines && li < int(vertex.num_lines)
                    && vertex.lines[li].num_segparms > 0
                    && vertex.lines[li].segparms) {
                    const double offset = vertex.lines[li].segparms[0];
                    if (std::isfinite(offset)
                        && std::abs(offset) < b.referenceExtent) {
                        px += vertex.miter_direction.x * offset;
                        py += vertex.miter_direction.y * offset;
                    }
                }
                const cad_point p = xf.map(px, py);
                line.push_back(p);
            }
            if (line.size() < 2) continue;
            cad_entity e{};
            addEntityCommon(b, obj, space, layer, rgb, aci, lw, flags, &e);
            e.kind = CAD_POLYLINE;
            e.pstart = int(b.doc->points.size());
            e.pcount = int(line.size());
            for (const cad_point &p : line) b.addPoint(p.x, p.y);
            pushEntity(b, e);
        }
        break;
    }
    case DWG_TYPE_XLINE:
    case DWG_TYPE_RAY: {
        // Infinite construction geometry. Both are drawn out to the drawing
        // extent so they appear where CAD shows them; the previous reader had
        // no case for either, so every construction line vanished.
        auto *ray = obj->fixedtype == DWG_TYPE_XLINE
            ? dwg_object_to_XLINE(obj) : dwg_object_to_RAY(obj);
        if (!ray) break;
        const double dx = ray->vector.x, dy = ray->vector.y;
        const double length = std::hypot(dx, dy);
        if (length < 1e-12) break;
        const double ux = dx / length, uy = dy / length;
        const double back = obj->fixedtype == DWG_TYPE_RAY ? 0.0 : b.referenceExtent;
        cad_entity e{};
        addEntityCommon(b, obj, space, layer, rgb, aci, lw, flags, &e);
        e.kind = CAD_POLYLINE;
        e.pstart = int(b.doc->points.size());
        const cad_point a = xf.map(ray->point.x - ux * back,
                                   ray->point.y - uy * back);
        const cad_point c = xf.map(ray->point.x + ux * b.referenceExtent,
                                   ray->point.y + uy * b.referenceExtent);
        b.addPoint(a.x, a.y);
        b.addPoint(c.x, c.y);
        e.pcount = 2;
        pushEntity(b, e);
        break;
    }
    case DWG_TYPE_REGION:
    case DWG_TYPE_BODY:
    case DWG_TYPE__3DSOLID: {
        // ACIS solids carry their visible shape as explicit wires. The previous
        // reader dropped the whole family, which is why filled regions and
        // solid-derived outlines were simply absent.
        auto *solid = dwg_object_to__3DSOLID(obj);
        if (!solid || !solid->wires) break;
        for (BITCODE_BL wi = 0; wi < solid->num_wires; ++wi) {
            const Dwg_3DSOLID_wire &wire = solid->wires[wi];
            if (!wire.points || wire.num_points < 2) continue;
            cad_entity e{};
            addEntityCommon(b, obj, space, layer, rgb, aci, lw, flags, &e);
            e.kind = CAD_POLYLINE;
            e.pstart = int(b.doc->points.size());
            for (BITCODE_BL i = 0; i < wire.num_points; ++i) {
                const cad_point p = xf.map(wire.points[i].x, wire.points[i].y);
                b.addPoint(p.x, p.y);
            }
            e.pcount = int(wire.num_points);
            pushEntity(b, e);
        }
        break;
    }
    default: {
        // The six base dimension types share one enum run; the jogged radius
        // and arc-length variants live in the extended range but start with
        // DIMENSION_COMMON, so the cast is safe. Stopping at ANG3PT silently
        // dropped radius, diameter and angular dimensions.
        const bool dimension =
            (obj->fixedtype >= DWG_TYPE_DIMENSION_ORDINATE
             && obj->fixedtype <= DWG_TYPE_DIMENSION_DIAMETER)
            || obj->fixedtype == DWG_TYPE_LARGE_RADIAL_DIMENSION
            || obj->fixedtype == DWG_TYPE_ARC_DIMENSION;
        if (!dimension) break;
        Dwg_DIMENSION_common *dim = nullptr;
        if (obj->fixedtype == DWG_TYPE_LARGE_RADIAL_DIMENSION) {
            dim = obj->tio.entity->tio.LARGE_RADIAL_DIMENSION
                      ? reinterpret_cast<Dwg_DIMENSION_common *>(
                            obj->tio.entity->tio.LARGE_RADIAL_DIMENSION)
                      : nullptr;
        } else if (obj->fixedtype == DWG_TYPE_ARC_DIMENSION) {
            dim = obj->tio.entity->tio.ARC_DIMENSION
                      ? reinterpret_cast<Dwg_DIMENSION_common *>(
                            obj->tio.entity->tio.ARC_DIMENSION)
                      : nullptr;
        } else {
            dim = ent->tio.DIMENSION_common;
        }
        bool expanded = false;
        b.dimTotal += 1;
        if (dim && dim->block) {
            Dwg_Object *bh = dwg_ref_object(b.dwg, dim->block);
            if (bh && bh->tio.object) {
                const size_t before = b.doc->entities.size();
                const int invisibleBefore = b.dropInvisible;
                expandBlock(b, bh, space, xf, layer, rgb, aci, lw, depth + 1);
                b.dimBlockChildren += int(b.doc->entities.size() - before);
                b.dimInvisibleChildren += b.dropInvisible - invisibleBefore;
                for (size_t k = before; k < b.doc->entities.size(); ++k) {
                    b.doc->entities[k].flags |= CAD_FLAG_DIMENSION;
                    b.dimChildKinds[b.doc->entities[k].kind] += 1;
                }
                if (getenv("CADCORE_DIM_DUMP") && b.dimTotal <= 3) {
                    fprintf(stderr, "[dim %d] children=%zu\n", b.dimTotal,
                            b.doc->entities.size() - before);
                    for (size_t k = before; k < b.doc->entities.size(); ++k) {
                        const cad_entity &c = b.doc->entities[k];
                        fprintf(stderr,
                                "   kind=%d pts=%d box=(%.1f,%.1f)-(%.1f,%.1f) "
                                "rgb=%06X aci=%d\n",
                                c.kind, c.pcount, c.box.minx, c.box.miny,
                                c.box.maxx, c.box.maxy, c.rgb & 0xFFFFFF,
                                int(c.aci));
                    }
                }
                expanded = true;
                b.dimExpanded += 1;
            }
        }
        if (!expanded) b.dimNoBlock += 1;
        // Without the anonymous block the drawn geometry is gone, but the
        // annotation itself is still real: DXF 1 carries the text and DXF 11
        // its midpoint, so the measurement does not have to disappear.
        if (dim && !expanded) {
            std::string label = cleanText(toUtf8(b.dwg, dim->user_text));
            if (label.empty() && std::isfinite(dim->act_measurement)) {
                char buffer[64];
                std::snprintf(buffer, sizeof(buffer), "%.0f",
                              double(dim->act_measurement));
                label = buffer;
            }
            if (!label.empty()) {
                // 0 means "not carried by the file": a DIMENSION with no
                // DIMSTYLE, or one whose DIMTXT is 0. finishSpace() then lifts
                // the height from the annotation the drawing already has,
                // which is what makes it agree with the GB paper height for
                // this plot scale (3.5 mm up to A1, 5 mm on A0).
                double height = 0;
                if (dim->dimstyle) {
                    Dwg_Object *styleObject = dwg_ref_object(b.dwg, dim->dimstyle);
                    Dwg_Object_DIMSTYLE *style =
                        styleObject && styleObject->tio.object
                            ? styleObject->tio.object->tio.DIMSTYLE : nullptr;
                    if (style && style->DIMTXT > 1e-9) {
                        height = style->DIMTXT * std::max(1.0, double(style->DIMSCALE));
                    }
                }
                const Ocs ocs = ocsFor(dim->extrusion, dim->elevation);
                cad_point local = ocs.map(dim->text_midpt.x, dim->text_midpt.y);
                cad_point p = xf.map(local.x, local.y);
                cad_entity e{};
                addEntityCommon(b, obj, space, layer, rgb, aci, lw, flags, &e);
                e.kind = CAD_TEXT;
                e.cx = p.x;
                e.cy = p.y;
                e.h = height > 1e-9 ? height * sx : 0.0;
                if (height <= 1e-9) e.flags |= CAD_FLAG_GB_HEIGHT;
                e.rot = (std::abs(dim->text_rotation) > 1e-12
                             ? double(dim->text_rotation) : double(dim->horiz_dir))
                        + (ocs.mirrored ? 0.0 : ocs.angle) + xf.rotation();
                e.ws = 1.0;
                e.halign = 1;   // dimensions are centred on their midpoint
                e.valign = 2;
                e.tstart = b.textStart(label);
                e.tlen = int(label.size());
                pushEntity(b, e);
            }
        }
        break;
    }
    }
}

/// Saved model camera. Reference: LibreDwgReader::readSavedModelView().
///
/// VPORT is the drawing's saved-view table (a viewport *configuration*, not a
/// paper-space VIEWPORT entity). Its `*Active` record holds the camera the
/// author last used in model space. Restoring it on first open is what makes a
/// reference viewer show the same three plan views at the same zoom; fitting
/// the entity extents instead re-frames the sheet and can crop the outer ones.
void readSavedView(Builder &b) {
    Dwg_Data *dwg = b.dwg;
    if (!dwg) return;
    Dwg_Object_VPORT *active = nullptr;
    Dwg_Object_VPORT *fallback = nullptr;
    for (BITCODE_BL i = 0; i < dwg->num_objects; ++i) {
        Dwg_Object *object = &dwg->object[i];
        if (object->fixedtype != DWG_TYPE_VPORT) continue;
        Dwg_Object_VPORT *vp = dwg_object_to_VPORT(object);
        if (!vp || vp->VIEWSIZE <= 1.0e-9) continue;
        if (getenv("CADCORE_VIEW_DEBUG")) {
            fprintf(stderr,
                    "[vport] name=%s ctr=(%g,%g) size=%g w=%g twist=%g\n",
                    vp->name ? vp->name : "(null)",
                    vp->VIEWCTR.x, vp->VIEWCTR.y, vp->VIEWSIZE,
                    vp->view_width, vp->VIEWTWIST);
        }
        if (!fallback) fallback = vp;
        if (vp->name) {
            std::string name(vp->name);
            for (char &c : name) {
                if (c >= 'A' && c <= 'Z') c = char(c - 'A' + 'a');
            }
            if (name == "*active") {
                active = vp;
                break;
            }
        }
    }
    Dwg_Object_VPORT *view = active ? active : fallback;
    if (!view) return;
    b.doc->savedView.valid = 1;
    b.doc->savedView.cx = view->VIEWCTR.x;
    b.doc->savedView.cy = view->VIEWCTR.y;
    b.doc->savedView.height = view->VIEWSIZE;
    b.doc->savedView.width =
        view->view_width > 1.0e-9 ? view->view_width : view->VIEWSIZE;
    b.doc->savedView.twist = view->VIEWTWIST;
}

void buildLayers(Builder &b) {
    Dwg_Data *dwg = b.dwg;
    struct Entry {
        std::string name;
        uint32_t rgb;
        int flags;
        float lineweight;
        uint64_t handle;
    };
    std::vector<Entry> entries;

    for (BITCODE_BL i = 0; i < dwg->num_objects; ++i) {
        Dwg_Object *obj = &dwg->object[i];
        if (obj->fixedtype != DWG_TYPE_LAYER || !obj->tio.object) continue;
        Dwg_Object_LAYER *layer = obj->tio.object->tio.LAYER;
        if (!layer) continue;
        std::string name = toUtf8(dwg, layer->name);
        if (name.empty()) name = "0";
        Entry entry;
        entry.name = name;
        const CmcColor layerColor = cmcColor(layer->color);
        const int aci = int(layerColor.aci);
        const uint32_t rgb = layerColor.rgb;
        entry.rgb = rgb | (uint32_t(aci) << 24);
        entry.flags = 0;
        if (layer->off) entry.flags |= CAD_LAYER_OFF;
        // AutoCAD's AUDIT sweeps orphans (furniture, plants, fixtures) onto
        // $TD_AUDIT_GENERATED_* layers. No viewport ever freezes them, so they
        // leak into every sheet; reference viewers hide them by default.
        if (name.rfind("$TD_AUDIT_GENERATED_", 0) == 0) {
            entry.flags |= CAD_LAYER_OFF;
        }
        if (layer->frozen) entry.flags |= CAD_LAYER_FROZEN;
        if (layer->locked) entry.flags |= CAD_LAYER_LOCKED;
        entry.lineweight = lineweightMm(layer->linewt);
        entry.handle = obj->handle.value;
        entries.push_back(entry);
    }

    bool hasZero = false;
    for (const Entry &entry : entries) {
        if (entry.name == "0") hasZero = true;
    }
    if (!hasZero) {
        Entry zero;
        zero.name = "0";
        zero.rgb = kAciPalette[7] | (uint32_t(7) << 24);
        zero.flags = 0;
        zero.lineweight = 0.25f;
        zero.handle = 0;
        entries.insert(entries.begin(), zero);
    }

    for (const Entry &entry : entries) {
        cad_layer layerOut{};
        layerOut.name_start = b.textStart(entry.name);
        layerOut.name_len = int(entry.name.size());
        layerOut.rgb = entry.rgb;
        layerOut.flags = entry.flags;
        layerOut.lineweight = entry.lineweight;
        layerOut.count = 0;
        int index = int(b.doc->layers.size());
        b.doc->layers.push_back(layerOut);
        if (!b.layerByName.count(entry.name)) b.layerByName[entry.name] = index;
        if (entry.handle) b.layerIndexByHandle[entry.handle] = index;
    }
}

void collectBlockHeaders(Builder &b, std::vector<Dwg_Object *> &headers) {
    Dwg_Data *dwg = b.dwg;
    for (BITCODE_BL i = 0; i < dwg->num_objects; ++i) {
        Dwg_Object *obj = &dwg->object[i];
        if (obj->fixedtype == DWG_TYPE_BLOCK_HEADER && obj->tio.object) {
            headers.push_back(obj);
        }
    }
}

std::string blockName(Dwg_Data *dwg, Dwg_Object *bh) {
    Dwg_Object_BLOCK_HEADER *h = bh->tio.object ? bh->tio.object->tio.BLOCK_HEADER : nullptr;
    if (!h) return {};
    return toUtf8(dwg, h->name);
}

int addSpace(cad_doc *doc, Builder &b, const std::string &name, int kind) {
    cad_space space{};
    space.name_start = b.textStart(name);
    space.name_len = int(name.size());
    space.kind = kind;
    space.first_entity = int(doc->entities.size());
    space.entity_count = 0;
    space.box = {1e300, 1e300, -1e300, -1e300};
    doc->spaces.push_back(space);
    return int(doc->spaces.size()) - 1;
}

void finishSpace(cad_doc *doc, int index) {
    cad_space &space = doc->spaces[size_t(index)];
    space.first_entity = index == 0 ? 0 : space.first_entity;
    space.entity_count = int(doc->entities.size()) - space.first_entity;
    // ---------------------------------------------------------- GB text height
    //
    // GB/T 50001-2017 (buildings) and GB/T 4458.4-2003 (mechanical parts) both
    // state the dimension text height as a *paper* figure — 3.5 mm on A2–A4,
    // 5 mm on A0–A1 — so the drawing-units height is that times the plot
    // scale, which the file never stores as such. The drawing does carry the
    // answer, though: every annotation on the sheet was already placed at the
    // right height, so the median of those heights *is* 3.5 mm × scale. Only a
    // sheet with no annotation at all falls back to the bare 3.5 mm, which is
    // the correct height when the drawing is drafted 1:1 in millimetres.
    {
        std::vector<double> heights;
        heights.reserve(size_t(space.entity_count));
        for (int i = 0; i < space.entity_count; ++i) {
            const cad_entity &e = doc->entities[size_t(space.first_entity) + size_t(i)];
            if (e.kind == CAD_TEXT && e.h > 0 && !(e.flags & CAD_FLAG_GB_HEIGHT)) {
                heights.push_back(e.h);
            }
        }
        double inferred = 3.5;
        if (!heights.empty()) {
            std::sort(heights.begin(), heights.end());
            inferred = heights[heights.size() / 2];
        }
        for (int i = 0; i < space.entity_count; ++i) {
            cad_entity &e = doc->entities[size_t(space.first_entity) + size_t(i)];
            if (e.kind != CAD_TEXT || !(e.flags & CAD_FLAG_GB_HEIGHT)) continue;
            e.h = inferred;
            updateTextBox(doc, e);
        }
    }
    space.box = {1e300, 1e300, -1e300, -1e300};
    for (int i = 0; i < space.entity_count; ++i) {
        const cad_entity &e = doc->entities[size_t(space.first_entity) + size_t(i)];
        if (e.box.minx > e.box.maxx) continue;
        space.box.minx = std::min(space.box.minx, e.box.minx);
        space.box.miny = std::min(space.box.miny, e.box.miny);
        space.box.maxx = std::max(space.box.maxx, e.box.maxx);
        space.box.maxy = std::max(space.box.maxy, e.box.maxy);
    }
    for (const cad_layer &layer : doc->layers) {
        (void) layer;
    }
    if (!(space.box.minx <= space.box.maxx)) {
        space.box = {0, 0, 0, 0};
    }
}

// ------------------------------------------------------- libdxfrw DXF reader
//
// LibreDWG's DXF importer rebuilds a complete DWG object graph and costs O(n²)
// in the entity count: 8 000 lines take ~3.5 s and 50 000 lines ~3.5 min, which
// is unusable for a site plan. libdxfrw streams the same file linearly
// (8 000 lines ≈ 50 ms), so DXF files are read through it first and fall back
// to LibreDWG only when libdxfrw rejects the file.

enum class DxfKind {
    none,
    line,
    polyline,
    circle,
    arc,
    ellipse,
    text,
    hatch,
    point,
    solid,
    insert
};

struct DxfPatternLine {
    double angle = 0, baseX = 0, baseY = 0, offsetX = 0, offsetY = 0;
    std::vector<double> dashes;
};

struct DxfItem {
    DxfKind kind = DxfKind::none;
    std::string layer = "0";
    int flags = 0;
    int aci = 256;  // 0 = byBlock, 256 = byLayer
    int rgb = -1;   // true colour, -1 = absent
    int lw = -1;    // >= 0 index, -1 byLayer, -2 byBlock
    bool visible = true;
    bool paper = false;

    std::vector<cad_point> pts;
    double cx = 0, cy = 0, r = 0, a0 = 0, a1 = 0;
    double majorX = 0, majorY = 0, ratio = 1;
    double rot = 0, height = 0, widthScale = 1;
    int halign = 0, valign = 0;
    std::string text;

    std::vector<std::vector<cad_point>> rings;
    bool solidFill = false;
    int hatchStyle = 0;
    double hatchAngle = 0, hatchScale = 1;
    std::vector<DxfPatternLine> pattern;

    std::string block;
    double insertX = 0, insertY = 0, scaleX = 1, scaleY = 1, insertRotation = 0;
    int columns = 1, rows = 1;
    double columnSpace = 0, rowSpace = 0;
};

std::string upperCase(std::string value) {
    for (char &c : value) {
        c = char(toupper(static_cast<unsigned char>(c)));
    }
    return value;
}

struct DxfLoad {
    cad_doc *doc = nullptr;
    Builder *builder = nullptr;
    std::unordered_map<std::string, int> layerIndex;
    // std::map keeps node addresses stable, so `current` stays valid while new
    // blocks are inserted.
    std::map<std::string, std::vector<DxfItem>> blocks;
    std::vector<DxfItem> model;
    std::vector<DxfItem> paper;
    std::vector<DxfItem> *current = &model;
    std::vector<std::string> stack;
    int skipped = 0;
    int emitted = 0;
    std::string version;
    int units = -1;
    // libdxfrw 这条快路不展开外部参照。碰到含参照的 DXF 就整份让给
    // LibreDWG——它走 Builder/INSERT 那条路，参照会随主图一起并进来。
    bool hasXref = false;

    int ensureLayer(const std::string &name) {
        auto found = layerIndex.find(name);
        if (found != layerIndex.end()) return found->second;
        cad_layer layer{};
        layer.name_start = builder->textStart(name);
        layer.name_len = int(name.size());
        layer.rgb = kAciPalette[7] | (uint32_t(7) << 24);
        layer.flags = 0;
        layer.lineweight = 0.25f;
        layer.count = 0;
        int index = int(doc->layers.size());
        doc->layers.push_back(layer);
        layerIndex[name] = index;
        return index;
    }

    void defineLayer(const std::string &name, int aci, int rgb, float lw, int flags) {
        if (aci <= 0 || aci > 255) aci = 7;
        uint32_t color = rgb >= 0 ? (uint32_t(rgb) & 0xFFFFFFu) : kAciPalette[aci];
        int index = ensureLayer(name);
        cad_layer &layer = doc->layers[size_t(index)];
        layer.rgb = color | (uint32_t(aci) << 24);
        layer.flags = flags;
        layer.lineweight = lw;
    }

    int layerAci(int index) const {
        if (index < 0 || index >= int(doc->layers.size())) return 7;
        return int((doc->layers[size_t(index)].rgb >> 24) & 0xFF);
    }

    float layerWeight(int index) const {
        if (index < 0 || index >= int(doc->layers.size())) return 0.25f;
        return doc->layers[size_t(index)].lineweight;
    }

    void push(DxfItem &item) {
        if (!current) return;
        if (item.paper && current == &model) {
            paper.push_back(std::move(item));
            return;
        }
        current->push_back(std::move(item));
    }
};

struct DxfStyle {
    int layer = 0;
    int aci = 7;
    uint32_t rgb = 0xFFFFFF;
    float lineweight = 0.25f;
};

DxfStyle resolveStyle(DxfLoad &ctx, const DxfItem &item, int inheritedAci,
                      uint32_t inheritedRgb, float inheritedLw) {
    DxfStyle style;
    style.layer = ctx.ensureLayer(item.layer);
    const int raw = item.aci;
    if (raw > 0 && raw < 256) {
        style.aci = raw;
    } else if (raw == 0) {
        style.aci = (inheritedAci > 0 && inheritedAci < 256) ? inheritedAci : 7;
    } else {
        style.aci = ctx.layerAci(style.layer);
    }
    if (item.rgb >= 0) {
        style.rgb = uint32_t(item.rgb) & 0xFFFFFFu;
    } else if (raw == 0 && inheritedRgb != 0) {
        style.rgb = inheritedRgb;
    } else {
        style.rgb = kAciPalette[style.aci];
    }
    if (item.lw >= 0) {
        style.lineweight = lineweightMm(item.lw);
    } else if (item.lw == -2 && inheritedLw > 0) {
        style.lineweight = inheritedLw;
    } else {
        style.lineweight = ctx.layerWeight(style.layer);
    }
    return style;
}

// Bulge sampling for the DXF path lives in the shared sampleBulge() defined
// above, so DWG and DXF use the same reference-derived arc maths.

void emitItem(DxfLoad &ctx, const DxfItem &item, int space, const Affine &xf,
              int inheritedAci, uint32_t inheritedRgb, float inheritedLw, int depth);

void emitInsert(DxfLoad &ctx, const DxfItem &item, int space, const Affine &xf,
                int aci, uint32_t rgb, float lw, int depth) {
    if (depth >= kMaxDepth) {
        ctx.skipped += 1;
        return;
    }
    auto found = ctx.blocks.find(upperCase(item.block));
    if (found == ctx.blocks.end() || found->second.empty()) {
        ctx.skipped += 1;
        return;
    }
    int columns = std::max(1, item.columns);
    int rows = std::max(1, item.rows);
    double sx = item.scaleX != 0 ? item.scaleX : 1;
    double sy = item.scaleY != 0 ? item.scaleY : 1;
    double c = std::cos(item.insertRotation), s = std::sin(item.insertRotation);
    // A DXF DIMENSION reaches this path as an INSERT of its `*D…` block; see
    // isDimensionBlockName() for why those children are flagged.
    const bool dimensionBlock = item.block.size() > 1 && item.block[0] == '*'
        && (item.block[1] == 'D' || item.block[1] == 'd');
    for (int row = 0; row < rows; ++row) {
        for (int column = 0; column < columns; ++column) {
            Affine local;
            local.m11 = sx * c;
            local.m12 = sx * s;
            local.m21 = -sy * s;
            local.m22 = sy * c;
            local.dx = item.insertX + double(column) * item.columnSpace;
            local.dy = item.insertY + double(row) * item.rowSpace;
            Affine combined = compose(local, xf);
            const size_t flagBegin = ctx.doc->entities.size();
            for (const DxfItem &child : found->second) {
                if (ctx.emitted >= int(kMaxEntities)) return;
                emitItem(ctx, child, space, combined, aci, rgb, lw, depth + 1);
            }
            if (dimensionBlock) {
                for (size_t k = flagBegin; k < ctx.doc->entities.size(); ++k) {
                    ctx.doc->entities[k].flags |= CAD_FLAG_DIMENSION;
                }
            }
        }
    }
}

void emitItem(DxfLoad &ctx, const DxfItem &item, int space, const Affine &xf,
              int inheritedAci, uint32_t inheritedRgb, float inheritedLw, int depth) {
    if (item.kind == DxfKind::none) return;
    DxfStyle style = resolveStyle(ctx, item, inheritedAci, inheritedRgb, inheritedLw);
    if (item.kind == DxfKind::insert) {
        emitInsert(ctx, item, space, xf, style.aci, style.rgb, style.lineweight, depth);
        return;
    }

    cad_doc *doc = ctx.doc;
    cad_entity e{};
    e.space = space;
    e.layer = style.layer;
    e.rgb = style.rgb;
    e.aci = uint8_t(style.aci);
    e.lineweight = style.lineweight;
    e.flags = item.flags;
    e.hatch = -1;
    e.tstart = -1;
    if (!item.visible) e.flags |= CAD_FLAG_INVISIBLE;

    double scale = xf.meanScale();
    if (!(scale > 0)) scale = 1;
    const double rotation = xf.rotation();
    const bool mirrored = (xf.m11 * xf.m22 - xf.m12 * xf.m21) < 0;

    switch (item.kind) {
    case DxfKind::line:
    case DxfKind::polyline: {
        if (item.pts.size() < 2) return;
        e.kind = item.kind == DxfKind::line ? CAD_LINE : CAD_POLYLINE;
        e.pstart = int(doc->points.size());
        e.pcount = int(item.pts.size());
        // No per-entity reserve(): asking for exactly size + n reallocates on
        // every call and turns the whole load quadratic.
        for (const cad_point &p : item.pts) doc->points.push_back(xf.map(p.x, p.y));
        break;
    }
    case DxfKind::circle:
    case DxfKind::arc: {
        cad_point c = xf.map(item.cx, item.cy);
        const bool circle = item.kind == DxfKind::circle;
        e.kind = circle ? CAD_CIRCLE : CAD_ARC;
        e.cx = c.x;
        e.cy = c.y;
        e.r = item.r * scale;
        if (mirrored) {
            e.a0 = 2 * rotation - item.a1;
            e.a1 = 2 * rotation - item.a0;
        } else {
            e.a0 = item.a0 + rotation;
            e.a1 = item.a1 + rotation;
        }
        // Reference CadModel.cpp::sampleArc(): flatten at import time, in
        // source coordinates, then map every vertex through the block affine.
        // The DXF backend has no OCS, so the plane is identity here.
        const Ocs plane;
        double start = 0.0, sweep = kTwoPi;
        if (!circle) {
            start = item.a0;
            sweep = item.a1 - item.a0;
            while (sweep <= 0.0) sweep += kTwoPi;
        }
        const auto samples = sampleArcOcs(xf, plane, item.cx, item.cy,
                                          item.r, start, sweep, circle);
        setCurvePoints(*ctx.builder, e, samples);
        if (circle) e.flags |= CAD_FLAG_CLOSED;
        break;
    }
    case DxfKind::ellipse: {
        cad_point c = xf.map(item.cx, item.cy);
        double mx = xf.m11 * item.majorX + xf.m21 * item.majorY;
        double my = xf.m12 * item.majorX + xf.m22 * item.majorY;
        e.kind = CAD_ELLIPSE;
        e.cx = c.x;
        e.cy = c.y;
        e.major_x = mx;
        e.major_y = my;
        e.ratio = item.ratio > 0 ? item.ratio : 1.0;
        e.a0 = item.a0;
        e.a1 = item.a1;
        const Ocs plane;
        double start = item.a0;
        double sweep = item.a1 - item.a0;
        const bool full = std::abs(sweep) < 1e-10
                          || std::abs(std::abs(sweep) - kTwoPi) < 1e-6;
        if (full) {
            start = 0.0;
            sweep = kTwoPi;
        } else {
            while (sweep <= 0.0) sweep += kTwoPi;
        }
        const double minorX = -item.majorY * e.ratio;
        const double minorY = item.majorX * e.ratio;
        const auto samples = sampleEllipseOcs(
            xf, plane, item.cx, item.cy, item.majorX, item.majorY,
            minorX, minorY, start, sweep, full);
        setCurvePoints(*ctx.builder, e, samples);
        if (full) e.flags |= CAD_FLAG_CLOSED;
        break;
    }
    case DxfKind::text: {
        if (item.text.empty()) return;
        cad_point p = xf.map(item.cx, item.cy);
        e.kind = CAD_TEXT;
        e.cx = p.x;
        e.cy = p.y;
        e.h = std::max(0.001, item.height * scale);
        e.ws = item.widthScale > 0 ? item.widthScale : 1.0;
        e.rot = item.rot + rotation;
        e.halign = item.halign;
        e.valign = item.valign;
        e.tstart = ctx.builder->textStart(item.text);
        e.tlen = int(item.text.size());
        break;
    }
    case DxfKind::solid: {
        if (item.pts.size() < 3) return;
        e.kind = CAD_SOLID;
        e.pstart = int(doc->points.size());
        e.pcount = int(item.pts.size());
        for (const cad_point &p : item.pts) doc->points.push_back(xf.map(p.x, p.y));
        break;
    }
    case DxfKind::point: {
        cad_point p = xf.map(item.cx, item.cy);
        e.kind = CAD_POINT;
        e.cx = p.x;
        e.cy = p.y;
        break;
    }
    case DxfKind::hatch: {
        if (item.rings.empty()) return;
        cad_hatch hatch{};
        hatch.ringstart = int(doc->rings.size());
        hatch.solid = item.solidFill ? 1 : 0;
        hatch.style = item.hatchStyle;
        hatch.angle = item.hatchAngle;
        hatch.scale = item.hatchScale > 0 ? item.hatchScale : 1.0;
        for (const std::vector<cad_point> &ring : item.rings) {
            if (ring.size() < 3) continue;
            cad_ring out{};
            out.pstart = int(doc->points.size());
            out.pcount = int(ring.size());
            out.closed = 1;
            for (const cad_point &p : ring) doc->points.push_back(xf.map(p.x, p.y));
            doc->rings.push_back(out);
        }
        hatch.ringcount = int(doc->rings.size()) - hatch.ringstart;
        if (hatch.ringcount <= 0) return;
        int dashOffset = 0;
        for (const DxfPatternLine &line : item.pattern) {
            if (hatch.defcount >= 8) break;
            int d = hatch.defcount;
            // Same contract as the DWG path: base point is a point, angle and
            // offset are vectors, and all of them go through the block affine.
            const cad_point origin = xf.map(line.baseX, line.baseY);
            const double ca = std::cos(line.angle), sa = std::sin(line.angle);
            const double dirX = xf.m11 * ca + xf.m21 * sa;
            const double dirY = xf.m12 * ca + xf.m22 * sa;
            const double dirLength = std::hypot(dirX, dirY);
            hatch.def_angle[d] = std::atan2(dirY, dirX);
            hatch.def_x[d] = origin.x;
            hatch.def_y[d] = origin.y;
            hatch.def_dx[d] = xf.m11 * line.offsetX + xf.m21 * line.offsetY;
            hatch.def_dy[d] = xf.m12 * line.offsetX + xf.m22 * line.offsetY;
            hatch.def_dash_start[d] = dashOffset;
            int count = 0;
            for (double dash : line.dashes) {
                if (dashOffset >= 128) break;
                hatch.dashes[dashOffset++] = dash * dirLength;
                count += 1;
            }
            hatch.def_ndashes[d] = count;
            hatch.defcount += 1;
        }
        if (hatch.defcount == 0 && !hatch.solid) {
            hatch.defcount = 1;
            hatch.def_angle[0] = kPi / 4.0;
            hatch.def_x[0] = xf.dx;
            hatch.def_y[0] = xf.dy;
            hatch.def_dx[0] = xf.m11 * 3.0;
            hatch.def_dy[0] = xf.m12 * 3.0;
            hatch.def_ndashes[0] = 0;
            hatch.def_dash_start[0] = 0;
        }
        e.kind = CAD_HATCH;
        e.flags |= CAD_FLAG_FILLED;
        e.hatch = int(doc->hatches.size());
        doc->hatches.push_back(hatch);
        e.cx = xf.map(0, 0).x;
        e.cy = xf.map(0, 0).y;
        break;
    }
    case DxfKind::none:
    case DxfKind::insert:
        return;
    }

    pushEntity(*ctx.builder, e);
    ctx.emitted += 1;
}

std::vector<cad_point> flattenHatchLoop(const DRW_HatchLoop &loop) {
    std::vector<cad_point> ring;
    for (const std::shared_ptr<DRW_Entity> &edge : loop.objlist) {
        if (!edge) continue;
        if (auto *line = dynamic_cast<DRW_Line *>(edge.get())) {
            if (ring.empty()) ring.push_back({line->basePoint.x, line->basePoint.y});
            ring.push_back({line->secPoint.x, line->secPoint.y});
        } else if (auto *arc = dynamic_cast<DRW_Arc *>(edge.get())) {
            double sweep = arc->endangle - arc->staangle;
            while (sweep <= 0) sweep += kTwoPi;
            int steps = std::clamp(int(std::ceil(sweep / 0.15)), 4, 256);
            for (int i = 0; i <= steps; ++i) {
                double a = arc->staangle + sweep * (double(i) / double(steps));
                ring.push_back({arc->basePoint.x + arc->radious * std::cos(a),
                                arc->basePoint.y + arc->radious * std::sin(a)});
            }
        } else if (auto *ellipse = dynamic_cast<DRW_Ellipse *>(edge.get())) {
            double mx = ellipse->secPoint.x, my = ellipse->secPoint.y;
            double rotation = std::atan2(my, mx);
            double major = std::hypot(mx, my);
            double ratio = ellipse->ratio > 0 ? ellipse->ratio : 1.0;
            double span = ellipse->endparam - ellipse->staparam;
            int steps = std::clamp(int(std::ceil(std::abs(span) / 0.15)), 8, 256);
            for (int i = 0; i <= steps; ++i) {
                double t = ellipse->staparam + span * (double(i) / double(steps));
                double ux = std::cos(t) * major;
                double uy = std::sin(t) * major * ratio;
                ring.push_back({ellipse->basePoint.x + ux * std::cos(rotation)
                                    - uy * std::sin(rotation),
                                ellipse->basePoint.y + ux * std::sin(rotation)
                                    + uy * std::cos(rotation)});
            }
        } else if (auto *poly = dynamic_cast<DRW_LWPolyline *>(edge.get())) {
            cad_point previous{};
            bool first = true;
            for (const std::shared_ptr<DRW_Vertex2D> &vertex : poly->vertlist) {
                if (!vertex) continue;
                cad_point p = {vertex->x, vertex->y + poly->elevation};
                if (first) {
                    ring.push_back(p);
                    first = false;
                } else {
                    sampleBulge(ring, previous, p, vertex->bulge);
                }
                previous = p;
            }
        }
    }
    return ring;
}

std::string dxfVersionName(const std::string &acadver) {
    if (acadver == "AC1009") return "r12";
    if (acadver == "AC1012") return "r13";
    if (acadver == "AC1014") return "r14";
    if (acadver == "AC1015") return "r2000";
    if (acadver == "AC1018") return "r2004";
    if (acadver == "AC1021") return "r2007";
    if (acadver == "AC1024") return "r2010";
    if (acadver == "AC1027") return "r2013";
    if (acadver == "AC1032") return "r2018";
    return acadver.empty() ? "DXF" : acadver;
}

class DxfAdapter : public DRW_Interface {
public:
    explicit DxfAdapter(DxfLoad &ctx) : ctx_(ctx) {}

    void addHeader(const DRW_Header *data) override {
        if (!data) return;
        auto integer = [&](const char *key, int &out) {
            auto found = data->vars.find(key);
            if (found == data->vars.end() || !found->second) return;
            const DRW_Variant *value = found->second;
            if (value->type() == DRW_Variant::INTEGER) {
                out = int(value->content.i);
            } else if (value->type() == DRW_Variant::DOUBLE) {
                out = int(value->content.d);
            }
        };
        auto text = [&](const char *key, std::string &out) {
            auto found = data->vars.find(key);
            if (found == data->vars.end() || !found->second) return;
            const DRW_Variant *value = found->second;
            if (value->type() == DRW_Variant::STRING && value->content.s) {
                out = *value->content.s;
            }
        };
        integer("$INSUNITS", ctx_.units);
        std::string acadver;
        text("$ACADVER", acadver);
        ctx_.version = dxfVersionName(acadver);
    }

    void addLType(const DRW_LType &) override {}
    void addLayer(const DRW_Layer &data) override {
        int lw = -1;
        if (data.lWeight != DRW_LW_Conv::widthByLayer
            && data.lWeight != DRW_LW_Conv::widthByBlock
            && data.lWeight != DRW_LW_Conv::widthDefault) {
            lw = int(data.lWeight);
        }
        int flags = 0;
        if (!data.plotF) flags |= CAD_LAYER_OFF;
        if (data.flags & 1) flags |= CAD_LAYER_FROZEN;
        if (data.flags & 4) flags |= CAD_LAYER_LOCKED;
        int aci = data.color;
        if (aci < 0) {
            flags |= CAD_LAYER_OFF;
            aci = -aci;
        }
        ctx_.defineLayer(data.name, aci, data.color24 >= 0 ? data.color24 : -1,
                         lineweightMm(lw), flags);
    }
    void addDimStyle(const DRW_Dimstyle &) override {}
    void addVport(const DRW_Vport &) override {}
    void addTextStyle(const DRW_Textstyle &) override {}
    void addAppId(const DRW_AppId &) override {}

    // ---- blocks ----
    void addBlock(const DRW_Block &data) override {
        // 组码 70 第 4 位表示"外部参照"，组码 1 是参照路径。
        if ((data.flags & 4) || !data.xrefPath.empty()) ctx_.hasXref = true;
        std::string key = upperCase(data.name);
        ctx_.stack.push_back(key);
        ctx_.current = &ctx_.blocks[key];
    }
    void setBlock(int) override {}
    void endBlock() override {
        if (!ctx_.stack.empty()) ctx_.stack.pop_back();
        ctx_.current = ctx_.stack.empty() ? &ctx_.model
                                          : &ctx_.blocks[ctx_.stack.back()];
    }

    // ---- entities ----
    void addPoint(const DRW_Point &data) override {
        DxfItem item;
        item.kind = DxfKind::point;
        begin(item, data);
        item.cx = data.basePoint.x;
        item.cy = data.basePoint.y;
        push(item);
    }
    void addLine(const DRW_Line &data) override {
        DxfItem item;
        item.kind = DxfKind::line;
        begin(item, data);
        item.pts.push_back({data.basePoint.x, data.basePoint.y});
        item.pts.push_back({data.secPoint.x, data.secPoint.y});
        push(item);
    }
    void addRay(const DRW_Ray &data) override { line(data); }
    void addXline(const DRW_Xline &data) override { line(data); }
    void addCircle(const DRW_Circle &data) override {
        DxfItem item;
        item.kind = DxfKind::circle;
        begin(item, data);
        item.cx = data.basePoint.x;
        item.cy = data.basePoint.y;
        item.r = data.radious;
        push(item);
    }
    void addArc(const DRW_Arc &data) override {
        DxfItem item;
        item.kind = DxfKind::arc;
        begin(item, data);
        item.cx = data.basePoint.x;
        item.cy = data.basePoint.y;
        item.r = data.radious;
        item.a0 = data.staangle;
        item.a1 = data.endangle;
        push(item);
    }
    void addEllipse(const DRW_Ellipse &data) override {
        DxfItem item;
        item.kind = DxfKind::ellipse;
        begin(item, data);
        item.cx = data.basePoint.x;
        item.cy = data.basePoint.y;
        item.majorX = data.secPoint.x;
        item.majorY = data.secPoint.y;
        item.ratio = data.ratio > 0 ? data.ratio : 1.0;
        item.a0 = data.staparam;
        item.a1 = data.endparam;
        push(item);
    }
    void addLWPolyline(const DRW_LWPolyline &data) override {
        DxfItem item;
        item.kind = DxfKind::polyline;
        begin(item, data);
        const bool closed = (data.flags & 1) != 0;
        if (closed) item.flags |= CAD_FLAG_CLOSED;
        std::vector<cad_point> pts;
        cad_point previous{};
        bool first = true;
        for (const std::shared_ptr<DRW_Vertex2D> &vertex : data.vertlist) {
            if (!vertex) continue;
            cad_point p = {vertex->x, vertex->y + data.elevation};
            if (first) {
                pts.push_back(p);
                first = false;
            } else {
                sampleBulge(pts, previous, p, vertex->bulge);
            }
            previous = p;
        }
        if (closed && pts.size() > 2 && !data.vertlist.empty()
            && data.vertlist.front()
            && std::abs(data.vertlist.front()->bulge) > 1e-9) {
            sampleBulge(pts, previous, pts.front(), data.vertlist.front()->bulge);
        }
        if (pts.size() < 2) return;
        item.pts = std::move(pts);
        push(item);
    }
    void addPolyline(const DRW_Polyline &data) override {
        DxfItem item;
        item.kind = DxfKind::polyline;
        begin(item, data);
        const bool closed = (data.flags & 1) != 0;
        if (closed) item.flags |= CAD_FLAG_CLOSED;
        std::vector<cad_point> pts;
        cad_point previous{};
        bool first = true;
        for (const std::shared_ptr<DRW_Vertex> &vertex : data.vertlist) {
            if (!vertex) continue;
            cad_point p = {vertex->basePoint.x, vertex->basePoint.y};
            if (first) {
                pts.push_back(p);
                first = false;
            } else {
                sampleBulge(pts, previous, p, vertex->bulge);
            }
            previous = p;
        }
        if (closed && pts.size() > 2 && !data.vertlist.empty()
            && data.vertlist.front()
            && std::abs(data.vertlist.front()->bulge) > 1e-9) {
            sampleBulge(pts, previous, pts.front(), data.vertlist.front()->bulge);
        }
        if (pts.size() < 2) return;
        item.pts = std::move(pts);
        push(item);
    }
    void addSpline(const DRW_Spline *data) override {
        if (!data) return;
        DxfItem item;
        item.kind = DxfKind::polyline;
        begin(item, *data);
        bool usingFitPoints = false;
        std::vector<cad_point> control;
        for (const std::shared_ptr<DRW_Coord> &point : data->controllist) {
            if (point) control.push_back({point->x, point->y});
        }
        if (control.size() < 2) {
            usingFitPoints = true;
            for (const std::shared_ptr<DRW_Coord> &point : data->fitlist) {
                if (point) control.push_back({point->x, point->y});
            }
        }
        if (control.size() < 2) return;
        std::vector<double> knots(data->knotslist.begin(), data->knotslist.end());
        const std::vector<double> weights(data->weightlist.begin(), data->weightlist.end());
        const bool closed = (data->flags & 1) != 0;
        item.pts = sampleSpline(std::max(1, int(data->degree)), control, knots,
                                weights, usingFitPoints);
        if (closed) item.flags |= CAD_FLAG_CLOSED;
        if (item.pts.size() < 2) return;
        push(item);
    }
    void addKnot(const DRW_Entity &) override {}
    void addInsert(const DRW_Insert &data) override {
        DxfItem item;
        item.kind = DxfKind::insert;
        begin(item, data);
        item.block = data.name;
        item.insertX = data.basePoint.x;
        item.insertY = data.basePoint.y;
        item.scaleX = data.xscale;
        item.scaleY = data.yscale;
        item.insertRotation = data.angle;
        item.columns = data.colcount;
        item.rows = data.rowcount;
        item.columnSpace = data.colspace;
        item.rowSpace = data.rowspace;
        push(item);

        // Attribute values sit on top of the block geometry.
        for (const std::shared_ptr<DRW_Attrib> &attrib : data.attlist) {
            if (!attrib || attrib->text.empty()) continue;
            DxfItem text;
            text.kind = DxfKind::text;
            begin(text, *attrib);
            text.cx = attrib->basePoint.x;
            text.cy = attrib->basePoint.y;
            text.height = attrib->height;
            text.rot = attrib->angle * kPi / 180.0;
            text.widthScale = attrib->widthscale > 0 ? attrib->widthscale : 1.0;
            text.halign = int(attrib->alignH);
            text.valign = int(attrib->alignV);
            text.text = cleanText(attrib->text);
            if (text.text.empty()) continue;
            push(text);
        }
    }
    void addTrace(const DRW_Trace &data) override { solid(data); }
    void add3dFace(const DRW_3Dface &data) override { solid(data); }
    void addSolid(const DRW_Solid &data) override { solid(data); }
    void addMText(const DRW_MText &data) override {
        DxfItem item;
        item.kind = DxfKind::text;
        begin(item, data);
        item.flags |= CAD_FLAG_MTEXT;
        item.cx = data.basePoint.x;
        item.cy = data.basePoint.y;
        item.height = data.height;
        item.rot = data.angle * kPi / 180.0;
        // Code 41 on an MTEXT is its reference-rectangle width, not a width
        // factor: libdxfrw routes it into DRW_Text::widthscale, so it has to be
        // dropped here or the text gets drawn stretched.
        item.widthScale = 1.0;
        item.text = cleanMText(data.text);
        while (!item.text.empty()
               && (item.text.back() == '\n' || item.text.back() == ' ')) {
            item.text.pop_back();
        }
        if (item.text.empty()) return;
        const int attach = std::clamp(int(data.alignV), 1, 9);
        item.halign = (attach - 1) % 3;
        // MTEXT attach 1..3 = top, 4..6 = middle, 7..9 = bottom。文本渲染器
        // 用的是 TEXT 的 valign（0 baseline/1 bottom/2 middle/3 top），不转换
        // 就会把 MTEXT 的字母整体抬高/压低半个字高。
        item.valign = 3 - (attach - 1) / 3;
        push(item);
    }
    void addText(const DRW_Text &data) override {
        DxfItem item;
        item.kind = DxfKind::text;
        begin(item, data);
        item.cx = data.basePoint.x;
        item.cy = data.basePoint.y;
        item.height = data.height;
        item.rot = data.angle * kPi / 180.0;
        item.widthScale = data.widthscale > 0 ? data.widthscale : 1.0;
        item.text = cleanText(data.text);
        if (item.text.empty()) return;
        item.halign = int(data.alignH);
        item.valign = int(data.alignV);
        // Aligned / middle / fit text is positioned by the second point.
        if (data.alignH == 4) {
            // middle：以第二点为中心，水平和垂直都居中。
            item.cx = data.secPoint.x;
            item.cy = data.secPoint.y;
            item.halign = 1;
            item.valign = 2;
        } else if (data.alignH == 3 || data.alignH == 5) {
            // aligned / fit：从第一点起排。宽度拉伸没有字体度量无法在这里
            // 精确做，但起点必须用 basePoint；用 secPoint 会把整串字母右移。
            item.cx = data.basePoint.x;
            item.cy = data.basePoint.y;
            item.halign = 0;
            item.valign = 0;
        } else if (data.alignH >= 3) {
            item.cx = data.secPoint.x;
            item.cy = data.secPoint.y;
            item.halign = 0;
            item.valign = 0;
        }
        push(item);
    }
    void addDimAlign(const DRW_DimAligned *data) override { dimension(data); }
    void addDimLinear(const DRW_DimLinear *data) override { dimension(data); }
    void addDimRadial(const DRW_DimRadial *data) override { dimension(data); }
    void addDimDiametric(const DRW_DimDiametric *data) override { dimension(data); }
    void addDimAngular(const DRW_DimAngular *data) override { dimension(data); }
    void addDimAngular3P(const DRW_DimAngular3p *data) override { dimension(data); }
    void addDimOrdinate(const DRW_DimOrdinate *data) override { dimension(data); }
    void addLeader(const DRW_Leader *) override {}
    void addHatch(const DRW_Hatch *data) override {
        if (!data) return;
        DxfItem item;
        item.kind = DxfKind::hatch;
        begin(item, *data);
        item.solidFill = data->solid != 0;
        item.hatchStyle = data->hstyle;
        item.hatchAngle = data->angle * kPi / 180.0;
        item.hatchScale = data->scale > 0 ? data->scale : 1.0;
        for (const std::shared_ptr<DRW_HatchLoop> &loop : data->looplist) {
            if (!loop) continue;
            std::vector<cad_point> ring = flattenHatchLoop(*loop);
            if (ring.size() > 2) item.rings.push_back(std::move(ring));
        }
        if (item.rings.empty()) return;
        for (const DRW_Hatch::PatternLine &line : data->patternLines) {
            DxfPatternLine pattern;
            pattern.angle = line.angle * kPi / 180.0;
            pattern.baseX = line.baseX;
            pattern.baseY = line.baseY;
            pattern.offsetX = line.offsetX;
            pattern.offsetY = line.offsetY;
            pattern.dashes = line.dashList;
            item.pattern.push_back(std::move(pattern));
        }
        push(item);
    }
    void addViewport(const DRW_Viewport &) override {}
    void addImage(const DRW_Image *) override {}
    void linkImage(const DRW_ImageDef *) override {}
    void addComment(const char *) override {}

    void writeHeader(DRW_Header &) override {}
    void writeBlocks() override {}
    void writeBlockRecords() override {}
    void writeEntities() override {}
    void writeLTypes() override {}
    void writeLayers() override {}
    void writeTextstyles() override {}
    void writeVports() override {}
    void writeDimstyles() override {}
    void writeObjects() override {}
    void writeAppId() override {}

private:
    void begin(DxfItem &item, const DRW_Entity &data) {
        item.layer = data.layer.empty() ? "0" : data.layer;
        item.aci = data.color;
        item.rgb = data.color24;
        if (data.lWeight == DRW_LW_Conv::widthByBlock) {
            item.lw = -2;
        } else if (data.lWeight == DRW_LW_Conv::widthByLayer
                   || data.lWeight == DRW_LW_Conv::widthDefault) {
            item.lw = -1;
        } else {
            item.lw = int(data.lWeight);
        }
        item.visible = data.visible;
        item.paper = data.space == DRW::PaperSpace;
    }

    void push(DxfItem &item) { ctx_.push(item); }

    void line(const DRW_Line &data) {
        DxfItem item;
        item.kind = DxfKind::line;
        begin(item, data);
        item.pts.push_back({data.basePoint.x, data.basePoint.y});
        item.pts.push_back({data.secPoint.x, data.secPoint.y});
        push(item);
    }

    void solid(const DRW_Trace &data) {
        DxfItem item;
        item.kind = DxfKind::solid;
        begin(item, data);
        // DXF stores the four corners in "Z" order: 1, 2, 4, 3.
        item.pts.push_back({data.basePoint.x, data.basePoint.y});
        item.pts.push_back({data.secPoint.x, data.secPoint.y});
        item.pts.push_back({data.fourPoint.x, data.fourPoint.y});
        item.pts.push_back({data.thirdPoint.x, data.thirdPoint.y});
        item.flags |= CAD_FLAG_FILLED;
        push(item);
    }

    void dimension(const DRW_Dimension *data) {
        if (!data) return;
        // getName() is not const in libdxfrw although it only reads a field.
        std::string block = const_cast<DRW_Dimension *>(data)->getName();
        if (block.empty()) return;
        // The measured geometry lives in an anonymous block that is already in
        // world coordinates, so it is referenced with an identity transform.
        DxfItem item;
        item.kind = DxfKind::insert;
        begin(item, *data);
        item.block = block;
        item.insertX = 0;
        item.insertY = 0;
        item.scaleX = 1;
        item.scaleY = 1;
        item.insertRotation = 0;
        push(item);
    }

    DxfLoad &ctx_;
};

bool loadDxfFast(const char *path, cad_doc *doc, std::string &error) {
    Builder builder;
    builder.doc = doc;
    DxfLoad ctx;
    ctx.doc = doc;
    ctx.builder = &builder;

    const auto readStart = std::chrono::steady_clock::now();
    // Layer "0" always exists and is listed first, matching the DWG path.
    ctx.ensureLayer("0");
    DxfAdapter adapter(ctx);
    dxfRW reader(path);
    // libdxfrw 默认 4M 条记录的安全预算大约只够 35 万图元；工业化图纸
    // （50 万图元/55MB）会在读到一半时被预算截断，然后回退到 LibreDWG 的
    // O(n²) DXF 导入器，几十分钟都打不开。这里把预算抬到 3200 万条记录
    // （约 200 万图元），仍保留上限防止恶意/损坏文件无限读。
    reader.setDxfReadRecordBudget(32u * 1024u * 1024u);
    const bool ok = reader.read(&adapter, true);
    if (getenv("CADCORE_PROFILE")) {
        const auto ms = std::chrono::duration<double, std::milli>(
            std::chrono::steady_clock::now() - readStart).count();
        fprintf(stderr, "[cadcore] libdxfrw read: %.1f ms, %zu model items, %zu blocks\n",
                ms, ctx.model.size(), ctx.blocks.size());
    }
    if (!ok) {
        DRW_OperationDiagnostic diagnostic = reader.getLastDiagnostic();
        if (!diagnostic.message.empty()) {
            error = "libdxfrw: " + diagnostic.message;
            if (diagnostic.hasOffset) {
                error += " @" + std::to_string(diagnostic.offset);
            }
        } else {
            error = "libdxfrw 无法解析该 DXF";
        }
        return false;
    }
    if (ctx.hasXref) {
        // 参照要跟主图一起渲染，这条快路做不到；让调用方改走 LibreDWG。
        error = "DXF 含外部参照，改用 LibreDWG 合并";
        return false;
    }

    const std::vector<DxfItem> *modelItems = &ctx.model;
    if (ctx.model.empty()) {
        auto found = ctx.blocks.find("*MODEL_SPACE");
        if (found != ctx.blocks.end()) modelItems = &found->second;
    }

    ctx.ensureLayer("0");
    int modelSpace = addSpace(doc, builder, "模型", 0);    for (const DxfItem &item : *modelItems) {
        if (ctx.emitted >= int(kMaxEntities)) break;
        Affine identity;
        emitItem(ctx, item, modelSpace, identity, 7, 0xFFFFFF, -1, 0);
    }
    finishSpace(doc, modelSpace);

    if (!ctx.paper.empty()) {
        int index = addSpace(doc, builder, "图纸", 1);
        for (const DxfItem &item : ctx.paper) {
            if (ctx.emitted >= int(kMaxEntities)) break;
            Affine identity;
            emitItem(ctx, item, index, identity, 7, 0xFFFFFF, -1, 0);
        }
        finishSpace(doc, index);
    }

    doc->skipped += ctx.skipped;
    if (getenv("CADCORE_PROFILE")) {
        const auto ms = std::chrono::duration<double, std::milli>(
            std::chrono::steady_clock::now() - readStart).count();
        fprintf(stderr, "[cadcore] libdxfrw emit: %.1f ms total, %d entities, %zu points\n",
                ms, ctx.emitted, doc->points.size());
    }
    if (doc->entities.empty()) {
        error = "DXF 中没有可显示的图元";
        return false;
    }
    doc->version = ctx.version.empty() ? "DXF" : ctx.version;
    doc->unitMeters = unitMetersFor(ctx.units);
    doc->backend = "libdxfrw (DXF)";
    if (doc->entities.size() >= kMaxEntities) doc->truncated = 1;
    return true;
}

}  // namespace

// ---------------------------------------------------------------- entry points

extern "C" cad_doc *cad_doc_load(const char *path, char **error_out) {
    if (error_out) *error_out = nullptr;
    if (!path) {
        if (error_out) *error_out = strdup("empty path");
        return nullptr;
    }
    const auto started = std::chrono::steady_clock::now();

    const char *dot = strrchr(path, '.');
    bool isDxf = false;
    if (dot) {
        std::string ext(dot);
        for (char &c : ext) c = char(tolower(c));
        isDxf = ext == ".dxf";
    }

    // DXF goes through libdxfrw first: its reader is linear, where LibreDWG's
    // DXF importer is quadratic in the entity count. CADCORE_NO_DXFRW forces
    // the LibreDWG path so the two can be compared.
    if (isDxf && !getenv("CADCORE_NO_DXFRW")) {
        cad_doc *fast = new cad_doc();
        std::string fastError;
        if (loadDxfFast(path, fast, fastError)) {
            fast->loadMs = std::chrono::duration<double, std::milli>(
                std::chrono::steady_clock::now() - started).count();
            return fast;
        }
        delete fast;
        if (getenv("CADCORE_PROFILE")) {
            fprintf(stderr, "[cadcore] libdxfrw failed (%s), falling back to libredwg\n",
                    fastError.c_str());
        }
        // 大 DXF 不要回退 LibreDWG：它的 DXF 导入是 O(n²)，55MB/50 万
        // 图元的文件会卡几十分钟且没有进度。超过 16MB 直接报错，至少
        // 用户能立刻看到“这个 DXF 没读进来”，而不是应用假死。
        struct stat st {};
        if (stat(path, &st) == 0 && st.st_size > 16 * 1024 * 1024) {
            if (error_out) {
                *error_out = strdup(("DXF 过大且快速解析失败：" + fastError
                                     + "（已拒绝回退到慢速 LibreDWG 导入）").c_str());
            }
            return nullptr;
        }
    }

    Dwg_Data *dwg = static_cast<Dwg_Data *>(calloc(1, sizeof(Dwg_Data)));
    if (!dwg) {
        if (error_out) *error_out = strdup("out of memory");
        return nullptr;
    }

    // A stale recent-document entry or a moved file used to surface as an empty
    // sheet labelled "invalid"; fail loudly instead.
    struct stat fileInfo;
    if (stat(path, &fileInfo) != 0 || !S_ISREG(fileInfo.st_mode)) {
        if (error_out) {
            char message[512];
            snprintf(message, sizeof(message), "找不到图纸文件：%s", path);
            *error_out = strdup(message);
        }
        dwg_free(dwg);
        free(dwg);
        return nullptr;
    }

    const auto readStart = std::chrono::steady_clock::now();
    int result = -1;
    if (isDxf) {
        result = dxf_read_file(path, dwg);
    } else {
        result = dwg_read_file(path, dwg);
    }
    const bool profile = getenv("CADCORE_PROFILE") != nullptr;
    if (profile) {
        const auto ms = std::chrono::duration<double, std::milli>(
            std::chrono::steady_clock::now() - readStart).count();
        fprintf(stderr, "[cadcore] read %s: %.1f ms, %u objects\n",
                isDxf ? "DXF" : "DWG", ms, (unsigned)dwg->num_objects);
    }
    if (result < 0) {
        char message[512];
        snprintf(message, sizeof(message), "无法解析图纸（%s，错误码 %d）",
                 isDxf ? "DXF" : "DWG", result);
        if (error_out) *error_out = strdup(message);
        dwg_free(dwg);
        free(dwg);
        return nullptr;
    }
    if (dwg->num_objects == 0) {
        if (error_out) {
            *error_out = strdup("图纸中没有可读取的对象，文件可能已损坏或不是有效的 CAD 图纸");
        }
        dwg_free(dwg);
        free(dwg);
        return nullptr;
    }

    cad_doc *doc = new cad_doc();
    Builder builder;
    builder.doc = doc;
    builder.dwg = dwg;
    // 找不到参照时按这个路径去同目录里找（见 xrefDocumentFor）。
    builder.sourcePath = path;
    builder.attributeMode = int(dwg->header_vars.ATTMODE);
    {
        // Same source as the reference reader: the drawing extent declared in
        // the header, so XLINE/RAY and MLINE offsets are bounded by the sheet
        // rather than by a hard-coded constant.
        const double ex = dwg->header_vars.EXTMAX.x - dwg->header_vars.EXTMIN.x;
        const double ey = dwg->header_vars.EXTMAX.y - dwg->header_vars.EXTMIN.y;
        if (std::isfinite(ex) && std::isfinite(ey) && ex > 0.0 && ey > 0.0) {
            builder.referenceExtent = std::hypot(ex, ey);
        }
        const double x0 = dwg->header_vars.EXTMIN.x, y0 = dwg->header_vars.EXTMIN.y;
        const double x1 = dwg->header_vars.EXTMAX.x, y1 = dwg->header_vars.EXTMAX.y;
        if (std::isfinite(x0) && std::isfinite(y0) && std::isfinite(x1)
            && std::isfinite(y1) && x1 > x0 && y1 > y0) {
            doc->declaredBox = {std::min(x0, x1), std::min(y0, y1),
                                std::max(x0, x1), std::max(y0, y1)};
            if (getenv("CADCORE_VIEW_DEBUG")) {
                fprintf(stderr, "[extents] declared=(%g,%g)-(%g,%g)\n",
                        doc->declaredBox.minx, doc->declaredBox.miny,
                        doc->declaredBox.maxx, doc->declaredBox.maxy);
            }
        }
    }

    // One linear pass builds both indexes. An ATTRIB's ownerhandle points at
    // the INSERT that carries its value, not at the block definition, so the
    // key is the INSERT's own handle (dwg handle values are absolute refs).
    for (BITCODE_BL i = 0; i < dwg->num_objects; ++i) {
        Dwg_Object *object = &dwg->object[i];
        builder.objectByHandle[object->handle.value] = object;
        if (object->fixedtype == DWG_TYPE_ATTRIB && object->tio.entity) {
            ++builder.attrSource;
            if ((object->tio.entity->invisible & 1) == 0) {
                ++builder.attrVisible;
            }
            if (object->tio.entity->ownerhandle) {
                builder.attributesByOwner[
                    object->tio.entity->ownerhandle->absolute_ref]
                    .push_back(object);
            }
        }
    }

    buildLayers(builder);
    readSavedView(builder);
    // Must run before any block is expanded: the clip polygons are looked up by
    // the INSERT's handle while its children are being converted.
    indexSpatialFilters(builder);

    std::vector<Dwg_Object *> headers;
    collectBlockHeaders(builder, headers);

    Dwg_Object *modelHeader = nullptr;
    std::unordered_map<uint64_t, Dwg_Object *> headerByHandle;
    for (Dwg_Object *bh : headers) {
        headerByHandle[bh->handle.value] = bh;
        std::string name = blockName(dwg, bh);
        if (name == "*Model_Space" || name == "$MODEL_SPACE"
            || name == "*MODEL_SPACE" || name == "MODEL_SPACE") {
            modelHeader = bh;
        }
    }

    int modelSpace = addSpace(doc, builder, "模型", 0);
    if (modelHeader) {
        Affine identity;
        expandBlock(builder, modelHeader, modelSpace, identity, -1, 0xFFFFFF, 7, 0, 0);
    }
    finishSpace(doc, modelSpace);

    // Layouts in tab order.
    struct LayoutEntry {
        Dwg_Object *layout;
        std::string name;
        Dwg_Object *block;
        int tabOrder;
    };
    std::vector<LayoutEntry> layouts;
    for (BITCODE_BL i = 0; i < dwg->num_objects; ++i) {
        Dwg_Object *obj = &dwg->object[i];
        if (obj->fixedtype != DWG_TYPE_LAYOUT || !obj->tio.object) continue;
        Dwg_Object_LAYOUT *layout = obj->tio.object->tio.LAYOUT;
        if (!layout) continue;
        LayoutEntry entry{obj, toUtf8(dwg, layout->layout_name), nullptr,
                          layout->tab_order};
        if (layout->block_header) {
            Dwg_Object *bh = dwg_ref_object(dwg, layout->block_header);
            if (bh) entry.block = bh;
        }
        if (!entry.block) continue;
        if (entry.block == modelHeader) continue;
        if (entry.name.empty()) continue;
        layouts.push_back(entry);
    }
    std::sort(layouts.begin(), layouts.end(),
              [](const LayoutEntry &a, const LayoutEntry &b) {
                  return a.tabOrder < b.tabOrder;
              });

    for (const LayoutEntry &entry : layouts) {
        int index = addSpace(doc, builder, entry.name, 1);
        Affine identity;
        expandBlock(builder, entry.block, index, identity, -1, 0xFFFFFF, 7, 0, 0);

        Dwg_Object_LAYOUT *layout = entry.layout->tio.object->tio.LAYOUT;
        // VIEWPORT entities are owned by the layout's block record. The
        // LAYOUT.viewports array is not always populated (layouts that only
        // keep block-owned viewports would otherwise lose every one of them),
        // so walk the owned list exactly like the reference reader.
        std::vector<Dwg_Object *> viewportObjects;
        Dwg_Object_BLOCK_HEADER *layoutBlock =
            entry.block->tio.object
                ? entry.block->tio.object->tio.BLOCK_HEADER : nullptr;
        if (layoutBlock && layoutBlock->entities && layoutBlock->num_owned > 0) {
            for (BITCODE_BL v = 0; v < layoutBlock->num_owned; ++v) {
                Dwg_Object *candidate =
                    dwg_ref_object(dwg, layoutBlock->entities[v]);
                if (candidate && candidate->tio.entity
                    && candidate->fixedtype == DWG_TYPE_VIEWPORT) {
                    viewportObjects.push_back(candidate);
                }
            }
        }
        if (viewportObjects.empty() && layout && layout->num_viewports > 0
            && layout->viewports) {
            for (BITCODE_BL v = 0; v < layout->num_viewports; ++v) {
                Dwg_Object *candidate = dwg_ref_object(dwg, layout->viewports[v]);
                if (candidate && candidate->tio.entity) {
                    viewportObjects.push_back(candidate);
                }
            }
        }

        for (Dwg_Object *vobj : viewportObjects) {
            Dwg_Entity_VIEWPORT *vp = vobj->tio.entity->tio.VIEWPORT;
            if (!vp || vp->width <= 1.0e-9 || vp->height <= 1.0e-9
                || vp->VIEWSIZE <= 1.0e-9) continue;
            cad_viewport out{};
            out.space = index;
            out.id = int(vp->id);
            // DXF group 68: 0 = off, -1 / >0 = on. `status_flag` is a
            // different UCS-related bitfield and must not gate display.
            // Non-active viewports are still drawn in a paper layout.
            out.status = int(vp->on_off);
            out.cx = vp->center.x;
            out.cy = vp->center.y;
            out.width = vp->width;
            out.height = vp->height;
            double modelCx = vp->VIEWCTR.x;
            double modelCy = vp->VIEWCTR.y;
            // The overall paper viewport has a 1:1 centre and view height;
            // viewport ids are not unique in real drawings.
            const double centreDistance = std::hypot(
                vp->center.x - modelCx, vp->center.y - modelCy);
            const bool paperViewport =
                centreDistance <= std::max(1.0, vp->VIEWSIZE) * 1.0e-9
                && std::abs(vp->VIEWSIZE - vp->height)
                   <= std::max(1.0, vp->height) * 1.0e-9;
            // VIEWCTR (DXF 12/22) is in the view's DCS. For a twisted view
            // the stored centre has to be rotated back by -twist, otherwise
            // the viewport looks at an empty model region.
            if (!paperViewport && std::abs(vp->VIEWTWIST) > 1.0e-12) {
                const double theta = -vp->VIEWTWIST;
                const double ct = std::cos(theta);
                const double st = std::sin(theta);
                const double rx = modelCx * ct - modelCy * st;
                const double ry = modelCx * st + modelCy * ct;
                modelCx = rx;
                modelCy = ry;
            }
            out.model_cx = modelCx;
            out.model_cy = modelCy;
            out.model_height = vp->VIEWSIZE;
            out.twist = vp->VIEWTWIST;
            // VPLAYER: layers frozen only inside this viewport. Resolve the
            // layer handles to indices once at load time.
            out.frozen_start = int32_t(doc->frozenLayers.size());
            if (!paperViewport && vp->frozen_layers
                && vp->num_frozen_layers > 0) {
                for (BITCODE_BL f = 0; f < vp->num_frozen_layers; ++f) {
                    const int frozen = builder.layerIndexFor(vp->frozen_layers[f]);
                    if (frozen >= 0) {
                        doc->frozenLayers.push_back(int32_t(frozen));
                    }
                }
            }
            out.frozen_count = int32_t(doc->frozenLayers.size())
                               - out.frozen_start;
            out.clip = {out.cx - out.width / 2, out.cy - out.height / 2,
                        out.cx + out.width / 2, out.cy + out.height / 2};
            doc->viewports.push_back(out);
        }
        finishSpace(doc, index);
        // LAYOUT.EXTMIN/EXTMAX is the paper window the designer framed the
        // layout with. The entity union is only a fallback: blocks parked
        // outside the paper (or detail strips dragged off the sheet) inflate it
        // and the layout then opens zoomed out past the actual drawing.
        Dwg_Object_LAYOUT *layoutView =
            entry.layout->tio.object ? entry.layout->tio.object->tio.LAYOUT
                                     : nullptr;
        if (layoutView) {
            const double ex0 = layoutView->EXTMIN.x;
            const double ey0 = layoutView->EXTMIN.y;
            const double ex1 = layoutView->EXTMAX.x;
            const double ey1 = layoutView->EXTMAX.y;
            cad_space &space = doc->spaces[size_t(index)];
            const double unionWidth = space.box.maxx - space.box.minx;
            const double unionHeight = space.box.maxy - space.box.miny;
            const bool sane = std::isfinite(ex0) && std::isfinite(ey0)
                && std::isfinite(ex1) && std::isfinite(ey1)
                && ex1 > ex0 && ey1 > ey0
                && (ex1 - ex0) <= unionWidth * 4.0 + 1.0
                && (ey1 - ey0) <= unionHeight * 4.0 + 1.0;
            if (sane) {
                space.box = {ex0, ey0, ex1, ey1};
            }
        }
    }

    doc->version = std::string(dwg_version_type(dwg->header.version));
    doc->backend = isDxf ? "libredwg (DXF)" : "libredwg (DWG)";
    if (doc->entities.size() >= kMaxEntities) doc->truncated = 1;
    if (doc->entities.empty()
        && (doc->version.empty() || doc->version == "invalid")) {
        if (error_out) {
            *error_out = strdup("图纸中没有可读取的对象，文件可能已损坏或不是有效的 CAD 图纸");
        }
        builder.freeXrefs();
        dwg_free(dwg);
        free(dwg);
        delete doc;
        return nullptr;
    }

    if (getenv("CADCORE_TYPES")) {
        fprintf(stderr,
                "[cadcore] attributeAudit mode=%d source=%d visible=%d "
                "rendered=%d suppressed=%d indexedOwners=%zu\n",
                builder.attributeMode, builder.attrSource, builder.attrVisible,
                builder.attrRendered, builder.attrSuppressed,
                builder.attributesByOwner.size());
        fprintf(stderr,
                "[cadcore] drop audit: emptyBox=%d invisible=%d depth=%d "
                "budget=%d\n",
                builder.dropEmpty, builder.dropInvisible, builder.dropDepth,
                builder.dropBudget);
        for (const auto &row : builder.dropByKind) {
            fprintf(stderr, "    dropped kind %d %8d\n", row.first, row.second);
        }
        fprintf(stderr,
                "[cadcore] dimensions: total=%d expandedBlock=%d noBlock=%d "
                "children=%d invisibleChildren=%d\n",
                builder.dimTotal, builder.dimExpanded, builder.dimNoBlock,
                builder.dimBlockChildren, builder.dimInvisibleChildren);
        for (const auto &row : builder.dimChildKinds) {
            fprintf(stderr, "    dim child kind %d %8d\n", row.first, row.second);
        }
        fprintf(stderr, "[cadcore] block children: chainOnly=%d arrayOnly=%d\n",
                builder.blockChainVisits, builder.blockArrayVisits);
        fprintf(stderr, "[cadcore] xclip: filters=%d clippedEntities=%d\n",
                builder.clipsIndexed, builder.clipDropped);
        std::vector<std::pair<int, int>> rows(builder.typeCount.begin(),
                                              builder.typeCount.end());
        std::sort(rows.begin(), rows.end(),
                  [](const std::pair<int, int> &a, const std::pair<int, int> &b) {
                      return a.second > b.second;
                  });
        fprintf(stderr, "[cadcore] converted entity types:\n");
        for (const auto &row : rows) {
            fprintf(stderr, "    type %-4d %8d\n", row.first, row.second);
        }
        std::unordered_map<int, int> rawTypes;
        for (BITCODE_BL i = 0; i < dwg->num_objects; ++i) {
            rawTypes[int(dwg->object[i].fixedtype)] += 1;
        }
        fprintf(stderr, "[cadcore] raw DWG objects: %u\n",
                (unsigned)dwg->num_objects);
        for (const auto &row : rawTypes) {
            const int converted = builder.typeCount.count(row.first)
                                      ? builder.typeCount[row.first] : 0;
            if (row.first == int(DWG_TYPE_TEXT)
                || row.first == int(DWG_TYPE_ATTRIB)
                || row.first == int(DWG_TYPE_MTEXT)
                || converted != row.second) {
                fprintf(stderr, "    raw type %-4d %8d  converted %8d\n",
                        row.first, row.second, converted);
            }
        }
    }

    int units = 4;
    if (dwg->header_vars.INSUNITS) units = int(dwg->header_vars.INSUNITS);
    doc->unitMeters = unitMetersFor(units);

    const auto ended = std::chrono::steady_clock::now();
    doc->loadMs = std::chrono::duration<double, std::milli>(ended - started).count();

    // 参照子文档只是取几何用，图元/点/文字都已拷进主文档，这里可以整批释放。
    const int xrefBound = builder.xrefBound;
    const size_t xrefDocs = builder.xrefDocs.size();
    builder.freeXrefs();
    if (getenv("CADCORE_XREF_LOG")) {
        fprintf(stderr, "[cadcore] xref: bound=%d docs=%zu inserts=%zu missing=%d "
                "entities=%zu\n",
                xrefBound, xrefDocs, doc->xrefInserts.size(), doc->skipped,
                doc->entities.size());
    }
    dwg_free(dwg);
    free(dwg);
    return doc;
}

extern "C" void cad_doc_free(cad_doc *doc) { delete doc; }

extern "C" const char *cad_doc_version(const cad_doc *doc) {
    return doc ? doc->version.c_str() : "";
}
extern "C" const char *cad_doc_backend(const cad_doc *doc) {
    return doc ? doc->backend.c_str() : "";
}
extern "C" double cad_doc_load_ms(const cad_doc *doc) { return doc ? doc->loadMs : 0; }

extern "C" int32_t cad_doc_entity_count(const cad_doc *doc) {
    return doc ? int32_t(doc->entities.size()) : 0;
}
extern "C" const cad_entity *cad_doc_entities(const cad_doc *doc) {
    return doc && !doc->entities.empty() ? doc->entities.data() : nullptr;
}
extern "C" int32_t cad_doc_point_count(const cad_doc *doc) {
    return doc ? int32_t(doc->points.size()) : 0;
}
extern "C" const cad_point *cad_doc_points(const cad_doc *doc) {
    return doc && !doc->points.empty() ? doc->points.data() : nullptr;
}
extern "C" int32_t cad_doc_ring_count(const cad_doc *doc) {
    return doc ? int32_t(doc->rings.size()) : 0;
}
extern "C" const cad_ring *cad_doc_rings(const cad_doc *doc) {
    return doc && !doc->rings.empty() ? doc->rings.data() : nullptr;
}
extern "C" int32_t cad_doc_hatch_count(const cad_doc *doc) {
    return doc ? int32_t(doc->hatches.size()) : 0;
}
extern "C" const cad_hatch *cad_doc_hatches(const cad_doc *doc) {
    return doc && !doc->hatches.empty() ? doc->hatches.data() : nullptr;
}
extern "C" double cad_hatch_dash(const cad_hatch *hatch, int32_t family,
                                 int32_t index) {
    if (!hatch || family < 0 || family >= 8 || index < 0) return 0.0;
    if (index >= hatch->def_ndashes[family]) return 0.0;
    const int32_t at = hatch->def_dash_start[family] + index;
    if (at < 0 || at >= 128) return 0.0;
    return hatch->dashes[at];
}
extern "C" int32_t cad_doc_layer_count(const cad_doc *doc) {
    return doc ? int32_t(doc->layers.size()) : 0;
}
extern "C" const cad_layer *cad_doc_layers(const cad_doc *doc) {
    return doc && !doc->layers.empty() ? doc->layers.data() : nullptr;
}
extern "C" int32_t cad_doc_space_count(const cad_doc *doc) {
    return doc ? int32_t(doc->spaces.size()) : 0;
}
extern "C" const cad_space *cad_doc_spaces(const cad_doc *doc) {
    return doc && !doc->spaces.empty() ? doc->spaces.data() : nullptr;
}
extern "C" int32_t cad_doc_viewport_count(const cad_doc *doc) {
    return doc ? int32_t(doc->viewports.size()) : 0;
}
extern "C" const cad_viewport *cad_doc_viewports(const cad_doc *doc) {
    return doc && !doc->viewports.empty() ? doc->viewports.data() : nullptr;
}
extern "C" cad_saved_view cad_doc_saved_view(const cad_doc *doc) {
    return doc ? doc->savedView : cad_saved_view{};
}
extern "C" cad_bbox cad_doc_declared_box(const cad_doc *doc) {
    return doc ? doc->declaredBox : cad_bbox{1.0, 1.0, -1.0, -1.0};
}
extern "C" int32_t cad_doc_frozen_layer_count(const cad_doc *doc) {
    return doc ? int32_t(doc->frozenLayers.size()) : 0;
}
extern "C" const int32_t *cad_doc_frozen_layers(const cad_doc *doc) {
    return doc && !doc->frozenLayers.empty() ? doc->frozenLayers.data() : nullptr;
}
extern "C" int32_t cad_doc_block_layer_count(const cad_doc *doc) {
    return doc ? int32_t(doc->blockLayers.size()) : 0;
}
extern "C" const int32_t *cad_doc_block_layers(const cad_doc *doc) {
    return doc && !doc->blockLayers.empty() ? doc->blockLayers.data() : nullptr;
}
extern "C" const char *cad_doc_text(const cad_doc *doc) {
    return doc ? doc->text.c_str() : "";
}
extern "C" int32_t cad_doc_text_size(const cad_doc *doc) {
    return doc ? int32_t(doc->text.size()) : 0;
}
extern "C" double cad_doc_unit_meters(const cad_doc *doc) {
    return doc ? doc->unitMeters : 0.001;
}
extern "C" void cad_doc_set_unit_meters(cad_doc *doc, double meters) {
    if (doc && meters > 0) {
        doc->unitMeters = meters;
        doc->calibrated = 1;
    }
}
extern "C" int32_t cad_doc_calibrated(const cad_doc *doc) {
    return doc ? doc->calibrated : 0;
}

extern "C" int32_t cad_doc_truncated(const cad_doc *doc) {
    return doc ? doc->truncated : 0;
}
extern "C" int32_t cad_doc_skipped(const cad_doc *doc) { return doc ? doc->skipped : 0; }

extern "C" int32_t cad_doc_xref_count(const cad_doc *doc) {
    return doc ? int32_t(doc->xrefs.size()) : 0;
}

extern "C" void cad_doc_xref_name(const cad_doc *doc, int32_t index,
                                  int32_t *start, int32_t *length) {
    if (start) *start = 0;
    if (length) *length = 0;
    if (!doc || index < 0 || size_t(index) >= doc->xrefs.size()) return;
    if (start) *start = doc->xrefs[size_t(index)].first;
    if (length) *length = doc->xrefs[size_t(index)].second;
}

extern "C" int32_t cad_doc_xref_insert_count(const cad_doc *doc) {
    return doc ? int32_t(doc->xrefInserts.size()) : 0;
}

extern "C" void cad_doc_xref_insert_info(const cad_doc *doc, int32_t index,
                                         int32_t *nameStart, int32_t *nameLen,
                                         int32_t *pathStart, int32_t *pathLen,
                                         int32_t *space, int32_t *layer,
                                         double *matrix) {
    if (nameStart) *nameStart = 0;
    if (nameLen) *nameLen = 0;
    if (pathStart) *pathStart = 0;
    if (pathLen) *pathLen = 0;
    if (space) *space = 0;
    if (layer) *layer = -1;
    if (matrix) {
        matrix[0] = 1; matrix[1] = 0; matrix[2] = 0;
        matrix[3] = 1; matrix[4] = 0; matrix[5] = 0;
    }
    if (!doc || index < 0 || size_t(index) >= doc->xrefInserts.size()) return;
    const cad_doc::xref_insert &record = doc->xrefInserts[size_t(index)];
    if (nameStart) *nameStart = record.nameStart;
    if (nameLen) *nameLen = record.nameLen;
    if (pathStart) *pathStart = record.pathStart;
    if (pathLen) *pathLen = record.pathLen;
    if (space) *space = record.space;
    if (layer) *layer = record.layer;
    if (matrix) {
        for (int i = 0; i < 6; ++i) matrix[i] = record.m[i];
    }
}

extern "C" int32_t cad_aci_rgb(int32_t aci) {
    if (aci < 0 || aci > 255) return 0xFFFFFF;
    return int32_t(kAciPalette[aci]);
}
