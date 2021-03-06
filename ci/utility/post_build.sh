#!/bin/bash
set -e

# First parameter is required and is a boolean indicating if the build was a
# success. Second paremeter is an error message if the build was a failure.
send_sns_callback_message() {
    echo "Sending SNS message to CodeBuild callback topic"

    MSG="$2"

    # Construct the message attributes JSON
    MSGATR="{"

    # Required status code (always comes first, for the comma)
    MSGATR+="\"STATUS\": {\"DataType\": \"String\", \"StringValue\": \"$1\"}"

    # Non-optional values
    MSGATR+=",\"CODEBUILD_BUILD_ARN\": {\"DataType\": \"String\", \"StringValue\": \"$CODEBUILD_BUILD_ARN\"}"
    MSGATR+=",\"PRX_AWS_ACCOUNT_ID\": {\"DataType\": \"String\", \"StringValue\": \"$PRX_AWS_ACCOUNT_ID\"}"
    MSGATR+=",\"PRX_REPO\": {\"DataType\": \"String\", \"StringValue\": \"$PRX_REPO\"}"
    MSGATR+=",\"PRX_COMMIT\": {\"DataType\": \"String\", \"StringValue\": \"$PRX_COMMIT\"}"
    MSGATR+=",\"PRX_BRANCH\": {\"DataType\": \"String\", \"StringValue\": \"$PRX_BRANCH\"}"

    # Optional GitHub pull request number parameter (pass-through)
    [ -z "$PRX_GITHUB_PR" ] || MSGATR+=",\"PRX_GITHUB_PR\": {\"DataType\": \"String\", \"StringValue\": \"$PRX_GITHUB_PR\"}"

    # Optional ECR parameters
    [ -z "$PRX_ECR_REGION" ] || MSGATR+=",\"PRX_ECR_REGION\": {\"DataType\": \"String\", \"StringValue\": \"$PRX_ECR_REGION\"}"
    [ -z "$PRX_ECR_REPOSITORY" ] || MSGATR+=",\"PRX_ECR_REPOSITORY\": {\"DataType\": \"String\", \"StringValue\": \"$PRX_ECR_REPOSITORY\"}"
    [ -z "$PRX_ECR_CONFIG_PARAMETERS" ] || MSGATR+=",\"PRX_ECR_CONFIG_PARAMETERS\": {\"DataType\": \"String\", \"StringValue\": \"$PRX_ECR_CONFIG_PARAMETERS\"}"
    [ -z "$PRX_ECR_IMAGE" ] || MSGATR+=",\"PRX_ECR_IMAGE\": {\"DataType\": \"String\", \"StringValue\": \"$PRX_ECR_IMAGE\"}"
    [ -z "$PRX_ECR_TAG" ] || MSGATR+=",\"PRX_ECR_TAG\": {\"DataType\": \"String\", \"StringValue\": \"$PRX_ECR_TAG\"}"

    # Optional Lambda code parameters
    [ -z "$PRX_LAMBDA_CODE_S3_KEY" ] || MSGATR+=",\"PRX_LAMBDA_CODE_S3_KEY\": {\"DataType\": \"String\", \"StringValue\": \"$PRX_LAMBDA_CODE_S3_KEY\"}"
    [ -z "$PRX_LAMBDA_CODE_S3_VERSION_ID" ] || MSGATR+=",\"PRX_LAMBDA_CODE_S3_VERSION_ID\": {\"DataType\": \"String\", \"StringValue\": \"$PRX_LAMBDA_CODE_S3_VERSION_ID\"}"
    [ -z "$PRX_LAMBDA_CODE_CONFIG_PARAMETERS" ] || MSGATR+=",\"PRX_LAMBDA_CODE_CONFIG_PARAMETERS\": {\"DataType\": \"String\", \"StringValue\": \"$PRX_LAMBDA_CODE_CONFIG_PARAMETERS\"}"

    # Optional S3 static site parameters
    [ -z "$PRX_S3_STATIC_S3_KEY" ] || MSGATR+=",\"PRX_S3_STATIC_S3_KEY\": {\"DataType\": \"String\", \"StringValue\": \"$PRX_S3_STATIC_S3_KEY\"}"
    [ -z "$PRX_S3_STATIC_S3_VERSION_ID" ] || MSGATR+=",\"PRX_S3_STATIC_S3_VERSION_ID\": {\"DataType\": \"String\", \"StringValue\": \"$PRX_S3_STATIC_S3_VERSION_ID\"}"
    [ -z "$PRX_S3_STATIC_CONFIG_PARAMETERS" ] || MSGATR+=",\"PRX_S3_STATIC_CONFIG_PARAMETERS\": {\"DataType\": \"String\", \"StringValue\": \"$PRX_S3_STATIC_CONFIG_PARAMETERS\"}"

    MSGATR+="}"

    echo "$MSGATR"

    OUT=$(aws sns publish --topic-arn "$PRX_SNS_CALLBACK" --message "$MSG" --message-attributes "$MSGATR")

    SNS_CLI_CODE=$?
    if [ $SNS_CLI_CODE -eq 0 ]; then
        echo "Sent SNS message: $MSG"
    else
        echo "Failed to send SNS message: $MSG"
        exit $SNS_CLI_CODE
    fi
}

