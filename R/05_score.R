#!/usr/bin/env Rscript
# 05_score.R -----------------------------------------------------------------
# Score the committed Matchday-1 forecast against the actual results.
# A forecast is only worth something if you grade it afterwards, including the
# times it loses to a baseline.
# -----------------------------------------------------------------------------

suppressMessages({ library(dplyr) })

# Actual results, 2026-09-09 (UEFA MD1, Wednesday slate)
RESULTS <- tibble::tribble(
  ~home_team,          ~away_team,           ~hs, ~as,
  "Barcelona",         "Feyenoord",           5L,  1L,
  "Stuttgart",         "Viking FK",           3L,  1L,
  "Liverpool",         "Ath Madrid",          2L,  1L,
  "Paris SG",          "Slovan Bratislava",   6L,  1L,
  "Sp Lisbon",         "Galatasaray",         3L,  1L,
  "Napoli",            "Arsenal",             0L,  1L
)

# De-vigged market probabilities captured pre-kickoff (external reference only)
MARKET <- tibble::tribble(
  ~home_team,   ~m_home, ~m_draw, ~m_away,
  "Barcelona",   0.8733,  0.0857,  0.0410,
  "Stuttgart",   0.7640,  0.1458,  0.0902,
  "Liverpool",   0.5504,  0.2380,  0.2116,
  "Paris SG",    0.9258,  0.0507,  0.0235,
  "Sp Lisbon",   0.5462,  0.2377,  0.2161,
  "Napoli",      0.2001,  0.2568,  0.5431
)

score_md1 <- function(model, slate = MD1_WED) {
  res <- slate |>
    left_join(RESULTS, by = c("home_team", "away_team")) |>
    left_join(MARKET, by = "home_team")
  stopifnot(!any(is.na(res$hs)))

  y <- ifelse(res$hs > res$as, 1L, ifelse(res$hs == res$as, 2L, 3L))

  P <- t(vapply(seq_len(nrow(res)), function(i) {
    predict_club(model, res$home_team[i], res$away_team[i], a_adv = 1,
                 lgA = res$home_lg[i], lgB = res$away_lg[i])$wdl
  }, numeric(3)))
  M <- as.matrix(res[, c("m_home", "m_draw", "m_away")])
  N <- matrix(1 / 3, nrow(res), 3)

  # exact-scoreline probability + rank the model gave the realized score
  sc <- vapply(seq_len(nrow(res)), function(i) {
    sm <- predict_club(model, res$home_team[i], res$away_team[i], a_adv = 1,
                       lgA = res$home_lg[i], lgB = res$away_lg[i])$matrix
    p <- sm[res$hs[i] + 1L, res$as[i] + 1L]
    c(p = p, rank = sum(sm > p) + 1)
  }, numeric(2))

  per <- tibble(
    match = sprintf("%s %d-%d %s", res$home_label, res$hs, res$as, res$away_label),
    result = c("home", "draw", "away")[y],
    model_p = P[cbind(seq_along(y), y)],
    market_p = M[cbind(seq_along(y), y)],
    model_ll = -log(clamp_probs(P[cbind(seq_along(y), y)])),
    market_ll = -log(clamp_probs(M[cbind(seq_along(y), y)])),
    exact_p = sc["p", ], exact_rank = sc["rank", ]
  )

  totals <- tibble(
    model = c("Dixon-Coles (ours)", "Market (de-vigged)", "Naive 33/33/33"),
    log_loss = c(multiclass_logloss(P, y), multiclass_logloss(M, y),
                 multiclass_logloss(N, y)),
    brier = c(multiclass_brier(P, y), multiclass_brier(M, y),
              multiclass_brier(N, y))
  ) |> arrange(log_loss)

  list(per_match = per, totals = totals,
       draws_pred = mean(P[, 2]), draws_actual = mean(y == 2))
}

if (sys.nframe() == 0L) {
  source("R/utils.R"); source("R/00_ingest.R"); source("R/02_match_model.R")
  source("R/04_predict.R")
  model <- readRDS("data/club_model.rds")
  s <- score_md1(model)
  message("=== Per-match ===")
  print(as.data.frame(s$per_match), row.names = FALSE, digits = 3)
  message("\n=== Totals (6 matches) ===")
  print(as.data.frame(s$totals), row.names = FALSE, digits = 4)
  message(sprintf("\nDraws: model predicted %.0f%% on average, actual %.0f%% (%d of 6)",
                  100 * s$draws_pred, 100 * s$draws_actual,
                  round(6 * s$draws_actual)))
  write.csv(s$per_match, "forecasts/ucl_md1_2026-09-09_scored.csv", row.names = FALSE)
}
