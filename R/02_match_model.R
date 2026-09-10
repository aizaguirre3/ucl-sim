#!/usr/bin/env Rscript
# 02_match_model.R -----------------------------------------------------------
# Hierarchical Dixon-Coles for CLUB football.
#
# The modelling problem that does not exist in international football: within
# La Liga every team plays every other team twice, so relative strengths are
# pinned precisely -- but La Liga and the Bundesliga are two separate, almost
# disconnected populations. The ONLY thing linking them is the thin bridge of
# European matches.
#
# So team strength is decomposed hierarchically:
#
#     attack(team)  =  league_attack(its league)  +  team_deviation
#
# The league term is identified by the bridge (cross-league) matches; the team
# deviation is ridge-penalized, which shrinks each club toward ITS OWN LEAGUE'S
# mean rather than toward a meaningless global mean. Clubs from countries with
# no modelled domestic league (e.g. Norway, Slovakia) get a per-country pseudo
# league, so their strength is estimated almost entirely from the bridge -- a
# UEFA-country-coefficient effect that falls out of the model rather than being
# imposed.
# -----------------------------------------------------------------------------

suppressMessages({
  library(dplyr)
  library(Matrix)
})

# Weighted Poisson IRLS on a sparse design (same solver as wc-sim: each long
# row has ~6 non-zeros, so this is far faster than a dense glm over thousands
# of club dummies).
fit_poisson_irls <- function(X, y, w, pen, maxit = 60, tol = 1e-9) {
  p <- ncol(X)
  beta <- numeric(p)
  beta[1] <- log(weighted.mean(y, w) + 1e-6)
  P <- Diagonal(p, x = pen)
  for (it in seq_len(maxit)) {
    eta <- as.numeric(X %*% beta)
    eta[eta > 700] <- 700
    mu <- exp(eta)
    wk <- w * mu
    z <- eta + (y - mu) / mu
    beta_new <- as.numeric(solve(crossprod(X, wk * X) + P, crossprod(X, wk * z)))
    if (max(abs(beta_new - beta)) < tol) { beta <- beta_new; break }
    beta <- beta_new
  }
  beta
}

#' Assemble domestic + bridge matches into one table with a league label per side.
#' Clubs outside the 11 modelled leagues keep their European name and are
#' assigned a pseudo-league equal to their country code.
prepare_matches <- function(domestic = readRDS("data/domestic.rds"),
                            bridge_mapped = readRDS("data/bridge_mapped.rds"),
                            current = if (file.exists("data/current_season.rds"))
                              readRDS("data/current_season.rds") else NULL) {
  for (nm in c("sot_h", "sot_a"))
    if (!nm %in% names(domestic)) domestic[[nm]] <- NA_real_
  dom <- domestic |>
    transmute(date, home, away, hs, as, lg_home = div, lg_away = div,
              sot_h, sot_a, comp = "domestic")
  # football-data now covers the current season itself, so openfootball only
  # contributes rows strictly newer than football-data's latest date PER LEAGUE
  # (normally none). Enforced here as well as at ingest -- defence in depth
  # against double-counting the same match from two sources.
  if (!is.null(current) && nrow(current)) {
    lastd <- domestic |> group_by(div) |>
      summarise(last = max(date), .groups = "drop")
    fresh <- current |> left_join(lastd, by = "div") |>
      filter(is.na(last) | date > last)
    if (nrow(fresh))
      dom <- bind_rows(dom, fresh |>
        transmute(date, home, away, hs, as, lg_home = div, lg_away = div,
                  sot_h = NA_real_, sot_a = NA_real_, comp = "domestic"))
  }
  # Clubs with no domestic league appear only under their European spelling,
  # and that spelling drifts between seasons ("Slovan Bratislava" vs
  # "SK Slovan Bratislava"), which silently splits one club's history into two
  # weaker identities. Collapse them onto the most frequent spelling per
  # (country, normalized key).
  unmapped <- bind_rows(
    bridge_mapped |> filter(is.na(h_fd)) |> transmute(cc = home_cc, team = home),
    bridge_mapped |> filter(is.na(a_fd)) |> transmute(cc = away_cc, team = away)
  ) |>
    count(cc, team, name = "apps") |>
    mutate(key = norm_club(team)) |>
    group_by(cc, key) |>
    slice_max(apps, n = 1, with_ties = FALSE) |>
    ungroup() |>
    transmute(cc, key, canon = team)
  canon_of <- function(team, cc) {
    k <- paste(cc, norm_club(team), sep = "|")
    idx <- match(k, paste(unmapped$cc, unmapped$key, sep = "|"))
    ifelse(is.na(idx), team, unmapped$canon[idx])
  }
  eur <- bridge_mapped |>
    transmute(date,
              home = ifelse(is.na(h_fd), canon_of(home, home_cc), h_fd),
              away = ifelse(is.na(a_fd), canon_of(away, away_cc), a_fd),
              hs, as,
              lg_home = ifelse(is.na(h_div), paste0("X_", home_cc), h_div),
              lg_away = ifelse(is.na(a_div), paste0("X_", away_cc), a_div),
              comp = "european")
  bind_rows(dom, eur) |>
    filter(!is.na(hs), !is.na(as), !is.na(home), !is.na(away), home != away) |>
    arrange(date)
}

