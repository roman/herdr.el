# `just check` with its tools baked in, so the pre-commit hook holds whether the
# commit comes from the dev shell, from magit, or from an editor that inherited
# neither PATH.
{
  writeShellApplication,
  just,
  git,
  herdr-el-emacs,
}:

writeShellApplication {
  name = "herdr-el-check";

  runtimeInputs = [
    just
    git
    herdr-el-emacs
  ];

  text = ''
    just check
  '';
}
