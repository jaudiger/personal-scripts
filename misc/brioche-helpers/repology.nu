#!/usr/bin/env nu

use ./mod.nu [github-get log]

export const REPOLOGY_API = "https://repology.org/api/v1"
export const REPOLOGY_USER_AGENT = "brioche-packages/1.0 (https://github.com/brioche-dev/brioche-packages)"

export def repology-fetch-project [project: string] {
    let url = $"($REPOLOGY_API)/project/($project)"
    let response = try {
        http get --headers {"User-Agent": $REPOLOGY_USER_AGENT} $url
    } catch {
        log $"WARNING: Failed to fetch Repology data for: ($project)"
        return null
    }
    if (($response | describe) != "list") {
        log $"WARNING: Invalid Repology response for: ($project)"
        return null
    }
    $response
}

export def repology-get-metadata [project: string, repo_filter: string = ""] {
    let project_data = repology-fetch-project $project
    if $project_data == null or ($project_data | is-empty) {
        return {description: "", licenses: [], version: "", repo: ""}
    }

    let candidates = if ($repo_filter | is-empty) {
        $project_data
    } else {
        $project_data | where {|entry| ($entry.repo? | default "") | str starts-with $repo_filter}
    }
    let ranked = $candidates
        | each {|entry|
            let status = $entry.status? | default ""
            let rank = if $status == "newest" {
                0
            } else if $status == "devel" {
                1
            } else {
                2
            }
            $entry | insert _rank $rank
        }
        | sort-by _rank
    let entry = $ranked | first
    if $entry == null {
        {description: "", licenses: [], version: "", repo: ""}
    } else {
        {
            description: ($entry.summary? | default "")
            licenses: ($entry.licenses? | default [])
            version: ($entry.version? | default "")
            repo: ($entry.repo? | default "")
        }
    }
}

export def repology-get-description [project: string, repo_filter: string = ""] {
    repology-get-metadata $project $repo_filter | get description
}

export def repology-get-version [project: string, repo_filter: string = ""] {
    repology-get-metadata $project $repo_filter | get version
}

export def repology-get-licenses [project: string, repo_filter: string = ""] {
    repology-get-metadata $project $repo_filter | get licenses | str join ", "
}

export def repology-guess-repository [project: string] {
    let url = $"https://api.github.com/search/repositories?q=($project)+in:name&sort=stars&per_page=1"
    let response = try { github-get $url } catch { return "" }
    let total_count = $response.total_count? | default 0
    if $total_count == 0 { return "" }

    let item = $response.items? | default [] | first
    if $item == null { return "" }
    let repo_name = $item.name? | default "" | str lowercase | str replace --all "_" "-"
    let project_normalized = $project | str lowercase | str replace --all "_" "-"
    if $repo_name == $project_normalized {
        $item.html_url? | default ""
    } else {
        ""
    }
}

export def fetch-repology-metadata [project: string, repo_filter: string = "", guess_repo: string = ""] {
    let metadata = repology-get-metadata $project $repo_filter
    let repository = if $guess_repo == "guess_repo" {
        repology-guess-repository $project
    } else {
        ""
    }
    $metadata | insert repository $repository
}

export def main [
    package?: string
    --repo: string = ""
    --guess-repo
    --field: string = ""
] {
    if $package == null {
        print --stderr "A package name is required"
        exit 1
    }
    let guess_repo = if $guess_repo {
        "guess_repo"
    } else {
        ""
    }
    let result = fetch-repology-metadata $package $repo $guess_repo
    if ($field | is-empty) {
        $result | to json
    } else {
        let value = try { $result | get $field } catch { "" }
        if (($value | describe) == "string") {
            $value
        } else {
            $value | to json --raw
        }
    }
}
