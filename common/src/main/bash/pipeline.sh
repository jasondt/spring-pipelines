#!/bin/bash
set -e

# It takes ages on Docker to run the app without this
export MAVEN_OPTS="${MAVEN_OPTS} -Djava.security.egd=file:///dev/urandom"

function logInToCf() {
    local redownloadInfra="${1}"
    local cfUsername="${2}"
    local cfPassword="${3}"
    local cfOrg="${4}"
    local cfSpace="${5}"
    local apiUrl="${6:-api.run.pivotal.io}"
    CF_INSTALLED="$( cf --version || echo "false" )"
    CF_DOWNLOADED="$( test -r cf && echo "true" || echo "false" )"
    echo "CF Installed? [${CF_INSTALLED}], CF Downloaded? [${CF_DOWNLOADED}]"
    if [[ ${CF_INSTALLED} == "false" && (${CF_DOWNLOADED} == "false" || ${CF_DOWNLOADED} == "true" && ${redownloadInfra} == "true") ]]; then
        echo "Downloading Cloud Foundry"
        curl -L "https://cli.run.pivotal.io/stable?release=linux64-binary&source=github" --fail | tar -zx
        CF_DOWNLOADED="true"
    else
        echo "CF is already installed or was already downloaded but the flag to redownload was disabled"
    fi

    if [[ ${CF_DOWNLOADED} == "true" ]]; then
        echo "Adding CF to PATH"
        PATH=${PATH}:`pwd`
        chmod +x cf
    fi

    echo "Cloud foundry version"
    cf --version

    echo "Logging in to CF to org [${cfOrg}], space [${cfSpace}]"
    cf api --skip-ssl-validation "${apiUrl}"
    cf login -u "${cfUsername}" -p "${cfPassword}" -o "${cfOrg}" -s "${cfSpace}"
}

function deployRabbitMqToCf() {
    local serviceName="${1:-rabbitmq-github}"
    echo "Waiting for RabbitMQ to start"
    local foundApp=`cf s | awk -v "app=${serviceName}" '$1 == app {print($0)}'`
    if [[ "${foundApp}" == "" ]]; then
        hostname="${hostname}-${CF_HOSTNAME_UUID}"
        (cf cs cloudamqp lemur "${serviceName}" && echo "Started RabbitMQ") ||
        (cf cs p-rabbitmq standard "${serviceName}" && echo "Started RabbitMQ for PCF Dev")
    else
        echo "Service [${foundName}] already started"
    fi
}

function deleteMySql() {
    local serviceName="${1:-mysql-github}"
    cf delete-service -f ${serviceName}
}

function deployMySqlToCf() {
    local serviceName="${1:-mysql-github}"
    echo "Waiting for MySQL to start"
    local foundApp=`cf s | awk -v "app=${serviceName}" '$1 == app {print($0)}'`
    if [[ "${foundApp}" == "" ]]; then
        hostname="${hostname}-${CF_HOSTNAME_UUID}"
        (cf cs p-mysql 100mb "${serviceName}" && echo "Started MySQL") ||
        (cf cs p-mysql 512mb "${serviceName}" && echo "Started MySQL for PCF Dev")
    else
        echo "Service [${foundName}] already started"
    fi
}

function deployAndRestartAppWithName() {
    local appName="${1}"
    local jarName="${2}"
    local env="${3}"
    echo "Deploying and restarting app with name [${appName}] and jar name [${jarName}]"
    deployAppWithName "${appName}" "${jarName}" "${env}" 'true'
    restartApp "${appName}"
}

