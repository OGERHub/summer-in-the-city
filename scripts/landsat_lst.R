# ============================================================
# Landsat 8/9 LST AOI Workflow – Hot/Cold Extremes + Teaching Layers
# ============================================================
#
# Purpose
# -------
# This script builds a complete local data package for one AOI:
#
#   1. Read or create AOI geometry.
#   2. Search Landsat 8/9 Collection 2 Level-2 scenes via STAC.
#   3. Keep STAC items unsigned and sign every scene just-in-time.
#   4. Convert Landsat ST_B10 / lwir11 to land surface temperature in °C.
#   5. Mask clouds, cloud shadow, cirrus, snow and fill via QA_PIXEL.
#   6. Store all processed AOI-clipped LST scenes locally.
#   7. Select hot extremes, cold extremes or both.
#   8. Build stacks and composites for the selected extreme scenes.
#   9. Build teaching layers: AOI, optional administrative districts, OSM
#      buildings, green areas, water and roads.
#  10. Write a PyQGIS script that creates a QGIS project with:
#      - LST products
#      - aerial photo WMS, if enabled
#      - AOI / administrative orientation layers
#      - OSM structure layers
#
# Output principle
# ----------------
# All outputs are stored below:
#
#   <project_root>/<AOI_NAME>/
#
# The directory name is derived from `aoi_name`.
# This keeps different AOIs strictly separated.
#
# Notes
# -----
# - The script uses Planetary Computer STAC.
# - Asset URLs are not signed globally because signed Azure URLs expire.
# - Every scene is signed immediately before remote access.
# - If a processed local scene already exists, it is reused.
# - For school/teaching use, EPSG:25832 is the default print/project CRS
#   for Cologne/NRW. EPSG:3035 is exported additionally for European LUCC
#   workflows.
#
# ============================================================


# ------------------------------------------------------------
# 0. Packages
# ------------------------------------------------------------

pkgs <- c(
  "sf",
  "terra",
  "rstac",
  "dplyr",
  "purrr",
  "tibble",
  "readr",
  "osmdata",
  "jsonlite"
)

missing_pkgs <- pkgs[!vapply(pkgs, requireNamespace, logical(1), quietly = TRUE)]

if (length(missing_pkgs) > 0) {
  install.packages(missing_pkgs)
}

library(sf)
library(terra)
library(rstac)
library(dplyr)
library(purrr)
library(tibble)
library(readr)
library(osmdata)
library(jsonlite)


# ------------------------------------------------------------
# 1. User configuration
# ------------------------------------------------------------
#
# Change only this block for a new AOI/run.
#
# aoi_name:
#   Human-readable AOI name. Used to create the output folder.
#
# aoi_mode:
#   "file"              read AOI from a vector file
#   "bbox"              use bbox coordinates below
#   "koeln_stadtbezirke" download/use Cologne administrative districts
#
# extreme_mode:
#   "hot"   only hot extreme scenes
#   "cold"  only cold extreme scenes
#   "both"  hot and cold extreme scenes
#
# seasonal_months:
#   Which months are allowed. For summer half-year use 4:9.
#   For full year use 1:12.
#
# ------------------------------------------------------------

aoi_name <- "koeln"
aoi_mode <- "koeln_stadtbezirke"

project_root <- file.path("data", "landsat_lst")

date_start <- "2020-01-01"
date_end   <- as.character(Sys.Date())

# Sommerhalbjahr: April bis September
seasonal_months <- 4:9

# Options: "hot", "cold", "both"
extreme_mode <- "both"

# Number of selected scenes for each extreme class
n_hot  <- 10
n_cold <- 10

# Hot/cold ranking metrics from calculated AOI LST statistics
# Hot: high q90_C = broadly hot surface conditions
# Cold: low q10_C = broadly cold surface conditions
hot_metric  <- "q90_C"
cold_metric <- "q10_C"

# Scene-level cloud metadata filter. Pixelwise QA masking follows later.
max_scene_cloud <- 30

# Keep only Landsat Collection Category T1 and processing level L2SP
require_tier1 <- TRUE
require_l2sp  <- TRUE

# Limit candidates for tests. Use Inf for full processing.
max_candidates <- Inf

# QA settings
mask_water <- FALSE
min_valid_pixels <- 500

# Reuse existing local products
skip_existing_outputs <- TRUE

# Coordinate systems
crs_qgis <- 25832   # ETRS89 / UTM Zone 32N; suitable for Cologne/NRW print work
crs_lucc <- 3035    # ETRS89 / LAEA Europe; suitable for European LUCC products

# Optional AOI file mode
# Used only when aoi_mode == "file".
aoi_file  <- NA_character_
aoi_layer <- NA_character_

# Optional bbox mode
# Used only when aoi_mode == "bbox".
# Coordinates must be EPSG:4326 lon/lat.
aoi_bbox <- c(
  xmin = 6.75,
  ymin = 50.82,
  xmax = 7.20,
  ymax = 51.10
)

# Optional additional administrative layer for orientation.
# If NULL, only the AOI outline is used.
# For aoi_mode == "koeln_stadtbezirke", the city districts are generated automatically.
admin_file  <- NA_character_
admin_layer <- NA_character_

# OSM teaching layers
load_osm_layers <- TRUE

# Overpass robustness
# -------------------
# Public Overpass endpoints can temporarily reject requests with HTTP 429
# (Too Many Requests). This is common for large AOIs such as a whole city
# and especially for building footprints. The workflow therefore retries
# OSM requests with exponential waiting and can switch to alternative
# endpoints before giving up.
#
# osm_fail_policy:
#   "warn_empty"  continue with an empty layer if all retries fail
#   "stop"        stop the script after all retries fail
#
# For a first LST-only run, set load_osm_layers <- TRUE.
osm_fail_policy <- "warn_empty"
# Non-blocking default: try each endpoint once and then continue with empty OSM layers.
# Whole-city Overpass queries can otherwise spend many minutes in backoff loops.
osm_retry_max <- 1
osm_retry_wait <- 0
osm_timeout <- 25

# Buildings are by far the heaviest OSM layer for a whole city.
# Keep FALSE for city-wide teaching packages. Students can identify
# buildings from the aerial image; vector buildings can be enabled
# for smaller AOIs.
osm_load_buildings <- FALSE
osm_disable_after_server_error <- TRUE
osm_endpoints <- c(
  "https://overpass-api.de/api/interpreter",
  "https://overpass.kumi.systems/api/interpreter",
  "https://overpass.openstreetmap.fr/api/interpreter"
)

# Aerial image source for the QGIS project.
# ----------------------------------------
# "wms"       online aerial image as QGIS WMS layer only
# "local_rgb" download one georeferenced RGB overview raster only
# "both"      use local RGB overview plus online WMS
# "none"      no aerial image layer
#
# Recommended for teaching packages:
#   "both" for preparation on your own machine.
#   "wms" if no local raster should be created.
aerial_source_mode <- "both"

# Backward-compatible flags derived from aerial_source_mode.
add_aerial_wms <- aerial_source_mode %in% c("wms", "both")
aerial_wms_name  <- "Luftbild NRW DOP RGB WMS"

# This is the RGB layer as QGIS reports it for the NRW DOP WMS:
#   crs=EPSG:25832&dpiMode=7&format=image/png&layers=nw_dop_rgb&styles&tilePixelRatio=0&url=https://www.wms.nrw.de/geobasis/wms_nw_dop?language%3Dger
aerial_wms_url   <- "https://www.wms.nrw.de/geobasis/wms_nw_dop?language=ger"
aerial_wms_layer <- "nw_dop_rgb"

# Default transparency for aerial imagery in the QGIS project.
# 0.35 means 35% opacity, i.e. 65% transparent.
aerial_opacity <- 0.35

# Local RGB aerial image
# ----------------------
# This creates a georeferenced RGB overview from the aerial-photo WMS.
# It is a cache/print fallback, not a replacement for the web service.
# The image is written at a controlled size so a city-wide AOI does not
# create a massive 10 cm DOP file.
add_local_rgb_aerial <- aerial_source_mode %in% c("local_rgb", "both")
aerial_rgb_format <- "image/png"
aerial_rgb_max_dim <- 6000
aerial_rgb_target_res_m <- 2

# Automatically start QGIS after writing the PyQGIS project script.
# Keep FALSE for reproducible batch runs.
run_qgis_project_creation <- FALSE


# ------------------------------------------------------------
# 2. Derived paths and run folders
# ------------------------------------------------------------

safe_filename <- function(x) {
  x <- iconv(x, from = "", to = "ASCII//TRANSLIT")
  x <- tolower(x)
  x <- gsub("[^a-z0-9_\\-]+", "_", x)
  x <- gsub("_+", "_", x)
  x <- gsub("^_|_$", "", x)
  if (!nzchar(x)) x <- "aoi"
  x
}

aoi_slug <- safe_filename(aoi_name)

out_dir <- file.path(project_root, aoi_slug)

