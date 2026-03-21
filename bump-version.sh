#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------
# bump-version.sh
# Semantic version bump driven by Conventional Commits.
# - Detects bump (major/minor/patch) from commits since last tag.
# - Updates version in package files if found.
# - Writes/updates CHANGELOG.md section.
# - Commits changes, creates annotated tag, and pushes.
#
# Usage:
#   ./bump-version.sh [patch|minor|major|auto] [--no-push] [--dry-run]
# Defaults:
#   mode=auto (derive from commits), push enabled
#
# Requires:
#   git, grep, sed, awk, date
# ---------------------------------------------

MODE="${1:-auto}"
PUSH="yes"
DRY_RUN="no"

for arg in "$@"; do
  case "$arg" in
    --no-push) PUSH="no" ;;
    --dry-run) DRY_RUN="yes" ;;
  esac
done

# Ensure we’re on a branch with a clean working tree
if [[ "$(git status --porcelain)" != "" ]]; then
  echo "✋ Working tree not clean. Commit or stash changes first."
  exit 1
fi

# Fetch tags to ensure we see remote tags too (harmless locally)
git fetch --tags --quiet || true

# Get the last tag (if none, start from 0.1.0)
LAST_TAG="$(git describe --tags --abbrev=0 2>/dev/null || echo "")"
if [[ -z "$LAST_TAG" ]]; then
  LAST_TAG="0.1.0"
  RANGE=""
  echo "ℹ️  No existing tag found. Starting at $LAST_TAG"
else
  RANGE="${LAST_TAG}..HEAD"
  echo "ℹ️  Last tag: $LAST_TAG"
fi

# Read current version from files or from tag
CURRENT_VERSION="$LAST_TAG"

# Utility: semver bump
bump_semver () {
  local ver="$1" kind="$2"
  IFS='.' read -r MA MI PA <<< "$ver"
  case "$kind" in
    major) echo "$((MA+1)).0.0" ;;
    minor) echo "$MA.$((MI+1)).0" ;;
    patch) echo "$MA.$MI.$((PA+1))" ;;
    *) echo "$ver" ;;
  esac
}

# Detect bump from Conventional Commits
# Rules:
#   - any "BREAKING CHANGE" line or ! marker => major
#   - any "feat:" => minor
#   - else => patch if any relevant commit exists
detect_bump () {
  local range="$1"
  local major="no" minor="no" patch="no"
  local logs
  if [[ -z "$range" ]]; then
    logs="$(git log --pretty=%s)"
  else
    logs="$(git log --pretty=%B "$range")"
  fi

  if echo "$logs" | grep -Eiq 'breaking change|!:'; then
    echo "major"; return
  fi
  if echo "$logs" | grep -Eiq '^feat(\(.+\))?: '; then
    echo "minor"; return
  fi
  if [[ -n "$logs" ]]; then
    echo "patch"; return
  fi
  # No commits or no conventional messages; default to patch
  echo "patch"
}

if [[ "$MODE" == "auto" ]]; then
  MODE="$(detect_bump "$RANGE")"
fi
echo "🔎 Determined bump: $MODE"

NEW_VERSION="$(bump_semver "$CURRENT_VERSION" "$MODE")"
echo "🔢 Version: $CURRENT_VERSION -> $NEW_VERSION"

if [[ "$DRY_RUN" == "yes" ]]; then
  echo "🧪 Dry run: will not modify files, commit, or tag."
fi

# Update version in known files if present
update_file_versions () {
  local newv="$1"
  local updated="no"

  # package.json
  if [[ -f package.json ]]; then
    jq --version >/dev/null 2>&1 && \
      (tmp=$(mktemp); jq ".version=\"$newv\"" package.json > "$tmp" && mv "$tmp" package.json && updated="yes") || \
      (sed -i.bak -E "s/\"version\": *\"[0-9]+\.[0-9]+\.[0-9]+\"/\"version\": \"$newv\"/" package.json && updated="yes")
  fi

  # pyproject.toml
  if [[ -f pyproject.toml ]]; then
    if grep -Eq '^version *= *"[0-9]+\.[0-9]+\.[0-9]+"' pyproject.toml; then
      sed -i.bak -E "s/^version *= *\"[0-9]+\.[0-9]+\.[0-9]+\"/version = \"$newv\"/" pyproject.toml && updated="yes"
    fi
  fi

  # setup.cfg
  if [[ -f setup.cfg ]]; then
    if grep -Eq '^version *= *[0-9]+\.[0-9]+\.[0-9]+' setup.cfg; then
      sed -i.bak -E "s/^version *= *[0-9]+\.[0-9]+\.[0-9]+/version = $newv/" setup.cfg && updated="yes"
    fi
  fi

  # .csproj
  if ls *.csproj >/dev/null 2>&1; then
    for f in *.csproj; do
      if grep -Eq '<Version>[0-9]+\.[0-9]+\.[0-9]+</Version>' "$f"; then
        sed -i.bak -E "s#<Version>[0-9]+\.[0-9]+\.[0-9]+</Version>#<Version>$newv</Version>#" "$f" && updated="yes"
      fi
    done
  fi

  # Cargo.toml
  if [[ -f Cargo.toml ]]; then
    if grep -Eq '^version *= *"[0-9]+\.[0-9]+\.[0-9]+"' Cargo.toml; then
      sed -i.bak -E "s/^version *= *\"[0-9]+\.[0-9]+\.[0-9]+\"/version = \"$newv\"/" Cargo.toml && updated="yes"
    fi
  fi

  # generic VERSION file
  if [[ -f VERSION ]]; then
    echo "$newv" > VERSION && updated="yes"
  fi

  echo "$updated"
}

