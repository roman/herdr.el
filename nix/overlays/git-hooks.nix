# The pre-commit hook the dev shell installs.
inputs:

final: prev: {
  herdr-el-git-hooks = inputs.git-hooks.lib.${prev.stdenv.hostPlatform.system}.run {
    src = ../../.;
    hooks.check = {
      enable = true;
      # `final`, so this does not depend on where the overlay that defines the
      # runner sits in the list.
      entry = prev.lib.getExe final.herdr-el-check;
      pass_filenames = false;
      stages = [ "pre-commit" ];
    };
  };
}
