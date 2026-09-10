#!/usr/bin/env Rscript
# 00_ingest.R ----------------------------------------------------------------
# Two data sources, two very different shapes:
#
#   * DOMESTIC (football-data.co.uk): one CSV per league per season. These pin
#     down team strength *within* a league -- everyone plays everyone twice, so
#     the comparison graph is fully connected inside each league.
#
#   * EUROPEAN (openfootball/champions-league): semi-structured text, one file
#     per season. These are the ONLY matches that connect one league to another,
#     so they are the entire empirical basis for cross-league calibration. We
#     call them the "bridge".
#
# The hard part here is not downloading -- it is matching club identities across
# the two sources ("Man United" vs "Manchester United FC"). That join is done
# per-country and its quality is reported, never assumed.
# -----------------------------------------------------------------------------

suppressMessages({
  library(dplyr)
  library(readr)
  library(stringr)
})

# league code -> (country code used by openfootball, human name)
LEAGUES <- tribble(
  ~div,  ~cc,    ~league,
  "E0",  "ENG",  "Premier League",
  "SP1", "ESP",  "La Liga",
  "I1",  "ITA",  "Serie A",
  "D1",  "GER",  "Bundesliga",
  "F1",  "FRA",  "Ligue 1",
  "N1",  "NED",  "Eredivisie",
  "P1",  "POR",  "Primeira Liga",
  "B1",  "BEL",  "Belgian Pro League",
  "T1",  "TUR",  "Super Lig",
  "G1",  "GRE",  "Super League Greece",
  "SC0", "SCO",  "Scottish Premiership"
)

# Clubs whose country code differs from the league they play in.
CC_OVERRIDE <- c("MCO" = "F1")   # AS Monaco plays in Ligue 1