function deployAndRestartAppWithNameForSmokeTests() {
    local appName="${1}"
    local jarName="${2}"
    local rabbitName="${3}"
    local eurekaName="${4}"
    local mysqlName="${5}"
    local profiles="${6:-cloud,smoke}"
    local env="${7:-test}"
    local lowerCaseAppName=$( echo "${appName}" | tr '[:upper:]' '[:lower:]' )
    deleteApp "${appName}"
    echo "Deploying and restarting app with name [${appName}] and jar name [${jarName}] and env [${env}]"
    deployAppWithName "${appName}" "${jarName}" "${env}" 'false'
    bindService "${rabbitName}" "${appName}"
    if [[ "${eurekaName}" != "" ]]; then
        bindService "${eurekaName}" "${appName}"
    fi
    bindService "${mysqlName}" "${appName}"
    setEnvVar "${lowerCaseAppName}" 'spring.profiles.active' "${profiles}"
    restartApp "${appName}"
}

function appHost() {
    local appName="${1}"
    local lowerCase="$( echo "${appName}" | tr '[:upper:]' '[:lower:]' )"
    local APP_HOST=`cf apps | awk -v "app=${lowerCase}" '$1 == app {print($0)}' | tr -s ' ' | cut -d' ' -f 6 | cut -d, -f1`
    echo "${APP_HOST}" | tail -1
}

function deployAppWithName() {
    local appName="${1}"
    local jarName="${2}"
    local env="${3}"
    local useManifest="${4:-false}"
    local manifestOption=$( if [[ "${useManifest}" == "false" ]] ; then echo "--no-manifest"; else echo "" ; fi )
    local lowerCaseAppName=$( echo "${appName}" | tr '[:upper:]' '[:lower:]' )
    local hostname="${lowerCaseAppName}"
    local memory="${APP_MEMORY_LIMIT:-256m}"
    local buildPackUrl="${JAVA_BUILDPACK_URL:-https://github.com/cloudfoundry/java-buildpack.git#v3.8.1}"
    if [[ "${CF_HOSTNAME_UUID}" != "" ]]; then
        hostname="${hostname}-${CF_HOSTNAME_UUID}"
    fi
    if [[ ${env} != "prod" ]]; then
        hostname="${hostname}-${env}"
    fi
    echo "Deploying app with name [${lowerCaseAppName}], env [${env}] with manifest [${useManifest}] and host [${hostname}]"
    if [[ ! -z "${manifestOption}" ]]; then
        cf push "${lowerCaseAppName}" -m "${memory}" -i 1 -p "${OUTPUT_FOLDER}/${jarName}.jar" -n "${hostname}" --no-start -b "${buildPackUrl}" ${manifestOption}
    else
        cf push "${lowerCaseAppName}" -p "${OUTPUT_FOLDER}/${jarName}.jar" -n "${hostname}" --no-start -b "${buildPackUrl}"
    fi
    APPLICATION_DOMAIN="$( appHost ${lowerCaseAppName} )"
    echo "Determined that application_domain for [${lowerCaseAppName}] is [${APPLICATION_DOMAIN}]"
    setEnvVar "${lowerCaseAppName}" 'APPLICATION_DOMAIN' "${APPLICATION_DOMAIN}"
    setEnvVar "${lowerCaseAppName}" 'JAVA_OPTS' '-Djava.security.egd=file:///dev/urandom'
}

function deleteApp() {
    local serviceName="${1}"
    local lowerCaseAppName=$( echo "${serviceName}" | tr '[:upper:]' '[:lower:]' )
    local APP_NAME="${lowerCaseAppName}"
    echo "Deleting application [${APP_NAME}]"
    cf delete -f ${APP_NAME} || echo "Failed to delete the app. Continuing with the script"
}

function setEnvVarIfMissing() {
    local appName="${1}"
    local key="${2}"
    local value="${3}"
    echo "Setting env var [${key}] -> [${value}] for app [${appName}] if missing"
    cf env "${appName}" | grep "${key}" || setEnvVar appName key value
}

function setEnvVar() {
    local appName="${1}"
    local key="${2}"
    local value="${3}"
    echo "Setting env var [${key}] -> [${value}] for app [${appName}]"
    cf set-env "${appName}" "${key}" "${value}"
}

function restartApp() {
    local appName="${1}"
    echo "Restarting app with name [${appName}]"
    cf restart "${appName}"
}

