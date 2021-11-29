#!/bin/bash
###eksctl scale nodegroup --cluster=managed-smartcheck --nodes=1 --name=<nodegroupName>
printf '%s\n' "------------------------------------------"
printf '%s\n' "     Deploying / Checking Smart Check     "
printf '%s\n' "------------------------------------------"

export EXISTINGSMARTCHECKOK="false"
# If no smartcheck deployment found, deploy it 
# ----------------------------------------------
if [[ "`helm list -n ${DSSC_NAMESPACE} -o json | jq -r '.[].name'`" =~ 'deepsecurity-smartcheck' ]]; then
    # found an existing DSSC
    [ ${VERBOSE} -eq 1 ] && printf "%s\n" "Found existing SmartCheck"
    #checking if we can get a bearertoken
    export DSSC_HOST=`kubectl get services proxy -n $DSSC_NAMESPACE -o json | jq -r "${DSSC_HOST_FILTER}"`
    [[ "${PLATFORM}" == "AZURE" ]] &&  export DSSC_HOST=${DSSC_HOST//./-}.nip.io
    [[ "${PLATFORM}" == "AWS" ]]  && export DSSC_HOST=${DSSC_HOST_RAW}
    [ ${VERBOSE} -eq 1 ] && printf "%s\n" "Getting a Bearer token"
    DSSC_BEARERTOKEN=''
    DSSC_BEARERTOKEN=$(curl -s -k -X POST https://${DSSC_HOST}/api/sessions -H "Content-Type: application/json"  -H "Api-Version: 2018-05-01" -H "cache-control: no-cache" -d "{\"user\":{\"userid\":\"${DSSC_USERNAME}\",\"password\":\"${DSSC_PASSWORD}\"}}" | jq '.token' | tr -d '"')
    [ ${VERBOSE} -eq 1 ] && printf "%s\n" "Bearer Token = ${DSSC_BEARERTOKEN}"
    if [[ ! -z "${DSSC_BEARERTOKEN}" ]]; then
        # existing DSSC + can get a Bearertoken
        export EXISTINGSMARTCHECKOK="true"
        printf '%s\n' "Reusing existing Smart Check deployment"
        export DSSC_HOST=`kubectl get services proxy -n $DSSC_NAMESPACE -o json | jq -r "${DSSC_HOST_FILTER}"`
        [[ "${PLATFORM}" == "AZURE" ]] &&  export DSSC_HOST=${DSSC_HOST//./-}.nip.io
        [[ "${PLATFORM}" == "AWS" ]]  && export DSSC_HOST=${DSSC_HOST_RAW}
    else  
      #existing DSSC found, but could not get a Bearertoken -> delete existing DSSC
      printf "%s" "Uninstalling existing (and broken) smartcheck... "
      helm delete deepsecurity-smartcheck -n ${DSSC_NAMESPACE}
      printf '\n%s' "Waiting for SmartCheck pods to be deleted"
      export NROFPODS=`kubectl get pods -A | grep -c smartcheck`
      while [[ "${NROFPODS}" -gt "0" ]];do
        sleep 5
        export NROFPODS=`kubectl get pods -A | grep -c smartcheck`
        printf '%s' "."
      done
    fi
fi


if [[  "${EXISTINGSMARTCHECKOK}" == "false" ]]; then
  # (re-)install smartcheck 
  #get certificate for internal registry
  #-------------------------------------
cat << EOF > ${WORKDIR}/req.conf
# This file is (re-)generated by code.
# Any manual changes will be overwritten.
[req]
  distinguished_name=req
[san]
  subjectAltName=DNS:${DSSC_SUBJECTALTNAME}
EOF
  
  NAMESPACES=`kubectl get namespaces`
  if [[ "$NAMESPACES" =~ "${DSSC_NAMESPACE}" ]]; then
    printf '%s\n' "Reusing existing namespace \"${DSSC_NAMESPACE}\""
  else
    printf '%s' "Creating namespace smartcheck...   "
    kubectl create namespace ${DSSC_NAMESPACE}
  fi
  
  printf '%s' "Creating certificate for loadballancer...  "
  openssl req -x509 -newkey rsa:4096 -sha256 -days 3650 -nodes -keyout ${WORKDIR}/k8s.key -out ${WORKDIR}/k8s.crt -subj "/CN=${DSSC_SUBJECTALTNAME}" -extensions san -config ${WORKDIR}/req.conf
  
  printf '%s' "Creating secret with keys in Kubernetes...  "
  kubectl create secret tls k8s-certificate --cert=${WORKDIR}/k8s.crt --key=${WORKDIR}/k8s.key --dry-run=client -n ${DSSC_NAMESPACE} -o yaml | kubectl apply -f -
  
  
  # Create overrides.yml
  #-------------------------
  printf '%s\n' "Creating overrides.yml file in work directory"
  cat << EOF >${WORKDIR}/overrides.yml
# This file is (re-) generated by code.
# Any manual changes will be overwritten.
#
##
## Default value: (none)
activationCode: '${DSSC_AC}'  
#update 202111xx will change to deploying C1CSkey
# C1CSSCANNERAPIKEY from https://container.REGION.cloudone.trendmicro.com/api/scanners
#cloudOne:
#  apiKey: ${C1CSSCANNERAPIKEY}
#  endpoint: https://container.REGION.cloudone.trendmicro.com

auth:
  ## secretSeed is used as part of the password generation process for
  ## all auto-generated internal passwords, ensuring that each installation of
  ## Deep Security Smart Check has different passwords.
  ##
  ## Default value: {must be provided by the installer}
  secretSeed: 'just_anything-really_anything'
  ## userName is the name of the default administrator user that the system creates on startup.
  ## If a user with this name already exists, no action will be taken.
  ##
  ## Default value: administrator
  ## userName: administrator
  userName: '${DSSC_USERNAME}'
  ## password is the password assigned to the default administrator that the system creates on startup.
  ## If a user with the name 'auth.userName' already exists, no action will be taken.
  ##
  ## Default value: a generated password derived from the secretSeed and system details
  ## password: # autogenerated
  password: '${DSSC_TEMPPW}'
registry:
  ## Enable the built-in registry for pre-registry scanning.
  ##
  ## Default value: false
  enabled: true
    ## Authentication for the built-in registry
  auth:
    ## User name for authentication to the registry
    ##
    ## Default value: empty string
    username: '${DSSC_REGUSER}'
    ## Password for authentication to the registry
    ##
    ## Default value: empty string
    password: '${DSSC_REGPASSWORD}'
    ## The amount of space to request for the registry data volume
    ##
    ## Default value: 5Gi
  dataVolume:
    sizeLimit: 10Gi
certificate:
  secret:
    name: k8s-certificate
    certificate: tls.crt
    privateKey: tls.key
vulnerabilityScan:
  requests:
    cpu: 1000m
    memory: 3Gi
  limits:
    cpu: 1000m
    memory: 3Gi
EOF
      
  printf '%s' "Deploying SmartCheck Helm chart..."
  helm install -n ${DSSC_NAMESPACE} --values ${WORKDIR}/overrides.yml deepsecurity-smartcheck https://github.com/deep-security/smartcheck-helm/archive/master.tar.gz > /dev/null
  export DSSC_HOST=''
  export DSSC_HOST_RAW=''
  while [[ -z "$DSSC_HOST_RAW" ]];do
    export DSSC_HOST_RAW=`kubectl get svc -n ${DSSC_NAMESPACE} proxy -o json | jq -r "${DSSC_HOST_FILTER}" 2>/dev/null`
    sleep 10
    printf "%s" "."
  done
  [[ "${PLATFORM}" == "AZURE" ]] &&  export DSSC_HOST=${DSSC_HOST_RAW//./-}.nip.io
  [[ "${PLATFORM}" == "AWS" ]]  && export DSSC_HOST=${DSSC_HOST_RAW}
  [ ${VERBOSE} -eq 1 ] && printf "\n%s\n" "DSSC_HOST=${DSSC_HOST}"
  printf '\n%s' "Waiting for SmartCheck Service to come online: ."
  export DSSC_BEARERTOKEN=''
  while [[ "$DSSC_BEARERTOKEN" == '' ]];do
    sleep 5
    export DSSC_BEARERTOKEN_RAW=`curl -s -k -X POST https://${DSSC_HOST}/api/sessions -H "Content-Type: application/json"  -H "Api-Version: 2018-05-01" -H "cache-control: no-cache" -d "{\"user\":{\"userid\":\"${DSSC_USERNAME}\",\"password\":\"${DSSC_TEMPPW}\"}}" 2>/dev/null `
    export DSSC_BEARERTOKEN=`echo ${DSSC_BEARERTOKEN_RAW} | jq -r '.token' 2>/dev/`
        printf '%s' "."
  done
 printf '\n' 
  export DSSC_USERID=`curl -s -k -X POST https://${DSSC_HOST}/api/sessions -H "Content-Type: application/json"  -H "Api-Version: 2018-05-01" -H "cache-control: no-cache" -d "{\"user\":{\"userid\":\"${DSSC_USERNAME}\",\"password\":\"${DSSC_TEMPPW}\"}}" | jq '.user.id'  2>/dev/null | tr -d '"' `
  [ ${VERBOSE} -eq 1 ] && printf "%s\n" "DSSC_BEARERTOKEN=${DSSC_BEARERTOKEN}"
  [ ${VERBOSE} -eq 1 ] && printf "%s\n" "DSSC_USERID=${DSSC_USERID}"
  
  printf '%s \n' " "
     
  # do mandatory initial password change
  #----------------------------------------
  printf '%s \n' "Doing initial (required) password change"
  DUMMY=`curl -s -k -X POST https://${DSSC_HOST}/api/users/${DSSC_USERID}/password -H "Content-Type:   application/json"  -H "Api-Version: 2018-05-01" -H "cache-control: no-cache" -H "authorization: Bearer ${DSSC_BEARERTOKEN}" -d "{  \"oldPassword\": \"${DSSC_TEMPPW}\", \"newPassword\": \"${DSSC_PASSWORD}\"  }"`
  printf '%s \n' "SmartCheck is available at: "
  printf '%s \n' "--------------------------------------------------"
  printf '%s \n' "     URL: https://${DSSC_HOST}"
  printf '%s \n' "     user: ${DSSC_USERNAME}"
  printf '%s \n' "     passw: ${DSSC_PASSWORD}"
fi 





printf '%s\n' "--------------------------"
printf '%s\n' "     (re-)Adding C1CS     "
printf '%s\n' "--------------------------"

#delete old namespaces  
printf '%s\n' "Deleting any potential old C1CS artefacts on the EKS cluster"
#kubectl delete namespace c1cs  &>/dev/null
kubectl delete namespace trendmicro-system   2>/dev/null
kubectl delete clusterrole oversight-manager-role 2>/dev/null 
kubectl delete ClusterRoleBinding "oversight-manager-rolebinding"  2>/dev/null 

kubectl delete clusterrole oversight-proxy-role 2>/dev/null 
kubectl delete ClusterRoleBinding "oversight-proxy-rolebinding"  2>/dev/null 

kubectl delete namespace nginx  2>/dev/null
kubectl delete clusterrole usage-manager-role 2>/dev/null
kubectl delete clusterroleBinding "usage-manager-rolebinding" 2>/dev/null

kubectl delete namespace mywhitelistednamespace 2>/dev/null
kubectl delete clusterrole usage-proxy-role 2>/dev/null
kubectl delete ClusterRoleBinding "usage-proxy-rolebinding"  2>/dev/null


# if a cluster object for this project already exists in c1cs, then delete it 
C1CSCLUSTERS=(`\
curl --silent --location --request GET "${C1CSAPIURL}/clusters" \
--header 'Content-Type: application/json' \
--header "${C1AUTHHEADER}"  \
--header 'api-version: v1' \
 | jq -r ".clusters[]? | select(.name == \"${C1PROJECT}\").id"`)

for i in "${!C1CSCLUSTERS[@]}"
do
  #printf "%s\n" "C1CS: found cluster ${C1CSCLUSTERS[$i]}"
  if [[ "${C1CSCLUSTERS[$i]}" =~ "${C1PROJECT}" ]]; 
  then
    printf "%s\n" "Deleting old Cluster object (${C1CSCLUSTERS[$i]}) in C1CS"
    curl --silent --location --request DELETE "${C1CSAPIURL}/clusters/${C1CSCLUSTERS[$i]}" \
       --header 'Content-Type: application/json' \
       --header "${C1AUTHHEADER}"  \
       --header 'api-version: v1' 
  fi
done 

# if a Scanner object for this project already exists in c1cs, then delete it 
C1CSSCANNERS=(`\
curl --silent --location --request GET "${C1CSAPIURL}/scanners" \
--header 'Content-Type: application/json' \
--header "${C1AUTHHEADER}"  \
--header 'api-version: v1' \
 | jq -r ".scanners[]? | select(.name == \"${C1PROJECT}\").id"`)

for i in "${!C1CSSCANNERS[@]}"
do
  printf "%s\n" "Deleting old scanner object ${C1CSSCANNERS[$i]} from C1CS"
  curl --silent --location --request DELETE "${C1CSAPIURL}/scanners/${C1CSSCANNERS[$i]}" \
--header 'Content-Type: application/json' \
--header "${C1AUTHHEADER}"  \
--header 'api-version: v1' 
done 

# if a Policy object for this project already exists in c1cs, then delete it 
C1CSPOLICIES=(`\
curl --silent --location --request GET "${C1CSAPIURL}/policies" \
--header 'Content-Type: application/json' \
--header "${C1AUTHHEADER}"  \
--header 'api-version: v1' \
 | jq -r ".policies[]? | select(.name == \"${C1PROJECT}\").id"`)  2>/dev/null

for i in "${!C1CSPOLICIES[@]}"
do
  printf "%s\n" "Deleting old policy objecy ${C1CSPOLICIES[$i]} from C1CS"
  curl --silent --location --request DELETE "${C1CSAPIURL}/policies/${C1CSPOLICIES[$i]}" \
--header 'Content-Type: application/json' \
--header "${C1AUTHHEADER}"  \
--header 'api-version: v1' 
done 


printf '%s\n' "Creating a cluster object in C1Cs and get an API key to deploy C1CS to the K8S cluster"
export TEMPJSON=` \
curl --silent --location --request POST "${C1CSAPIURL}/clusters" \
--header 'Content-Type: application/json' \
--header "${C1AUTHHEADER}"  \
--header 'api-version: v1' \
--data-raw "{   \
    \"name\": \"${C1PROJECT}\", \
    \"description\": \"EKS cluster added by the CloudOneOnAWS project ${C1PROJECT}\"}"`
#echo $TEMPJSON | jq

export C1APIKEYforCLUSTERS=`echo ${TEMPJSON}| jq -r ".apiKey"`
#echo  C1APIKEYforCLUSTERS = $C1APIKEYforCLUSTERS
export C1CSCLUSTERID=`echo ${TEMPJSON}| jq -r ".id"`
#echo C1CSCLUSTERID = $C1CSCLUSTERID
if [[ "${C1CS_RUNTIME}" == "true" ]]; then
    export C1RUNTIMEKEY=`echo ${TEMPJSON}| jq -r ".runtimeKey"`
    #echo C1RUNTIMEKEY = $C1RUNTIMEKEY
    export C1RUNTIMESECRET=`echo ${TEMPJSON}| jq -r ".runtimeSecret"`
    #echo C1RUNTIMESECRET = $C1RUNTIMESECRET
else
    export C1RUNTIMEKEY=""
    export C1RUNTIMESECRET=""
fi

## deploy C1CS to the K8S cluster of the CloudOneOnAWS project
printf '%s\n' "Deploying C1CS to the K8S cluster of the CloudOneOnAWS project"

if [[ "${C1CS_RUNTIME}" == "true" ]]; then
    cat << EOF >work/overrides.addC1csToK8s.yml
    cloudOne:
        apiKey: ${C1APIKEYforCLUSTERS}
        endpoint: ${C1CSENDPOINTFORHELM}
        runtimeSecurity:
          enabled: true
EOF
else
    cat << EOF >work/overrides.addC1csToK8s.yml
    cloudOne:
        apiKey: ${C1APIKEYforCLUSTERS}
        endpoint: ${C1CSENDPOINTFORHELM}
EOF
fi
printf '%s\n' "Running Helm to deploy/upgrade C1CS"
DUMMY=`helm upgrade \
     trendmicro \
     --namespace trendmicro-system --create-namespace \
     --values work/overrides.addC1csToK8s.yml \
     --install \
     https://github.com/trendmicro/cloudone-container-security-helm/archive/master.tar.gz`

printf '%s' "Waiting for C1CS pod to become running"
while [[ `kubectl get pods -n trendmicro-system | grep trendmicro-admission-controller | grep "1/1" | grep -c Running` -ne 1 ]];do
  sleep 3
  printf '%s' "."
  #kubectl get pods -n trendmicro-system
done

# Creating a Scanner
## Creating a Scanner object in C1Cs and getting an API key for the Scanner

printf '\n%s\n' "Creating a Scanner object in C1Cs and getting an API key for the Scanner"
export TEMPJSON=`\
curl --silent --location --request POST "${C1CSAPIURL}/scanners" \
--header 'Content-Type: application/json' \
--header "${C1AUTHHEADER}"  \
--header 'api-version: v1' \
--data-raw "{
    \"name\": \"${C1PROJECT}\",
    \"description\": \"The SmartCheck scanner added by the CloudOneDevOps project ${C1PROJECT} \"
}" `
#echo $TEMPJSON | jq
export C1APIKEYforSCANNERS=`echo ${TEMPJSON}| jq -r ".apiKey"`
#echo  $C1APIKEYforSCANNERS
export C1CSSCANNERID=`echo ${TEMPJSON}| jq -r ".id"`
#echo $C1CSSCANNERID
cat << EOF > work/overrides.smartcheck.yml
cloudOne:
     apiKey: ${C1APIKEYforSCANNERS}
     endpoint: ${C1CSENDPOINTFORHELM}
EOF
printf '%s\n' "Running Helm upgrade for SmartCheck"
DUMMY=`helm upgrade \
     deepsecurity-smartcheck -n ${DSSC_NAMESPACE} \
     --values work/overrides.smartcheck.yml \
     --reuse-values \
     https://github.com/deep-security/smartcheck-helm/archive/master.tar.gz`
     
#watch kubectl get pods -n ${DSSC_NAMESPACE} 
        
# Creating an Admission Policy
printf '%s\n' "Creating Admission Policy in C1Cs"
export POLICYID=`curl --silent --location --request POST "${C1CSAPIURL}/policies" \
--header 'Content-Type: application/json' \
--header "${C1AUTHHEADER}"  \
--header 'api-version: v1' \
--data-raw "{
    \"name\": \"${C1PROJECT}\",
    \"description\": \"Policy created by the CloudOneDevOps project ${C1PROJECT}\",
    \"default\": {
        \"rules\": [
            {
                \"type\": \"registry\",
                \"enabled\": true,
                \"action\": \"block\",
                \"statement\": {
                    \"key\": \"equals\",
                    \"value\": \"docker.io\"
                }
             },   
            {
              \"action\": \"block\",
              \"type\": \"unscannedImage\",
              \"enabled\": true
            },
            {
              \"action\": \"block\",
              \"type\": \"malware\",
              \"enabled\": true,
              \"statement\": {
                \"key\": \"count\",
                \"value\": \"0\"
              }
            }

          ],
        \"exceptions\": [
            {
                \"type\": \"registry\",
                \"enabled\": true,
                \"statement\": {
                    \"key\": \"equals\",
                    \"value\": \"gcr.io\"
                }
            }
        ]
    }
}" \
| jq -r ".id"`
#echo $POLICYID


# AssignAdmission Policy to Cluster
ADMISSION_POLICY_ID=`curl --silent --request POST \
  --url ${C1CSAPIURL}/clusters/${C1CSCLUSTERID} \
  --header "${C1AUTHHEADER}" \
  --header 'Content-Type: application/json' \
  --data "{\"description\":\"EKS cluster added and Policy Assigned by the CloudOneOnAWS project ${C1PROJECT}\",\"policyID\":\"${POLICYID}\"}" | jq -r ".policyID"`

# testing C1CS (admission control)
# --------------------------------
printf '%s\n' "Whitelisting namespace smartcheck for Admission Control"
kubectl label namespace smartcheck ignoreAdmissionControl=ignore &>/dev/null
# testing admission control
kubectl create namespace nginx 
kubectl create namespace mywhitelistednamespace
#whitelist that namespace for C1CS
kubectl label namespace mywhitelistednamespace ignoreAdmissionControl=ignore --overwrite=true 
printf '%s\n' "Testing C1CS Admission Control:"
printf '%s\n' "   THE DEPLOYMENT BELOW SHOULD FAIL: Deploying nginx pod in its own namespace "
kubectl run nginx --image=nginx --namespace nginx nginx 
printf '%s\n' "   THE DEPLOYMENT BELOW SHOULD WORK: Deploying nginx pod in whitelisted namespace "
#deploying nginx in the "mywhitelistednamespace" will work:
kubectl run nginx --image=nginx --namespace mywhitelistednamespace 
#kubectl get namespaces --show-labels
#kubectl get pods -A | grep nginx







#printf '%s\n' "-------------------------------------------------------"
#printf '%s\n' "     (re-)Adding C1CS activation key to SmartCheck     "
#printf '%s\n' "-------------------------------------------------------"




#!/bin/bash

printf '%s\n' "--------------------------------------------------"
printf '%s\n' "     Adding internal registry to SmartCheck     "
printf '%s\n' "--------------------------------------------------"

varsok=true
if  [ -z "${DSSC_USERNAME}" ]; then echo DSSC_USERNAME must be set && varsok=false; fi
if  [ -z "${DSSC_PASSWORD}" ]; then echo DSSC_PASSWORD must be set && varsok=false; fi
if  [ -z "${DSSC_HOST}" ]; then echo DSSC_HOST must be set && varsok=false; fi
if [ "$varsok" = "false" ]; then 
   printf "%s\n" "Check the above-mentioned variables"; 
   read -p "Press CTRL-C to exit script, or Enter to continue anyway (script will fail)"
fi
# Getting a DSSC_BEARERTOKEN 
#-----------------------------
[ ${VERBOSE} -eq 1 ] && printf "\n%s\n" "Getting Bearer token"
[ ${VERBOSE} -eq 1 ] && curl -s -k -X POST https://${DSSC_HOST}/api/sessions -H "Content-Type: application/json"  -H "Api-Version: 2018-05-01" -H "cache-control: no-cache" -d "{\"user\":{\"userid\":\"${DSSC_USERNAME}\",\"password\":\"${DSSC_PASSWORD}\"}}"
DSSC_BEARERTOKEN=$(curl -s -k -X POST https://${DSSC_HOST}/api/sessions -H "Content-Type: application/json"  -H "Api-Version: 2018-05-01" -H "cache-control: no-cache" -d "{\"user\":{\"userid\":\"${DSSC_USERNAME}\",\"password\":\"${DSSC_PASSWORD}\"}}" | jq '.token' | tr -d '"')
[ ${VERBOSE} -eq 1 ] && printf "\n%s\n" "Bearer Token = ${DSSC_BEARERTOKEN}"

# Adding internal registry to SmartCheck:
# ------------------------------------------
[ ${VERBOSE} -eq 1 ] && printf "\n%s\n" "Adding internal registry to SmartCheck"
DSSC_REPOID=$(curl -s -k -X POST https://$DSSC_HOST/api/registries?scan=true -H "Content-Type: application/json" -H "Api-Version: 2018-05-01" -H "Authorization: Bearer $DSSC_BEARERTOKEN" -H 'cache-control: no-cache' -d "{\"name\":\"Internal_Registry\",\"description\":\"added by  ChrisV\n\",\"host\":\"${DSSC_HOST}:5000\",\"credentials\":{\"username\":\"${DSSC_REGUSER}\",\"password\":\"$DSSC_REGPASSWORD\"},\"insecureSkipVerify\":"true"}" | jq '.id')
printf "\n%s\n" "Repo added with id: ${DSSC_REPOID}"

#TODO: write a test to verify if the Registry was successfully added
