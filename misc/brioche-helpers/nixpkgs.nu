#!/usr/bin/env nu

use ./mod.nu [GITHUB_API MAX_RETRIES github-get github-raw-get github-api-error log set-quiet parse-limit parse-exclusions is-excluded detect-nixpkgs-build-type extract-nixpkgs-builder make-package-json-extended]
use ./repology.nu [fetch-repology-metadata]

const DEFAULT_LIMIT = "30"
const NIXPKGS_RAW = "https://raw.githubusercontent.com/NixOS/nixpkgs/master"

export def fetch-nix-file [name: string] {
    let first_two = $name | str substring 0..1
    let paths = [
        $"pkgs/by-name/($first_two)/($name)/package.nix"
        $"pkgs/tools/misc/($name)/default.nix"
        $"pkgs/applications/misc/($name)/default.nix"
        $"pkgs/development/tools/($name)/default.nix"
    ]
    for path in $paths {
        let content = try { github-raw-get $"($NIXPKGS_RAW)/($path)" } catch { null }
        if $content != null { return $content }
    }
    null
}

export def fetch-nixpkgs [limit: int, exclusions: list<string>] {
    log "Fetching Nixpkgs commits..."
    let commits_url = $"($GITHUB_API)/repos/NixOS/nixpkgs/commits?per_page=($limit)&sha=master"
    mut commits = null
    mut attempt = 0
    mut delay = 2

    loop {
        let response = try { github-get $commits_url } catch { null }
        if $response == null {
            log "WARNING: Failed to fetch Nixpkgs commits"
            return []
        }
        let api_error = github-api-error $response
        if $api_error.rate_limited {
            $attempt += 1
            if $attempt >= $MAX_RETRIES {
                log $"WARNING: GitHub API rate limit reached for Nixpkgs after ($MAX_RETRIES) attempts"
                return []
            }
            log $"Rate limited fetching Nixpkgs commits, retry ($attempt)/($MAX_RETRIES) after ($delay)s..."
            sleep ($delay * 1sec)
            $delay *= 2
            continue
        }
        if not ($api_error.message | is-empty) {
            log $"WARNING: GitHub API error for Nixpkgs: ($api_error.message)"
            return []
        }
        $commits = $response
        break
    }

    mut packages = []
    mut count = 0
    for commit in $commits {
        if $count >= $limit { break }
        let message = $commit.commit.message | lines | first
        let name_match = try { $message | parse --regex '^(?P<name>[a-zA-Z0-9_-]+):' | first } catch { null }
        if $name_match == null { continue }
        let name = $name_match.name
        if (is-excluded $name $exclusions) {
            log $"Skipping excluded package: ($name)"
            continue
        }

        let version_match = try { $message | parse --regex '[:\-]\s*(?P<version>[0-9]+\.[0-9]+[0-9a-zA-Z._-]*)' | first } catch { null }
        mut version = if $version_match == null {
            "unknown"
        } else {
            $version_match.version
        }
        let updated_version = try { $message | parse --regex '->\s*(?P<version>[0-9]+\.[0-9]+[0-9a-zA-Z._-]*)' | first } catch { null }
        if $updated_version != null { $version = $updated_version.version }

        log $"Fetching .nix file for: ($name)"
        let nix_content = fetch-nix-file $name
        mut build_type = "Make"
        mut confidence = "low"
        mut builder = ""
        if $nix_content != null and not ($nix_content | is-empty) {
            $build_type = detect-nixpkgs-build-type $nix_content
            $builder = extract-nixpkgs-builder $nix_content
            if not ($build_type | is-empty) {
                $confidence = "high"
            } else {
                $build_type = "Make"
            }
        } else if ($message =~ '(?i)rust|cargo') {
            $build_type = "Rust"
        } else if ($message =~ '(?i)go\s|golang') {
            $build_type = "Go"
        } else if ($message =~ '(?i)node|npm') {
            $build_type = "npm"
        } else if ($message =~ '(?i)python|pip') {
            $build_type = "Python"
        } else if ($message =~ '(?i)cmake') {
            $build_type = "CMake"
        } else if ($message =~ '(?i)meson') {
            $build_type = "Meson"
        }

        let metadata = try { fetch-repology-metadata $name "nix" "guess_repo" } catch { {description: "", repository: ""} }
        let description = $metadata.description? | default ""
        let repository = $metadata.repository? | default ""
        $packages = ($packages | append (make-package-json-extended $name "nixpkgs" $build_type $version $description $repository $confidence [] "" $builder))
        $count += 1
    }
    log $"Fetched ($count) packages from Nixpkgs"
    $packages
}

def main [
    --limit (-l): string = $DEFAULT_LIMIT
    --exclude: string = ""
] {
    set-quiet false
    let parsed_limit = parse-limit $limit
    let exclusions = parse-exclusions $exclude
    log $"Starting Nixpkgs package discovery, limit=($parsed_limit)"
    fetch-nixpkgs $parsed_limit $exclusions | to json --raw
}