function deployEureka() {
    local redeploy="${1}"
    local jarName="${2}"
    local appName="${3}"
    local env="${4}"
    echo "Deploying Eureka. Options - redeploy [${redeploy}], jar name [${jarName}], app name [${appName}], env [${env}]"
    local fileExists="true"
    local fileName="`pwd`/${OUTPUT_FOLDER}/${jarName}.jar"
    if [[ ! -f "${fileName}" ]]; then
        fileExists="false"
    fi
    if [[ ${fileExists} == "false" || ( ${fileExists} == "true" && ${redeploy} == "true" ) ]]; then
        deployAppWithName "${appName}" "${jarName}" "${env}"
        restartApp "${appName}"
        createServiceWithName "${appName}"
    else
        echo "Current folder is [`pwd`]; The [${fileName}] exists [${fileExists}]; redeploy flag was set [${redeploy}]. Skipping deployment"
    fi
}

function deployStubRunnerBoot() {
    local redeploy="${1}"
    local jarName="${2}"
    local repoWithJars="${3}"
    local rabbitName="${4}"
    local eurekaName="${5}"
    local env="${6:-test}"
    local stubRunnerName="${7:-stubrunner}"
    local fileExists="true"
    local fileName="`pwd`/${OUTPUT_FOLDER}/${jarName}.jar"
    local stubRunnerUseClasspath="${STUBRUNNER_USE_CLASSPATH:-false}"
    if [[ ! -f "${fileName}" ]]; then
        fileExists="false"
    fi
    echo "Deploying Stub Runner. Options - redeploy [${redeploy}], jar name [${jarName}], app name [${stubRunnerName}]"
    if [[ ${fileExists} == "false" || ( ${fileExists} == "true" && ${redeploy} == "true" ) ]]; then
        deployAppWithName "${stubRunnerName}" "${jarName}" "${env}" "false"
        local prop="$( retrieveStubRunnerIds )"
        echo "Found following stub runner ids [${prop}]"
        setEnvVar "${stubRunnerName}" "stubrunner.ids" "${prop}"
        if [[ "${stubRunnerUseClasspath}" == "false" ]]; then
            setEnvVar "${stubRunnerName}" "stubrunner.repositoryRoot" "${repoWithJars}"
        fi
        bindService "${rabbitName}" "${stubRunnerName}"
        setEnvVar "${stubRunnerName}" "spring.rabbitmq.addresses" "\${vcap.services.${rabbitName}.credentials.uri}"
        if [[ "${eurekaName}" != "" ]]; then
            bindService "${eurekaName}" "${stubRunnerName}"
            setEnvVar "${stubRunnerName}" "eureka.client.serviceUrl.defaultZone" "\${vcap.services.${eurekaName}.credentials.uri:http://127.0.0.1:8761}/eureka/"
        fi
        restartApp "${stubRunnerName}"
    else
        echo "Current folder is [`pwd`]; The [${fileName}] exists [${fileExists}]; redeploy flag was set [${redeploy}]. Skipping deployment"
    fi
}

function bindService() {
    local serviceName="${1}"
    local appName="${2}"
    echo "Binding service [${serviceName}] to app [${appName}]"
    cf bind-service "${appName}" "${serviceName}"
}

function createServiceWithName() {
    local name="${1}"
    echo "Creating service with name [${name}]"
    APPLICATION_DOMAIN=`cf apps | grep ${name} | tr -s ' ' | cut -d' ' -f 6 | cut -d, -f1`
    JSON='{"uri":"http://'${APPLICATION_DOMAIN}'"}'
    cf create-user-provided-service "${name}" -p "${JSON}" || echo "Service already created. Proceeding with the script"
}

