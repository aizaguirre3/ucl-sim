#!/usr/bin/env Rscript
# 01_current_season.R --------------------------------------------------------
# Fill the CURRENT-season gap that football-data.co.uk cannot (it has been
# returning HTTP 503) by pulling 2026-27 domestic results from openfootball.
#
# SAFETY MODEL -- this code fetches data from the public internet, so the
# guardrails below are enforced in code, not assumed:
#
#   1. ALLOWLIST      Only the exact URLs in SOURCES are ever fetched. No URL is
#                     built from external input, and every one is asserted to be
#                     on https://raw.githubusercontent.com/openfootball/ before
#                     the request is made.
#   2. TEXT ONLY      Files are plain .txt. They are read as text and parsed with
#                     regexes. Nothing downloaded is EVER source()'d, eval()'d,
#                     parse()'d, deserialized, or handed to system(). There is no
#                     code path by which remote content can execute.
#   3. SIZE CAP       Anything over MAX_BYTES (2 MB) is rejected and deleted.
#                     Real files are ~20 KB.
#   4. SANDBOXED      Writes go only to data/raw/ inside the project. No archive
#                     extraction, no executable bits, nothing written outside.
#   5. VALIDATED      Parsed rows must pass structural checks (plausible dates,
#                     sane scores, sane match counts) before they are allowed to
#                     reach the model. A file failing validation is discarded.
#   6. NO OVERLAP     Only matches strictly AFTER the existing football-data
#                     history are accepted, so new data can never silently
#                     duplicate or contradict rows we already trust.
#
# Licence: openfootball data is public domain (CC0).
# -----------------------------------------------------------------------------

suppressMessages({
  library(dplyr)
  library(stringr)
  library(readr)
})

ALLOWED_PREFIX <- "https://raw.githubusercontent.com/openfootball/"
MAX_BYTES <- 2e6
SEASON <- "2026-27"

# Exact, hard-coded sources. Turkey / Greece / Scotland are absent because
# openfootball has not published their 2026-27 files yet.
SOURCES <- tribble(
  ~div,  ~url,
  "E0",  "https://raw.githubusercontent.com/openfootball/england/master/2026-27/1-premierleague.txt",
  "D1",  "https://raw.githubusercontent.com/openfootball/deutschland/master/2026-27/1-bundesliga.txt",
  "SP1", "https://raw.githubusercontent.com/openfootball/espana/master/2026-27/1-liga.txt",
  "I1",  "https://raw.githubusercontent.com/openfootball/italy/master/2026-27/1-seriea.txt",
  "B1",  "https://raw.githubusercontent.com/openfootball/belgium/master/2026-27/be1.txt",
  "F1",  "https://raw.githubusercontent.com/openfootball/europe/master/france/2026-27_fr1.txt",
  "N1",  "https://raw.githubusercontent.com/openfootball/europe/master/netherlands/2026-27_nl1.txt",
  "P1",  "https://raw.githubusercontent.com/openfootball/europe/master/portugal/2026-27_pt1.txt"
)

# Guardrail 1: refuse anything not on the allowlisted host/org.
.assert_allowed <- function(url) {
  if (!startsWith(url, ALLOWED_PREFIX))
    stop("BLOCKED: refusing to fetch off-allowlist URL: ", url)
  if (grepl("\\.\\.", url, fixed = TRUE))
    stop("BLOCKED: path traversal in URL: ", url)
  invisible(TRUE)
}

# Guardrail 3/4: download to the project sandbox, cap the size.
.safe_fetch <- function(url, dest, force = FALSE) {
  .assert_allowed(url)
  if (!force && file.exists(dest) && file.info(dest)$size > 0) return(TRUE)
  ok <- tryCatch({ utils::download.file(url, dest, quiet = TRUE); TRUE },
                 error = function(e) FALSE)
  if (!ok) return(FALSE)
  sz <- file.info(dest)$size
  if (is.na(sz) || sz <= 0 || sz > MAX_BYTES) {
    unlink(dest)
    warning("REJECTED (size ", sz, " bytes): ", url)
    return(FALSE)
  }
  Sys.chmod(dest, "0644")          # never executable
  TRUE
}

# Domestic result line, e.g.
#   "  20:00  Arsenal FC   v Coventry City FC   3-0 (2-0)"
# Same shape as the UCL files but WITHOUT the "(ENG)" country tags.
DOM_RE <- "^\\s*(?:\\d{1,2}:\\d{2}\\s+)?(.+?)\\s+v\\s+(.+?)\\s+(\\d+)-(\\d+)(.*)$"