cfg_dir      <- file.path(out_dir, "00_config")
aoi_dir      <- file.path(out_dir, "01_aoi")
stac_dir     <- file.path(out_dir, "02_stac")
scene_dir    <- file.path(out_dir, "03_landsat_scenes", "all_processed_lst_c")
extreme_dir  <- file.path(out_dir, "04_extremes")
teaching_dir <- file.path(out_dir, "05_teaching_layers")
qgis_dir     <- file.path(out_dir, "06_qgis_project")
log_dir      <- file.path(out_dir, "99_logs")

all_dirs <- c(
  cfg_dir,
  aoi_dir,
  stac_dir,
  scene_dir,
  extreme_dir,
  teaching_dir,
  qgis_dir,
  log_dir
)

invisible(lapply(all_dirs, dir.create, recursive = TRUE, showWarnings = FALSE))

# Store configuration for reproducibility
run_config <- list(
  aoi_name = aoi_name,
  aoi_slug = aoi_slug,
  aoi_mode = aoi_mode,
  project_root = project_root,
  date_start = date_start,
  date_end = date_end,
  seasonal_months = seasonal_months,
  extreme_mode = extreme_mode,
  n_hot = n_hot,
  n_cold = n_cold,
  hot_metric = hot_metric,
  cold_metric = cold_metric,
  max_scene_cloud = max_scene_cloud,
  require_tier1 = require_tier1,
  require_l2sp = require_l2sp,
  max_candidates = if (is.finite(max_candidates)) max_candidates else "Inf",
  mask_water = mask_water,
  min_valid_pixels = min_valid_pixels,
  skip_existing_outputs = skip_existing_outputs,
  crs_qgis = crs_qgis,
  crs_lucc = crs_lucc,
  load_osm_layers = load_osm_layers,
  osm_fail_policy = osm_fail_policy,
  osm_retry_max = osm_retry_max,
  osm_retry_wait = osm_retry_wait,
  osm_timeout = osm_timeout,
  osm_load_buildings = osm_load_buildings,
  osm_disable_after_server_error = osm_disable_after_server_error,
  aerial_source_mode = aerial_source_mode,
  add_aerial_wms = add_aerial_wms,
  aerial_wms_name = aerial_wms_name,
  aerial_wms_url = aerial_wms_url,
  aerial_wms_layer = aerial_wms_layer,
  aerial_opacity = aerial_opacity,
  add_local_rgb_aerial = add_local_rgb_aerial,
  aerial_rgb_format = aerial_rgb_format,
  aerial_rgb_max_dim = aerial_rgb_max_dim,
  aerial_rgb_target_res_m = aerial_rgb_target_res_m
)

jsonlite::write_json(
  run_config,
  file.path(cfg_dir, "run_config.json"),
  pretty = TRUE,
  auto_unbox = TRUE
)


# ------------------------------------------------------------
# 3. AOI loading and local AOI package
# ------------------------------------------------------------
#
# Output:
#   01_aoi/aoi.gpkg
#     - aoi_boundary_4326
#     - aoi_boundary_25832
#     - aoi_boundary_3035
#     - admin_orientation_25832, if available
#     - admin_orientation_3035, if available
#
# For Cologne:
#   aoi_mode == "koeln_stadtbezirke" downloads the official city district
#   file and dissolves districts to one AOI boundary.
#
# ------------------------------------------------------------

read_sf_optional_layer <- function(dsn, layer = NA_character_) {
  if (!file.exists(dsn)) {
    stop("Vector file does not exist: ", dsn)
  }

  if (!is.na(layer) && nzchar(layer)) {
    st_read(dsn, layer = layer, quiet = TRUE)
  } else {
    st_read(dsn, quiet = TRUE)
  }
}

write_gpkg_layer <- function(obj, dsn, layer) {
  if (file.exists(dsn) && layer %in% st_layers(dsn)$name) {
    st_delete(dsn, layer = layer, quiet = TRUE)
  }

  st_write(
    obj,
    dsn = dsn,
    layer = layer,
    quiet = TRUE
  )
}

load_koeln_stadtbezirke <- function(target_dir) {

  zip_url <- "https://www.offenedaten-koeln.de/sites/default/files/distribution/Stadtbezirk_18.zip"
  zip_file <- file.path(target_dir, "koeln_stadtbezirke.zip")
  unzip_dir <- file.path(target_dir, "koeln_stadtbezirke_raw")

  if (!file.exists(zip_file)) {
    message("Lade Stadtbezirke Köln ...")
    download.file(zip_url, zip_file, mode = "wb")
  } else {
    message("Stadtbezirke-ZIP existiert bereits: ", zip_file)
  }

  if (!dir.exists(unzip_dir)) {
    dir.create(unzip_dir, recursive = TRUE, showWarnings = FALSE)
    unzip(zip_file, exdir = unzip_dir)
  } else {
    message("Stadtbezirke-Verzeichnis existiert bereits: ", unzip_dir)
  }

  shp <- list.files(
    unzip_dir,
    pattern = "\\.shp$",
    recursive = TRUE,
    full.names = TRUE
  )

  if (length(shp) == 0) {
    stop("No Cologne city district shapefile found after unzip.")
  }

  stadtbezirke <- st_read(shp[1], quiet = TRUE) |>
    st_make_valid()

  # Portal states ETRS89 / UTM Zone 32N. Set it if missing.
  if (is.na(st_crs(stadtbezirke))) {
    st_crs(stadtbezirke) <- 25832
  }

  stadtbezirke
}

if (aoi_mode == "file") {

  message("Lade AOI aus Datei ...")

  aoi_raw <- read_sf_optional_layer(aoi_file, aoi_layer) |>
    st_make_valid()

  admin_raw <- NULL

  if (!is.na(admin_file) && file.exists(admin_file)) {
    admin_raw <- read_sf_optional_layer(admin_file, admin_layer) |>
      st_make_valid()
  }

} else if (aoi_mode == "bbox") {

  message("Erzeuge AOI aus Bounding Box ...")

  aoi_raw <- st_sf(
    aoi_name = aoi_name,
    geometry = st_as_sfc(st_bbox(aoi_bbox, crs = 4326))
  )

  admin_raw <- NULL

} else if (aoi_mode == "koeln_stadtbezirke") {

  message("Erzeuge AOI aus Kölner Stadtbezirken ...")

  admin_raw <- load_koeln_stadtbezirke(aoi_dir)
  aoi_raw <- admin_raw |>
    st_make_valid() |>
    summarise(aoi_name = aoi_name, geometry = st_union(geometry), .groups = "drop") |>
    st_make_valid()

} else {

  stop("Unknown aoi_mode: ", aoi_mode)
}

if (is.na(st_crs(aoi_raw))) {
  stop("AOI has no CRS. Assign a CRS before running the workflow.")
}

aoi_4326 <- aoi_raw |>
  st_make_valid() |>
  st_transform(4326) |>
  st_union() |>
  st_as_sf() |>
  mutate(aoi_name = aoi_name)

aoi_25832 <- st_transform(aoi_4326, crs_qgis)
aoi_3035  <- st_transform(aoi_4326, crs_lucc)

admin_25832 <- NULL
admin_3035  <- NULL

if (!is.null(admin_raw)) {
  admin_25832 <- admin_raw |>
    st_make_valid() |>
    st_transform(crs_qgis)

  admin_3035 <- st_transform(admin_25832, crs_lucc)
}

aoi_gpkg <- file.path(aoi_dir, "aoi.gpkg")

write_gpkg_layer(aoi_4326,  aoi_gpkg, "aoi_boundary_4326")
write_gpkg_layer(aoi_25832, aoi_gpkg, "aoi_boundary_25832")
write_gpkg_layer(aoi_3035,  aoi_gpkg, "aoi_boundary_3035")

if (!is.null(admin_25832)) {
  write_gpkg_layer(admin_25832, aoi_gpkg, "admin_orientation_25832")
  write_gpkg_layer(admin_3035,  aoi_gpkg, "admin_orientation_3035")
}

bbox <- st_bbox(aoi_4326)

message("AOI package written: ", aoi_gpkg)


# ------------------------------------------------------------
# 4. STAC search: keep items unsigned
# ------------------------------------------------------------
#
# Important:
#   Do not sign all items here. Signed Planetary Computer URLs are temporary
#   Azure SAS URLs. They can expire during long processing runs.
#   The script signs each scene immediately before remote reading.
#
# ------------------------------------------------------------

stac_url <- "https://planetarycomputer.microsoft.com/api/stac/v1"

message("Suche Landsat-C2-L2-Szenen über STAC ...")

items <- stac(stac_url) |>
  stac_search(
    collections = "landsat-c2-l2",
    bbox = c(
      bbox["xmin"],
      bbox["ymin"],
      bbox["xmax"],
      bbox["ymax"]
    ),
    datetime = paste0(date_start, "/", date_end),
    limit = 100
  ) |>
  post_request()

items <- tryCatch(
  {
    rstac::items_fetch(items)
  },
  error = function(e) {
    message("items_fetch() failed or was not needed. Using available STAC page.")
    items
  }
)

