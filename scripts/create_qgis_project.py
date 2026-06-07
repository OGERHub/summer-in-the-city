from pathlib import Path
import os

from qgis.core import *
from qgis.PyQt.QtGui import QColor, QFont

try:
    from osgeo import gdal
    import numpy as np
except Exception as exc:
    gdal = None
    np = None
    print("Warnung: GDAL/NumPy für Quantilstyling nicht verfügbar:", exc)


# ============================================================
# create_qgis_project.py
# ============================================================
#
# Project + print layout builder for the Cologne LST teaching maps.
#
# Layout v6:
#   - A4 landscape safe layout
#   - four separate layouts
#   - minimal right-side legends
#   - map frame reduced to fit the physical page
#   - scale bar below the right-side legend/text block
#   - no automatic QGIS legend, because it was too large
#
# ============================================================


# QGIS --code executes via exec(f.read()), so __file__ is not defined.
# The launcher passes QGIS_SCRIPT_DIR and PROJECT_ROOT explicitly.
SCRIPT_DIR = Path(os.environ.get("QGIS_SCRIPT_DIR", ".")).resolve()
PROJECT_ROOT = Path(os.environ.get("PROJECT_ROOT", SCRIPT_DIR.parent)).resolve()

AOI_NAME = "koeln"
CRS_EPSG = 25832

# Optional fixed layout extent in EPSG:25832.
# To use the exact current QGIS canvas extent, run in the QGIS Python console:
#
#   e = iface.mapCanvas().extent()
#   print((e.xMinimum(), e.yMinimum(), e.xMaximum(), e.yMaximum()))
#
# Then paste the four numbers here.
#
# If this stays None, the script tries to use the current canvas extent
# before clearing the project. If that is not useful, it falls back to AOI.
MAP_EXTENT_25832 = (353000.00, 5642500.00, 358500.00, 5647500.00)
DATA_ROOT = PROJECT_ROOT / "data" / "landsat_lst" / AOI_NAME

AOI_GPKG = DATA_ROOT / "01_aoi" / "aoi.gpkg"
PROJECTED_LST_DIR = DATA_ROOT / "05_teaching_layers" / "projected_lst"
DOP_CIR_MASK_DIR = DATA_ROOT / "05_teaching_layers" / "dop_cir_surface_mask"
QGIS_DIR = DATA_ROOT / "06_qgis_project"
PRINT_DIR = QGIS_DIR / "print_exports"

QGIS_PROJECT_FILE = QGIS_DIR / "koeln_lst_oberflaechenmaske.qgz"

QGIS_DIR.mkdir(parents=True, exist_ok=True)
PRINT_DIR.mkdir(parents=True, exist_ok=True)

print("QGIS SCRIPT VERSION: layout_fit_q90_only_extent_layerorder_v8")


# ------------------------------------------------------------
# Input layers
# ------------------------------------------------------------

HOT_LST_FILES = [
    (PROJECTED_LST_DIR / "koeln_LST_hot_q90_C_EPSG25832.tif", "Hot LST q90 / hottest hot"),
]

DOP_WMS_URL = "https://www.wms.nrw.de/geobasis/wms_nw_dop?language=ger"
DOP_WMS_LAYER = "nw_dop_rgb"
DOP_WMS_TITLE = "Luftbild NRW DOP RGB WMS"

DOP_CIR_MASK_GPKG = DOP_CIR_MASK_DIR / "koeln_dop_cir_30m_3klassen.gpkg"
DOP_CIR_MASK_LAYER = "dop_cir_30m_3klassen"


# ------------------------------------------------------------
# A4 landscape layout geometry
# ------------------------------------------------------------
#
# A4 landscape is 297 x 210 mm.
# The map is deliberately reduced so that labels, ticks and the
# right-side legend column remain inside the page.
#
# ------------------------------------------------------------

EXPORT_DPI = 300

PAGE_SIZE = "A4"
PAGE_ORIENTATION = QgsLayoutItemPage.Landscape

