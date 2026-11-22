# Functional preview — 2026-11-22

This snapshot packages the presentation-companion functional line, including the pending cue/preview, deck and tracking changes present at staging time. No lunar UI changes are included.

## Included

- PPTX notes, preview rendering and local draft workflows.
- Speaker-follow tracking, cue targeting and preview controls.
- Typed/voice question capture and optional configured online providers.
- Synthetic fixture generators and deterministic regression checks.

## Known boundaries

- macOS 15+ only for this local build; package architecture follows the build machine.
- Ad-hoc signing only: no Developer ID signature, notarization, or App Store distribution claim.
- LibreOffice and cloud providers are not redistributed and must be installed/configured separately.
- Live speech, microphone permissions, service availability and real-world deck fidelity need user acceptance on representative non-confidential inputs.
- The functional source and the lunar UI line are intentionally separate.

The upstream tag-triggered publishing workflow is archived as `docs/upstream/release-workflow.yml.example`, not active in `.github/workflows`, because it targets upstream release conventions. Publication is manual until the new repository's owner configures and reviews its release process.

Demonstration WAVs are excluded. The optional bundled-audio regression explicitly skips without them; developer sample buttons are disabled in this release. Core microphone and typed-question workflows remain available.