features <- items$features

if (length(features) == 0) {
  stop("No STAC items found.")
}

saveRDS(items, file.path(stac_dir, "stac_items_unsigned.rds"))


# ------------------------------------------------------------
# 5. Robust STAC metadata extraction and filtering
# ------------------------------------------------------------

get_prop <- function(x, name, default = NA) {
  val <- x$properties[[name]]
  if (is.null(val) || length(val) == 0) {
    return(default)
  }
  val[[1]]
}

get_chr <- function(x, name, default = NA_character_) {
  val <- get_prop(x, name, default)
  if (is.null(val) || length(val) == 0 || is.na(val)) {
    return(default)
  }
  as.character(val)
}

get_dbl <- function(x, name, default = NA_real_) {
  val <- get_prop(x, name, default)
  if (is.null(val) || length(val) == 0 || is.na(val)) {
    return(default)
  }
  suppressWarnings(as.numeric(val))
}

has_asset <- function(x, asset_name) {
  !is.null(x$assets[[asset_name]]) &&
    !is.null(x$assets[[asset_name]]$href)
}

make_scene_outfile <- function(scene_id, scene_date, out_dir) {
  file.path(
    out_dir,
    paste0(
      format(scene_date, "%Y%m%d"),
      "_",
      safe_filename(scene_id),
      "_LST_C.tif"
    )
  )
}

meta_all <- tibble(
  idx = seq_along(features),
  id = map_chr(features, \(x) as.character(x$id)),
  datetime = map_chr(features, \(x) get_chr(x, "datetime")),
  platform = map_chr(features, \(x) get_chr(x, "platform")),

  # eo:cloud_cover is numeric. Do not use map_chr().
  cloud = map_dbl(features, \(x) get_dbl(x, "eo:cloud_cover")),

  collection_category = map_chr(
    features,
    \(x) get_chr(x, "landsat:collection_category")
  ),

  processing_level = map_chr(
    features,
    \(x) get_chr(x, "landsat:processing_level")
  ),

  has_lwir11 = map_lgl(features, \(x) has_asset(x, "lwir11")),
  has_qa_pixel = map_lgl(features, \(x) has_asset(x, "qa_pixel"))
) |>
  mutate(
    date = as.Date(substr(datetime, 1, 10)),
    month = as.integer(format(date, "%m")),
    out_file = map2_chr(id, date, \(id, date) make_scene_outfile(id, date, scene_dir)),
    out_exists = file.exists(out_file)
  )

meta <- meta_all |>
  filter(platform %in% c("landsat-8", "landsat-9")) |>
  filter(month %in% seasonal_months) |>
  filter(is.na(cloud) | cloud <= max_scene_cloud) |>
  filter(has_lwir11, has_qa_pixel)

if (isTRUE(require_tier1)) {
  meta <- meta |>
    filter(is.na(collection_category) | collection_category == "T1")
}

if (isTRUE(require_l2sp)) {
  meta <- meta |>
    filter(is.na(processing_level) | processing_level == "L2SP")
}

meta <- meta |>
  arrange(date)

if (nrow(meta) == 0) {
  stop("No matching Landsat 8/9 L2SP scenes after filtering.")
}

if (is.finite(max_candidates)) {
  meta <- meta |>
    slice_head(n = max_candidates)
}

readr::write_csv(meta_all, file.path(stac_dir, "stac_metadata_all.csv"))
readr::write_csv(meta,     file.path(stac_dir, "stac_metadata_candidates.csv"))

message("Candidates after filtering: ", nrow(meta))
message("Already local: ", sum(meta$out_exists))


# ------------------------------------------------------------
# 6. QA, signing and scene processing functions
# ------------------------------------------------------------

qa_bit <- function(x, bit) {
  floor(x / 2^bit) %% 2 == 1
}

calc_lst_stats_from_file <- function(file, meta_row) {

  r <- terra::rast(file)
  vals <- terra::values(r, mat = FALSE, na.rm = TRUE)

  if (length(vals) < min_valid_pixels) {
    message("  Local file exists, but has too few valid pixels: ", length(vals))
    return(tibble())
  }

  tibble(
    id = meta_row$id,
    date = meta_row$date,
    datetime = meta_row$datetime,
    platform = meta_row$platform,
    scene_cloud = meta_row$cloud,
    mean_C = mean(vals, na.rm = TRUE),
    median_C = median(vals, na.rm = TRUE),
    q10_C = as.numeric(stats::quantile(vals, probs = 0.10, na.rm = TRUE, names = FALSE)),
    q90_C = as.numeric(stats::quantile(vals, probs = 0.90, na.rm = TRUE, names = FALSE)),
    min_C = min(vals, na.rm = TRUE),
    max_C = max(vals, na.rm = TRUE),
    valid_pixels = length(vals),
    valid_fraction = length(vals) / terra::ncell(r),
    file = file,
    source = "local_existing"
  )
}

sign_single_scene <- function(scene) {

  one_item <- items
  one_item$features <- list(scene)

  one_item_signed <- one_item |>
    rstac::items_sign(rstac::sign_planetary_computer())

  one_item_signed$features[[1]]
}

process_one_scene <- function(scene, meta_row, aoi_4326, out_dir) {

  scene_id <- meta_row$id
  scene_date <- meta_row$date

  out_file <- make_scene_outfile(scene_id, scene_date, out_dir)

  if (isTRUE(skip_existing_outputs) && file.exists(out_file)) {

    message("Use local file, no remote access: ", basename(out_file))

    return(
      calc_lst_stats_from_file(
        file = out_file,
        meta_row = meta_row
      )
    )
  }

  message("Remote processing: ", scene_date, " / ", scene_id)

  # Just-in-time signing prevents expired SAS URLs.
  scene_signed <- sign_single_scene(scene)

  lst_href <- scene_signed$assets$lwir11$href
  qa_href  <- scene_signed$assets$qa_pixel$href

  # Remote COGs are read through GDAL/terra.
  lst_raw <- terra::rast(lst_href)
  qa      <- terra::rast(qa_href)

  # Transform AOI to raster CRS before crop/mask.
  aoi_r <- terra::vect(sf::st_transform(aoi_4326, terra::crs(lst_raw)))

  # Spatial reduction before calculation keeps remote reads smaller.
  lst_raw_crop <- terra::crop(lst_raw, aoi_r, snap = "out")
  qa_crop      <- terra::crop(qa, aoi_r, snap = "out")

  # Landsat Collection 2 Level-2 Surface Temperature:
  # Kelvin  = DN * 0.00341802 + 149.0
  # Celsius = Kelvin - 273.15
  lst_c <- lst_raw_crop * 0.00341802 + 149.0 - 273.15

  # QA_PIXEL bits for Landsat 8/9:
  # 0 Fill
  # 1 Dilated Cloud
  # 2 Cirrus
  # 3 Cloud
  # 4 Cloud Shadow
  # 5 Snow
  # Optional:
  # 7 Water
  bad <- qa_bit(qa_crop, 0) |
    qa_bit(qa_crop, 1) |
    qa_bit(qa_crop, 2) |
    qa_bit(qa_crop, 3) |
    qa_bit(qa_crop, 4) |
    qa_bit(qa_crop, 5) |
    is.na(lst_c) |
    lst_raw_crop == 0

  if (isTRUE(mask_water)) {
    bad <- bad | qa_bit(qa_crop, 7)
  }

  lst_clean <- terra::ifel(bad, NA, lst_c)
  lst_clip <- terra::mask(lst_clean, aoi_r)

  vals <- terra::values(lst_clip, mat = FALSE, na.rm = TRUE)

  if (length(vals) < min_valid_pixels) {
    message("  Skipped: too few valid pixels after QA mask: ", length(vals))
    return(tibble())
  }

  terra::writeRaster(
    lst_clip,
    out_file,
    overwrite = TRUE,
    wopt = list(
      gdal = c(
        "COMPRESS=DEFLATE",
        "TILED=YES",
        "BIGTIFF=IF_SAFER"
      )
    )
  )

  tibble(
    id = scene_id,
    date = scene_date,
    datetime = meta_row$datetime,
    platform = meta_row$platform,
    scene_cloud = meta_row$cloud,
    mean_C = mean(vals, na.rm = TRUE),
    median_C = median(vals, na.rm = TRUE),
    q10_C = as.numeric(stats::quantile(vals, probs = 0.10, na.rm = TRUE, names = FALSE)),
    q90_C = as.numeric(stats::quantile(vals, probs = 0.90, na.rm = TRUE, names = FALSE)),
    min_C = min(vals, na.rm = TRUE),
    max_C = max(vals, na.rm = TRUE),
    valid_pixels = length(vals),
    valid_fraction = length(vals) / terra::ncell(lst_clip),
    file = out_file,
    source = "remote_processed"
  )
}


# ------------------------------------------------------------
# 7. Process all candidate scenes
# ------------------------------------------------------------

message("Calculate LST and scene statistics ...")

