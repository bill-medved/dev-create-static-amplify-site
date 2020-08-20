# Reference: https://stedolan.github.io/jq/download/
# Reference: https://jqplay.org/

# Proof Of Concept!
# Create an AWS Amplify static website from a template static web site
#
# Please see Readme.MD for background
#
# PREREQUISITES:
#   - github and AWS accounts set up 
#   - AWS Secret Manager set up with a personal github tokens
#   - AWS profile set up on your local machine
#   - github SSH set up on your local machine
#   - jq and git installed

# FUNCTION: wait_for_Amplify_application
# Wait for Amplify application to be created.  If it is not found within a certain
# period of time, exit.
wait_for_Amplify_application ()
{
    local COUNTER=0
    AMPLIFY_APP_JSON=
    echo "Waiting for Amplify application to be created within AWS"
    until [[ $AMPLIFY_APP_JSON != "" ]]
    do
        AMPLIFY_APP_JSON=$(aws amplify list-apps --region $AWS_REGION | jq '.apps[] | select(.name == '\"$DOMAIN\"')')
        sleep 10
        printf " $COUNTER "
        let COUNTER=COUNTER+1
        if [[ $COUNTER -gt 20 ]]
        then
            echo "Timing out - you must manually kick off the Amplify build in the console when the application is available"
            exit 1
        fi
    done

    APP_ID=$(echo $AMPLIFY_APP_JSON | jq --raw-output '.appId')
    APPLICATION_URL=$(echo $AMPLIFY_APP_JSON | jq --raw-output '.defaultDomain')

}

# FUNCTION: wait_for_Amplify_branch
# You need both Amplify application branch to be available before
# kicking off an Amplify job (build)
wait_for_Amplify_branch ()
{
    local COUNTER=0
    BRANCH_ARN=
    echo "Waiting for Amplify branch to be created within AWS"
    until [[ $BRANCH_ARN != "" ]]
    do
        sleep 10
        BRANCH_ARN=$(aws amplify get-branch --app-id  $APP_ID --branch-name $BRANCH --region $AWS_REGION)
        printf " $COUNTER "
        let COUNTER=COUNTER+1
        if [[ $COUNTER -gt 20 ]]
        then
            echo "Timing out - you must manually kick off the Amplify build in the console when the application is available"
            exit 1
        fi
    done
    BRANCH_ARN=$(echo $BRANCH_ARN | jq --raw-output '.branch.branchArn')
}

# Presumes to run this script out of current directory
BUILD_ROOT=$PWD

# Cloud formation template used to create the stack.
CREATE_SITE_TEMPLATE="create-static-site.yaml"

# This is where you are going to put the local git repository
SOURCE_ROOT="/media/psf/Shared/IT/dev/available-sites"

# Location of files that we will use to create the Amplify static website
TEMPLATE_ROOT=$BUILD_ROOT/template

# Default region unless specified as $2 on command line
AWS_REGION="us-west-2"

# default branch name to publish.  Note this would require changes in git repository commands as well
# as the create-static-stie.YAML.  This variable is an FYI, rather than actionable for this POC.
BRANCH=master

if [[ $1 == '--help' ]]; then
    echo "Usage: create-available-site my-domain-name aws-region"
    echo "if no aws-region is specified, the default is used: $AWS_REGION"
    exit 1
fi

if [ -z $1 ]
  then
    echo "you must supply at least one argument - the site domain name."
    echo "use --help for more information."
    exit 1
fi

if [[ ! $2 == "" ]]
    then
        AWS_REGION=$2
fi

# AWS Secret Manager is used to store github personal access token.
# This token is used in this bash runtime to create a github repository
# as well as referenced in the cloud formation YAML file so the github
# personal token is never stored in a file (only the key name is stored).
# This token is how Amplify authenticates with github

# I would recommend using different names for your AWS secrets.
# NOTE: If you change the name of the Secret Manager keys below you must change
# the OAuthToken references in create-static-site.YAML!

SECRET_ID='GitHub-manage'
CREATE_KEY='create_token'
READ_KEY='read_token'

# Rough check of parameters ok, so lets start process.  It is important to realize
# the following items all use the DOMAIN name.  This includes:
# local and github repository names, and amplify application name.
# I use "DOMAIN" to refer throughout as the intent is to eventually tie the
# amplify application to: www.DOMAIN.com

DOMAIN=$1

# putting logfiles on /log subdirectory from BUILDROOT.  Note log files
# simply overwrite each iteration

[ ! -d "$BUILD_ROOT/log" ] && mkdir "$BUILD_ROOT/log"
LOG_BASE_FILE="$DOMAIN-$AWS_REGION-create.log"
LOG_FILE="$BUILD_ROOT/log/$LOG_BASE_FILE" 

# first echo to log file overwrites previous version of log file

echo "Automated CREATE of Amplify Application and associated components" | tee $LOG_FILE
echo "$(date +"%m-%d-%Y-%T") create $DOMAIN in region $AWS_REGION"  | tee -a $LOG_FILE

# Use AWS secretsmanager to get secret value for github personal access token and then create 
# repository with same name as site 

GH=$(aws secretsmanager get-secret-value --region $AWS_REGION --secret-id $SECRET_ID)

if [ -z $GH ]
    then
        echo "Unable to find Secret Manager github $SECRET_ID in $AWS_REGION"
        exit 1
fi

# Used to create github repsiotry:
CREATE_TOKEN=$(echo $GH | jq --raw-output .SecretString | jq -r ."${CREATE_KEY}")
if [ -z $CREATE_TOKEN ]
    then
        echo "Unable to find Secret Manager github token $CREATE_KEY in $AWS_REGION"
        exit 1
fi

# Used for Amplify access to github respository
READ_TOKEN=$(echo $GH | jq --raw-output .SecretString | jq -r ."${READ_KEY}")
if [ -z $READ_TOKEN ]
    then
        echo "Unable to find Secret Manager github token $READ_KEY in $AWS_REGION"
        exit 1
fi

# Create the github repository
# Note repository name is same as DOMIAN, and repository type is private.
# Repository will have to be public if you don't have a paid github account, then...
# change next line: \"private\": false

RGH=$(curl -s -i -H "Authorization: token ${CREATE_TOKEN}" -H "Content-Type: application/json" https://api.github.com/user/repos -d "{\"name\": \"${DOMAIN}\", \"description\": \"${DESCRIPTION}\", \"private\": true, \"has_issues\": true, \"has_downloads\": true, \"has_wiki\": false}")

# Strip out response header and get SSH URL for github access

REPOSITORY_URL=$(echo "{" "${RGH#*{}" | jq --raw-output '.html_url')
SSH_URL=$(echo "{" "${RGH#*{}" | jq --raw-output '.ssh_url')

# Copy template static-web site from $TEMPLATE_ROOT
# Make simple substitutions for domain name in template.html {{WebSite}} and $DOMAIN
# Create local git repository, then wire it up to the github repository created above

cp -R $TEMPLATE_ROOT $SOURCE_ROOT/$DOMAIN
cd $SOURCE_ROOT/$DOMAIN

# Local repository create

git init

# You can put as much info into Readme as you like-be aware it will end up on github
# which may be public depending on your configuration and github account status

echo "Static Web Site">"Readme.MD"

# The next section makes an assumption that the template.html
# will be rewritten as index.html.  template.html is deleted after sed
# template file.  {{WebSite}} will be replaced with $DOMAIN
# If you want to transform a static website from the template, this is 
# where you would accomplish this work

sed "s/{{WebSite}}/$DOMAIN/g" template.html > index.html
rm template.html
git add .
git commit -m "Initial commit $DOMAIN"

# push new local DOMAIN repository to github
git remote add origin $SSH_URL
git push -u origin $BRANCH

# Create cloud formation stack
# This call will return successful even if there is an error on the stack creation

cd $BUILD_ROOT
CFN_PARAMETERS="ParameterKey=Domain,ParameterValue=$DOMAIN ParameterKey=Repository,ParameterValue=$REPOSITORY_URL"
aws cloudformation create-stack --stack-name $DOMAIN --template-body file://./$CREATE_SITE_TEMPLATE --region $AWS_REGION \
--parameters $CFN_PARAMETERS  --capabilities CAPABILITY_NAMED_IAM

# Wait for Amplify application.  If it isn't created within certain time, exit.
# For this proof of concept we will poll

wait_for_Amplify_application

if  [ -z $APPLICATION_URL ]
then
    echo "Unable to look up defaultDomain $APP_ID"  | tee -a $LOG_FILE
else
    echo ""
    echo "Kicking off initial build and deploy for application: $APP_ID"
    echo "defaultDomain URL:" $APPLICATION_URL
fi

# Wait for AWS to create the branch.
# For this proof of concept we will poll

wait_for_Amplify_branch

# kick off the "job" (build) which includes turning the website live.

aws amplify start-job --app-id $APP_ID --branch-name $BRANCH --region $AWS_REGION --job-type RELEASE

echo "Amplify deployment process kicked off.  This takes time as AWS also"
echo "deploys Amplify application to cloudfront."
echo ""

# if you have a domain name to associate with the site,
# please see Amplify and Route53 documenation to create appropriate DNS records

# Log results to console and LOG_FILE
# Note, With jq this could be easily written to JSON for downstream automation
#
echo "____________________________________________________________________________"
echo "RESULTS:"
echo ""
echo "Static Web Creation: $DOMAIN" | tee -a $LOG_FILE
echo "AWS Region: $AWS_REGION"  | tee -a $LOG_FILE
echo "Application id: $APP_ID"  | tee -a $LOG_FILE
echo "Branch arn: $BRANCH_ARN"  | tee -a $LOG_FILE
echo "defaultDomain URL: $APPLICATION_URL"  | tee -a $LOG_FILE
echo "deployed branch URL: https:://$BRANCH.$APPLICATION_URL"  | tee -a $LOG_FILE
echo "Local git respository $SOURCE_ROOT/$DOMAIN"  | tee -a $LOG_FILE
echo "github respositry url: $REPOSITORY_URL"  | tee -a $LOG_FILE


