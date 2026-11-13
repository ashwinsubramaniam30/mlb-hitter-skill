# 01_stabilization.R
# How many trials until a hitter's observed rate says more about skill than luck?
#
# Model: each hitter has a true rate p drawn from Beta(mu * M, (1 - mu) * M) across the
# league, and his observed count is Binomial(n, p). Fitting this beta-binomial model gives
# M, the "stabilization point": after M trials, half the spread in observed rates reflects
# real skill differences (reliability = n / (n + M) = 0.5).
# Fit separately for each season so league-wide changes don't inflate the spread.

MIN_TRIALS_STAB <- 50

betabinom_nll <- function(par, y, n) {
  mu <- plogis(par[1]); M <- exp(par[2])
  a <- mu * M; b <- (1 - mu) * M
  -sum(lchoose(n, y) + lbeta(y + a, n - y + b) - lbeta(a, b))
}

fit_betabinom <- function(y, n) {
  start <- c(qlogis(sum(y) / sum(n)), log(200))
  fit <- optim(start, betabinom_nll, y = y, n = n, method = "L-BFGS-B",
               lower = c(-10, log(1)), upper = c(10, log(1e5)), hessian = TRUE)
  se <- tryCatch(sqrt(diag(solve(fit$hessian))), error = \(e) c(NA, NA))
  tibble(mu = plogis(fit$par[1]), M = exp(fit$par[2]),
         M_lo = exp(fit$par[2] - 1.96 * se[2]), M_hi = exp(fit$par[2] + 1.96 * se[2]),
         players = length(y))
}

stabilization_by_season <- player_stats |>
  filter(n >= MIN_TRIALS_STAB) |>
  group_by(stat, label, yearID) |>
  group_modify(\(d, k) fit_betabinom(d$y, d$n)) |>
  ungroup()

# Summary across seasons (2020 excluded: 60-game season, very different sample sizes)
stabilization <- stabilization_by_season |>
  filter(yearID != 2020) |>
  group_by(stat, label) |>
  summarise(
    stabilization_point = median(M),
    low_season  = min(M),
    high_season = max(M),
    talent_sd   = median(sqrt(mu * (1 - mu) / (M + 1))),  # spread of true skill
    .groups = "drop"
  ) |>
  left_join(STATS |> select(stat, trials), by = "stat") |>
  arrange(stabilization_point)

# Reliability curve: share of observed variance that is skill, by trials.
reliability_curve <- stabilization |>
  select(stat, label, stabilization_point) |>
  tidyr::crossing(n = seq(0, 1000, by = 10)) |>
  mutate(reliability = n / (n + stabilization_point))