results <- purrr::map_dfr(
  seq_len(nrow(meta)),
  function(i) {

    scene <- features[[meta$idx[i]]]
    meta_row <- meta[i, ]

    tryCatch(
      process_one_scene(
        scene = scene,
        meta_row = meta_row,
        aoi_4326 = aoi_4326,
        out_dir = scene_dir
      ),
      error = function(e) {
        message("  Error in scene ", meta_row$id, ": ", conditionMessage(e))
        tibble()
      }
    )
  }
)

if (nrow(results) == 0) {
  stop("No scene could be processed successfully.")
}

all_ranked_file <- file.path(out_dir, "all_processed_scenes_ranked.csv")

results_ranked <- results |>
  arrange(desc(q90_C))

readr::write_csv(results_ranked, all_ranked_file)

message("All processed scene ranking written: ", all_ranked_file)


# ------------------------------------------------------------
# 8. Extreme selection and composite creation
# ------------------------------------------------------------
#
# Hot extremes:
#   highest hot_metric, usually q90_C.
#
# Cold extremes:
#   lowest cold_metric, usually q10_C.
#
# For each selected extreme class:
#   - selected scenes are copied into 04_extremes/<mode>/scenes
#   - aligned rasters are written into 04_extremes/<mode>/aligned
#   - stack is written
#   - median composite is written
#   - q10 and q90 composites are written
#
# ------------------------------------------------------------

q_fun <- function(prob) {
  force(prob)
  function(x) {
    x <- x[!is.na(x)]
    if (length(x) == 0) {
      NA_real_
    } else {
      as.numeric(stats::quantile(x, probs = prob, names = FALSE))
    }
  }
}

build_extreme_products <- function(results, mode_label, metric, n_select, descending = TRUE) {

  if (!metric %in% names(results)) {
    stop("Metric does not exist: ", metric)
  }

  mode_dir <- file.path(extreme_dir, mode_label)
  mode_scene_dir <- file.path(mode_dir, "scenes")
  mode_align_dir <- file.path(mode_dir, "aligned")
  mode_comp_dir  <- file.path(mode_dir, "composites")

  invisible(lapply(
    c(mode_dir, mode_scene_dir, mode_align_dir, mode_comp_dir),
    dir.create,
    recursive = TRUE,
    showWarnings = FALSE
  ))

  if (isTRUE(descending)) {
    selected <- results |>
      arrange(desc(.data[[metric]])) |>
      slice_head(n = n_select)
  } else {
    selected <- results |>
      arrange(.data[[metric]]) |>
      slice_head(n = n_select)
  }

  if (nrow(selected) == 0) {
    warning("No selected scenes for mode: ", mode_label)
    return(NULL)
  }

  selected_files <- file.path(mode_scene_dir, basename(selected$file))

  file.copy(
    from = selected$file,
    to = selected_files,
    overwrite = TRUE
  )

  selected <- selected |>
    mutate(selected_file = selected_files)

  selected_csv <- file.path(mode_dir, paste0(aoi_slug, "_", mode_label, "_selected_scenes.csv"))
  readr::write_csv(selected, selected_csv)

  template <- terra::rast(selected$selected_file[1])
  aligned_files <- character(nrow(selected))

  for (i in seq_len(nrow(selected))) {

    r <- terra::rast(selected$selected_file[i])

    out_aligned <- file.path(
      mode_align_dir,
      paste0(
        "aligned_",
        sprintf("%02d", i),
        "_",
        basename(selected$selected_file[i])
      )
    )

    if (file.exists(out_aligned)) {
      message("Aligned file exists: ", basename(out_aligned))
      aligned_files[i] <- out_aligned
      next
    }

    if (!identical(terra::crs(r, proj = TRUE), terra::crs(template, proj = TRUE))) {
      r <- terra::project(r, template, method = "bilinear")
    } else if (!terra::compareGeom(r, template, stopOnError = FALSE)) {
      r <- terra::resample(r, template, method = "bilinear")
    }

    terra::writeRaster(
      r,
      out_aligned,
      overwrite = TRUE,
      wopt = list(
        gdal = c(
          "COMPRESS=DEFLATE",
          "TILED=YES",
          "BIGTIFF=IF_SAFER"
        )
      )
    )

    aligned_files[i] <- out_aligned
  }

  selected$aligned_file <- aligned_files
  readr::write_csv(selected, selected_csv)

  r_stack <- terra::rast(aligned_files)
  names(r_stack) <- paste0("LST_", format(selected$date, "%Y%m%d"))

  out_stack <- file.path(mode_comp_dir, paste0(aoi_slug, "_LST_", mode_label, "_stack_C.tif"))

  if (!file.exists(out_stack)) {
    terra::writeRaster(
      r_stack,
      out_stack,
      overwrite = TRUE,
      wopt = list(gdal = c("COMPRESS=DEFLATE", "TILED=YES", "BIGTIFF=IF_SAFER"))
    )
  } else {
    message("Stack exists: ", out_stack)
  }

  out_median <- file.path(mode_comp_dir, paste0(aoi_slug, "_LST_", mode_label, "_median_C.tif"))
  out_q10    <- file.path(mode_comp_dir, paste0(aoi_slug, "_LST_", mode_label, "_q10_C.tif"))
  out_q90    <- file.path(mode_comp_dir, paste0(aoi_slug, "_LST_", mode_label, "_q90_C.tif"))

  if (!file.exists(out_median)) {
    r_median <- terra::app(r_stack, fun = median, na.rm = TRUE)
    terra::writeRaster(
      r_median,
      out_median,
      overwrite = TRUE,
      wopt = list(gdal = c("COMPRESS=DEFLATE", "TILED=YES", "BIGTIFF=IF_SAFER"))
    )
  }

  if (!file.exists(out_q10)) {
    r_q10 <- terra::app(r_stack, fun = q_fun(0.10))
    terra::writeRaster(
      r_q10,
      out_q10,
      overwrite = TRUE,
      wopt = list(gdal = c("COMPRESS=DEFLATE", "TILED=YES", "BIGTIFF=IF_SAFER"))
    )
  }

  if (!file.exists(out_q90)) {
    r_q90 <- terra::app(r_stack, fun = q_fun(0.90))
    terra::writeRaster(
      r_q90,
      out_q90,
      overwrite = TRUE,
      wopt = list(gdal = c("COMPRESS=DEFLATE", "TILED=YES", "BIGTIFF=IF_SAFER"))
    )
  }

  list(
    mode = mode_label,
    selected = selected,
    selected_csv = selected_csv,
    stack = out_stack,
    median = out_median,
    q10 = out_q10,
    q90 = out_q90
  )
}

extreme_products <- list()

if (extreme_mode %in% c("hot", "both")) {
  message("Build hot extreme products ...")
  extreme_products$hot <- build_extreme_products(
    results = results,
    mode_label = "hot",
    metric = hot_metric,
    n_select = n_hot,
    descending = TRUE
  )
}

if (extreme_mode %in% c("cold", "both")) {
  message("Build cold extreme products ...")
  extreme_products$cold <- build_extreme_products(
    results = results,
    mode_label = "cold",
    metric = cold_metric,
    n_select = n_cold,
    descending = FALSE
  )
}

saveRDS(extreme_products, file.path(extreme_dir, "extreme_products.rds"))


# ------------------------------------------------------------
# 9. Teaching layers: AOI, admin orientation, OSM and projected LST
# ------------------------------------------------------------
#
# EPSG:25832 GeoPackage:
#   - aoi_boundary
#   - admin_orientation, if available
#   - osm_buildings
#   - osm_green
#   - osm_water
#   - osm_roads
#
# EPSG:3035 GeoPackage:
#   same layers for LUCC workflows
#
# LST products:
#   selected composite rasters are projected to EPSG:25832 and EPSG:3035.
#
# ------------------------------------------------------------

gpkg_25832 <- file.path(teaching_dir, paste0(aoi_slug, "_teaching_layers_EPSG25832.gpkg"))
gpkg_3035  <- file.path(teaching_dir, paste0(aoi_slug, "_teaching_layers_EPSG3035.gpkg"))

write_gpkg_layer(aoi_25832, gpkg_25832, "aoi_boundary")
write_gpkg_layer(aoi_3035,  gpkg_3035,  "aoi_boundary")

if (!is.null(admin_25832)) {
  write_gpkg_layer(admin_25832, gpkg_25832, "admin_orientation")
  write_gpkg_layer(admin_3035,  gpkg_3035,  "admin_orientation")
}

osm_layer_exists <- function(gpkg, layer) {
  if (!file.exists(gpkg)) return(FALSE)
  layer %in% st_layers(gpkg)$name
}

empty_sf <- function(crs) {
  st_sf(geometry = st_sfc(crs = crs))
}

is_osm_transient_error <- function(e) {
  inherits(e, "httr2_http_429") ||
    inherits(e, "httr2_http_502") ||
    inherits(e, "httr2_http_503") ||
    inherits(e, "httr2_http_504") ||
    grepl("429|502|503|504|Too Many Requests|Gateway Timeout|Service Unavailable|Bad Gateway", conditionMessage(e), ignore.case = TRUE)
}

