#!/usr/bin/env nu

use ./mod.nu [api-get github-raw-get log set-quiet detect-build-type]
use ./homebrew.nu [detect-homebrew-build-type]
use ./nixpkgs.nu [fetch-nix-file-info detect-nixpkgs-build-type extract-nixpkgs-build-deps]

const HOMEBREW_RAW = "https://raw.githubusercontent.com/Homebrew/homebrew-core/master/Formula"
const HOMEBREW_BLOB = "https://github.com/Homebrew/homebrew-core/blob/master/Formula"
const NIXPKGS_BLOB = "https://github.com/NixOS/nixpkgs/blob/master"
const ARCH_API = "https://archlinux.org/packages/search/json"
const ARCH_PACKAGE = "https://archlinux.org/packages"
const BREW_API = "https://formulae.brew.sh/api"

export def fetch-homebrew-info [name: string]: nothing -> record {
    let first_letter = $name | str substring 0..0
    let formula = try { github-raw-get $"($HOMEBREW_RAW)/($first_letter)/($name).rb" } catch { "" }
    if ($formula | is-empty) { return {} }

    let detected_type = detect-homebrew-build-type $formula
    let api = try { api-get $"($BREW_API)/formula/($name).json" } catch { null }
    let build_deps = if $api == null {
        []
    } else {
        $api.build_dependencies? | default []
    }
    let deps = if $api == null {
        ""
    } else {
        let runtime_deps = $api.dependencies? | default []
        ($build_deps ++ $runtime_deps) | str join ","
    }
    let build_type = if ($detected_type | is-empty) {
        detect-build-type $deps
    } else {
        $detected_type
    }
    {
        url: $"($HOMEBREW_BLOB)/($first_letter)/($name).rb"
        type: $build_type
        build_deps: $build_deps
    }
}

export def fetch-arch-info [name: string]: nothing -> record {
    let response = try { api-get $"($ARCH_API)/?q=($name)&repo=Extra&repo=Core" } catch { return {} }
    let package = $response.results? | default [] | where pkgname == $name | first
    if $package == null { return {} }
    let makedepends = $package.makedepends? | default []
    let repo = $package.repo? | default ""
    let arch = $package.arch? | default ""
    let package_name = $package.pkgname? | default $name
    let package_url = if ($repo | is-empty) or ($arch | is-empty) {
        null
    } else {
        $"($ARCH_PACKAGE)/($repo)/($arch)/($package_name)/"
    }
    {
        url: $package_url
        type: (detect-build-type ($makedepends | str join ","))
        build_deps: $makedepends
    }
}

export def fetch-nixpkgs-info [name: string]: nothing -> record {
    let file = fetch-nix-file-info $name
    if $file == null { return {} }
    let content = $file.content
    mut build_type = detect-nixpkgs-build-type $content
    if ($build_type | is-empty) {
        $build_type = "Make"
    }
    {
        url: $"($NIXPKGS_BLOB)/($file.path)"
        type: $build_type
        build_deps: (extract-nixpkgs-build-deps $content)
    }
}

def main [name: string]: nothing -> string {
    set-quiet false
    log $"Looking up build type for: ($name)"
    log "Fetching Homebrew info..."
    let homebrew = fetch-homebrew-info $name
    log "Fetching Arch info..."
    let arch = fetch-arch-info $name
    log "Fetching Nixpkgs info..."
    let nixpkgs = fetch-nixpkgs-info $name

    let available = [$homebrew $nixpkgs $arch] | where {|source| ($source.type? | default "") != "" }
    let types = $available | get type
    let recommended = if not ($homebrew.type? | default "" | is-empty) {
        $homebrew.type
    } else if not ($nixpkgs.type? | default "" | is-empty) {
        $nixpkgs.type
    } else if not ($arch.type? | default "" | is-empty) {
        $arch.type
    } else {
        null
    }
    let matching = if $recommended == null {
        0
    } else {
        $types | where {|type| $type == $recommended } | length
    }
    let consensus = ($available | length) >= 2 and $matching >= 2
    {
        package: $name
        sources: {
            homebrew: (if ($homebrew | is-empty) {
                null
            } else {
                $homebrew
            })
            arch: (if ($arch | is-empty) {
                null
            } else {
                $arch
            })
            nixpkgs: (if ($nixpkgs | is-empty) {
                null
            } else {
                $nixpkgs
            })
        }
        recommended: $recommended
        consensus: $consensus
    } | to json --raw
}
