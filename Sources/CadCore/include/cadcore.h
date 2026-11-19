// CadCore — DWG/DXF → flat C structures for the native macOS app.
// Zero dependency on Qt; the only externals are LibreDWG and libdxfrw.
#ifndef CADCORE_H
#define CADCORE_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct { double x, y; } cad_point;
typedef struct { double minx, miny, maxx, maxy; } cad_bbox;

enum cad_kind {
    CAD_LINE = 1,
    CAD_POLYLINE,
    CAD_CIRCLE,
    CAD_ARC,
    CAD_ELLIPSE,
    CAD_TEXT,
    CAD_HATCH,
    CAD_POINT,
    CAD_SOLID
};

enum {
    CAD_FLAG_CLOSED    = 1 << 0,
    CAD_FLAG_FILLED    = 1 << 1,
    CAD_FLAG_INVISIBLE = 1 << 2,
    CAD_FLAG_MTEXT     = 1 << 3,
    CAD_FLAG_IMAGE     = 1 << 4,
    // Height not carried by the file (a DIMENSION whose DIMSTYLE is missing or
    // has DIMTXT = 0). Resolved from the drawing's own annotation in
    // finishSpace(), following the GB paper-height figures.
    CAD_FLAG_GB_HEIGHT = 1 << 5,
    // Geometry that came out of a dimension's anonymous block (`*D…`): the
    // witness lines, the dimension line and its terminators. It is ink on the
    // sheet, not part of the building, so object snap skips it — snapping to
    // the far end of a witness line that hangs 10 mm past the wall is never
    // what the user is aiming at.
    CAD_FLAG_DIMENSION = 1 << 6
};

enum {
    CAD_LAYER_OFF    = 1 << 0,
    CAD_LAYER_FROZEN = 1 << 1,
    CAD_LAYER_LOCKED = 1 << 2
};

typedef struct {
    int32_t kind;        // cad_kind
    int32_t space;       // space index (0 = model)
    int32_t layer;       // layer index, -1 unresolved
    int32_t flags;
    uint64_t handle;
    uint32_t rgb;        // resolved 0xRRGGBB
    uint8_t  aci;        // 0 = by block, 256 = by layer
    uint8_t  pad0;
    uint16_t pad1;
    float    lineweight; // mm, 0 = use layer / default
    int32_t  pstart;     // first index into doc points
    int32_t  pcount;
    double   cx, cy;     // circle/arc centre, text anchor
    double   r;
    double   a0, a1;     // arc angles in radians
    double   major_x, major_y; // ellipse major axis vector
    double   ratio;      // ellipse minor/major
    double   rot;        // text rotation in radians
    double   h;          // text height (drawing units)
    double   ws;         // text width factor
    int32_t  tstart;     // byte offset into doc text blob
    int32_t  tlen;
    int32_t  halign;
    int32_t  valign;
    int32_t  hatch;      // hatch index or -1
    cad_bbox box;
    // Paper-space clip of the viewport this entity was composed into.
    // All-zero means "no clip" (an ordinary model or paper-space entity).
    cad_bbox clip;
    // Layers of every enclosing INSERT, nearest first. VPLAYER freezes a
    // viewport layer even when the geometry's own effective layer is layer 0
    // inherited through the block (reference: CadEntity::blockLayerIndices).
    // Slice into cad_doc_block_layers().
    int32_t  block_layer_start;
    int32_t  block_layer_count;
} cad_entity;

typedef struct {
    int32_t pstart;
    int32_t pcount;
    int32_t closed;
    int32_t pad;
} cad_ring;

typedef struct {
    int32_t ringstart;
    int32_t ringcount;
    int32_t solid;
    int32_t style;       // 0 normal, 1 outer, 2 ignore
    double  angle;       // pattern rotation (radians)
    double  scale;
    int32_t defcount;
    double  def_angle[8];
    double  def_x[8];
    double  def_y[8];
    double  def_dx[8];
    double  def_dy[8];
    // Every pattern family carries its own dash list (AR-SAND, AR-CONC and
    // most ISO patterns define four), so the dashes live in one flat pool
    // sliced per family. A single shared `dashes[16]` corrupted every family
    // but the first, which made patterned fills look like solid hatching.
    int32_t def_ndashes[8];
    int32_t def_dash_start[8];
    double  dashes[128];
} cad_hatch;

typedef struct {
    int32_t name_start;
    int32_t name_len;
    uint32_t rgb;
    int32_t flags;
    float   lineweight;
    int32_t count;
    int32_t pad;
} cad_layer;

typedef struct {
    int32_t name_start;
    int32_t name_len;
    int32_t kind;        // 0 model, 1 paper layout
    int32_t first_entity;
    int32_t entity_count;
    cad_bbox box;
} cad_space;