# Reduced again by roughly 15-20 % compared with the previous
# map frame. This keeps the coordinate labels and the right-side
# column safely inside the A4 landscape page.
MAP_X_MM = 24
MAP_Y_MM = 24
MAP_W_MM = 180
MAP_H_MM = 180

# Move the right-side column further right and keep it compact.
SIDE_X_MM = 250
SIDE_Y_MM = 24
SIDE_W_MM = 64

# Scale bar below the legend / explanation block.
SCALE_X_MM = MAP_X_MM + 4
SCALE_Y_MM = MAP_Y_MM + MAP_H_MM - 12
NOTE_Y_MM = 208

GRID_INTERVAL_M = 1000

OUT_DOP_PDF = PRINT_DIR / "koeln_print_01_dop.pdf"
OUT_LST_PDF = PRINT_DIR / "koeln_print_02_lst_hot_q90.pdf"
OUT_MASK_PDF = PRINT_DIR / "koeln_print_03_mask_overlay.pdf"
OUT_FRAME_PDF = PRINT_DIR / "koeln_print_04_frame_graticule.pdf"

OUT_MASK_PNG = PRINT_DIR / "koeln_print_03_mask_overlay_transparent.png"
OUT_FRAME_PNG = PRINT_DIR / "koeln_print_04_frame_graticule_transparent.png"


# ------------------------------------------------------------
# Project setup
# ------------------------------------------------------------

# Capture current canvas extent before project.clear().
# This only helps when the script is executed from an already open QGIS
# session with the desired map view. For scripted terminal runs, use
# MAP_EXTENT_25832 above for exact control.
CANVAS_EXTENT_BEFORE_CLEAR = None

try:
    CANVAS_EXTENT_BEFORE_CLEAR = QgsRectangle(iface.mapCanvas().extent())
except Exception:
    CANVAS_EXTENT_BEFORE_CLEAR = None

project = QgsProject.instance()
project.clear()
project.setCrs(QgsCoordinateReferenceSystem(f"EPSG:{CRS_EPSG}"))

root = project.layerTreeRoot()

# Remove old layouts from the currently running QGIS session.
for old_layout in list(project.layoutManager().layouts()):
    project.layoutManager().removeLayout(old_layout)


def add_group(name):
    return root.addGroup(name)


def add_vector(path, layername, title, group):
    path = Path(path)

    if not path.exists():
        print("Vektor fehlt:", title, str(path))
        return None

    uri = f"{path}|layername={layername}"
    layer = QgsVectorLayer(uri, title, "ogr")

    if layer.isValid():
        project.addMapLayer(layer, False)
        group.addLayer(layer)
        return layer

    print("Layer ungültig:", title, uri)
    return None


def add_raster(path, title, group):
    path = Path(path)

    if not path.exists():
        print("Raster fehlt:", title, str(path))
        return None

    layer = QgsRasterLayer(str(path), title)

    if layer.isValid():
        project.addMapLayer(layer, False)
        group.addLayer(layer)
        return layer

    print("Raster ungültig:", title, str(path))
    return None


def add_wms(url, layername, title, group):
    encoded_url = (
        url.replace(":", "%3A")
           .replace("/", "%2F")
           .replace("?", "%3F")
           .replace("&", "%26")
           .replace("=", "%3D")
    )

    uri = (
        f"contextualWMSLegend=0"
        f"&crs=EPSG:{CRS_EPSG}"
        f"&dpiMode=7"
        f"&format=image/png"
        f"&layers={layername}"
        f"&styles="
        f"&tilePixelRatio=0"
        f"&url={encoded_url}"
    )

    layer = QgsRasterLayer(uri, title, "wms")

    if layer.isValid():
        project.addMapLayer(layer, False)
        group.addLayer(layer)
        return layer

    print("WMS ungültig:", title)
    return None


# ------------------------------------------------------------
# Styling helpers
# ------------------------------------------------------------