.osm_disabled <- FALSE

set_overpass_endpoint_safe <- function(endpoint) {
  try(
    osmdata::set_overpass_url(endpoint),
    silent = TRUE
  )
  invisible(endpoint)
}

osmdata_sf_retry <- function(q, label = "OSM query") {

  if (isTRUE(.osm_disabled)) {
    message("  ", label, ": OSM disabled after previous Overpass failure. Empty layer.")
    return(empty_sf(4326))
  }

  last_error <- NULL

  for (endpoint in osm_endpoints) {

    set_overpass_endpoint_safe(endpoint)

    for (attempt in seq_len(osm_retry_max)) {

      res <- tryCatch(
        osmdata::osmdata_sf(q),
        error = function(e) e
      )

      if (!inherits(res, "error")) {
        return(res)
      }

      last_error <- res

      message(
        "  ", label,
        ": endpoint failed at ", endpoint,
        " (attempt ", attempt, "/", osm_retry_max, "): ",
        conditionMessage(res)
      )

      if (attempt < osm_retry_max) {
        wait <- osm_retry_wait[min(attempt, length(osm_retry_wait))]
        if (wait > 0) {
          message("  ", label, ": waiting ", wait, " s before retry ...")
          Sys.sleep(wait)
        }
      }
    }
  }

  if (identical(osm_fail_policy, "stop")) {
    stop(last_error)
  }

  if (isTRUE(osm_disable_after_server_error) && !is.null(last_error) && is_osm_transient_error(last_error)) {
    .osm_disabled <<- TRUE
    message("  ", label, ": transient Overpass failure. OSM disabled for the remaining layers in this run.")
  }

  message("  ", label, ": continuing with an empty layer.")

  empty_sf(4326)
}

get_osm_polygons_safe <- function(q, label = "OSM polygon query") {
  res <- osmdata_sf_retry(q, label = label)

  if (inherits(res, "sf")) {
    return(res)
  }

  polys <- res$osm_polygons
  multipolys <- res$osm_multipolygons

  out <- list()

  if (!is.null(polys) && nrow(polys) > 0) {
    out <- append(out, list(polys))
  }

  if (!is.null(multipolys) && nrow(multipolys) > 0) {
    out <- append(out, list(multipolys))
  }

  if (length(out) == 0) {
    return(empty_sf(4326))
  }

  bind_rows(out) |>
    st_make_valid()
}

get_osm_lines_safe <- function(q, label = "OSM line query") {
  res <- osmdata_sf_retry(q, label = label)

  if (inherits(res, "sf")) {
    return(res)
  }

  lines <- res$osm_lines

  if (is.null(lines) || nrow(lines) == 0) {
    return(empty_sf(4326))
  }

  lines |>
    st_make_valid()
}


# OSM feature logic:
# add_osm_feature() is kept to one key at a time. This avoids accidental
# AND logic or version-dependent behaviour when several keys are passed at
# once. For thematic groups such as "green" or "water", several simple
# queries are executed and then combined.
combine_sf <- function(x, crs = 4326) {
  x <- x[vapply(x, function(z) !is.null(z) && nrow(z) > 0, logical(1))]
  if (length(x) == 0) {
    return(empty_sf(crs))
  }
  bind_rows(x) |>
    st_make_valid()
}

get_osm_polygons_multi <- function(bbox, specs, timeout = osm_timeout) {
  parts <- lapply(specs, function(spec) {
    tryCatch(
      {
        q <- opq(bbox = bbox, timeout = timeout) |>
          add_osm_feature(key = spec$key, value = spec$value)
        get_osm_polygons_safe(q, label = paste0("OSM polygons: ", spec$key))
      },
      error = function(e) {
        message("  OSM polygon query failed for key=", spec$key, ": ", conditionMessage(e))
        empty_sf(4326)
      }
    )
  })

  combine_sf(parts, crs = 4326)
}

clip_to_aoi <- function(x, aoi) {
  if (nrow(x) == 0) return(x)
  suppressWarnings(st_intersection(x, aoi))
}

if (isTRUE(load_osm_layers)) {

  aoi_osm_4326 <- st_transform(aoi_4326, 4326)
  osm_bbox <- st_bbox(aoi_osm_4326)

  if (!isTRUE(osm_load_buildings)) {

    message("OSM-Gebäude werden übersprungen (osm_load_buildings = FALSE).")
    osm_buildings_25832 <- empty_sf(crs_qgis)

  } else if (!osm_layer_exists(gpkg_25832, "osm_buildings")) {

    message("Lade OSM-Gebäude ...")

    q_buildings <- opq(bbox = osm_bbox, timeout = osm_timeout) |>
      add_osm_feature(key = "building")

    osm_buildings_4326 <- get_osm_polygons_safe(q_buildings, label = "OSM buildings")

    if (nrow(osm_buildings_4326) > 0) {
      osm_buildings_25832 <- osm_buildings_4326 |>
        st_transform(crs_qgis) |>
        clip_to_aoi(aoi_25832) |>
        select(any_of(c("osm_id", "name", "building")), geometry)
    } else {
      osm_buildings_25832 <- empty_sf(crs_qgis)
    }

  } else {
    osm_buildings_25832 <- st_read(gpkg_25832, layer = "osm_buildings", quiet = TRUE)
  }

  if (!osm_layer_exists(gpkg_25832, "osm_green")) {

    message("Lade OSM-Grünflächen ...")

    green_specs <- list(
      list(key = "leisure", value = c("park", "garden", "recreation_ground")),
      list(key = "landuse", value = c("grass", "forest", "cemetery", "meadow")),
      list(key = "natural", value = c("wood", "scrub", "grassland"))
    )

    osm_green_4326 <- get_osm_polygons_multi(osm_bbox, green_specs)

    if (nrow(osm_green_4326) > 0) {
      osm_green_25832 <- osm_green_4326 |>
        st_transform(crs_qgis) |>
        clip_to_aoi(aoi_25832) |>
        select(any_of(c("osm_id", "name", "leisure", "landuse", "natural")), geometry)
    } else {
      osm_green_25832 <- empty_sf(crs_qgis)
    }

  } else {
    osm_green_25832 <- st_read(gpkg_25832, layer = "osm_green", quiet = TRUE)
  }

  if (!osm_layer_exists(gpkg_25832, "osm_water")) {

    message("Lade OSM-Wasserflächen ...")

    water_specs <- list(
      list(key = "natural", value = "water"),
      list(key = "water", value = c("reservoir", "basin", "lake", "pond", "river")),
      list(key = "landuse", value = "reservoir")
    )

    osm_water_4326 <- get_osm_polygons_multi(osm_bbox, water_specs)

    if (nrow(osm_water_4326) > 0) {
      osm_water_25832 <- osm_water_4326 |>
        st_transform(crs_qgis) |>
        clip_to_aoi(aoi_25832) |>
        select(any_of(c("osm_id", "name", "natural", "water", "landuse")), geometry)
    } else {
      osm_water_25832 <- empty_sf(crs_qgis)
    }

  } else {
    osm_water_25832 <- st_read(gpkg_25832, layer = "osm_water", quiet = TRUE)
  }

  if (!osm_layer_exists(gpkg_25832, "osm_roads")) {

    message("Lade OSM-Straßen ...")

    q_roads <- opq(bbox = osm_bbox, timeout = osm_timeout) |>
      add_osm_feature(
        key = "highway",
        value = c(
          "motorway",
          "trunk",
          "primary",
          "secondary",
          "tertiary",
          "residential",
          "service",
          "pedestrian",
          "cycleway",
          "footway",
          "path"
        )
      )

    osm_roads_4326 <- get_osm_lines_safe(q_roads, label = "OSM roads")

    if (nrow(osm_roads_4326) > 0) {
      osm_roads_25832 <- osm_roads_4326 |>
        st_transform(crs_qgis) |>
        clip_to_aoi(aoi_25832) |>
        select(any_of(c("osm_id", "name", "highway")), geometry)
    } else {
      osm_roads_25832 <- empty_sf(crs_qgis)
    }

  } else {
    osm_roads_25832 <- st_read(gpkg_25832, layer = "osm_roads", quiet = TRUE)
  }

} else {

  osm_buildings_25832 <- empty_sf(crs_qgis)
  osm_green_25832     <- empty_sf(crs_qgis)
  osm_water_25832     <- empty_sf(crs_qgis)
  osm_roads_25832     <- empty_sf(crs_qgis)
}

osm_buildings_3035 <- st_transform(osm_buildings_25832, crs_lucc)
osm_green_3035     <- st_transform(osm_green_25832, crs_lucc)
osm_water_3035     <- st_transform(osm_water_25832, crs_lucc)
osm_roads_3035     <- st_transform(osm_roads_25832, crs_lucc)

