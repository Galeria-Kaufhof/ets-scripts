#!/usr/bin/env bash

set -e

PR_URL="$1"
LOWEST_RELEASE_VERSION="$2"

parts=(${1//\// })
pr=${parts[${#parts[@]}-1]}

hub am -3 $1

COMMIT_ID="foobar"
OLDEST_VERSION="1"

git checkout $OLDEST_VERSION.x

git cherry-pick $COMMIT_ID
git commit --edit --amend -F <(echo -ne "$(git log -1 --format=format:%B)\n\ncloses #$pr")

PREVIOUS_VERSION="$OLDEST_VERSION"
CURRENT_VERSION="$($PREVIOUS_VERSION + 1)"
while [ $(git rev-parse --verify $CURRENT_VERSION.x) exists ]; do
	git checkout $CURRENT_VERSION.x
	git merge PREVIOUS_VERSION.x

	if conflicts; then
		find -name "pom.xml" | xargs git checkout --theirs/--yours
	fi

	if still_conflicts; then
		anhalten
		in subshell lösen und committen
		oder in idea
	fi

	git push origin $CURRENT_VERSION.x

	PREVIOUS_VERSION="$CURRENT_VERSION"
	CURRENT_VERSION="$($CURRENT_VERSION + 1)"
done
+ master

