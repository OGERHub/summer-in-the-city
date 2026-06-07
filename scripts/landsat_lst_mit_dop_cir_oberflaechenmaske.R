#!/usr/bin/env Rscript

# ============================================================
# landsat_lst_mit_dop_cir_oberflaechenmaske.R
# ============================================================
#
# Landsat-LST-Workflow mit DOP-CIR-Oberflächenmaske.
#
# Dieses Skript wird ausschließlich durch
# scripts/00_run_lst_oberflaechenmaske.R gestartet.
#
# ============================================================

# ------------------------------------------------------------
# 0. Pflichtparameter prüfen
# ------------------------------------------------------------

required_parameters <- c(
  "root_folder",
  "script_dir",
  "aoi_name",
  "aoi_mode",
  "project_root",
  "aoi_file",
  "aoi_layer",
  "aoi_bbox",
  "admin_file",
  "admin_layer",
  "date_start",
  "date_end",
  "seasonal_months",
  "crs_qgis",
  "crs_lucc",
  "extreme_mode",
  "n_hot",
  "hot_metric",
  "max_scene_cloud",
  "require_tier1",
  "require_l2sp",
  "max_candidates",
  "mask_water",
  "min_valid_pixels",
  "skip_existing_outputs",
  "aerial_source_mode",
  "aerial_wms_name",
  "aerial_wms_url",
  "aerial_wms_layer",
  "aerial_opacity",
  "aerial_rgb_format",
  "aerial_rgb_max_dim",
  "aerial_rgb_target_res_m",
  "run_qgis_project_creation"
)

script_env <- environment()

missing_parameters <- required_parameters[!vapply(
  required_parameters,
  function(x) exists(x, envir = script_env, inherits = FALSE),
  logical(1)
)]

if (length(missing_parameters) > 0) {
  stop(
    "Fehlende Parameter im Runner: ",
    paste(missing_parameters, collapse = ", ")
  )
}


# ------------------------------------------------------------
# 1. Pakete
# ------------------------------------------------------------

