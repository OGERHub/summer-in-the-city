# ============================================================
# dop_cir_oberflaechenmaske_modul.R
# ============================================================
#
# Erstellt eine einfache 3-Klassen-Oberflächenmaske aus dem
# DOP Colorinfrarot-WMS NRW.
#
# Datenquelle:
#   Name:  DOP Colorinfrarot
#   WMS:   https://www.wms.nrw.de/geobasis/wms_nw_dop?language=ger
#   Layer: nw_dop_cir
#
# Ziel:
#   - didaktisch robuste Grobmaske auf Landsat-/LST-Maßstab
#   - keine Sentinel-Daten
#   - keine OSM-Daten
#   - keine Objektklassifikation
#
# Klassen:
#   1 Vegetation
#   2 Wasser
#   3 Versiegelung / Bebauung
#
# Wichtige Einschränkung:
#   Das DOP-CIR-WMS ist ein dargestelltes RGB-Bild, kein
#   radiometrisch kalibriertes NIR/Red/Green-Bandprodukt.
#   Die Klassifikation ist eine didaktische Farblogik für den
#   Vergleich mit Landsat-LST, keine wissenschaftliche
#   Landcover-Klassifikation.
#
# Diese Version restituiert die vorherige RGB-/Excess-Logik.
# Keine HSV-Klassifikation.
#
# ============================================================


