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
QUOTA_CAP     <- 100L  # update after confirming BASIC plan limit in §4

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
# Field mapping confirmed against live API response 2026-07-04.
# Response shape: raw_list$data$products (data.frame, ~20 rows, 86 cols)

parse_rapidapi_response <- function(raw_list, term) {
  items <- if (!is.null(raw_list$data) && is.list(raw_list$data) &&
               is.data.frame(raw_list$data$products)) {
    raw_list$data$products
  } else if (is.data.frame(raw_list)) {
    raw_list
  } else if (is.null(raw_list$data) || !is.data.frame(raw_list$data$products)) {
    # zero-result response (empty list or missing data key) — not an error
    return(NULL)
  } else {
    warning("[rapidapi] Unrecognised response shape for term '", term,
            "' — inspect data/raw/ and update parse_rapidapi_response()")
    return(NULL)
  }

  if (nrow(items) == 0L) return(NULL)

  items |>
    transmute(
      date      = Sys.Date(),
      source    = "rapidapi",
      title     = as.character(item_product_name),
      price     = as.double(item_location_pricing_salePrice),
      price_was = as.double(item_location_pricing_listPrice),
      on_sale   = (!is.na(price) & !is.na(price_was) & price < price_was) |
                    str_detect(coalesce(item_product_marketing_statement, ""),
                               regex("\\boff\\b|save|savings|instant", ignore_case = TRUE)),
      url       = paste0("https://www.costco.com/s?keyword=", utils::URLencode(item_product_name, reserved=TRUE)),
      upc_raw   = as.character(item_number),
      in_stock  = as.logical(isItemInStock),
      keyword   = term,
      category  = NA_character_,
      signal    = NA_real_
    ) |>
    mutate(product_key = make_product_key(title, upc = upc_raw)) |>
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
