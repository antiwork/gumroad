#!/bin/bash

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NO_COLOR='\033[0m'

# Helper functions
print_message() { echo -e "\n${1}${2}${NO_COLOR}\n"; }
error_message() { print_message "${RED}" "Error: $1"; }
warning_message() { print_message "${YELLOW}" "Warning: $1"; }
success_message() { print_message "${GREEN}" "$1"; }

# Function to get PR diff and local changes
get_combined_diff() {
  {
    git diff --cached
    git diff
    gh pr diff
  } | awk '/^diff --git/ {in_folder=($0 ~ " b/(app|config|db|scripts)/| b/[^/]+$")} in_folder {print}'
}

# Function to get all spec files
get_all_spec_files() {
  find spec -name '*_spec.rb' | sort
}

# Function to determine which spec files to run based on confidence level
determine_spec_files() {
  local confidence_level=$1
  local combined_diff=$(get_combined_diff)
  local all_spec_files=$(get_all_spec_files)

  local system_content="You are an expert software engineer that determines which spec files should be run to achieve a ${confidence_level}% confidence level in the passing build. Analyze the provided diff and available spec files to make your decision. If there are no spec files worth running to get to the desired confidence level, return an empty array. Return only available spec files."

  local user_content="
Diff:
<diff>
${combined_diff}
</diff>

Available spec files:
<spec_files>
${all_spec_files}
</spec_files>"

  local payload=$(jq -n \
    --arg system_content "$system_content" \
    --arg user_content "$user_content" \
    '{
      model: "gpt-4o-2024-08-06",
      messages: [
        { role: "system", content: $system_content },
        { role: "user", content: $user_content }
      ],
      response_format: {
        type: "json_schema",
        json_schema: {
          name: "spec_files_to_run",
          schema: {
            type: "object",
            properties: {
              spec_files: {
                type: "array",
                items: {
                  type: "string",
                  description: "Spec file to run"
                }
              }
            },
            required: ["spec_files"],
            additionalProperties: false
          },
          strict: true
        }
      }
    }')

  local response=$(curl -s -X POST https://api.openai.com/v1/chat/completions \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${PERSONAL_OPENAI_API_KEY:-}" \
    -d "$payload")

  echo "$response" | jq -r '.choices[0].message.content | fromjson | .spec_files[]'
}

# Function to determine specific specs to run within selected spec files
determine_specs() {
  local confidence_level=$1
  local spec_files=("${@:2}")
  local combined_diff=$(get_combined_diff)
  local spec_contents=""

  for file in "${spec_files[@]}"; do
    spec_contents+="File: $file\n$(awk '{print NR ":" $0}' "$file")\n\n"
  done

  local system_content="You are an expert software engineer that determines which specific specs within the provided spec files should be run to achieve a ${confidence_level}% confidence level in the passing build. Analyze the provided diff and spec file contents to make your decision. Return the specific spec lines to run in the format 'file_path:line_number'."

  local user_content="
Diff:
<diff>
${combined_diff}
</diff>

Spec file contents:
<spec_contents>
${spec_contents}
</spec_contents>"

  local payload=$(jq -n \
    --arg system_content "$system_content" \
    --arg user_content "$user_content" \
    '{
      model: "gpt-4o-2024-08-06",
      messages: [
        { role: "system", content: $system_content },
        { role: "user", content: $user_content }
      ],
      response_format: {
        type: "json_schema",
        json_schema: {
          name: "specs_to_run",
          schema: {
            type: "object",
            properties: {
              specs: {
                type: "array",
                items: {
                  type: "string",
                  description: "Specific spec to run in format file_path:line_number"
                }
              }
            },
            required: ["specs"],
            additionalProperties: false
          },
          strict: true
        }
      }
    }')

  local response=$(curl -s -X POST https://api.openai.com/v1/chat/completions \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${PERSONAL_OPENAI_API_KEY:-}" \
    -d "$payload")

  echo "$response" | jq -r '.choices[0].message.content | fromjson | .specs[]'
}

# Function to run specs based on confidence level
run_specs() {
  local confidence_level=$1

  echo "Determining which spec files to run for ${confidence_level}% confidence level..."

  local spec_files=($(determine_spec_files $confidence_level))

  if [ ${#spec_files[@]} -eq 0 ]; then
    error_message "Failed to determine which spec files to run."
    return 1
  else
    echo "Spec files to run:"
    for file in "${spec_files[@]}"; do
      echo "$file"
    done
  fi

  echo "Determining specific specs to run within selected spec files..."
  local specs_to_run=($(determine_specs $confidence_level "${spec_files[@]}"))

  if [ ${#specs_to_run[@]} -eq 0 ]; then
    error_message "Failed to determine specific specs to run."
    return 1
  fi

  echo "Running specific specs for ${confidence_level}% confidence level:"
  for file in "${specs_to_run[@]}"; do
    echo "$file"
  done
  bundle exec rspec "${specs_to_run[@]}"
}

# Check if GitHub CLI is installed
if ! command -v gh &>/dev/null; then
  error_message "GitHub CLI (gh) is not installed. Please visit https://cli.github.com/"
  exit 1
fi

# Source the .env.development.local file if it exists
if [ -f .env.development.local ]; then
  source .env.development.local
fi

# Check for PERSONAL_OPENAI_API_KEY
if [ -z "${PERSONAL_OPENAI_API_KEY:-}" ]; then
  error_message "PERSONAL_OPENAI_API_KEY is not set. Please set it in .env.development.local"
  exit 1
fi

# Main function to run the shortest build
shortest_build() {
  local confidence_levels=(80 95 99 99.9)

  for level in "${confidence_levels[@]}"; do
    echo "Running specs for ${level}% confidence level..."
    if ! run_specs $level; then
      error_message "Build failed at ${level}% confidence level."
      exit 1
    fi
    success_message "Specs passed for ${level}% confidence level."
  done

  success_message "All confidence levels passed successfully!"
}

# Run the shortest build
shortest_build