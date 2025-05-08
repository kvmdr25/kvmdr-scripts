# Load required libraries
library(dplyr)
library(ggplot2)
library(isotree)  # Use isotree for Isolation Forest
library(zoo)
library(scales)

# Read arguments for input file and output path
args <- commandArgs(trailingOnly = TRUE)
input_file <- args[1]
graph_path <- args[2]

# Read the data
data <- read.csv(input_file, header = TRUE, stringsAsFactors = FALSE)

# Parse timestamp correctly
data <- data %>%
  mutate(
    timestamp = as.POSIXct(as.character(timestamp), format = "%Y%m%d%H%M%S", tz = "UTC")
  )

# Check for empty data
if (nrow(data) == 0) {
  stop("Error: No data found.")
}

# Feature engineering
data <- data %>%
  arrange(timestamp) %>%
  mutate(
    delta_entropy = c(0, diff(entropy_score)),
    delta_dirty = c(0, diff(dirty_block_ratio)),
    delta_zeroed = c(0, diff(zeroed_block_ratio)),
    delta_variance = c(0, diff(variance)),
    delta_std_dev = c(0, diff(std_deviation)),
    delta_mean_block = c(0, diff(mean_block_size)),
    time_diff = c(0, diff(as.numeric(timestamp)))
  )

# Normalize all features
normalize <- function(x) {
  return((x - min(x, na.rm = TRUE)) / (max(x, na.rm = TRUE) - min(x, na.rm = TRUE)))
}

data_norm <- data %>%
  mutate(
    entropy_score = normalize(entropy_score),
    dirty_block_ratio = normalize(dirty_block_ratio),
    zeroed_block_ratio = normalize(zeroed_block_ratio),
    variance = normalize(variance),
    std_deviation = normalize(std_deviation),
    mean_block_size = normalize(mean_block_size),
    delta_entropy = normalize(delta_entropy),
    delta_dirty = normalize(delta_dirty),
    delta_zeroed = normalize(delta_zeroed),
    delta_variance = normalize(delta_variance),
    delta_std_dev = normalize(delta_std_dev),
    delta_mean_block = normalize(delta_mean_block),
    time_diff = normalize(time_diff)
  )

# Remove timestamp for model training
dataset <- data_norm %>% select(-timestamp)

# Train Isolation Forest model using isotree
model <- isolation.forest(dataset, ntrees = 100)

# Compute anomaly scores for the data
anomaly_scores <- predict(model, dataset)

# Add the anomaly score to the data
data$anomaly_score <- anomaly_scores$anomaly

# Graph anomaly score over time
plot_file <- file.path(graph_path, "anomaly_score_plot.png")
p <- ggplot(data, aes(x = timestamp, y = anomaly_score)) +
  geom_line(color = "red") +
  labs(title = "Anomaly Score Over Time", x = "Timestamp", y = "Anomaly Score") +
  theme_minimal()

ggsave(plot_file, plot = p, width = 10, height = 6)

# Output final results
cat("Anomaly Score Analysis Completed\n")
cat(paste("Graph saved at:", plot_file, "\n"))
cat(paste("Latest Anomaly Score:", tail(data$anomaly_score, 1), "\n"))
