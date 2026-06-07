#!/usr/bin/env Rscript

# ============================================================
# 00_run_lst_oberflaechenmaske.R
# ============================================================
#
# Zentraler Einstieg für das Unterrichtspaket.
#
# Aufruf:
#   Rscript scripts/00_run_lst_oberflaechenmaske.R
#
# Projektstruktur:
#   scripts/
#     00_run_lst_oberflaechenmaske.R
#     landsat_lst_mit_dop_cir_oberflaechenmaske.R
#     dop_cir_oberflaechenmaske_modul.R
#
# ============================================================

library(here)

#here::i_am("scripts/00_run_lst_oberflaechenmaske.R")

root_folder <- here::here()
script_dir  <- here::here("scripts")

# ------------------------------------------------------------
# 1. Zentrale Parameter
# ------------------------------------------------------------

aoi_name <- "koeln"
aoi_mode <- "koeln_stadtbezirke"

project_root <- here::here("data", "landsat_lst")

aoi_file  <- NA_character_
aoi_layer <- NA_character_

aoi_bbox <- c(
  xmin = 6.75,
  ymin = 50.82,
  xmax = 7.20,
  ymax = 51.10
)

admin_file  <- NA_character_
admin_layer <- NA_character_

date_start <- "2023-01-01"
date_end   <- "2026-01-01" #as.character(Sys.Date())

seasonal_months <- 6:8

crs_qgis <- 25832
crs_lucc <- 3035

extreme_mode <- "hot"

n_hot  <- 10

hot_metric  <- "q90_C"

max_scene_cloud <- 30

require_tier1 <- TRUE
require_l2sp  <- TRUE

max_candidates <- Inf

mask_water <- FALSE

min_valid_pixels <- 500

skip_existing_outputs <- TRUE

aerial_source_mode <- "both"

aerial_wms_name  <- "Luftbild NRW DOP RGB WMS"
aerial_wms_url   <- "https://www.wms.nrw.de/geobasis/wms_nw_dop?language=ger"
aerial_wms_layer <- "nw_dop_rgb"

aerial_opacity <- 0.35

aerial_rgb_format <- "image/png"
aerial_rgb_max_dim <- 6000
aerial_rgb_target_res_m <- 2

run_qgis_project_creation <- TRUE

# ------------------------------------------------------------
# 2. Module laden und Hauptworkflow starten
# ------------------------------------------------------------

# ------------------------------------------------------------
# DOP-CIR-Modul laden
# ------------------------------------------------------------

source(here::here("scripts", "dop_cir_oberflaechenmaske_modul.R"))

stopifnot(exists("build_dop_cir_surface_mask", mode = "function"))

source(
  here::here("scripts", "landsat_lst_mit_dop_cir_oberflaechenmaske.R"),
  local = environment()
)