#!/bin/bash

## Test for standalone certificates.

if [[ -z $TRAVIS_CI ]]; then
  le_container_name="$(basename ${0%/*})_$(date "+%Y-%m-%d_%H.%M.%S")"
else
  le_container_name="$(basename ${0%/*})"
fi

# Create the $domains array from comma separated domains in TEST_DOMAINS.
IFS=',' read -r -a domains <<< "$TEST_DOMAINS"

cat > ${TRAVIS_BUILD_DIR}/test/tests/certs_standalone/letsencrypt_user_data <<EOF
LETSENCRYPT_STANDALONE_CERTS=('single' 'san')
LETSENCRYPT_single_HOST=('${domains[0]}')
LETSENCRYPT_san_HOST=('${domains[1]}' '${domains[2]}')
EOF

run_le_container ${1:?} "$le_container_name" \
  "--volume ${TRAVIS_BUILD_DIR}/test/tests/certs_standalone/letsencrypt_user_data:/app/letsencrypt_user_data"

  # Wait for a symlink at /etc/nginx/certs/${domains[0]}.crt
  # then grab the certificate in text form ...
wait_for_symlink "${domains[0]}" "$le_container_name"
created_cert="$(docker exec "$le_container_name" \
  openssl x509 -in /etc/nginx/certs/${domains[0]}/cert.pem -text -noout)"

# Check if the domain is on the certificate.
if grep -q "${domains[0]}" <<< "$created_cert"; then
  echo "Domain ${domains[0]} is on certificate."
else
  echo "Domain ${domains[0]} did not appear on certificate."
fi

# Wait for a symlink at /etc/nginx/certs/${domains[1]}.crt
# then grab the certificate in text form ...
wait_for_symlink "${domains[1]}" "$le_container_name"
created_cert="$(docker exec "$le_container_name" \
  openssl x509 -in /etc/nginx/certs/${domains[1]}/cert.pem -text -noout)"

for domain in "${domains[1]}" "${domains[2]}"; do
  # Check if the domain is on the certificate.
  if grep -q "$domain" <<< "$created_cert"; then
    echo "Domain $domain is on certificate."
  else
    echo "Domain $domain did not appear on certificate."
  fi
done

# Cleanup the files created by this run of the test to avoid foiling following test(s).
docker exec "$le_container_name" sh -c 'rm -rf /etc/nginx/certs/le?.wtf*'
docker stop "$le_container_name" > /dev/null