write_gpkg_layer(osm_buildings_25832, gpkg_25832, "osm_buildings")
write_gpkg_layer(osm_green_25832,     gpkg_25832, "osm_green")
write_gpkg_layer(osm_water_25832,     gpkg_25832, "osm_water")
write_gpkg_layer(osm_roads_25832,     gpkg_25832, "osm_roads")

write_gpkg_layer(osm_buildings_3035, gpkg_3035, "osm_buildings")
write_gpkg_layer(osm_green_3035,     gpkg_3035, "osm_green")
write_gpkg_layer(osm_water_3035,     gpkg_3035, "osm_water")
write_gpkg_layer(osm_roads_3035,     gpkg_3035, "osm_roads")


# ------------------------------------------------------------
# 10. Project selected LST composites to QGIS/LUCC CRS
# ------------------------------------------------------------

projected_lst_dir <- file.path(teaching_dir, "projected_lst")
dir.create(projected_lst_dir, recursive = TRUE, showWarnings = FALSE)

reproject_raster_if_missing <- function(infile, outfile, crs) {
  if (!file.exists(infile)) {
    warning("Input raster missing: ", infile)
    return(invisible(FALSE))
  }

  if (file.exists(outfile)) {
    message("Raster exists: ", outfile)
    return(invisible(TRUE))
  }

  r <- terra::rast(infile)
  r_proj <- terra::project(r, paste0("EPSG:", crs), method = "bilinear")

  terra::writeRaster(
    r_proj,
    outfile,
    overwrite = TRUE,
    wopt = list(gdal = c("COMPRESS=DEFLATE", "TILED=YES", "BIGTIFF=IF_SAFER"))
  )

  invisible(TRUE)
}

lst_project_table <- tibble()

for (mode_name in names(extreme_products)) {

  p <- extreme_products[[mode_name]]

  if (is.null(p)) next

  candidates <- tibble(
    mode = mode_name,
    product = c("median", "q10", "q90"),
    infile = c(p$median, p$q10, p$q90)
  )

  for (i in seq_len(nrow(candidates))) {

    mode <- candidates$mode[i]
    product <- candidates$product[i]
    infile <- candidates$infile[i]

    out_25832 <- file.path(
      projected_lst_dir,
      paste0(aoi_slug, "_LST_", mode, "_", product, "_C_EPSG25832.tif")
    )

    out_3035 <- file.path(
      projected_lst_dir,
      paste0(aoi_slug, "_LST_", mode, "_", product, "_C_EPSG3035.tif")
    )

    reproject_raster_if_missing(infile, out_25832, crs_qgis)
    reproject_raster_if_missing(infile, out_3035,  crs_lucc)

    lst_project_table <- bind_rows(
      lst_project_table,
      tibble(
        mode = mode,
        product = product,
        original = infile,
        epsg25832 = out_25832,
        epsg3035 = out_3035
      )
    )
  }
}

lst_project_table_file <- file.path(projected_lst_dir, "projected_lst_products.csv")
readr::write_csv(lst_project_table, lst_project_table_file)



# ------------------------------------------------------------
# 10b. Optional local RGB aerial image from WMS
# ------------------------------------------------------------
#
# The WMS is the primary high-resolution aerial image source in QGIS.
# The optional local RGB raster is only a controlled overview/cache layer
# for offline teaching packages and stable printing. It prevents the
# common problem that externally requested imagery is treated as grey or
# is unavailable during a class.
#
# The image is requested as a WMS GetMap in EPSG:25832 and then written as
# a georeferenced 3-band RGB GeoTIFF.
#
# ------------------------------------------------------------

aerial_dir <- file.path(teaching_dir, "aerial")
dir.create(aerial_dir, recursive = TRUE, showWarnings = FALSE)

local_aerial_rgb <- file.path(aerial_dir, paste0(aoi_slug, "_aerial_rgb_EPSG25832.tif"))

build_wms_getmap_url <- function(base_url, layer, bbox, width, height, crs, format = "image/jpeg") {

  base_url <- sub("\\?$", "", base_url)

  params <- c(
    SERVICE = "WMS",
    VERSION = "1.1.1",
    REQUEST = "GetMap",
    LAYERS = layer,
    STYLES = "",
    SRS = paste0("EPSG:", crs),
    BBOX = paste(
      formatC(c(bbox["xmin"], bbox["ymin"], bbox["xmax"], bbox["ymax"]), format = "f", digits = 3),
      collapse = ","
    ),
    WIDTH = as.character(width),
    HEIGHT = as.character(height),
    FORMAT = format,
    TRANSPARENT = "FALSE"
  )

  query <- paste(
    paste0(names(params), "=", utils::URLencode(params, reserved = TRUE)),
    collapse = "&"
  )

  paste0(base_url, ifelse(grepl("\\?", base_url), "&", "?"), query)
}

download_local_aerial_rgb <- function(outfile) {

  if (!isTRUE(add_local_rgb_aerial)) {
    message("Lokales RGB-Luftbild deaktiviert.")
    return(NA_character_)
  }

  if (file.exists(outfile)) {
    message("Lokales RGB-Luftbild existiert bereits: ", outfile)
    return(outfile)
  }

  bbox_25832 <- st_bbox(aoi_25832)

  dx <- as.numeric(bbox_25832["xmax"] - bbox_25832["xmin"])
  dy <- as.numeric(bbox_25832["ymax"] - bbox_25832["ymin"])

  width <- ceiling(dx / aerial_rgb_target_res_m)
  height <- ceiling(dy / aerial_rgb_target_res_m)

  scale_factor <- max(width, height) / aerial_rgb_max_dim

  if (scale_factor > 1) {
    width <- max(1, floor(width / scale_factor))
    height <- max(1, floor(height / scale_factor))
  }

  message(
    "Lade lokales RGB-Luftbild über WMS: ",
    width, " x ", height, " px"
  )

  ext <- tools::file_ext(outfile)
  tmp <- tempfile(fileext = ifelse(grepl("jpeg|jpg", aerial_rgb_format), ".jpg", ".png"))

  url <- build_wms_getmap_url(
    base_url = aerial_wms_url,
    layer = aerial_wms_layer,
    bbox = bbox_25832,
    width = width,
    height = height,
    crs = crs_qgis,
    format = aerial_rgb_format
  )

  ok <- tryCatch(
    {
      utils::download.file(url, tmp, mode = "wb", quiet = TRUE)
      TRUE
    },
    error = function(e) {
      message("  RGB-Luftbild konnte nicht geladen werden: ", conditionMessage(e))
      FALSE
    }
  )

  if (!isTRUE(ok) || !file.exists(tmp) || file.info(tmp)$size < 1000) {
    message("  Kein gültiges RGB-Luftbild empfangen. WMS bleibt als Online-Layer erhalten.")
    return(NA_character_)
  }

  r <- tryCatch(
    terra::rast(tmp),
    error = function(e) {
      message("  RGB-Luftbild konnte nicht als Raster gelesen werden: ", conditionMessage(e))
      NULL
    }
  )

  if (is.null(r)) {
    return(NA_character_)
  }

  # Keep only RGB if an alpha channel is present.
  if (terra::nlyr(r) >= 3) {
    r <- r[[1:3]]
    names(r) <- c("red", "green", "blue")
  } else {
    message("  WMS-Antwort ist kein RGB-Raster. Erhaltene Bandzahl: ", terra::nlyr(r))
    return(NA_character_)
  }

  terra::ext(r) <- terra::ext(
    as.numeric(bbox_25832["xmin"]),
    as.numeric(bbox_25832["xmax"]),
    as.numeric(bbox_25832["ymin"]),
    as.numeric(bbox_25832["ymax"])
  )

  terra::crs(r) <- paste0("EPSG:", crs_qgis)

  terra::writeRaster(
    r,
    outfile,
    overwrite = TRUE,
    wopt = list(
      gdal = c(
        "COMPRESS=JPEG",
        "JPEG_QUALITY=85",
        "PHOTOMETRIC=RGB",
        "INTERLEAVE=PIXEL",
        "TILED=YES",
        "BIGTIFF=IF_SAFER"
      )
    )
  )

  outfile
}

local_aerial_rgb <- download_local_aerial_rgb(local_aerial_rgb)


# ------------------------------------------------------------
# 11. Write a portable QGIS project file directly (.qgs XML)
# ------------------------------------------------------------
#
# This section intentionally does NOT call QGIS and does NOT use PyQGIS.
# A QGIS project file is plain XML. For teaching packages this is more
# robust than generating a project through the QGIS Python environment.
#
# Output:
#   06_qgis_project/<AOI>_lst_teaching_project.qgs
#
# Path principle:
#   All layer sources are written as relative paths from the .qgs file to
#   the local AOI package. The complete <AOI>/ directory can therefore be
#   moved as one unit.
#
# Notes:
#   - The project is deliberately simple and portable.
#   - QGIS will apply its default renderers if a renderer block is omitted.
#   - The WMS layer is included as a normal QGIS WMS datasource. If a local
#     installation blocks WMS access, the local vector and raster layers
#     still load.
#
# ------------------------------------------------------------