def raster_values(path):
    if gdal is None or np is None:
        return None

    ds = gdal.Open(str(path))
    if ds is None:
        return None

    band = ds.GetRasterBand(1)
    arr = band.ReadAsArray()
    nodata = band.GetNoDataValue()

    vals = arr.astype("float64").ravel()

    if nodata is not None:
        vals = vals[vals != nodata]

    vals = vals[np.isfinite(vals)]

    if vals.size == 0:
        return None

    return vals


def quantile_breaks(path, n=5):
    vals = raster_values(path)

    if vals is None:
        return None

    probs = np.linspace(0.0, 1.0, n + 1)
    brks = np.quantile(vals, probs)
    brks = [float(x) for x in brks]

    for i in range(1, len(brks)):
        if brks[i] <= brks[i - 1]:
            brks[i] = brks[i - 1] + 1e-6

    return brks


def turbo_5_colors():
    return [
        QColor(48, 18, 59),
        QColor(45, 110, 185),
        QColor(42, 185, 115),
        QColor(245, 185, 40),
        QColor(180, 4, 38),
    ]


def style_hot_lst_quantile(layer, raster_path):
    if layer is None or not layer.isValid():
        return None

    brks = quantile_breaks(raster_path, n=5)

    if brks is None:
        print("Quantil-Styling nicht möglich:", str(raster_path))
        return None

    colors = turbo_5_colors()
    items = []

    for i in range(5):
        lower = brks[i]
        upper = brks[i + 1]
        label = f"Q{i + 1}: {lower:.1f}–{upper:.1f} °C"

        items.append(
            QgsColorRampShader.ColorRampItem(
                upper,
                colors[i],
                label
            )
        )

    shader = QgsColorRampShader()
    shader.setColorRampType(QgsColorRampShader.Discrete)
    shader.setColorRampItemList(items)
    shader.setMinimumValue(brks[0])
    shader.setMaximumValue(brks[-1])

    raster_shader = QgsRasterShader()
    raster_shader.setRasterShaderFunction(shader)

    renderer = QgsSingleBandPseudoColorRenderer(
        layer.dataProvider(),
        1,
        raster_shader
    )

    layer.setRenderer(renderer)
    layer.triggerRepaint()

    return list(zip(colors, [(brks[i], brks[i + 1]) for i in range(5)]))


def style_mask_outline(layer):
    if layer is None or not layer.isValid():
        return

    symbol = QgsFillSymbol.createSimple({
        "style": "no",
        "outline_style": "solid",
        "outline_color": "0,0,0,230",
        "outline_width": "0.35",
        "outline_width_unit": "MM",
    })

    layer.setRenderer(QgsSingleSymbolRenderer(symbol))
    layer.setOpacity(1.0)
    layer.triggerRepaint()


def set_opacity(layer, opacity):
    if layer is None or not layer.isValid():
        return

    layer.setOpacity(opacity)
    layer.triggerRepaint()


# ------------------------------------------------------------
# Load project layers
# ------------------------------------------------------------

# Visual layer order in QGIS:
#   top    mask lines
#          map frame
#          Hot LST q90 at 40 % opacity
#          DOP RGB at 100 % opacity
#   bottom orientation
g_surface = add_group("04 Oberflächenmaske Linien")
g_frame = add_group("03 Kartenrahmen")
g_lst = add_group("02 Hot LST q90 40 Prozent")
g_aerial = add_group("01 DOP RGB volle Deckkraft")
g_base = add_group("00 Orientierung")

aoi_layer = add_vector(AOI_GPKG, "aoi_boundary_25832", "AOI", g_base)
admin_layer = add_vector(AOI_GPKG, "admin_orientation_25832", "Administrative Orientierung", g_base)

hot_layers = {}
hot_legend = {}

for raster_path, title in HOT_LST_FILES:
    layer = add_raster(raster_path, title, g_lst)
    legend_items = style_hot_lst_quantile(layer, raster_path)

    # Hot LST overlay: 40 % opacity.
    set_opacity(layer, 1.0)

    if layer is not None:
        hot_layers[title] = layer
        hot_legend[title] = legend_items

