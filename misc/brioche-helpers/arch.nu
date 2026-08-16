#!/usr/bin/env nu

use ./mod.nu [api-get api-get-raw log set-quiet parse-limit parse-exclusions is-excluded detect-build-type-with-confidence make-package-json-extended]
use ./repology.nu [repology-guess-repository]

const ARCH_RSS_FEED = "https://archlinux.org/feeds/packages/"
const ARCH_API = "https://archlinux.org/packages/search/json"
const DEFAULT_LIMIT = "30"

def xml-text [node: record] {
    $node.content
    | where {|entry| $entry.tag == null }
    | get content
    | str join ""
}

export def parse-rss-feed [rss_content: string] {
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

export def fetch-arch [limit: int, exclusions: list<string>] {
    log "Fetching Arch Linux RSS feed..."
    let rss_content = try { api-get-raw $ARCH_RSS_FEED } catch {
        log "WARNING: Failed to fetch Arch RSS feed"
        return []
    }
    let entries = parse-rss-feed ($rss_content | into string)
    if ($entries | is-empty) {
        log "No packages found in Arch RSS feed"
        return []
    }

    mut packages = []
    mut seen = []
    mut count = 0
    for entry in $entries {
        if $count >= $limit { break }
        let name = $entry.name
        if ($entry.repo | str contains "-testing") or ($entry.repo | str contains "-staging") { continue }
        if $name in $seen { continue }
        $seen = ($seen | append $name)
        if (is-excluded $name $exclusions) {
            log $"Skipping excluded package: ($name)"
            continue
        }

        log $"Fetching details for: ($name)"
        let api_url = $"($ARCH_API)?name=($name)"
        let api_json = try { api-get $api_url } catch { null }
        mut url = ""
        mut build_deps = []
        mut build_type = "Make"
        mut confidence = "low"
        if $api_json != null {
            let result = $api_json.results? | default [] | first
            if $result != null {
                $url = $result.url? | default ""
                $build_deps = $result.makedepends? | default []
                if not ($build_deps | is-empty) {
                    let type_confidence = detect-build-type-with-confidence ($build_deps | str join ",")
                    let parts = $type_confidence | split row ":"
                    $build_type = $parts | get 0
                    $confidence = $parts | get 1
                }
            }
        }
        if ($url | is-empty) or not (($url | str contains "github.com") or ($url | str contains "gitlab.com") or ($url | str contains "codeberg.org") or ($url | str contains "sr.ht")) {
            let guessed = repology-guess-repository $name
            if not ($guessed | is-empty) { $url = $guessed }
        }
        $packages = ($packages | append (make-package-json-extended $name "arch" $build_type $entry.version $entry.description $url $confidence $build_deps "" ""))
        $count += 1
    }
    log $"Fetched ($count) packages from Arch Linux"
    $packages
}

def main [
    --limit (-l): string = $DEFAULT_LIMIT
    --exclude: string = ""
] {
    set-quiet false
    let parsed_limit = parse-limit $limit
    let exclusions = parse-exclusions $exclude
    log $"Starting Arch package discovery, limit=($parsed_limit)"
    fetch-arch $parsed_limit $exclusions | to json --raw
}
