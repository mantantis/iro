# Changelog

All notable changes to iro are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and iro uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Local history of earlier file versions: the last 20 per file, Alt+R brings one back.
- A file already open in another iro opens read-only and names that iro's PID.

### Changed
- Saving keeps owner, group, ACLs and hard links intact.
- iro only wakes up when there is work to do.

### Security
- The config sandbox no longer offers `print` and `string.dump`.
