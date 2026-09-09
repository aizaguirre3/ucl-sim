#!/usr/bin/env Rscript
# 03_crossleague.R -----------------------------------------------------------
# THE experiment: does cross-league calibration actually hold up?
#
# Protocol: rolling-origin, leave-future-out by season. For each test season we
# refit on everything strictly before 1 August of that season and predict the
# CROSS-LEAGUE European matches played in it (a club from league A vs a club
# from league B). Those are the only matches whose difficulty depends on
# getting the league levels right.
#
# Variants compared:
#   hier     - hierarchical league terms, trained on domestic + bridge
#   pooled   - NO league terms (all clubs shrink to one global mean)
#   nobridge - league terms present but trained on DOMESTIC ONLY, so nothing
#              ties the leagues together: the ablation that shows the bridge is
#              doing real work
#   elo      - club Elo difference through an ordered logit (rating baseline)
#
# We also test for the SELECTION BIAS visible in the fitted league terms: if a
# strong league's term is inflated, its clubs should systematically underperform
# their own forecasts. That is a directional bias test, not just a scalar score.
# -----------------------------------------------------------------------------

suppressMessages({
  library(dplyr)
  library(ggplot2)
})

TEST_SEASONS <- 2019:2025          # season starting year (Aug Y -> Jul Y+1)

outcome_class <- function(hs, as_) ifelse(hs > as_, 1L, ifelse(hs == as_, 2L, 3L))

# ---- club Elo baseline ------------------------------------------------------
run_club_elo <- function(matches, k = 20, hfa = 60, init = 1500) {
  h <- matches |> arrange(date)
  teams <- sort(unique(c(h$home, h$away)))
  R <- setNames(rep(init, length(teams)), teams)
  hi <- match(h$home, teams); ai <- match(h$away, teams)
  s_home <- ifelse(h$hs > h$as, 1, ifelse(h$hs == h$as, 0.5, 0))
  mov <- pmax(1, log1p(abs(h$hs - h$as)))
  pre_h <- numeric(nrow(h)); pre_a <- numeric(nrow(h))
  for (i in seq_len(nrow(h))) {
    rh <- R[hi[i]]; ra <- R[ai[i]]
    pre_h[i] <- rh; pre_a[i] <- ra
    e <- 1 / (1 + 10^(-((rh + hfa) - ra) / 400))
    d <- k * mov[i] * (s_home[i] - e)
    R[hi[i]] <- rh + d; R[ai[i]] <- ra - d
  }
  h$home_elo <- pre_h; h$away_elo <- pre_a
  list(history = h, ratings = R)
}

fit_ordered_elo <- function(tr, hfa = 60) {
  x <- (tr$home_elo + hfa - tr$away_elo) / 100
  y <- outcome_class(tr$hs, tr$as)
  nll <- function(par) {
    b <- par[1]; c1 <- par[2]; c2 <- c1 + exp(par[3]); eta <- b * x
    p <- clamp_probs(cbind(1 - plogis(c2 - eta),
                           plogis(c2 - eta) - plogis(c1 - eta),
                           plogis(c1 - eta)))
    -mean(log(p[cbind(seq_along(y), y)]))
  }
  par <- optim(c(1, -0.5, 0), nll, method = "BFGS")$par
  list(b = par[1], c1 = par[2], c2 = par[2] + exp(par[3]), hfa = hfa)
}
predict_ordered_elo <- function(m, he, ae) {
  eta <- m$b * (he + m$hfa - ae) / 100
  cbind(home = 1 - plogis(m$c2 - eta),
        draw = plogis(m$c2 - eta) - plogis(m$c1 - eta),
        away = plogis(m$c1 - eta))
}

