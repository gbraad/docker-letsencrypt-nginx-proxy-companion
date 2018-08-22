#!/bin/bash
# shellcheck disable=SC2155

[[ -z "${VHOST_DIR:-}" ]] && \
 declare -r VHOST_DIR=/etc/nginx/vhost.d
[[ -z "${START_HEADER:-}" ]] && \
 declare -r START_HEADER='## Start of configuration add by letsencrypt container'
[[ -z "${END_HEADER:-}" ]] && \
 declare -r END_HEADER='## End of configuration add by letsencrypt container'

function check_nginx_proxy_container_run {
    local _nginx_proxy_container=$(get_nginx_proxy_container)
    if [[ -n "$_nginx_proxy_container" ]]; then
        if [[ $(docker_api "/containers/${_nginx_proxy_container}/json" | jq -r '.State.Status') = "running" ]];then
            return 0
        else
            echo "$(date "+%Y/%m/%d %T") Error: nginx-proxy container ${_nginx_proxy_container} isn't running." >&2
            return 1
        fi
    else
        echo "$(date "+%Y/%m/%d %T") Error: could not get a nginx-proxy container ID." >&2
        return 1
fi
}

function add_location_configuration {
    local domain="${1:-}"
    [[ -z "$domain" || ! -f "${VHOST_DIR}/${domain}" ]] && domain=default
    [[ -f "${VHOST_DIR}/${domain}" && \
       -n $(sed -n "/$START_HEADER/,/$END_HEADER/p" "${VHOST_DIR}/${domain}") ]] && return 0
    echo "$START_HEADER" > "${VHOST_DIR}/${domain}".new
    cat /app/nginx_location.conf >> "${VHOST_DIR}/${domain}".new
    echo "$END_HEADER" >> "${VHOST_DIR}/${domain}".new
    [[ -f "${VHOST_DIR}/${domain}" ]] && cat "${VHOST_DIR}/${domain}" >> "${VHOST_DIR}/${domain}".new
    mv -f "${VHOST_DIR}/${domain}".new "${VHOST_DIR}/${domain}"
    return 1
}

function add_standalone_configuration {
    local domain="${1:?}"
    cat > "/etc/nginx/conf.d/$domain-standalone-cert.conf" << EOF
server {
    server_name $domain;
    listen 80;
    access_log /var/log/nginx/access.log vhost;
    location ^~ /.well-known/acme-challenge/ {
        auth_basic off;
        allow all;
        root /usr/share/nginx/html;
        try_files \$uri =404;
        break;
    }
}
EOF
}

function remove_all_location_configurations {
    local old_shopt_options=$(shopt -p) # Backup shopt options
    shopt -s nullglob
    for file in "${VHOST_DIR}"/*; do
        [[ -n $(sed -n "/$START_HEADER/,/$END_HEADER/p" "$file") ]] && \
         sed -i "/$START_HEADER/,/$END_HEADER/d" "$file"
    done
    eval "$old_shopt_options" # Restore shopt options
}

function check_cert_min_validity {
    # Check if a certificate ($1) is still valid for a given amount of time in seconds ($2).
    # Returns 0 if the certificate is still valid for this amount of time, 1 otherwise.
    local cert_path="$1"
    local min_validity="$(( $(date "+%s") + $2 ))"

    local cert_expiration
    cert_expiration="$(openssl x509 -noout -enddate -in "$cert_path" | cut -d "=" -f 2)"
    cert_expiration="$(date --utc --date "${cert_expiration% GMT}" "+%s")"

    [[ $cert_expiration -gt $min_validity ]] || return 1
}

function get_self_cid {
    DOCKER_PROVIDER=${DOCKER_PROVIDER:-docker}

    case "${DOCKER_PROVIDER}" in
    ecs|ECS)
        # AWS ECS. Enabled in /etc/ecs/ecs.config (http://docs.aws.amazon.com/AmazonECS/latest/developerguide/container-metadata.html)
        if [[ -n "${ECS_CONTAINER_METADATA_FILE:-}" ]]; then
            grep ContainerID "${ECS_CONTAINER_METADATA_FILE}" | sed 's/.*: "\(.*\)",/\1/g'
        else
            echo "${DOCKER_PROVIDER} specified as 'ecs' but not available. See: http://docs.aws.amazon.com/AmazonECS/latest/developerguide/container-metadata.html" >&2
            exit 1
        fi
        ;;
    *)
        sed -nE 's/^.+docker[\/-]([a-f0-9]{64}).*/\1/p' /proc/self/cgroup | head -n 1
        ;;
    esac
}