#' Fit the hierarchical Dixon-Coles club model.
#' @param matches output of prepare_matches().
#' @param ref_date "as of" date; only matches on/before it are used.
#' @param half_life time-decay half-life (days).
#' @param ridge L2 penalty on TEAM deviations (shrinks toward league mean).
#' @param league_pen penalty on league terms (near-zero = freely estimated).
#' @param w_european extra weight on European matches (they carry the
#'   cross-league signal; >1 leans on the bridge harder).
#' @param use_league if FALSE, drop the league terms entirely -- the "naive
#'   pooled" ablation that ignores that leagues differ in strength.
# league_pen = 15 is NOT cosmetic. Left free (~0) the league terms over-disperse
# badly -- clubs from weak leagues are under-rated by ~14pp and clubs from
# strong leagues over-rated by ~6pp on held-out cross-league matches, and the
# model loses to a naive pooled fit. Tuned by rolling-origin validation in
# R/03_crossleague.R; see data/league_pen_sweep.rds.
fit_club_model <- function(matches, ref_date = max(matches$date),
                           half_life = 730, ridge = 8, league_pen = 15,
                           w_european = 1, window_years = 11,
                           use_league = TRUE, shot_w = 0) {
  ref_date <- as.Date(ref_date)
  df <- matches |>
    filter(date <= ref_date, date >= ref_date - round(window_years * 365.25)) |>
    mutate(w = time_decay_weight(date, ref_date, half_life) *
             ifelse(comp == "european", w_european, 1)) |>
    filter(w > 0)

  teams <- sort(unique(c(df$home, df$away)))
  leagues <- sort(unique(c(df$lg_home, df$lg_away)))
  nT <- length(teams); nL <- length(leagues)

  # Response: goals, optionally blended with a shots-on-target xG proxy.
  # Split-half tests on 1,979 team-seasons: SOT alone predicts future goals no
  # better than goals (r 0.684 vs 0.684 attack; 0.540 vs 0.554 defence) but the
  # 50/50 blend beats both (0.714; 0.584) -- the two carry partly independent
  # signal. The goals-per-SOT rate is estimated from THIS fit's training rows,
  # so validation folds never see future data. Rows without shots (European
  # bridge matches, a few early seasons) fall back to actual goals.
  if (!"sot_h" %in% names(df)) df$sot_h <- NA_real_
  if (!"sot_a" %in% names(df)) df$sot_a <- NA_real_
  has_sot <- !is.na(df$sot_h) & !is.na(df$sot_a)
  conv <- if (any(has_sot))
    sum(df$hs[has_sot] + df$as[has_sot]) / sum(df$sot_h[has_sot] + df$sot_a[has_sot]) else 0
  df$yh <- ifelse(has_sot, (1 - shot_w) * df$hs + shot_w * conv * df$sot_h, df$hs)
  df$ya <- ifelse(has_sot, (1 - shot_w) * df$as + shot_w * conv * df$sot_a, df$as)

  # long format: one row per (match, scoring side)
  long <- bind_rows(
    df |> transmute(goals = yh, off = home, def = away,
                    lg_off = lg_home, lg_def = lg_away, home = 1L,
                    eu = as.integer(comp == "european"), w),
    df |> transmute(goals = ya, off = away, def = home,
                    lg_off = lg_away, lg_def = lg_home, home = 0L,
                    eu = as.integer(comp == "european"), w)
  )
  n <- nrow(long)
  ti_off <- match(long$off, teams); ti_def <- match(long$def, teams)
  li_off <- match(long$lg_off, leagues); li_def <- match(long$lg_def, leagues)

  nLc <- if (use_league) (nL - 1L) else 0L   # league 1 is the reference
  # col 3 is a European-only home bonus: continental away trips are harder than
  # domestic ones, and without it the model under-predicts home wins in Europe.
  oLa <- 3L; oLd <- 3L + nLc
  oTa <- 3L + 2L * nLc; oTd <- oTa + nT
  p <- oTd + nT

  he <- which(long$home == 1L)
  hee <- which(long$home == 1L & long$eu == 1L)
  rows <- c(seq_len(n), he, hee, seq_len(n), seq_len(n))
  cols <- c(rep(1L, n), rep(2L, length(he)), rep(3L, length(hee)),
            oTa + ti_off, oTd + ti_def)
  vals <- rep(1, length(rows))
  if (use_league) {
    ka <- which(li_off > 1L); kd <- which(li_def > 1L)
    rows <- c(rows, ka, kd)
    cols <- c(cols, oLa + (li_off[ka] - 1L), oLd + (li_def[kd] - 1L))
    vals <- c(vals, rep(1, length(ka) + length(kd)))
  }
  X <- sparseMatrix(i = rows, j = cols, x = vals, dims = c(n, p))

  pen <- c(1e-7, 1e-7, 1e-7,
           rep(league_pen, 2L * nLc),
           rep(ridge, 2L * nT))
  beta <- fit_poisson_irls(X, long$goals, long$w, pen)

  b0 <- beta[1]; bh <- beta[2]; bh_eu <- beta[3]
  Latt <- setNames(numeric(nL), leagues); Ldef <- setNames(numeric(nL), leagues)
  if (use_league) {
    Latt[leagues[-1]] <- beta[oLa + seq_len(nLc)]
    Ldef[leagues[-1]] <- beta[oLd + seq_len(nLc)]
  }
  Tatt <- setNames(beta[oTa + seq_len(nT)], teams)
  Tdef <- setNames(beta[oTd + seq_len(nT)], teams)

  # team -> league (most recent observed league for that club)
  tl <- bind_rows(
    df |> transmute(team = home, lg = lg_home, date),
    df |> transmute(team = away, lg = lg_away, date)
  ) |> group_by(team) |> slice_max(date, n = 1, with_ties = FALSE) |> ungroup()
  team_league <- setNames(tl$lg, tl$team)

  # Dixon-Coles rho by profile likelihood on the fitted means
  eu_f <- as.integer(df$comp == "european")
  la <- exp(b0 + bh + bh_eu * eu_f + Latt[df$lg_home] + Ldef[df$lg_away] +
              Tatt[df$home] + Tdef[df$away])
  mu <- exp(b0 + Latt[df$lg_away] + Ldef[df$lg_home] +
              Tatt[df$away] + Tdef[df$home])
  nll <- function(rho) {
    tau <- dc_tau(df$hs, df$as, la, mu, rho)
    if (any(tau <= 0)) return(1e10)
    -sum(df$w * log(tau))
  }
  rho <- optimize(nll, c(-0.2, 0.2))$minimum

  structure(list(
    b0 = b0, bh = bh, bh_eu = bh_eu, Latt = Latt, Ldef = Ldef, Tatt = Tatt, Tdef = Tdef,
    rho = rho, teams = teams, leagues = leagues, team_league = team_league,
    ref_date = ref_date, n_matches = nrow(df), use_league = use_league,
    params = list(half_life = half_life, ridge = ridge,
                  w_european = w_european, window_years = window_years,
                  shot_w = shot_w, goals_per_sot = conv)
  ), class = "club_dc")
}