build_success() {
    echo "Script completed successfully!"
    send_sns_callback_message true "Success"
    exit 0
}

build_error() {
    echo "Script did not complete successfully: $1"
    send_sns_callback_message false "$1"
    exit 1
}

# If PRX_ECR_REPOSITORY is present, we try to push to ECR
push_to_ecr() {
    if [ -n "$PRX_ECR_REPOSITORY" ]
    then
        if [ -z "$PRX_ECR_REGION" ]; then build_error "PRX_ECR_REGION required for ECR push"; fi
        if [ -z "$PRX_ECR_CONFIG_PARAMETERS" ]; then build_error "PRX_ECR_CONFIG_PARAMETERS required for ECR push"; fi
        echo "Handling ECR push..."

        echo "Logging into ECR..."
        $(aws ecr get-login --no-include-email --region $PRX_ECR_REGION)
        echo "...Logged in to ECR"

        # Need to allow errors temporarily to check if the repo exists
        set +e
        aws ecr describe-repositories --repository-names "$PRX_ECR_REPOSITORY" > /dev/null 2>&1
        if [ $? -eq 0 ]
        then
            echo "ECR Repository already exists"
        else
            echo "Creating ECR repository"
            aws ecr create-repository --repository-name "$PRX_ECR_REPOSITORY"
        fi
        set -e

        echo "Getting Docker image ID"
        IMAGE_ID=$(docker images --filter "label=org.prx.app" --format "{{.ID}}" | head -n 1)

        if [ -z "$IMAGE_ID" ]; then
            build_error "No Docker image found; ensure at least one Dockerfile has an org.prx.app label"
        else
            # Construct the image name with a tag
            TAG="${PRX_COMMIT:0:7}"
            export PRX_ECR_TAG="$TAG"
            TAGGED_IMAGE_NAME="${PRX_AWS_ACCOUNT_ID}.dkr.ecr.${PRX_ECR_REGION}.amazonaws.com/${PRX_ECR_REPOSITORY}:${TAG}"
            export PRX_ECR_IMAGE="$TAGGED_IMAGE_NAME"

            echo "Pushing image $IMAGE_ID to ECR $TAGGED_IMAGE_NAME..."
            docker tag $IMAGE_ID $TAGGED_IMAGE_NAME
            docker push $TAGGED_IMAGE_NAME
        fi
    fi
}

