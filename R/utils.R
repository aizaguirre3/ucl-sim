#!/usr/bin/env Rscript
# utils.R --------------------------------------------------------------------
# Pure, side-effect-free helpers shared across the wc-sim pipeline. Everything
# here is unit-tested in tests/test_utils.R. The fiddly competition rules
# (group tiebreakers, "eight best third-place" selection, third-place -> R32
# slot assignment) and the scoring metrics (log loss, Brier, reliability) live
# here precisely so they can be tested against hand-constructed expectations.
# -----------------------------------------------------------------------------

suppressMessages({
  library(dplyr)
})

`%||%` <- function(a, b) if (is.null(a) || length(a) == 0L) b else a

# ---- Team-name normalization ------------------------------------------------
# Map historical / variant names onto a single canonical spelling so that a
# team's full history joins to one set of ratings. The canonical spelling is
# the one used by the martj42 results feed for the *current* nation, so the
# 2026 fixtures and the deep history line up without further work.
TEAM_NAME_MAP <- c(
  "West Germany"            = "Germany",
  "East Germany"           = "Germany DR",   # kept distinct: a different nation
  "Soviet Union"           = "Russia",
  "CIS"                    = "Russia",
  "Czechoslovakia"         = "Czech Republic",
  "Czechia"                = "Czech Republic",
  "Yugoslavia"             = "Serbia",
  "Serbia and Montenegro"  = "Serbia",
  "FR Yugoslavia"          = "Serbia",
  "Zaire"                  = "DR Congo",
  "Congo DR"               = "DR Congo",
  "Republic of Ireland"    = "Ireland",
  "Korea Republic"         = "South Korea",
  "Korea DPR"              = "North Korea",
  "IR Iran"                = "Iran",
  "Cote d'Ivoire"          = "Ivory Coast",
  "Cote d`Ivoire"          = "Ivory Coast",
  "Cabo Verde"             = "Cape Verde",
  "Turkiye"                = "Turkey",
  "Turkiye "               = "Turkey",
  "T" = "Turkey"  # guard against a stray truncation; harmless if unused
)

#' Normalize a vector of team names to canonical spellings.
#' @param x character vector of raw team names.
#' @return character vector, same length, with known variants remapped.
normalize_team_names <- function(x) {
  x <- trimws(as.character(x))
  hit <- x %in% names(TEAM_NAME_MAP)
  x[hit] <- TEAM_NAME_MAP[x[hit]]
  x
}

# ---- Match-importance & time-decay weights ----------------------------------

#' Classify a tournament label as "friendly" or "competitive".
#' Everything that is not an explicit friendly counts as competitive
#' (World Cup + qualifiers, continental finals + qualifiers, Nations League,
#' Confederations Cup, etc.).
#' @param tournament character vector of tournament labels.
#' @return character vector of "friendly" / "competitive".
classify_importance <- function(tournament) {
  ifelse(grepl("friendly", tournament, ignore.case = TRUE),
         "friendly", "competitive")
}

#' Match-importance weight: friendlies down-weighted relative to competitive.
#' @param tournament tournament labels.
#' @param w_friendly weight applied to friendlies (competitive == 1).
#' @return numeric weight vector.
importance_weight <- function(tournament, w_friendly = 0.5) {
  ifelse(classify_importance(tournament) == "friendly", w_friendly, 1.0)
}

#' Exponential time-decay weight (half-life parameterized).
#' @param match_date Date vector of match dates.
#' @param ref_date single Date the model is "as of" (recent == weight 1).
#' @param half_life_days half-life in days (default ~2 years).
#' @return numeric weight in (0, 1]; future matches (after ref) get 0.
time_decay_weight <- function(match_date, ref_date, half_life_days = 730) {
  age <- as.numeric(difftime(ref_date, match_date, units = "days"))
  w <- 0.5^(age / half_life_days)
  w[age < 0] <- 0          # never let post-cutoff matches leak into a fit
  w
}

# ---- Dixon-Coles low-score dependence + score matrix ------------------------

#' Dixon-Coles tau adjustment for the four low-score cells.
#' @param x,y home/away goals (scalars or equal-length vectors).
#' @param lambda,mu home/away expected goals.
#' @param rho dependence parameter.
#' @return multiplicative adjustment(s).
dc_tau <- function(x, y, lambda, mu, rho) {
  out <- rep(1, length(x))
  out[x == 0 & y == 0] <- (1 - lambda * mu * rho)[x == 0 & y == 0]
  out[x == 0 & y == 1] <- (1 + lambda * rho)[x == 0 & y == 1]
  out[x == 1 & y == 0] <- (1 + mu * rho)[x == 1 & y == 0]
  out[x == 1 & y == 1] <- (1 - rho)
  out
}

