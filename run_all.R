# Runs the full analysis: data, stabilization points, Stan models, backtest, charts.
source("R/00_setup.R")
source("R/01_stabilization.R")
source("R/02_forecast_models.R")
source("R/03_figures.R")

dir.create("output", showWarnings = FALSE)
write.csv(stabilization, "output/stabilization_points.csv", row.names = FALSE)
write.csv(scores |> select(-model_label), "output/backtest_scores.csv", row.names = FALSE)
write.csv(coverage, "output/interval_coverage.csv", row.names = FALSE)
write.csv(variance_parts, "output/model_summary.csv", row.names = FALSE)
write.csv(surprises, "output/2025_changes_beyond_noise.csv", row.names = FALSE)
write.csv(forecasts, "output/forecasts_2025.csv", row.names = FALSE)
message("Done. Results in output/, charts in output/figures/.")
