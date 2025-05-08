# Load necessary libraries
library(dplyr)

# Read data from the input file
args <- commandArgs(trailingOnly = TRUE)
data_file <- args[1]

# Read the data into a dataframe
data <- read.table(data_file, sep=",", header=FALSE, stringsAsFactors=FALSE)

# Clean the data by stripping the labels and splitting values
data <- data %>%
  mutate(
    Start = as.numeric(gsub("Start: ", "", V1)),
    Length = as.numeric(gsub("Length: ", "", V2)),
    Dirty = as.logical(gsub("Dirty: ", "", V3)),
    Zero = as.logical(gsub("Zero: ", "", V4)),
    Date = gsub("Date: ", "", V5),
    Time = gsub("Time: ", "", V6)
  )

# Check if the data is valid
if (nrow(data) == 0) {
  stop("Error: No valid data available after cleaning.")
}

# Calculate Shannon Entropy only for 'Length'
calculate_entropy <- function(values) {
  prob <- table(values) / length(values)  # Frequency distribution
  entropy <- -sum(prob * log2(prob), na.rm = TRUE)  # Shannon entropy formula
  return(entropy)
}

# Entropy for Length only (ignore Dirty and Zero)
shannon_entropy_length <- calculate_entropy(data$Length)

# Metrics calculations
mean_block_size <- mean(data$Length, na.rm = TRUE)
variance <- var(data$Length, na.rm = TRUE)
std_deviation <- sd(data$Length, na.rm = TRUE)

# Calculate zeroed and dirty block ratios (still possible but not related to entropy)
zeroed_block_ratio <- sum(data$Zero, na.rm = TRUE) / nrow(data)
dirty_block_ratio <- sum(data$Dirty, na.rm = TRUE) / nrow(data)

# Print the results
cat("Shannon Entropy (Length):", shannon_entropy_length, "\n")
cat("Mean Block Size:", mean_block_size, "\n")
cat("Variance:", variance, "\n")
cat("Standard Deviation:", std_deviation, "\n")
cat("Zeroed Block Ratio:", zeroed_block_ratio, "\n")
cat("Dirty Block Ratio:", dirty_block_ratio, "\n")
