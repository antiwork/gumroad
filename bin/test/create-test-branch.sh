#!/bin/bash

set -euo pipefail

REPO="${REPO:-antiwork/gumroad}"
INTERACTIVE="${INTERACTIVE:-true}"
PR_LIMIT="${PR_LIMIT:-25}"
PR_NUMBERS=()

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

error_exit() {
  echo -e "${RED}ERROR: $1${NC}" >&2
  exit 1
}

authenticate_github() {
  echo -e "${YELLOW}GitHub CLI is not authenticated.${NC}"
  echo -n "Would you like to authenticate now? (y/n): "
  read -r auth_choice

  case "$auth_choice" in
    y|Y|yes|Yes|YES)
      gh auth login || error_exit "GitHub authentication failed"
      ;;
    *)
      error_exit "GitHub authentication is required"
      ;;
  esac
}

install_github_cli() {
  echo -e "${YELLOW}GitHub CLI is not installed.${NC}"
  echo -n "Install it automatically? (y/n): "
  read -r install_choice

  [[ "$install_choice" =~ ^[yY] ]] || error_exit "GitHub CLI is required"

  if [[ "$OSTYPE" == "darwin"* ]]; then
    command -v brew >/dev/null || error_exit "Homebrew not found. Install from https://brew.sh/"
    brew install gh
  elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
    if command -v apt >/dev/null; then
      curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg
      sudo chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg
      echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null
      sudo apt update && sudo apt install gh
    else
      error_exit "Unsupported package manager. Install from https://cli.github.com/"
    fi
  else
    error_exit "Unsupported OS. Install from https://cli.github.com/"
  fi
}

check_git_clean() {
  git diff-index --quiet HEAD -- || error_exit "Git working directory is not clean"

  local untracked=$(git ls-files --others --exclude-standard)
  if [[ -n "$untracked" ]]; then
    echo -e "${YELLOW}Warning: Found untracked files${NC}"
    echo -n "Continue anyway? (y/n): "
    read -r continue_choice
    [[ "$continue_choice" =~ ^[yY] ]] || error_exit "Aborted due to untracked files"
  fi
}

check_permissions() {
  local user=$(gh api user --jq '.login')
  local permission=$(gh api "repos/$REPO/collaborators/$user/permission" --jq '.permission' 2>/dev/null || echo "none")

  case "$permission" in
    admin|maintain|write)
      return 0
      ;;
    *)
      error_exit "Insufficient permissions. Need write, maintain, or admin access"
      ;;
  esac
}

check_prerequisites() {
  git rev-parse --git-dir >/dev/null || error_exit "Not in a Git repository"
  check_git_clean

  command -v gh >/dev/null || install_github_cli
  gh auth status >/dev/null 2>&1 || authenticate_github
  gh repo view "$REPO" >/dev/null || error_exit "Cannot access repository: $REPO"
  check_permissions
}

get_external_prs() {
  local prs=$(gh pr list --repo "$REPO" --state open --limit "$PR_LIMIT" --json number,title,headRefName,author,isCrossRepository)
  echo "$prs" | jq -c '.[] | select(.isCrossRepository == true)' 2>/dev/null || echo "$prs" | jq -c '.[]'
}

