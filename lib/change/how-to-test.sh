#!/usr/bin/env bash
# how-to-test.sh — how changes are verified in this repository. Pure detection:
# it reads the repository's own declarations and runs nothing. The ladder is
# deterministic and fail-closed, so "I could not find the tests" can never be
# mistaken for "the tests pass".

swe_source_once core.sh change/usage.sh

# A declared target in a task runner: the repository says exactly how to test.
_htt_declared_target() {
  local f
  for f in Makefile makefile GNUmakefile; do
    [[ -f $f ]] || continue
    if awk '/^test[[:space:]]*:/{found=1} END{exit !found}' "$f"; then
      printf 'make test\n'; return 0
    fi
  done
  local jf=''
  if [[ -f justfile ]]; then jf=justfile; fi
  if [[ -f Justfile ]]; then jf=Justfile; fi
  if [[ -n $jf ]] && awk '/^test[[:space:]]*:/{found=1} END{exit !found}' "$jf"; then
    printf 'just test\n'; return 0
  fi
  local t
  for t in Taskfile.yml Taskfile.yaml; do
    [[ -f $t ]] || continue
    if grep -qE '^[[:space:]]*test:' "$t"; then printf 'task test\n'; return 0; fi
  done
  return 1
}

# A declared script/manifest: the repository names its own test command.
_htt_declared_script() {
  if [[ -f package.json ]] && jq -e '.scripts.test // empty' package.json >/dev/null 2>&1; then
    printf 'npm test\n'; return 0
  fi
  if [[ -f pyproject.toml || -f tox.ini ]]; then printf 'pytest\n'; return 0; fi
  if [[ -f Cargo.toml ]]; then printf 'cargo test\n'; return 0; fi
  if [[ -f go.mod ]]; then printf 'go test ./...\n'; return 0; fi
  if [[ -f pom.xml ]]; then printf 'mvn test\n'; return 0; fi
  if [[ -f build.gradle || -f build.gradle.kts ]]; then printf './gradlew test\n'; return 0; fi
  if [[ -f Gemfile ]]; then printf 'bundle exec rspec\n'; return 0; fi
  return 1
}

# The automation job the repository runs: only the command it contains is
# interesting, and only the ones we can name deterministically are accepted.
_htt_automation_job() {
  local -a files=()
  local f
  for f in .github/workflows/*.yml .github/workflows/*.yaml .gitlab-ci.yml Jenkinsfile; do
    if [[ -f $f ]]; then files+=("$f"); fi
  done
  ((${#files[@]} > 0)) || return 1
  local cmd
  for cmd in 'make test' 'just test' 'task test' 'npm test' 'pytest' \
             'cargo test' 'go test ./...' 'mvn test' './gradlew test' 'bundle exec rspec'; do
    if grep -qF "$cmd" "${files[@]}" 2>/dev/null; then printf '%s\n' "$cmd"; return 0; fi
  done
  return 1
}

# The language's conventional suite, only when the tree really holds that language.
_htt_language_suite() {
  if compgen -G 'test_*.py' >/dev/null || compgen -G '*_test.py' >/dev/null; then
    printf 'pytest\n'; return 0
  fi
  if compgen -G '*_test.go' >/dev/null; then printf 'go test ./...\n'; return 0; fi
  if [[ -f Cargo.toml ]]; then printf 'cargo test\n'; return 0; fi
  return 1
}

# The detection ladder itself, shared by the verb and by the local
# verification policy's proof: ONE ladder, so "how this repo is tested" and
# "prove this repo's tests pass" can never name two different commands. Sets
# `_htt_command` and `_htt_from`; fails when the repository declares nothing.
_htt_detect() {
  _htt_command='' _htt_from=''
  if _htt_command=$(_htt_declared_target); then _htt_from=declared_target
  elif _htt_command=$(_htt_declared_script); then _htt_from=declared_script
  elif _htt_command=$(_htt_automation_job); then _htt_from=automation_job
  elif _htt_command=$(_htt_language_suite); then _htt_from=language_suite
  else return 1
  fi
}

cmd_how_to_test() {
  while [[ $# -gt 0 ]]; do
    case $1 in
      -h|--help) change_usage ;;
      *) fail "unknown_argument_$1" ;;
    esac
  done

  local command='' from=''
  if _htt_detect; then command=$_htt_command; from=$_htt_from; fi

  [[ -n $command ]] || fail "VERIFICATION_UNKNOWN" \
    "$(jq -nc '{searched: ["declared_target","declared_script","automation_job","language_suite"]}')"

  jq -nc --arg command "$command" --arg from "$from" \
    --argjson warnings "$(warnings_json)" \
    '{ok: true, command: $command, detected_from: $from, warnings: $warnings}'
  exit 0
}