# If the buildspec provides an S3 object key for Lambda code, the built code
# from the CodeBuild needs to be pushed to that key in the standard Application
# Code bucket provided by the Storage stack.
push_to_s3_lambda() {
    if [ -n "$PRX_LAMBDA_CODE_S3_KEY" ]
    then
        if [ -z "$PRX_APPLICATION_CODE_BUCKET" ]; then build_error "PRX_APPLICATION_CODE_BUCKET required for Lambda code push"; fi
        if [ -z "$PRX_LAMBDA_CODE_CONFIG_PARAMETERS" ]; then build_error "PRX_LAMBDA_CODE_CONFIG_PARAMETERS required for Lambda code push"; fi
        if [ -z "$PRX_LAMBDA_ARCHIVE_BUILD_PATH" ]; then export PRX_LAMBDA_ARCHIVE_BUILD_PATH="/.prxci/build.zip" ; fi
        echo "Handling Lambda code push..."

        echo "Getting Docker image ID"
        image_id=$(docker images --filter "label=org.prx.lambda" --format "{{.ID}}" | head -n 1)

        if [ -z "$image_id" ]; then
            build_error "No Docker image found; ensure at least one Dockerfile has an org.prx.lambda label"
        else
            container_id=$(docker create $image_id)

            echo "Copying zip archive for Lambda source..."
            docker cp $container_id:$PRX_LAMBDA_ARCHIVE_BUILD_PATH build.zip

            cleaned=`docker rm $container_id`

            echo "Sending zip archive to S3..."
            version_id=`aws s3api put-object --bucket $PRX_APPLICATION_CODE_BUCKET --key $PRX_LAMBDA_CODE_S3_KEY --acl private --body build.zip --output text --query 'VersionId'`

            export PRX_LAMBDA_CODE_S3_VERSION_ID="$version_id"
        fi
    fi
}

#
push_to_s3_static() {
    if [ -n "$PRX_S3_STATIC_S3_KEY" ]
    then
        if [ -z "$PRX_APPLICATION_CODE_BUCKET" ]; then build_error "PRX_APPLICATION_CODE_BUCKET required for S3 static code push"; fi
        if [ -z "$PRX_S3_STATIC_CONFIG_PARAMETERS" ]; then build_error "PRX_S3_STATIC_CONFIG_PARAMETERS required for S3 static code push"; fi
        if [ -z "$PRX_S3_STATIC_ARCHIVE_BUILD_PATH" ]; then export PRX_S3_STATIC_ARCHIVE_BUILD_PATH="/.prxci/build.zip" ; fi
        echo "Handling S3 static code push..."

        echo "Getting Docker image ID"
        image_id=$(docker images --filter "label=org.prx.s3static" --format "{{.ID}}" | head -n 1)

        if [ -z "$image_id" ]; then
            build_error "No Docker image found; ensure at least one Dockerfile has an org.prx.s3static label"
        else
            container_id=$(docker create $image_id)

            echo "Copying zip archive for S3 static source..."
            docker cp $container_id:$PRX_S3_STATIC_ARCHIVE_BUILD_PATH build.zip

            cleaned=`docker rm $container_id`

            echo "Sending zip archive to S3..."
            version_id=`aws s3api put-object --bucket $PRX_APPLICATION_CODE_BUCKET --key $PRX_S3_STATIC_S3_KEY --acl private --body build.zip --output text --query 'VersionId'`

            export PRX_S3_STATIC_S3_VERSION_ID="$version_id"
        fi

    fi
}

init() {
    echo "Running post_build script..."

    # Check for required environment variables
    if [ -z "$PRX_SNS_CALLBACK" ]; then echo "PRX_SNS_CALLBACK required"; exit 1; fi
    if [ -z "$PRX_AWS_ACCOUNT_ID" ]; then build_error "PRX_AWS_ACCOUNT_ID required"; fi
    if [ -z "$PRX_REPO" ]; then build_error "PRX_REPO required"; fi
    if [ -z "$PRX_COMMIT" ]; then build_error "PRX_COMMIT required"; fi
    if [ -z "$CODEBUILD_BUILD_SUCCEEDING" ]; then build_error "CODEBUILD_BUILD_SUCCEEDING required"; fi

    # Check the status of the build
    if [ $CODEBUILD_BUILD_SUCCEEDING -eq 0 ]
    then
        build_error "A previous CodeBuild phase did not succeed"
    fi

    # Handle code publish if enabled
    if [ "$PRX_CI_PUBLISH" = "true" ]
    then
        echo "Publishing code..."
        push_to_ecr
        push_to_s3_lambda
        push_to_s3_static

        build_success
    else
        build_success
    fi
}

init