# ---- one fold ---------------------------------------------------------------
run_fold <- function(matches, start_year) {
  cut <- as.Date(sprintf("%d-08-01", start_year))
  end <- as.Date(sprintf("%d-08-01", start_year + 1))
  train <- matches |> filter(date < cut)
  test <- matches |> filter(comp == "european", date >= cut, date < end,
                            lg_home != lg_away)
  if (nrow(test) < 10 || nrow(train) < 1000) return(NULL)

  mods <- list(
    hier     = fit_club_model(train, ref_date = cut - 1, use_league = TRUE),
    pooled   = fit_club_model(train, ref_date = cut - 1, use_league = FALSE),
    nobridge = fit_club_model(train |> filter(comp == "domestic"),
                              ref_date = cut - 1, use_league = TRUE)
  )
  preds <- lapply(mods, function(m) {
    t(vapply(seq_len(nrow(test)), function(i)
      predict_club(m, test$home[i], test$away[i], a_adv = 1,
                   lgA = test$lg_home[i], lgB = test$lg_away[i])$wdl,
      numeric(3)))
  })

  el <- run_club_elo(train)
  ob <- fit_ordered_elo(el$history)
  he <- ifelse(test$home %in% names(el$ratings), el$ratings[test$home], 1500)
  ae <- ifelse(test$away %in% names(el$ratings), el$ratings[test$away], 1500)
  preds$elo <- predict_ordered_elo(ob, he, ae)

  # league-gap for the bias test (positive = home club's league rated stronger)
  hm <- mods$hier
  gap <- (hm$Latt[test$lg_home] - hm$Ldef[test$lg_home]) -
         (hm$Latt[test$lg_away] - hm$Ldef[test$lg_away])

  list(y = outcome_class(test$hs, test$as), preds = preds,
       gap = unname(gap), season = start_year, n = nrow(test))
}

# ---- main -------------------------------------------------------------------
run_crossleague <- function() {
  matches <- readRDS("data/matches.rds")
  folds <- lapply(TEST_SEASONS, function(s) {
    r <- run_fold(matches, s)
    if (!is.null(r)) message(sprintf("  fold %d-%02d: %d cross-league matches",
                                     s, (s + 1) %% 100, r$n))
    r
  })
  folds <- Filter(Negate(is.null), folds)

  y <- unlist(lapply(folds, `[[`, "y"))
  gap <- unlist(lapply(folds, `[[`, "gap"))
  vnames <- names(folds[[1]]$preds)
  P <- lapply(vnames, function(v) do.call(rbind, lapply(folds, function(f) f$preds[[v]])))
  names(P) <- vnames

  pooled_rel <- function(p) {
    rt <- reliability_table(c(p[, 1], p[, 2], p[, 3]),
                            c(as.integer(y == 1), as.integer(y == 2), as.integer(y == 3)),
                            bins = 10)
    expected_calibration_error(rt)
  }
  tab <- tibble(
    model = c("hierarchical (league terms)", "pooled (no league terms)",
              "domestic-only (no bridge)", "club Elo logit"),
    key = vnames,
    log_loss = vapply(P, function(p) multiclass_logloss(p, y), numeric(1)),
    brier = vapply(P, function(p) multiclass_brier(p, y), numeric(1)),
    ece = vapply(P, pooled_rel, numeric(1))
  ) |> arrange(log_loss)

  # ---- directional bias test: do favoured-league clubs underperform? --------
  ph <- P$hier
  bias <- tibble(gap = gap, pred_home = ph[, 1], obs_home = as.integer(y == 1)) |>
    mutate(bucket = cut(gap, breaks = c(-Inf, -0.4, -0.15, 0.15, 0.4, Inf),
                        labels = c("much weaker", "weaker", "similar",
                                   "stronger", "much stronger"))) |>
    group_by(bucket) |>
    summarise(n = n(), pred = mean(pred_home), obs = mean(obs_home),
              .groups = "drop") |>
    mutate(gap_pp = 100 * (obs - pred))

  saveRDS(list(table = tab, bias = bias, n = length(y)),
          "data/crossleague.rds")

  message(sprintf("\nCross-league test set: %d matches over %d seasons\n",
                  length(y), length(folds)))
  print(as.data.frame(tab |> select(model, log_loss, brier, ece)),
        row.names = FALSE, digits = 4)
  message("\nDirectional bias -- predicted vs observed home-win rate by league gap:")
  print(as.data.frame(bias), row.names = FALSE, digits = 3)
  message("\n(gap_pp = observed minus predicted, in percentage points;",
          " systematic negatives where the home league is 'stronger'",
          " would mean big-league clubs are over-rated.)")
  invisible(tab)
}

if (sys.nframe() == 0L) {
  source("R/utils.R"); source("R/02_match_model.R")
  run_crossleague()
}
