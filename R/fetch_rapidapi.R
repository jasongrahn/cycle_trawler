suppressPackageStartupMessages({
  library(httr2)
  library(jsonlite)
  library(dplyr)
  library(purrr)
  library(readr)
  library(lubridate)
  library(stringr)
})

source("R/normalize.R")

RAPIDAPI_HOST <- "real-time-costco-data.p.rapidapi.com"
QUOTA_PATH    <- "data/quota_rapidapi.csv"
QUOTA_CAP     <- 75L  # update after confirming BASIC plan limit in §4

# ---------- quota helpers ----------

read_quota <- function() {
  if (!file.exists(QUOTA_PATH)) {
    return(tibble(month = character(), calls = integer()))
  }
  read_csv(QUOTA_PATH, col_types = cols(month = col_character(), calls = col_integer()),
           show_col_types = FALSE)
}

calls_this_month <- function(quota) {
  mo <- format(Sys.Date(), "%Y-%m")
  row <- filter(quota, month == mo)
  if (nrow(row) == 0L) 0L else row$calls[[1L]]
}

increment_quota <- function(quota, n) {
  mo <- format(Sys.Date(), "%Y-%m")
  if (any(quota$month == mo)) {
    quota$calls[quota$month == mo] <- quota$calls[quota$month == mo] + n
  } else {
    quota <- bind_rows(quota, tibble(month = mo, calls = n))
  }
  write_csv(quota, QUOTA_PATH)
  quota
}

# ---------- parser ----------
# Field names below are best-guess from typical RapidAPI Costco responses.
# On the first real run, inspect data/raw/<date>_rapidapi_<term>.json and
# update the mapping if the actual keys differ. The function warns loudly on mismatch.

parse_rapidapi_response <- function(raw_list, term) {
  # Common wrapper patterns: list may be top-level array or nested under a key
  items <- if (is.data.frame(raw_list)) {
    raw_list
  } else if (!is.null(raw_list$items)) {
    raw_list$items
  } else if (!is.null(raw_list$products)) {
    raw_list$products
  } else if (!is.null(raw_list$data)) {
    raw_list$data
  } else if (is.list(raw_list) && length(raw_list) > 0 && is.list(raw_list[[1]])) {
    bind_rows(raw_list)
  } else {
    warning("[rapidapi] Unrecognised response shape for term '", term,
            "' — inspect the raw JSON and update parse_rapidapi_response()")
    return(NULL)
  }

  if (nrow(items) == 0L) return(NULL)

  # Warn about any field mapping that falls back to NA
  expected <- c("title", "price", "originalPrice", "onSale", "productUrl", "itemId", "inStock")
  missing  <- setdiff(expected, names(items))
  if (length(missing) > 0) {
    warning("[rapidapi] Expected fields not found in response: ",
            paste(missing, collapse = ", "),
            " — inspect raw JSON and update field mapping")
  }

  items |>
    transmute(
      date        = Sys.Date(),
      source      = "rapidapi",
      title       = as.character(if ("title"         %in% names(items)) title         else NA),
      price       = as.double(  if ("price"          %in% names(items)) price         else NA),
      price_was   = as.double(  if ("originalPrice"  %in% names(items)) originalPrice else NA),
      on_sale     = as.logical( if ("onSale"         %in% names(items)) onSale        else
                                  !is.na(price_was) & price_was > price),
      url         = as.character(if ("productUrl"    %in% names(items)) productUrl    else NA),
      upc_raw     = as.character(if ("itemId"        %in% names(items)) itemId        else NA),
      in_stock    = as.logical( if ("inStock"        %in% names(items)) inStock       else NA),
      keyword     = term,
      category    = NA_character_,
      signal      = NA_real_
    ) |>
    mutate(
      product_key = make_product_key(title, upc = upc_raw)
    ) |>
    select(-upc_raw)
}

# ---------- keyword → category join ----------

join_category <- function(df) {
  kw <- read_csv("keywords.csv", col_types = cols(.default = col_character()),
                 show_col_types = FALSE)
  df |>
    left_join(select(kw, term, category), by = c("keyword" = "term")) |>
    mutate(category = coalesce(category.y, category.x)) |>
    select(-any_of(c("category.x", "category.y")))
}

# ---------- single-term fetcher ----------

fetch_costco <- function(term, key) {
  raw_path <- file.path("data", "raw",
                        paste0(Sys.Date(), "_rapidapi_", str_replace_all(term, " ", "_"), ".json"))

  resp <- tryCatch(
    request(paste0("https://", RAPIDAPI_HOST)) |>
      req_url_path_append("search") |>        # likely path — update if wrong
      req_url_query(query = term, region = "US") |>
      req_headers(
        "X-RapidAPI-Key"  = key,
        "X-RapidAPI-Host" = RAPIDAPI_HOST
      ) |>
      req_retry(max_tries = 3) |>
      req_throttle(rate = 1 / 2) |>
      req_perform(),
    error = function(e) {
      warning("[rapidapi] Request failed for '", term, "': ", conditionMessage(e))
      NULL
    }
  )

  if (is.null(resp)) return(NULL)

  raw_text <- resp_body_string(resp)
  write(raw_text, raw_path)

  raw_list <- tryCatch(
    fromJSON(raw_text, simplifyDataFrame = TRUE),
    error = function(e) {
      warning("[rapidapi] JSON parse failed for '", term, "': ", conditionMessage(e))
      NULL
    }
  )

  if (is.null(raw_list)) return(NULL)

  parse_rapidapi_response(raw_list, term)
}

# ---------- main ----------

run_rapidapi <- function() {
  key <- Sys.getenv("RAPIDAPI_KEY")
  if (nchar(key) == 0L) stop("RAPIDAPI_KEY not set — copy .Renviron.example to .Renviron and fill it in")

  kw        <- read_csv("keywords.csv", col_types = cols(.default = col_character()), show_col_types = FALSE)
  core_terms <- filter(kw, tier == "core") |> pull(term)

  quota <- read_quota()
  used  <- calls_this_month(quota)

  if (used + length(core_terms) > QUOTA_CAP) {
    message("[rapidapi] QUOTA GUARD: would use ", used + length(core_terms),
            " calls (cap ", QUOTA_CAP, ", used this month ", used, "). Skipping run.")
    quit(status = 0, save = "no")
  }

  message("[rapidapi] Fetching ", length(core_terms), " core terms (quota: ",
          used, " used + ", length(core_terms), " new = ",
          used + length(core_terms), " / ", QUOTA_CAP, ")")

  results <- map(core_terms, \(t) {
    message("  → ", t)
    fetch_costco(t, key)
  })

  combined <- bind_rows(compact(results))

  if (nrow(combined) == 0L) {
    warning("[rapidapi] No rows returned — check raw JSON files in data/raw/")
    return(invisible(NULL))
  }

  combined <- join_category(combined)
  written  <- append_history(combined)
  increment_quota(quota, length(core_terms))

  message("[rapidapi] Done. ", nrow(combined), " rows fetched → ",
          nrow(written), " unique rows in history.")
  invisible(combined)
}

run_rapidapi()
