#!/usr/bin/env nu

use ./mod.nu [api-get github-raw-get log set-quiet detect-build-type detect-homebrew-build-type extract-homebrew-build-command detect-nixpkgs-build-type extract-nixpkgs-builder]

const HOMEBREW_RAW = "https://raw.githubusercontent.com/Homebrew/homebrew-core/master/Formula"
const NIXPKGS_RAW = "https://raw.githubusercontent.com/NixOS/nixpkgs/master"
const ARCH_API = "https://archlinux.org/packages/search/json"
const BREW_API = "https://formulae.brew.sh/api"

export def fetch-homebrew-info [name: string] {
    let first_letter = $name | str substring 0..0
    let formula = try { github-raw-get $"($HOMEBREW_RAW)/($first_letter)/($name).rb" } catch { "" }
    if ($formula | is-empty) { return {} }

    let build_type = detect-homebrew-build-type $formula
    let build_command = extract-homebrew-build-command $formula
    let api = try { api-get $"($BREW_API)/formula/($name).json" } catch { null }
    let build_deps = if $api == null {
        []
    } else {
        $api.build_dependencies? | default []
    }
    let runtime_deps = if $api == null {
        []
    } else {
        $api.dependencies? | default []
    }
    let deps = ($build_deps ++ $runtime_deps) | str join ","
    mut resolved_type = $build_type
    mut confidence = "high"
    if ($resolved_type | is-empty) {
        $resolved_type = detect-build-type $deps
        $confidence = "medium"
    } else {
        $confidence = "very_high"
    }
    {
        build_type: $resolved_type
        confidence: $confidence
        build_command: (if ($build_command | is-empty) {
            null
        } else {
            $build_command
        })
        build_deps: $build_deps
        runtime_deps: $runtime_deps
    }
}

export def fetch-arch-info [name: string] {
    let response = try { api-get $"($ARCH_API)/?q=($name)&repo=Extra&repo=Core" } catch { return {} }
    let package = $response.results? | default [] | where pkgname == $name | first
    if $package == null { return {} }
    let makedepends = $package.makedepends? | default []
    {
        build_type: (detect-build-type ($makedepends | str join ","))
        confidence: "high"
        makedepends: $makedepends
    }
}

export def fetch-nixpkgs-info [name: string] {
    let first_two = $name | str substring 0..1
    let path = $"pkgs/by-name/($first_two)/($name)/package.nix"
    let content = try { github-raw-get $"($NIXPKGS_RAW)/($path)" } catch { "" }
    if ($content | is-empty) { return {} }
    mut build_type = detect-nixpkgs-build-type $content
    let builder = extract-nixpkgs-builder $content
    mut confidence = "high"
    if ($build_type | is-empty) {
        $build_type = "Make"
        $confidence = "low"
    }
    {
        build_type: $build_type
        confidence: $confidence
        builder: (if ($builder | is-empty) {
            null
        } else {
            $builder
        })
        path: $path
    }
}

def main [name: string] {
    set-quiet false
    log $"Looking up build type for: ($name)"
    log "Fetching Homebrew info..."
    let homebrew = fetch-homebrew-info $name
    log "Fetching Arch info..."
    let arch = fetch-arch-info $name
    log "Fetching Nixpkgs info..."
    let nixpkgs = fetch-nixpkgs-info $name

    let available = [$homebrew $nixpkgs $arch] | where {|source| ($source.build_type? | default "") != "" }
    let types = $available | get build_type
    let recommended = if not ($homebrew.build_type? | default "" | is-empty) {
        $homebrew.build_type
    } else if not ($nixpkgs.build_type? | default "" | is-empty) {
        $nixpkgs.build_type
    } else if not ($arch.build_type? | default "" | is-empty) {
        $arch.build_type
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