pkgs <- c(
  "sf",
  "terra",
  "rstac",
  "dplyr",
  "purrr",
  "tibble",
  "readr",
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
library(jsonlite)

# ------------------------------------------------------------
# 2. Abgeleitete Pfade
# ------------------------------------------------------------

safe_filename <- function(x) {
  x <- iconv(x, from = "", to = "ASCII//TRANSLIT")
  x <- tolower(x)
  x <- gsub("[^a-z0-9_\\-]+", "_", x)
  x <- gsub("_+", "_", x)
  x <- gsub("^_|_$", "", x)
  
  if (!nzchar(x)) {
    x <- "aoi"
  }
  
  x
}

aoi_slug <- safe_filename(aoi_name)

out_dir <- file.path(project_root, aoi_slug)

aoi_dir      <- file.path(out_dir, "01_aoi")
stac_dir     <- file.path(out_dir, "02_stac")
scene_dir    <- file.path(out_dir, "03_landsat_scenes", "all_processed_lst_c")
extreme_dir  <- file.path(out_dir, "04_extremes")
teaching_dir <- file.path(out_dir, "05_teaching_layers")
qgis_dir     <- file.path(out_dir, "06_qgis_project")
log_dir      <- file.path(out_dir, "99_logs")

dop_cir_surface_dir <- file.path(teaching_dir, "dop_cir_surface_mask")

all_dirs <- c(
  aoi_dir,
  stac_dir,
  scene_dir,
  extreme_dir,
  teaching_dir,
  qgis_dir,
  log_dir,
  dop_cir_surface_dir
)

invisible(lapply(all_dirs, dir.create, recursive = TRUE, showWarnings = FALSE))

add_aerial_wms <- aerial_source_mode %in% c("wms", "both")
add_local_rgb_aerial <- aerial_source_mode %in% c("local_rgb", "both")

# ------------------------------------------------------------
# 3. Hilfsfunktionen für Vektordaten
# ------------------------------------------------------------

read_sf_optional_layer <- function(dsn, layer = NA_character_) {
  if (!file.exists(dsn)) {
    stop("Vektordatei nicht gefunden: ", dsn)
  }
  
  if (!is.na(layer) && nzchar(layer)) {
    sf::st_read(dsn, layer = layer, quiet = TRUE)
  } else {
    sf::st_read(dsn, quiet = TRUE)
  }
}

write_gpkg_layer <- function(obj, dsn, layer) {
  if (file.exists(dsn) && layer %in% sf::st_layers(dsn)$name) {
    sf::st_delete(dsn, layer = layer, quiet = TRUE)
  }
  
  sf::st_write(
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
    message("Lade Kölner Stadtbezirke ...")
    utils::download.file(zip_url, zip_file, mode = "wb")
  }
  
  if (!dir.exists(unzip_dir)) {
    dir.create(unzip_dir, recursive = TRUE, showWarnings = FALSE)
    utils::unzip(zip_file, exdir = unzip_dir)
  }
  
  shp <- list.files(
    unzip_dir,
    pattern = "\\.shp$",
    recursive = TRUE,
    full.names = TRUE
  )
  
  if (length(shp) == 0) {
    stop("Kein Shapefile für Kölner Stadtbezirke gefunden.")
  }
  
  stadtbezirke <- sf::st_read(shp[1], quiet = TRUE) |>
    sf::st_make_valid()
  
  if (is.na(sf::st_crs(stadtbezirke))) {
    sf::st_crs(stadtbezirke) <- 25832
  }
  
  stadtbezirke
}

# ------------------------------------------------------------
# 4. AOI laden
# ------------------------------------------------------------

if (aoi_mode == "file") {
  message("Lade AOI aus Datei ...")
  
  aoi_raw <- read_sf_optional_layer(aoi_file, aoi_layer) |>
    sf::st_make_valid()
  
  admin_raw <- NULL
  
  if (!is.na(admin_file) && file.exists(admin_file)) {
    admin_raw <- read_sf_optional_layer(admin_file, admin_layer) |>
      sf::st_make_valid()
  }
  
} else if (aoi_mode == "bbox") {
  message("Erzeuge AOI aus Bounding Box ...")
  
  aoi_raw <- sf::st_sf(
    aoi_name = aoi_name,
    geometry = sf::st_as_sfc(sf::st_bbox(aoi_bbox, crs = 4326))
  )
  
  admin_raw <- NULL
  
} else if (aoi_mode == "koeln_stadtbezirke") {
  message("Erzeuge AOI aus Kölner Stadtbezirken ...")
  
  admin_raw <- load_koeln_stadtbezirke(aoi_dir)
  
  aoi_raw <- admin_raw |>
    sf::st_make_valid() |>
    dplyr::summarise(
      aoi_name = aoi_name,
      geometry = sf::st_union(geometry),
      .groups = "drop"
    ) |>
    sf::st_make_valid()
  
} else {
  stop("Unbekannter aoi_mode: ", aoi_mode)
}

if (is.na(sf::st_crs(aoi_raw))) {
  stop("AOI hat kein CRS.")
}

aoi_4326 <- aoi_raw |>
  sf::st_make_valid() |>
  sf::st_transform(4326) |>
  sf::st_union() |>
  sf::st_as_sf() |>
  dplyr::mutate(aoi_name = aoi_name)

aoi_25832 <- sf::st_transform(aoi_4326, crs_qgis)
aoi_3035  <- sf::st_transform(aoi_4326, crs_lucc)

admin_25832 <- NULL
admin_3035  <- NULL

if (!is.null(admin_raw)) {
  admin_25832 <- admin_raw |>
    sf::st_make_valid() |>
    sf::st_transform(crs_qgis)
  
  admin_3035 <- sf::st_transform(admin_25832, crs_lucc)
}

aoi_gpkg <- file.path(aoi_dir, "aoi.gpkg")

write_gpkg_layer(aoi_4326,  aoi_gpkg, "aoi_boundary_4326")
write_gpkg_layer(aoi_25832, aoi_gpkg, "aoi_boundary_25832")
write_gpkg_layer(aoi_3035,  aoi_gpkg, "aoi_boundary_3035")

if (!is.null(admin_25832)) {
  write_gpkg_layer(admin_25832, aoi_gpkg, "admin_orientation_25832")
  write_gpkg_layer(admin_3035,  aoi_gpkg, "admin_orientation_3035")
}

message("AOI geschrieben: ", aoi_gpkg)

# ------------------------------------------------------------
# 5. DOP-CIR-Oberflächenmaske
# ------------------------------------------------------------

# The DOP-CIR mask is now the surface mask reference for the teaching
# package. The runner loads dop_cir_oberflaechenmaske_modul.R before
# this script, so build_dop_cir_surface_mask() is available here after
# the AOI has been written.

if (!exists("build_dop_cir_surface_mask", mode = "function", inherits = TRUE)) {
  stop(
    "build_dop_cir_surface_mask() fehlt. ",
    "Das DOP-CIR-Modul muss im Runner vor dem Hauptskript geladen werden."
  )
}

dop_cir_mask_raster_file <- file.path(
  dop_cir_surface_dir,
  paste0(aoi_slug, "_dop_cir_30m_3klassen_EPSG", crs_qgis, ".tif")
)

dop_cir_mask_vector_file <- file.path(
  dop_cir_surface_dir,
  paste0(aoi_slug, "_dop_cir_30m_3klassen.gpkg")
)

dop_cir_mask <- build_dop_cir_surface_mask(
  aoi_file = aoi_gpkg,
  aoi_layer = "aoi_boundary_25832",
  aoi_name = aoi_slug,
  outdir = dop_cir_surface_dir,
  target_crs = crs_qgis,
  target_res_m = 30,
  wms_url = "https://www.wms.nrw.de/geobasis/wms_nw_dop?language=ger",
  wms_layer = "nw_dop_cir",
  write_polygons = TRUE,
  overwrite = TRUE
)

# ------------------------------------------------------------
# 6. Landsat-STAC-Suche
# ------------------------------------------------------------

bbox <- sf::st_bbox(aoi_4326)

stac_url <- "https://planetarycomputer.microsoft.com/api/stac/v1"

message("Suche Landsat-C2-L2-Szenen ...")

items <- rstac::stac(stac_url) |>
  rstac::stac_search(
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
  rstac::post_request()

items <- tryCatch(
  rstac::items_fetch(items),
  error = function(e) items
)

features <- items$features

if (length(features) == 0) {
  stop("Keine Landsat-Szenen gefunden.")
}

saveRDS(items, file.path(stac_dir, "stac_items_unsigned.rds"))

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

make_scene_outfile <- function(scene_id, scene_date, target_dir) {
  file.path(
    target_dir,
    paste0(
      format(scene_date, "%Y%m%d"),
      "_",
      safe_filename(scene_id),
      "_LST_C.tif"
    )
  )
}

meta_all <- tibble::tibble(
  idx = seq_along(features),
  id = purrr::map_chr(features, \(x) as.character(x$id)),
  datetime = purrr::map_chr(features, \(x) get_chr(x, "datetime")),
  platform = purrr::map_chr(features, \(x) get_chr(x, "platform")),
  cloud = purrr::map_dbl(features, \(x) get_dbl(x, "eo:cloud_cover")),
  collection_category = purrr::map_chr(
    features,
    \(x) get_chr(x, "landsat:collection_category")
  ),
  processing_level = purrr::map_chr(
    features,
    \(x) get_chr(x, "landsat:processing_level")
  ),
  has_lwir11 = purrr::map_lgl(features, \(x) has_asset(x, "lwir11")),
  has_qa_pixel = purrr::map_lgl(features, \(x) has_asset(x, "qa_pixel"))
) |>
  dplyr::mutate(
    date = as.Date(substr(datetime, 1, 10)),
    month = as.integer(format(date, "%m")),
    out_file = purrr::map2_chr(
      id,
      date,
      \(id, date) make_scene_outfile(id, date, scene_dir)
    ),
    out_exists = file.exists(out_file)
  )

meta <- meta_all |>
  dplyr::filter(platform %in% c("landsat-8", "landsat-9")) |>
  dplyr::filter(month %in% seasonal_months) |>
  dplyr::filter(is.na(cloud) | cloud <= max_scene_cloud) |>
  dplyr::filter(has_lwir11, has_qa_pixel)

if (isTRUE(require_tier1)) {
  meta <- meta |>
    dplyr::filter(is.na(collection_category) | collection_category == "T1")
}

if (isTRUE(require_l2sp)) {
  meta <- meta |>
    dplyr::filter(is.na(processing_level) | processing_level == "L2SP")
}

meta <- meta |>
  dplyr::arrange(date)

if (nrow(meta) == 0) {
  stop("Keine passenden Landsat-Szenen nach Filterung.")
}

if (is.finite(max_candidates)) {
  meta <- meta |>
    dplyr::slice_head(n = max_candidates)
}

readr::write_csv(meta_all, file.path(stac_dir, "stac_metadata_all.csv"))
readr::write_csv(meta, file.path(stac_dir, "stac_metadata_candidates.csv"))

message("Landsat-Kandidaten: ", nrow(meta))
message("Bereits lokal vorhanden: ", sum(meta$out_exists))

# ------------------------------------------------------------
# 7. Landsat-LST berechnen
# ------------------------------------------------------------

qa_bit <- function(x, bit) {
  floor(x / 2^bit) %% 2 == 1
}

calc_lst_stats_from_file <- function(file, meta_row) {
  r <- terra::rast(file)
  vals <- terra::values(r, mat = FALSE, na.rm = TRUE)
  
  if (length(vals) < min_valid_pixels) {
    message("Lokale Datei hat zu wenige gültige Pixel: ", file)
    return(tibble::tibble())
  }
  
  tibble::tibble(
    id = meta_row$id,
    date = meta_row$date,
    datetime = meta_row$datetime,
    platform = meta_row$platform,
    scene_cloud = meta_row$cloud,
    mean_C = mean(vals, na.rm = TRUE),
    median_C = stats::median(vals, na.rm = TRUE),
    q10_C = as.numeric(stats::quantile(vals, 0.10, na.rm = TRUE, names = FALSE)),
    q90_C = as.numeric(stats::quantile(vals, 0.90, na.rm = TRUE, names = FALSE)),
    min_C = min(vals, na.rm = TRUE),
    max_C = max(vals, na.rm = TRUE),
    valid_pixels = length(vals),
    valid_fraction = length(vals) / terra::ncell(r),
    file = file,
    quelle = "lokal"
  )
}

sign_single_scene <- function(scene) {
  one_item <- items
  one_item$features <- list(scene)
  
  one_item_signed <- one_item |>
    rstac::items_sign(rstac::sign_planetary_computer())
  
  one_item_signed$features[[1]]
}

process_one_scene <- function(scene, meta_row, aoi_4326, target_dir) {
  scene_id <- meta_row$id
  scene_date <- meta_row$date
  
  out_file <- make_scene_outfile(scene_id, scene_date, target_dir)
  
  if (isTRUE(skip_existing_outputs) && file.exists(out_file)) {
    message("Nutze lokale LST-Datei: ", basename(out_file))
    return(calc_lst_stats_from_file(out_file, meta_row))
  }
  
  message("Verarbeite Landsat-Szene: ", scene_date, " / ", scene_id)
  
  scene_signed <- sign_single_scene(scene)
  
  lst_href <- scene_signed$assets$lwir11$href
  qa_href  <- scene_signed$assets$qa_pixel$href
  
  lst_raw <- terra::rast(lst_href)
  qa <- terra::rast(qa_href)
  
  aoi_r <- terra::vect(sf::st_transform(aoi_4326, terra::crs(lst_raw)))
  
  lst_raw_crop <- terra::crop(lst_raw, aoi_r, snap = "out")
  qa_crop <- terra::crop(qa, aoi_r, snap = "out")
  
  lst_c <- lst_raw_crop * 0.00341802 + 149.0 - 273.15
  
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
    message("Zu wenige gültige Pixel nach QA-Maske: ", length(vals))
    return(tibble::tibble())
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
  
  tibble::tibble(
    id = scene_id,
    date = scene_date,
    datetime = meta_row$datetime,
    platform = meta_row$platform,
    scene_cloud = meta_row$cloud,
    mean_C = mean(vals, na.rm = TRUE),
    median_C = stats::median(vals, na.rm = TRUE),
    q10_C = as.numeric(stats::quantile(vals, 0.10, na.rm = TRUE, names = FALSE)),
    q90_C = as.numeric(stats::quantile(vals, 0.90, na.rm = TRUE, names = FALSE)),
    min_C = min(vals, na.rm = TRUE),
    max_C = max(vals, na.rm = TRUE),
    valid_pixels = length(vals),
    valid_fraction = length(vals) / terra::ncell(lst_clip),
    file = out_file,
    quelle = "neu"
  )
}

message("Berechne Landsat-LST und Szenenstatistik ...")

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
        target_dir = scene_dir
      ),
      error = function(e) {
        message("Fehler in Szene ", meta_row$id, ": ", conditionMessage(e))
        tibble::tibble()
      }
    )
  }
)

