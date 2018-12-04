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
    if [ -z "$RELEASE_VERSION" ]; then
        echo -n "Release version: "
        read RELEASE_VERSION
    fi

    if ! valid_version "$RELEASE_VERSION"; then
        echo "Version does not match the expected scheme MAJOR.MINOR.BUGFIX"
        exit 1
    fi

    MAJOR_VERSION=$(echo $RELEASE_VERSION | cut -d '.' -f1)
    MINOR_VERSION=$(echo $RELEASE_VERSION | cut -d '.' -f2)

    DEVELOPMENT_VERSION="$MAJOR_VERSION.$(($MINOR_VERSION + 1)).0-SNAPSHOT"

    RELEASE_BRANCH="${MAJOR_VERSION}.x.x"
    RELEASE_TAG="$RELEASE_VERSION"
}

function valid_version {
    [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] && return $?
}

function build_files {
    local ARTIFACT_DIRECTORY="$1"
    [[ -z "$ARTIFACT_DIRECTORY" ]] && read -p "Local artifact directory: " ARTIFACT_DIRECTORY

    # Checkout to release branch
    git checkout "$RELEASE_BRANCH"

    # Create release commit and tag
    mvn versions:set -DnewVersion="$RELEASE_VERSION" -DgenerateBackupPoms="false" -DprocessAllModules="true"

    git commit -a -m "[release] Update POM versions to release $RELEASE_VERSION"

    GIT_TAG_SIGNING_ARGS=(-s)
    if [ -n "$GPG_RELEASE_KEY_ID" ]; then
        GIT_TAG_SIGNING_ARGS+=(-u "$GPG_RELEASE_KEY_ID")
    fi
    
    git tag "${GIT_TAG_SIGNING_ARGS[@]}" -m "[release] Release version $RELEASE_TAG" "$RELEASE_TAG"

    # Create development commit
    mvn versions:set -DnewVersion="$DEVELOPMENT_VERSION" -DgenerateBackupPoms="false" -DprocessAllModules="true"

    git commit -a -m "[release] Update POM versions to development $DEVELOPMENT_VERSION"

    # Build and publish release artifacts
    git checkout "$RELEASE_TAG"

    mvn clean

    GPG_MAVEN_SIGNING_ARGS=(gpg:sign)
    if [ -n "$GPG_RELEASE_KEY_ID" ]; then
        GPG_MAVEN_SIGNING_ARGS+=(-Dkeyname="$GPG_RELEASE_KEY_ID")
    fi

    mvn package source:jar net.alchim31.maven:scala-maven-plugin:3.4.1:doc-jar "${GPG_MAVEN_SIGNING_ARGS[@]}"  deploy -DaltDeploymentRepository="local::default::file:$ARTIFACT_DIRECTORY"

    echo "Deployed locally built files to $ARTIFACT_DIRECTORY"
    echo "To deploy the files to a remote repository, use $0 --deploy $ARTIFACT_DIRECTORY"
    echo
    echo "The Maven central deployment repository url is https://oss.sonatype.org/service/local/staging/deploy/maven2"
    echo "For more information see https://central.sonatype.org/pages/ossrh-guide.html#accessing-repositories"
    echo "To deploy the files to the Maven central repository, use RELEASE_VERSION='$RELEASE_VERSION' DEPLOYMENT_REPOSITORY='https://oss.sonatype.org/service/local/staging/deploy/maven2' $0 --deploy $ARTIFACT_DIRECTORY"
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
    local FILES_FOR_DEPLOYMENT="$(cd "$ARTIFACT_DIRECTORY" && find * -type f | sort)"

    local FILE_DEPLOYMENT_COUNTER=1
    local NUMBER_OF_FILES_FOR_DEPLOYMENT="$(echo $FILES_FOR_DEPLOYMENT | wc -w)"
    for LOCAL_FILE in $FILES_FOR_DEPLOYMENT; do
        REMOTE_FILE="$DEPLOYMENT_REPOSITORY/$LOCAL_FILE"
        LOCAL_FILE_PATH="$ARTIFACT_DIRECTORY/$LOCAL_FILE"

        echo "[$FILE_DEPLOYMENT_COUNTER/$NUMBER_OF_FILES_FOR_DEPLOYMENT] Uploading $LOCAL_FILE_PATH to $REMOTE_FILE"
        curl -L -f -u "$UPLOAD_USER":"$UPLOAD_PASSWORD" --upload-file "$LOCAL_FILE_PATH" "$REMOTE_FILE"
        FILE_DEPLOYMENT_COUNTER=$((FILE_DEPLOYMENT_COUNTER + 1))
    done

    # Push commits
    git checkout "$RELEASE_BRANCH"

    GIT_UPSTREAM_URL=$("$SCRIPT_DIR/git-upstream-url.py")
    git push "$GIT_UPSTREAM_URL" "$RELEASE_BRANCH"
    git push "$GIT_UPSTREAM_URL" "$RELEASE_TAG"
}

