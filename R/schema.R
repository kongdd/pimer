#' JSON schema helpers for Pi extraction
#'
#' These minimal constructors create ordinary JSON Schema lists. They do not
#' enable provider-side constrained decoding; pimer validates results in R.
#' @export
pi_type_string <- function(description = NULL) {
  schema <- list(type = "string")
  if (!is.null(description)) schema$description <- description
  schema
}

#' @rdname pi_type_string
#' @export
pi_type_integer <- function(description = NULL) {
  schema <- list(type = "integer")
  if (!is.null(description)) schema$description <- description
  schema
}

#' @rdname pi_type_string
#' @export
pi_type_number <- function(description = NULL) {
  schema <- list(type = "number")
  if (!is.null(description)) schema$description <- description
  schema
}

#' @rdname pi_type_string
#' @export
pi_type_boolean <- function(description = NULL) {
  schema <- list(type = "boolean")
  if (!is.null(description)) schema$description <- description
  schema
}

#' @param values One or more allowed character values.
#' @rdname pi_type_string
#' @export
pi_type_enum <- function(values, description = NULL) {
  stopifnot(is.character(values), length(values) > 0, !anyNA(values))
  schema <- pi_type_string(description)
  schema$enum <- as.list(values)
  schema
}

#' @param items Schema describing each array element.
#' @rdname pi_type_string
#' @export
pi_type_array <- function(items, description = NULL) {
  stopifnot(is.list(items), !is.null(items$type))
  schema <- list(type = "array", items = items)
  if (!is.null(description)) schema$description <- description
  schema
}

#' @param ... Named property schemas.
#' @param required Names of required properties. All are required by default.
#' @rdname pi_type_string
#' @export
pi_type_object <- function(..., required = NULL, description = NULL) {
  props <- list(...)
  if (length(props) && (is.null(names(props)) || any(!nzchar(names(props))))) {
    stop("All object properties must be named.", call. = FALSE)
  }
  if (is.null(required)) required <- names(props)
  if (!all(required %in% names(props))) {
    stop("'required' must refer to named properties.", call. = FALSE)
  }
  schema <- list(type = "object", properties = props, required = as.list(required),
                 additionalProperties = FALSE)
  if (!is.null(description)) schema$description <- description
  schema
}

strip_json_fence <- function(x) {
  x <- trimws(x)
  x <- sub("^```(?:json)?[[:space:]]*", "", x, ignore.case = TRUE, perl = TRUE)
  trimws(sub("[[:space:]]*```$", "", x, perl = TRUE))
}

# Check the supported schema subset. Parsed with simplifyVector=FALSE, so JSON
# arrays become unnamed lists and JSON objects become named lists.
check_schema <- function(value, schema, path = "$") {
  kind <- schema$type
  if (is.null(kind) || length(kind) != 1L) return("type is missing")
  object <- is.list(value) && !is.null(names(value))
  array <- is.list(value) && is.null(names(value))
  if (identical(kind, "object")) {
    if (!object && !(is.list(value) && !length(value))) return(paste(path, "must be an object"))
    keys <- names(value)
    for (key in unlist(schema$required, use.names = FALSE)) {
      if (!key %in% keys) return(paste(path, "missing required property", key))
    }
    allowed <- names(schema$properties)
    if (identical(schema$additionalProperties, FALSE) && any(!keys %in% allowed)) {
      return(paste(path, "contains unknown property", keys[which(!keys %in% allowed)[1]]))
    }
    for (key in intersect(keys, allowed)) {
      result <- check_schema(value[[key]], schema$properties[[key]], paste0(path, ".", key))
      if (!is.null(result)) return(result)
    }
  } else if (identical(kind, "array")) {
    if (!array) return(paste(path, "must be an array"))
    for (i in seq_along(value)) {
      result <- check_schema(value[[i]], schema$items, sprintf("%s[%d]", path, i))
      if (!is.null(result)) return(result)
    }
  } else {
    ok <- switch(kind,
      string = is.character(value) && length(value) == 1L,
      boolean = is.logical(value) && length(value) == 1L,
      number = is.numeric(value) && length(value) == 1L && is.finite(value),
      integer = is.numeric(value) && length(value) == 1L && is.finite(value) && value == floor(value),
      FALSE
    )
    if (!ok) return(paste(path, "must be", kind))
    if (!is.null(schema$enum) && !value %in% unlist(schema$enum, use.names = FALSE)) {
      return(paste(path, "is not in allowed values"))
    }
  }
  NULL
}
