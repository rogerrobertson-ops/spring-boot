#!/bin/bash
# =============================================================================
# setup-aws-cicd.sh
# Provisions AWS CI/CD pipeline resources for the inventory application.
#
# Usage:
#   bash setup-aws-cicd.sh <CODESTAR_CONNECTION_ARN> [nostart]
#
# Arguments:
#   CODESTAR_CONNECTION_ARN  - Full ARN of your AVAILABLE CodeStar connection
#   nostart                  - Optional: if provided, pipeline will NOT be
#                              triggered automatically after setup
#
# Example:
#   bash setup-aws-cicd.sh arn:aws:codestar-connections:us-east-2:621753709886:connection/4614c8a0-12d8-4f05-879d-3c03daf4c932 nostart
# =============================================================================

set -e

# ── Arguments ────────────────────────────────────────────────────────────────
CONNECTION_ARN="${1}"
START_MODE="${2}"

if [[ -z "$CONNECTION_ARN" ]]; then
  echo "ERROR: Missing CodeStar connection ARN."
  echo "Usage: bash setup-aws-cicd.sh <CODESTAR_CONNECTION_ARN> [nostart]"
  exit 1
fi

# ── Config ───────────────────────────────────────────────────────────────────
REGION="us-east-2"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

APP_NAME="inventory"
PIPELINE_NAME="inventory-task"
CLUSTER_NAME="inventory-cluster"
SERVICE_NAME="inventory-task-service"
ECR_REPO_NAME="inventory-app"
CODEBUILD_PROJECT="inventory-build"
CODEPIPELINE_BUCKET="${APP_NAME}-pipeline-artifacts-${ACCOUNT_ID}"

GITHUB_REPO="your-github-username/your-repo-name"   # ← UPDATE THIS
GITHUB_BRANCH="main"

echo ""
echo "============================================="
echo " AWS CI/CD Setup for: ${APP_NAME}"
echo " Account : ${ACCOUNT_ID}"
echo " Region  : ${REGION}"
echo "============================================="
echo ""

# ── 1. ECR Repository ────────────────────────────────────────────────────────
echo "[1/6] Creating ECR repository..."
aws ecr describe-repositories --repository-names "${ECR_REPO_NAME}" --region "${REGION}" > /dev/null 2>&1 || \
  aws ecr create-repository \
    --repository-name "${ECR_REPO_NAME}" \
    --region "${REGION}" \
    --image-scanning-configuration scanOnPush=true \
    --output table

ECR_URI="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${ECR_REPO_NAME}"
echo "    ECR URI: ${ECR_URI}"

# ── 2. S3 Artifact Bucket ────────────────────────────────────────────────────
echo ""
echo "[2/6] Creating S3 artifact bucket..."
aws s3api head-bucket --bucket "${CODEPIPELINE_BUCKET}" 2>/dev/null || \
  aws s3api create-bucket \
    --bucket "${CODEPIPELINE_BUCKET}" \
    --region "${REGION}" \
    --create-bucket-configuration LocationConstraint="${REGION}"

aws s3api put-bucket-versioning \
  --bucket "${CODEPIPELINE_BUCKET}" \
  --versioning-configuration Status=Enabled
echo "    Bucket: s3://${CODEPIPELINE_BUCKET}"

# ── 3. IAM Roles ─────────────────────────────────────────────────────────────
echo ""
echo "[3/6] Creating IAM roles..."

# CodeBuild role
CB_ROLE_NAME="${APP_NAME}-codebuild-role"
aws iam get-role --role-name "${CB_ROLE_NAME}" > /dev/null 2>&1 || \
aws iam create-role \
  --role-name "${CB_ROLE_NAME}" \
  --assume-role-policy-document '{
    "Version":"2012-10-17",
    "Statement":[{"Effect":"Allow","Principal":{"Service":"codebuild.amazonaws.com"},"Action":"sts:AssumeRole"}]
  }' > /dev/null

