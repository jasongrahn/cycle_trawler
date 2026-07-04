suppressPackageStartupMessages({
  library(dplyr)
  library(readr)
  library(digest)
  library(stringr)
})

HISTORY_PATH <- "data/history.csv"

HISTORY_COLS <- list(
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
)

make_product_key <- function(title, upc = NA) {
  ifelse(
    !is.na(upc) & nchar(as.character(upc)) > 0,
    as.character(upc),
    digest(tolower(str_squish(title)), algo = "xxhash32")
  )
}

append_history <- function(df) {
  col_names <- names(HISTORY_COLS)

  # coerce incoming df to match schema
  for (col in col_names) {
    if (!col %in% names(df)) df[[col]] <- NA
  }
  df <- df[col_names]

  if (file.exists(HISTORY_PATH)) {
    existing <- read_csv(HISTORY_PATH, col_types = do.call(cols, HISTORY_COLS), show_col_types = FALSE)
  } else {
    existing <- read_csv(I(paste(col_names, collapse = ",")), col_types = do.call(cols, HISTORY_COLS), show_col_types = FALSE)
  }

  combined <- bind_rows(existing, df) |>
    group_by(date, source, product_key) |>
    slice_tail(n = 1) |>
    ungroup() |>
    arrange(date, source, product_key)

  write_csv(combined, HISTORY_PATH, na = "")
  invisible(combined)
}
