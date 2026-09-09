#!/usr/bin/env Rscript
# 04_predict.R ---------------------------------------------------------------
# Forecast a slate of Champions League fixtures with the fitted hierarchical
# club model. Club identities are resolved EXPLICITLY (not fuzzily) and the
# resolution is printed, because a silent mis-resolution -- e.g. Paris SG vs
# Paris FC -- produces a confident, wrong forecast.
# -----------------------------------------------------------------------------

suppressMessages({ library(dplyr) })

# 2026/27 UCL league phase, Matchday 1, Wed 9 Sep 2026.
# Fixture list cross-checked across three independent sources (UEFA, Wikipedia,
# beIN); all three agreed on all six matches and their home/away orientation.
MD1_WED <- tibble::tribble(
  ~home_label,           ~home_team,   ~home_lg, ~away_label,          ~away_team,           ~away_lg,
  "Barcelona",           "Barcelona",  "SP1",    "Feyenoord",          "Feyenoord",          "N1",
  "VfB Stuttgart",       "Stuttgart",  "D1",     "Viking FK",          "Viking FK",          "X_NOR",
  "Liverpool",           "Liverpool",  "E0",     "Atletico Madrid",    "Ath Madrid",         "SP1",
  "Paris Saint-Germain", "Paris SG",   "F1",     "Slovan Bratislava",  "Slovan Bratislava",  "X_SVK",
  "Sporting CP",         "Sp Lisbon",  "P1",     "Galatasaray",        "Galatasaray",        "T1",
  "Napoli",              "Napoli",     "I1",     "Arsenal",            "Arsenal",            "E0"
)

top_scores <- function(m, k = 3) {
  o <- order(-m); idx <- arrayInd(o[seq_len(k)], dim(m))
  paste(sprintf("%d-%d (%.0f%%)", idx[, 1] - 1, idx[, 2] - 1, 100 * m[o[seq_len(k)]]),
        collapse = ", ")
}

predict_slate <- function(model, slate = MD1_WED) {
  # hard fail rather than silently forecasting the wrong club
  missing <- setdiff(c(slate$home_team, slate$away_team), model$teams)
  if (length(missing))
    stop("unresolved clubs: ", paste(missing, collapse = ", "))

  rows <- lapply(seq_len(nrow(slate)), function(i) {
    f <- predict_club(model, slate$home_team[i], slate$away_team[i],
                      a_adv = 1, b_adv = 0,
                      lgA = slate$home_lg[i], lgB = slate$away_lg[i],
                      european = TRUE)
    tibble(
      match = sprintf("%s vs %s", slate$home_label[i], slate$away_label[i]),
      home = slate$home_label[i], away = slate$away_label[i],
      p_home = f$wdl[["home"]], p_draw = f$wdl[["draw"]], p_away = f$wdl[["away"]],
      xg_home = f$xg[["home"]], xg_away = f$xg[["away"]],
      likeliest = top_scores(f$matrix)
    )
  })
  bind_rows(rows)
}

if (sys.nframe() == 0L) {
  source("R/utils.R"); source("R/00_ingest.R"); source("R/02_match_model.R")
  mt <- prepare_matches(); saveRDS(mt, "data/matches.rds")
  model <- fit_club_model(mt)
  saveRDS(model, "data/club_model.rds")

  message(sprintf("Model: %s matches through %s | %d clubs | %d leagues",
                  format(model$n_matches, big.mark = ","), model$ref_date,
                  length(model$teams), length(model$leagues)))
  message("\nResolved club identities:")
  for (i in seq_len(nrow(MD1_WED)))
    message(sprintf("  %-20s -> %-20s [%s]   |  %-18s -> %-20s [%s]",
                    MD1_WED$home_label[i], MD1_WED$home_team[i], MD1_WED$home_lg[i],
                    MD1_WED$away_label[i], MD1_WED$away_team[i], MD1_WED$away_lg[i]))

  out <- predict_slate(model)
  message("\n=== UCL 2026/27 Matchday 1 -- Wednesday 9 September 2026 ===\n")
  for (i in seq_len(nrow(out))) {
    r <- out[i, ]
    message(sprintf("%s", r$match))
    message(sprintf("   %-22s %2.0f%%  |  Draw %2.0f%%  |  %-22s %2.0f%%",
                    r$home, 100 * r$p_home, 100 * r$p_draw, r$away, 100 * r$p_away))
    message(sprintf("   xG %.2f - %.2f   |  likeliest: %s\n",
                    r$xg_home, r$xg_away, r$likeliest))
  }
  write.csv(out, sprintf("forecasts/ucl_md1_%s.csv", "2026-09-09"), row.names = FALSE)
}