build_dop_cir_surface_mask <- function(
    aoi_file,
    aoi_layer = NULL,
    aoi_name,
    outdir,
    target_crs = 25832,
    target_res_m = 30,
    
    wms_url = "https://www.wms.nrw.de/geobasis/wms_nw_dop?language=ger",
    wms_layer = "nw_dop_cir",
    wms_format = "image/png",
    
    max_pixels = 4096,
    download_timeout_sec = 180,
    
    # Restituierte RGB-/Excess-Logik
    vegetation_red_ratio = 1.08,
    vegetation_red_min = 95,
    vegetation_red_excess_min = 18,
    
    water_red_max = 75,
    water_brightness_max = 105,
    water_cyan_excess_min = 18,
    water_gb_diff_max = 45,
    
    shadow_brightness_max = 75,
    shadow_rgb_range_max = 30,
    
    # Filterung der Rastermaske
    majority_filter = TRUE,
    majority_radius_px = 2,
    
    # Class-specific raster cleanup.
    # Removes isolated false-positive patches before vectorization.
    # At 30 m resolution, 1 pixel equals 900 m².
    water_sieve = TRUE,
    water_min_pixels = 4,
    vegetation_sieve = TRUE,
    vegetation_min_pixels = 4,
    
    # Cartographic vector smoothing.
    # Water and vegetation receive separate weaker smoothing, because
    # small water bodies and small parks can otherwise collapse.
    vector_smooth = TRUE,
    vector_smooth_m = 30,
    water_smooth_m = 7.5,
    vegetation_smooth_m = 7.5,
    coverage_snap = TRUE,
    coverage_snap_grid_m = 1,
    vector_simplify_m = 0,
    
    write_polygons = TRUE,
    overwrite = TRUE
) {
  
  # ----------------------------------------------------------
  # Pakete
  # ----------------------------------------------------------
  
  required <- c("sf", "terra", "jsonlite", "png")
  
  missing <- required[
    !vapply(required, requireNamespace, logical(1), quietly = TRUE)
  ]
  
  if (length(missing) > 0) {
    stop(
      "Fehlende R-Pakete: ",
      paste(missing, collapse = ", "),
      "\nInstallieren z.B. mit install.packages(c(",
      paste(sprintf('"%s"', missing), collapse = ", "),
      "))"
    )
  }
  
  # ----------------------------------------------------------
  # Lokale Hilfsfunktion: Majority / Modus
  # ----------------------------------------------------------
  
  dop_cir_majority_fun <- function(x, ...) {
    x <- x[is.finite(x)]
    
    if (length(x) == 0) {
      return(NA_integer_)
    }
    
    tab <- table(as.integer(x))
    as.integer(names(tab)[which.max(tab)])
  }
  
  # ----------------------------------------------------------
  # Ausgabeordner
  # ----------------------------------------------------------
  
  dir.create(outdir, recursive = TRUE, showWarnings = FALSE)
  
  out_png <- file.path(
    outdir,
    paste0(aoi_name, "_dop_cir_30m_wms_EPSG", target_crs, ".png")
  )
  
  out_rgb_tif <- file.path(
    outdir,
    paste0(aoi_name, "_dop_cir_30m_rgb_EPSG", target_crs, ".tif")
  )
  
  out_class_tif <- file.path(
    outdir,
    paste0(aoi_name, "_dop_cir_30m_3klassen_EPSG", target_crs, ".tif")
  )
  
  out_class_png <- file.path(
    outdir,
    paste0(aoi_name, "_dop_cir_30m_3klassen_preview.png")
  )
  
  out_poly_gpkg <- file.path(
    outdir,
    paste0(aoi_name, "_dop_cir_30m_3klassen.gpkg")
  )
  
  out_json <- file.path(
    outdir,
    paste0(aoi_name, "_dop_cir_30m_3klassen_parameter.json")
  )
  
  if (!overwrite) {
    existing <- c(
      out_png,
      out_rgb_tif,
      out_class_tif,
      out_class_png,
      out_json
    )
    
    if (write_polygons) {
      existing <- c(existing, out_poly_gpkg)
    }
    
    if (all(file.exists(existing))) {
      message("DOP-CIR-Maske existiert bereits. Überspringe.")
      
      return(invisible(list(
        png = out_png,
        rgb = out_rgb_tif,
        class_raster = out_class_tif,
        class_preview = out_class_png,
        polygons = if (write_polygons) out_poly_gpkg else NA_character_,
        parameters = out_json
      )))
    }
  }
  
  # ----------------------------------------------------------
  # AOI lesen und BBOX in Ziel-CRS ableiten
  # ----------------------------------------------------------
  
  if (!file.exists(aoi_file)) {
    stop("AOI-Datei nicht gefunden: ", aoi_file)
  }
  
  if (is.null(aoi_layer) || is.na(aoi_layer) || !nzchar(aoi_layer)) {
    aoi <- sf::st_read(aoi_file, quiet = TRUE)
  } else {
    aoi <- sf::st_read(aoi_file, layer = aoi_layer, quiet = TRUE)
  }
  
  if (nrow(aoi) == 0) {
    stop("AOI ist leer: ", aoi_file)
  }
  
  if (is.na(sf::st_crs(aoi))) {
    stop("AOI hat kein CRS.")
  }
  
  aoi <- sf::st_make_valid(aoi)
  aoi <- sf::st_transform(aoi, target_crs)
  
  bbox <- sf::st_bbox(aoi)
  
  xmin <- floor(as.numeric(bbox["xmin"]) / target_res_m) * target_res_m
  ymin <- floor(as.numeric(bbox["ymin"]) / target_res_m) * target_res_m
  xmax <- ceiling(as.numeric(bbox["xmax"]) / target_res_m) * target_res_m
  ymax <- ceiling(as.numeric(bbox["ymax"]) / target_res_m) * target_res_m
  
  width <- as.integer(round((xmax - xmin) / target_res_m))
  height <- as.integer(round((ymax - ymin) / target_res_m))
  
  if (width <= 0 || height <= 0) {
    stop("Ungültige Rastergröße aus AOI/BBOX.")
  }
  
  if (width > max_pixels || height > max_pixels) {
    stop(
      "Ausgabe wäre zu groß: ",
      width, " x ", height, " Pixel. ",
      "AOI verkleinern oder target_res_m erhöhen."
    )
  }
  
  message(
    "DOP-CIR-WMS BBOX EPSG:",
    target_crs,
    ": ",
    paste(c(xmin, ymin, xmax, ymax), collapse = ", ")
  )
  
  message(
    "Zielraster: ",
    width,
    " x ",
    height,
    " Pixel bei ",
    target_res_m,
    " m"
  )
  
  # ----------------------------------------------------------
  # WMS GetMap auf Zielraster laden
  # ----------------------------------------------------------
  
  query <- list(
    SERVICE = "WMS",
    VERSION = "1.1.1",
    REQUEST = "GetMap",
    LAYERS = wms_layer,
    STYLES = "",
    SRS = paste0("EPSG:", target_crs),
    BBOX = paste(c(xmin, ymin, xmax, ymax), collapse = ","),
    WIDTH = width,
    HEIGHT = height,
    FORMAT = wms_format,
    TRANSPARENT = "FALSE"
  )
  
  wms_request <- paste0(
    wms_url,
    if (grepl("\\?", wms_url)) "&" else "?",
    paste(
      paste0(
        names(query),
        "=",
        utils::URLencode(as.character(query), reserved = TRUE)
      ),
      collapse = "&"
    )
  )
  
  message("Lade DOP Colorinfrarot WMS ...")
  
  old_timeout <- getOption("timeout")
  options(timeout = max(download_timeout_sec, old_timeout))
  on.exit(options(timeout = old_timeout), add = TRUE)
  
  utils::download.file(
    url = wms_request,
    destfile = out_png,
    mode = "wb",
    quiet = FALSE
  )
  
  if (!file.exists(out_png) || file.info(out_png)$size < 1000) {
    stop("WMS-Download fehlgeschlagen oder Datei zu klein: ", out_png)
  }
  
  # ----------------------------------------------------------
  # PNG kontrolliert als RGB-Matrix lesen und georeferenzieren
  # ----------------------------------------------------------
  
  img <- png::readPNG(out_png)
  
  if (length(dim(img)) < 3 || dim(img)[3] < 3) {
    stop("WMS-PNG enthält keine RGB-Bänder.")
  }
  
  if (dim(img)[2] != width || dim(img)[1] != height) {
    stop(
      "WMS-PNG-Größe passt nicht zum angeforderten Raster: ",
      "PNG = ",
      dim(img)[2],
      " x ",
      dim(img)[1],
      ", erwartet = ",
      width,
      " x ",
      height
    )
  }
  
  r_mat <- round(img[, , 1] * 255)
  g_mat <- round(img[, , 2] * 255)
  b_mat <- round(img[, , 3] * 255)
  
  r <- terra::rast(
    nrows = height,
    ncols = width,
    xmin = xmin,
    xmax = xmax,
    ymin = ymin,
    ymax = ymax,
    crs = paste0("EPSG:", target_crs)
  )
  
  g <- r
  b <- r
  
  terra::values(r) <- as.vector(t(r_mat))
  terra::values(g) <- as.vector(t(g_mat))
  terra::values(b) <- as.vector(t(b_mat))
  
  rgb <- c(r, g, b)
  names(rgb) <- c("cir_red", "cir_green", "cir_blue")
  
  terra::writeRaster(
    rgb,
    out_rgb_tif,
    overwrite = overwrite,
    gdal = c("COMPRESS=DEFLATE", "TILED=YES")
  )
  
  # ----------------------------------------------------------
  # Restituierte RGB-/Excess-Farblogik
  # ----------------------------------------------------------
  #
  # DOP-CIR:
  #   Vegetation: rot / magenta
  #     -> R deutlich höher als G und B
  #
  #   Wasser: dunkel türkis / blaugrün
  #     -> R niedrig
  #     -> G und B deutlich höher als R
  #     -> G und B aber nicht extrem verschieden
  #     -> insgesamt eher dunkel
  #
  #   Versiegelung / Bebauung:
  #     -> Restklasse
  #     -> grau, cyan, hell, asphaltartig, Dachflächen, Schatten usw.
  #
  # ----------------------------------------------------------
  
  r <- rgb[[1]]
  g <- rgb[[2]]
  b <- rgb[[3]]
  
  brightness <- (r + g + b) / 3
  
  max_gb <- terra::ifel(g >= b, g, b)
  min_gb <- terra::ifel(g <= b, g, b)
  
  rgb_max <- terra::ifel(
    r >= g & r >= b,
    r,
    terra::ifel(g >= b, g, b)
  )
  
  rgb_min <- terra::ifel(
    r <= g & r <= b,
    r,
    terra::ifel(g <= b, g, b)
  )
  
  red_excess <- r - max_gb
  cyan_excess <- min_gb - r
  gb_diff <- abs(g - b)
  rgb_range <- rgb_max - rgb_min
  
  vegetation <- (
    r >= vegetation_red_min &
      red_excess >= vegetation_red_excess_min &
      r >= g * vegetation_red_ratio &
      r >= b * vegetation_red_ratio
  )
  
  shadow_like <- (
    brightness < shadow_brightness_max &
      rgb_range < shadow_rgb_range_max
  )
  
  water <- (
    r <= water_red_max &
      cyan_excess >= water_cyan_excess_min &
      gb_diff <= water_gb_diff_max &
      brightness <= water_brightness_max &
      !vegetation &
      !shadow_like
  )
  
  class <- r * NA_integer_
  class <- terra::ifel(water, 2L, class)
  class <- terra::ifel(!water & vegetation, 1L, class)
  class <- terra::ifel(is.na(class), 3L, class)
  
  names(class) <- "klasse_id"
  
  # ----------------------------------------------------------
  # Optionaler Majority-Filter / Modusfilter
  # ----------------------------------------------------------
  
  if (isTRUE(majority_filter)) {
    majority_radius_px <- as.integer(majority_radius_px)
    
    if (is.na(majority_radius_px) || majority_radius_px < 1L) {
      stop("majority_radius_px muss eine ganze Zahl >= 1 sein.")
    }
    
    majority_window_size <- 2L * majority_radius_px + 1L
    
    message(
      "Wende Majority-Filter an: Radius ",
      majority_radius_px,
      " px, Fenster ",
      majority_window_size,
      " x ",
      majority_window_size,
      " px."
    )
    
    class <- terra::focal(
      class,
      w = matrix(
        1,
        nrow = majority_window_size,
        ncol = majority_window_size
      ),
      fun = dop_cir_majority_fun,
      na.policy = "omit",
      fillvalue = NA
    )
    
    names(class) <- "klasse_id"
  }
  
  # ----------------------------------------------------------
  # Water-specific raster sieve
  # ----------------------------------------------------------
  #
  # The raw RGB/CIR rule may create isolated false-positive water
  # pixels. Full vector smoothing can remove small real water bodies,
  # while complete protection keeps false-positive speckles. Therefore
  # water is cleaned on the raster before vectorization:
  #
  #   1. identify connected water patches
  #   2. remove patches smaller than water_min_pixels
  #   3. reassign removed water pixels to class 3
  #
  # This keeps marked water bodies such as the Aachener Weiher while
  # removing isolated blue artifacts.
  #
  # ----------------------------------------------------------
  
  if (isTRUE(water_sieve)) {
    
    water_min_pixels <- as.integer(water_min_pixels)
    
    if (is.na(water_min_pixels) || water_min_pixels < 1L) {
      stop("water_min_pixels muss eine ganze Zahl >= 1 sein.")
    }
    
    message(
      "Entferne kleine Wasser-Speckles: Mindestgröße ",
      water_min_pixels,
      " Pixel."
    )
    
    water_raster <- class == 2L
    
    water_patches <- terra::patches(
      water_raster,
      directions = 8,
      zeroAsNA = TRUE
    )
    
    patch_freq <- terra::freq(
      water_patches
    )
    
    if (!is.null(patch_freq) && nrow(patch_freq) > 0) {
      
      small_patch_ids <- patch_freq$value[
        patch_freq$count < water_min_pixels
      ]
      
      if (length(small_patch_ids) > 0) {
        
        small_water <- water_patches %in% small_patch_ids
        
        class <- terra::ifel(
          small_water,
          3L,
          class
        )
        
        names(class) <- "klasse_id"
      }
    }
  }
  
  # ----------------------------------------------------------
  # Vegetation-specific raster sieve
  # ----------------------------------------------------------
  #
  # Small parks, tree groups, green strips and courtyards can have a
  # strong local thermal relevance. Therefore vegetation is handled
  # analogously to water: isolated one-pixel artifacts can be removed,
  # but the minimum patch size must remain conservative.
  #
  #   1. identify connected vegetation patches
  #   2. remove patches smaller than vegetation_min_pixels
  #   3. reassign removed vegetation pixels to class 3
  #
  # With target_res_m = 30 and vegetation_min_pixels = 4, the minimum
  # retained green patch is 3,600 m². Lower this value if small urban
  # green spaces are being removed.
  #
  # ----------------------------------------------------------
  
  if (isTRUE(vegetation_sieve)) {
    
    vegetation_min_pixels <- as.integer(vegetation_min_pixels)
    
    if (is.na(vegetation_min_pixels) || vegetation_min_pixels < 1L) {
      stop("vegetation_min_pixels muss eine ganze Zahl >= 1 sein.")
    }
    
    message(
      "Entferne kleine Vegetations-Speckles: Mindestgröße ",
      vegetation_min_pixels,
      " Pixel."
    )
    
    vegetation_raster <- class == 1L
    
    vegetation_patches <- terra::patches(
      vegetation_raster,
      directions = 8,
      zeroAsNA = TRUE
    )
    
    patch_freq <- terra::freq(
      vegetation_patches
    )
    
    if (!is.null(patch_freq) && nrow(patch_freq) > 0) {
      
      small_patch_ids <- patch_freq$value[
        patch_freq$count < vegetation_min_pixels
      ]
      
      if (length(small_patch_ids) > 0) {
        
        small_vegetation <- vegetation_patches %in% small_patch_ids
        
        class <- terra::ifel(
          small_vegetation,
          3L,
          class
        )
        
        names(class) <- "klasse_id"
      }
    }
  }
  
  # ----------------------------------------------------------
  # AOI-Maske anwenden und Integer-Raster erzwingen
  # ----------------------------------------------------------
  
  aoi_vect <- terra::vect(aoi)
  class <- terra::mask(class, aoi_vect)
  
  class <- round(class)
  class <- terra::ifel(
    class == 1,
    1L,
    terra::ifel(
      class == 2,
      2L,
      terra::ifel(class == 3, 3L, NA)
    )
  )
  
  names(class) <- "klasse_id"
  
  terra::writeRaster(
    class,
    out_class_tif,
    overwrite = overwrite,
    datatype = "INT1U",
    gdal = c("COMPRESS=DEFLATE", "TILED=YES")
  )
  
  # ----------------------------------------------------------
  # Klassenvorschau als PNG schreiben
  # ----------------------------------------------------------
  
  class_vals <- terra::values(class, mat = FALSE)
  
  class_mat <- matrix(
    class_vals,
    nrow = height,
    ncol = width,
    byrow = TRUE
  )
  
  preview <- array(255, dim = c(height, width, 4))
  
  # 1 Vegetation = grün
  preview[, , 1][class_mat == 1] <- 70
  preview[, , 2][class_mat == 1] <- 170
  preview[, , 3][class_mat == 1] <- 80
  preview[, , 4][class_mat == 1] <- 255
  
  # 2 Wasser = blau
  preview[, , 1][class_mat == 2] <- 40
  preview[, , 2][class_mat == 2] <- 120
  preview[, , 3][class_mat == 2] <- 210
  preview[, , 4][class_mat == 2] <- 255
  
  # 3 Versiegelung / Bebauung = rot/grau
  preview[, , 1][class_mat == 3] <- 190
  preview[, , 2][class_mat == 3] <- 70
  preview[, , 3][class_mat == 3] <- 60
  preview[, , 4][class_mat == 3] <- 255
  
  # NA transparent
  preview[, , 4][is.na(class_mat)] <- 0
  
  png::writePNG(preview / 255, out_class_png)
  
  # ----------------------------------------------------------
  # Optional: Polygone erzeugen
  # ----------------------------------------------------------
  
  if (write_polygons) {
    message("Vektorisiere 30-m-Klassenraster ...")
    
    poly <- terra::as.polygons(
      class,
      dissolve = TRUE,
      values = TRUE,
      na.rm = TRUE
    )
    
    poly_sf <- sf::st_as_sf(poly)
    poly_sf <- sf::st_make_valid(poly_sf)
    
    attr_cols <- setdiff(names(poly_sf), attr(poly_sf, "sf_column"))
    
    if ("klasse_id" %in% attr_cols) {
      id_col <- "klasse_id"
    } else if (length(attr_cols) >= 1) {
      id_col <- attr_cols[1]
      names(poly_sf)[names(poly_sf) == id_col] <- "klasse_id"
    } else {
      stop("Vektorisierung hat keine Attributspalte für klasse_id erzeugt.")
    }
    
    poly_sf$klasse_id <- as.integer(poly_sf$klasse_id)
    
    poly_sf$klasse_name <- NA_character_
    poly_sf$klasse_name[poly_sf$klasse_id == 1L] <- "Vegetation"
    poly_sf$klasse_name[poly_sf$klasse_id == 2L] <- "Wasser"
    poly_sf$klasse_name[poly_sf$klasse_id == 3L] <- "Versiegelung / Bebauung"
    
    # --------------------------------------------------------
    # Vektor-Glättung der Rastertreppen
    # --------------------------------------------------------
    #
    # Das 30-m-Klassenraster bleibt unverändert.
    # Geglättet wird ausschließlich die Polygongeometrie nach
    # terra::as.polygons(). Das ist der richtige Ort, weil die
    # sichtbaren Treppen durch Rasterzellen -> Polygonkanten
    # entstehen.
    #
    # Methode:
    #   smoothr::smooth(method = "ksmooth")
    #
    # Keine HSV-Logik.
    # Keine Änderung der Klassifikation.
    # Keine Buffer-Kaskade.
    # Keine Chaikin-/Spline-Eigenimplementierung.
    #
    # --------------------------------------------------------
    
    if (isTRUE(vector_smooth)) {
      
      if (!requireNamespace("smoothr", quietly = TRUE)) {
        stop(
          "Paket 'smoothr' fehlt. Installieren mit install.packages('smoothr') ",
          "oder vector_smooth = FALSE setzen."
        )
      }
      
      vector_smooth_m <- as.numeric(vector_smooth_m)
      vector_simplify_m <- as.numeric(vector_simplify_m)
      
      if (is.na(vector_smooth_m) || vector_smooth_m <= 0) {
        stop("vector_smooth_m muss numerisch und > 0 sein.")
      }
      
      if (is.na(vector_simplify_m) || vector_simplify_m < 0) {
        stop("vector_simplify_m muss numerisch und >= 0 sein.")
      }
      
      message(
        "Glätte Polygonränder mit smoothr::smooth(method = 'ksmooth'); ",
        "smoothness = ",
        vector_smooth_m,
        "; simplify_m = ",
        vector_simplify_m,
        "."
      )
      
      poly_sf <- sf::st_make_valid(poly_sf)
      
      # ------------------------------------------------------
      # Coverage-preserving vector smoothing with snap-to-grid
      # ------------------------------------------------------
      #
      # Goal:
      #   Convert the stair-stepped polygon boundaries from the 30 m
      #   raster into smoother cartographic polygon boundaries while
      #   keeping a closed polygon coverage.
      #
      # Mechanical rules:
      #   1. Only water and vegetation are smoothed.
      #   2. Water and vegetation are snapped to a fixed coordinate grid.
      #   3. Priority is fixed:
      #        water > vegetation > built-up / sealed
      #   4. Class 3 is reconstructed as the exact AOI remainder:
      #        built-up / sealed = AOI - water - vegetation
      #   5. The final geometries are snapped again before writing.
      #
      # This is not a new classification step. It is only a geometric
      # post-processing step for the polygon output.
      #
      # ------------------------------------------------------
      
      water_smooth_m <- as.numeric(water_smooth_m)
      vegetation_smooth_m <- as.numeric(vegetation_smooth_m)
      vector_simplify_m <- as.numeric(vector_simplify_m)
      coverage_snap_grid_m <- as.numeric(coverage_snap_grid_m)
      
      if (is.na(water_smooth_m) || water_smooth_m < 0) {
        stop("water_smooth_m muss numerisch und >= 0 sein.")
      }
      
      if (is.na(vegetation_smooth_m) || vegetation_smooth_m < 0) {
        stop("vegetation_smooth_m muss numerisch und >= 0 sein.")
      }
      
      if (is.na(vector_simplify_m) || vector_simplify_m < 0) {
        stop("vector_simplify_m muss numerisch und >= 0 sein.")
      }
      
      if (isTRUE(coverage_snap)) {
        if (!requireNamespace("lwgeom", quietly = TRUE)) {
          stop(
            "Paket 'lwgeom' fehlt. Installieren mit install.packages('lwgeom') ",
            "oder coverage_snap = FALSE setzen."
          )
        }
        
        if (is.na(coverage_snap_grid_m) || coverage_snap_grid_m <= 0) {
          stop("coverage_snap_grid_m muss numerisch und > 0 sein.")
        }
      }
      
      message(
        "Glätte coverage-erhaltend mit Snap-to-grid: Wasser ",
        water_smooth_m,
        " m; Vegetation ",
        vegetation_smooth_m,
        " m; Snap-Grid ",
        if (isTRUE(coverage_snap)) coverage_snap_grid_m else NA_real_,
        " m; Klasse 3 wird als AOI-Restfläche rekonstruiert."
      )
      
      snap_geom <- function(g) {
        if (is.null(g)) {
          return(NULL)
        }
        
        g <- sf::st_make_valid(g)
        g <- suppressWarnings(sf::st_collection_extract(g, "POLYGON"))
        
        if (length(g) == 0) {
          return(NULL)
        }
        
        if (isTRUE(coverage_snap)) {
          g <- lwgeom::st_snap_to_grid(
            g,
            size = coverage_snap_grid_m
          )
          g <- sf::st_make_valid(g)
          g <- suppressWarnings(sf::st_collection_extract(g, "POLYGON"))
        }
        
        if (length(g) == 0) {
          return(NULL)
        }
        
        g
      }
      
      union_geom <- function(x) {
        if (is.null(x)) {
          return(NULL)
        }
        
        if (inherits(x, "sf")) {
          if (nrow(x) == 0) {
            return(NULL)
          }
          g <- sf::st_geometry(x)
        } else {
          g <- x
        }
        
        g <- snap_geom(g)
        
        if (is.null(g)) {
          return(NULL)
        }
        
        g <- sf::st_union(g)
        g <- snap_geom(g)
        
        g
      }
      
      smooth_class_geom <- function(x, smooth_m) {
        if (nrow(x) == 0) {
          return(NULL)
        }
        
        x <- sf::st_make_valid(x)
        
        if (smooth_m > 0) {
          x <- smoothr::smooth(
            x,
            method = "ksmooth",
            smoothness = smooth_m
          )
          x <- sf::st_make_valid(x)
          x <- suppressWarnings(sf::st_collection_extract(x, "POLYGON"))
        }
        
        if (nrow(x) == 0) {
          return(NULL)
        }
        
        union_geom(x)
      }
      
      aoi_union <- sf::st_union(sf::st_geometry(aoi))
      aoi_union <- snap_geom(aoi_union)
      
      if (is.null(aoi_union)) {
        stop("AOI geometry collapsed during snap-to-grid processing.")
      }
      
      poly_vegetation <- poly_sf[poly_sf$klasse_id == 1L, ]
      poly_water <- poly_sf[poly_sf$klasse_id == 2L, ]
      
      water_final <- smooth_class_geom(
        poly_water,
        water_smooth_m
      )
      
      vegetation_final <- smooth_class_geom(
        poly_vegetation,
        vegetation_smooth_m
      )
      
      # Clip water to AOI.
      if (!is.null(water_final)) {
        water_final <- suppressWarnings(
          sf::st_intersection(water_final, aoi_union)
        )
        water_final <- union_geom(water_final)
      }
      
      # Clip vegetation to AOI and remove water overlap.
      if (!is.null(vegetation_final)) {
        vegetation_final <- suppressWarnings(
          sf::st_intersection(vegetation_final, aoi_union)
        )
        vegetation_final <- union_geom(vegetation_final)
        
        if (!is.null(water_final)) {
          vegetation_final <- suppressWarnings(
            sf::st_difference(vegetation_final, water_final)
          )
          vegetation_final <- union_geom(vegetation_final)
        }
      }
      
      # Build occupied area from water and vegetation after priority.
      occupied <- NULL
      
      if (!is.null(water_final) && !is.null(vegetation_final)) {
        occupied <- sf::st_union(water_final, vegetation_final)
        occupied <- union_geom(occupied)
      } else if (!is.null(water_final)) {
        occupied <- union_geom(water_final)
      } else if (!is.null(vegetation_final)) {
        occupied <- union_geom(vegetation_final)
      }
      
      # Class 3 is the AOI remainder. This closes gaps mechanically.
      if (!is.null(occupied)) {
        built_final <- suppressWarnings(
          sf::st_difference(aoi_union, occupied)
        )
      } else {
        built_final <- aoi_union
      }
      
      built_final <- union_geom(built_final)
      
      make_class_sf <- function(geom, klasse_id, klasse_name) {
        geom <- union_geom(geom)
        
        if (is.null(geom)) {
          return(NULL)
        }
        
        sf::st_as_sf(
          data.frame(
            klasse_id = as.integer(klasse_id),
            klasse_name = klasse_name
          ),
          geometry = sf::st_sfc(geom, crs = sf::st_crs(aoi))
        )
      }
      
      parts <- list(
        make_class_sf(vegetation_final, 1L, "Vegetation"),
        make_class_sf(water_final, 2L, "Wasser"),
        make_class_sf(built_final, 3L, "Versiegelung / Bebauung")
      )
      
      parts <- parts[!vapply(parts, is.null, logical(1))]
      
      if (length(parts) == 0) {
        stop("Coverage-preserving smoothing produced no polygon output.")
      }
      
      poly_sf <- do.call(rbind, parts)
      poly_sf <- sf::st_make_valid(poly_sf)
      poly_sf <- suppressWarnings(sf::st_collection_extract(poly_sf, "POLYGON"))
      
      # Final snap of all output geometries to the same grid.
      if (isTRUE(coverage_snap)) {
        geom <- sf::st_geometry(poly_sf)
        geom <- lwgeom::st_snap_to_grid(
          geom,
          size = coverage_snap_grid_m
        )
        geom <- sf::st_make_valid(geom)
        geom <- suppressWarnings(sf::st_collection_extract(geom, "POLYGON"))
        sf::st_geometry(poly_sf) <- geom
        poly_sf <- sf::st_make_valid(poly_sf)
      }
      
      if (vector_simplify_m > 0) {
        
        # Simplification is applied only to class 3.
        # Water and vegetation are kept geometrically conservative
        # because small lakes, ponds, parks and green spaces matter.
        poly_vegetation <- poly_sf[poly_sf$klasse_id == 1L, ]
        poly_water <- poly_sf[poly_sf$klasse_id == 2L, ]
        poly_built <- poly_sf[poly_sf$klasse_id == 3L, ]
        
        if (nrow(poly_built) > 0) {
          poly_built <- sf::st_simplify(
            poly_built,
            dTolerance = vector_simplify_m,
            preserveTopology = TRUE
          )
          
          poly_built <- sf::st_make_valid(poly_built)
          
          if (isTRUE(coverage_snap)) {
            geom <- sf::st_geometry(poly_built)
            geom <- lwgeom::st_snap_to_grid(
              geom,
              size = coverage_snap_grid_m
            )
            geom <- sf::st_make_valid(geom)
            sf::st_geometry(poly_built) <- geom
          }
          
          poly_built <- suppressWarnings(
            sf::st_collection_extract(poly_built, "POLYGON")
          )
        }
        
        parts <- list(poly_vegetation, poly_water, poly_built)
        parts <- parts[vapply(parts, nrow, integer(1)) > 0]
        
        if (length(parts) == 0) {
          stop("Simplification produced no polygon output.")
        }
        
        poly_sf <- do.call(rbind, parts)
        poly_sf <- sf::st_make_valid(poly_sf)
        poly_sf <- suppressWarnings(
          sf::st_collection_extract(poly_sf, "POLYGON")
        )
      }
      
      poly_sf$flaeche_m2 <- as.numeric(sf::st_area(poly_sf))
      
      geom_col <- attr(poly_sf, "sf_column")
      
      poly_sf <- poly_sf[, c(
        "klasse_id",
        "klasse_name",
        "flaeche_m2",
        geom_col
      )]
      
      if (file.exists(out_poly_gpkg) && overwrite) {
        file.remove(out_poly_gpkg)
      }
      
      sf::st_write(
        poly_sf,
        out_poly_gpkg,
        layer = "dop_cir_30m_3klassen",
        quiet = TRUE
      )
    }
    
    # ----------------------------------------------------------
    # Parameter schreiben
    # ----------------------------------------------------------
    
    params <- list(
      data_source = list(
        name = "DOP Colorinfrarot",
        provider = "Geobasis NRW WMS",
        url = wms_url,
        layer = wms_layer,
        format = wms_format
      ),
      processing = list(
        target_crs = target_crs,
        target_res_m = target_res_m,
        bbox = c(
          xmin = xmin,
          ymin = ymin,
          xmax = xmax,
          ymax = ymax
        ),
        width = width,
        height = height
      ),
      thresholds = list(
        vegetation_red_ratio = vegetation_red_ratio,
        vegetation_red_min = vegetation_red_min,
        vegetation_red_excess_min = vegetation_red_excess_min,
        water_red_max = water_red_max,
        water_brightness_max = water_brightness_max,
        water_cyan_excess_min = water_cyan_excess_min,
        water_gb_diff_max = water_gb_diff_max,
        shadow_brightness_max = shadow_brightness_max,
        shadow_rgb_range_max = shadow_rgb_range_max
      ),
      majority_filter = list(
        enabled = isTRUE(majority_filter),
        radius_px = as.integer(majority_radius_px),
        window_size_px = if (isTRUE(majority_filter)) {
          2L * as.integer(majority_radius_px) + 1L
        } else {
          NA_integer_
        },
        approximate_window_m = if (isTRUE(majority_filter)) {
          (2L * as.integer(majority_radius_px) + 1L) * target_res_m
        } else {
          NA_real_
        }
      ),
      water_sieve = list(
        enabled = isTRUE(water_sieve),
        min_pixels = as.integer(water_min_pixels),
        min_area_m2 = as.integer(water_min_pixels) * target_res_m * target_res_m
      ),
      vegetation_sieve = list(
        enabled = isTRUE(vegetation_sieve),
        min_pixels = as.integer(vegetation_min_pixels),
        min_area_m2 = as.integer(vegetation_min_pixels) * target_res_m * target_res_m
      ),
      vector_smoothing = list(
        enabled = isTRUE(vector_smooth),
        method = "coverage_preserving_smoothr_ksmooth_remainder_snap_to_grid",
        water_smooth_m = as.numeric(water_smooth_m),
        vegetation_smooth_m = as.numeric(vegetation_smooth_m),
        coverage_snap = isTRUE(coverage_snap),
        coverage_snap_grid_m = as.numeric(coverage_snap_grid_m),
        built_class = "AOI remainder after water and vegetation",
        simplify_m = as.numeric(vector_simplify_m)
      ),
      classes = list(
        `1` = "Vegetation",
        `2` = "Wasser",
        `3` = "Versiegelung / Bebauung"
      ),
      warning = paste(
        "Das DOP-CIR-WMS ist eine farbige Darstellung und kein",
        "radiometrisch kalibriertes Fernerkundungsprodukt.",
        "Die Klassifikation ist didaktisch und für den Vergleich",
        "mit Landsat-LST auf 30 m Maßstab gedacht."
      )
    )
    
    jsonlite::write_json(
      params,
      out_json,
      pretty = TRUE,
      auto_unbox = TRUE
    )
    
    message("geschrieben: ", out_png)
    message("geschrieben: ", out_rgb_tif)
    message("geschrieben: ", out_class_tif)
    message("geschrieben: ", out_class_png)
    if (write_polygons) {
      message("geschrieben: ", out_poly_gpkg)
    }
    message("geschrieben: ", out_json)
    
    invisible(list(
      png = out_png,
      rgb = out_rgb_tif,
      class_raster = out_class_tif,
      class_preview = out_class_png,
      polygons = if (write_polygons) out_poly_gpkg else NA_character_,
      parameters = out_json
    ))
  }
}