as_posix <- function(x) {
  gsub("\\\\", "/", x)
}

xml_escape <- function(x) {
  x <- as.character(x)
  x <- gsub("&", "&amp;", x, fixed = TRUE)
  x <- gsub("<", "&lt;", x, fixed = TRUE)
  x <- gsub(">", "&gt;", x, fixed = TRUE)
  x <- gsub('"', "&quot;", x, fixed = TRUE)
  x
}

qgis_project_file <- file.path(qgis_dir, paste0(aoi_slug, "_lst_teaching_project.qgs"))

# Relative paths from 06_qgis_project/ to 05_teaching_layers/.
rel_teaching <- function(path) {
  as_posix(file.path("..", "05_teaching_layers", basename(path)))
}

rel_projected_lst <- function(path) {
  as_posix(file.path("..", "05_teaching_layers", "projected_lst", basename(path)))
}

rel_aerial <- function(path) {
  as_posix(file.path("..", "05_teaching_layers", "aerial", basename(path)))
}

# A compact CRS block is sufficient for EPSG-based project/layer CRS.
qgis_srs_xml <- function(epsg) {
  paste0(
'      <srs>
        <spatialrefsys nativeFormat="Wkt">
          <wkt></wkt>
          <proj4></proj4>
          <srsid>0</srsid>
          <srid>', epsg, '</srid>
          <authid>EPSG:', epsg, '</authid>
          <description>EPSG:', epsg, '</description>
          <projectionacronym></projectionacronym>
          <ellipsoidacronym></ellipsoidacronym>
          <geographicflag>false</geographicflag>
        </spatialrefsys>
      </srs>'
  )
}

make_layer_id <- function(prefix, i, name) {
  raw <- paste(prefix, i, name, sep = "_")
  raw <- safe_filename(raw)
  paste0(raw, "_", sprintf("%03d", i))
}

# Layer registry ---------------------------------------------------------

layers <- list()

add_layer <- function(group, name, type, provider, datasource, epsg = crs_qgis, opacity = NA_real_, raster_kind = "generic") {
  i <- length(layers) + 1
  id <- make_layer_id(type, i, name)

  layers[[i]] <<- list(
    id = id,
    group = group,
    name = name,
    type = type,
    provider = provider,
    datasource = datasource,
    epsg = epsg,
    opacity = opacity,
    raster_kind = raster_kind
  )

  invisible(id)
}

# Local RGB aerial raster has priority for teaching use.
if (!is.na(local_aerial_rgb) && file.exists(local_aerial_rgb)) {
  add_layer(
    group = "01 Luftbild / Orientierung",
    name = "Luftbild lokal RGB",
    type = "raster",
    provider = "gdal",
    datasource = rel_aerial(local_aerial_rgb),
    epsg = crs_qgis,
    opacity = aerial_opacity,
    raster_kind = "rgb"
  )
}

# Optional aerial WMS
if (isTRUE(add_aerial_wms)) {
  wms_url <- sub("\\?$", "", aerial_wms_url)

  wms_source <- paste0(
    "crs=EPSG:", crs_qgis,
    "&dpiMode=7",
    "&format=", aerial_rgb_format,
    "&layers=", aerial_wms_layer,
    "&styles",
    "&tilePixelRatio=0",
    "&url=", utils::URLencode(wms_url, reserved = TRUE)
  )

  add_layer(
    group = "01 Luftbild / Orientierung",
    name = aerial_wms_name,
    type = "raster",
    provider = "wms",
    datasource = wms_source,
    epsg = crs_qgis,
    opacity = aerial_opacity,
    raster_kind = "wms"
  )
}

# LST rasters
if (nrow(lst_project_table) > 0) {
  for (i in seq_len(nrow(lst_project_table))) {
    lst_mode <- as.character(lst_project_table$mode[i])

    add_layer(
      group = "02 LST-Karten",
      name = paste("LST", lst_mode, lst_project_table$product[i], "[°C]"),
      type = "raster",
      provider = "gdal",
      datasource = rel_projected_lst(lst_project_table$epsg25832[i]),
      epsg = crs_qgis,
      opacity = 0.75,
      raster_kind = ifelse(
        identical(lst_mode, "hot"),
        "lst_hot",
        ifelse(identical(lst_mode, "cold"), "lst_cold", "lst_generic")
      )
    )
  }
}

# Vector layers from the teaching GeoPackage
gpkg_source <- rel_teaching(gpkg_25832)

add_layer(
  group = "03 AOI / Verwaltungsgrenzen",
  name = "AOI-Grenze",
  type = "vector",
  provider = "ogr",
  datasource = paste0(gpkg_source, "|layername=aoi_boundary"),
  epsg = crs_qgis
)

if (!is.null(admin_25832)) {
  add_layer(
    group = "03 AOI / Verwaltungsgrenzen",
    name = "Verwaltungs-/Orientierungsgrenzen",
    type = "vector",
    provider = "ogr",
    datasource = paste0(gpkg_source, "|layername=admin_orientation"),
    epsg = crs_qgis
  )
}

add_layer(
  group = "04 OSM-Strukturlayer",
  name = "Gebäude OSM",
  type = "vector",
  provider = "ogr",
  datasource = paste0(gpkg_source, "|layername=osm_buildings"),
  epsg = crs_qgis
)

add_layer(
  group = "04 OSM-Strukturlayer",
  name = "Parks / Grünflächen OSM",
  type = "vector",
  provider = "ogr",
  datasource = paste0(gpkg_source, "|layername=osm_green"),
  epsg = crs_qgis
)

add_layer(
  group = "04 OSM-Strukturlayer",
  name = "Wasserflächen OSM",
  type = "vector",
  provider = "ogr",
  datasource = paste0(gpkg_source, "|layername=osm_water"),
  epsg = crs_qgis
)

add_layer(
  group = "04 OSM-Strukturlayer",
  name = "Straßen OSM",
  type = "vector",
  provider = "ogr",
  datasource = paste0(gpkg_source, "|layername=osm_roads"),
  epsg = crs_qgis
)

# XML writers ------------------------------------------------------------

layer_tree_layer_xml <- function(layer) {
  paste0(
'      <layer-tree-layer expanded="1" checked="Qt::Checked" providerKey="', xml_escape(layer$provider), '" source="', xml_escape(layer$datasource), '" name="', xml_escape(layer$name), '" id="', xml_escape(layer$id), '">
        <customproperties/>
      </layer-tree-layer>'
  )
}

layer_tree_group_xml <- function(group_name, layer_list) {
  group_layers <- Filter(function(x) identical(x$group, group_name), layer_list)

  if (length(group_layers) == 0) {
    return("")
  }

  paste0(
'    <layer-tree-group expanded="1" checked="Qt::Checked" name="', xml_escape(group_name), '">
      <customproperties/>
',
    paste(vapply(group_layers, layer_tree_layer_xml, character(1)), collapse = "\n"),
'
    </layer-tree-group>'
  )
}

qgis_quantile_breaks <- function(datasource, n = 5) {
  # datasource is relative to the .qgs file. Build an existing path for terra.
  raster_path <- datasource
  if (!file.exists(raster_path)) {
    raster_path <- file.path(qgis_dir, datasource)
  }

  if (!file.exists(raster_path)) {
    return(NULL)
  }

  r <- tryCatch(
    terra::rast(raster_path),
    error = function(e) NULL
  )

  if (is.null(r)) {
    return(NULL)
  }

  vals <- tryCatch(
    terra::values(r[[1]], mat = FALSE, na.rm = TRUE),
    error = function(e) numeric()
  )

  vals <- vals[is.finite(vals)]

  if (length(vals) == 0) {
    return(NULL)
  }

  brks <- as.numeric(stats::quantile(
    vals,
    probs = seq(0, 1, length.out = n + 1),
    na.rm = TRUE,
    names = FALSE
  ))

  # Avoid duplicate breaks if a raster has too little value spread.
  brks <- unique(brks)

  if (length(brks) < 2) {
    return(NULL)
  }

  brks
}

format_break_label <- function(a, b) {
  paste0(format(round(a, 1), nsmall = 1), " – ", format(round(b, 1), nsmall = 1), " °C")
}

pseudocolor_items_xml <- function(breaks, colors) {
  n <- length(breaks) - 1
  colors <- colors[seq_len(n)]

  items <- character(n)

  for (i in seq_len(n)) {
    items[i] <- paste0(
      '            <item alpha="255" value="', breaks[i + 1], '" label="',
      xml_escape(format_break_label(breaks[i], breaks[i + 1])),
      '" color="', colors[i], '"/>'
    )
  }

  paste(items, collapse = "\n")
}

