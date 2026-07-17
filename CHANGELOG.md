# Changelog

All notable changes to donts3p are documented here.

## [1.1.0] - 2026-07-17

### Added

- Experimental Labs system sleep override with explicit macOS administrator authentication.
- Exact restoration of the previously recorded Battery, AC, and UPS `disablesleep` values.
- Recovery safeguards for failed, partial, or interrupted override operations.
- Emergency system sleep restoration script and uninstall protection while restoration is pending.
- Lightweight protection status dashboard in the menu-bar menu.

### Changed

- Replaced one-second status-icon polling with event-driven observation updates.
- Cached active and inactive status icons instead of redrawing them repeatedly.
- Reduced idle CPU usage to effectively zero in local sampling.
- Expanded documentation for closed-lid limitations, Labs risks, and restoration behavior.

### Notes

- Labs remains off by default and does not alter normal installation or operation unless explicitly enabled.
- The Labs override is persistent system-wide state and does not guarantee closed-lid operation.
- The supported target remains Apple Silicon with macOS 14 or later.

## [1.0.0] - 2026-07-17

- Initial public release of the native macOS menu-bar app.
- IOKit-based user-idle system sleep prevention with display sleep still allowed.
- Login recovery, status indication, ad-hoc packaging, and safe uninstall support.

[1.1.0]: https://github.com/jaymunsh/donts3p/releases/tag/v1.1.0
[1.0.0]: https://github.com/jaymunsh/donts3p/releases/tag/v1.0.0
