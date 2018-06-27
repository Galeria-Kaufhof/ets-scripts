#!/usr/bin/env bash

set -e

echo -n "Release version: "
read RELEASE_VERSION

DEPLOYMENT_REPOSITORIES="$@"
 
if ! [[ "$RELEASE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Version does not match the expected scheme MAJOR.MINOR.BUGFIX"
    exit 1
fi

if [ -z "$DEPLOYMENT_REPOSITORIES" ]; then
    echo "You did not pass repositories for artifact deployment"
    echo "To do so, use $0 [<repository>...]"
    exit 1
fi

for DEPLOYMENT_REPOSITORY in $DEPLOYMENT_REPOSITORIES; do
    # http://maven.apache.org/plugins/maven-deploy-plugin/deploy-mojo.html#altDeploymentRepository
    if ! [[ "$DEPLOYMENT_REPOSITORY" =~ ^(.*)::(.*)::(.*)$ ]]; then
        echo "Repository $DEPLOYMENT_REPOSITORY does not match the expected scheme ID::LAYOUT::URL"
        exit 1
    fi
done

SCRIPT_DIR="$(cd $(dirname ${BASH_SOURCE[0]}) && pwd)"

MAJOR_VERSION=$(echo $RELEASE_VERSION | cut -d '.' -f1)
MINOR_VERSION=$(echo $RELEASE_VERSION | cut -d '.' -f2)

DEVELOPMENT_VERSION="$MAJOR_VERSION.$(($MINOR_VERSION + 1)).0-SNAPSHOT"

RELEASE_BRANCH="${MAJOR_VERSION}.x"
RELEASE_TAG="$RELEASE_VERSION"

# Checkout to release branch
git checkout "$RELEASE_BRANCH"

# Create release commit and tag
mvn versions:set -DnewVersion="$RELEASE_VERSION" -DgenerateBackupPoms="false" -DprocessAllModules="true"

git commit -a -m "[release] Update POM versions to release $RELEASE_VERSION"
git tag -s -m "[release] Release version $RELEASE_TAG" "$RELEASE_TAG"

# Create development commit
mvn versions:set -DnewVersion="$DEVELOPMENT_VERSION" -DgenerateBackupPoms="false" -DprocessAllModules="true"

git commit -a -m "[release] Update POM versions to development $DEVELOPMENT_VERSION"

# Build and publish release artifacts
git checkout "$RELEASE_TAG"

mvn clean package

for DEPLOYMENT_REPOSITORY in $DEPLOYMENT_REPOSITORIES; do
    # https://maven.apache.org/plugins/maven-gpg-plugin/examples/deploy-signed-artifacts.html
    mvn verify gpg:sign deploy -DaltDeploymentRepository="$DEPLOYMENT_REPOSITORY"
done

# Push commits
git checkout "$RELEASE_BRANCH"

GIT_UPSTREAM_URL=$("$SCRIPT_DIR/git-upstream-url.py")
git push "$GIT_UPSTREAM_URL" "$RELEASE_BRANCH"
git push "$GIT_UPSTREAM_URL" "$RELEASE_TAG"
