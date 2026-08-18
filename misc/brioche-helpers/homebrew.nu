#!/usr/bin/env nu

use ./mod.nu [GITHUB_API MAX_RETRIES github-get github-raw-get api-get github-api-error log die set-quiet parse-limit parse-exclusions is-excluded detect-build-type make-package-json]
use ./repology.nu [repology-guess-repository]

const BREW_API = "https://formulae.brew.sh/api"
const HOMEBREW_RAW = "https://raw.githubusercontent.com/Homebrew/homebrew-core/master/Formula"
const HOMEBREW_BLOB = "https://github.com/Homebrew/homebrew-core/blob/master/Formula"
const DEFAULT_LIMIT = "30"

export def detect-homebrew-build-type [content: string]: nothing -> string {
    if ($content =~ "(?is)cargo\\s+(install|build)" or $content =~ "(?is)system\\s+[\"']cargo[\"']") {
        "Rust"
    } else if ($content =~ "(?is)go\\s+(build|install)" or $content =~ "(?is)system\\s+[\"']go[\"']\\s*,\\s*[\"'](build|install)[\"']") {
        "Go"
    } else if ($content =~ "(?is)npm\\s+(install|ci)" or $content =~ "(?is)system\\s+[\"']npm[\"']") {
        "npm"
    } else if ($content =~ "(?is)pip\\s+install" or $content =~ "(?is)system\\s+[\"']pip[\"']" or $content =~ "(?is)virtualenv_install_with_resources") {
        "Python"
    } else if ($content =~ "(?is)system\\s+[\"']cmake[\"']" or $content =~ "(?is)cmake\\s+-S" or ($content | str contains "std_cmake_args")) {
        "CMake"
    } else if ($content =~ "(?is)system\\s+[\"']meson[\"']" or ($content | str contains "meson setup") or ($content | str contains "std_meson_args")) {
        "Meson"
    } else if ($content =~ "(?is)system\\s+[\"']dotnet[\"']\\s*,\\s*[\"'](publish|build|pack|restore|test|run)[\"']" or ($content | str contains "buildDotnet") or ($content =~ "(?is)system\\s+[\"']dotnet[\"']\\s*,\\s*[\"']tool[\"']\\s*,\\s*[\"']install[\"']") or (($content =~ "(?is)depends_on\\s+[\"']dotnet[\"']") and ($content =~ "(?is)system\\s+[\"']dotnet[\"']"))) {
        ".NET"
    } else if (($content | str contains "./configure") and ($content =~ "(?is)system\\s+[\"']make[\"']")) {
        "Autotools"
    } else if ($content =~ "(?is)system\\s+[\"']make[\"']") {
        "Make"
    } else {
        ""
    }
}

export def fetch-homebrew [limit: int, exclusions: list<string>]: nothing -> list<record> {
    log "Fetching Homebrew commits..."
    let commits_url = $"($GITHUB_API)/repos/Homebrew/homebrew-core/commits?per_page=($limit)"
    mut commits = []
    mut attempt = 0
    mut delay = 2

    loop {
        let response = try { github-get $commits_url } catch {|error|
            let message = $error.msg? | default ($error.rendered? | default "unknown error")
            die $"Failed to fetch Homebrew commits: ($message)"
        }
        if $response == null {
            die "Failed to fetch Homebrew commits"
        }
        let api_error = github-api-error $response
        if $api_error.rate_limited {
            $attempt += 1
            if $attempt >= $MAX_RETRIES {
                die $"GitHub API rate limit reached for Homebrew after ($MAX_RETRIES) attempts"
            }
            log $"Rate limited fetching Homebrew commits, retry ($attempt)/($MAX_RETRIES) after ($delay)s..."
            sleep ($delay * 1sec)
            $delay *= 2
            continue
        }
        if not ($api_error.message | is-empty) {
            die $"GitHub API error for Homebrew: ($api_error.message)"
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

    let candidates = $names
        | each {|name|
            if (is-excluded $name $exclusions) {
                log $"Skipping excluded package: ($name)"
                null
            } else {
                $name
            }
        }
        | compact
        | take $limit

    let packages = $candidates
        | each {|name|
            log $"Fetching details for: ($name)"
            let formula_url = $"($BREW_API)/formula/($name).json"
            let formula = try { api-get $formula_url } catch {|error|
                let message = $error.msg? | default ($error.rendered? | default "unknown error")
                log $"WARNING: Failed to fetch details for ($name): ($message)"
                null
            }
            if $formula == null {
                null
            } else {
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
                mut build_type = detect-homebrew-build-type $ruby_content
                if ($build_type | is-empty) {
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

                let recipe = {
                    url: $"($HOMEBREW_BLOB)/($first_letter)/($name).rb"
                    type: $build_type
                    build_deps: $build_deps
                }
                make-package-json $name "homebrew" $version $description $repository {homebrew: $recipe}
            }
        }
        | compact
    log $"Fetched ($packages | length) packages from Homebrew"
    $packages
}

def main [
    --limit (-l): string = $DEFAULT_LIMIT
    --exclude: string = ""
]: nothing -> string {
    set-quiet false
    let parsed_limit = parse-limit $limit
    let exclusions = parse-exclusions $exclude
    log $"Starting Homebrew package discovery, limit=($parsed_limit)"
    fetch-homebrew $parsed_limit $exclusions | to json --raw
}