# The function uses Maven Wrapper - if you're using Maven you have to have it on your classpath
# and change this function
function extractMavenProperty() {
    local prop="${1}"
    MAVEN_PROPERTY=$(./mvnw ${BUILD_OPTIONS} -q \
                    -Dexec.executable="echo" \
                    -Dexec.args="\${${prop}}" \
                    --non-recursive \
                    org.codehaus.mojo:exec-maven-plugin:1.3.1:exec)
    # In some spring cloud projects there is info about deactivating some stuff
    MAVEN_PROPERTY=$( echo "${MAVEN_PROPERTY}" | tail -1 )
    # In Maven if there is no property it prints out ${propname}
    if [[ "${MAVEN_PROPERTY}" == "\${${prop}}" ]]; then
        echo ""
    else
        echo "${MAVEN_PROPERTY}"
    fi
}

# The values of group / artifact ids can be later retrieved from Maven
function downloadJar() {
    local redownloadInfra="${1}"
    local repoWithJars="${2}"
    local groupId="${3}"
    local artifactId="${4}"
    local version="${5}"
    local destination="`pwd`/${OUTPUT_FOLDER}/${artifactId}-${version}.jar"
    local changedGroupId="$( echo "${groupId}" | tr . / )"
    local pathToJar="${repoWithJars}/${changedGroupId}/${artifactId}/${version}/${artifactId}-${version}.jar"
    if [[ ! -e ${destination} || ( -e ${destination} && ${redownloadInfra} == "true" ) ]]; then
        mkdir -p "${OUTPUT_FOLDER}"
        echo "Current folder is [`pwd`]; Downloading [${pathToJar}] to [${destination}]"
        (curl "${pathToJar}" -o "${destination}" --fail && echo "File downloaded successfully!") || (echo "Failed to download file!" && return 1)
    else
        echo "File [${destination}] exists and redownload flag was set to false. Will not download it again"
    fi
}

function propagatePropertiesForTests() {
    local projectArtifactId="${1}"
    local stubRunnerHost="${2:-stubrunner-${projectArtifactId}}"
    local fileLocation="${3:-${OUTPUT_FOLDER}/test.properties}"
    echo "Propagating properties for tests. Project [${projectArtifactId}] stub runner host [${stubRunnerHost}] properties location [${fileLocation}]"
    # retrieve host of the app / stubrunner
    # we have to store them in a file that will be picked as properties
    rm -rf "${fileLocation}"
    local host=$( appHost "${projectArtifactId}" )
    APPLICATION_URL="${host}"
    echo "APPLICATION_URL=${host}" >> ${fileLocation}
    host=$( appHost "${stubRunnerHost}" )
    STUBRUNNER_URL="${host}"
    echo "STUBRUNNER_URL=${host}" >> ${fileLocation}
    echo "Resolved properties"
    cat ${fileLocation}
}

function readTestPropertiesFromFile() {
    local fileLocation="${1:-${OUTPUT_FOLDER}/test.properties}"
    if [ -f "${fileLocation}" ]
    then
      echo "${fileLocation} found."
      while IFS='=' read -r key value
      do
        key=$(echo ${key} | tr '.' '_')
        eval "${key}='${value}'"
      done < "${fileLocation}"
    else
      echo "${fileLocation} not found."
    fi
}

# Function that executes integration tests
function runSmokeTests() {
    local applicationHost="${1}"
    local stubrunnerHost="${2}"
    echo "Running smoke tests"

    if [[ "${PROJECT_TYPE}" == "MAVEN" ]]; then
        if [[ "${CI}" == "CONCOURSE" ]]; then
            ./mvnw clean install -Psmoke -Dapplication.url="${applicationHost}" -Dstubrunner.url="${stubrunnerHost}" ${BUILD_OPTIONS} || ( echo "$( printTestResults )" && return 1)
        else
            ./mvnw clean install -Psmoke -Dapplication.url="${applicationHost}" -Dstubrunner.url="${stubrunnerHost}" ${BUILD_OPTIONS}
        fi
    elif [[ "${PROJECT_TYPE}" == "GRADLE" ]]; then
        if [[ "${CI}" == "CONCOURSE" ]]; then
            ./gradlew smoke -PnewVersion=${PIPELINE_VERSION} -Dapplication.url="${applicationHost}" -Dstubrunner.url="${stubrunnerHost}" ${BUILD_OPTIONS} || ( echo "$( printTestResults )" && return 1)
        else
            ./gradlew smoke -PnewVersion=${PIPELINE_VERSION} -Dapplication.url="${applicationHost}" -Dstubrunner.url="${stubrunnerHost}" ${BUILD_OPTIONS}
        fi
    else
        echo "Unsupported project build tool"
        return 1
    fi
}

