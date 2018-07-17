#!/usr/bin/env bash

set -e

SCRIPT_DIR="$(cd $(dirname ${BASH_SOURCE[0]}) && pwd)"

function mk_temp_directory {
    TEMP_ARTIFACT_ROOT_DIR="target"
    mkdir -p "$TEMP_ARTIFACT_ROOT_DIR"

    TEMP_ARTIFACT_DIR="$(mktemp -d -p $TEMP_ARTIFACT_ROOT_DIR --suffix .artifacts)"

    echo "$TEMP_ARTIFACT_DIR"
}

function initialize_version_and_git_vars {
    echo -n "Release version: "
    read RELEASE_VERSION

    if ! [[ "$RELEASE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "Version does not match the expected scheme MAJOR.MINOR.BUGFIX"
        exit 1
    fi

    MAJOR_VERSION=$(echo $RELEASE_VERSION | cut -d '.' -f1)
    MINOR_VERSION=$(echo $RELEASE_VERSION | cut -d '.' -f2)

    DEVELOPMENT_VERSION="$MAJOR_VERSION.$(($MINOR_VERSION + 1)).0-SNAPSHOT"

    RELEASE_BRANCH="${MAJOR_VERSION}.x.x"
    RELEASE_TAG="$RELEASE_VERSION"
}

function build_files {
    local ARTIFACT_DIRECTORY="$1"
    [[ -z "$ARTIFACT_DIRECTORY" ]] && read -p "Local artifact directory: " ARTIFACT_DIRECTORY

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

    mvn clean
    mvn package source:jar net.alchim31.maven:scala-maven-plugin:3.4.1:doc-jar gpg:sign deploy -DaltDeploymentRepository="local::default::file:$ARTIFACT_DIRECTORY"

    echo "Deployed locally built files to $ARTIFACT_DIRECTORY"
    echo "To deploy the files to a remote repository, use $0 --deploy $ARTIFACT_DIRECTORY"
}

function deploy_files_to_repository {
    local ARTIFACT_DIRECTORY="$1"
    local DEPLOYMENT_REPOSITORY="$2"
    local UPLOAD_USER="$3"
    local UPLOAD_PASSWORD="$4"

    [[ -z "$ARTIFACT_DIRECTORY" ]] && read -p "Local artifact directory: " ARTIFACT_DIRECTORY
    [[ -z "$DEPLOYMENT_REPOSITORY" ]] && read -p "Deployment repository: " DEPLOYMENT_REPOSITORY
    [[ -z "$UPLOAD_USER" ]] && read -p "Upload username: " UPLOAD_USER
    [[ -z "$UPLOAD_PASSWORD" ]] && read -s -p "Upload password: " UPLOAD_PASSWORD
    echo

    # Sort files, because Artifactory refuses md5 sum files if the file for the sum does not exist before
    for LOCAL_FILE in $(cd "$ARTIFACT_DIRECTORY" && find * -type f | sort); do
        REMOTE_FILE="$DEPLOYMENT_REPOSITORY/$LOCAL_FILE"
        LOCAL_FILE_PATH="$ARTIFACT_DIRECTORY/$LOCAL_FILE"

        echo "Uploading $LOCAL_FILE_PATH to $REMOTE_FILE"
        curl -L -f -u "$UPLOAD_USER":"$UPLOAD_PASSWORD" --upload-file "$LOCAL_FILE_PATH" "$REMOTE_FILE"
    done

    # Push commits
    git checkout "$RELEASE_BRANCH"

    GIT_UPSTREAM_URL=$("$SCRIPT_DIR/git-upstream-url.py")
    git push "$GIT_UPSTREAM_URL" "$RELEASE_BRANCH"
    git push "$GIT_UPSTREAM_URL" "$RELEASE_TAG"
}

case "$1" in
    --build)
        initialize_version_and_git_vars

        ARTIFACT_DIRECTORY="$2"
        [[ -z "$ARTIFACT_DIRECTORY" ]] && ARTIFACT_DIRECTORY="$(mk_temp_directory)"

        build_files "$ARTIFACT_DIRECTORY"
        ;;
    --deploy)
        initialize_version_and_git_vars

        deploy_files_to_repository "$2"
        ;;
    --build-and-deploy)
        initialize_version_and_git_vars

        ARTIFACT_DIRECTORY="$2"
        [[ -z "$ARTIFACT_DIRECTORY" ]] && ARTIFACT_DIRECTORY="$(mk_temp_directory)"

        build_files "$ARTIFACT_DIRECTORY"
        deploy_files_to_repository "$ARTIFACT_DIRECTORY"
        ;;
    *)
        echo "Usage: $0 [--build/--build-and-deploy/--deploy]"
        exit 1
esac