if (nrow(results) == 0) {
  stop("Keine Landsat-Szene konnte verarbeitet werden.")
}

results_ranked <- results |>
  dplyr::arrange(dplyr::desc(q90_C))

all_ranked_file <- file.path(out_dir, "all_processed_scenes_ranked.csv")

readr::write_csv(results_ranked, all_ranked_file)

# ------------------------------------------------------------
# 8. Extreme und Komposite
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
    stop("Metrik existiert nicht: ", metric)
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
      dplyr::arrange(dplyr::desc(.data[[metric]])) |>
      dplyr::slice_head(n = n_select)
  } else {
    selected <- results |>
      dplyr::arrange(.data[[metric]]) |>
      dplyr::slice_head(n = n_select)
  }
  
  if (nrow(selected) == 0) {
    warning("Keine Szenen für Extremmodus: ", mode_label)
    return(NULL)
  }
  
  selected_files <- file.path(mode_scene_dir, basename(selected$file))
  
  file.copy(
    from = selected$file,
    to = selected_files,
    overwrite = TRUE
  )
  
  selected <- selected |>
    dplyr::mutate(selected_file = selected_files)
  
  selected_csv <- file.path(
    mode_dir,
    paste0(aoi_slug, "_", mode_label, "_selected_scenes.csv")
  )
  
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
  
  out_stack <- file.path(
    mode_comp_dir,
    paste0(aoi_slug, "_LST_", mode_label, "_stack_C.tif")
  )
  
  if (!file.exists(out_stack)) {
    terra::writeRaster(
      r_stack,
      out_stack,
      overwrite = TRUE,
      wopt = list(
        gdal = c(
          "COMPRESS=DEFLATE",
          "TILED=YES",
          "BIGTIFF=IF_SAFER"
        )
      )
    )
  }
  
  out_median <- file.path(
    mode_comp_dir,
    paste0(aoi_slug, "_LST_", mode_label, "_median_C.tif")
  )
  
  out_q10 <- file.path(
    mode_comp_dir,
    paste0(aoi_slug, "_LST_", mode_label, "_q10_C.tif")
  )
  
  out_q90 <- file.path(
    mode_comp_dir,
    paste0(aoi_slug, "_LST_", mode_label, "_q90_C.tif")
  )
  
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
  message("Erzeuge Hot-Extreme-Produkte ...")
  
  extreme_products$hot <- build_extreme_products(
    results = results,
    mode_label = "hot",
    metric = hot_metric,
    n_select = n_hot,
    descending = TRUE
  )
}

