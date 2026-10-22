//! Every pin `flow pin` knows about, and where its upstream publishes releases.

use super::System;
use super::fetch::Artifact;

pub struct Pin {
    pub name: &'static str,
    pub kind: Kind,
}

pub enum Kind {
    /// `flow pin bump` rewrites `pins/<name>.json`.
    Managed(Managed),
    /// Reported by `flow pin check`; a bump needs lock-file work this tool
    /// does not attempt.
    Manual(Manual),
}

pub struct Managed {
    pub upstream: Upstream,
    pub artifact: Artifact,
    /// Flake package that consumes the pin, built after a bump on systems the
    /// pin covers. `None` when the fixed-output fetch is the whole artifact.
    pub flake_attr: Option<&'static str>,
}

pub enum Upstream {
    /// One npm package per platform, versioned together with `version_package`.
    NpmPlatforms {
        version_package: &'static str,
        packages: &'static [(System, &'static str)],
    },
    /// Assets of the latest GitHub release, tagged `v<version>`.
    GithubRelease {
        repo: &'static str,
        assets: &'static [(System, &'static str)],
    },
    /// Sparkle appcast feeds; the newest item by build number wins.
    Sparkle {
        feeds: &'static [(System, &'static str)],
        version: SparkleVersion,
    },
    /// Wispr Flow's Squirrel `RELEASES.json`, one per architecture.
    WisprReleases {
        feeds: &'static [(System, &'static str)],
    },
    /// OrbStack's download endpoint redirects to
    /// `OrbStack_v<version>_<build>_<arch>.dmg`.
    OrbStackRedirect { system: System, url: &'static str },
    /// Tailscale's stable package index; one universal macOS installer.
    TailscaleStable { systems: &'static [System] },
    /// A URL that always serves the newest DMG; the version is read from the
    /// bundle's Info.plist at `info_plist` inside the image.
    UnversionedDmg {
        systems: &'static [System],
        url: &'static str,
        info_plist: &'static str,
    },
}

#[derive(Clone, Copy, Debug)]
pub enum SparkleVersion {
    ShortVersionString,
    /// A query parameter of the enclosure URL, for feeds whose display version
    /// drops a prefix the download needs.
    EnclosureQuery(&'static str),
}

pub enum Manual {
    /// A tag-pinned GitHub flake input; the pinned tag comes from `flake.lock`.
    FlakeInputTag {
        input: &'static str,
        repo: &'static str,
        reason: &'static str,
    },
    /// An npm dependency declared in a package.json under the repo.
    NpmDependency {
        package_json: &'static str,
        package: &'static str,
        reason: &'static str,
    },
}

impl Manual {
    pub fn reason(&self) -> &'static str {
        match self {
            Self::FlakeInputTag { reason, .. } | Self::NpmDependency { reason, .. } => reason,
        }
    }
}

const DARWIN: &[System] = &["aarch64-darwin", "x86_64-darwin"];

pub const PINS: &[Pin] = &[
    Pin {
        name: "claude-code",
        kind: Kind::Managed(Managed {
            upstream: Upstream::NpmPlatforms {
                version_package: "@anthropic-ai/claude-code",
                packages: &[
                    ("aarch64-darwin", "@anthropic-ai/claude-code-darwin-arm64"),
                    ("x86_64-darwin", "@anthropic-ai/claude-code-darwin-x64"),
                    ("aarch64-linux", "@anthropic-ai/claude-code-linux-arm64"),
                    ("x86_64-linux", "@anthropic-ai/claude-code-linux-x64"),
                ],
            },
            artifact: Artifact::File,
            flake_attr: Some("claude-code"),
        }),
    },
    Pin {
        name: "codex-desktop",
        kind: Kind::Managed(Managed {
            upstream: Upstream::Sparkle {
                feeds: &[
                    (
                        "aarch64-darwin",
                        "https://persistent.oaistatic.com/codex-app-prod/appcast.xml",
                    ),
                    (
                        "x86_64-darwin",
                        "https://persistent.oaistatic.com/codex-app-prod/appcast-x64.xml",
                    ),
                ],
                version: SparkleVersion::ShortVersionString,
            },
            artifact: Artifact::File,
            flake_attr: Some("codex-desktop"),
        }),
    },
    Pin {
        name: "omp",
        kind: Kind::Managed(Managed {
            upstream: Upstream::GithubRelease {
                repo: "can1357/oh-my-pi",
                assets: &[
                    ("aarch64-darwin", "omp-darwin-arm64"),
                    ("x86_64-darwin", "omp-darwin-x64"),
                    ("aarch64-linux", "omp-linux-arm64"),
                    ("x86_64-linux", "omp-linux-x64"),
                ],
            },
            artifact: Artifact::File,
            flake_attr: Some("omp"),
        }),
    },
    Pin {
        name: "orbstack",
        kind: Kind::Managed(Managed {
            upstream: Upstream::OrbStackRedirect {
                system: "x86_64-darwin",
                url: "https://orbstack.dev/download/stable/latest/amd64",
            },
            artifact: Artifact::File,
            flake_attr: Some("orbstack"),
        }),
    },
    Pin {
        name: "spotify",
        kind: Kind::Managed(Managed {
            upstream: Upstream::UnversionedDmg {
                systems: &["aarch64-darwin"],
                url: "https://download.scdn.co/SpotifyARM64.dmg",
                info_plist: "Spotify/Spotify.app/Contents/Info.plist",
            },
            artifact: Artifact::File,
            flake_attr: Some("spotify"),
        }),
    },
    Pin {
        name: "tailscale",
        kind: Kind::Managed(Managed {
            upstream: Upstream::TailscaleStable { systems: DARWIN },
            artifact: Artifact::File,
            flake_attr: None,
        }),
    },
    Pin {
        name: "whatsapp",
        kind: Kind::Managed(Managed {
            upstream: Upstream::Sparkle {
                feeds: &[
                    (
                        "aarch64-darwin",
                        "https://web.whatsapp.com/desktop/mac_native/updates/?branch=master&configuration=Release",
                    ),
                    (
                        "x86_64-darwin",
                        "https://web.whatsapp.com/desktop/mac_native/updates/?branch=master&configuration=Release",
                    ),
                ],
                version: SparkleVersion::EnclosureQuery("version"),
            },
            // Matches `name` in pkgs/whatsapp/default.nix.
            artifact: Artifact::UnpackedZip {
                name: "WhatsApp.app",
            },
            flake_attr: Some("whatsapp"),
        }),
    },
    Pin {
        name: "wispr-flow",
        kind: Kind::Managed(Managed {
            upstream: Upstream::WisprReleases {
                feeds: &[
                    (
                        "aarch64-darwin",
                        "https://dl.wisprflow.com/wispr-flow/darwin/arm64/RELEASES.json",
                    ),
                    (
                        "x86_64-darwin",
                        "https://dl.wisprflow.com/wispr-flow/darwin/x64/RELEASES.json",
                    ),
                ],
            },
            artifact: Artifact::File,
            flake_attr: Some("wispr-flow"),
        }),
    },
    Pin {
        name: "notion-cli",
        kind: Kind::Manual(Manual::FlakeInputTag {
            input: "notion-cli",
            repo: "lox/notion-cli",
            reason: "edit the notion-cli input tag and vendorHash in flake.nix",
        }),
    },
    Pin {
        name: "oracle",
        kind: Kind::Manual(Manual::NpmDependency {
            package_json: "pkgs/oracle/package.json",
            package: "@steipete/oracle",
            reason: "follow the 7-day cooldown procedure in pkgs/oracle/default.nix",
        }),
    },
    Pin {
        name: "voxtype",
        kind: Kind::Manual(Manual::FlakeInputTag {
            input: "voxtype",
            repo: "peteonrails/voxtype",
            reason: "edit the voxtype input tag in flake.nix and regenerate pkgs/voxtype/Cargo.lock",
        }),
    },
];

pub fn find(name: &str) -> Option<&'static Pin> {
    PINS.iter().find(|pin| pin.name == name)
}

#[cfg(test)]
mod tests {
    use super::PINS;

    /// `find` returns the first match, so a duplicate name would shadow a pin.
    #[test]
    fn pin_names_are_unique() {
        let mut names: Vec<_> = PINS.iter().map(|pin| pin.name).collect();
        let count = names.len();
        names.sort_unstable();
        names.dedup();
        assert_eq!(names.len(), count);
    }
}
