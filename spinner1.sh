#!/bin/bash

#Argument
sleeper=$1

# Spinner function
spinner() {
    local pid=$!
    local delay=0.1
    local spinstr='|/-\\'
    while [ "$(ps a | awk '{print $1}' | grep $pid)" ]; do
        local temp=${spinstr#?}
        printf " [%c]  " "$spinstr"
        local spinstr=$temp${spinstr%"$temp"}
        sleep $delay
        printf "\b\b\b\b\b\b"
    done
    printf "    \b\b\b\b"
}

# Simulate a long-running command in the background
(sleep $sleeper) &

# Call the spinner function to run while the long-running command is running
spinner

# Ensure the spinner stops after the long-running command completes
#wait

# Clear spinner residues from the screen
printf "\r    \r\n"

# Continue with the rest of the script
echo "Spinner Completed"