lst_q90_layer = hot_layers.get("Hot LST q90 / hottest hot")
lst_q90_legend = hot_legend.get("Hot LST q90 / hottest hot")

dop_layer = add_wms(DOP_WMS_URL, DOP_WMS_LAYER, DOP_WMS_TITLE, g_aerial)
set_opacity(dop_layer, 1.0)

mask_layer = add_vector(
    DOP_CIR_MASK_GPKG,
    DOP_CIR_MASK_LAYER,
    "DOP-CIR Oberflächenmaske Linien",
    g_surface
)
style_mask_outline(mask_layer)


# ------------------------------------------------------------
# Shared extent
# ------------------------------------------------------------

def shared_print_extent():
    # 1) Fixed explicit extent has highest priority.
    if MAP_EXTENT_25832 is not None:
        xmin, ymin, xmax, ymax = MAP_EXTENT_25832
        return QgsRectangle(float(xmin), float(ymin), float(xmax), float(ymax))

    # 2) Current QGIS canvas extent, if available and plausible.
    if CANVAS_EXTENT_BEFORE_CLEAR is not None:
        ext = QgsRectangle(CANVAS_EXTENT_BEFORE_CLEAR)

        # Reject the default global/invalid-looking startup extent.
        if (
            ext.width() > 1000
            and ext.height() > 1000
            and ext.width() < 100000
            and ext.height() < 100000
        ):
            return ext

    # 3) Fallback: AOI extent.
    if aoi_layer is not None and aoi_layer.isValid():
        ext = QgsRectangle(aoi_layer.extent())
    elif lst_q90_layer is not None and lst_q90_layer.isValid():
        ext = QgsRectangle(lst_q90_layer.extent())
    else:
        raise RuntimeError("Keine gültige Ausdehnung für Print-Export gefunden.")

    ext.scale(1.025)
    return ext


SHARED_EXTENT = shared_print_extent()


# ------------------------------------------------------------
# Frame layer for project layer tree
# ------------------------------------------------------------

def create_frame_layer(extent):
    layer = QgsVectorLayer(f"Polygon?crs=EPSG:{CRS_EPSG}", "Kartenrahmen Layoutausschnitt", "memory")
    pr = layer.dataProvider()

    feat = QgsFeature()
    geom = QgsGeometry.fromRect(extent)
    feat.setGeometry(geom)
    pr.addFeatures([feat])
    layer.updateExtents()

    symbol = QgsFillSymbol.createSimple({
        "style": "no",
        "outline_style": "solid",
        "outline_color": "0,0,0,255",
        "outline_width": "0.45",
        "outline_width_unit": "MM",
    })

    layer.setRenderer(QgsSingleSymbolRenderer(symbol))

    project.addMapLayer(layer, False)
    g_frame.addLayer(layer)

    return layer


frame_layer = create_frame_layer(SHARED_EXTENT)


# ------------------------------------------------------------
# Layout helpers
# ------------------------------------------------------------

def make_font(size=8.0, bold=False):
    font = QFont("Arial")
    font.setPointSizeF(float(size))
    font.setBold(bool(bold))
    return font


def create_layout(name):
    manager = project.layoutManager()
    old = manager.layoutByName(name)

    if old is not None:
        manager.removeLayout(old)

    layout = QgsPrintLayout(project)
    layout.initializeDefaults()
    layout.setName(name)
    manager.addLayout(layout)

    page = layout.pageCollection().pages()[0]
    page.setPageSize(PAGE_SIZE, PAGE_ORIENTATION)

    return layout


def add_text(layout, text, x, y, w, h, size=8.0, bold=False):
    label = QgsLayoutItemLabel(layout)
    label.setText(text)
    label.setFont(make_font(size=size, bold=bold))
    label.setRect(0, 0, w, h)
    label.attemptMove(QgsLayoutPoint(x, y, QgsUnitTypes.LayoutMillimeters))
    label.attemptResize(QgsLayoutSize(w, h, QgsUnitTypes.LayoutMillimeters))

    try:
        label.setMarginX(0)
        label.setMarginY(0)
    except Exception:
        pass

    layout.addLayoutItem(label)
    return label


