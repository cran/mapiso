#' @title Create Contour Polygons from Regular Grids
#' @description Regularly spaced grids containing continuous data are
#' transformed into contour polygons. A grid can be defined by a
#' data.frame (x, y, value), an \code{sf} object or a \code{terra} SpatRaster.
#'
#' @param x a data.frame, an sf object or a SpatRaster
#' @param var name of the variable, for data.frames and sf objects only
#' @param breaks list of break values (default to equal interval)
#' @param nbreaks number of classes
#' @param mask an sf object of polygons or multipolygons.
#' \code{mask} is  used to clip contour polygons
#' @param coords names of the coordinates variables
#' (e.g. \code{c("lon", "lat")}), for data.frames only
#' @param crs CRS code (e.g. "epsg:2154"), for data.frames only.
#' @importFrom sf st_union st_intersection st_cast st_agr<- st_coordinates
#' st_crs st_geometry st_sf st_sfc
#' @importFrom isoband isobands iso_to_sfg
#' @return The output is an sf object of polygons. The data frame contains three
#' fields: id (id of each polygon), isomin and isomax (minimum and maximum
#' breaks of the polygon).
#' @export
#' @examples
#' # sf, using a mask
#' library(sf)
#' s <- st_read(system.file("gpkg/elevation.gpkg", package = "mapiso"),
#'   layer = "elevation", quiet = TRUE
#' )
#' m <- st_read(system.file("gpkg/elevation.gpkg", package = "mapiso"),
#'   layer = "com", quiet = TRUE
#' )
#' isos <- mapiso(
#'   x = s, var = "elevation",
#'   mask = m
#' )
#' plot(isos)
#'
#' # data.frame, using user breaks values
#' d <- read.csv(system.file("csv/elevation.csv", package = "mapiso"))
#' bks <- c(98, 100, 150, 200, 250, 300, 350, 400, 412.6)
#' isod <- mapiso(
#'   x = d, var = "elevation",
#'   breaks = bks, coords = c("x", "y"), crs = "epsg:2154"
#' )
#' plot(isod)
#' if (require(mapsf, quietly = TRUE)) {
#'   mf_map(isod, "isomin", "choro", breaks = bks, leg_title = "Elevation")
#' }
#' \dontrun{
#' # terra
#' if (require(terra, quietly = TRUE)) {
#'   r <- rast(system.file("tif/elevation.tif", package = "mapiso"))
#'   isor <- mapiso(x = r)
#'   plot(r)
#'   library(sf)
#'   plot(st_geometry(isor), add = TRUE, col = NA)
#' }
#' }
#'
mapiso <- function(x, var, breaks, nbreaks = 8, mask, coords, crs) {
  # test inputs
  if (!inherits(x = x, what = c("SpatRaster", "sf", "data.frame"))) {
    stop(
      "'x' should be a data.frame, an sf data.frame or a SpatRaster.",
      call. = FALSE
    )
  }

  if (inherits(x = x, what = "SpatRaster")) {
    if (!requireNamespace("terra", quietly = TRUE)) {
      stop(
        paste0(
          "This function needs the 'terra' package to work with ",
          "SpatRaster objects. Please install it."
        ),
        call. = FALSE
      )
    }
    if (terra::nlyr(x) != 1) {
      stop(
        "'x' should be a single layer SpatRaster.",
        call. = FALSE
      )
    }
    ext <- terra::ext(x)
    nc <- terra::ncol(x)
    nr <- terra::nrow(x)
    xr <- terra::xres(x) / 2
    yr <- terra::yres(x) / 2
    crs <- st_crs(x)
    lon <- seq(ext[1] + xr, ext[2] - xr, length.out = nc)
    lat <- seq(ext[4] - yr, ext[3] + yr, length.out = nr)
    m <- matrix(
      data = terra::values(x),
      nrow = nr,
      dimnames = list(lat, lon),
      byrow = TRUE
    )
  }


  if (inherits(x = x, what = "sf")) {
    if (missing(var)) {
      stop("'var' is missing.", call. = FALSE)
    }
    if (!var %in% names(x)) {
      stop("'var' is not a valid variable of 'x'.", call. = FALSE)
    }
    crs <- st_crs(x)
    x <- data.frame(st_coordinates(x), var = x[[var]])
    coords <- c("X", "Y")
    var <- "var"
  }


  if (inherits(x = x, what = "data.frame")) {
    if (missing(var)) {
      stop("'var' is missing.", call. = FALSE)
    }
    if (missing(coords)) {
      stop("'coords' is missing.", call. = FALSE)
    }
    if (!var %in% names(x)) {
      stop("'var' is not a valid variable of 'x'.", call. = FALSE)
    }
    if (length(unique(x[[coords[1]]])) * length(unique(x[[coords[2]]])) != length(x[[var]])) {
      stop(
        "It seems that 'x' is not a regular grid.",
        call. = FALSE
      )
    }

    m <- t(
      matrix(
        data = x[[var]],
        nrow = length(unique(x[[coords[1]]])),
        dimnames = list(
          unique(x[[coords[1]]]),
          unique(x[[coords[2]]])
        )
      )
    )
  }

  # breaks management
  vmin <- min(m, na.rm = TRUE)
  vmax <- max(m, na.rm = TRUE)
  if (missing(breaks)) {
    breaks <- seq(
      from = vmin,
      to = vmax,
      length.out = (nbreaks + 1)
    )
  } else {
    breaks <- sort(unique(c(vmin, breaks[breaks > vmin & breaks < vmax], vmax)))
  }

  # isobanding (+ 1e-10 to avoid invalid polygons)
  lev_low <- breaks[1:(length(breaks) - 1)]
  lev_high <- breaks[2:length(breaks)]
  raw <- isobands(
    x = as.numeric(colnames(m)),
    y = as.numeric(rownames(m)),
    z = m + 1e-10,
    levels_low = lev_low,
    levels_high = c(lev_high[-length(lev_high)], vmax)
  )

  bands <- iso_to_sfg(raw)
  iso <- st_sf(
    id = 1:length(bands),
    isomin = lev_low,
    isomax = lev_high,
    geometry = st_sfc(bands),
    crs = crs
  )

  # mask mgmt
  if (!missing(mask)) {
    st_agr(iso) <- "constant"
    if (st_crs(iso) == st_crs(mask)) {
      iso <- st_cast(st_intersection(x = iso, y = st_union(st_geometry(mask))))
    } else {
      cat(
        "CRS of 'x' and 'mask' should be identical, polygons are not clipped."
      )
    }
  }


  return(iso)
}