raster_pipe_xml <- function(layer) {
  if (!identical(layer$type, "raster")) {
    return("")
  }

  opacity <- ifelse(is.na(layer$opacity), "1", as.character(layer$opacity))

  if (identical(layer$raster_kind, "wms")) {
    # WMS is server-rendered. Do not force a single-band renderer here.
    return("")
  }

  if (identical(layer$raster_kind, "rgb")) {
    return(
      paste0(
'      <pipe>
        <rasterrenderer type="multibandcolor" opacity="', opacity, '" redBand="1" greenBand="2" blueBand="3" alphaBand="-1">
          <rasterTransparency/>
          <redContrastEnhancement>
            <minValue>0</minValue>
            <maxValue>255</maxValue>
            <algorithm>StretchToMinimumMaximum</algorithm>
          </redContrastEnhancement>
          <greenContrastEnhancement>
            <minValue>0</minValue>
            <maxValue>255</maxValue>
            <algorithm>StretchToMinimumMaximum</algorithm>
          </greenContrastEnhancement>
          <blueContrastEnhancement>
            <minValue>0</minValue>
            <maxValue>255</maxValue>
            <algorithm>StretchToMinimumMaximum</algorithm>
          </blueContrastEnhancement>
        </rasterrenderer>
      </pipe>
')
    )
  }

  if (identical(layer$raster_kind, "lst_hot") || identical(layer$raster_kind, "lst_cold")) {

    breaks <- qgis_quantile_breaks(layer$datasource, n = 5)

    if (is.null(breaks)) {
      # Safe fallback if the raster cannot be read during project creation.
      return(
        paste0(
'      <pipe>
        <rasterrenderer type="singlebandgray" opacity="', opacity, '" grayBand="1" alphaBand="-1"/>
      </pipe>
')
      )
    }

    n <- length(breaks) - 1

    turbo_5 <- c(
      "#30123b",
      "#28bceb",
      "#a2fc3c",
      "#fb8022",
      "#7a0403"
    )

    spectral_5 <- c(
      "#2c7bb6",
      "#abd9e9",
      "#ffffbf",
      "#fdae61",
      "#d7191c"
    )

    colors <- if (identical(layer$raster_kind, "lst_hot")) turbo_5 else spectral_5
    colors <- colors[seq_len(n)]

    return(
      paste0(
'      <pipe>
        <rasterrenderer type="singlebandpseudocolor" opacity="', opacity, '" band="1" alphaBand="-1" classificationMin="', breaks[1], '" classificationMax="', breaks[length(breaks)], '">
          <rasterTransparency/>
          <rastershader>
            <colorrampshader colorRampType="DISCRETE" classificationMode="2" clip="0" minimumValue="', breaks[1], '" maximumValue="', breaks[length(breaks)], '">
',
        pseudocolor_items_xml(breaks, colors),
'
            </colorrampshader>
          </rastershader>
        </rasterrenderer>
      </pipe>
')
    )
  }

  return(
    paste0(
'      <pipe>
        <rasterrenderer type="singlebandgray" opacity="', opacity, '" grayBand="1" alphaBand="-1"/>
      </pipe>
')
  )
}


maplayer_xml <- function(layer) {

  opacity_xml <- ""
  if (!is.na(layer$opacity)) {
    opacity_xml <- paste0("      <opacity>", layer$opacity, "</opacity>\n")
  }

  layer_type <- if (identical(layer$type, "vector")) "vector" else "raster"

  geometry_xml <- ""
  if (identical(layer$type, "vector")) {
    geometry_xml <- "      <geometry>Unknown</geometry>\n"
  }

  paste0(
'    <maplayer styleCategories="AllStyleCategories" simplifyMaxScale="1" refreshOnNotifyMessage="" autoRefreshMode="Disabled" refreshOnNotifyEnabled="0" autoRefreshTime="0" type="', layer_type, '" hasScaleBasedVisibilityFlag="0">
      <id>', xml_escape(layer$id), '</id>
      <datasource>', xml_escape(layer$datasource), '</datasource>
      <layername>', xml_escape(layer$name), '</layername>
',
      qgis_srs_xml(layer$epsg), "\n",
      geometry_xml,
      opacity_xml,
      raster_pipe_xml(layer),
'      <provider encoding="UTF-8">', xml_escape(layer$provider), '</provider>
      <customproperties/>
      <blendMode>0</blendMode>
      <legend type="default-vector"/>
      <referencedLayers/>
    </maplayer>'
  )
}

project_groups <- c(
  "01 Luftbild / Orientierung",
  "02 LST-Karten",
  "03 AOI / Verwaltungsgrenzen",
  "04 OSM-Strukturlayer"
)

qgs_xml <- paste0(
'<!DOCTYPE qgis PUBLIC "http://mrcc.com/qgis.dtd" "SYSTEM">
<QGIS version="3.34.0" projectname="', xml_escape(paste0(aoi_name, " LST Teaching Project")), '">
  <homePath path="."/>
  <title>', xml_escape(paste0(aoi_name, " LST Teaching Project")), '</title>

  <projectCrs>
    <spatialrefsys nativeFormat="Wkt">
      <wkt></wkt>
      <proj4></proj4>
      <srsid>0</srsid>
      <srid>', crs_qgis, '</srid>
      <authid>EPSG:', crs_qgis, '</authid>
      <description>EPSG:', crs_qgis, '</description>
      <projectionacronym></projectionacronym>
      <ellipsoidacronym></ellipsoidacronym>
      <geographicflag>false</geographicflag>
    </spatialrefsys>
  </projectCrs>

  <layer-tree-group expanded="1" checked="Qt::Checked" name="">
    <customproperties/>
',
  paste(vapply(project_groups, layer_tree_group_xml, character(1), layer_list = layers), collapse = "\n"),
'
  </layer-tree-group>

  <projectlayers>
',
  paste(vapply(layers, maplayer_xml, character(1)), collapse = "\n"),
'
  </projectlayers>

  <properties>
    <Gui>
      <SelectionColorRedPart type="int">255</SelectionColorRedPart>
      <SelectionColorGreenPart type="int">255</SelectionColorGreenPart>
      <SelectionColorBluePart type="int">0</SelectionColorBluePart>
    </Gui>
    <SpatialRefSys>
      <ProjectCRSProj4String type="QString"></ProjectCRSProj4String>
      <ProjectCrs type="QString">EPSG:', crs_qgis, '</ProjectCrs>
      <ProjectCRSID type="int">0</ProjectCRSID>
    </SpatialRefSys>
  </properties>
</QGIS>
'
)

writeLines(qgs_xml, qgis_project_file)

message("QGIS project written directly: ", qgis_project_file)
message("Open this .qgs file directly in QGIS. No PyQGIS, no reticulate and no qgis --code call are required.")

# ------------------------------------------------------------
# 12. Final manifest
# ------------------------------------------------------------

manifest <- list(
  out_dir = as_posix(out_dir),
  config = as_posix(file.path(cfg_dir, "run_config.json")),
  aoi_gpkg = as_posix(aoi_gpkg),
  stac_items = as_posix(file.path(stac_dir, "stac_items_unsigned.rds")),
  stac_metadata_all = as_posix(file.path(stac_dir, "stac_metadata_all.csv")),
  stac_metadata_candidates = as_posix(file.path(stac_dir, "stac_metadata_candidates.csv")),
  processed_scene_dir = as_posix(scene_dir),
  all_ranked_scenes = as_posix(all_ranked_file),
  extreme_products_rds = as_posix(file.path(extreme_dir, "extreme_products.rds")),
  teaching_gpkg_25832 = as_posix(gpkg_25832),
  teaching_gpkg_3035 = as_posix(gpkg_3035),
  projected_lst_products = as_posix(lst_project_table_file),
  local_aerial_rgb = ifelse(is.na(local_aerial_rgb), NA_character_, as_posix(local_aerial_rgb)),
  qgis_project_file = as_posix(qgis_project_file)
)

manifest_file <- file.path(out_dir, "manifest.json")
jsonlite::write_json(manifest, manifest_file, pretty = TRUE, auto_unbox = TRUE)

message("")
message("Done.")
message("AOI output directory: ", out_dir)
message("Manifest: ", manifest_file)
message("")
message("Main outputs:")
message("  AOI package:              ", aoi_gpkg)
message("  Processed scenes:         ", scene_dir)
message("  Scene ranking CSV:        ", all_ranked_file)
message("  Extremes directory:       ", extreme_dir)
message("  Teaching GPKG EPSG:25832: ", gpkg_25832)
message("  Teaching GPKG EPSG:3035:  ", gpkg_3035)
message("  Projected LST table:      ", lst_project_table_file)
message("  Aerial source mode:       ", aerial_source_mode)
message("  Aerial opacity:           ", aerial_opacity)
message("  Local RGB aerial:         ", ifelse(is.na(local_aerial_rgb), "not created", local_aerial_rgb))
message("  QGIS project file:        ", qgis_project_file)
message("")

print(
  results_ranked |>
    select(
      date,
      platform,
      scene_cloud,
      mean_C,
      median_C,
      q10_C,
      q90_C,
      min_C,
      max_C,
      valid_fraction,
      source,
      file
    ) |>
    arrange(desc(q90_C)) |>
    slice_head(n = 20)
)
