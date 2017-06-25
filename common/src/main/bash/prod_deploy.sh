#!/bin/bash

set -o errexit

__DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[[ -f "${__DIR}/pipeline.sh" ]] && source "${__DIR}/pipeline.sh" || \
    echo "No pipeline.sh found"

projectGroupId=$( retrieveGroupId )
projectArtifactId=$( retrieveArtifactId )

# download app
downloadJar 'true' ${REPO_WITH_JARS} ${projectGroupId} ${projectArtifactId} ${PIPELINE_VERSION}
# Log in to CF to start deployment
logInToCf "${REDOWNLOAD_INFRA}" "${CF_PROD_USERNAME}" "${CF_PROD_PASSWORD}" "${CF_PROD_ORG}" "${CF_PROD_SPACE}" "${CF_PROD_API_URL}"

# deploying infra
# TODO: most likely rabbitmq / eureka / db would be there on production; this remains for demo purposes
deployRabbitMqToCf
deployMySqlToCf "mysql-github-analytics"
downloadJar ${REDEPLOY_INFRA} ${REPO_WITH_JARS} ${EUREKA_GROUP_ID} ${EUREKA_ARTIFACT_ID} ${EUREKA_VERSION}
deployEureka ${REDEPLOY_INFRA} "${EUREKA_ARTIFACT_ID}-${EUREKA_VERSION}" "${EUREKA_ARTIFACT_ID}" "prod"

# deploy app
renameTheOldApplicationIfPresent "${projectArtifactId}"
deployAndRestartAppWithName "${projectArtifactId}" "${projectArtifactId}-${PIPELINE_VERSION}" "prod"