if [[ "$DRY_RUN" != "yes" ]]; then
  UPDATED="$(update_file_versions "$NEW_VERSION")"
  if [[ "$UPDATED" == "no" ]]; then
    echo "⚠️  No known version file found. Create a VERSION file or tell me your project type."
  fi
fi

# Generate changelog entry (simple): commits since last tag
generate_changelog () {
  local range="$1" newv="$2"
  local date
  date="$(date +%Y-%m-%d)"
  {
    echo "## $newv - $date"
    if [[ -z "$range" ]]; then
      git log --pretty="* %s"
    else
      git log --pretty="* %s" "$range"
    fi
    echo
  }
}

if [[ "$DRY_RUN" != "yes" ]]; then
  ENTRY="$(generate_changelog "$RANGE" "$NEW_VERSION")"
  if [[ -f CHANGELOG.md ]]; then
    printf "%s\n\n%s" "$ENTRY" "$(cat CHANGELOG.md)" > CHANGELOG.md.tmp && mv CHANGELOG.md.tmp CHANGELOG.md
  else
    printf "# Changelog\n\n%s" "$ENTRY" > CHANGELOG.md
  fi
fi

# Commit, tag, push
if [[ "$DRY_RUN" != "yes" ]]; then
  git add -A
  git commit -m "chore(release): v$NEW_VERSION"
  git tag -a "v$NEW_VERSION" -m "Release $NEW_VERSION"

  if [[ "$PUSH" == "yes" ]]; then
    # In Actions, write access token must be configured
    git push && git push --tags
  else
    echo "ℹ️  Skipped push (--no-push)."
  fi
else
  echo "DRY RUN would:"
  echo "- Update version files to $NEW_VERSION"
  echo "- Prepend changelog section"
  echo "- Commit & tag v$NEW_VERSION"
  [[ "$PUSH" == "yes" ]] && echo "- Push to origin"
fi

echo "✅ Done. New version: $NEW_VERSION"

# ... keep the script as-is above this point ...

# Generate changelog entry (simple): commits since last tag
generate_changelog () {
  local range="$1" newv="$2"
  local date
  date="$(date +%Y-%m-%d)"
  {
    echo "## $newv - $date"
    if [[ -z "$range" ]]; then
      git log --pretty="* %s"
    else
      git log --pretty="* %s" "$range"
    fi
    echo
  }
}

if [[ "$DRY_RUN" != "yes" ]]; then
  ENTRY="$(generate_changelog "$RANGE" "$NEW_VERSION")"

  # --- NEW: also save the latest entry as a standalone release notes file
  echo "$ENTRY" > .release-notes.md   # <--- NEW

  if [[ -f CHANGELOG.md ]]; then
    printf "%s\n\n%s" "$ENTRY" "$(cat CHANGELOG.md)" > CHANGELOG.md.tmp && mv CHANGELOG.md.tmp CHANGELOG.md
  else
    printf "# Changelog\n\n%s" "$ENTRY" > CHANGELOG.md
  fi
fi

# Commit, tag, push
if [[ "$DRY_RUN" != "yes" ]]; then
  git add -A
  git commit -m "chore(release): v$NEW_VERSION"
  git tag -a "v$NEW_VERSION" -m "Release $NEW_VERSION"

  if [[ "$PUSH" == "yes" ]]; then
    git push && git push --tags
  else
    echo "ℹ️  Skipped push (--no-push)."
  fi
else
  echo "DRY RUN would:"
  echo "- Update version files to $NEW_VERSION"
  echo "- Prepend changelog section"
  echo "- Commit & tag v$NEW_VERSION"
  [[ "$PUSH" == "yes" ]] && echo "- Push to origin"
fi

# --- NEW: if running in GitHub Actions, publish outputs for downstream steps
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    echo "new_version=$NEW_VERSION"
    echo "tag=v$NEW_VERSION"
    echo "release_notes=.release-notes.md"
  } >> "$GITHUB_OUTPUT"
fi
# --- END NEW

echo "✅ Done. New version: $NEW_VERSION"