def add_title(layout, text):
    return add_text(layout, text, MAP_X_MM, 8, MAP_W_MM + SIDE_W_MM, 7, size=12, bold=True)


def add_map_grid(map_item, with_annotations=True, with_crosses=True):
    grid = QgsLayoutItemMapGrid("EPSG25832 2 km grid", map_item)
    map_item.grids().addGrid(grid)

    grid.setEnabled(True)
    grid.setIntervalX(GRID_INTERVAL_M)
    grid.setIntervalY(GRID_INTERVAL_M)

    try:
        grid.setCrs(QgsCoordinateReferenceSystem(f"EPSG:{CRS_EPSG}"))
    except Exception:
        pass

    if with_crosses:
        try:
            grid.setStyle(QgsLayoutItemMapGrid.Cross)
        except Exception:
            pass
        try:
            grid.setCrossLength(2.0)
        except Exception:
            pass
    else:
        try:
            grid.setStyle(QgsLayoutItemMapGrid.FrameAnnotationsOnly)
        except Exception:
            pass

    try:
        grid.setFrameStyle(QgsLayoutItemMapGrid.ExteriorTicks)
    except Exception:
        pass

    try:
        grid.setFrameWidth(0.25)
    except Exception:
        pass

    grid.setAnnotationEnabled(with_annotations)

    try:
        grid.setAnnotationPrecision(0)
    except Exception:
        pass

    try:
        grid.setAnnotationFrameDistance(1.0)
    except Exception:
        pass


def add_map(layout, layers, with_grid=True, with_annotations=True, with_crosses=True, frame_only=False):
    valid_layers = [layer for layer in layers if layer is not None and layer.isValid()]

    map_item = QgsLayoutItemMap(layout)
    map_item.setRect(MAP_X_MM, MAP_Y_MM, MAP_W_MM, MAP_H_MM)
    map_item.attemptMove(QgsLayoutPoint(MAP_X_MM, MAP_Y_MM, QgsUnitTypes.LayoutMillimeters))
    map_item.attemptResize(QgsLayoutSize(MAP_W_MM, MAP_H_MM, QgsUnitTypes.LayoutMillimeters))
    map_item.setExtent(SHARED_EXTENT)
    map_item.setLayers(valid_layers)

    if frame_only:
        try:
            map_item.setBackgroundEnabled(False)
        except Exception:
            pass

    try:
        map_item.setFrameEnabled(True)
        map_item.setFrameStrokeWidth(QgsLayoutMeasurement(0.25, QgsUnitTypes.LayoutMillimeters))
        map_item.setFrameStrokeColor(QColor(0, 0, 0, 255))
    except Exception:
        pass

    layout.addLayoutItem(map_item)

    if with_grid:
        add_map_grid(map_item, with_annotations=with_annotations, with_crosses=with_crosses)

    return map_item


def add_scale_bar(layout, map_item):
    scalebar = QgsLayoutItemScaleBar(layout)
    scalebar.setStyle("Single Box")
    scalebar.setLinkedMap(map_item)

    scalebar.setUnits(QgsUnitTypes.DistanceKilometers)

    # max. 2 km total: 2 segments × 1 km
    scalebar.setNumberOfSegments(2)
    scalebar.setNumberOfSegmentsLeft(0)
    scalebar.setUnitsPerSegment(0.5)
    scalebar.setUnitLabel("km")

    # compact visual size
    try:
        scalebar.setHeight(2.0)
    except Exception:
        pass

    try:
        scalebar.setFont(make_font(6.5))
    except Exception:
        pass

    # lower-left inside the map frame
    scalebar.attemptMove(
        QgsLayoutPoint(
            MAP_X_MM + 4,
            MAP_Y_MM + MAP_H_MM - 10,
            QgsUnitTypes.LayoutMillimeters
        )
    )

    layout.addLayoutItem(scalebar)
    return scalebar