function merge_branches {
    GIT_UPSTREAM_URL=$("$SCRIPT_DIR/git-upstream-url.py")
    GIT_REMOTE_NAME="upstream"

    # Check remote
    if git ls-remote --exit-code $GIT_REMOTE_NAME > /dev/null; then
        if [ "$(git remote get-url $GIT_REMOTE_NAME)" != "$GIT_UPSTREAM_URL" ]; then
            SET_GIT_UPSTREAM_URL="$(git remote git-url $GIT_REMOTE_NAME)"
            echo "Remote $GIT_REMOTE_NAME exists, but URL is $SET_GIT_UPSTREAM_URL instead of $GIT_UPSTREAM_URL"
            echo "You can use 'git remote set-url $GIT_REMOTE_NAME $GIT_UPSTREAM_URL' to update your remote url"
            exit 1
        fi
    else
        echo "Remote $GIT_REMOTE_NAME does not exist, adding with URL $GIT_UPSTREAM_URL"
        git remote add "$GIT_REMOTE_NAME" "$GIT_UPSTREAM_URL"
    fi

    # Update remote
    git fetch "$GIT_REMOTE_NAME"

    MAJOR_BRANCHES=($(git for-each-ref --format="%(refname:lstrip=-1)" "refs/remotes/$GIT_REMOTE_NAME" | grep -E "^[0-9]+\.x\.x$" | sort -n) master)

    local INDEX=0
    while [ $INDEX -lt $((${#MAJOR_BRANCHES[@]} - 1)) ];
    do
        local SOURCE_BRANCH="${MAJOR_BRANCHES[$INDEX]}"
        local DESTINATION_BRANCH="${MAJOR_BRANCHES[$((INDEX + 1))]}"

        # Merge remote branch into local branch
        if git rev-parse --quiet --verify "$SOURCE_BRANCH" > /dev/null; then
            git checkout "$SOURCE_BRANCH"
            git pull "$GIT_REMOTE_NAME" "$SOURCE_BRANCH"
        else
            git checkout --track "$GIT_REMOTE_NAME"/"$SOURCE_BRANCH"
        fi

        read -n1 -p "Merge $SOURCE_BRANCH to $DESTINATION_BRANCH and push changes? (Y/n) " MERGE_BRANCH
        echo

        if [ -z "$MERGE_BRANCH" -o "$MERGE_BRANCH" = "y" -o "$MERGE_BRANCH" = "Y" ]; then
            if git rev-parse --quiet --verify "$DESTINATION_BRANCH" > /dev/null; then
                git checkout "$DESTINATION_BRANCH"
                git pull "$GIT_REMOTE_NAME" "$DESTINATION_BRANCH"
            else
                git checkout --track "$GIT_REMOTE_NAME"/"$DESTINATION_BRANCH"
            fi

            git merge "$SOURCE_BRANCH"
            git push "$GIT_UPSTREAM_URL" "$DESTINATION_BRANCH"
        fi

        INDEX=$((INDEX + 1))
    done
}

function abort_build {
    # Checkout to release branch
    git checkout "$RELEASE_BRANCH"

    local COMMITS_TO_RESET=0
    if git log -1 --pretty=%B | grep -qF "[release] Update POM versions to release $RELEASE_VERSION"; then
        COMMITS_TO_RESET=1
    elif git log -1 --pretty=%B | grep -qF "[release] Update POM versions to development $DEVELOPMENT_VERSION"; then
        COMMITS_TO_RESET=2
    fi

    # Remove tag
    if [ $(git tag -l "$RELEASE_TAG") ]; then
        echo -n "=== Remove tag $RELEASE_TAG? [y/n]:"
        read REMOVE_TAG

        if [ "$REMOVE_TAG" == "y" ]; then
            git tag -d "$RELEASE_TAG"
        fi
    fi

    # Reset commits
    if [ $COMMITS_TO_RESET -gt 0 ]; then
        echo
        echo -n "=== Reset $COMMITS_TO_RESET commits and branch $(git rev-parse --abbrev-ref HEAD) to"$'\n'"$(git log -1 HEAD~$COMMITS_TO_RESET)"$'\n'"?[y/n]:"
        read RESET_COMMITS

        if [ "$RESET_COMMITS" == "y" ]; then
            git reset --hard HEAD~$COMMITS_TO_RESET
        fi
    fi

    # Remove files
    echo -n "=== Remove built files? [y/n]:"
    read REMOVE_BUILT_FILES

    if [ "$REMOVE_BUILT_FILES" == "y" ]; then
        mvn clean
    fi
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

        deploy_files_to_repository "$2" "$DEPLOYMENT_REPOSITORY"
        ;;
    --build-and-deploy)
        initialize_version_and_git_vars

        ARTIFACT_DIRECTORY="$2"
        [[ -z "$ARTIFACT_DIRECTORY" ]] && ARTIFACT_DIRECTORY="$(mk_temp_directory)"

        build_files "$ARTIFACT_DIRECTORY"
        deploy_files_to_repository "$ARTIFACT_DIRECTORY" "$DEPLOYMENT_REPOSITORY"
        ;;
    --abort-build)
        initialize_version_and_git_vars

        abort_build
        ;;
    --merge-branches)
        merge_branches
        ;;

    *)
        echo "Usage: $0 [--abort-build/--build/--build-and-deploy/--deploy/--merge-branches]"
        exit 1
esac
