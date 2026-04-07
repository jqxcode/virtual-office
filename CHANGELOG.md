# Changelog

## [Unreleased]

### Added
- **TEAM tab (V2)**: Agent directory showing identity, description, skills (jobs) with click-to-copy, schedules in human-readable format, draggable cards
- **OFFICE tab (V2)**: Spatial "live office floor" view with agent desk grid, working/idle/sleeping states, live elapsed timer for active jobs, queue display, and ambient live feed (last 5 events)
- **HISTORY tab (V2)**: Job health summary cards (success rate per job, color-coded), sortable run history table with agent/job/result/time filters, inline report links, pagination (20/page)
- **SCHEDULE tab (V2)**: Upcoming schedule with agent filter, last-result column, next-24h highlighting, pagination
- V2 tabs coexist with V1 for side-by-side comparison (V1 retirement planned for future release)

### Changed
- Replaced old Agents V2 and Job Schedules V2 stub tabs with first-principles redesign (TEAM, OFFICE, HISTORY, SCHEDULE)
- Navigation: 7 tabs total (3 V1 legacy + 4 V2)

### Design Decisions
- Added D12-D18 covering V2 tab architecture, spatial office view, and filter model

## [0.1.0] - 2026-03-15
### Added
- Initial project structure
- Generic agent job runner with lock, queue, and drain
- Windows Task Scheduler integration
- Audit log system (append-only, monthly partitioned)
- Live dashboard UI with agent status cards
- Scrum Master agent configuration (sprint-progress job)
- Test suite for all core components