# Hand-verified aliases, keyed "<div>|<normalized european name>" -> the exact
# football-data spelling. Needed because football-data abbreviates heavily
# ("Man United", "Ath Madrid", "Paris SG") in ways no string metric can safely
# recover -- note Ligue 1 contains BOTH "Paris SG" and "Paris FC", so a fuzzy
# guess here would attribute PSG's results to a different club entirely.
CLUB_ALIAS <- c(
  # England
  "E0|manchester united"          = "Man United",
  "E0|manchester city"            = "Man City",
  "E0|tottenham hotspur"          = "Tottenham",
  "E0|newcastle united"           = "Newcastle",
  "E0|nottingham forest"          = "Nott'm Forest",
  "E0|wolverhampton wanderers"    = "Wolves",
  "E0|west ham united"            = "West Ham",
  "E0|leicester city"             = "Leicester",
  "E0|leeds united"               = "Leeds",
  "E0|brighton hove albion"       = "Brighton",
  # Spain
  "SP1|atletico madrid"           = "Ath Madrid",
  "SP1|club atletico madrid"      = "Ath Madrid",
  "SP1|athletic club"             = "Ath Bilbao",
  "SP1|athletic bilbao"           = "Ath Bilbao",
  "SP1|real sociedad"             = "Sociedad",
  "SP1|real betis"                = "Betis",
  "SP1|real betis balompie"       = "Betis",
  "SP1|espanyol"                  = "Espanol",
  "SP1|rcd espanyol barcelona"    = "Espanol",
  "SP1|rayo vallecano"            = "Vallecano",
  "SP1|celta vigo"                = "Celta",
  "SP1|real club celta vigo"      = "Celta",
  # Germany
  "D1|bayern munchen"             = "Bayern Munich",
  "D1|bayern muenchen"            = "Bayern Munich",
  "D1|borussia monchengladbach"   = "M'gladbach",
  "D1|borussia moenchengladbach"  = "M'gladbach",
  "D1|eintracht frankfurt"        = "Ein Frankfurt",
  "D1|bayer 04 leverkusen"        = "Leverkusen",
  "D1|bayer leverkusen"           = "Leverkusen",
  "D1|borussia dortmund"          = "Dortmund",
  "D1|1 koln"                     = "FC Koln",
  "D1|koln"                       = "FC Koln",
  "D1|rasenballsport leipzig"     = "RB Leipzig",
  "D1|stuttgart"                  = "Stuttgart",
  # France
  "F1|paris saint germain"        = "Paris SG",
  "F1|olympique de marseille"     = "Marseille",
  "F1|olympique marseille"        = "Marseille",
  "F1|olympique lyonnais"         = "Lyon",
  "F1|lille osc"                  = "Lille",
  "F1|stade rennais 1901"         = "Rennes",
  "F1|stade rennais"              = "Rennes",
  "F1|stade brestois 29"          = "Brest",
  "F1|stade brestois"             = "Brest",
  "F1|lens"                       = "Lens",
  "F1|saint etienne"              = "St Etienne",
  # Italy
  "I1|internazionale milano"      = "Inter",
  "I1|inter milan"                = "Inter",
  "I1|milan"                      = "Milan",
  "I1|roma"                       = "Roma",
  "I1|lazio"                      = "Lazio",
  "I1|lazio roma"                 = "Lazio",
  "I1|atalanta bc"                = "Atalanta",
  "I1|acf fiorentina"             = "Fiorentina",
  # Portugal
  "P1|sl benfica"                 = "Benfica",
  "P1|sport lisboa e benfica"     = "Benfica",
  "P1|sporting"                   = "Sp Lisbon",
  "P1|sporting clube portugal"    = "Sp Lisbon",
  "P1|sporting lisbon"            = "Sp Lisbon",
  "P1|sporting braga"             = "Sp Braga",
  "P1|sporting clube braga"       = "Sp Braga",
  "P1|braga"                      = "Sp Braga",
  "P1|vitoria guimaraes"          = "Guimaraes",
  "P1|vitoria"                    = "Guimaraes",
  # Netherlands
  "N1|psv"                        = "PSV Eindhoven",
  "N1|feyenoord rotterdam"        = "Feyenoord",
  # Greece
  "G1|olympiakos piraeus"         = "Olympiakos",
  "G1|olympiacos"                 = "Olympiakos",
  "G1|olympiacos piraeus"         = "Olympiakos",
  "G1|aek athen"                  = "AEK",
  "G1|aek athens"                 = "AEK",
  "G1|paok saloniki"              = "PAOK",
  "G1|paok thessaloniki"          = "PAOK",
  "G1|panathinaikos athens"       = "Panathinaikos",
  # Belgium
  "B1|krc genk"                   = "Genk",
  "B1|royal antwerp"              = "Antwerp",
  "B1|union saint gilloise"       = "St. Gilloise",
  "B1|royale union saint gilloise" = "St. Gilloise",
  # Turkey
  "T1|istanbul basaksehir"        = "Buyuksehyr",
  "T1|basaksehir"                 = "Buyuksehyr",
  # Spain / Germany / France stragglers
  "SP1|real sociedad futbol"      = "Sociedad",
  "D1|bor monchengladbach"        = "M'gladbach",
  "D1|fsv mainz"                  = "Mainz",
  "F1|racing club lens"           = "Lens",
  "F1|ogc nice"                   = "Nice",
  "SC0|heart of midlothian"       = "Hearts",
  "B1|sporting charleroi"         = "Charleroi",
  "G1|aris saloniki"              = "Aris"
)

SEASONS <- c("1516", "1617", "1718", "1819", "1920", "2021",
             "2122", "2223", "2324", "2425", "2526")
UCL_SEASONS <- c("2015-16", "2016-17", "2017-18", "2018-19", "2019-20",
                 "2020-21", "2021-22", "2022-23", "2023-24", "2024-25",
                 "2025-26")

FD_BASE <- "https://www.football-data.co.uk/mmz4281"
OF_BASE <- paste0("https://raw.githubusercontent.com/openfootball/",
                  "champions-league/master")

# ---- name normalization -----------------------------------------------------

# Tokens that are pure legal/sport boilerplate and never distinguish two clubs.
# Deliberately CONSERVATIVE: words like "real", "atletico", "athletic" and
# "sporting" look like noise but are precisely what separates Real Madrid from
# Atletico Madrid, so they stay. Over-stripping silently merges rival clubs.
NOISE <- c("fc", "cf", "afc", "sc", "ssc", "bsc", "sk", "bv", "sv", "vfb",
           "vfl", "tsg", "cp", "ud", "cd", "rc", "sd", "ac", "as", "ss", "kv",
           "kaa", "rsc", "calcio", "sportiva", "association", "aps", "pae",
           "sfp", "de", "of", "the",
           # Central/Eastern-European legal-form prefixes. Omitting these split
           # e.g. "FK Shakhtar Donetsk" from "Shakhtar Donetsk" into two weaker
           # identities -- the same failure mode as the Slovan Bratislava case.
           "fk", "nk", "hnk", "gnk", "mfk", "ofk", "pfc", "fsv", "tsv", "msv",
           "bk", "if", "ik", "fkø")