# Cold products are intentionally not generated for this teaching workflow.

saveRDS(extreme_products, file.path(extreme_dir, "extreme_products.rds"))

# ------------------------------------------------------------
# 9. Teaching-Layer und LST-Projektion
# ------------------------------------------------------------

gpkg_25832 <- file.path(
  teaching_dir,
  paste0(aoi_slug, "_teaching_layers_EPSG", crs_qgis, ".gpkg")
)

gpkg_3035 <- file.path(
  teaching_dir,
  paste0(aoi_slug, "_teaching_layers_EPSG", crs_lucc, ".gpkg")
)

write_gpkg_layer(aoi_25832, gpkg_25832, "aoi_boundary")
write_gpkg_layer(aoi_3035, gpkg_3035, "aoi_boundary")

if (!is.null(admin_25832)) {
  write_gpkg_layer(admin_25832, gpkg_25832, "admin_orientation")
  write_gpkg_layer(admin_3035, gpkg_3035, "admin_orientation")
}

projected_lst_dir <- file.path(teaching_dir, "projected_lst")
dir.create(projected_lst_dir, recursive = TRUE, showWarnings = FALSE)

reproject_raster_if_missing <- function(infile, outfile, crs) {
  if (!file.exists(infile)) {
    warning("Input-Raster fehlt: ", infile)
    return(invisible(FALSE))
  }
  
  if (file.exists(outfile)) {
    return(invisible(TRUE))
  }
  
  r <- terra::rast(infile)
  r_proj <- terra::project(r, paste0("EPSG:", crs), method = "bilinear")
  
  terra::writeRaster(
    r_proj,
    outfile,
    overwrite = TRUE,
    wopt = list(
      gdal = c(
        "COMPRESS=DEFLATE",
        "TILED=YES",
        "BIGTIFF=IF_SAFER"
      )
    )
  )
  
  invisible(TRUE)
}

