# Reference: https://stackoverflow.com/questions/19319516/how-to-delete-a-github-repo-using-the-api
# Reference: https://docs.github.com/en/rest/reference/repos#delete-a-repository

# Delete Static Website  CAUTION: There is no recovery from this operation
# This script was created for a scenario where the entire static
# website is created from a template.  If you run this script,
# you will lose any work done on github, git local, and the Amplify app

# see create-static.sh for addtional details

# Presumes to run this script out of current directory
DEV_OPS_ROOT=$PWD

# local git repository will be deleted at this directory point
SOURCE_ROOT="/media/psf/Shared/IT/dev/available-sites"

# Default region unless specified as $2 on command line
AWS_REGION="us-west-2"

# AWS Secret Manager tokens for delete static-web-site github.

# create-static-site.sh uses an AWS Secret Manager "createtoken".  I don't
# recommend giving createtoken , which is used by Amplify, delete rights.
# If you are going to destroy the static website stack using this script, 
# then I recommend that you create a different personal github token
# specifically with delete rights.

# Note that if you use this script, you must also have the github user name in
# AWS Secrets Manager.  In create-static-website, we didn't need the username to
# create the repo.
SECRET_ID='GitHub-manage'
DELETE_KEY='delete_token'
SECRET_USER='user_name'

if [[ $1 == '--help' ]]; then
    echo "Usage: destroy-static-site my-domain-apex-name aws-region"
    echo "if no aws-region is specified, the default is $AWS_REGION"
    exit 1
fi

if [ -z $1 ]
  then
    echo "you must supply at least one argument - the site apex name."
    echo "use --help for more information."
    exit 1
fi

if [[ ! $2 == "" ]]
    then
        AWS_REGION=$2
fi

DOMAIN=$1

echo "CAUTION:"
echo "CAUTION: There is no recovery from this action!"
echo "CAUTION: "
echo "The action will delete EVERYTHING related to your deployment of: "
echo ""
echo "                   $DOMAIN on $AWS_REGION!"
echo ""
read -p "Continue (y/n)?" CONTINUE
if [ "$CONTINUE" != "y" ]; then
  echo "Exiting with no action taken...";
  exit 1
fi

# Rough check of parameters ok, so lets start process
LOG_BASE_FILE="$DOMAIN-$AWS_REGION-delete.log"
# keep log file in DEV_OPS_ROOT until completiong them mv to /log
LOG_FILE="$DEV_OPS_ROOT/log/$LOG_BASE_FILE" 

echo "Automated DELETE of ${DOMAIN} publication"  | tee $LOG_FILE
echo "$(date +"%m-%d-%Y-%T") Delete Amplify deploy of $DOMAIN in region $AWS_REGION"  | tee -a $LOG_FILE

# Use AWS secretsmanager to get secret value for deletetoken and username,
# then remove the github repository

GH=$(aws secretsmanager get-secret-value --secret-id GitHub-manage --region $AWS_REGION)

if [ -z "$GH" ]
    then
        echo "Unable to find SSM github tokens in $AWS_REGION"
        exit 1
fi

# github delete token
GH_TOKEN=$(echo $GH | jq --raw-output .SecretString | jq -r ."${DELETE_KEY}")
if [ -z "$GH_TOKEN" ]
    then
        echo "Unable to find Secret Manager github delete token $DELETE_KEY in $AWS_REGION"
        exit 1
fi

# github user
GH_USER=$(echo $GH | jq --raw-output .SecretString | jq -r ."${SECRET_USER}")
if [ -z "$GH_USER" ]
    then
        echo "Unable to find Secret Manager github user name $SECRET_USER in $AWS_REGION"
        exit 1
fi

# delete cloud formation stack
aws cloudformation delete-stack --stack-name $DOMAIN --region $AWS_REGION

# Delete github repository

curl -X DELETE \
-H "Authorization: token ${GH_TOKEN}" \
https://api.github.com/repos/${GH_USER}/${DOMAIN}

# remove local source files including local git repository
rm -rf $SOURCE_ROOT/$DOMAIN

echo "Delete scheduled - Cloud formation stack delete in progress."  | tee -a $LOG_FILE