# league of a team, with a safe fallback
.lg_of <- function(m, t, lg = NULL) {
  if (!is.null(lg) && lg %in% names(m$Latt)) return(lg)
  l <- unname(m$team_league[t])
  if (is.na(l) || !(l %in% names(m$Latt))) m$leagues[1] else l
}
.att <- function(m, t) if (t %in% names(m$Tatt)) unname(m$Tatt[t]) else 0
.def <- function(m, t) if (t %in% names(m$Tdef)) unname(m$Tdef[t]) else 0

#' Expected goals for one fixture.
#' @param a_adv,b_adv 0/1 home-advantage flags.
club_lambda <- function(m, A, B, a_adv = 1, b_adv = 0, lgA = NULL, lgB = NULL,
                        european = TRUE) {
  la_ <- .lg_of(m, A, lgA); lb_ <- .lg_of(m, B, lgB)
  bhe <- if (isTRUE(european)) (m$bh_eu %||% 0) else 0
  list(
    lambda = exp(m$b0 + (m$bh + bhe) * a_adv + m$Latt[[la_]] + m$Ldef[[lb_]] +
                   .att(m, A) + .def(m, B)),
    mu = exp(m$b0 + (m$bh + bhe) * b_adv + m$Latt[[lb_]] + m$Ldef[[la_]] +
               .att(m, B) + .def(m, A))
  )
}

#' Full probabilistic forecast for one club fixture.
predict_club <- function(m, A, B, a_adv = 1, b_adv = 0, lgA = NULL, lgB = NULL,
                         european = TRUE, max_goals = 10L) {
  e <- club_lambda(m, A, B, a_adv, b_adv, lgA, lgB, european)
  sm <- score_matrix(e$lambda, e$mu, m$rho, max_goals)
  list(lambda = e$lambda, mu = e$mu, wdl = wdl_from_matrix(sm),
       xg = xg_from_matrix(sm), matrix = sm)
}

if (sys.nframe() == 0L) {
  source("R/utils.R")
  mt <- prepare_matches()
  saveRDS(mt, "data/matches.rds")
  m <- fit_club_model(mt)
  saveRDS(m, "data/club_model.rds")
  message(sprintf("Fitted on %s matches | %d clubs | %d leagues",
                  format(m$n_matches, big.mark = ","), length(m$teams),
                  length(m$leagues)))
  message(sprintf("home adv = %.3f (x%.2f) | +European bonus = %.3f | rho = %.3f",
                  m$bh, exp(m$bh), m$bh_eu, m$rho))
  message("\nLeague attacking strength (relative to reference, higher = stronger):")
  ls <- sort(m$Latt - m$Ldef, decreasing = TRUE)
  print(round(head(ls, 14), 3))
}
