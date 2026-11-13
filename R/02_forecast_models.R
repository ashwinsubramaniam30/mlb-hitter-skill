# 02_forecast_models.R
# Forecast each hitter's 2025 rates using only data through 2024, then score the
# forecasts against what actually happened in 2025.
#
# Four forecasts, from simplest to most complex:
#   1. League average   - everyone gets the 2024 league rate
#   2. Last season      - a hitter's raw 2024 rate
#   3. Weighted + regressed (empirical Bayes) - 2022-24 weighted 5/4/3 like Marcel,
#      then pulled toward the league rate by the stabilization point from 01_stabilization.R
#   4. Bayesian hierarchical model (Stan via brms) - partial pooling across players,
#      an age curve, season effects, and recent seasons weighted more heavily
#   5. Same model plus a player-season term, which lets a hitter's true skill drift from
#      year to year. Version 4's forecast intervals turned out too narrow (it assumed
#      skill is fixed); this version tests whether modeling drift fixes that.

MODEL_DIR <- "output/models"
dir.create(MODEL_DIR, showWarnings = FALSE, recursive = TRUE)

# ---- Test set: hitters with a real 2025 sample and a 2024 track record ----------
test_players <- player_seasons |>
  filter(yearID == TEST_YEAR, PA >= MIN_TEST_PA) |>
  semi_join(player_seasons |> filter(yearID == TEST_YEAR - 1, PA >= MIN_PRIOR_PA),
            by = "playerID") |>
  pull(playerID)

actual_2025 <- player_stats |>
  filter(yearID == TEST_YEAR, playerID %in% test_players) |>
  select(playerID, name, stat, label, age, y_2025 = y, n_2025 = n)

lg_2024 <- league_rates |> filter(yearID == TEST_YEAR - 1) |> select(stat, lg = league_rate)

# ---- Forecasts 1-3 -------------------------------------------------------------------
recent <- player_stats |>
  filter(playerID %in% test_players, yearID %in% (TEST_YEAR - 3):(TEST_YEAR - 1)) |>
  mutate(w = c(`2022` = 3, `2023` = 4, `2024` = 5)[as.character(yearID)])

simple_forecasts <- recent |>
  group_by(playerID, stat) |>
  summarise(
    last_rate = sum(y[yearID == TEST_YEAR - 1]) / sum(n[yearID == TEST_YEAR - 1]),
    wy = sum(w * y), wn = sum(w * n), .groups = "drop"
  ) |>
  left_join(lg_2024, by = "stat") |>
  left_join(stabilization |> select(stat, M = stabilization_point), by = "stat") |>
  transmute(playerID, stat,
            league_avg = lg,
            last_season = last_rate,
            weighted_regressed = (wy + M * lg) / (wn + M))

# ---- Forecast 4: Bayesian hierarchical model in Stan -------------------------------
# For each stat:  y ~ Binomial(n, p)
#   logit(p) = intercept + age curve (quadratic) + season effect + player effect
#   season effect ~ Normal(0, sigma_season); player effect ~ Normal(0, sigma_player)
# The player effect is "partially pooled": a hitter with few trials is pulled toward
# the league average, while one with many trials keeps more of his own rate.
# Season weights (0.75 per year back) let recent seasons count more, since skill drifts.
train <- player_stats |>
  filter(yearID %in% TRAIN_YEARS, n >= 5) |>
  mutate(age_c = age - 28,
         season = factor(yearID),
         wt = 0.75^(max(TRAIN_YEARS) - yearID))

priors <- c(
  prior(normal(0, 1.5), class = "Intercept"),
  prior(normal(0, 0.5), class = "b"),
  prior(exponential(2), class = "sd")
)

FORMULAS <- list(
  static = y | trials(n) + weights(wt) ~ age_c + I(age_c^2) + (1 | season) + (1 | playerID),
  drift  = y | trials(n) + weights(wt) ~ age_c + I(age_c^2) + (1 | season) + (1 | playerID) +
    (1 | playerID:season)
)

fit_stat <- function(s, version, template = NULL) {
  path <- file.path(MODEL_DIR, paste0("fit_", s, if (version == "drift") "_drift", ".rds"))
  if (file.exists(path)) return(readRDS(path))
  d <- filter(train, stat == s)
  fit <- if (is.null(template)) {
    brm(FORMULAS[[version]], data = d, family = binomial(), prior = priors,
        chains = 2, cores = 2, iter = 1500, warmup = 500, seed = 2025,
        refresh = 0, silent = 2)
  } else {
    update(template, newdata = d, recompile = FALSE, seed = 2025, refresh = 0, silent = 2)
  }
  saveRDS(fit, path)
  fit
}

fits <- list(); fits_drift <- list()
for (s in STATS$stat) {
  message("Fitting ", s, " (static) ...")
  fits[[s]] <- fit_stat(s, "static", template = if (length(fits)) fits[[1]] else NULL)
  message("Fitting ", s, " (drift) ...")
  fits_drift[[s]] <- fit_stat(s, "drift", template = if (length(fits_drift)) fits_drift[[1]] else NULL)
}

