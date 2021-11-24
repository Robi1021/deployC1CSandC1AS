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
