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

export def detect-build-type-with-confidence [deps: string] {
    let tokens = $deps
        | str lowercase
        | split row -r '[[:space:],]+'
        | where { is-not-empty }
    if ($tokens | any {|it| $it in [rust cargo]}) {
        "Rust:high"
    } else if ($tokens | any {|it| $it in [go golang]}) {
        "Go:high"
    } else if ($tokens | any {|it| $it in [node npm nodejs]}) {
        "npm:high"
    } else if ($tokens | any {|it| $it in [python python3]}) {
        "Python:high"
    } else if ($tokens | any {|it| $it == "cmake"}) {
        "CMake:medium"
    } else if ($tokens | any {|it| $it == "meson"}) {
        "Meson:medium"
    } else if ($tokens | any {|it| $it in [autoconf automake]}) {
        "Autotools:medium"
    } else if ($tokens | any {|it| $it =~ '^dotnet(-sdk)?(-[0-9]+([-.][0-9]+)?)?$'}) {
        ".NET:low"
    } else {
        "Make:low"
    }
}

export def detect-homebrew-build-type [content: string] {
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

export def extract-nixpkgs-builder [content: string] {
    let patterns = [
        'rustPlatform\.buildRustPackage'
        'buildGoModule'
        'buildNpmPackage'
        'python[0-9]*Packages\.buildPythonApplication'
        'python[0-9]*Packages\.buildPythonPackage'
        'stdenv\.mkDerivation'
    ]
    for pattern in $patterns {
        let match = try {
            $content | parse --regex ("(?P<builder>" + $pattern + ")") | first
        } catch {
            null
        }
        if $match != null {
            return $match.builder
        }
    }
    ""
}

export def extract-homebrew-build-command [content: string] {
    let lines = $content | lines
    let system_line = $lines
        | where {|line| $line =~ "(?i)system\\s+[\"'](cargo|go|npm)[\"']"}
        | first
    if $system_line != null {
        let command = try {
            $system_line | parse --regex "(?i).*system\\s+[\"'](?P<command>[^\"']+)[\"'](?P<args>.*)" | first
        } catch {
            null
        }
        if $command != null {
            let args = try {
                $command.args
                | parse --regex "[\"'](?P<arg>[^\"']+)[\"']"
                | get arg
                | str join " "
            } catch {
                ""
            }
            $"($command.command) ($args)"
            | str replace --regex '\s+\*std_\w+_args' ""
            | str trim
        } else {
            ""
        }
    } else if ($content | str contains "std_cmake_args") {
        "cmake with std_cmake_args"
    } else if ($content | str contains "std_meson_args") {
        "meson with std_meson_args"
    } else if ($content =~ "(?i)system\\s+[\"']npm[\"']") {
        "npm install"
    } else if ($content =~ "(?i)pip\\s+install|virtualenv_install") {
        "pip install"
    } else {
        ""
    }
}

export def make-package-json [name: string, source: string, type: string, version: string, description: string, repository: string] {
    {
        name: $name
        source: $source
        type: $type
        version: $version
        description: $description
        repository: $repository
    }
}

export def make-package-json-extended [name: string, source: string, type: string, version: string, description: string, repository: string, confidence: string, build_deps: any, build_command: string, builder: string] {
    let deps = if $build_deps == null {
        []
    } else {
        $build_deps
    }
    let command = if ($build_command | is-empty) {
        null
    } else {
        $build_command
    }
    let detected_builder = if ($builder | is-empty) {
        null
    } else {
        $builder
    }
    {
        name: $name
        source: $source
        type: $type
        version: $version
        description: $description
        repository: $repository
        build_info: {
            confidence: $confidence
            build_deps: $deps
            build_command: $command
            builder: $detected_builder
        }
    }
}
