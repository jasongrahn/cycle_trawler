suppressPackageStartupMessages({
  library(dplyr)
  library(readr)
  library(tidyr)
  library(lubridate)
})

HISTORY_PATH   <- "data/history.csv"
SITE_DIR       <- "data/site"
NUTRITION_PATH <- "nutrition.csv"

# ---------- helpers ----------

read_history <- function() {
  if (!file.exists(HISTORY_PATH)) {
    message("[build] No history.csv yet — writing empty site data")
    return(NULL)
  }
  df <- read_csv(HISTORY_PATH, show_col_types = FALSE,
                 col_types = cols(
                   date        = col_date(),
                   source      = col_character(),
                   product_key = col_character(),
                   title       = col_character(),
                   price       = col_double(),
                   price_was   = col_double(),
                   on_sale     = col_logical(),
                   url         = col_character(),
                   category    = col_character(),
                   keyword     = col_character(),
                   signal      = col_double(),
                   in_stock    = col_logical()
                 ))
  if (nrow(df) == 0L) NULL else df
}

write_site <- function(df, name) {
  path <- file.path(SITE_DIR, name)
  write_csv(df, path, na = "")
  message("[build] wrote ", name, " (", nrow(df), " rows)")
}

empty_on_sale     <- function() tibble(title=character(), price=double(), price_was=double(),
                                        pct_off=double(), source=character(), category=character(), url=character())
empty_buzz        <- function() tibble(title=character(), source=character(), category=character(),
                                        signal=double(), price=double(), url=character(), date=as.Date(NA_character_))
empty_new_items   <- function() tibble(title=character(), price=double(), category=character(), url=character())
empty_trends      <- function() tibble(date=as.Date(NA_character_), product_key=character(),
                                        title=character(), price=double(), category=character())
empty_deal_flags  <- function() tibble(title=character(), price=double(), median_price=double(),
                                        pct_below_median=double(), category=character(), url=character())
empty_fuel_value  <- function() tibble(title=character(), price=double(), category=character(),
                                        usd_per_100g_carbs=double(), usd_per_100g_protein=double(), url=character())

# ---------- 1. on_sale_now ----------

build_on_sale_now <- function(df) {
  if (is.null(df)) return(empty_on_sale())

  latest <- max(df$date, na.rm = TRUE)

  out <- df |>
    filter(date == latest, on_sale == TRUE, !is.na(price)) |>
    group_by(product_key) |>
    slice_max(order_by = coalesce(signal, -Inf), n = 1, with_ties = FALSE) |>
    ungroup() |>
    mutate(pct_off = if_else(!is.na(price_was) & price_was > 0,
                             round((price_was - price) / price_was * 100, 1),
                             NA_real_)) |>
    arrange(desc(coalesce(pct_off, 0))) |>
    select(title, price, price_was, pct_off, source, category, url)

  out
}

# ---------- 2. community_buzz ----------

build_community_buzz <- function(df) {
  if (is.null(df)) return(empty_buzz())

  cutoff <- Sys.Date() - 14L

  df |>
    filter(source != "rapidapi", date >= cutoff) |>
    group_by(product_key) |>
    slice_max(order_by = coalesce(signal, 0), n = 1, with_ties = FALSE) |>
    ungroup() |>
    arrange(desc(coalesce(signal, 0))) |>
    slice_head(n = 25) |>
    select(title, source, category, signal, price, url, date)
}

# ---------- 3. new_items ----------

build_new_items <- function(df) {
  if (is.null(df)) return(empty_new_items())

  rapidapi_rows <- filter(df, source == "rapidapi")
  if (nrow(rapidapi_rows) == 0L) return(empty_new_items())

  latest <- max(rapidapi_rows$date, na.rm = TRUE)

  first_seen <- rapidapi_rows |>
    group_by(product_key) |>
    summarise(first_date = min(date), .groups = "drop")

  rapidapi_rows |>
    filter(date == latest) |>
    left_join(first_seen, by = "product_key") |>
    filter(first_date == latest) |>
    select(title, price, category, url)
}

# ---------- 4. price_trends ----------

