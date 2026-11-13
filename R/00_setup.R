# 00_setup.R
# Packages, settings, and the player-season table used by every other script.

suppressPackageStartupMessages({
  library(Lahman)    # season-level MLB data through 2025
  library(dplyr)
  library(tidyr)
  library(ggplot2)
  library(brms)      # Bayesian models fit in Stan
})

SEASONS      <- 2015:2025
TRAIN_YEARS  <- 2018:2024   # seasons the forecasting models learn from
TEST_YEAR    <- 2025        # held-out season used to score forecasts
MIN_TEST_PA  <- 200         # hitters scored in the backtest need this many 2025 PA...
MIN_PRIOR_PA <- 100         # ...and this many 2024 PA

# The four outcomes studied. Each is a count of successes out of a number of trials.
#   K%    = strikeouts / plate appearances
#   BB%   = walks / plate appearances
#   HR%   = home runs / plate appearances
#   BABIP = hits on balls in play / balls in play
STATS <- tibble::tribble(
  ~stat,   ~label,  ~success, ~trials,
  "k",     "K%",    "SO",     "PA",
  "bb",    "BB%",   "BB",     "PA",
  "hr",    "HR%",   "HR",     "PA",
  "babip", "BABIP", "H_BIP",  "BIP"
)

# ---- Player-season table -------------------------------------------------------
# Players traded mid-season appear once per team ("stint"), so sum stints first.
batting <- Batting |>
  filter(yearID %in% SEASONS) |>
  group_by(playerID, yearID) |>
  summarise(across(c(G, AB, H, HR, BB, SO, HBP, SH, SF), \(x) sum(x, na.rm = TRUE)),
            .groups = "drop") |>
  mutate(
    PA    = AB + BB + HBP + SH + SF,
    BIP   = AB - SO - HR + SF,       # balls in play
    H_BIP = H - HR                   # hits on balls in play
  )

# Remove pitchers batting: players who spent most of their games on the mound.
pitchers <- Appearances |>
  filter(yearID %in% SEASONS) |>
  group_by(playerID, yearID) |>
  summarise(G_all = sum(G_all), G_p = sum(G_p), .groups = "drop") |>
  filter(G_p > 0.5 * G_all) |>
  select(playerID, yearID)

# Baseball age = age on July 1 of the season (the standard convention).
ages <- People |>
  select(playerID, nameFirst, nameLast, birthYear, birthMonth) |>
  mutate(name = paste(nameFirst, nameLast))

player_seasons <- batting |>
  anti_join(pitchers, by = c("playerID", "yearID")) |>
  inner_join(ages, by = "playerID") |>
  mutate(age = yearID - birthYear - (birthMonth >= 7)) |>
  filter(PA > 0, !is.na(age)) |>
  select(playerID, name, yearID, age, PA, AB, H, HR, BB, SO, HBP, SF, BIP, H_BIP)

# Long format: one row per player-season-stat, with successes (y) and trials (n).
to_long <- function(df) {
  purrr::pmap_dfr(STATS, function(stat, label, success, trials) {
    df |>
      transmute(playerID, name, yearID, age, PA,
                stat = stat, label = label,
                y = .data[[success]], n = .data[[trials]])
  }) |>
    filter(n > 0)
}
player_stats <- to_long(player_seasons)

# League rate by season, used for the simple benchmark forecasts.
league_rates <- player_stats |>
  group_by(stat, yearID) |>
  summarise(league_rate = sum(y) / sum(n), .groups = "drop")
