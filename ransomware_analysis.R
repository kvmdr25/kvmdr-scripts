# Load necessary libraries
library(dplyr)

# Read data from the input file
args <- commandArgs(trailingOnly = TRUE)
data_file <- args[1]

# Read the data into a dataframe
data <- read.table(data_file, sep=",", header=FALSE, stringsAsFactors=FALSE)

# Clean and convert data
data <- data %>%
  mutate(
    Start = as.numeric(gsub("Start: ", "", V1)),
    Length = as.numeric(gsub("Length: ", "", V2)),
    Dirty = tolower(trimws(gsub("Dirty: ", "", V3))) == "true",
    Zero = tolower(trimws(gsub("Zero: ", "", V4))) == "true",
    Date = gsub("Date: ", "", V5),
    Time = gsub("Time: ", "", V6)
  )

# Validate data
if (nrow(data) == 0) {
  stop("Error: No valid data available after cleaning.")
}

# Calculate Shannon Entropy for Length
calculate_entropy <- function(values) {
  prob <- table(values) / length(values)
  entropy <- -sum(prob * log2(prob), na.rm = TRUE)
  return(entropy)
}

shannon_entropy_length <- calculate_entropy(data$Length)

# Metrics calculations
mean_block_size <- mean(data$Length, na.rm = TRUE)
variance <- var(data$Length, na.rm = TRUE)
std_deviation <- sd(data$Length, na.rm = TRUE)

total_size <- sum(data$Length, na.rm = TRUE)

# Zeroed and dirty block ratios based on total length
zeroed_block_ratio <- ifelse(total_size > 0,
                             sum(data$Length[data$Zero == TRUE], na.rm = TRUE) / total_size, 0)
dirty_block_ratio <- ifelse(total_size > 0,
                            sum(data$Length[data$Dirty == TRUE], na.rm = TRUE) / total_size, 0)

# ======================
# Weighted Entropy Score (Consensus Average)
# ======================

# Consensus weights
w_shannon_entropy <- 0.35
w_dirty_block_ratio <- 0.28
w_zeroed_block_ratio <- 0.15
w_variance <- 0.10
w_std_deviation <- 0.10
w_mean_block_size <- 0.05

# Normalize metrics
normalized_shannon_entropy <- shannon_entropy_length / 8  # Max entropy for 8-bit
normalized_mean_block_size <- mean_block_size / max(mean_block_size, na.rm = TRUE)
normalized_variance <- variance / max(variance, na.rm = TRUE)
normalized_std_dev <- std_deviation / max(std_deviation, na.rm = TRUE)

# Calculate final entropy score
entropy_score <- round(
  (w_shannon_entropy * normalized_shannon_entropy) +
  (w_dirty_block_ratio * dirty_block_ratio) +
  (w_zeroed_block_ratio * zeroed_block_ratio) +
  (w_variance * normalized_variance) +
  (w_std_deviation * normalized_std_dev) +
  (w_mean_block_size * normalized_mean_block_size),
  5
)

# Print the results
cat("Shannon Entropy (Length):", round(shannon_entropy_length, 5), "\n")
cat("Mean Block Size:", round(mean_block_size, 5), "\n")
cat("Variance:", format(variance, scientific = TRUE, digits = 5), "\n")
cat("Standard Deviation:", round(std_deviation, 5), "\n")
cat("Zeroed Block Ratio:", round(zeroed_block_ratio, 5), "\n")
cat("Dirty Block Ratio:", round(dirty_block_ratio, 5), "\n")
cat("Weighted Entropy Score:", entropy_score, "\n")
