# License, in plain English

riskell is under the [Functional Source License 1.1, MIT Future License](LICENSE) (`FSL-1.1-MIT`). The canonical text in `LICENSE` is
what governs; this page only says what it means in practice, and it is not legal advice.

The short version: **use it for anything except shipping a product that replaces it.** Every release becomes MIT two years after it
ships, irrevocably.

## Table

| What you want to do | Allowed |
|---|---|
| Install it, use it, rice it | Yes |
| Use it on a work laptop, at a company, in a business | Yes — "internal use and access" is a permitted purpose by name |
| Read the source, fork it, modify it, keep the fork private | Yes |
| Publish your own fork, patch or rice as source | Yes, with the license text and copyright notices kept |
| Write an extension, theme, pill or preset | Yes, and it stays under **your** license — this license does not reach your repository |
| Sell your extension, theme or preset | Yes |
| Charge someone to set up or support riskell | Yes, that is professional services on top of a permitted use |
| Ship a commercial product that does the same job as riskell (a paid bar, a reskin you sell, a hosted substitute) | **No** — that is a Competing Use; ask for a commercial license |
| White-label it into a product you ship under another name | **No**, without a commercial license and a different name |
| Make money from riskell itself (paid builds, presets, OEM, priority support) | Yes — the Competing Use clause binds licensees, not the author |

The Competing Use clause is deliberately narrow: it stops someone taking this code, changing the colours and selling it. It does not
stop you earning from your own work on top of riskell.

## Two years, then MIT

The license grants an additional, irrevocable MIT license effective on the **second anniversary** of each release. So:

- the next release, `0.2.0`, is `FSL-1.1-MIT`;
- the same code is `MIT` from 2028-11-18, with no action needed from anyone;
- if this project is abandoned, everything published is MIT within two years.

Nothing here is permanently locked up, and no release can be recalled.

## What the license does not cover

- **The name.** Trademark rights are not granted. A fork that changes the software must rename it and must not imply it is official or
  endorsed. The `riskell.` prefix in the extension registry is reserved for first-party listings.
- **RiskellKit** ([riskell-kit](https://github.com/rish139/riskell-kit)) is **Apache-2.0**, unchanged. So are `Sources/riskell-ext/`,
  `schemas/` and `Examples/` in this repository — the parts an extension author needs. That asymmetry is deliberate: the shell is
  restricted for two years, the toolkit and the widgets are free.
- **Extensions** are never covered by this license. They live in their own repositories under whatever license their authors choose,
  commercial and proprietary included.
- **Colour schemes** keep their own upstream licenses; see [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).

## Why this license

Two other shapes were considered:

- **PolyForm Noncommercial** (what `0.1.x` used) also blocks commercial *use*, which rules out work laptops and companies. That costs
  adoption and protects nothing extra: the thing worth preventing is resale, not employment.
- **GPL-3.0 with a CLA** allows commercial use but cannot stop a paid fork, because anyone may sell GPL software.

`FSL-1.1-MIT` blocks resale, allows work use, and ends in MIT. The cost is that it is **not OSI-approved**, so riskell cannot go into
Homebrew core, nixpkgs or a distribution's own repositories. The tap and the 2-year tail cover that.

## Commercial and OEM licenses

A commercial license is available for anything the table above marks **No** — a paid product built on riskell, white-labelling, an OEM
bundle. [Open an issue](https://github.com/rish139/riskell/issues) to talk about it. Contributions are covered by the [CLA](CLA.md),
which is what keeps a second license possible; the CLA does not take your copyright.

## History

`0.1.0`–`0.1.2` were released under PolyForm Noncommercial 1.0.0. Those releases stay under it. This license applies to `0.2.0` and
later, and to the repository's `main` from 2026-11-18.

The license is the standard text maintained at [getsentry/fsl.software](https://github.com/getsentry/fsl.software); it is on the
[SPDX list](https://spdx.org/licenses/FSL-1.1-MIT.html) as `FSL-1.1-MIT`. If you are choosing a license for your own project, use their
text, not this page.
