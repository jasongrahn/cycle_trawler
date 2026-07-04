# Warehouse Watts

Costco deals tracker for cyclists — fuel, hydration, recovery, and gear.

**Live site:** https://jasongrahn.github.io/cycle_trawler/

---

## What it does

Runs weekly (Monday noon UTC) and pulls Costco product data from two sources:

- **RapidAPI "Real-Time Costco Data"** — catalog prices, on-sale flags, stock status for 12 core cycling keywords
- **Slickdeals RSS** — community-reported deals across all 28 keywords

Renders a static site with five sections:

| Section | What you see |
|---|---|
| 🔥 On Sale Now | Products currently marked down, sorted by % off |
| 🗣️ Community Buzz | Hottest community-reported deals from the last 14 days |
| 🆕 New at Costco | Products appearing for the first time in this week's fetch |
| 📈 Price Trends | Price history charts by category (populates after ~3 weeks of data) |
| 🏆 Fuel Value Leaderboard | $/100g carbs and protein ranked cheapest first |

## Stack

- R + Quarto — data fetching, processing, site rendering
- GitHub Actions — weekly cron + manual dispatch
- GitHub Pages — static hosting
- `data/history.csv` in git — append-only price history (no database)

## Repo layout

```
R/
├── fetch_rapidapi.R    # Adapter A: RapidAPI catalog
├── fetch_reddit.R      # Adapter B1: Reddit r/Costco (unauthenticated)
├── fetch_slickdeals.R  # Adapter B2: Slickdeals RSS
├── normalize.R         # Common schema + append_history()
└── build_site_data.R   # Aggregates history → data/site/ CSVs
data/
├── raw/                # Raw JSON responses (one file per term per run)
├── site/               # Small CSVs read by index.qmd
├── history.csv         # Append-only price history spine
└── quota_rapidapi.csv  # Monthly API call counter
index.qmd               # Site
keywords.csv            # Search terms with tier + category
nutrition.csv           # Manual nutrition data for fuel leaderboard
```

## Running locally

```r
# fetch data (requires RAPIDAPI_KEY in .Renviron)
Rscript R/fetch_rapidapi.R
Rscript R/fetch_slickdeals.R

# build site CSVs
Rscript R/build_site_data.R

# preview
quarto preview index.qmd
```

## Setup

1. Copy `.Renviron.example` to `.Renviron` and add your `RAPIDAPI_KEY`
2. Add `RAPIDAPI_KEY` as a GitHub Actions secret
3. Repo Settings → Pages → Source: **GitHub Actions**
4. Actions tab → `weekly-update` → **Run workflow**

## Disclaimer

Not affiliated with Costco. Hobby project. Data may be wrong.
