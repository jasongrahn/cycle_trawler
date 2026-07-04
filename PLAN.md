# PLAN.md — Warehouse Watts: Costco deals tracker for cyclists

Static site. GitHub Pages. R + Quarto. Weekly GitHub Action.
Two data adapters. Same output schema. Site renders whatever data exists.

- Adapter A = RapidAPI "Real-Time Costco Data" (catalog: systematic prices)
- Adapter B = Free community sources (Reddit r/Costco + Slickdeals RSS: deal buzz)

Build BOTH. They feed different site sections. Decision criteria in §8 says when to drop one.

RULES FOR EXECUTOR (Claude Code):
- Work phase by phase. Do not skip acceptance checks.
- Small commits. One phase = one or more commits.
- Never print or commit API keys. Never hardcode keys.
- If an external endpoint differs from this doc, trust the live endpoint. Update this doc.
- Fail-soft everywhere: fetch error → warn, keep old data, site still renders.
- R style: tidyverse. No loops where purrr works. Comment sparsely.

---

## §1 STACK

- R >= 4.3. Packages: httr2, jsonlite, dplyr, purrr, tidyr, stringr, readr,
  lubridate, ggplot2, gt, tidyRSS, xml2, glue, digest.
- renv for lockfile. Quarto for site. GitHub Actions for cron. GitHub Pages for hosting.
- No database. `data/history.csv` in git IS the database. Append-only.

## §2 REPO LAYOUT

```
cycle_trawler/           # GitHub repo: jasongrahn/cycle_trawler. Brand name: "Warehouse Watts"
├── PLAN.md
├── keywords.csv          # §5. term, tier(core|extended), category
├── nutrition.csv         # §6. manual. product_key, label, carbs_g_serving, protein_g_serving, servings_per_container
├── R/
│   ├── fetch_rapidapi.R  # Adapter A
│   ├── fetch_reddit.R    # Adapter B1
│   ├── fetch_slickdeals.R# Adapter B2
│   ├── normalize.R       # all adapters → common schema, append history
│   └── build_site_data.R # deal scores, trends, value metrics → data/site/*.csv
├── data/
│   ├── raw/              # YYYY-MM-DD_<source>.json  (keep, cheap, debuggable)
│   ├── history.csv       # the spine. append-only
│   └── site/             # small csvs the qmd reads
├── index.qmd
├── _quarto.yml
├── .Renviron.example     # template. real .Renviron is gitignored
├── .gitignore            # MUST contain: .Renviron, .Rhistory, /.quarto/, /_site/
└── .github/workflows/update.yml
```

## §3 COMMON SCHEMA (every adapter outputs this)

One row per product-sighting. Columns:

| col | type | note |
|---|---|---|
| date | date | run date |
| source | chr | "rapidapi" \| "reddit" \| "slickdeals" |
| product_key | chr | UPC if known, else `tolower(str_squish(title))` hashed w/ digest. stable join key |
| title | chr | product name / post title |
| price | dbl | current price. NA ok for reddit if unparseable |
| price_was | dbl | pre-discount price. NA ok |
| on_sale | lgl | TRUE if badge/markdown/price_was>price |
| url | chr | link to product or post |
| category | chr | joined from keywords.csv |
| keyword | chr | search term that found it |
| signal | dbl | upvotes (reddit), NA otherwise |
| in_stock | lgl | NA if unknown |

`normalize.R` exports `append_history(df)`: bind df to existing history.csv, dedupe on
(date, source, product_key) keeping the LAST occurrence (so a same-day re-run overwrites
with fresh values, not stale), write back. Built in Phase 0.5. `product_key` uses
`digest::digest(tolower(str_squish(title)), algo="xxhash32")` when no UPC.

## §4 SECRETS — HOW THEY WORK (read this, human, then do the clicks)

Concept: a secret = named value GitHub stores encrypted. Workflow reads it as env var.
Code reads env var. Value never appears in code, logs, or git history.

IMPORTANT CLARIFICATION: your RapidAPI "Application ID" is NOT the key you need.
RapidAPI gives every app an **X-RapidAPI-Key** (long string). That is the secret.
Also: the key does nothing until you SUBSCRIBE the app to this API's plan.

Human steps (one time, ~5 min):
1. rapidapi.com → log in (your GitHub auth) → open "Real-Time Costco Data" API page.
2. Pricing tab → subscribe to BASIC (free) plan. Note the monthly request quota. Write it in §8 table.
3. Endpoints tab → any endpoint → right panel shows `X-RapidAPI-Key`. Copy it.
4. GitHub repo → Settings → Secrets and variables → Actions → "New repository secret".
   - Name: `RAPIDAPI_KEY`  Value: paste key. Save.