# Predict 2025: the player's own effect plus the age curve at his 2025 age, averaged
# over seasons (a new season's effect is unknown before it happens). For the drift model,
# 2025 is a new player-season, so its drift term is drawn from the fitted distribution.
predict_2025 <- function(fit_list, prefix, drift = FALSE) {
  purrr::map_dfr(STATS$stat, function(s) {
    nd <- actual_2025 |> filter(stat == s) |>
      mutate(age_c = age - 28, n = n_2025, wt = 1, season = factor(TEST_YEAR))
    ref <- if (drift) ~ (1 | playerID) + (1 | playerID:season) else ~ (1 | playerID)
    args <- list(object = fit_list[[s]], newdata = nd, re_formula = ref,
                 allow_new_levels = TRUE, sample_new_levels = "gaussian")
    # posterior_epred returns expected counts (draws x hitters); divide each column by its trials
    p_draws <- sweep(do.call(posterior_epred, args), 2, nd$n, "/")
    y_draws <- do.call(posterior_predict, args)
    out <- nd |> transmute(
      playerID, stat,
      pred = colMeans(p_draws),
      # 80% interval for the *observed* 2025 rate (skill uncertainty + binomial noise)
      pred_lo = apply(y_draws, 2, quantile, 0.1) / n,
      pred_hi = apply(y_draws, 2, quantile, 0.9) / n
    )
    names(out)[3:5] <- paste0(prefix, c("", "_lo", "_hi"))
    out
  })
}
bayes_forecasts <- predict_2025(fits, "bayes") |>
  left_join(predict_2025(fits_drift, "drift", drift = TRUE), by = c("playerID", "stat"))

forecasts <- actual_2025 |>
  left_join(simple_forecasts, by = c("playerID", "stat")) |>
  left_join(bayes_forecasts, by = c("playerID", "stat")) |>
  mutate(actual = y_2025 / n_2025)

# ---- Scoring ---------------------------------------------------------------------
# Trial-weighted RMSE between forecast and actual 2025 rate. Even a perfect forecast
# of true skill can't reach zero, because 2025 results include binomial luck; the
# "noise floor" is that unavoidable error, estimated from the Bayesian forecasts.
model_labels <- c(league_avg = "League average", last_season = "Last season (raw 2024)",
                  weighted_regressed = "Weighted 2022-24 + regressed",
                  bayes = "Bayesian hierarchical (Stan)",
                  drift = "Bayesian + skill drift (Stan)")

scores <- forecasts |>
  pivot_longer(all_of(names(model_labels)), names_to = "model", values_to = "pred") |>
  group_by(stat, label, model) |>
  summarise(rmse = sqrt(weighted.mean((pred - actual)^2, n_2025)), .groups = "drop") |>
  left_join(
    forecasts |> group_by(stat) |>
      summarise(noise_floor = sqrt(weighted.mean(drift * (1 - drift) / n_2025, n_2025)),
                hitters = n()),
    by = "stat") |>
  group_by(stat) |>
  mutate(vs_last_season = 1 - rmse / rmse[model == "last_season"]) |>
  ungroup() |>
  mutate(model_label = factor(model_labels[model], levels = model_labels))

# Calibration: share of hitters whose actual 2025 rate fell inside each model's 80% interval
coverage <- forecasts |>
  group_by(stat, label) |>
  summarise(static_80 = mean(actual >= bayes_lo & actual <= bayes_hi),
            drift_80  = mean(actual >= drift_lo & actual <= drift_hi), .groups = "drop")

# Model summaries: how much of the spread is player skill vs. season-to-season shifts
variance_parts <- purrr::map_dfr(STATS$stat, function(s) {
  f <- fits_drift[[s]]; vc <- VarCorr(f)
  tibble(stat = s,
         sd_player = vc$playerID$sd[1, "Estimate"],         # stable skill differences
         sd_drift  = vc$`playerID:season`$sd[1, "Estimate"],# year-to-year skill changes
         sd_season = vc$season$sd[1, "Estimate"],           # league-wide shifts
         age_linear = fixef(f)["age_c", "Estimate"],
         age_quad = fixef(f)["Iage_cE2", "Estimate"],
         max_rhat = max(brms::rhat(f), na.rm = TRUE),
         min_ess_ratio = min(brms::neff_ratio(f), na.rm = TRUE))
})

# ---- 2025 changes beyond what luck explains ----------------------------------------
# Hitters whose 2025 rate landed outside the model's 80% predictive interval, ranked by
# how far outside. These are the changes most likely to be real (new approach, injury,
# aging) rather than noise, and worth a closer look from scouts and coaches.
surprises <- forecasts |>
  filter(stat %in% c("k", "hr")) |>
  mutate(miss = case_when(actual > drift_hi ~ actual - drift_hi,
                          actual < drift_lo ~ actual - drift_lo,
                          TRUE ~ 0),
         z = (actual - drift) / sqrt(drift * (1 - drift) / n_2025)) |>
  filter(miss != 0) |>
  arrange(desc(abs(z))) |>
  group_by(stat) |>
  slice_head(n = 5) |>
  ungroup() |>
  select(label, name, age, PA = n_2025, forecast = drift, actual,
         interval_lo = drift_lo, interval_hi = drift_hi, z)
