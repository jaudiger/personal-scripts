#!/usr/bin/env nu

use ./mod.nu [GITHUB_API MAX_RETRIES github-get github-raw-get api-get github-api-error log set-quiet parse-limit parse-exclusions is-excluded detect-homebrew-build-type detect-build-type extract-homebrew-build-command make-package-json-extended]
use ./repology.nu [repology-guess-repository]

const BREW_API = "https://formulae.brew.sh/api"
const HOMEBREW_RAW = "https://raw.githubusercontent.com/Homebrew/homebrew-core/master/Formula"
const DEFAULT_LIMIT = "30"

export def fetch-homebrew [limit: int, exclusions: list<string>] {
    log "Fetching Homebrew commits..."
    let commits_url = $"($GITHUB_API)/repos/Homebrew/homebrew-core/commits?per_page=($limit)"
    mut commits = null
    mut attempt = 0
    mut delay = 2

    loop {
        let response = try { github-get $commits_url } catch { null }
        if $response == null {
            log "WARNING: Failed to fetch Homebrew commits"
            return []
        }
        let api_error = github-api-error $response
        if $api_error.rate_limited {
            $attempt += 1
            if $attempt >= $MAX_RETRIES {
                log $"WARNING: GitHub API rate limit reached for Homebrew after ($MAX_RETRIES) attempts"
                return []
            }
            log $"Rate limited fetching Homebrew commits, retry ($attempt)/($MAX_RETRIES) after ($delay)s..."
            sleep ($delay * 1sec)
            $delay *= 2
            continue
        }
        if not ($api_error.message | is-empty) {
            log $"WARNING: GitHub API error for Homebrew: ($api_error.message)"
            return []
        }
        $commits = $response
        break
    }

    let names = $commits
        | each {|commit| $commit.commit.message | lines | first }
        | each {|message| try { $message | parse --regex '^(?P<name>[a-z0-9_@-]+):' | first | get name } catch { null } }
        | where {|name| $name != null }
        | uniq
    if ($names | is-empty) {
        log "No packages found in Homebrew commits"
        return []
    }

    mut packages = []
    mut count = 0
    for name in $names {
        if $count >= $limit { break }
        if (is-excluded $name $exclusions) {
            log $"Skipping excluded package: ($name)"
            continue
        }

        log $"Fetching details for: ($name)"
        let formula_url = $"($BREW_API)/formula/($name).json"
        let formula = try { api-get $formula_url } catch {
            log $"WARNING: Failed to fetch details for ($name)"
            continue
        }
        let version = $formula.versions.stable? | default "unknown"
        let description = $formula.desc? | default ""
        let homepage = $formula.homepage? | default ""
        let build_deps = $formula.build_dependencies? | default []
        let runtime_deps = $formula.dependencies? | default []
        let deps = ($build_deps ++ $runtime_deps) | str join ","
        let source_url = $formula.urls.stable.url? | default ""

        let first_letter = $name | str substring 0..0
        let ruby_formula_url = $"($HOMEBREW_RAW)/($first_letter)/($name).rb"
        let ruby_content = try { github-raw-get $ruby_formula_url } catch { "" }
        mut build_type = "Make"
        mut confidence = "medium"
        mut build_command = ""
        if not ($ruby_content | is-empty) {
            $build_type = detect-homebrew-build-type $ruby_content
            $build_command = extract-homebrew-build-command $ruby_content
            if not ($build_type | is-empty) {
                $confidence = "very_high"
            } else {
                $build_type = detect-build-type $deps
            }
        } else {
            $build_type = detect-build-type $deps
        }

        mut repository = $homepage
        if not (($repository | str contains "github.com") or ($repository | str contains "gitlab.com")) {
            let source_match = try { $source_url | parse --regex 'github\\.com/(?P<repo>[^/]+/[^/]+)' | first } catch { null }
            if $source_match != null { $repository = $"https://github.com/($source_match.repo | str replace --regex '\\.git$' '')" }
        }
        if ($repository | is-empty) or not (($repository | str contains "github.com") or ($repository | str contains "gitlab.com") or ($repository | str contains "codeberg.org") or ($repository | str contains "sr.ht")) {
            let guessed = repology-guess-repository $name
            if not ($guessed | is-empty) { $repository = $guessed }
        }

        $packages = ($packages | append (make-package-json-extended $name "homebrew" $build_type $version $description $repository $confidence $build_deps $build_command ""))
        $count += 1
    }
    log $"Fetched ($count) packages from Homebrew"
    $packages
}

def main [
    --limit (-l): string = $DEFAULT_LIMIT
    --exclude: string = ""
] {
    set-quiet false
    let parsed_limit = parse-limit $limit
    let exclusions = parse-exclusions $exclude
    log $"Starting Homebrew package discovery, limit=($parsed_limit)"
    fetch-homebrew $parsed_limit $exclusions | to json --raw
}