#' Normalize a club name to a comparable key.
#' Lowercases, strips accents and punctuation, drops legal/sport noise tokens.
norm_club <- function(x) {
  # stringi's Latin-ASCII transliteration, NOT iconv("ASCII//TRANSLIT"):
  # on macOS the latter emits "?" for accented characters, so "Bayern
  # Munchen" would never match "Bayern Munich".
  y <- stringi::stri_trans_general(as.character(x), "Latin-ASCII")
  y[is.na(y)] <- as.character(x)[is.na(y)]
  y <- tolower(y)
  y <- str_replace_all(y, "[^a-z0-9 ]", " ")
  y <- str_squish(y)
  toks <- strsplit(y, " ")
  vapply(toks, function(tk) {
    # drop boilerplate and bare founding-year / squad numbers ("Bologna FC
    # 1909", "Schalke 04") -- stripped on BOTH sides so it stays symmetric
    keep <- setdiff(tk, NOISE)
    keep <- keep[!grepl("^[0-9]+$", keep)]
    if (!length(keep)) keep <- tk           # never normalize to nothing
    paste(keep, collapse = " ")
  }, character(1))
}

# ---- domestic ---------------------------------------------------------------

#' Parse football-data dates, which are dd/mm/yy in older files and dd/mm/yyyy
#' in newer ones. Chosen per-value on the width of the year field: a blanket
#' tryFormats() silently reads "15/07/24" as the year 24 AD.
parse_fd_date <- function(x) {
  x <- str_squish(as.character(x))
  yr <- str_match(x, "^\\d{1,2}/\\d{1,2}/(\\d{2,4})$")[, 2]
  out <- as.Date(rep(NA_character_, length(x)))
  four <- !is.na(yr) & nchar(yr) == 4L
  two <- !is.na(yr) & nchar(yr) == 2L
  out[four] <- as.Date(x[four], format = "%d/%m/%Y")
  out[two] <- as.Date(x[two], format = "%d/%m/%y")
  out
}

#' Download + parse every league-season CSV (cached under data/raw).
load_domestic <- function(force = FALSE) {
  rows <- list()
  for (s in SEASONS) for (d in LEAGUES$div) {
    f <- file.path("data/raw", sprintf("fd_%s_%s.csv", s, d))
    if (force || !file.exists(f)) {
      url <- sprintf("%s/%s/%s.csv", FD_BASE, s, d)
      ok <- tryCatch({
        utils::download.file(url, f, quiet = TRUE); TRUE
      }, error = function(e) FALSE)
      if (!ok) next
    }
    x <- tryCatch(suppressWarnings(
      read_csv(f, show_col_types = FALSE, progress = FALSE,
               name_repair = "minimal")), error = function(e) NULL)
    if (is.null(x) || !all(c("HomeTeam", "AwayTeam", "FTHG", "FTAG") %in% names(x)))
      next
    x <- x[, c("Div", "Date", "HomeTeam", "AwayTeam", "FTHG", "FTAG")]
    names(x) <- c("div", "date", "home", "away", "hs", "as")
    rows[[length(rows) + 1L]] <- x |> mutate(season = s)
  }
  bind_rows(rows) |>
    mutate(
      date = parse_fd_date(date),
      hs = suppressWarnings(as.integer(hs)),
      as = suppressWarnings(as.integer(as))
    ) |>
    filter(!is.na(date), !is.na(hs), !is.na(as), !is.na(home), !is.na(away)) |>
    mutate(comp = "domestic", neutral = FALSE)
}

# ---- european bridge --------------------------------------------------------

