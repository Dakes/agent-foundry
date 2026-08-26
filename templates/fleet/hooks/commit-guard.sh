#!/usr/bin/env bash
#
# Agent Foundry - fleet git guard (PreToolUse on Bash)
#
# "Agents never commit; the orchestrator lands, and only what it has verified"
# is the fleet's central safety property. A rule that exists only in prose is a
# rule that holds until an agent is in a hurry.
#
# Two separate rules, because they exist for different reasons:
#
# 1. LANDING VERBS - commit, push, merge, rebase, tag.
#    Routed through `fleet-land`, which runs the gate before it commits. This
#    is a route rather than a restriction: it makes landing-without-measuring
#    something nobody can do by accident, including the orchestrator.
#
# 2. DESTRUCTIVE FORMS - stash, clean, reset --hard, checkout --, restore.
#    Denied outright to everyone. The tree is shared: several agents have
#    uncommitted work in it at once, and every one of these commands destroys
#    work belonging to whoever else is in there. `git stash` is the classic -
#    it sweeps up foreign work along with the caller's, and the caller has no
#    idea it happened.
#
# Everything else is untouched. Branch work (`git checkout -b`, `git switch`),
# and all of read-only git - status, diff, log, show, blame - are how an agent
# proves anything at all, and denying them would only push the work into a
# shell alias where no hook can see it.
#

set -uo pipefail

_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./fleet-runtime.sh
source "${_dir}/fleet-runtime.sh"

payload=$(cat)

tool=$(fleet_field "$payload" '.tool_name')
[[ "$tool" == "Bash" ]] || fleet_allow

cmd=$(fleet_field "$payload" '.tool_input.command')
[[ -n "$cmd" ]] || fleet_allow

# A git invocation at the start of the string or after a shell separator, with
# any leading git-level flags (-C dir, --no-pager) stepped over. Anchoring this
# way keeps `git log --grep=commit`, `./scripts/commit.sh` and `echo push` out
# of it - all three used to be false positives on a naive substring match.
_git_re() {
    printf '(^|[;&|]|&&|\\|\\|)[[:space:]]*git([[:space:]]+(-C[[:space:]]+[^[:space:]]+|-[^[:space:]]+))*[[:space:]]+%s' "$1"
}

_matches() {
    printf '%s' "$cmd" | grep -qE "$(_git_re "$1")"
}

# --------------------------------------------------------------------------
# 1. Destructive forms - denied to everyone, no sanctioned alternative
# --------------------------------------------------------------------------
_destructive() {
    _matches 'stash([[:space:]]|$)'            && return 0
    _matches 'clean([[:space:]]|$)'            && return 0
    _matches 'restore([[:space:]]|$)'          && return 0
    _matches 'reset[[:space:]]+--hard'         && return 0
    _matches 'checkout[[:space:]]+--([[:space:]]|$)' && return 0
    _matches 'checkout[[:space:]]+\.([[:space:]]|$)' && return 0
    return 1
}

if _destructive; then
    fleet_log WARN "commit-guard: denied destructive git in: $cmd"
    fleet_deny "THAT COMMAND DISCARDS WORK, AND THE TREE IS SHARED.

Other agents have uncommitted changes in this same working tree right now. stash, clean, restore, reset --hard and checkout -- take their work along with yours, and they will not find out until their round fails for reasons that make no sense.

If you need to undo your own change, edit the file back. If you need a clean copy of something to compare against, read it out of git with \`git show HEAD:<path>\` instead of moving the tree.

If you believe the tree is genuinely broken, stop and report that - it is the orchestrator's call, not yours."
fi

# --------------------------------------------------------------------------
# 2. Landing verbs - routed through the gate
# --------------------------------------------------------------------------
for verb in commit push merge rebase tag; do
    if _matches "${verb}([[:space:]]|$)"; then
        fleet_log WARN "commit-guard: routed 'git $verb' to fleet-land"
        fleet_deny "GIT ${verb^^} DOES NOT RUN DIRECTLY IN A FLEET RUN.

Work lands through the gate, or it does not land:

    fleet-land -m 'message' -- <paths...>     verify and commit
    fleet-land --push [branch]                publish a verified branch

fleet-land runs the gate first and refuses while it is failing. That is the point of it.

If you are a builder or a critic, you do not land anything at all: leave your work in the tree, describe it in your report, and the orchestrator verifies and lands it.

Do not reach for another way to run git. There isn't one that skips the gate."
    fi
done

fleet_allow
