{ ... }:
{
  # npm and Yarn 1 read these from the environment, so the defaults apply
  # without managing ~/.npmrc, which may hold auth tokens.
  home.sessionVariables = {
    # Dependency lifecycle scripts are the usual npm worm payload. Allow them
    # per project when a package needs a native build.
    NPM_CONFIG_IGNORE_SCRIPTS = "true";
    YARN_IGNORE_SCRIPTS = "true";
    # Resolve only versions published at least 7 days ago (npm >= 11.10).
    NPM_CONFIG_MIN_RELEASE_AGE = "7";
  };
}