# One result line looks like either
#   "  18:45  Juventus FC (ITA)  v Borussia Dortmund (GER)  4-4 (0-0)"
# or, when a tie needed extra time / penalties,
#   "  Liverpool FC (ENG) v PSG (FRA)  1-4 pen. 0-1 a.e.t. (0-1, 0-1)"
# Dixon-Coles models REGULATION time, so we always take the 90-minute score:
# the last score inside the parentheses when a.e.t. is present, otherwise the
# headline score (the parenthesised value is then just half-time).
MATCH_RE <- paste0(
  "^\\s*(?:\\d{1,2}:\\d{2}\\s+)?",
  "(.+?)\\s*\\(([A-Z]{3})\\)\\s+v\\s+",
  "(.+?)\\s*\\(([A-Z]{3})\\)\\s+",
  "(\\d+)-(\\d+)(.*)$"
)

parse_ucl_file <- function(txt, season) {
  lines <- strsplit(txt, "\n", fixed = TRUE)[[1]]
  cur_date <- NA
  out <- list()
  for (ln in lines) {
    # date headers: "  Tue Sep 16 2025" or "  Wed Sep 17"
    dm <- str_match(ln, "^\\s*[A-Z][a-z]{2}\\s+([A-Z][a-z]{2})\\s+(\\d{1,2})(?:\\s+(\\d{4}))?\\s*$")
    if (!is.na(dm[1, 1])) {
      # A European season spans two calendar years. Rather than tracking state
      # (which drifts), derive the year from the month: Jul-Dec belong to the
      # first year of the season, Jan-Jun to the second.
      yr <- dm[1, 4]
      if (is.na(yr)) {
        y1 <- as.integer(substr(season, 1, 4))
        mon <- match(dm[1, 2], month.abb)
        yr <- as.character(if (!is.na(mon) && mon <= 6L) y1 + 1L else y1)
      }
      d <- as.Date(paste(yr, dm[1, 2], dm[1, 3]), format = "%Y %b %d")
      if (!is.na(d)) cur_date <- d
      next
    }
    m <- str_match(ln, MATCH_RE)
    if (is.na(m[1, 1])) next
    tail_txt <- m[1, 8]
    hs <- as.integer(m[1, 6]); as_ <- as.integer(m[1, 7])
    if (grepl("a\\.e\\.t\\.", tail_txt)) {
      # take the LAST "n-n" inside the trailing parentheses = 90-minute score
      inner <- str_match(tail_txt, "\\(([^)]*)\\)\\s*$")[1, 2]
      if (!is.na(inner)) {
        sc <- str_match_all(inner, "(\\d+)-(\\d+)")[[1]]
        if (nrow(sc)) {
          hs <- as.integer(sc[nrow(sc), 2]); as_ <- as.integer(sc[nrow(sc), 3])
        }
      }
    }
    out[[length(out) + 1L]] <- tibble(
      date = cur_date, home = str_squish(m[1, 2]), home_cc = m[1, 3],
      away = str_squish(m[1, 4]), away_cc = m[1, 5], hs = hs, as = as_,
      season = season
    )
  }
  bind_rows(out)
}

#' Download + parse the European bridge matches (UCL proper + qualifiers).
load_bridge <- function(force = FALSE) {
  rows <- list()
  for (s in UCL_SEASONS) for (fn in c("cl", "clq", "elq", "confq")) {
    f <- file.path("data/raw", sprintf("ucl_%s_%s.txt", s, fn))
    if (force || !file.exists(f)) {
      url <- sprintf("%s/%s/%s.txt", OF_BASE, s, fn)
      ok <- tryCatch({
        utils::download.file(url, f, quiet = TRUE); TRUE
      }, error = function(e) FALSE)
      if (!ok) next
    }
    txt <- tryCatch(readr::read_file(f), error = function(e) "")  # UTF-8 safe
    if (!nzchar(txt)) next
    p <- parse_ucl_file(txt, s)
    if (nrow(p)) rows[[length(rows) + 1L]] <- p |> mutate(comp_file = fn)
  }
  bind_rows(rows) |>
    filter(!is.na(hs), !is.na(as), !is.na(date)) |>
    mutate(comp = "european", neutral = FALSE)
}

# ---- cross-source club matching --------------------------------------------

