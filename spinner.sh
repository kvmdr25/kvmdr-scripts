#!/bin/bash

# Spinner function
spinner() {
  local pid=$!  # Capture current process ID
  local delay=0.75  # Delay between spins in seconds
  local spinstr='|/-\\'  # Characters for the spinner animation

  # Loop until the current process (the script calling spinner) finishes
  while [ "$(ps a | awk '{print $1}' | grep $pid)" ]; do
    local temp=${spinstr#?}  # Remove first character from spinstr
    printf " [%c]  " "$spinstr"  # Print the current spin character
    local spinstr=$temp${spinstr%"$temp"}  # Rotate characters
    sleep $delay  # Wait for the delay
    printf "\b\b\b\b\b\b\b"  # Move cursor back to overwrite previous output
  done
  printf "      \b\b\b\b\b\b"  # Clear any remaining spinner characters
}

# This line calls the spinner function with an error (missing parentheses)
# spinner  # Corrected version is below
spinner &  # Call the function in the background and add missing parentheses

