suppressMessages({library(dplyr)})
setwd("/Users/alejandro/ucl-sim")
source("R/utils.R"); source("R/00_ingest.R"); source("R/02_match_model.R"); source("R/03_crossleague.R")
matches <- readRDS("data/matches.rds")
fold_p <- function(start_year, lp, rg) {
  cut <- as.Date(sprintf("%d-08-01", start_year)); end <- as.Date(sprintf("%d-08-01", start_year+1))
  train <- matches |> filter(date < cut)
  test <- matches |> filter(comp=="european", date>=cut, date<end, lg_home!=lg_away)
  if (nrow(test) < 10) return(NULL)
  m <- fit_club_model(train, ref_date=cut-1, league_pen=lp, ridge=rg)
  p <- t(vapply(seq_len(nrow(test)), function(i)
    predict_club(m, test$home[i], test$away[i], a_adv=1,
                 lgA=test$lg_home[i], lgB=test$lg_away[i])$wdl, numeric(3)))
  list(y=outcome_class(test$hs,test$as), p=p)
}
grid <- expand.grid(ridge=c(0.5,1,2,4,8,16), league_pen=c(5,15,40))
res <- lapply(seq_len(nrow(grid)), function(k) {
  fs <- Filter(Negate(is.null), lapply(TEST_SEASONS, function(s) fold_p(s, grid$league_pen[k], grid$ridge[k])))
  y <- unlist(lapply(fs, `[[`, "y")); P <- do.call(rbind, lapply(fs, `[[`, "p"))
  rt <- reliability_table(c(P[,1],P[,2],P[,3]), c(as.integer(y==1),as.integer(y==2),as.integer(y==3)), bins=10)
  tibble(ridge=grid$ridge[k], league_pen=grid$league_pen[k],
         log_loss=multiclass_logloss(P,y), brier=multiclass_brier(P,y),
         ece=expected_calibration_error(rt))
})
out <- bind_rows(res) |> arrange(log_loss)
cat("=== joint (ridge x league_pen) sweep on 1,838 cross-league matches ===\n")
print(as.data.frame(head(out,10)), row.names=FALSE, digits=5)
saveRDS(out, "data/joint_sweep.rds")
