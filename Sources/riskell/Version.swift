/// The one version number of riskell. `VERSION` at the repository root is the source; `scripts/version-check.sh` fails when this, `VERSION` and the
/// top released heading of CHANGELOG.md disagree, and `scripts/release` refuses to tag until they agree.
enum Build { static let version = "0.3.1" }