#' Parse an openfootball domestic league file into matches.
#' Pure text -> data frame. Never evaluates the input.
parse_domestic_file <- function(txt, season, div) {
  lines <- strsplit(txt, "\n", fixed = TRUE)[[1]]
  y1 <- as.integer(substr(season, 1, 4))
  cur <- as.Date(NA); out <- list()
  for (ln in lines) {
    if (grepl("^\\s*[=#▪]", ln)) next          # headers / comments
    dm <- str_match(ln, "^\\s*[A-Z][a-z]{2}\\s+([A-Z][a-z]{2})\\s+(\\d{1,2})(?:\\s+(\\d{4}))?\\s*$")
    if (!is.na(dm[1, 1])) {
      yr <- dm[1, 4]
      if (is.na(yr)) {
        mon <- match(dm[1, 2], month.abb)
        yr <- as.character(if (!is.na(mon) && mon <= 6L) y1 + 1L else y1)
      }
      d <- as.Date(paste(yr, dm[1, 2], dm[1, 3]), format = "%Y %b %d")
      if (!is.na(d)) cur <- d
      next
    }
    m <- str_match(ln, DOM_RE)
    if (is.na(m[1, 1])) next
    hs <- as.integer(m[1, 4]); as_ <- as.integer(m[1, 5])
    # if extra time is annotated, prefer the 90-minute score in parentheses
    if (grepl("a\\.e\\.t\\.", m[1, 6])) {
      inner <- str_match(m[1, 6], "\\(([^)]*)\\)\\s*$")[1, 2]
      if (!is.na(inner)) {
        sc <- str_match_all(inner, "(\\d+)-(\\d+)")[[1]]
        if (nrow(sc)) { hs <- as.integer(sc[nrow(sc), 2]); as_ <- as.integer(sc[nrow(sc), 3]) }
      }
    }
    out[[length(out) + 1L]] <- tibble(date = cur, div = div,
                                      home_raw = str_squish(m[1, 2]),
                                      away_raw = str_squish(m[1, 3]),
                                      hs = hs, as = as_)
  }
  bind_rows(out)
}

# Guardrail 5: structural validation. A file that fails is discarded whole.
.validate <- function(df, div) {
  if (!nrow(df)) return(list(ok = FALSE, why = "no parsable rows"))
  bad <- c(
    if (any(is.na(df$date))) "missing dates",
    if (any(df$date < as.Date("2026-06-01") | df$date > as.Date("2027-08-01"), na.rm = TRUE))
      "dates outside the 2026-27 season window",
    if (any(df$hs < 0 | df$hs > 20 | df$as < 0 | df$as > 20, na.rm = TRUE))
      "implausible scores",
    if (any(!nzchar(df$home_raw)) || any(!nzchar(df$away_raw))) "empty team names",
    if (any(df$home_raw == df$away_raw)) "team playing itself",
    if (nrow(df) > 800) "implausibly many matches"
  )
  if (length(bad)) list(ok = FALSE, why = paste(bad, collapse = "; "))
  else list(ok = TRUE, why = "")
}

#' Map openfootball club names onto the football-data identities already in the
#' model, per league. Unmatched names are KEPT as new clubs (a promoted side
#' genuinely is new) but are reported so identity splits can be caught.
map_domestic_names <- function(names_raw, div, fd_teams) {
  key <- norm_club(names_raw)
  cand <- tibble(team = fd_teams, k = norm_club(fd_teams))
  cand_tok <- strsplit(cand$k, " ")
  res <- lapply(seq_along(names_raw), function(i) {
    mk <- function(m, meth) tibble(raw = names_raw[i], mapped = m, method = meth)
    ak <- paste(div, key[i], sep = "|")
    if (ak %in% names(CLUB_ALIAS)) {
      al <- unname(CLUB_ALIAS[ak])
      if (al %in% cand$team) return(mk(al, "alias"))
    }
    hit <- cand$team[cand$k == key[i]]
    if (length(hit) == 1L) return(mk(hit, "exact"))
    # Token containment, but ONLY when exactly one candidate qualifies.
    # "Genoa CFC" -> "Genoa", "AZ" -> "AZ Alkmaar". Requiring whole-token
    # equality is far safer than edit distance, and the uniqueness test stops
    # a name from being claimed by two different clubs. The alias table is
    # checked first, which is what protects the Paris SG / Paris FC case.
    kt <- strsplit(key[i], " ")[[1]]
    contain <- vapply(cand_tok, function(ct)
      (length(kt) && all(ct %in% kt)) || (length(ct) && all(kt %in% ct)),
      logical(1))
    if (sum(contain) == 1L) return(mk(cand$team[which(contain)], "contain"))
    d <- as.numeric(adist(key[i], cand$k, ignore.case = TRUE))
    rel <- d / pmax(nchar(key[i]), nchar(cand$k))
    o <- order(rel)
    if (length(o) && rel[o[1]] <= 0.25 &&
        (length(o) < 2 || rel[o[2]] - rel[o[1]] >= 0.10))
      return(mk(cand$team[o[1]], "fuzzy"))
    mk(names_raw[i], "new")            # genuinely new club (e.g. promoted)
  })
  bind_rows(res)
}

