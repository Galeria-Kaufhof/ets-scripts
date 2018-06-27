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

declare -A DEPLOYMENT_USERS
declare -A DEPLOYMENT_PASSWORDS

for DEPLOYMENT_REPOSITORY in $DEPLOYMENT_REPOSITORIES; do
    echo "Reading credentials for $DEPLOYMENT_REPOSITORY"
    
    read -p "Upload username: " UPLOAD_USER
    read -s -p "Upload password: " UPLOAD_PASSWORD

    DEPLOYMENT_USERS["$DEPLOYMENT_REPOSITORY"]="$UPLOAD_USER"
    DEPLOYMENT_PASSWORDS["$DEPLOYMENT_REPOSITORY"]="$UPLOAD_PASSWORD"
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

TEMP_ARTIFACT_DIR="$(mktemp -d -p target --suffix .artifacts)"

mvn clean
mvn package source:jar javadoc:jar gpg:sign deploy -DaltDeploymentRepository="local::default::file:$TEMP_ARTIFACT_DIR"

for DEPLOYMENT_REPOSITORY in $DEPLOYMENT_REPOSITORIES; do
    # Sort files, because Artifactory refuses md5 sum files if the file for the sum does not exist before
    for LOCAL_FILE in $(cd "$TEMP_ARTIFACT_DIR" && find * -type f | sort); do
        REMOTE_FILE="$DEPLOYMENT_REPOSITORY/$LOCAL_FILE"
        LOCAL_FILE_PATH="$TEMP_ARTIFACT_DIR/$LOCAL_FILE"

        echo "Uploading $LOCAL_FILE_PATH to $REMOTE_FILE"
        curl -L -f -u "${DEPLOYMENT_USERS["$DEPLOYMENT_REPOSITORY"]}":"${DEPLOYMENT_PASSWORDS["$DEPLOYMENT_REPOSITORY"]}" --upload-file "$LOCAL_FILE_PATH" "$REMOTE_FILE"
    done
done

# Push commits
git checkout "$RELEASE_BRANCH"

GIT_UPSTREAM_URL=$("$SCRIPT_DIR/git-upstream-url.py")
git push "$GIT_UPSTREAM_URL" "$RELEASE_BRANCH"
git push "$GIT_UPSTREAM_URL" "$RELEASE_TAG"