typedef struct {
    int32_t space;
    int32_t id;
    int32_t status;          // DXF 68 on_off: 0 = off, non-zero = on
    int32_t frozen_start;    // slice in cad_doc_frozen_layers()
    int32_t frozen_count;    // VPLAYER frozen layer indices for this viewport
    int32_t reserved;
    double  cx, cy;          // centre in paper coordinates
    double  width, height;   // size in paper coordinates
    double  model_cx, model_cy;
    double  model_height;
    double  twist;
    cad_bbox clip;           // viewport rect in paper coordinates
} cad_viewport;

/// Camera stored in the drawing's VPORT table (the `*Active` entry).
/// Reference: LibreDwgReader::readSavedModelView(). The first open restores
/// this view instead of fitting the entity extents, which is why a reference
/// viewer shows exactly the same three plan views the author last saved.
typedef struct {
    int32_t valid;
    int32_t reserved;
    double  cx, cy;          // VIEWCTR (model/world coordinates)
    double  width, height;   // view_width / VIEWSIZE
    double  twist;           // VIEWTWIST (radians)
} cad_saved_view;

typedef struct cad_doc cad_doc;

cad_doc   *cad_doc_load(const char *path, char **error_out);
void       cad_doc_free(cad_doc *doc);
const char *cad_doc_version(const cad_doc *doc);
const char *cad_doc_backend(const cad_doc *doc);
double     cad_doc_load_ms(const cad_doc *doc);

int32_t    cad_doc_entity_count(const cad_doc *doc);
const cad_entity *cad_doc_entities(const cad_doc *doc);
int32_t    cad_doc_point_count(const cad_doc *doc);
const cad_point  *cad_doc_points(const cad_doc *doc);
int32_t    cad_doc_ring_count(const cad_doc *doc);
const cad_ring   *cad_doc_rings(const cad_doc *doc);
int32_t    cad_doc_hatch_count(const cad_doc *doc);
const cad_hatch  *cad_doc_hatches(const cad_doc *doc);
// Dash element `index` of pattern family `family`. Exposed as a function
// because a 128-entry C array imports into Swift as an unwieldy tuple; every
// family owns its own dash run inside the shared pool.
double     cad_hatch_dash(const cad_hatch *hatch, int32_t family, int32_t index);
int32_t    cad_doc_layer_count(const cad_doc *doc);
const cad_layer  *cad_doc_layers(const cad_doc *doc);
int32_t    cad_doc_space_count(const cad_doc *doc);
const cad_space  *cad_doc_spaces(const cad_doc *doc);
int32_t    cad_doc_viewport_count(const cad_doc *doc);
const cad_viewport *cad_doc_viewports(const cad_doc *doc);
cad_saved_view cad_doc_saved_view(const cad_doc *doc);
/// EXTMIN/EXTMAX from the DWG header — the extent the drawing was saved with.
/// The reference viewer prefers it over a computed entity union when deciding
/// how big the drawing is (CadModel.cpp::finalize). Invalid when
/// `minx > maxx`; callers must check before use.
cad_bbox   cad_doc_declared_box(const cad_doc *doc);
int32_t    cad_doc_frozen_layer_count(const cad_doc *doc);
const int32_t *cad_doc_frozen_layers(const cad_doc *doc);
int32_t    cad_doc_block_layer_count(const cad_doc *doc);
const int32_t *cad_doc_block_layers(const cad_doc *doc);
const char *cad_doc_text(const cad_doc *doc);
int32_t    cad_doc_text_size(const cad_doc *doc);

double     cad_doc_unit_meters(const cad_doc *doc);
void       cad_doc_set_unit_meters(cad_doc *doc, double meters);
int32_t    cad_doc_calibrated(const cad_doc *doc);
/// 1 when the 900k entity safety ceiling dropped geometry.
int32_t    cad_doc_truncated(const cad_doc *doc);

int32_t    cad_aci_rgb(int32_t aci);
int32_t    cad_doc_skipped(const cad_doc *doc);

/* External references the drawing inserts but whose files are not next to it.
   The geometry lives in another file, so no amount of parsing brings it back;
   naming the missing references is what lets the user go and find them. */
int32_t    cad_doc_xref_count(const cad_doc *doc);
/* Slice into the cad_doc_text() blob. */
void       cad_doc_xref_name(const cad_doc *doc, int32_t index,
                             int32_t *start, int32_t *length);

/* Every INSERT of an external reference, with the 2x3 affine it was placed at.
   The referenced geometry is in another file, but the placement is in this one:
   the app resolves the path, loads the file and transforms its geometry through
   `matrix` so the xref lands exactly where the author put it.
   matrix = [m11, m12, m21, m22, dx, dy], x' = m11*x + m21*y + dx. */
int32_t    cad_doc_xref_insert_count(const cad_doc *doc);
void       cad_doc_xref_insert_info(const cad_doc *doc, int32_t index,
                                    int32_t *nameStart, int32_t *nameLen,
                                    int32_t *pathStart, int32_t *pathLen,
                                    int32_t *space, int32_t *layer,
                                    double *matrix);

#ifdef __cplusplus
}
#endif

#endif
