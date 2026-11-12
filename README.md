# ViePN Lottery Analytics (Swift-only V1.1)
iOS 17+ native SwiftUI app, SQLite storage, CSV import, HTTPS JSON sync, historical frequency dashboard. No Python dependency.

## Build IPA
The GitHub Actions workflow `Build unsigned iOS IPA` builds an **unsigned** IPA on a macOS runner. It requires separate signing before installation.

## Data
Five-year target window begins 2021-11-12. The app **does not yet contain verified five-year results**, and no source of results is embedded. It displays statistics only for imported data.

CSV columns: `date,region,station,prize,position,number,source`. Regions: MB, MT, MN. Position is 1-based. Keep zero-padded winning numbers as text. A JSON sync endpoint must use HTTPS and return `{"schema_version":1,"results":[...]}`.

Historical statistics do not predict independently drawn future lottery results.
