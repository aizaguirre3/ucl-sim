suppressMessages({library(dplyr)})
setwd("/Users/alejandro/ucl-sim")
source("R/utils.R"); source("R/00_ingest.R"); source("R/02_match_model.R"); source("R/03_crossleague.R")
matches <- readRDS("data/matches.rds")
RIDGES <- c(2,4,8,16)
acc <- list()
for (s in TEST_SEASONS) {
  cut <- as.Date(sprintf("%d-08-01", s)); end <- as.Date(sprintf("%d-08-01", s+1))
  train <- matches |> filter(date < cut)
  test <- matches |> filter(comp=="european", date>=cut, date<end, lg_home!=lg_away)
  if (nrow(test) < 10) next
  ref <- fit_club_model(train, ref_date=cut-1, league_pen=15, ridge=8)   # fixed bucketer
  netv <- function(t,l) {
    a <- if (t %in% names(ref$Tatt)) ref$Tatt[[t]] else 0
    dd <- if (t %in% names(ref$Tdef)) ref$Tdef[[t]] else 0
    lg <- if (!is.null(l) && l %in% names(ref$Latt)) l else ref$leagues[1]
    unname(a - dd + ref$Latt[[lg]] - ref$Ldef[[lg]])
  }
  gap <- abs(vapply(seq_len(nrow(test)), function(i)
    netv(test$home[i],test$lg_home[i]) - netv(test$away[i],test$lg_away[i]), numeric(1)))
  y <- outcome_class(test$hs, test$as)
  for (rg in RIDGES) {
    m <- fit_club_model(train, ref_date=cut-1, league_pen=15, ridge=rg)
    p <- t(vapply(seq_len(nrow(test)), function(i)
      predict_club(m, test$home[i], test$away[i], a_adv=1,
                   lgA=test$lg_home[i], lgB=test$lg_away[i])$wdl, numeric(3)))
    fav_is_home <- p[,1] >= p[,3]
    acc[[length(acc)+1]] <- tibble(ridge=rg, gap=gap, y=y,
                                   p_actual=p[cbind(seq_along(y), y)],
                                   p_fav=pmax(p[,1],p[,3]),
                                   fav_won=ifelse(fav_is_home, y==1L, y==3L),
                                   p_draw=p[,2], drew=y==2L)
  }
}
d <- bind_rows(acc)
qs <- quantile(d$gap[d$ridge==8], c(1/3,2/3))
d <- d |> mutate(bucket=cut(gap, c(-Inf,qs[1],qs[2],Inf),
                            labels=c("even","moderate","LOPSIDED")))
out <- d |> group_by(bucket, ridge) |>
  summarise(n=n(), log_loss=mean(-log(clamp_probs(p_actual))), .groups="drop") |>
  tidyr::pivot_wider(names_from=ridge, values_from=log_loss, names_prefix="ridge_")
cat("=== log loss by matchup imbalance (cols = ridge) ===\n")
print(as.data.frame(out), row.names=FALSE, digits=5)
cat("\n=== LOPSIDED tercile: is the model under-confident in favourites? ===\n")
print(as.data.frame(d |> filter(bucket=="LOPSIDED") |> group_by(ridge) |>
  summarise(n=n(), pred_fav=mean(p_fav), actual_fav_won=mean(fav_won),
            gap_pp=100*(mean(fav_won)-mean(p_fav)),
            pred_draw=mean(p_draw), actual_draw=mean(drew), .groups="drop")), row.names=FALSE, digits=4)
cat("\n=== same check, EVEN tercile (control) ===\n")
print(as.data.frame(d |> filter(bucket=="even") |> group_by(ridge) |>
  summarise(n=n(), pred_fav=mean(p_fav), actual_fav_won=mean(fav_won),
            gap_pp=100*(mean(fav_won)-mean(p_fav)), .groups="drop")), row.names=FALSE, digits=4)