#' Fetch + parse + validate the current season; returns matches strictly newer
#' than the existing football-data history.
ingest_current_season <- function(force = FALSE, verbose = TRUE) {
  dir.create("data/raw", recursive = TRUE, showWarnings = FALSE)
  dom <- readRDS("data/domestic.rds")
  cutoff <- max(dom$date)
  rows <- list(); report <- list(); decisions <- list()

  for (i in seq_len(nrow(SOURCES))) {
    div <- SOURCES$div[i]; url <- SOURCES$url[i]
    dest <- file.path("data/raw", sprintf("of_%s_%s.txt", SEASON, div))
    if (!.safe_fetch(url, dest, force)) {
      report[[length(report) + 1L]] <- tibble(div = div, n = 0L, status = "fetch failed")
      next
    }
    txt <- tryCatch(read_file(dest), error = function(e) "")
    p <- parse_domestic_file(txt, SEASON, div)
    v <- .validate(p, div)
    if (!v$ok) {
      report[[length(report) + 1L]] <- tibble(div = div, n = 0L,
                                              status = paste("REJECTED:", v$why))
      next
    }
    fd_teams <- sort(unique(c(dom$home[dom$div == div], dom$away[dom$div == div])))
    mh <- map_domestic_names(p$home_raw, div, fd_teams)
    ma <- map_domestic_names(p$away_raw, div, fd_teams)
    p$home <- mh$mapped; p$away <- ma$mapped
    dec <- bind_rows(mh, ma) |> distinct(raw, mapped, method) |> mutate(div = div)
    decisions[[length(decisions) + 1L]] <- dec
    p <- p |> filter(date > cutoff)                       # guardrail 6
    # Guardrail 7: some openfootball files are published SCHEDULES with no
    # results yet (Belgium's be1.txt is a fixture list). A file yielding almost
    # no scored matches is not a results feed -- reject it rather than let a
    # stray line in.
    if (nrow(p) < 5L) {
      report[[length(report) + 1L]] <- tibble(
        div = div, n = 0L, status = "REJECTED: fixtures-only (fewer than 5 results)")
      next
    }
    newclubs <- dec$raw[dec$method == "new"]
    rows[[length(rows) + 1L]] <- p |>
      transmute(date, div, home, away, hs, as, comp = "domestic")
    report[[length(report) + 1L]] <- tibble(
      div = div, n = nrow(p),
      status = if (length(newclubs))
        paste0("ok (new clubs: ", paste(newclubs, collapse = ", "), ")") else "ok")
  }

  cur <- bind_rows(rows)
  dec_all <- bind_rows(decisions)
  saveRDS(cur, "data/current_season.rds")
  saveRDS(dec_all, "data/current_season_namemap.rds")
  rep <- bind_rows(report)
  if (verbose) {
    message(sprintf("Current season (%s): %d matches after %s across %d leagues",
                    SEASON, nrow(cur), cutoff, n_distinct(cur$div)))
    print(as.data.frame(rep |> select(div, n)), row.names = FALSE)
    nx <- dec_all |> filter(method != "exact")
    message(sprintf("\nNon-exact name decisions to review (%d):", nrow(nx)))
    print(as.data.frame(nx |> arrange(method, div) |> select(div, raw, mapped, method)),
          row.names = FALSE)
    # collision check: two different raw names claiming the same club
    col <- dec_all |> filter(method != "new") |> count(div, mapped) |> filter(n > 1)
    message(sprintf("\nCollisions (two raw names -> one club): %d", nrow(col)))
    if (nrow(col)) print(as.data.frame(col), row.names = FALSE)
  }
  invisible(cur)
}

if (sys.nframe() == 0L) {
  source("R/utils.R"); source("R/00_ingest.R")
  ingest_current_season(force = identical(Sys.getenv("UCL_FORCE_INGEST"), "1"))
}
