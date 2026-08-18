#!/usr/bin/env nu

use ./mod.nu [GITHUB_API MAX_RETRIES github-get github-raw-get github-api-error log die set-quiet parse-limit parse-exclusions is-excluded make-package-json]
use ./repology.nu [fetch-repology-metadata]

const DEFAULT_LIMIT = "30"
const NIXPKGS_RAW = "https://raw.githubusercontent.com/NixOS/nixpkgs/master"
const NIXPKGS_BLOB = "https://github.com/NixOS/nixpkgs/blob/master"

export def detect-nixpkgs-build-type [content: string] {
    if ($content | str contains "rustPlatform.buildRustPackage") {
        "Rust"
    } else if ($content | str contains "buildGoModule") {
        "Go"
    } else if ($content | str contains "buildNpmPackage") {
        "npm"
    } else if ($content =~ '(?is)python[0-9]*Packages\.buildPython(Application|Package)') {
        "Python"
    } else if ($content =~ '(?is)nativeBuildInputs.*cmake' or ($content | str contains "cmakeFlags")) {
        "CMake"
    } else if ($content =~ '(?is)nativeBuildInputs.*meson' or ($content | str contains "mesonFlags")) {
        "Meson"
    } else if ($content =~ '(?is)nativeBuildInputs.*autoreconfHook' or ($content | str contains "configureFlags")) {
        "Autotools"
    } else if (($content | str contains "buildDotnetPackage") or ($content | str contains "buildDotnetGlobalTool")) {
        ".NET"
    } else if ($content | str contains "stdenv.mkDerivation") {
        "Make"
    } else {
        ""
    }
}

export def extract-nixpkgs-build-deps [content: string] {
    let blocks = try {
        $content
        | str replace --all --regex '(?m)#.*$' ''
        | parse --regex '(?ms)(?:^|\n)\s*(?:nativeBuildInputs|buildInputs)\s*=\s*(?:with\s+[^;]+;\s*)?\[(?<deps>.*?)\]'
    } catch {
        []
    }
    $blocks
    | get deps
    | each {|deps|
        $deps
        | split row -r '[[:space:]]+'
        | each {|dep|
            $dep
            | str trim
            | str replace --all --regex '^[\[\](),;]+|[\[\](),;]+$' ''
        }
        | where {|dep| $dep =~ '^[A-Za-z_][A-Za-z0-9_+.-]*$' }
    }
    | flatten
    | uniq
}

export def fetch-nix-file-info [name: string] {
    let first_two = $name | str substring 0..1
    let paths = [
        $"pkgs/by-name/($first_two)/($name)/package.nix"
        $"pkgs/tools/misc/($name)/default.nix"
        $"pkgs/applications/misc/($name)/default.nix"
        $"pkgs/development/tools/($name)/default.nix"
    ]
    for path in $paths {
        let content = try { github-raw-get $"($NIXPKGS_RAW)/($path)" } catch { null }
        if $content != null { return {path: $path content: $content} }
    }
    null
}

def fetch-nix-file [name: string] {
    let file = fetch-nix-file-info $name
    if $file == null { null } else { $file.content }
}

export def fetch-nixpkgs [limit: int, exclusions: list<string>] {
    log "Fetching Nixpkgs commits..."
    let commits_url = $"($GITHUB_API)/repos/NixOS/nixpkgs/commits?per_page=($limit)&sha=master"
    mut commits = []
    mut attempt = 0
    mut delay = 2

    loop {
        let response = try { github-get $commits_url } catch {|error|
            let message = $error.msg? | default ($error.rendered? | default "unknown error")
            die $"Failed to fetch Nixpkgs commits: ($message)"
        }
        if $response == null {
            die "Failed to fetch Nixpkgs commits"
        }
        let api_error = github-api-error $response
        if $api_error.rate_limited {
            $attempt += 1
            if $attempt >= $MAX_RETRIES {
                die $"GitHub API rate limit reached for Nixpkgs after ($MAX_RETRIES) attempts"
            }
            log $"Rate limited fetching Nixpkgs commits, retry ($attempt)/($MAX_RETRIES) after ($delay)s..."
            sleep ($delay * 1sec)
            $delay *= 2
            continue
        }
        if not ($api_error.message | is-empty) {
            die $"GitHub API error for Nixpkgs: ($api_error.message)"
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

        log $"Fetching details for: ($name)"
        let nix_file = fetch-nix-file-info $name
        let nix_content = if $nix_file == null { null } else { $nix_file.content }
        mut build_type = "Make"
        mut build_deps = []
        mut recipe = {}
        if $nix_content != null and not ($nix_content | is-empty) {
            $build_type = detect-nixpkgs-build-type $nix_content
            if ($build_type | is-empty) {
                $build_type = "Make"
            }
            $build_deps = extract-nixpkgs-build-deps $nix_content
            $recipe = {
                url: $"($NIXPKGS_BLOB)/($nix_file.path)"
                type: $build_type
                build_deps: $build_deps
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
        $packages = ($packages | append (make-package-json $name "nixpkgs" $version $description $repository {nixpkgs: $recipe}))
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
