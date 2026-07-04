suppressPackageStartupMessages({
  library(httr2)
  library(jsonlite)
  library(dplyr)
  library(purrr)
  library(readr)
  library(stringr)
  library(lubridate)
})

source("R/normalize.R")

REDDIT_BASE  <- "https://www.reddit.com"
USER_AGENT   <- "warehouse-watts/0.1 (hobby price tracker)"
PRICE_RE     <- r"(\$\s?(\d{1,4}(?:\.\d{2})?))"
ON_SALE_RE   <- r"((?i)(sale|markdown|clearance|\.97|instant savings|deal))"

# ---------- price helpers ----------

extract_prices <- function(title) {
  matches <- str_match_all(title, PRICE_RE)[[1]]
  if (nrow(matches) == 0L) return(list(price = NA_real_, price_was = NA_real_))
  vals <- sort(as.double(matches[, 2]))
  if (length(vals) == 1L) list(price = vals[[1L]], price_was = NA_real_)
  else                    list(price = vals[[1L]], price_was = vals[[length(vals)]])
}

# ---------- single-term fetcher ----------

fetch_reddit <- function(term) {
  url <- paste0(
    REDDIT_BASE, "/r/Costco/search.json?",
    "q=", utils::URLencode(term, reserved = TRUE),
    "&restrict_sr=1&sort=new&t=month&limit=50"
  )

  resp <- tryCatch(
    request(url) |>
      req_headers("User-Agent" = USER_AGENT) |>
      req_error(is_error = \(r) FALSE) |>  # handle status ourselves
      req_retry(max_tries = 3, is_transient = \(r) resp_status(r) == 429L) |>
      req_throttle(rate = 1 / 2) |>
      req_perform(),
    error = function(e) {
      warning("[reddit] Request failed for '", term, "': ", conditionMessage(e))
      NULL
    }
  )

  if (is.null(resp)) return(NULL)

  status <- resp_status(resp)
  if (status == 403L || status == 429L) {
    warning("[reddit] HTTP ", status, " for '", term,
            "' — if this persists in CI, build OAuth fallback per PLAN.md Phase 2")
    return(NULL)
  }
  if (status != 200L) {
    warning("[reddit] HTTP ", status, " for '", term, "'")
    return(NULL)
  }

  raw  <- resp_body_string(resp)
  parsed <- tryCatch(fromJSON(raw, simplifyDataFrame = FALSE), error = function(e) NULL)
  if (is.null(parsed)) return(NULL)

  posts <- parsed$data$children
  if (length(posts) == 0L) return(NULL)

  map_dfr(posts, function(p) {
    d <- p$data
    prices  <- extract_prices(d$title %||% "")
    on_sale <- isTRUE(str_detect(d$title %||% "", ON_SALE_RE)) ||
               (!is.na(prices$price_was) && prices$price_was > (prices$price %||% 0))

    tibble(
      date        = Sys.Date(),
      source      = "reddit",
      title       = d$title %||% NA_character_,
      price       = prices$price,
      price_was   = prices$price_was,
      on_sale     = on_sale,
      url         = if (!is.null(d$permalink)) paste0(REDDIT_BASE, d$permalink) else NA_character_,
      keyword     = term,
      category    = NA_character_,
      signal      = as.double(d$ups %||% NA),
      in_stock    = NA,
      product_key = make_product_key(d$title %||% "")
    )
  })
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

run_reddit <- function() {
  kw    <- read_csv("keywords.csv", col_types = cols(.default = col_character()), show_col_types = FALSE)
  terms <- pull(kw, term)

  message("[reddit] Fetching ", length(terms), " terms")

  results <- map(terms, \(t) {
    message("  → ", t)
    fetch_reddit(t)
  })

  combined <- bind_rows(compact(results))

  if (nrow(combined) == 0L) {
    warning("[reddit] No rows returned")
    return(invisible(NULL))
  }

  combined <- join_category(combined)
  written  <- append_history(combined)
  message("[reddit] Done. ", nrow(combined), " rows fetched → ",
          nrow(written), " unique rows in history.")
  invisible(written)
}

run_reddit()
