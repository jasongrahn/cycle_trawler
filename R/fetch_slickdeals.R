suppressPackageStartupMessages({
  library(httr2)
  library(tidyRSS)
  library(dplyr)
  library(purrr)
  library(readr)
  library(stringr)
})

source("R/normalize.R")

PRICE_RE   <- r"(\$\s?(\d{1,4}(?:\.\d{2})?))"
ON_SALE_RE <- r"((?i)(sale|markdown|clearance|\.97|instant savings|deal))"

# ---------- price helpers (same logic as reddit) ----------

extract_prices <- function(title) {
  matches <- str_match_all(title, PRICE_RE)[[1]]
  if (nrow(matches) == 0L) return(list(price = NA_real_, price_was = NA_real_))
  vals <- sort(as.double(matches[, 2]))
  if (length(vals) == 1L) list(price = vals[[1L]], price_was = NA_real_)
  else                    list(price = vals[[1L]], price_was = vals[[length(vals)]])
}

# ---------- single-term fetcher ----------

fetch_slickdeals <- function(term) {
  url <- paste0(
    "https://slickdeals.net/newsearch.php?",
    "q=", utils::URLencode(paste(term, "costco"), reserved = TRUE),
    "&searchin=first&rss=1"
  )

  # verify RSS is reachable before handing to tidyRSS
  probe <- tryCatch(
    request(url) |>
      req_throttle(rate = 1 / 2) |>
      req_retry(max_tries = 3) |>
      req_perform(),
    error = function(e) {
      warning("[slickdeals] Request failed for '", term, "': ", conditionMessage(e))
      NULL
    }
  )

  if (is.null(probe)) return(NULL)
  if (resp_status(probe) != 200L) {
    warning("[slickdeals] HTTP ", resp_status(probe), " for '", term, "'")
    return(NULL)
  }

  feed <- tryCatch(
    tidyfeed(url),
    error = function(e) {
      warning("[slickdeals] RSS parse failed for '", term, "': ", conditionMessage(e))
      NULL
    }
  )

  if (is.null(feed) || nrow(feed) == 0L) return(NULL)

  # keep only items mentioning costco
  feed <- filter(feed, str_detect(item_title %||% "", regex("costco", ignore_case = TRUE)))
  if (nrow(feed) == 0L) return(NULL)

  feed |>
    rowwise() |>
    mutate(
      prices   = list(extract_prices(item_title %||% "")),
      price    = prices$price,
      price_was = prices$price_was
    ) |>
    ungroup() |>
    transmute(
      date        = Sys.Date(),
      source      = "slickdeals",
      title       = item_title %||% NA_character_,
      price       = price,
      price_was   = price_was,
      on_sale     = str_detect(item_title %||% "", regex(ON_SALE_RE)) |
                      (!is.na(price_was) & price_was > price),
      url         = item_link %||% NA_character_,
      keyword     = term,
      category    = NA_character_,
      signal      = NA_real_,
      in_stock    = NA,
      product_key = make_product_key(item_title %||% "")
    )
}

# ---------- keyword → category join ----------

join_category <- function(df) {
  kw <- read_csv("keywords.csv", col_types = cols(.default = col_character()), show_col_types = FALSE)
  df |>
    left_join(select(kw, term, category), by = c("keyword" = "term")) |>
    mutate(category = coalesce(category.y, category.x)) |>
    select(-any_of(c("category.x", "category.y")))
}

# ---------- main ----------

run_slickdeals <- function() {
  kw    <- read_csv("keywords.csv", col_types = cols(.default = col_character()), show_col_types = FALSE)
  terms <- pull(kw, term)

  message("[slickdeals] Fetching ", length(terms), " terms")

  results <- map(terms, \(t) {
    message("  → ", t)
    fetch_slickdeals(t)
  })

  combined <- bind_rows(compact(results))

  if (nrow(combined) == 0L) {
    warning("[slickdeals] No rows returned")
    return(invisible(NULL))
  }

  combined <- join_category(combined)
  written  <- append_history(combined)
  message("[slickdeals] Done. ", nrow(combined), " rows fetched → ",
          nrow(written), " unique rows in history.")
  invisible(written)
}

run_slickdeals()