# Function that executes end to end tests
function runE2eTests() {
    local applicationHost="${1}"
    local stubrunnerHost="${2}"
    echo "Running e2e tests"

    if [[ "${PROJECT_TYPE}" == "MAVEN" ]]; then
        if [[ "${CI}" == "CONCOURSE" ]]; then
            ./mvnw clean install -Pe2e -Dapplication.url="${applicationHost}" -Dstubrunner.url="${stubrunnerHost}" ${BUILD_OPTIONS} || ( $( printTestResults ) && return 1)
        else
            ./mvnw clean install -Pe2e -Dapplication.url="${applicationHost}" -Dstubrunner.url="${stubrunnerHost}" ${BUILD_OPTIONS}
        fi
    elif [[ "${PROJECT_TYPE}" == "GRADLE" ]]; then
        if [[ "${CI}" == "CONCOURSE" ]]; then
            ./gradlew e2e -PnewVersion=${PIPELINE_VERSION} -Dapplication.url="${applicationHost}" -Dstubrunner.url="${stubrunnerHost}" ${BUILD_OPTIONS} || ( $( printTestResults ) && return 1)
        else
            ./gradlew e2e -PnewVersion=${PIPELINE_VERSION} -Dapplication.url="${applicationHost}" -Dstubrunner.url="${stubrunnerHost}" ${BUILD_OPTIONS}
        fi
    else
        echo "Unsupported project build tool"
        return 1
    fi
}

