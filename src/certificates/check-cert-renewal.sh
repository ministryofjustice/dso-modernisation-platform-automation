#!/bin/bash
ec2_hostname=$1
renew_expiry_days=$2
commonName=$3
date_cmd=date
shift 2
san=$(echo "$@" | tr ' ' '\n' | sort | xargs)

echo "aws secretsmanager get-secret-value --secret-id /ec2/$ec2_hostname/web-cert" >&2
cert_json=$(aws secretsmanager get-secret-value --secret-id "/ec2/$ec2_hostname/web-cert"  --query SecretString --output text || true)

if [[ $OSTYPE == 'darwin'* ]]; then
  date_cmd=gdate
fi

if [[ -n $cert_json ]]; then
  password=$(jq -r .Password <<< "$cert_json")
  pfx_base_64=$(jq -r .PfxBase64 <<< "$cert_json")
  echo "$pfx_base_64" | base64 -d > cert.pfx
  openssl pkcs12 -in cert.pfx -out cert.cer -nokeys -passin "pass:${password}"
  cert_commonName=$(openssl x509 -in cert.cer -noout -subject -nameopt multiline | sed -n 's/ *commonName *= //p')
  cert_san=$(openssl x509 -in cert.cer -noout -text | grep "DNS:" | sed 's/DNS://g' | sed 's/,/ /g' | tr -s '[:space:]' | sed 's/^ //' | tr ' ' '\n' | sort | xargs)
  cert_enddate=$(openssl x509 -in cert.cer -noout -enddate | cut -d= -f 2-)
  cert_enddate_epoch=$($date_cmd -d"$cert_enddate" +%s)
  now_epoch=$($date_cmd +%s)
  cert_days_to_expiry=$(( (cert_enddate_epoch - now_epoch) / 86400 ))
  if [[ $cert_commonName != "$commonName" ]]; then
    echo "Cert Mismatch CommonName: Cert=$cert_commonName Conf=$commonName" >&2
  elif [[ $cert_san != "$san" ]]; then
    echo "Cert Mismatch SAN: Cert=$cert_san Conf=$san" >&2
  elif (( cert_days_to_expiry <= renew_expiry_days )); then
    echo "Cert Renewal Due: CertExpiry=$cert_enddate DaysToExpiry=$cert_days_to_expiry<=$renew_expiry_days" >&2
  else
    echo "renew_cert=0"
    exit
  fi
fi
echo "renew_cert=1"
echo "update_web=1"
echo "requires_update=1"
