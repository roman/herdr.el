# herdr.el task runner

emacs := env_var_or_default("EMACS", "emacs")
lisp := "herdr-api.el herdr-session.el herdr-term.el"
tests := "test/herdr-api-tests.el test/herdr-session-tests.el test/herdr-term-tests.el"

# List the available recipes
default:
    @just --list

# Byte-compile, check declarations and doc strings, run tests
check: build check-declare checkdoc test

# Byte-compile the package and its tests, treating warnings as errors
build:
    #!/usr/bin/env bash
    set -euo pipefail
    load_path=$({{ just_executable() }} _load-path)
    for file in {{ lisp }} {{ tests }}; do
        printf 'Compiling %s\n' "$file"
        {{ emacs }} -Q --batch $load_path -L test \
            --eval '(setq byte-compile-error-on-warn t)' \
            --funcall batch-byte-compile "$file"
    done

# Run the ERT suites
test: build
    #!/usr/bin/env bash
    set -euo pipefail
    load_path=$({{ just_executable() }} _load-path)
    load=()
    for file in {{ tests }}; do
        load+=(-l "$(basename "$file" .el)")
    done
    {{ emacs }} -Q --batch $load_path -L test \
        "${load[@]}" -f ert-run-tests-batch-and-exit

# Run the ERT suites in a live Emacs, for stepping through a failure
test-interactive: build
    #!/usr/bin/env bash
    set -euo pipefail
    load_path=$({{ just_executable() }} _load-path)
    load=()
    for file in {{ tests }}; do
        load+=(-l "$(basename "$file" .el)")
    done
    {{ emacs }} -Q $load_path -L test "${load[@]}" --eval '(ert t)'

# Verify that every `declare-function' matches its definition
check-declare:
    #!/usr/bin/env bash
    set -euo pipefail
    load_path=$({{ just_executable() }} _load-path)
    printf 'Checking function declarations\n'
    {{ emacs }} -Q --batch $load_path \
        --eval '(check-declare-directory default-directory)'

# Check doc strings against checkdoc
checkdoc:
    #!/usr/bin/env bash
    set -euo pipefail
    load_path=$({{ just_executable() }} _load-path)
    printf 'Checking doc strings\n'
    # `checkdoc-file' reports to stderr and still exits successfully, so
    # the exit status is rebuilt from whether it said anything at all.
    {{ emacs }} -Q --batch $load_path -L test --eval '(progn
      (require (quote checkdoc))
      (let ((issues nil))
        (advice-add (quote checkdoc-error) :before
                    (lambda (&rest _) (setq issues t)))
        (dolist (file command-line-args-left) (checkdoc-file file))
        (when issues (kill-emacs 1))))' {{ lisp }} {{ tests }}

# Remove byte-compiled files
clean:
    #!/usr/bin/env bash
    set -euo pipefail
    printf 'Cleaning *.elc\n'
    for file in {{ lisp }} {{ tests }}; do
        rm -f "${file}c"
    done

# Print the -L flags for herdr.el and its dependencies.
#
# `emacs -Q' plus `package-initialize' finds a Nix, site-lisp or ELPA
# install without loading user init, which keeps the build reproducible.
# Set EMACS_LOAD_PATH when a dependency lives somewhere neither finds.
[private]
_load-path:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ -n "${EMACS_LOAD_PATH:-}" ]; then
        echo "-L . ${EMACS_LOAD_PATH}"
        exit 0
    fi
    echo "-L . $({{ emacs }} -Q --batch -f package-initialize --eval '
      (dolist (lib (list "ghostel"))
        (let ((file (locate-library lib)))
          (unless file
            (error "Cannot locate %s; set EMACS_LOAD_PATH" lib))
          (princ "-L ")
          (princ (directory-file-name (file-name-directory file)))
          (princ " ")))')"