def add_color_box(layout, x, y, color):
    rect = QgsLayoutItemShape(layout)
    rect.setShapeType(QgsLayoutItemShape.Rectangle)
    rect.attemptMove(QgsLayoutPoint(x, y, QgsUnitTypes.LayoutMillimeters))
    rect.attemptResize(QgsLayoutSize(4.5, 2.8, QgsUnitTypes.LayoutMillimeters))

    try:
        rect.setSymbol(
            QgsFillSymbol.createSimple({
                "color": f"{color.red()},{color.green()},{color.blue()},255",
                "outline_color": "0,0,0,255",
                "outline_width": "0.1",
                "outline_width_unit": "MM",
            })
        )
    except Exception:
        pass

    layout.addLayoutItem(rect)
    return rect


def add_line_sample(layout, x, y):
    line = QgsLayoutItemShape(layout)
    line.setShapeType(QgsLayoutItemShape.Rectangle)
    line.attemptMove(QgsLayoutPoint(x, y + 1.3, QgsUnitTypes.LayoutMillimeters))
    line.attemptResize(QgsLayoutSize(12, 0.4, QgsUnitTypes.LayoutMillimeters))

    try:
        line.setSymbol(
            QgsFillSymbol.createSimple({
                "color": "0,0,0,255",
                "outline_color": "0,0,0,255",
            })
        )
    except Exception:
        pass

    layout.addLayoutItem(line)
    return line


def add_lst_manual_legend(layout, legend_items, y=SIDE_Y_MM):
    add_text(layout, "Temperatur-Bereiche", SIDE_X_MM, y, SIDE_W_MM, 6, size=10, bold=True)
    y += 7

    if not legend_items:
        add_text(layout, "keine Klassen verfügbar", SIDE_X_MM, y, SIDE_W_MM, 10, size=10.0)
        return

    for i, (color, br) in enumerate(legend_items, start=1):
        add_color_box(layout, SIDE_X_MM, y + 0.7, color)
        add_text(
            layout,
            f"Bereich{i}: {br[0]:.0f}–{br[1]:.0f} °C",
            SIDE_X_MM + 7,
            y,
            SIDE_W_MM - 7,
            5,
            size=6.5
        )
        y += 5.2


def add_dop_side(layout, map_item):
    add_text(layout, "Luftbild", SIDE_X_MM, SIDE_Y_MM, SIDE_W_MM, 6, size=10.0, bold=True)
    add_text(
        layout,
        "Sichtbare Stadtstruktur:\n"
        "Straßen, Plätze, Dächer\n"
        "Rhein, Parks, Bäume\n"
        "Bahnanlagen, offene Flächen",
        SIDE_X_MM,
        SIDE_Y_MM + 8,
        SIDE_W_MM,
        34,
        size=6.6
    )

    add_scale_bar(layout, map_item)
    


def add_lst_side(layout, map_item):
    add_lst_manual_legend(layout, lst_q90_legend, y=SIDE_Y_MM)

    add_scale_bar(layout, map_item)
   

def add_mask_side(layout, map_item):
    add_text(layout, "Maske", SIDE_X_MM, SIDE_Y_MM, SIDE_W_MM, 6, size=10, bold=True)
    add_line_sample(layout, SIDE_X_MM, SIDE_Y_MM + 11)
    add_text(layout, "Oberflächen-Grenzen", SIDE_X_MM + 16, SIDE_Y_MM + 8, SIDE_W_MM - 16, 8, size=6.6)

    add_scale_bar(layout, map_item)


def add_frame_side(layout, map_item):
    add_text(layout, "Passfolie", SIDE_X_MM, SIDE_Y_MM, SIDE_W_MM, 6, size=7.8, bold=True)

    add_scale_bar(layout, map_item)



def export_layout_pdf(layout, outfile):
    exporter = QgsLayoutExporter(layout)
    settings = QgsLayoutExporter.PdfExportSettings()
    settings.dpi = EXPORT_DPI

    result = exporter.exportToPdf(str(outfile), settings)

    if result == QgsLayoutExporter.Success:
        print("PDF geschrieben:", outfile)
    else:
        raise RuntimeError(f"FEHLER PDF-Export: {outfile}, result={result}")