build_price_trends <- function(df) {
  if (is.null(df)) return(empty_trends())

  rapidapi_rows <- filter(df, source == "rapidapi", !is.na(price))
  if (nrow(rapidapi_rows) == 0L) return(empty_trends())

  eligible <- rapidapi_rows |>
    group_by(product_key) |>
    summarise(n_dates = n_distinct(date), .groups = "drop") |>
    filter(n_dates >= 3) |>
    pull(product_key)

  if (length(eligible) == 0L) return(empty_trends())

  rapidapi_rows |>
    filter(product_key %in% eligible) |>
    group_by(date, product_key) |>
    slice_min(order_by = price, n = 1, with_ties = FALSE) |>
    ungroup() |>
    select(date, product_key, title, price, category)
}

# ---------- 5. deal_flags ----------

build_deal_flags <- function(df) {
  if (is.null(df)) return(empty_deal_flags())

  rapidapi_rows <- filter(df, source == "rapidapi", !is.na(price))
  if (nrow(rapidapi_rows) == 0L) return(empty_deal_flags())

  latest <- max(rapidapi_rows$date, na.rm = TRUE)

  eligible <- rapidapi_rows |>
    group_by(product_key) |>
    summarise(n_obs = n(), .groups = "drop") |>
    filter(n_obs >= 4) |>
    pull(product_key)

  if (length(eligible) == 0L) return(empty_deal_flags())

  stats <- rapidapi_rows |>
    filter(product_key %in% eligible) |>
    group_by(product_key) |>
    summarise(median_price = median(price, na.rm = TRUE), .groups = "drop")

  rapidapi_rows |>
    filter(product_key %in% eligible, date == latest) |>
    left_join(stats, by = "product_key") |>
    filter(price < 0.85 * median_price) |>
    mutate(pct_below_median = round((median_price - price) / median_price * 100, 1)) |>
    arrange(desc(pct_below_median)) |>
    select(title, price, median_price, pct_below_median, category, url)
}

# ---------- 6. fuel_value ----------

build_fuel_value <- function(df) {
  if (is.null(df)) return(empty_fuel_value())

  nutrition <- tryCatch(
    read_csv(NUTRITION_PATH, show_col_types = FALSE,
             col_types = cols(
               product_key          = col_character(),
               label                = col_character(),
               carbs_g_serving      = col_double(),
               protein_g_serving    = col_double(),
               servings_per_container = col_double()
             )),
    error = function(e) {
      warning("[build] Could not read nutrition.csv: ", conditionMessage(e))
      NULL
    }
  )

  if (is.null(nutrition) || nrow(nutrition) == 0L) return(empty_fuel_value())

  latest_prices <- df |>
    filter(!is.na(price)) |>
    group_by(product_key) |>
    slice_max(order_by = date, n = 1, with_ties = FALSE) |>
    ungroup() |>
    select(product_key, price, category, url)

  nutrition |>
    inner_join(latest_prices, by = "product_key") |>
    mutate(
      usd_per_100g_carbs   = if_else(
        carbs_g_serving * servings_per_container > 0,
        round(price / (carbs_g_serving * servings_per_container) * 100, 2),
        NA_real_
      ),
      usd_per_100g_protein = if_else(
        protein_g_serving * servings_per_container > 0,
        round(price / (protein_g_serving * servings_per_container) * 100, 2),
        NA_real_
      )
    ) |>
    filter(!is.na(usd_per_100g_carbs) | !is.na(usd_per_100g_protein)) |>
    arrange(coalesce(usd_per_100g_carbs, Inf)) |>
    select(title = label, price, category, usd_per_100g_carbs, usd_per_100g_protein, url)
}

# ---------- main ----------

build_site_data <- function() {
  df <- read_history()

  write_site(build_on_sale_now(df),   "on_sale_now.csv")
  write_site(build_community_buzz(df), "community_buzz.csv")
  write_site(build_new_items(df),     "new_items.csv")
  write_site(build_price_trends(df),  "price_trends.csv")
  write_site(build_deal_flags(df),    "deal_flags.csv")
  write_site(build_fuel_value(df),    "fuel_value.csv")

  message("[build] All site data written.")
}

build_site_data()
