
#dsscreporter

source ~/environment/cloudOneOnAws/00_define_vars.sh

git clone https://github.com/mawinkler/vulnerability-management.git
PREVIOUS_DIR=`pwd`
cd vulnerability-management/cloudone-image-security/scan-report
# cp config.yml.sample config.yml
# sudo apt install python3-pip -y

pip3 install -r requirements.txt
pip3 install  fpdf requests simplejson urllib3
pip3 install --upgrade requests

Adding ACR
az acr list --resource-group AZ03 --output table
az acr update -n c1appsecmoneyx --admin-enabled true
az acr credential show --name c1appsecmoneyx
ACR_URL=`az acr list --resource-group AZ03 | jq -r '.[].loginServer'`
ACR_USERNAME=`az acr credential show --name c1appsecmoneyx | jq -r '.username'`
ACR_PASSWORD=`az acr credential show --name c1appsecmoneyx | jq -r '.passwords[0].value'`
echo ${ACR_URL}
echo ${ACR_USERNAME}
echo ${ACR_PASSWORD}

cat <<EOF >config.yml
dssc:
  service: "${DSSC_HOST}:443"
  username: "${DSSC_USERNAME}"
  password: "${DSSC_PASSWORD}"

repository:
  #repository name should NOT include the path (PoC code)
  name: "cappsecmoneyx"
  image_tag: "latest"

criticalities:
  - defcon1
  - critical
  - high
  - medium
EOF

cat config.yml

python3 scan-report.py


#get registry overview
cd $PREVIOUS_DIR

#-----------------------------------------------------

# Get Registry findings
#-----------------------
source ~/environment/cloudOneOnAws/00_define_vars.sh
export DSSC_HOST=`kubectl get service proxy  -n smartcheck -o json |jq -r ".status.loadBalancer.ingress[].hostname"`
[[ "${PLATFORM}" == "AZURE" ]] &&  export DSSC_HOST=${DSSC_HOST//./-}.nip.io
[[ "${PLATFORM}" == "AWS" ]]  && export DSSC_HOST=${DSSC_HOST_RAW}
echo $DSSC_HOST

DSSC_BEARERTOKEN=$(curl -k -X POST https://${DSSC_HOST}/api/sessions -H "Content-Type: application/json"  -H "Api-Version: 2018-05-01" -H "cache-control: no-cache" -d "{\"user\":{\"userid\":\"${DSSC_USERNAME}\",\"password\":\"${DSSC_PASSWORD}\"}}" | jq '.token' | tr -d '"')
echo -E Bearer Token = $DSSC_BEARERTOKEN

DSSC_REGISTRYIDS=(`curl -s -k -X GET https://${DSSC_HOST}/api/registries -H "Content-Type: application/json" -H "Api-Version: 2018-05-01" -H "Authorization: Bearer ${DSSC_BEARERTOKEN}" -H 'cache-control: no-cache' | jq -r ".registries[].id" `)
echo ${DSSC_REGISTRYIDS[@]}

DSSC_REGISTRYINAMES=(`curl -s -k -X GET https://${DSSC_HOST}/api/registries -H "Content-Type: application/json" -H "Api-Version: 2018-05-01" -H "Authorization: Bearer ${DSSC_BEARERTOKEN}" -H 'cache-control: no-cache' | jq -r ".registries[].name" `)
echo ${DSSC_REGISTRYINAMES[@}]}



curl -s -k -X GET https://${DSSC_HOST}/api/registries -H "Content-Type: application/json" -H "Api-Version: 2018-05-01" -H "Authorization: Bearer ${DSSC_BEARERTOKEN}" -H 'cache-control: no-cache' | jq -r 'map({id,title,url,company,location}) | (first | keys_unsorted) as $keys | map([to_entries[] | .value]) as $rows | $keys,$rows[] | @csv' jobs.json > jobs.csv



printf '%s\n' $DSSC_ECR_REPOID