def export_layout_png(layout, outfile, transparent=True):
    exporter = QgsLayoutExporter(layout)
    settings = QgsLayoutExporter.ImageExportSettings()
    settings.dpi = EXPORT_DPI

    try:
        settings.transparentBackground = transparent
    except Exception:
        pass

    result = exporter.exportToImage(str(outfile), settings)

    if result == QgsLayoutExporter.Success:
        print("PNG geschrieben:", outfile)
    else:
        raise RuntimeError(f"FEHLER PNG-Export: {outfile}, result={result}")


# ------------------------------------------------------------
# Layout 01: DOP
# ------------------------------------------------------------

layout_dop = create_layout("Print 01 DOP")
add_title(layout_dop, "Köln: Luftbild")
map_dop = add_map(layout_dop, [dop_layer], with_grid=True, with_annotations=True, with_crosses=True)
add_dop_side(layout_dop, map_dop)
export_layout_pdf(layout_dop, OUT_DOP_PDF)


# ------------------------------------------------------------
# Layout 02: Hot LST q90
# ------------------------------------------------------------

layout_lst = create_layout("Print 02 Hot LST q90")
add_title(layout_lst, "Köln: Oberflächentemperatur")
map_lst = add_map(layout_lst, [lst_q90_layer], with_grid=True, with_annotations=True, with_crosses=True)
add_lst_side(layout_lst, map_lst)
export_layout_pdf(layout_lst, OUT_LST_PDF)


# ------------------------------------------------------------
# Layout 03: Maskenoverlay
# ------------------------------------------------------------

layout_mask = create_layout("Print 03 Maskenoverlay")
add_title(layout_mask, "Köln: Oberflächenmaske / Folienoverlay")
map_mask = add_map(layout_mask, [mask_layer], with_grid=True, with_annotations=True, with_crosses=True)
add_mask_side(layout_mask, map_mask)
export_layout_pdf(layout_mask, OUT_MASK_PDF)
export_layout_png(layout_mask, OUT_MASK_PNG, transparent=True)


# ------------------------------------------------------------
# Layout 04: transparent frame + graticule ticks only
# ------------------------------------------------------------

layout_frame = create_layout("Print 04 Rahmen Graticule")
add_title(layout_frame, "Köln: Rahmen und Gitternetz")
map_frame = add_map(layout_frame, [frame_layer], with_grid=True, with_annotations=True, with_crosses=False, frame_only=True)
add_frame_side(layout_frame, map_frame)
export_layout_pdf(layout_frame, OUT_FRAME_PDF)
export_layout_png(layout_frame, OUT_FRAME_PNG, transparent=True)


# ------------------------------------------------------------
# Hard check + save
# ------------------------------------------------------------

expected_layouts = [
    "Print 01 DOP",
    "Print 02 Hot LST q90",
    "Print 03 Maskenoverlay",
    "Print 04 Rahmen Graticule",
]

actual_layouts = [layout.name() for layout in project.layoutManager().layouts()]
print("Layouts im Projekt:", actual_layouts)

missing = [name for name in expected_layouts if name not in actual_layouts]
if missing:
    raise RuntimeError("Fehlende Layouts: " + ", ".join(missing))

expected_outputs = [
    OUT_DOP_PDF,
    OUT_LST_PDF,
    OUT_MASK_PDF,
    OUT_FRAME_PDF,
    OUT_MASK_PNG,
    OUT_FRAME_PNG,
]

missing_outputs = [path for path in expected_outputs if not path.exists()]
if missing_outputs:
    raise RuntimeError("Fehlende Ausgaben: " + ", ".join(str(path) for path in missing_outputs))

project.write(str(QGIS_PROJECT_FILE))
print("QGIS-Projekt geschrieben:", QGIS_PROJECT_FILE)
print("Printprodukte geschrieben nach:", PRINT_DIR)