lst_project_table <- tibble::tibble()

for (mode_name in names(extreme_products)) {
  p <- extreme_products[[mode_name]]
  
  if (is.null(p)) {
    next
  }
  
  candidates <- tibble::tibble(
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
      paste0(aoi_slug, "_LST_", mode, "_", product, "_C_EPSG", crs_qgis, ".tif")
    )
    
    out_3035 <- file.path(
      projected_lst_dir,
      paste0(aoi_slug, "_LST_", mode, "_", product, "_C_EPSG", crs_lucc, ".tif")
    )
    
    reproject_raster_if_missing(infile, out_25832, crs_qgis)
    reproject_raster_if_missing(infile, out_3035, crs_lucc)
    
    lst_project_table <- dplyr::bind_rows(
      lst_project_table,
      tibble::tibble(
        mode = mode,
        product = product,
        crs = c(crs_qgis, crs_lucc),
        file = c(out_25832, out_3035)
      )
    )
  }
}

readr::write_csv(
  lst_project_table,
  file.path(projected_lst_dir, paste0(aoi_slug, "_projected_lst_products.csv"))
)

# ------------------------------------------------------------
# 10. Lokales DOP-Bild aus WMS optional erzeugen
# ------------------------------------------------------------

aerial_dir <- file.path(teaching_dir, "aerial")
dir.create(aerial_dir, recursive = TRUE, showWarnings = FALSE)

local_aerial_file <- file.path(
  aerial_dir,
  paste0(aoi_slug, "_dop_rgb_EPSG", crs_qgis, ".png")
)

download_aerial_rgb_wms <- function(aoi_sf, outfile) {
  if (file.exists(outfile)) {
    return(outfile)
  }
  
  bb <- sf::st_bbox(aoi_sf)
  
  width_m <- as.numeric(bb["xmax"] - bb["xmin"])
  height_m <- as.numeric(bb["ymax"] - bb["ymin"])
  
  width_px <- ceiling(width_m / aerial_rgb_target_res_m)
  height_px <- ceiling(height_m / aerial_rgb_target_res_m)
  
  scale <- min(
    1,
    aerial_rgb_max_dim / max(width_px, height_px)
  )
  
  width_px <- max(256, floor(width_px * scale))
  height_px <- max(256, floor(height_px * scale))
  
  query <- list(
    SERVICE = "WMS",
    VERSION = "1.1.1",
    REQUEST = "GetMap",
    LAYERS = aerial_wms_layer,
    STYLES = "",
    SRS = paste0("EPSG:", crs_qgis),
    BBOX = paste(
      bb["xmin"],
      bb["ymin"],
      bb["xmax"],
      bb["ymax"],
      sep = ","
    ),
    WIDTH = width_px,
    HEIGHT = height_px,
    FORMAT = aerial_rgb_format,
    TRANSPARENT = "TRUE"
  )
  
  qs <- paste(
    names(query),
    utils::URLencode(unlist(query), reserved = TRUE),
    sep = "=",
    collapse = "&"
  )
  
  url <- paste0(aerial_wms_url, "&", qs)
  
  tryCatch(
    {
      utils::download.file(url, outfile, mode = "wb", quiet = TRUE)
      outfile
    },
    error = function(e) {
      warning("Lokales DOP-Bild konnte nicht geladen werden: ", conditionMessage(e))
      NA_character_
    }
  )
}

if (isTRUE(add_local_rgb_aerial)) {
  local_aerial_file <- download_aerial_rgb_wms(aoi_25832, local_aerial_file)
}

