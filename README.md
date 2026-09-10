# ucl-sim — Cross-League Calibration for Champions League Forecasting

Retargets the [`wc-sim`](https://github.com/aizaguirre3/wc-sim) modelling core from
international to **club** football, to attack the one problem that doesn't exist
in a World Cup: **how do you compare teams that never play each other?**

> **Status:** ingest → model → rolling-origin cross-league validation → live
> Matchday-1 forecast, all running end-to-end. Headline result is a *negative*
> one that turns positive under regularization — see below.

## The problem

Within La Liga, every team plays every other team twice a season. Relative
strength is pinned down precisely. But **is 5th in La Liga better than 5th in
the Bundesliga?** Those clubs never meet. Two leagues are near-disconnected
populations, joined only by a thin **bridge** of European matches — a few
hundred games a year linking thousands.

That makes club football a genuine *transfer* problem, and it's the same shape as
plenty of business questions: comparing sales reps across regions, students
across schools, or clinicians across sites, when each population is only
weakly connected to the others.

## The model

Team strength is decomposed hierarchically:

```
attack(team) = league_attack(its league) + team_deviation
```

- The **league term** is identified *only* by cross-league (bridge) matches.
- The **team deviation** is ridge-penalized, shrinking each club toward **its own
  league's mean** rather than a meaningless global mean.
- Clubs from countries with no modelled domestic league (Norway, Slovakia, …)
  get a **per-country pseudo-league**, so a UEFA-coefficient-like effect falls
  out of the model instead of being imposed.

Fitting is a weighted **sparse Poisson IRLS** (each long-format row has ~6
non-zeros) with a Dixon-Coles low-score correction — 40,606 matches, 566 clubs,
56 leagues, in **~1 second**.

## Headline finding: naive hierarchy is *worse than useless*

Rolling-origin, leave-future-out by season: refit on everything before 1 August,
predict that season's **cross-league** European matches. **1,838 held-out matches
across 7 seasons.**

| Variant | Log loss | Brier | ECE |
|---|---:|---:|---:|
| **hierarchical, `league_pen=15`** | **0.9688** | **0.5752** | **0.0167** |
| pooled (no league terms) | 0.9861 | 0.5872 | 0.0229 |
| club Elo logit | 0.9955 | 0.5930 | 0.0214 |
| domestic-only (no bridge) | 1.0025 | 0.5985 | 0.0253 |
| hierarchical, **unregularized** | 1.0174 | 0.5939 | 0.0320 |

Read the last row against the second: **letting the league terms fit freely is
worse than ignoring leagues entirely.** The reason is a clean, monotone
over-dispersion — the model stretches leagues too far apart:

| Home club's league is… | Predicted win % | Actual | Gap |
|---|---:|---:|---:|
| much weaker | 21.5% | **35.1%** | **+13.6pp** |
| weaker | 34.6% | 36.5% | +1.9pp |
| similar | 44.7% | 47.0% | +2.3pp |
| stronger | 52.7% | 53.0% | +0.3pp |
| much stronger | 68.1% | **62.4%** | **−5.7pp** |

**Why:** only a league's *elite* reach Europe, but the league term spreads their
results across *every* club in it. Unregularized, the fitted model rated
**Brentford and Bournemouth above Napoli and Juventus** — mid-table Premier
League sides inheriting credit earned by City and Arsenal.

Shrinking the league terms (`league_pen=15`, tuned by the same rolling-origin
validation) collapses that bias — the −5.7pp over-rating of strong leagues
disappears — and the hierarchy then **beats pooled, Elo, and the no-bridge
ablation on every metric**.

**The transferable lesson:** group-level effects estimated from a *selected*
sample must be shrunk hard. The naive hierarchical fit isn't just noisy — it is
confidently, directionally wrong, and worse than not modelling groups at all.

## External check: the betting market

Odds were pulled **once, read-only** for the six Matchday-1 fixtures of
2026-09-09 and de-vigged, purely as an outside reference (never a feature).

**Four of six agree within 3.4pp on every outcome** — including correctly making
Arsenal a road favourite at Napoli (model 51%, market 54%). Two disagree badly,
and in the *same direction*:

| Fixture | Model (underdog) | Market | Gap |
|---|---:|---:|---:|
| Stuttgart vs **Viking FK** | 20.0% | 9.0% | **+11.0pp** |
| Barcelona vs **Feyenoord** | 11.0% | 4.1% | **+6.9pp** |

The model shifts probability off the favourite into *both* the draw and the
underdog — the signature of under-dispersed ratings. Held-out data partly
agrees: in the most lopsided third of cross-league matches the model puts the
favourite at **64.5%** when it actually wins **67.1%** (+2.6pp), and predicts
**20.3%** draws against **17.1%** actual.

But the fix is *not* to loosen the team-ratings penalty. Sweeping it shows a
genuine **sharpness-vs-calibration trade-off**: `ridge=16` minimises log loss in
every imbalance bucket, while `ridge=2` is near-perfectly calibrated on
favourite win rate and *worse* on log loss and Brier everywhere. The whole
surface spans 0.967–0.971 log loss — inside the noise of 1,838 matches — so the
shipped default (`ridge=8`, `league_pen=15`) is left where it is rather than
tuned to the third decimal of a single test set.

The residual double-digit gaps on Viking and Feyenoord are therefore **not**
explained by shrinkage alone. The likelier causes are structural and are stated
in Limitations: Viking has 4 matches of evidence, and the market knows the
2026-27 season and summer transfers that this model cannot see.

## Scored: Matchday 1, 9 September 2026

The forecast above was committed **before kickoff** and graded afterwards.

| Model | Log loss | Brier |
|---|---:|---:|
| Market (de-vigged) | **0.382** | **0.174** |
| **Dixon-Coles (ours)** | 0.438 | 0.204 |
| Naive 33/33/33 | 1.099 | 0.667 |

**Outright result: 6 of 6 correct**, including Arsenal to win away at Napoli.
The model beat an uninformed baseline by a mile — and **lost to the market**,
which is the honest and expected outcome given the market knows the current
season and this model's data stops on 2026-05-30.

Where it lost is the interesting part. The pre-kickoff market check flagged
exactly two fixtures as outliers, both "over-rates the weak-league underdog":

| Match | Result | Model p(actual) | Market p(actual) |
|---|---|---:|---:|
| Barcelona **5-1** Feyenoord | home | 0.742 | **0.873** |
| Stuttgart **3-1** Viking FK | home | 0.610 | **0.764** |
| Liverpool **2-1** Atlético | home | **0.583** | 0.550 |
| PSG **6-1** Slovan | home | 0.920 | **0.926** |
| Sporting **3-1** Galatasaray | home | **0.585** | 0.546 |
| Napoli **0-1** Arsenal | away | 0.509 | **0.543** |

Both flagged fixtures resolved as comfortable favourite wins (5-1 and 3-1) —
precisely the direction the diagnostic predicted, and essentially all of the
model's deficit came from those two rows. On the four fixtures where model and
market agreed, **the model beat the market on two of them**.

Also consistent with the under-dispersion finding: the model carried an average
**18% draw probability** and there were **0 draws in 6**.

*Sample-size honesty: n = 6. One matchday settles nothing — it is reported
because a forecast you never grade is worthless, not because six matches
validate or refute a model.* Re-run with `Rscript R/05_score.R`.

## Engineering notes worth reading

- **Cross-source club identity is the real dirty work.** football-data.co.uk
  abbreviates (`Man United`, `Ath Madrid`, `Paris SG`); openfootball spells out
  (`Manchester United FC`, `Club Atlético de Madrid`). Fuzzy matching is
  **unsafe**: Ligue 1 contains *both* `Paris SG` and `Paris FC`, so one bad
  guess attributes PSG's results to a different club. Resolution is a
  hand-verified **alias table** plus strict, ambiguity-checked edit distance;
  unmatched clubs are pooled as rest-of-Europe, never silently dropped.
  Unmatched fell from 36 clubs / 651 appearances to **1**.
- **Accent handling matters.** `iconv(to="ASCII//TRANSLIT")` emits `?` on macOS,
  so "Bayern München" never matched "Bayern Munich". Uses
  `stringi::stri_trans_general(..., "Latin-ASCII")`.
- **Identity splitting.** Clubs with no domestic league drift between spellings
  across seasons (`Slovan Bratislava` / `ŠK Slovan Bratislava`), silently
  halving their history. Collapsed onto the modal spelling per country.
- **A European-specific home bonus was tested and rejected** — it came out at
  ×1.06 and did not improve cross-league scores (0.9695 vs 0.9688). Reported,
  not hidden.

## Pipeline

```
R/00_ingest.R      11 domestic leagues + European bridge; club identity matching
R/02_match_model.R hierarchical Dixon-Coles, sparse IRLS
R/03_crossleague.R rolling-origin cross-league validation + bias test
R/04_predict.R     forecast a fixture slate
R/utils.R          score matrix, DC tau, scoring metrics (shared with wc-sim)
```

## Limitations (stated, not buried)

- **No 2026-27 domestic form.** football-data.co.uk was returning HTTP 503
  during the build, so the model trains through **2026-05-30** — it has not seen
  the opening weeks of the current domestic season, nor summer transfers.
  Club squads churn far more than national teams, so this matters more here than
  it would for a World Cup model.
- **Thin evidence for small leagues.** Viking FK has **4** matches in the data;
  its rating is essentially the Norwegian pseudo-league term, which is itself
  dominated by Bodø/Glimt (20 of 56 matches). Forecasts involving such clubs
  carry much wider uncertainty than the point estimate suggests.
- **Residual home bias.** Even after shrinkage, home sides win ~3-5pp more often
  than forecast on the cross-league test set. A European-specific home term did
  not explain it; the likely culprit is empty-stadium COVID-era matches in the
  training window depressing the fitted home advantage.
- No player, injury, or transfer data. Team-strength level only.

## Data & attribution

- Domestic results: **football-data.co.uk** (free CSVs, 11 leagues, 2015-16 →
  2025-26).
- European results: **openfootball/champions-league** (UCL proper + UCL/UEL/UECL
  qualifying, 2015-16 → 2025-26).
- Betting odds are used **once, read-only**, as an external calibration
  reference — never as a model feature.