5. Local dev: copy `.Renviron.example` to `.Renviron` in repo root, fill in
   `RAPIDAPI_KEY=paste-key-here`. Restart R session. Confirm `.Renviron` is gitignored BEFORE first commit.

Code side (executor):
- R: `key <- Sys.getenv("RAPIDAPI_KEY"); if (key == "") stop("no key")`
- Workflow: pass through with `env: RAPIDAPI_KEY: ${{ secrets.RAPIDAPI_KEY }}`
- Same pattern later for optional `REDDIT_CLIENT_ID` / `REDDIT_CLIENT_SECRET` (§Phase 2 fallback).

## §5 keywords.csv SEED

Header: `term,tier,category`

Core tier (Adapter A spends quota ONLY on these — 12 terms):
electrolyte powder,core,hydration
liquid iv,core,hydration
protein powder,core,recovery
energy bar,core,fuel
clif bar,core,fuel
fig bar,core,fuel
energy chews,core,fuel
dates,core,fuel
peanut butter,core,fuel
sunscreen,core,body
creatine,core,recovery
coconut water,core,hydration

Extended tier (free sources only — add these):
gummy,extended,fuel
applesauce pouch,extended,fuel
fruit snacks,extended,fuel
stroopwafel,extended,fuel
tart cherry,extended,recovery
chocolate milk,extended,recovery
greek yogurt,extended,recovery
compression socks,extended,gear
wool socks,extended,gear
sunglasses,extended,gear
massage gun,extended,gear
foam roller,extended,gear
bike,extended,gear
helmet,extended,gear
garmin,extended,gear
lmnt,extended,hydration

## §6 nutrition.csv

Manual file. Human fills top ~30 recurring fuel/hydration/recovery items over time.
Header: `product_key,label,carbs_g_serving,protein_g_serving,servings_per_container`
Start with 5 rows of known Costco staples (executor: leave placeholder rows, human fills).
Used only by value-leaderboard. Missing rows = item just skips leaderboard. Fail-soft.

---

## PHASE 0 — Scaffold (local, in Positron)

Tasks:
1. Repo already exists (jasongrahn/cycle_trawler, one commit). Create layout per §2 inside it.
   Write/verify .gitignore FIRST (before any commit that could touch secrets).
2. `renv::init()`. Install packages §1 (incl. `digest`). `renv::snapshot()`.
3. Write keywords.csv (§5), nutrition.csv header + placeholders (§6), .Renviron.example.
4. Minimal `_quarto.yml` (project type website, output-dir `_site`, simple theme e.g. `flatly`).
   Project Pages serve from `/cycle_trawler/` — set `site-url: https://jasongrahn.github.io/cycle_trawler/`
   so resource/asset links resolve. (Test after Phase 4; a wrong base path = 404 CSS/JS on live site.)
5. Minimal index.qmd: title, "no data yet" placeholder. `quarto render` works.

Accept: `quarto render` exits 0. `git status` shows no .Renviron. Commit.

## PHASE 0.5 — normalize.R (the spine)

File: `R/normalize.R`. Every adapter depends on this, so build it before any fetcher.

1. Export `append_history(df)` per §3: bind `df` to existing `data/history.csv` (create if
   absent), dedupe on (date, source, product_key) keeping the LAST occurrence, write back.
   Enforce the §3 column set/order so all adapters share one shape.
2. Export a `make_product_key(title, upc = NA)` helper: UPC when known, else
   `digest::digest(tolower(str_squish(title)), algo="xxhash32")`.
3. Fetchers `source()` this file; do not duplicate the logic.

Accept: sourcing normalize.R + calling `append_history()` twice on the same rows leaves
history.csv unchanged (dedupe works, last-write-wins). Commit.

## PHASE 1 — Adapter A: RapidAPI

File: `R/fetch_rapidapi.R`

1. Host: `real-time-costco-data.p.rapidapi.com`. VERIFY exact endpoint path + params on the
   API's Endpoints tab (likely a product-search endpoint taking `query`; there may be region
   param — use US). Update this doc with the real path.
2. Function `fetch_costco(term)`:
   - httr2: `request() |> req_headers("X-RapidAPI-Key"=key, "X-RapidAPI-Host"=host) |> req_url_query(query=term)`
   - `req_retry(max_tries=3)`, `req_throttle(rate=1/2)` (1 call per 2 sec. be polite.)
   - Save raw JSON to `data/raw/{Sys.Date()}_rapidapi_{term}.json`.
   - Parse → schema §3. Map fields: look for price, original/list price, on-sale flag,
     item id/UPC, product url, stock. Field names unknown until first real response —
     inspect raw JSON, then write parser. Do not guess silently.