# ------------------------------------------------------------
# 11. DOP-CIR-Maske
# ------------------------------------------------------------

# Kein nachträglicher Oberflächenmasken-Aufruf.
# Die Maske wurde bereits im Runner erstellt und wird unten nur
# im QGIS-Projekt eingebunden.

# ------------------------------------------------------------
# 12. QGIS-Python-Skript schreiben
# ------------------------------------------------------------

qgis_project_file <- file.path(qgis_dir, paste0(aoi_slug, "_lst_oberflaechenmaske.qgz"))
qgis_py_file <- file.path(qgis_dir, paste0("create_", aoi_slug, "_qgis_project.py"))

hot_lst_products <- tibble::tibble(
  title = c(
    "Hot LST median",
    "Hot LST q10",
    "Hot LST q90 / hottest hot"
  ),
  product = c("median", "q10", "q90"),
  file = file.path(
    projected_lst_dir,
    paste0(aoi_slug, "_LST_hot_", product, "_C_EPSG", crs_qgis, ".tif")
  )
) |>
  dplyr::filter(file.exists(file))

if (nrow(hot_lst_products) == 0) {
  warning("Keine Hot-LST-Produkte für das QGIS-Projekt gefunden.")
}

qgis_config <- list(
  project_file = normalizePath(qgis_project_file, mustWork = FALSE),
  crs_authid = paste0("EPSG:", crs_qgis),
  aoi_gpkg = normalizePath(aoi_gpkg, mustWork = FALSE),
  has_admin = !is.null(admin_25832),
  aerial_wms_url = aerial_wms_url,
  aerial_wms_layer = aerial_wms_layer,
  aerial_wms_name = aerial_wms_name,
  add_aerial_wms = isTRUE(add_aerial_wms),
  local_aerial_file = if (!is.na(local_aerial_file) && file.exists(local_aerial_file)) {
    normalizePath(local_aerial_file, mustWork = FALSE)
  } else {
    ""
  },
  dop_opacity = 0.55,
  hot_lst = lapply(seq_len(nrow(hot_lst_products)), function(i) {
    list(
      title = hot_lst_products$title[i],
      product = hot_lst_products$product[i],
      file = normalizePath(hot_lst_products$file[i], mustWork = FALSE)
    )
  }),
  dop_cir_mask_vector_file = if (file.exists(dop_cir_mask_vector_file)) {
    normalizePath(dop_cir_mask_vector_file, mustWork = FALSE)
  } else {
    ""
  },
  dop_cir_mask_layer = "dop_cir_30m_3klassen",
  dop_cir_mask_raster_file = if (file.exists(dop_cir_mask_raster_file)) {
    normalizePath(dop_cir_mask_raster_file, mustWork = FALSE)
  } else {
    ""
  }
)

qgis_config_file <- file.path(qgis_dir, paste0(aoi_slug, "_qgis_project_config.json"))
jsonlite::write_json(qgis_config, qgis_config_file, auto_unbox = TRUE, pretty = TRUE)

