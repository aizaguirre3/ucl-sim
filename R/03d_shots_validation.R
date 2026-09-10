suppressMessages({ library(dplyr) })
source("R/utils.R"); source("R/00_ingest.R"); source("R/02_match_model.R")
source("R/03_crossleague.R")
matches <- readRDS("data/matches.rds")
stopifnot("sot_h" %in% names(matches))

SW <- c(0, 0.25, 0.5, 0.75, 1)

# ---- 1. cross-league validation: does the shots blend help? ---------------
per <- list()
for (s in TEST_SEASONS) {
  cut <- as.Date(sprintf("%d-08-01", s)); end <- as.Date(sprintf("%d-08-01", s + 1))
  train <- matches |> filter(date < cut)
  test <- matches |> filter(comp == "european", date >= cut, date < end,
                            lg_home != lg_away)
  if (nrow(test) < 10) next
  y <- outcome_class(test$hs, test$as)
  for (sw in SW) {
    m <- fit_club_model(train, ref_date = cut - 1, shot_w = sw)
    p <- t(vapply(seq_len(nrow(test)), function(i)
      predict_club(m, test$home[i], test$away[i], a_adv = 1,
                   lgA = test$lg_home[i], lgB = test$lg_away[i])$wdl, numeric(3)))
    per[[length(per) + 1L]] <- tibble(sw = sw, season = s, id = seq_along(y),
      y = y, ph = p[, 1], pd = p[, 2], pa = p[, 3],
      ll = -log(clamp_probs(p[cbind(seq_along(y), y)])))
  }
}
d <- bind_rows(per)
base <- d |> filter(sw == 0) |> select(season, id, ll0 = ll)
tab <- d |> group_by(sw) |> group_modify(function(g, k) {
  P <- as.matrix(g[, c("ph", "pd", "pa")])
  rt <- reliability_table(c(P[, 1], P[, 2], P[, 3]),
          c(as.integer(g$y == 1), as.integer(g$y == 2), as.integer(g$y == 3)), bins = 10)
  j <- g |> left_join(base, by = c("season", "id"))
  dif <- j$ll - j$ll0
  tibble(n = nrow(g), log_loss = mean(g$ll), brier = multiclass_brier(P, g$y),
         ece = expected_calibration_error(rt),
         d_vs_goals = mean(dif), se = sd(dif) / sqrt(length(dif)))
}) |> ungroup()
cat("=== shots-blend weight on held-out CROSS-LEAGUE matches ===\n")
cat("(d_vs_goals = mean per-match log-loss change vs goals-only; negative = better)\n")
print(as.data.frame(tab), row.names = FALSE, digits = 4)
best <- tab$sw[which.min(tab$log_loss)]
cat(sprintf("\nbest shot_w = %.2f\n", best))
saveRDS(tab, "data/shots_sweep.rds")

# ---- 2. the two target fixtures: goals-only vs best blend -----------------
TARGETS <- tibble::tribble(
  ~hl, ~ht, ~hlg, ~al, ~at, ~alg,
  "Fenerbahce", "Fenerbahce", "T1", "Roma", "Roma", "I1",
  "PSV", "PSV Eindhoven", "N1", "Shakhtar", "Shakhtar Donetsk", "X_UKR")
cat(sprintf("\n=== targets (data through %s) ===\n", max(matches$date)))
for (sw in unique(c(0, best))) {
  m <- fit_club_model(matches, shot_w = sw)
  cat(sprintf("\n-- shot_w = %.2f (goals per SOT in training = %.3f) --\n",
              sw, m$params$goals_per_sot))
  for (i in seq_len(nrow(TARGETS))) {
    t <- TARGETS[i, ]
    f <- predict_club(m, t$ht, t$at, a_adv = 1, lgA = t$hlg, lgB = t$alg)
    cat(sprintf("  %-10s vs %-9s  %2.0f / %2.0f / %2.0f   xG %.2f-%.2f\n",
                t$hl, t$al, 100 * f$wdl[1], 100 * f$wdl[2], 100 * f$wdl[3],
                f$xg[1], f$xg[2]))
  }
}
