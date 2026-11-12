# ViePN Lottery Analytics (Swift-only V1.1)
iOS 17+ native SwiftUI app, SQLite storage, CSV import, HTTPS JSON sync, historical frequency dashboard. No Python dependency.

## Build IPA
The GitHub Actions workflow `Build unsigned iOS IPA` builds an **unsigned** IPA on a macOS runner. It requires separate signing before installation.

## Data
Five-year target window begins 2021-11-12. The app **does not yet contain verified five-year results**, and no source of results is embedded. It displays statistics only for imported data.

CSV columns: `date,region,station,prize,position,number,source`. Regions: MB, MT, MN. Position is 1-based. Keep zero-padded winning numbers as text. A JSON sync endpoint must use HTTPS and return `{"schema_version":1,"results":[...]}`.

Historical statistics do not predict independently drawn future lottery results.

## Historical archive synchronization (Swift native)

Tap **Đồng bộ lịch sử tự động (2021–nay)** inside the iOS app. It downloads completed-quarter SQLite archives directly over HTTPS from [itgi8vn/api-kqxs-archives-quarterly](https://github.com/itgi8vn/api-kqxs-archives-quarterly), imports draw results into on-device SQLite, and remembers completed quarters so subsequent imports only fetch missing quarters. The start date is 2021-11-12.

**Important:** Historical archives contain only completed quarters. Results for the current quarter are NOT supplied by this archive. This integration has been built and CI-compiled, but full archive coverage, source licensing, data integrity and schema/runtime compatibility need field verification on an actual device. Partial datasets must not be represented as complete. The manual CSV and custom HTTPS JSON import paths remain available.

Archive attribution: https://github.com/itgi8vn/api-kqxs-archives-quarterly . Review upstream terms before commercial distribution.