qgis_lines <- c(
  "from qgis.core import *",
  "from qgis.PyQt.QtGui import QColor, QFont",
  "import json, os, math",
  "try:",
  "    from osgeo import gdal",
  "    import numpy as np",
  "except Exception as exc:",
  "    gdal = None",
  "    np = None",
  "    print('Warnung: GDAL/NumPy für Quantilstyling nicht verfügbar:', exc)",
  "",
  sprintf("CONFIG_FILE = r'%s'", normalizePath(qgis_config_file, mustWork = FALSE)),
  "with open(CONFIG_FILE, 'r', encoding='utf-8') as f:",
  "    CONFIG = json.load(f)",
  "",
  "project = QgsProject.instance()",
  "project.clear()",
  "project.setCrs(QgsCoordinateReferenceSystem(CONFIG['crs_authid']))",
  "root = project.layerTreeRoot()",
  "",
  "def add_group(name):",
  "    return root.addGroup(name)",
  "",
  "def add_vector(path, layername, title, group):",
  "    if not path or not os.path.exists(path):",
  "        print('Vektor fehlt:', title, path)",
  "        return None",
  "    uri = path + '|layername=' + layername",
  "    layer = QgsVectorLayer(uri, title, 'ogr')",
  "    if layer.isValid():",
  "        project.addMapLayer(layer, False)",
  "        group.addLayer(layer)",
  "        return layer",
  "    print('Layer ungültig:', title, uri)",
  "    return None",
  "",
  "def add_raster(path, title, group):",
  "    if not path or not os.path.exists(path):",
  "        print('Raster fehlt:', title, path)",
  "        return None",
  "    layer = QgsRasterLayer(path, title)",
  "    if layer.isValid():",
  "        project.addMapLayer(layer, False)",
  "        group.addLayer(layer)",
  "        return layer",
  "    print('Raster ungültig:', title, path)",
  "    return None",
  "",
  "def add_wms(url, layername, title, group):",
  "    encoded_url = url.replace(':', '%3A').replace('/', '%2F').replace('?', '%3F').replace('&', '%26').replace('=', '%3D')",
  "    uri = 'contextualWMSLegend=0&crs=EPSG:25832&dpiMode=7&format=image/png&layers=%s&styles=&tilePixelRatio=0&url=%s' % (layername, encoded_url)",
  "    layer = QgsRasterLayer(uri, title, 'wms')",
  "    if layer.isValid():",
  "        project.addMapLayer(layer, False)",
  "        group.addLayer(layer)",
  "        return layer",
  "    print('WMS ungültig:', title)",
  "    return None",
  "",
  "def raster_values(path):",
  "    if gdal is None or np is None:",
  "        return None",
  "    ds = gdal.Open(path)",
  "    if ds is None:",
  "        return None",
  "    band = ds.GetRasterBand(1)",
  "    arr = band.ReadAsArray()",
  "    nodata = band.GetNoDataValue()",
  "    vals = arr.astype('float64').ravel()",
  "    if nodata is not None:",
  "        vals = vals[vals != nodata]",
  "    vals = vals[np.isfinite(vals)]",
  "    return vals if vals.size else None",
  "",
  "def quantile_breaks(path, n=5):",
  "    vals = raster_values(path)",
  "    if vals is None:",
  "        return None",
  "    brks = [float(x) for x in np.quantile(vals, np.linspace(0, 1, n + 1))]",
  "    for i in range(1, len(brks)):",
  "        if brks[i] <= brks[i - 1]:",
  "            brks[i] = brks[i - 1] + 1e-6",
  "    return brks",
  "",
  "def turbo_5_colors():",
  "    return [QColor(48,18,59), QColor(45,110,185), QColor(42,185,115), QColor(245,185,40), QColor(180,4,38)]",
  "",
  "def apply_hot_quantile_style(layer, path, title):",
  "    if layer is None or not layer.isValid():",
  "        return",
  "    brks = quantile_breaks(path, 5)",
  "    if brks is None:",
  "        print('Quantile konnten nicht berechnet werden:', path)",
  "        return",
  "    items = []",
  "    for i, color in enumerate(turbo_5_colors()):",
  "        label = '%s Q%d: %.1f–%.1f °C' % (title, i + 1, brks[i], brks[i + 1])",
  "        items.append(QgsColorRampShader.ColorRampItem(brks[i + 1], color, label))",
  "    shader = QgsColorRampShader()",
  "    shader.setColorRampType(QgsColorRampShader.Discrete)",
  "    shader.setColorRampItemList(items)",
  "    shader.setMinimumValue(brks[0])",
  "    shader.setMaximumValue(brks[-1])",
  "    raster_shader = QgsRasterShader()",
  "    raster_shader.setRasterShaderFunction(shader)",
  "    renderer = QgsSingleBandPseudoColorRenderer(layer.dataProvider(), 1, raster_shader)",
  "    layer.setRenderer(renderer)",
  "    layer.triggerRepaint()",
  "",
  "def style_mask_outline(layer):",
  "    if layer is None or not layer.isValid():",
  "        return",
  "    symbol = QgsFillSymbol.createSimple({'style':'no','outline_style':'solid','outline_color':'20,20,20,230','outline_width':'0.35','outline_width_unit':'MM'})",
  "    layer.setRenderer(QgsSingleSymbolRenderer(symbol))",
  "    layer.setOpacity(1.0)",
  "    layer.triggerRepaint()",
  "",
  "g_surface = add_group('04 Oberflächenmaske Linien')",
  "g_aerial = add_group('02 DOP Vordergrund 45 Prozent transparent')",
  "g_lst = add_group('03 Landsat LST hot')",
  "g_base = add_group('01 Orientierung')",
  "",
  "aoi_layer = add_vector(CONFIG['aoi_gpkg'], 'aoi_boundary_25832', 'AOI', g_base)",
  "if CONFIG.get('has_admin'):",
  "    add_vector(CONFIG['aoi_gpkg'], 'admin_orientation_25832', 'Administrative Orientierung', g_base)",
  "",
  "hot_layers = {}",
  "for item in CONFIG['hot_lst']:",
  "    lyr = add_raster(item['file'], item['title'], g_lst)",
  "    if lyr is not None:",
  "        apply_hot_quantile_style(lyr, item['file'], item['title'])",
  "        hot_layers[item['title']] = lyr",
  "",
  "dop_wms = None",
  "if CONFIG.get('add_aerial_wms'):",
  "    dop_wms = add_wms(CONFIG['aerial_wms_url'], CONFIG['aerial_wms_layer'], CONFIG['aerial_wms_name'], g_aerial)",
  "    if dop_wms is not None:",
  "        dop_wms.setOpacity(CONFIG.get('dop_opacity', 0.55))",
  "local_dop = add_raster(CONFIG.get('local_aerial_file',''), 'DOP lokal', g_aerial)",
  "if local_dop is not None:",
  "    local_dop.setOpacity(CONFIG.get('dop_opacity', 0.55))",
  "",
  "mask_layers = []",
  "mask_vector = add_vector(CONFIG.get('dop_cir_mask_vector_file',''), CONFIG.get('dop_cir_mask_layer','dop_cir_30m_3klassen'), 'DOP-CIR Oberflächenmaske Linien', g_surface)",
  "if mask_vector is not None:",
  "    style_mask_outline(mask_vector)",
  "    mask_layers.append(mask_vector)",
  "",
  "hottest_layer = hot_layers.get('Hot LST q90 / hottest hot')",
  "if hottest_layer is None and hot_layers:",
  "    hottest_layer = list(hot_layers.values())[-1]",
  "",
  "def create_layout():",
  "    if hottest_layer is None:",
  "        print('Kein hottest-hot-Layer für Layout verfügbar.')",
  "        return",
  "    manager = project.layoutManager()",
  "    existing = manager.layoutByName('Hottest Hot LST + DOP + Maske')",
  "    if existing is not None:",
  "        manager.removeLayout(existing)",
  "    layout = QgsPrintLayout(project)",
  "    layout.initializeDefaults()",
  "    layout.setName('Hottest Hot LST + DOP + Maske')",
  "    manager.addLayout(layout)",
  "    page = layout.pageCollection().pages()[0]",
  "    try:",
  "        page.setPageSize('A4', QgsLayoutItemPage.Landscape)",
  "    except Exception:",
  "        pass",
  "    map_item = QgsLayoutItemMap(layout)",
  "    map_item.attemptMove(QgsLayoutPoint(10, 15, QgsUnitTypes.LayoutMillimeters))",
  "    map_item.attemptResize(QgsLayoutSize(277, 175, QgsUnitTypes.LayoutMillimeters))",
  "    layers = [hottest_layer]",
  "    if dop_wms is not None:",
  "        layers.append(dop_wms)",
  "    elif local_dop is not None:",
  "        layers.append(local_dop)",
  "    layers.extend(mask_layers)",
  "    map_item.setLayers(layers)",
  "    ext = QgsRectangle(hottest_layer.extent())",
  "    if aoi_layer is not None:",
  "        ext.combineExtentWith(aoi_layer.extent())",
  "    ext.scale(1.02)",
  "    map_item.setExtent(ext)",
  "    layout.addLayoutItem(map_item)",
  "    grid = QgsLayoutItemMapGrid('EPSG25832 1 km cross grid', map_item)",
  "    map_item.grids().addGrid(grid)",
  "    grid.setEnabled(True)",
  "    grid.setIntervalX(1000)",
  "    grid.setIntervalY(1000)",
  "    try: grid.setCrs(QgsCoordinateReferenceSystem(CONFIG['crs_authid']))",
  "    except Exception: pass",
  "    try: grid.setStyle(QgsLayoutItemMapGrid.Cross)",
  "    except Exception: pass",
  "    try: grid.setCrossLength(2.0)",
  "    except Exception: pass",
  "    grid.setAnnotationEnabled(True)",
  "    try: grid.setAnnotationPrecision(0)",
  "    except Exception: pass",
  "    try: grid.setAnnotationFrameDistance(1.5)",
  "    except Exception: pass",
  "    try: grid.setFrameStyle(QgsLayoutItemMapGrid.ExteriorTicks)",
  "    except Exception: pass",
  "    title = QgsLayoutItemLabel(layout)",
  "    title.setText('Köln: Hot q90, DOP und Oberflächenmaske')",
  "    title.setFont(QFont('Arial', 14))",
  "    title.adjustSizeToText()",
  "    title.attemptMove(QgsLayoutPoint(10, 5, QgsUnitTypes.LayoutMillimeters))",
  "    layout.addLayoutItem(title)",
  "    scalebar = QgsLayoutItemScaleBar(layout)",
  "    scalebar.setStyle('Single Box')",
  "    scalebar.setLinkedMap(map_item)",
  "    scalebar.setUnits(QgsUnitTypes.DistanceKilometers)",
  "    scalebar.setNumberOfSegments(4)",
  "    scalebar.setNumberOfSegmentsLeft(0)",
  "    scalebar.setUnitsPerSegment(1)",
  "    scalebar.setUnitLabel('km')",
  "    scalebar.attemptMove(QgsLayoutPoint(10, 193, QgsUnitTypes.LayoutMillimeters))",
  "    layout.addLayoutItem(scalebar)",
  "",
  "create_layout()",
  "project.write(CONFIG['project_file'])",
  "print('QGIS-Projekt geschrieben:', CONFIG['project_file'])"
)

writeLines(qgis_lines, qgis_py_file, useBytes = TRUE)

message("QGIS-Python-Skript geschrieben: ", qgis_py_file)

if (isTRUE(run_qgis_project_creation)) {
  system2("qgis", c("--code", qgis_py_file), wait = TRUE)
}

# ------------------------------------------------------------
# 13. Abschluss
# ------------------------------------------------------------

message("Fertig.")
message("Projektordner: ", out_dir)
message("QGIS-Skript: ", qgis_py_file)
message("QGIS-Projektdatei, falls erzeugt: ", qgis_project_file)