interactive_pr_selection() {
  local external_prs=$(get_external_prs)
  [[ -n "$external_prs" ]] || error_exit "No PRs found"

  local pr_data=()
  local index=1

  echo -e "${BLUE}Available PRs:${NC}"
  while IFS= read -r pr_json; do
    [[ -n "$pr_json" ]] || continue

    local pr_number=$(echo "$pr_json" | jq -r '.number // "unknown"')
    local title=$(echo "$pr_json" | jq -r '.title // "No title"')
    local author=$(echo "$pr_json" | jq -r '.author.login // "unknown"')
    local head_ref=$(echo "$pr_json" | jq -r '.headRefName // "unknown"')

    [[ "$pr_number" != "unknown" && "$head_ref" != "unknown" ]] || continue

    pr_data+=("$pr_number:$head_ref")
    echo -e "${YELLOW}[$index]${NC} PR #$pr_number by ${GREEN}$author${NC}"
    echo "    $title"
    echo
    ((index++))
  done <<< "$external_prs"

  [[ ${#pr_data[@]} -gt 0 ]] || error_exit "No valid PRs found"

  echo "Enter numbers (e.g., 1 3 5), 'all', or 'quit':"
  while true; do
    echo -n "Your choice: "
    read -r selection

    case "$selection" in
      quit|q|exit)
        exit 0
        ;;
      all)
        for pr_entry in "${pr_data[@]}"; do
          PR_NUMBERS+=($(echo "$pr_entry" | cut -d: -f1))
        done
        return 0
        ;;
      "")
        echo "Please enter a selection"
        continue
        ;;
      *)
        local temp_numbers=()
        for item in $selection; do
          if [[ "$item" =~ ^[0-9]+$ ]]; then
            local item_index=$((item - 1))
            if [[ $item_index -ge 0 && $item_index -lt ${#pr_data[@]} ]]; then
              temp_numbers+=($(echo "${pr_data[$item_index]}" | cut -d: -f1))
            else
              echo "Invalid selection: $item"
              continue 2
            fi
          else
            echo "Invalid input: $item"
            continue 2
          fi
        done

        if [[ ${#temp_numbers[@]} -gt 0 ]]; then
          PR_NUMBERS=("${temp_numbers[@]}")
          return 0
        fi
        ;;
    esac
  done
}

validate_pr() {
  local pr_number="$1"
  local pr_info=$(gh pr view "$pr_number" --repo "$REPO" --json headRefName,isCrossRepository,state 2>/dev/null)

  [[ -n "$pr_info" ]] || return 1
  [[ "$(echo "$pr_info" | jq -r '.state')" == "OPEN" ]] || return 1

  echo "$pr_info" | jq -r '.headRefName'
}

create_test_branch() {
  local pr_number="$1"
  local head_ref="$2"
  local new_branch="test/${head_ref}"
  local current_branch=$(git branch --show-current)

  git show-ref --verify --quiet "refs/remotes/origin/$new_branch" && {
    echo "Branch $new_branch already exists, skipping"
    return 0
  }

  gh pr checkout "$pr_number" --repo "$REPO" || return 1
  git checkout -b "$new_branch" || return 1
  git push origin "$new_branch" || return 1
  git checkout "$current_branch"

  echo -e "${GREEN}✅ Created test branch: $new_branch${NC}"
}

main() {
  check_prerequisites

  if [[ "$INTERACTIVE" == "true" && ${#PR_NUMBERS[@]} -eq 0 ]]; then
    interactive_pr_selection
  fi

  [[ ${#PR_NUMBERS[@]} -gt 0 ]] || error_exit "No PRs specified"

  local processed=0
  local failed=0

  for pr_number in "${PR_NUMBERS[@]}"; do
    echo "Processing PR #$pr_number..."

    if head_ref=$(validate_pr "$pr_number"); then
      if create_test_branch "$pr_number" "$head_ref"; then
        ((processed++))
      else
        echo -e "${RED}Failed to create branch for PR #$pr_number${NC}"
        ((failed++))
      fi
    else
      echo -e "${RED}PR #$pr_number is invalid or not external${NC}"
      ((failed++))
    fi
  done

  echo
  echo "Processed: $processed, Failed: $failed"
  [[ $failed -eq 0 ]] || exit 1
}

case "${1:-}" in
  -h|--help)
    echo "Usage: $0 [PR_NUMBERS...]"
    echo "Environment: REPO (default: antiwork/gumroad), INTERACTIVE (default: true), PR_LIMIT (default: 25)"
    exit 0
    ;;
  *)
    while [[ $# -gt 0 ]]; do
      [[ $1 =~ ^[0-9]+$ ]] || error_exit "Invalid PR number: $1"
      PR_NUMBERS+=("$1")
      INTERACTIVE=false
      shift
    done
    main
    ;;
esac
