# Changelog

All notable changes to this project will be documented in this file.

## [4.2.0] - 2026-03-24

### Added
- `install.bat`: dynamically resolve WSL `$HOME` via `wsl -e bash -c "echo $HOME"` so instructions work on any username/PC
- `shutsujin_departure.sh`: `csst` alias now uses `$HOME/multi-agent-shogun` instead of hardcoded path

### Changed
- `install.bat`: repository reference updated from `feature-shogun` to `multi-agent-shogun`
- `config/settings.yaml`: `skills/logs/images` paths changed to relative `./` paths for portability
- `scripts/backup_daily.sh`: cron example uses `$HOME`-based path
- Regenerated `AGENTS.md` and `copilot-instructions.md` (bloom_routing_rule + Post-Compaction Recovery section)

### Fixed
- `inbox_write.sh`: removed `xxd` dependency (CI compatibility)
- `tests/unit/test_idle_flag.bats`: updated T-008 to match v4.0.1 idle flag design (preserve not delete)
