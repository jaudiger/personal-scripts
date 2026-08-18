#!/usr/bin/env nu

use ./mod.nu [api-get api-get-raw log die set-quiet parse-limit parse-exclusions is-excluded detect-build-type make-package-json]
use ./repology.nu [repology-guess-repository]

const ARCH_RSS_FEED = "https://archlinux.org/feeds/packages/"
const ARCH_API = "https://archlinux.org/packages/search/json"
const ARCH_PACKAGE = "https://archlinux.org/packages"
const DEFAULT_LIMIT = "30"

def xml-text [node: record]: nothing -> string {
    $node.content
    | where {|entry| $entry.tag == null }
    | get content
    | str join ""
}

def parse-rss-feed [rss_content: string]: nothing -> list<record> {
    let document = try { $rss_content | from xml } catch { return [] }
    let channel = $document.content | where tag == "channel" | first
    if $channel == null { return [] }
    let items = $channel.content | where tag == "item"
    $items | each {|item|
        let title_node = $item.content | where tag == "title" | first
        let link_node = $item.content | where tag == "link" | first
        let description_node = $item.content | where tag == "description" | first
        if $title_node == null { return null }
        let title = xml-text $title_node | str trim
        let parts = $title | split row -r '\s+' | where { is-not-empty }
        if ($parts | length) < 1 { return null }
        let link = if $link_node == null {
            ""
        } else {
            xml-text $link_node | str trim
        }
        let description = if $description_node == null {
            ""
        } else {
            xml-text $description_node | str trim
        }
        let repo_match = try { $link | parse --regex '/packages/(?P<repo>[^/]+)/' | first } catch { null }
        {
            name: ($parts | get 0)
            version: (if ($parts | length) > 1 {
                $parts | get 1
            } else {
                ""
            })
            arch: (if ($parts | length) > 2 {
                $parts | get 2
            } else {
                ""
            })
            description: $description
            repo: (if $repo_match == null {
                ""
            } else {
                $repo_match.repo
            })
        }
    } | where {|entry| $entry != null }
}

export def fetch-arch [limit: int, exclusions: list<string>]: nothing -> list<record> {
    log "Fetching Arch Linux RSS feed..."
    let rss_content = try { api-get-raw $ARCH_RSS_FEED } catch {|error|
        let message = $error.msg? | default ($error.rendered? | default "unknown error")
        die $"Failed to fetch Arch RSS feed: ($message)"
    }
    let entries = parse-rss-feed ($rss_content | into string)
    if ($entries | is-empty) {
        log "No packages found in Arch RSS feed"
        return []
    }

    let candidates = $entries
        | where {|entry|
            not (($entry.repo | str contains "-testing") or ($entry.repo | str contains "-staging"))
        }
        | uniq-by name
        | each {|entry|
            if (is-excluded $entry.name $exclusions) {
                log $"Skipping excluded package: ($entry.name)"
                null
            } else {
                $entry
            }
        }
        | compact

    let packages = $candidates
        | each {|entry|
            let name = $entry.name
            log $"Fetching details for: ($name)"
            let api_url = $"($ARCH_API)?name=($name)"
            let api_json = try { api-get $api_url } catch { null }
            mut url = ""
            mut build_deps = []
            mut build_type = "Make"
            mut recipe_url = ""
            if $api_json != null {
                let result = $api_json.results? | default [] | first
                if $result != null {
                    $url = $result.url? | default ""
                    $build_deps = $result.makedepends? | default []
                    if not ($build_deps | is-empty) {
                        $build_type = detect-build-type ($build_deps | str join ",")
                    }
                    let repo = $result.repo? | default ""
                    let arch = $result.arch? | default ""
                    let package_name = $result.pkgname? | default $name
                    if not ($repo | is-empty) and not ($arch | is-empty) {
                        $recipe_url = $"($ARCH_PACKAGE)/($repo)/($arch)/($package_name)/"
                    }
                }
            }
            if ($url | is-empty) or not (($url | str contains "github.com") or ($url | str contains "gitlab.com") or ($url | str contains "codeberg.org") or ($url | str contains "sr.ht")) {
                let guessed = repology-guess-repository $name
                if not ($guessed | is-empty) { $url = $guessed }
            }
            let recipe = if ($recipe_url | is-empty) {
                {}
            } else {
                {
                    url: $recipe_url
                    type: $build_type
                    build_deps: $build_deps
                }
            }
            make-package-json $name "arch" $entry.version $entry.description $url {arch: $recipe}
        }
        | compact
        | take $limit
    log $"Fetched ($packages | length) packages from Arch Linux"
    $packages
}

def main [
    --limit (-l): string = $DEFAULT_LIMIT
    --exclude: string = ""
]: nothing -> string {
    set-quiet false
    let parsed_limit = parse-limit $limit
    let exclusions = parse-exclusions $exclude
    log $"Starting Arch package discovery, limit=($parsed_limit)"
    fetch-arch $parsed_limit $exclusions | to json --raw
}