#' Build a (max_goals+1) x (max_goals+1) score-line probability matrix.
#' Rows index home goals (0..max), columns away goals. Dixon-Coles corrected
#' and renormalized to sum to 1.
#' @param lambda home expected goals, mu away expected goals, rho DC parameter.
#' @param max_goals truncation (default 10 covers virtually all mass).
#' @return numeric matrix summing to 1.
score_matrix <- function(lambda, mu, rho = 0, max_goals = 10L) {
  hg <- 0:max_goals
  m <- outer(dpois(hg, lambda), dpois(hg, mu))   # independent Poisson
  # Dixon-Coles corner correction
  m[1, 1] <- m[1, 1] * (1 - lambda * mu * rho)
  m[1, 2] <- m[1, 2] * (1 + lambda * rho)
  m[2, 1] <- m[2, 1] * (1 + mu * rho)
  m[2, 2] <- m[2, 2] * (1 - rho)
  m[m < 0] <- 0
  m / sum(m)
}

#' Collapse a score matrix to (home win, draw, away win) probabilities.
#' @param m score matrix from score_matrix().
#' @return named numeric vector c(home, draw, away) summing to 1.
wdl_from_matrix <- function(m) {
  hw <- sum(m[lower.tri(m)])
  aw <- sum(m[upper.tri(m)])
  dr <- sum(diag(m))
  c(home = hw, draw = dr, away = aw)
}

#' Expected goals for each side implied by a score matrix.
#' @param m score matrix.
#' @return named numeric vector c(home, away).
xg_from_matrix <- function(m) {
  g <- seq_len(nrow(m)) - 1L
  c(home = sum(rowSums(m) * g), away = sum(colSums(m) * g))
}

# ---- Scoring metrics --------------------------------------------------------

#' Clamp probabilities away from {0,1} for stable logs.
clamp_probs <- function(p, eps = 1e-15) pmin(pmax(p, eps), 1 - eps)

#' Multiclass log loss.
#' @param probs N x K matrix of class probabilities (rows sum ~1).
#' @param y integer vector length N in 1..K of realized class.
#' @return mean negative log-likelihood.
multiclass_logloss <- function(probs, y) {
  probs <- clamp_probs(as.matrix(probs))
  idx <- cbind(seq_along(y), y)
  -mean(log(probs[idx]))
}

#' Multiclass Brier score (sum of squared error over the one-hot target).
#' @param probs N x K matrix; y integer 1..K.
#' @return mean over rows of sum_k (p_k - 1{y=k})^2.
multiclass_brier <- function(probs, y) {
  probs <- as.matrix(probs)
  onehot <- matrix(0, nrow(probs), ncol(probs))
  onehot[cbind(seq_along(y), y)] <- 1
  mean(rowSums((probs - onehot)^2))
}

#' Reliability table for a binary forecast.
#' @param p numeric predicted probabilities in [0,1].
#' @param y 0/1 outcomes.
#' @param bins number of equal-width bins on [0,1].
#' @return tibble(bin, n, mean_pred, obs_freq).
reliability_table <- function(p, y, bins = 10L) {
  br <- seq(0, 1, length.out = bins + 1L)
  b <- cut(p, breaks = br, include.lowest = TRUE, labels = FALSE)
  tibble(bin = b, p = p, y = y) |>
    group_by(bin) |>
    summarise(n = n(), mean_pred = mean(p), obs_freq = mean(y),
              .groups = "drop") |>
    arrange(bin)
}

#' Expected Calibration Error from a reliability table (weighted |gap|).
#' @param rt output of reliability_table().
#' @return scalar ECE.
expected_calibration_error <- function(rt) {
  sum(rt$n * abs(rt$mean_pred - rt$obs_freq)) / sum(rt$n)
}

# ---- Group tables & FIFA tiebreakers ---------------------------------------

#' Compute a group table from played matches.
#' @param matches tibble(home, away, home_score, away_score). Teams are taken
#'   from the union of home/away, so all four appear even with partial play.
#' @param teams optional character vector to force the team set / order.
#' @return tibble(team, pld, w, d, l, gf, ga, gd, pts).
compute_group_table <- function(matches, teams = NULL) {
  teams <- teams %||% sort(unique(c(matches$home, matches$away)))
  acc <- lapply(teams, function(t) {
    h <- matches[matches$home == t, , drop = FALSE]
    a <- matches[matches$away == t, , drop = FALSE]
    gf <- sum(h$home_score, a$away_score, na.rm = TRUE)
    ga <- sum(h$away_score, a$home_score, na.rm = TRUE)
    res <- c(
      ifelse(h$home_score > h$away_score, "W",
             ifelse(h$home_score == h$away_score, "D", "L")),
      ifelse(a$away_score > a$home_score, "W",
             ifelse(a$away_score == a$home_score, "D", "L"))
    )
    res <- res[!is.na(res)]
    tibble(team = t, pld = length(res),
           w = sum(res == "W"), d = sum(res == "D"), l = sum(res == "L"),
           gf = gf, ga = ga, gd = gf - ga,
           pts = 3L * sum(res == "W") + sum(res == "D"))
  })
  bind_rows(acc)
}