3. Function `run_rapidapi()`: read keywords.csv, filter tier=="core", map fetch_costco,
   bind, `append_history()`. `source("R/normalize.R")` at top. Call `run_rapidapi()` at the
   BOTTOM of the file so `Rscript R/fetch_rapidapi.R` actually runs it (CI invokes it that way).
4. QUOTA GUARD: maintain `data/quota_rapidapi.csv` (month, calls). Before run: if
   calls this month + length(core terms) > QUOTA_CAP (set from §4 step 2; default 75),
   skip run, message loudly, exit 0 (not error — fail-soft).

Accept: local run with real key fetches ≥3 terms, history.csv gains rows with non-NA
prices, quota file increments, no key in any committed file. Commit.

## PHASE 2 — Adapter B: free sources

File: `R/fetch_reddit.R`
1. URL: `https://www.reddit.com/r/Costco/search.json?q={URLencode(term)}&restrict_sr=1&sort=new&t=month&limit=50`
2. MUST send custom User-Agent: `"warehouse-watts/0.1 (hobby price tracker)"`. Reddit 403s default UAs.
3. Parse posts: title, permalink (prefix https://www.reddit.com), ups → signal, created_utc.
4. Price regex from title: `\$\s?(\d{1,4}(?:\.\d{2})?)`. First match → price. NA fine.
   `price_was`: if two prices in title, larger = was, smaller = price. on_sale = TRUE if
   title matches regex `(?i)(sale|markdown|clearance|\.97|instant savings|deal)` or price_was set.
5. Loop ALL keywords (core + extended). Throttle 1 req / 2 sec.
6. KNOWN RISK: Reddit rate-limits/blocks datacenter IPs (GitHub Actions runners).
   If runs start returning 403/429 in CI: fallback = create free Reddit "script" app
   (reddit.com/prefs/apps) → gives client id + secret → add as repo secrets
   REDDIT_CLIENT_ID / REDDIT_CLIENT_SECRET → OAuth token via httr2
   (POST https://www.reddit.com/api/v1/access_token, grant_type=client_credentials,
   basic auth = id:secret) → call oauth.reddit.com instead of www. Do NOT build this
   preemptively. Build only when unauthenticated fails in CI.

File: `R/fetch_slickdeals.R`
1. Slickdeals exposes RSS. Candidate: `https://slickdeals.net/newsearch.php?q={term}+costco&searchin=first&rss=1`.
   VERIFY: fetch once, check it's valid RSS (xml2::read_xml succeeds, has <item>). If URL
   pattern wrong, find working RSS pattern from slickdeals RSS docs page. Update this doc.
2. tidyRSS::tidyfeed(url). Keep items whose title contains "costco" (case-insens).
3. Same price regex as reddit. source="slickdeals". signal=NA.
4. Throttle 1 req / 2 sec. Loop all keywords.

Both files: `source("R/normalize.R")` at top, and call the top-level `run_*()` at the BOTTOM
so `Rscript R/fetch_reddit.R` / `Rscript R/fetch_slickdeals.R` execute when CI invokes them.

Accept: local run produces reddit + slickdeals rows in history.csv with urls that open. Commit.

## PHASE 3 — Build site data

File: `R/build_site_data.R`. Reads history.csv. Writes small csvs to data/site/:

1. `on_sale_now.csv`: latest date, on_sale==TRUE, dedupe product_key keep max-signal row,
   cols: title, price, price_was, pct_off, source, category, url. Sort pct_off desc.
2. `community_buzz.csv`: source!="rapidapi", last 14 days, sort signal desc, top 25.
3. `new_items.csv`: product_keys whose first-ever date == latest run date. rapidapi source only.
4. `price_trends.csv`: rapidapi rows, product_keys with ≥3 distinct dates, cols for ggplot.
5. `deal_flags.csv`: rapidapi rows where latest price < 0.85 * trailing median(price) for
   that product_key. Needs ≥4 observations. Empty until ~week 5 — that is fine. Fail-soft.
6. `fuel_value.csv`: join nutrition.csv on product_key. usd_per_100g_carbs =
   price / (carbs_g_serving * servings_per_container) * 100. Same for protein. Sort asc.

Accept: all 6 csvs written (empty allowed), no errors on partial data. Commit.

## PHASE 4 — Site

`index.qmd`. Sections in order. Each section: read csv, if 0 rows show "Nothing yet — check back Monday." else render.

1. 🔥 On Sale Now — gt table. Green pct_off. Link titles.
2. 🗣️ Community Buzz — gt table w/ upvote count. Note: "prices community-reported, verify in store."
3. 🆕 New at Costco — gt table.
4. 📈 Price Trends — ggplot: line per product, facet_wrap(~category, scales="free_y"),
   theme_minimal, date x-axis. Only render if ≥2 dates in data.
5. 🏆 Fuel Value Leaderboard — gt table, $/100g carbs. Footnote: manual nutrition data.
6. Footer: "Not affiliated with Costco. Hobby project. Data may be wrong. Last updated {date}."

Style: one .qmd. No custom JS. Mobile-first (people read this in the parking lot).

Accept: `quarto render` exits 0 with real data AND with empty data/site/. Commit.

## PHASE 5 — CI + deploy

File: `.github/workflows/update.yml`

```yaml
name: weekly-update
on:
  schedule:
    - cron: "0 12 * * 1"
  workflow_dispatch:
permissions:
  contents: write
  pages: write
  id-token: write
concurrency:
  group: pages
  cancel-in-progress: false
jobs:
  update:
    runs-on: ubuntu-latest
    env:
      RAPIDAPI_KEY: ${{ secrets.RAPIDAPI_KEY }}
    steps:
      - uses: actions/checkout@v4
      - uses: r-lib/actions/setup-r@v2
        with: { use-public-rspm: true }
      - uses: r-lib/actions/setup-renv@v2
      - uses: quarto-dev/quarto-actions/setup@v2
      - run: Rscript R/fetch_rapidapi.R
        continue-on-error: true          # fail-soft: one bad source ≠ dead site
      - run: Rscript R/fetch_reddit.R
        continue-on-error: true
      - run: Rscript R/fetch_slickdeals.R
        continue-on-error: true
      - run: Rscript R/build_site_data.R
      - name: commit data
        run: |
          git config user.name "ww-bot"
          git config user.email "bot@users.noreply.github.com"
          git add data/
          git diff --cached --quiet || git commit -m "data: weekly update [skip ci]"
          git push
      - run: quarto render
      - uses: actions/upload-pages-artifact@v3
        with: { path: _site }
  deploy:
    needs: update
    runs-on: ubuntu-latest
    environment:
      name: github-pages
      url: ${{ steps.deployment.outputs.page_url }}
    steps:
      - id: deployment
        uses: actions/deploy-pages@v4
```

Human steps:
1. Push repo to GitHub (public repo = free Pages + free Actions minutes).
2. Repo Settings → Pages → Source: "GitHub Actions".
3. Add RAPIDAPI_KEY secret (§4).
4. Actions tab → weekly-update → "Run workflow" (this is your manual once-a-week button).

Notes for executor:
- `[skip ci]` in data commit prevents push→workflow→push loops.
- `permissions: contents: write` required or the data commit 403s.
- Cron is UTC and best-effort; Monday noon UTC = fine.

Accept: manual dispatch run goes green end-to-end, site live at
`https://jasongrahn.github.io/cycle_trawler/`, history.csv grew in repo. Tag v0.1.

## PHASE 6 — Evaluate (after 3 weekly runs)

Fill this table, then apply §8.

| metric | Adapter A (rapidapi) | Adapter B (free) |
|---|---|---|
| rows/run | ? | ? |
| % rows w/ valid price | ? | ? |
| CI failures in 3 runs | ? | ? |
| monthly quota used vs cap | ? | n/a |
| found a deal B missed / A missed | ? | ? |

## §8 DECISION CRITERIA

- KEEP BOTH (default) if: A stays inside free quota AND B failure rate < 1/3 runs.
  They answer different questions. A = trends + value math. B = hot deals + new sightings.
- DROP A if: free quota < ~50 req/month effective, or provider starts erroring, or paid
  tier required. Site loses trend charts + leaderboard; keeps buzz sections. Still good.
- DROP B if: Reddit blocks CI even after OAuth fallback AND slickdeals RSS dies.
  Site loses buzz; keeps catalog. Still good.
- SPEND MONEY (~$10-25/mo RapidAPI tier) only if: you check the site weekly for 2 months
  straight AND quota is the only thing limiting it. Otherwise no.

## §9 GUARDRAILS (executor enforce always)

- No secrets in code/commits/logs. `.Renviron` gitignored.
- Every fetcher: throttle ≥2 s between calls, retry ≤3, custom User-Agent.
- Quota guard before every rapidapi run.
- Site must render from empty data. Test this.
- history.csv append-only. Never rewrite past rows.
- Repo/site name avoids "Costco" (trademark). Footer disclaimer stays.
- If anything ambiguous: stop, ask human. Do not invent endpoints.