#' Match European-source club names onto domestic-source club names.
#' Matching is done WITHIN a country (a Spanish club can only match a La Liga
#' club), first on the normalized key, then on token containment, then on edit
#' distance with a conservative threshold. Unmatched clubs are kept and pooled
#' later as rest-of-Europe rather than silently dropped.
#' @return tibble(eu_name, cc, div, fd_name, method, score).
build_club_map <- function(domestic, bridge) {
  fd <- domestic |>
    distinct(div, team = home) |>
    bind_rows(distinct(domestic, div, team = away)) |>
    distinct(div, team) |>
    mutate(key = norm_club(team))
  eu <- bind_rows(
    bridge |> distinct(cc = home_cc, team = home),
    bridge |> distinct(cc = away_cc, team = away)
  ) |> distinct(cc, team) |> mutate(key = norm_club(team))

  cc2div <- setNames(LEAGUES$div, LEAGUES$cc)
  cc2div <- c(cc2div, CC_OVERRIDE)

  res <- lapply(seq_len(nrow(eu)), function(i) {
    cc <- eu$cc[i]; k <- eu$key[i]
    div <- unname(cc2div[cc])
    if (is.na(div)) return(tibble(eu_name = eu$team[i], cc = cc, div = NA,
                                  fd_name = NA, method = "no_league", score = NA))
    cand <- fd |> filter(div == !!div)
    if (!nrow(cand)) return(tibble(eu_name = eu$team[i], cc = cc, div = div,
                                   fd_name = NA, method = "no_cand", score = NA))
    # 1. explicit alias (hand-verified; the only safe way to resolve the
    #    source's abbreviations, e.g. "Paris Saint-Germain" -> "Paris SG"
    #    when "Paris FC" is a DIFFERENT club in the same league)
    akey <- paste(div, k, sep = "|")
    al <- if (akey %in% names(CLUB_ALIAS)) unname(CLUB_ALIAS[akey]) else NULL
    if (!is.null(al) && al %in% cand$team)
      return(tibble(eu_name = eu$team[i], cc = cc, div = div,
                    fd_name = al, method = "alias", score = 0))
    # 2. exact normalized key
    hit <- cand$team[cand$key == k]
    if (length(hit) == 1L)
      return(tibble(eu_name = eu$team[i], cc = cc, div = div,
                    fd_name = hit[1], method = "exact", score = 0))
    # 3. edit distance -- strict, and only when the winner is UNAMBIGUOUS
    #    (clearly better than the runner-up). Ambiguous near-ties are left
    #    unmatched for a human to alias rather than guessed at.
    d <- as.numeric(adist(k, cand$key, ignore.case = TRUE))
    rel <- d / pmax(nchar(k), nchar(cand$key))
    o <- order(rel)
    best <- rel[o[1]]
    runner <- if (length(o) > 1L) rel[o[2]] else Inf
    if (best <= 0.20 && runner - best >= 0.10)
      return(tibble(eu_name = eu$team[i], cc = cc, div = div,
                    fd_name = cand$team[o[1]], method = "fuzzy", score = best))
    tibble(eu_name = eu$team[i], cc = cc, div = div, fd_name = NA,
           method = "unmatched", score = best)
  })
  bind_rows(res)
}

# ---- main -------------------------------------------------------------------

ingest_all <- function(force = FALSE) {
  dir.create("data/raw", recursive = TRUE, showWarnings = FALSE)
  message("Loading domestic leagues ...")
  dom <- load_domestic(force)
  message("Loading European bridge ...")
  br <- load_bridge(force)
  message("Matching club identities across sources ...")
  cmap <- build_club_map(dom, br)

  saveRDS(dom, "data/domestic.rds")
  saveRDS(br, "data/bridge.rds")
  saveRDS(cmap, "data/club_map.rds")

  message(sprintf("\nDomestic: %s matches, %d leagues, %s..%s",
                  format(nrow(dom), big.mark = ","), n_distinct(dom$div),
                  min(dom$date), max(dom$date)))
  message(sprintf("Bridge  : %s matches, %s..%s",
                  format(nrow(br), big.mark = ","), min(br$date), max(br$date)))
  meth <- cmap |> count(method, sort = TRUE)
  message("Club-name match methods:")
  print(as.data.frame(meth), row.names = FALSE)
  invisible(list(domestic = dom, bridge = br, club_map = cmap))
}

if (sys.nframe() == 0L) {
  source("R/utils.R")
  ingest_all(force = identical(Sys.getenv("UCL_FORCE_INGEST"), "1"))
}
