# 03_figures.R
# Charts for the README and report.

FIG_DIR <- "output/figures"
dir.create(FIG_DIR, showWarnings = FALSE, recursive = TRUE)

NAVY <- "#0B2545"; ORANGE <- "#BF5700"; GREY <- "#8A94A6"
theme_report <- function() {
  theme_minimal(base_size = 11) +
    theme(plot.title = element_text(face = "bold", colour = NAVY, size = 12.5),
          plot.subtitle = element_text(colour = "grey40", size = 9),
          plot.caption = element_text(colour = "grey50", size = 8),
          panel.grid.minor = element_blank(),
          plot.title.position = "plot",
          legend.position = "bottom")
}
caption <- "Data: Lahman Baseball Database, 2015-2025"
stat_colours <- c("K%" = NAVY, "BB%" = "#3E7CB1", "HR%" = ORANGE, "BABIP" = GREY)

# 1. Reliability curves ------------------------------------------------------------
rel_labels <- stabilization |>
  mutate(key = paste0(label, " (", round(stabilization_point), " ", ifelse(trials == "BIP", "BIP", "PA"), ")"))
rel_key <- setNames(rel_labels$key, rel_labels$label)
p1 <- ggplot(reliability_curve, aes(n, reliability, colour = label)) +
  geom_hline(yintercept = 0.5, linetype = "dashed", colour = "grey60") +
  geom_line(linewidth = 1.1) +
  geom_point(data = stabilization, aes(stabilization_point, 0.5), size = 3) +
  scale_colour_manual(values = stat_colours, labels = rel_key, breaks = names(rel_key), name = NULL) +
  scale_y_continuous(labels = scales::percent, limits = c(0, 1)) +
  labs(title = "Strikeout rate reflects skill about 9x sooner than BABIP",
       subtitle = "Share of the spread in observed rates that reflects true skill. Dots and legend = stabilization point (50% reliability)",
       x = "Trials (plate appearances; balls in play for BABIP)", y = "Reliability", caption = caption) +
  theme_report()
ggsave(file.path(FIG_DIR, "reliability_curves.png"), p1, width = 7.2, height = 3.8, dpi = 220, bg = "white")

# 2. Backtest results -----------------------------------------------------------------
p2_data <- scores |> filter(model != "last_season") |>
  mutate(label = factor(label, levels = stabilization$label))
p2 <- ggplot(p2_data, aes(vs_last_season, label, colour = model_label)) +
  geom_vline(xintercept = 0, colour = "grey60") +
  geom_point(size = 3.4, position = position_dodge(width = 0.65)) +
  scale_colour_manual(values = c("League average" = GREY,
                                 "Weighted 2022-24 + regressed" = "#3E7CB1",
                                 "Bayesian hierarchical (Stan)" = "#E8A06A",
                                 "Bayesian + skill drift (Stan)" = ORANGE), name = NULL) +
  scale_x_continuous(labels = scales::percent) +
  labs(title = "Pooling information beats taking last season at face value",
       subtitle = "Reduction in forecast error (RMSE) for 2025 rates vs. using each hitter's raw 2024 rate",
       x = "Error reduction vs. last season (higher is better)", y = NULL, caption = caption) +
  theme_report()
ggsave(file.path(FIG_DIR, "backtest_2025.png"), p2, width = 7.2, height = 3.6, dpi = 220, bg = "white")

# 3. Age curves from the Stan models ------------------------------------------------
age_grid <- tibble(age = 21:38, age_c = age - 28)
age_curves <- purrr::map_dfr(STATS$stat, function(s) {
  draws <- as_draws_df(fits_drift[[s]])
  eta <- outer(draws$b_Intercept, rep(1, nrow(age_grid))) +
    outer(draws$b_age_c, age_grid$age_c) + outer(draws$b_Iage_cE2, age_grid$age_c^2)
  p <- plogis(eta)
  rel_draws <- sweep(p, 1, plogis(draws$b_Intercept), "/")   # relative to age 28
  age_grid |> mutate(stat = s, rel = colMeans(rel_draws),
                     lo = apply(rel_draws, 2, quantile, 0.05),
                     hi = apply(rel_draws, 2, quantile, 0.95))
}) |> left_join(STATS |> select(stat, label), by = "stat")

p3 <- ggplot(age_curves, aes(age, rel, colour = label, fill = label)) +
  geom_hline(yintercept = 1, colour = "grey60") +
  geom_ribbon(aes(ymin = lo, ymax = hi), alpha = 0.15, colour = NA) +
  geom_line(linewidth = 1.1) +
  scale_colour_manual(values = stat_colours, name = NULL) +
  scale_fill_manual(values = stat_colours, name = NULL) +
  scale_y_continuous(labels = \(x) paste0(round(x * 100), "%")) +
  labs(title = "Estimated aging curves from the hierarchical model",
       subtitle = "Rate relative to the same hitter at age 28, with 90% credible bands",
       x = "Age", y = "Relative to age 28", caption = caption) +
  theme_report()
ggsave(file.path(FIG_DIR, "age_curves.png"), p3, width = 7.2, height = 3.6, dpi = 220, bg = "white")

# 4. Shrinkage example: HR% ---------------------------------------------------------
hr <- forecasts |> filter(stat == "hr") |>
  left_join(player_stats |> filter(yearID == TEST_YEAR - 1, stat == "hr") |>
              transmute(playerID, rate_2024 = y / n, pa_2024 = n), by = "playerID")
p4 <- ggplot(hr, aes(rate_2024, drift)) +
  geom_abline(slope = 1, intercept = 0, linetype = "dashed", colour = "grey60") +
  geom_point(aes(size = pa_2024), colour = NAVY, alpha = 0.45) +
  scale_size_area(max_size = 3.2, name = "2024 PA") +
  scale_x_continuous(labels = scales::percent) + scale_y_continuous(labels = scales::percent) +
  labs(title = "Extreme home run rates get pulled toward the middle",
       subtitle = "Raw 2024 HR% vs. 2025 forecast.\nDashed line = forecast equals last season",
       x = "2024 HR per PA", y = "Model forecast, 2025", caption = caption) +
  coord_equal() + theme_report()
ggsave(file.path(FIG_DIR, "hr_shrinkage.png"), p4, width = 6, height = 5.4, dpi = 220, bg = "white")