function findLatestProdTag() {
    local LAST_PROD_TAG=$(git for-each-ref --sort=taggerdate --format '%(refname)' refs/tags/prod | head -n 1)
    LAST_PROD_TAG=${LAST_PROD_TAG#refs/tags/}
    echo "${LAST_PROD_TAG}"
}

function extractVersionFromProdTag() {
    local tag="${1}"
    LAST_PROD_VERSION=${tag#prod/}
    echo "${LAST_PROD_VERSION}"
}

function retrieveGroupId() {
    if [[ "${PROJECT_TYPE}" == "GRADLE" ]]; then
        local result=$( ./gradlew groupId ${BUILD_OPTIONS} -q )
        result=$( echo "${result}" | tail -1 )
        echo "${result}"
    else
        local result=$( ruby -r rexml/document -e 'puts REXML::Document.new(File.new(ARGV.shift)).elements["/project/groupId"].text' pom.xml || ./mvnw ${BUILD_OPTIONS} org.apache.maven.plugins:maven-help-plugin:2.2:evaluate -Dexpression=project.groupId |grep -Ev '(^\[|Download\w+:)' )
        result=$( echo "${result}" | tail -1 )
        echo "${result}"
    fi
}

function retrieveArtifactId() {
    if [[ "${PROJECT_TYPE}" == "GRADLE" ]]; then
        local result=$( ./gradlew artifactId ${BUILD_OPTIONS} -q )
        result=$( echo "${result}" | tail -1 )
        echo "${result}"
    else
        local result=$( ruby -r rexml/document -e 'puts REXML::Document.new(File.new(ARGV.shift)).elements["/project/artifactId"].text' pom.xml || ./mvnw ${BUILD_OPTIONS} org.apache.maven.plugins:maven-help-plugin:2.2:evaluate -Dexpression=project.artifactId |grep -Ev '(^\[|Download\w+:)' )
        result=$( echo "${result}" | tail -1 )
        echo "${result}"
    fi
}

# Jenkins passes these as a separate step, in Concourse we'll do it manually
function prepareForSmokeTests() {
    local redownloadInfra="${1}"
    local username="${2}"
    local password="${3}"
    local org="${4}"
    local space="${5}"
    local api="${6}"
    echo "Retrieving group and artifact id - it can take a while..."
    projectGroupId=$( retrieveGroupId )
    projectArtifactId=$( retrieveArtifactId )
    mkdir -p "${OUTPUT_FOLDER}"
    logInToCf "${redownloadInfra}" "${username}" "${password}" "${org}" "${space}" "${api}"
    propagatePropertiesForTests ${projectArtifactId}
    readTestPropertiesFromFile
}

# Jenkins passes these as a separate step, in Concourse we'll do it manually
function prepareForE2eTests() {
    local redownloadInfra="${1}"
    local username="${2}"
    local password="${3}"
    local org="${4}"
    local space="${5}"
    local api="${6}"
    echo "Retrieving group and artifact id - it can take a while..."
    projectGroupId=$( retrieveGroupId )
    projectArtifactId=$( retrieveArtifactId )
    echo "Project groupId is ${projectGroupId}"
    echo "Project artifactId is ${projectArtifactId}"
    mkdir -p "${OUTPUT_FOLDER}"
    logInToCf "${redownloadInfra}" "${username}" "${password}" "${org}" "${space}" "${api}"
    propagatePropertiesForTests ${projectArtifactId}
    readTestPropertiesFromFile
}

function isMavenProject() {
    [ -f "mvnw" ]
}

function isGradleProject() {
    [ -f "gradlew" ]
}

function projectType() {
    if isMavenProject; then
        echo "MAVEN"
    elif isGradleProject; then
        echo "GRADLE"
    else
        echo "UNKNOWN"
    fi
}

function outputFolder() {
    if [[ "${PROJECT_TYPE}" == "GRADLE" ]]; then
        echo "build/libs"
    else
        echo "target"
    fi
}

function testResultsFolder() {
    if [[ "${PROJECT_TYPE}" == "GRADLE" ]]; then
        echo "**/test-results/*.xml"
    else
        echo "**/surefire-reports/*"
    fi
}

function printTestResults() {
    echo -e "\n\nBuild failed!!! - will print all test results to the console (it's the easiest way to debug anything later)\n\n" && tail -n +1 "$( testResultsFolder )"
}

function retrieveStubRunnerIds() {
    if [[ "${PROJECT_TYPE}" == "GRADLE" ]]; then
        echo "$( ./gradlew stubIds ${BUILD_OPTIONS} -q | tail -1 )"
    else
        echo "$( extractMavenProperty 'stubrunner.ids' )"
    fi
}

function renameTheOldApplicationIfPresent() {
    local appName="${1}"
    local newName="${appName}-venerable"
    echo "Renaming the app from [${appName}] -> [${newName}]"
    local appPresent="no"
    cf app "${appName}" && appPresent="yes"
    if [[ "${appPresent}" == "yes" ]]; then
        cf rename "${appName}" "${newName}"
    else
        echo "Will not rename the application cause it's not there"
    fi
}

function deleteTheOldApplicationIfPresent() {
    local appName="${1}"
    local oldName="${appName}-venerable"
    echo "Deleting the app [${oldName}]"
    cf app "${oldName}" && appPresent="yes"
    if [[ "${appPresent}" == "yes" ]]; then
        cf delete "${oldName}" -f
    else
        echo "Will not remove the old application cause it's not there"
    fi
}

export PROJECT_TYPE=$( projectType )
export OUTPUT_FOLDER=$( outputFolder )
export TEST_REPORTS_FOLDER=$( testResultsFolder )

echo "Project type [${PROJECT_TYPE}]"
echo "Output folder [${OUTPUT_FOLDER}]"
echo "Test reports folder [${TEST_REPORTS_FOLDER}]"