aws iam attach-role-policy --role-name "${CB_ROLE_NAME}" --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPowerUser
aws iam attach-role-policy --role-name "${CB_ROLE_NAME}" --policy-arn arn:aws:iam::aws:policy/CloudWatchLogsFullAccess
aws iam attach-role-policy --role-name "${CB_ROLE_NAME}" --policy-arn arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess
echo "    CodeBuild role: ${CB_ROLE_NAME}"

# CodePipeline role
CP_ROLE_NAME="${APP_NAME}-codepipeline-role"
aws iam get-role --role-name "${CP_ROLE_NAME}" > /dev/null 2>&1 || \
aws iam create-role \
  --role-name "${CP_ROLE_NAME}" \
  --assume-role-policy-document '{
    "Version":"2012-10-17",
    "Statement":[{"Effect":"Allow","Principal":{"Service":"codepipeline.amazonaws.com"},"Action":"sts:AssumeRole"}]
  }' > /dev/null

aws iam attach-role-policy --role-name "${CP_ROLE_NAME}" --policy-arn arn:aws:iam::aws:policy/AWSCodeBuildAdminAccess
aws iam attach-role-policy --role-name "${CP_ROLE_NAME}" --policy-arn arn:aws:iam::aws:policy/AmazonS3FullAccess
aws iam attach-role-policy --role-name "${CP_ROLE_NAME}" --policy-arn arn:aws:iam::aws:policy/AmazonECS_FullAccess
aws iam attach-role-policy --role-name "${CP_ROLE_NAME}" --policy-arn arn:aws:iam::aws:policy/AWSCodeStarFullAccess

# Inline policy for codestar-connections passthrough
aws iam put-role-policy \
  --role-name "${CP_ROLE_NAME}" \
  --policy-name "codestar-connections-use" \
  --policy-document "{
    \"Version\":\"2012-10-17\",
    \"Statement\":[{
      \"Effect\":\"Allow\",
      \"Action\":\"codestar-connections:UseConnection\",
      \"Resource\":\"${CONNECTION_ARN}\"
    }]
  }"
echo "    CodePipeline role: ${CP_ROLE_NAME}"

CB_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${CB_ROLE_NAME}"
CP_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${CP_ROLE_NAME}"

# ── 4. ECS Cluster + Service ─────────────────────────────────────────────────
echo ""
echo "[4/6] Creating ECS cluster and service..."

# Cluster
aws ecs describe-clusters --clusters "${CLUSTER_NAME}" --region "${REGION}" \
  --query "clusters[?status=='ACTIVE'].clusterName" --output text | grep -q "${CLUSTER_NAME}" || \
  aws ecs create-cluster --cluster-name "${CLUSTER_NAME}" --region "${REGION}" > /dev/null
echo "    Cluster: ${CLUSTER_NAME}"

# Task execution role
EXEC_ROLE_NAME="${APP_NAME}-ecs-task-execution-role"
aws iam get-role --role-name "${EXEC_ROLE_NAME}" > /dev/null 2>&1 || \
aws iam create-role \
  --role-name "${EXEC_ROLE_NAME}" \
  --assume-role-policy-document '{
    "Version":"2012-10-17",
    "Statement":[{"Effect":"Allow","Principal":{"Service":"ecs-tasks.amazonaws.com"},"Action":"sts:AssumeRole"}]
  }' > /dev/null
aws iam attach-role-policy --role-name "${EXEC_ROLE_NAME}" \
  --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy

EXEC_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${EXEC_ROLE_NAME}"

