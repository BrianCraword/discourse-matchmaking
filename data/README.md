# ZIP Code Reference Data

The matchmaking plugin uses a US ZIP code → latitude/longitude reference table for distance-based location matching.

## Quick Setup (simplemaps — recommended)

1. Go to https://simplemaps.com/data/us-zips
2. Download the **Basic (free)** CSV — the file is called `uszips.csv`
3. Place it in this directory: `data/uszips.csv` (in the plugin repo root)
4. Rebuild Discourse — the seed job runs automatically on first boot and loads ~33K rows

That's it. No renaming or reformatting needed — the seed job reads simplemaps column names (`zip`, `lat`, `lng`, `city`, `state_id`) natively.

**License requirement**: The simplemaps Basic (free) license requires a visible backlink to https://simplemaps.com/data/us-zips from a public page on your site. A footer link on an "about" or "credits" page works.

## Alternative: US Census Bureau Gazetteer (public domain)

If you prefer zero attribution requirements, use the Census Bureau's ZCTA Gazetteer file:

1. Download from: https://www2.census.gov/geo/docs/maps-data/data/gazetteer/2023_Gazetteer/
2. Get the ZCTA national file, unzip it
3. Convert to CSV with headers `zip_code,latitude,longitude,city,state_abbr`
4. Place as `data/us_zip_codes.csv`

Note: The Census file does not include city/state names per ZIP code. The simplemaps file is easier to work with.

## How it works

On first boot after rebuild (when `matchmaking_enabled` is true and the `zip_code_locations` table is empty), a background Sidekiq job reads the CSV and bulk-inserts rows into the `zip_code_locations` database table.

When two users both have valid US ZIP codes, the scoring engine calculates Haversine distance (great-circle miles) and converts it to a compatibility score:

| Distance | Score |
|----------|-------|
| ≤10 mi   | 1.0   |
| ≤25 mi   | 0.9   |
| ≤50 mi   | 0.8   |
| ≤100 mi  | 0.65  |
| ≤200 mi  | 0.5   |
| ≤500 mi  | 0.35  |
| ≤1000 mi | 0.2   |
| 1000+ mi | 0.1   |

These scores are further adjusted by each user's location flexibility setting.

## Fallback behavior

If the CSV is missing, the table is empty, or either user doesn't have a ZIP code, the plugin falls back to string-based location matching (same city → same state → same country) with flexibility modifiers. Everything still works — just without mile-based precision.

## Data size

~33,000 rows, approximately 1.5 MB as CSV, ~2 MB in the database.
