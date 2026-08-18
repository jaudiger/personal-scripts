export const GITHUB_API = "https://api.github.com"
export const USER_AGENT = "discover-packages/1.0"
export const MAX_RETRIES = 3

export def --env set-quiet [quiet: bool] {
    $env.DISCOVER_PACKAGES_QUIET = $quiet
}

export def log [message: string] {
    if not ($env.DISCOVER_PACKAGES_QUIET? | default false) {
        print --stderr $"[(date now | format date "%Y-%m-%dT%H:%M:%SZ")] ($message)"
    }
}

export def die [message: string] {
    log $"ERROR: ($message)"
    error make {msg: $message}
}

export def parse-limit [value: string] {
    let parsed = try { $value | into int } catch { null }
    if $parsed == null or $parsed < 1 or not ($value =~ '^[0-9]+$') {
        die $"Invalid limit: ($value), must be a positive integer"
    }
    $parsed
}

export def parse-exclusions [list: string] {
    let exclusions = $list
        | split row ","
        | each { str trim }
        | where { is-not-empty }
    log $"Loaded ($exclusions | length) exclusions"
    $exclusions
}

export def is-excluded [pkg: string, exclusions: list<string>] {
    let pkg_norm = $pkg | str replace --all "_" "-"
    let pkg_nolib = $pkg
        | str replace --regex '^lib' ""
        | str replace --regex '^-' ""
        | str replace --regex '^_' ""
    let pkg_nolib_norm = $pkg_nolib | str replace --all "_" "-"

    $exclusions | any {|excl|
        let excl_norm = $excl | str replace --all "_" "-"
        let excl_nolib = $excl
            | str replace --regex '^lib' ""
            | str replace --regex '^-' ""
            | str replace --regex '^_' ""
        let direct = $pkg in [
            $excl
            $"lib($excl)"
            $"lib-($excl)"
            $"lib_($excl)"
            $excl_nolib
        ]
        $direct or ($pkg_norm == $excl_norm) or ($pkg_nolib == $excl) or ($pkg_nolib_norm == $excl_norm)
    }
}

export def github-get [url: string] {
    mut headers = {
        "User-Agent": $USER_AGENT
        "Accept": "application/vnd.github+json"
    }
    if ($env.GITHUB_TOKEN? | is-not-empty) {
        $headers = ($headers | insert Authorization $"Bearer ($env.GITHUB_TOKEN)")
    }
    http get --headers $headers $url
}

export def github-raw-get [url: string] {
    mut headers = {"User-Agent": $USER_AGENT}
    if ($env.GITHUB_TOKEN? | is-not-empty) {
        $headers = ($headers | insert Authorization $"Bearer ($env.GITHUB_TOKEN)")
    }
    http get --raw --headers $headers $url
}

export def api-get [url: string] {
    http get --headers {"User-Agent": $USER_AGENT} $url
}

export def api-get-raw [url: string] {
    http get --raw --headers {"User-Agent": $USER_AGENT} $url
}

export def github-api-error [response: any] {
    let message = if (($response | describe) == "record") {
        $response.message? | default ""
    } else {
        ""
    }
    {
        message: $message
        rate_limited: ($message | str contains --ignore-case "rate limit")
    }
}

export def detect-build-type [deps: string] {
    let tokens = $deps
        | str lowercase
        | split row -r '[[:space:],]+'
        | where { is-not-empty }
    if ($tokens | any {|it| $it in [rust cargo]}) {
        "Rust"
    } else if ($tokens | any {|it| $it in [go golang]}) {
        "Go"
    } else if ($tokens | any {|it| $it in [node npm nodejs]}) {
        "npm"
    } else if ($tokens | any {|it| $it in [python python3]}) {
        "Python"
    } else if ($tokens | any {|it| $it == "cmake"}) {
        "CMake"
    } else if ($tokens | any {|it| $it == "meson"}) {
        "Meson"
    } else if ($tokens | any {|it| $it in [autoconf automake]}) {
        "Autotools"
    } else if ($tokens | any {|it| $it =~ '^dotnet(-sdk)?(-[0-9]+([-.][0-9]+)?)?$'}) {
        ".NET"
    } else {
        "Make"
    }
}

export def make-package-json [name: string, source: string, version: string, description: string, repository: string, recipes: record] {
    let homebrew = $recipes.homebrew? | default null
    let nixpkgs = $recipes.nixpkgs? | default null
    let arch = $recipes.arch? | default null
    {
        name: $name
        source: $source
        version: $version
        description: $description
        repository: $repository
        recipes: {
            homebrew: (if $homebrew == null or ($homebrew | is-empty) { null } else { $homebrew })
            nixpkgs: (if $nixpkgs == null or ($nixpkgs | is-empty) { null } else { $nixpkgs })
            arch: (if $arch == null or ($arch | is-empty) { null } else { $arch })
        }
    }
}