# Task definition
echo "    Registering task definition..."
TASK_DEF_ARN=$(aws ecs register-task-definition \
  --family "${APP_NAME}-task" \
  --network-mode awsvpc \
  --requires-compatibilities FARGATE \
  --cpu "256" \
  --memory "512" \
  --execution-role-arn "${EXEC_ROLE_ARN}" \
  --container-definitions "[{
    \"name\":\"${APP_NAME}\",
    \"image\":\"${ECR_URI}:latest\",
    \"portMappings\":[{\"containerPort\":8080,\"protocol\":\"tcp\"}],
    \"essential\":true,
    \"logConfiguration\":{
      \"logDriver\":\"awslogs\",
      \"options\":{
        \"awslogs-group\":\"/ecs/${APP_NAME}\",
        \"awslogs-region\":\"${REGION}\",
        \"awslogs-stream-prefix\":\"ecs\",
        \"awslogs-create-group\":\"true\"
      }
    }
  }]" \
  --region "${REGION}" \
  --query "taskDefinition.taskDefinitionArn" \
  --output text)
echo "    Task definition: ${TASK_DEF_ARN}"

# VPC / Subnet / Security Group (uses default VPC)
DEFAULT_VPC=$(aws ec2 describe-vpcs --filters "Name=isDefault,Values=true" \
  --query "Vpcs[0].VpcId" --output text --region "${REGION}")
SUBNET_IDS=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=${DEFAULT_VPC}" \
  --query "Subnets[0:2].SubnetId" --output text --region "${REGION}" | tr '\t' ',')

SG_NAME="${APP_NAME}-ecs-sg"
SG_ID=$(aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=${SG_NAME}" "Name=vpc-id,Values=${DEFAULT_VPC}" \
  --query "SecurityGroups[0].GroupId" --output text --region "${REGION}" 2>/dev/null)

if [[ -z "$SG_ID" || "$SG_ID" == "None" ]]; then
  SG_ID=$(aws ec2 create-security-group \
    --group-name "${SG_NAME}" \
    --description "ECS security group for ${APP_NAME}" \
    --vpc-id "${DEFAULT_VPC}" \
    --region "${REGION}" \
    --query "GroupId" --output text)
  aws ec2 authorize-security-group-ingress \
    --group-id "${SG_ID}" \
    --protocol tcp --port 8080 --cidr 0.0.0.0/0 \
    --region "${REGION}" > /dev/null
fi
echo "    Security group: ${SG_ID}"

# ECS Service
EXISTING_SERVICE=$(aws ecs describe-services \
  --cluster "${CLUSTER_NAME}" --services "${SERVICE_NAME}" \
  --region "${REGION}" \
  --query "services[?status=='ACTIVE'].serviceName" --output text 2>/dev/null)

if [[ -z "$EXISTING_SERVICE" ]]; then
  aws ecs create-service \
    --cluster "${CLUSTER_NAME}" \
    --service-name "${SERVICE_NAME}" \
    --task-definition "${APP_NAME}-task" \
    --desired-count 1 \
    --launch-type FARGATE \
    --network-configuration "awsvpcConfiguration={subnets=[${SUBNET_IDS}],securityGroups=[${SG_ID}],assignPublicIp=ENABLED}" \
    --region "${REGION}" > /dev/null
  echo "    ECS service created: ${SERVICE_NAME}"
else
  echo "    ECS service already exists: ${SERVICE_NAME}"
fi

# ── 5. CodeBuild Project ──────────────────────────────────────────────────────
echo ""
echo "[5/6] Creating CodeBuild project..."

aws codebuild batch-get-projects --names "${CODEBUILD_PROJECT}" \
  --query "projects[0].name" --output text 2>/dev/null | grep -q "${CODEBUILD_PROJECT}" || \
aws codebuild create-project \
  --name "${CODEBUILD_PROJECT}" \
  --source "type=CODEPIPELINE,buildspec=buildspec.yml" \
  --artifacts "type=CODEPIPELINE" \
  --environment "type=LINUX_CONTAINER,computeType=BUILD_GENERAL1_SMALL,image=aws/codebuild/standard:7.0,privilegedMode=true,environmentVariables=[
    {name=AWS_DEFAULT_REGION,value=${REGION}},
    {name=AWS_ACCOUNT_ID,value=${ACCOUNT_ID}},
    {name=IMAGE_REPO_NAME,value=${ECR_REPO_NAME}},
    {name=IMAGE_TAG,value=latest}
  ]" \
  --service-role "${CB_ROLE_ARN}" \
  --region "${REGION}" > /dev/null