## Docker API
function docker_api {
    local scheme
    local curl_opts=(-s)
    local method=${2:-GET}
    # data to POST
    if [[ -n "${3:-}" ]]; then
        curl_opts+=(-d "$3")
    fi
    if [[ -z "$DOCKER_HOST" ]];then
        echo "Error DOCKER_HOST variable not set" >&2
        return 1
    fi
    if [[ $DOCKER_HOST == unix://* ]]; then
        curl_opts+=(--unix-socket ${DOCKER_HOST#unix://})
        scheme='http://localhost'
    else
        scheme="http://${DOCKER_HOST#*://}"
    fi
    [[ $method = "POST" ]] && curl_opts+=(-H 'Content-Type: application/json')
    curl "${curl_opts[@]}" -X${method} ${scheme}$1
}

function docker_exec {
    local id="${1?missing id}"
    local cmd="${2?missing command}"
    local data=$(printf '{ "AttachStdin": false, "AttachStdout": true, "AttachStderr": true, "Tty":false,"Cmd": %s }' "$cmd")
    exec_id=$(docker_api "/containers/$id/exec" "POST" "$data" | jq -r .Id)
    if [[ -n "$exec_id" && "$exec_id" != "null" ]]; then
        docker_api /exec/$exec_id/start "POST" '{"Detach": false, "Tty":false}'
    else
        echo "$(date "+%Y/%m/%d %T"), Error: can't exec command ${cmd} in container ${id}. Check if the container is running." >&2
        return 1
    fi
}

function docker_kill {
    local id="${1?missing id}"
    local signal="${2?missing signal}"
    docker_api "/containers/$id/kill?signal=$signal" "POST"
}

function labeled_cid {
    docker_api "/containers/json" | jq -r '.[] | select(.Labels["'$1'"])|.Id'
}

function is_docker_gen_container {
    local id="${1?missing id}"
    if [[ $(docker_api "/containers/$id/json" | jq -r '.Config.Env[]' | egrep -c '^DOCKER_GEN_VERSION=') = "1" ]]; then
        return 0
    else
        return 1
    fi
}

function get_docker_gen_container {
    # First try to get the docker-gen container ID from the container label.
    local docker_gen_cid="$(labeled_cid com.github.jrcs.letsencrypt_nginx_proxy_companion.docker_gen)"

    # If the labeled_cid function dit not return anything and the env var is set, use it.
    if [[ -z "$docker_gen_cid" ]] && [[ -n "${NGINX_DOCKER_GEN_CONTAINER:-}" ]]; then
        docker_gen_cid="$NGINX_DOCKER_GEN_CONTAINER"
    fi

    # If a container ID was found, output it. The function will return 1 otherwise.
    [[ -n "$docker_gen_cid" ]] && echo "$docker_gen_cid"
}

function get_nginx_proxy_container {
    local volumes_from
    # First try to get the nginx container ID from the container label.
    local nginx_cid="$(labeled_cid com.github.jrcs.letsencrypt_nginx_proxy_companion.nginx_proxy)"

    # If the labeled_cid function dit not return anything ...
    if [[ -z "${nginx_cid}" ]]; then
        # ... and the env var is set, use it ...
        if [[ -n "${NGINX_PROXY_CONTAINER:-}" ]]; then
            nginx_cid="$NGINX_PROXY_CONTAINER"
        # ... else try to get the container ID with the volumes_from method.
        else
            volumes_from=$(docker_api "/containers/${SELF_CID:-$(get_self_cid)}/json" | jq -r '.HostConfig.VolumesFrom[]' 2>/dev/null)
            for cid in $volumes_from; do
                cid="${cid%:*}" # Remove leading :ro or :rw set by remote docker-compose (thx anoopr)
                if [[ $(docker_api "/containers/$cid/json" | jq -r '.Config.Env[]' | egrep -c '^NGINX_VERSION=') = "1" ]];then
                    nginx_cid="$cid"
                    break
                fi
            done
        fi
    fi

    # If a container ID was found, output it. The function will return 1 otherwise.
    [[ -n "$nginx_cid" ]] && echo "$nginx_cid"
}

## Nginx
function reload_nginx {
    local _docker_gen_container=$(get_docker_gen_container)
    local _nginx_proxy_container=$(get_nginx_proxy_container)

    if [[ -n "${_docker_gen_container:-}" ]]; then
        # Using docker-gen and nginx in separate container
        echo "Reloading nginx docker-gen (using separate container ${_docker_gen_container})..."
        docker_kill "${_docker_gen_container}" SIGHUP

        if [[ -n "${_nginx_proxy_container:-}" ]]; then
            # Reloading nginx in case only certificates had been renewed
            echo "Reloading nginx (using separate container ${_nginx_proxy_container})..."
            docker_kill "${_nginx_proxy_container}" SIGHUP
        fi
    else
        if [[ -n "${_nginx_proxy_container:-}" ]]; then
            echo "Reloading nginx proxy (${_nginx_proxy_container})..."
            docker_exec "${_nginx_proxy_container}" \
                '[ "sh", "-c", "/app/docker-entrypoint.sh /usr/local/bin/docker-gen /app/nginx.tmpl /etc/nginx/conf.d/default.conf; /usr/sbin/nginx -s reload" ]' \
                | sed -rn 's/^.*([0-9]{4}\/[0-9]{2}\/[0-9]{2}.*$)/\1/p'
            [[ ${PIPESTATUS[0]} -eq 1 ]] && echo "$(date "+%Y/%m/%d %T"), Error: can't reload nginx-proxy." >&2
        fi
    fi
}

# Convert argument to lowercase (bash 4 only)
function lc {
	echo "${@,,}"
}