#' Order a tied block of teams by head-to-head, then drawing of lots.
#' @keywords internal
.order_block <- function(block, matches) {
  if (length(block) <= 1L) return(block)
  sub <- matches[matches$home %in% block & matches$away %in% block, ,
                 drop = FALSE]
  tab <- compute_group_table(sub, teams = block)
  # head-to-head: points, then GD, then GF (all within the tied subset)
  ord <- order(-tab$pts, -tab$gd, -tab$gf)
  tab <- tab[ord, ]
  # any still-tied on h2h pts/gd/gf -> drawing of lots (random)
  key <- paste(tab$pts, tab$gd, tab$gf)
  out <- character(0)
  for (k in unique(key)) {
    grp <- tab$team[key == k]
    if (length(grp) > 1L) grp <- sample(grp)   # lots
    out <- c(out, grp)
  }
  out
}

#' Rank a group 1st..last applying FIFA 2026 tiebreakers in order:
#' points -> goal difference -> goals scored -> head-to-head (pts, GD, GF among
#' the tied teams) -> drawing of lots. (Fair-play points are not modelled and
#' fall through to lots; documented.)
#' @param matches tibble(home, away, home_score, away_score) for the group.
#' @param teams optional team set.
#' @return character vector of teams in finishing order (1st first).
rank_group <- function(matches, teams = NULL) {
  tab <- compute_group_table(matches, teams)
  ord <- order(-tab$pts, -tab$gd, -tab$gf)
  tab <- tab[ord, ]
  key <- paste(tab$pts, tab$gd, tab$gf)
  out <- character(0)
  for (k in unique(key)) {
    block <- tab$team[key == k]
    out <- c(out, .order_block(block, matches))
  }
  out
}

# ---- Third-place ranking & R32 slot assignment ------------------------------

#' Rank the third-placed teams across groups (best first) and flag the
#' qualifiers. FIFA criteria across third-place teams: points, goal difference,
#' goals scored, then drawing of lots.
#' @param tp tibble(group, team, pts, gd, gf) one row per group's 3rd team.
#' @param n_qualify how many advance (8 for the 48-team format).
#' @return input augmented with integer `rank` and logical `qualified`.
rank_third_place <- function(tp, n_qualify = 8L) {
  jitter <- runif(nrow(tp), 0, 1e-9)            # drawing of lots
  ord <- order(-tp$pts, -tp$gd, -tp$gf, -jitter)
  tp <- tp[ord, ]
  tp$rank <- seq_len(nrow(tp))
  tp$qualified <- tp$rank <= n_qualify
  tp
}

#' Maximum bipartite matching (Kuhn's augmenting-path algorithm).
#' @param allowed named list: slot_id -> character vector of admissible groups.
#' @param groups character vector of group letters to place (one per slot).
#' @return named character vector slot_id -> group, or NULL if no perfect match.
bipartite_match <- function(allowed, groups) {
  slots <- names(allowed)
  match_for_group <- setNames(rep(NA_character_, length(groups)), groups)
  try_assign <- function(slot, visited) {
    for (g in allowed[[slot]]) {
      if (!(g %in% groups) || g %in% visited) next
      visited <- c(visited, g)
      cur <- match_for_group[[g]]
      if (is.na(cur) || try_assign(cur, visited)) {
        match_for_group[[g]] <<- slot
        return(TRUE)
      }
    }
    FALSE
  }
  for (s in slots) try_assign(s, character(0))
  if (any(is.na(match_for_group))) return(NULL)
  # invert: slot -> group
  setNames(names(match_for_group), match_for_group)[slots]
}

#' Assign qualifying third-place groups to the eight R32 third-place slots.
#' Respects each slot's admissible-group constraint via bipartite matching;
#' falls back to a rank-ordered greedy fill if the constraints admit no perfect
#' matching (defensive — the official constraints always do).
#' @param qual_groups character vector (length == #slots) of qualifying groups.
#' @param slot_allowed named list slot_id -> admissible group letters.
#' @return named character vector slot_id -> group.
assign_third_place_slots <- function(qual_groups, slot_allowed) {
  m <- bipartite_match(slot_allowed, qual_groups)
  if (!is.null(m)) return(m)
  # fallback: greedy by slot order
  remaining <- qual_groups
  out <- setNames(rep(NA_character_, length(slot_allowed)), names(slot_allowed))
  for (s in names(slot_allowed)) {
    cand <- intersect(slot_allowed[[s]], remaining)
    pick <- if (length(cand)) cand[1] else remaining[1]
    out[s] <- pick
    remaining <- setdiff(remaining, pick)
  }
  out
}

# Auto-run guard: this file only defines functions.
if (sys.nframe() == 0L) message("utils.R loaded (functions only).")
