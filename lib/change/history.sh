#!/usr/bin/env bash
# history.sh — the pure, branch-free shaping of a change's history. It reads a
# sequence of steps as TSV lines `type<TAB>scope` (oldest first) and prints the
# units, ordered by each concern's first appearance, as
# `member-indexes<TAB>type<TAB>scope<TAB>concerns`.
#
# Grouping is BY CONCERN (the step's scope), never by contiguity: every step of
# a concern belongs to exactly one unit, no matter where it sits in the history.
# The set of units therefore depends only on which concerns are present; the
# order is the first appearance of each concern, never alphabetical. There is no
# fixed-point iteration: each emitted unit carries its concern, so re-planning an
# emitted shape yields the same shape by construction.
#
# The number of units is a repository-declared policy (see shape-change-history):
#   * one-per-concern — the documented default; one unit per concern;
#   * single-unit     — the whole change becomes one unit;
#   * max:<N>         — at most N units; when there are more concerns than N the
#                       overflow folds deterministically into the last unit,
#                       never dropping a concern.
#
# `history_units <policy> [limit]` reads the steps TSV on stdin.

swe_source_once core.sh

# shellcheck disable=SC2016
readonly HISTORY_AWK='
BEGIN { FS="\t"; n=0; kc=0 }
{
  t[n]=$1; s[n]=$2
  if (!(s[n] in seen)) { seen[s[n]]=kc; ocv[kc]=s[n]; kc++ }
  n++
}
END {
  if (kc==0) exit
  nu=0
  if (policy=="single-unit") {
    nu=1; uconc[1]=""
    for (c=0;c<kc;c++) uconc[1]=(uconc[1]==""?c:uconc[1]" "c)
  } else if (policy=="max" && limit>0 && kc>limit) {
    # The first N-1 concerns keep their unit; every remaining concern folds into
    # the Nth unit. Deterministic, and no concern is dropped.
    for (c=0;c<kc;c++) {
      if (c < limit-1) { nu++; uconc[nu]=c }
      else if (nu < limit) { nu++; uconc[nu]=c }
      else uconc[nu]=uconc[nu]" "c
    }
  } else {
    for (c=0;c<kc;c++) { nu++; uconc[nu]=c }
  }
  for (u=1;u<=nu;u++) {
    split(uconc[u], cc, " ")
    mem=""; lead_type=""; lead_scope=""; lead_set=0
    for (i=0;i<n;i++) {
      ci=seen[s[i]]; hit=0
      for (j=1;j<=length(cc);j++) if (cc[j]==ci) { hit=1; break }
      if (!hit) continue
      mem=(mem==""?i:mem " " i)
      if (!lead_set) { lead_type=t[i]; lead_scope=s[i]; lead_set=1 }
    }
    # The concerns this unit carries, in first-appearance order.
    concerns=""
    for (j=1;j<=length(cc);j++) concerns=(concerns==""?ocv[cc[j]]:concerns" "ocv[cc[j]])
    printf "%s\t%s\t%s\t%s\n", mem, lead_type, lead_scope, concerns
  }
}
'

# `history_units <policy> [limit]` — the pure grouping over TSV steps on stdin.
history_units() {
  awk -v policy="${1:-one-per-concern}" -v limit="${2:-0}" "$HISTORY_AWK"
}
