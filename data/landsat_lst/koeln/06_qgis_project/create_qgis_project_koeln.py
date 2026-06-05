from pathlib import Path
from urllib.parse import quote

from qgis.core import (
    QgsProject,
    QgsCoordinateReferenceSystem,
    QgsRasterLayer,
    QgsVectorLayer,
    QgsSingleSymbolRenderer,
    QgsFillSymbol,
    QgsLineSymbol
)

# ------------------------------------------------------------
# Portable paths
# ------------------------------------------------------------

SCRIPT_DIR = Path(__file__).resolve().parent

def p(rel):
    return str((SCRIPT_DIR / rel).resolve())

project = QgsProject.instance()
project.clear()
project.setCrs(QgsCoordinateReferenceSystem("EPSG:25832"))

gpkg = p(r"../05_teaching_layers/koeln_teaching_layers_EPSG25832.gpkg")
project_out = p(r"koeln_lst_teaching_project.qgz")

lst_layers = [
    (p(r'../05_teaching_layers/projected_lst/koeln_LST_hot_median_C_EPSG25832.tif'), 'hot median [°C]'),
    (p(r'../05_teaching_layers/projected_lst/koeln_LST_hot_q10_C_EPSG25832.tif'), 'hot q10 [°C]'),
    (p(r'../05_teaching_layers/projected_lst/koeln_LST_hot_q90_C_EPSG25832.tif'), 'hot q90 [°C]'),
    (p(r'../05_teaching_layers/projected_lst/koeln_LST_cold_median_C_EPSG25832.tif'), 'cold median [°C]'),
    (p(r'../05_teaching_layers/projected_lst/koeln_LST_cold_q10_C_EPSG25832.tif'), 'cold q10 [°C]'),
    (p(r'../05_teaching_layers/projected_lst/koeln_LST_cold_q90_C_EPSG25832.tif'), 'cold q90 [°C]')
]

# ------------------------------------------------------------
# Layer tree groups
# ------------------------------------------------------------

root = project.layerTreeRoot()

grp_base = root.addGroup("01 Luftbild / Orientierung")
grp_lst = root.addGroup("02 LST-Karten")
grp_admin = root.addGroup("03 AOI / Verwaltungsgrenzen")
grp_osm = root.addGroup("04 OSM-Strukturlayer")

# ------------------------------------------------------------
# Optional aerial WMS
# ------------------------------------------------------------

def add_wms_layer(url, layer_name, title, epsg, group):
    # QGIS WMS provider URI. Keep URL without trailing question mark.
    clean_url = url.rstrip("?")
    uri = (
        "contextualWMSLegend=0"
        "&crs=EPSG:{epsg}"
        "&dpiMode=7"
        "&featureCount=10"
        "&format=image/png"
        "&layers={layer}"
        "&styles="
        "&url={url}"
    ).format(
        epsg=epsg,
        layer=layer_name,
        url=quote(clean_url, safe=":/?=&")
    )

    lyr = QgsRasterLayer(uri, title, "wms")

    if lyr.isValid():
        project.addMapLayer(lyr, False)
        group.addLayer(lyr)
        return lyr

    print("WARNUNG: WMS konnte nicht geladen werden:", title)
    print("URI:", uri)
    return None

if True:
    add_wms_layer(
        url="https://www.wms.nrw.de/geobasis/wms_nw_dop",
        layer_name="WMS_NW_DOP",
        title="Luftbild NRW DOP WMS",
        epsg=25832,
        group=grp_base
    )

# ------------------------------------------------------------
# LST rasters
# ------------------------------------------------------------

for path, title in lst_layers:
    lyr = QgsRasterLayer(path, "LST " + title, "gdal")
    if lyr.isValid():
        lyr.setOpacity(0.65)
        project.addMapLayer(lyr, False)
        grp_lst.addLayer(lyr)
    else:
        print("WARNUNG: LST-Raster konnte nicht geladen werden:", path)

# ------------------------------------------------------------
# Vector layers
# ------------------------------------------------------------

def add_gpkg_layer(layer_name, title, group):
    uri = gpkg + "|layername=" + layer_name
    lyr = QgsVectorLayer(uri, title, "ogr")
    if lyr.isValid():
        project.addMapLayer(lyr, False)
        group.addLayer(lyr)
        return lyr

    print("WARNUNG: Layer konnte nicht geladen werden:", layer_name)
    print("URI:", uri)
    return None

aoi_boundary = add_gpkg_layer("aoi_boundary", "AOI-Grenze", grp_admin)

if True:
    admin_orientation = add_gpkg_layer("admin_orientation", "Verwaltungs-/Orientierungsgrenzen", grp_admin)
else:
    admin_orientation = None

osm_buildings = add_gpkg_layer("osm_buildings", "Gebäude OSM", grp_osm)
osm_green = add_gpkg_layer("osm_green", "Parks / Grünflächen OSM", grp_osm)
osm_water = add_gpkg_layer("osm_water", "Wasserflächen OSM", grp_osm)
osm_roads = add_gpkg_layer("osm_roads", "Straßen OSM", grp_osm)

# ------------------------------------------------------------
# Simple print-friendly styles
# ------------------------------------------------------------

if aoi_boundary:
    symbol = QgsFillSymbol.createSimple({
        "color": "0,0,0,0",
        "outline_color": "0,0,0,255",
        "outline_width": "1.2"
    })
    aoi_boundary.setRenderer(QgsSingleSymbolRenderer(symbol))

if admin_orientation:
    symbol = QgsFillSymbol.createSimple({
        "color": "0,0,0,0",
        "outline_color": "0,0,0,180",
        "outline_width": "0.6"
    })
    admin_orientation.setRenderer(QgsSingleSymbolRenderer(symbol))

if osm_buildings:
    symbol = QgsFillSymbol.createSimple({
        "color": "120,120,120,80",
        "outline_color": "80,80,80,180",
        "outline_width": "0.1"
    })
    osm_buildings.setRenderer(QgsSingleSymbolRenderer(symbol))

if osm_green:
    symbol = QgsFillSymbol.createSimple({
        "color": "80,160,80,100",
        "outline_color": "40,120,40,160",
        "outline_width": "0.2"
    })
    osm_green.setRenderer(QgsSingleSymbolRenderer(symbol))

if osm_water:
    symbol = QgsFillSymbol.createSimple({
        "color": "80,140,220,120",
        "outline_color": "40,90,180,180",
        "outline_width": "0.2"
    })
    osm_water.setRenderer(QgsSingleSymbolRenderer(symbol))

if osm_roads:
    symbol = QgsLineSymbol.createSimple({
        "color": "230,230,230,180",
        "width": "0.4"
    })
    osm_roads.setRenderer(QgsSingleSymbolRenderer(symbol))

# ------------------------------------------------------------
# Save project
# ------------------------------------------------------------

ok = project.write(project_out)
print("QGIS-Projekt geschrieben:", project_out, "OK=", ok)