echo "    CodeBuild project: ${CODEBUILD_PROJECT}"

# ── 6. CodePipeline ───────────────────────────────────────────────────────────
echo ""
echo "[6/6] Creating CodePipeline..."

# Write imagedefinitions.json placeholder (used by ECS deploy action)
PIPELINE_JSON=$(cat <<EOF
{
  "pipeline": {
    "name": "${PIPELINE_NAME}",
    "roleArn": "${CP_ROLE_ARN}",
    "executionMode": "QUEUED",
    "artifactStore": {
      "type": "S3",
      "location": "${CODEPIPELINE_BUCKET}"
    },
    "stages": [
      {
        "name": "Source",
        "actions": [{
          "name": "GitHub_Source",
          "actionTypeId": {
            "category": "Source",
            "owner": "AWS",
            "provider": "CodeStarSourceConnection",
            "version": "1"
          },
          "outputArtifacts": [{"name": "SourceOutput"}],
          "configuration": {
            "ConnectionArn": "${CONNECTION_ARN}",
            "FullRepositoryId": "${GITHUB_REPO}",
            "BranchName": "${GITHUB_BRANCH}",
            "OutputArtifactFormat": "CODE_ZIP"
          },
          "runOrder": 1
        }]
      },
      {
        "name": "Build",
        "actions": [{
          "name": "CodeBuild",
          "actionTypeId": {
            "category": "Build",
            "owner": "AWS",
            "provider": "CodeBuild",
            "version": "1"
          },
          "inputArtifacts": [{"name": "SourceOutput"}],
          "outputArtifacts": [{"name": "BuildOutput"}],
          "configuration": {
            "ProjectName": "${CODEBUILD_PROJECT}"
          },
          "runOrder": 1
        }]
      },
      {
        "name": "Deploy",
        "actions": [{
          "name": "ECS_Deploy",
          "actionTypeId": {
            "category": "Deploy",
            "owner": "AWS",
            "provider": "ECS",
            "version": "1"
          },
          "inputArtifacts": [{"name": "BuildOutput"}],
          "configuration": {
            "ClusterName": "${CLUSTER_NAME}",
            "ServiceName": "${SERVICE_NAME}",
            "FileName": "imagedefinitions.json"
          },
          "runOrder": 1
        }]
      }
    ]
  }
}
EOF
)

# Check if pipeline exists
aws codepipeline get-pipeline --name "${PIPELINE_NAME}" --region "${REGION}" > /dev/null 2>&1 && \
  echo "    Pipeline already exists, skipping create." || \
  (echo "${PIPELINE_JSON}" | aws codepipeline create-pipeline --cli-input-json file:///dev/stdin --region "${REGION}" > /dev/null && \
   echo "    Pipeline created: ${PIPELINE_NAME}")

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo "============================================="
echo " Setup complete!"
echo "============================================="
echo " ECR:          ${ECR_URI}"
echo " ECS Cluster:  ${CLUSTER_NAME}"
echo " ECS Service:  ${SERVICE_NAME}"
echo " Pipeline:     ${PIPELINE_NAME}"
echo ""

if [[ "${START_MODE}" != "nostart" ]]; then
  echo "Triggering pipeline execution..."
  aws codepipeline start-pipeline-execution --name "${PIPELINE_NAME}" --region "${REGION}"
else
  echo "Pipeline created but NOT started (nostart mode)."
  echo ""
  echo "To start manually, run:"
  echo "  aws codepipeline start-pipeline-execution --name ${PIPELINE_NAME} --region ${REGION}"
fi

echo ""
echo "To verify pipeline execution mode:"
echo "  aws codepipeline get-pipeline --name ${PIPELINE_NAME} --region ${REGION} --query \"pipeline.executionMode\" --output text"
echo ""
