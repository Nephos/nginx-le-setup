#!/bin/bash
#
# Setup a virtual host with a let's encrypt certificate
#
# This script assumes that your nginx default servername
# is configured for lets encrypt
#

if [ "$(id -u)" != "0" ]; then
    echo "This script requires root privileges."
    exit 1
fi

if ! command -v nginx 1>/dev/null; then
    echo "This script requires nginx."
    exit 1
fi

NGINX_DIR="/etc/nginx"
HTTP2_MIN_VERSION=1.9.5
# Internal variables
CONFIRM=0
HTTP2=""
HSTS=""
LE_ARGS=""
NGINX_VERSION=$(nginx -v 2>&1 | cut -d '/' -f 2)
domains=$(find ${NGINX_DIR} -type f -print0 | xargs -0 egrep '^(\s|\t)*server_name' \
	      | sed -r 's/(.*server_name\s*|;)//g' | grep -v "localhost\|_")

config ()
{
    STATIC="root ${VPATH};
        location / { try_files \$uri \$uri/ =404; }"
    DYNAMIC="location / {
        proxy_pass http://localhost:${VPORT}/;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \"upgrade\";
        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forward-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forward-Proto http;
        proxy_set_header X-Nginx-Proxy true;
        proxy_redirect off;
    }"
}

version_gt() { test "$(printf '%s\n' "$@" | sort -V | head -n 1)" != "$1"; }

if ! version_gt "$HTTP2_MIN_VERSION" "$NGINX_VERSION"; then
   HTTP2=" http2"
fi

#Check for a config file
if [ -f ~/.nginx-le-setup ];then
    . ~/.nginx-le-setup
fi

# render a template configuration file
# expand variables + preserve formatting
render_template() {
    eval "echo \"$(cat "$1")\""
}

error () {
    echo "try '$0 --help' for more information"
}
usage () {
    echo "Usage: $0 <add|list> <params>"
    echo -e "\nCreate/Add arguments\n  -n, \t--name"
    echo -e "  -d, \t--directory \tWebsite directory"
    echo -e "  -p, \t--port \t\tPort used for a dynamic website"
    echo -e "  -e, \t--email \tlets encrypt email"
    echo -e "  -wb, \t--webroot-path"
    echo -e "  -y\t\t\tAssume Yes to all queries and do not prompt"
    echo -e "  --staging\t\tDo not issue a trusted certificate"
}

create () {
    while [[ $# -gt 0 ]]
    do
	key="$1"
	case $key in
	    -n|--name)
		VNAME="$2"
		shift
		;;
	    -d|--dir|--directory)
		VPATH="$2"
		shift
		;;
	    -p|--port)
		VPORT="$2"
		shift
		;;
	    -e|--email)
		EMAIL="$2"
		shift
		;;
	    -wb|--webroot-path)
		WEBROOT_PATH="$2"
		shift
		;;
	    --staging)
		LE_ARGS+="--staging "
		;;
	    -y)
		CONFIRM=1
		;;
	    *)
		# unknown option
		;;
    esac
    shift # past argument or value
    done

    if [[ -z "$VNAME" ]]; then
	echo "--name required" && error && exit 1
    elif [[ -z "$VPATH" ]] && [[ -z "$VPORT" ]]; then
	echo "Directory (-d) or port number (-p) is required" && error && exit 1
    elif [[ -z "$EMAIL" ]]; then
	echo "Lets encrypt email is required" && error && exit 1
    elif [[ -z "${WEBROOT_PATH}" ]]; then
	echo "Web root path is not set !" && error && exit 1
    elif [[ ! -z "$VPATH" ]] && [[ ! -z "$VPORT" ]]; then
	echo "--port and --directory parameters are mutually exclusive"  && error && exit 1
    else
	for domain in $domains; do
	    if [[ "${domain}" == "${VNAME}" ]]; then
		echo "Error : Domain already listed in nginx's virtual hosts"
		exit 2;
	    fi
	done
    fi

    if [[ ! -d "${WEBROOT_PATH}" ]]; then
	echo "Error : Webroot path '${WEBROOT_PATH}' does not exists" && exit 3
    elif [[ ! -z "$VPATH" ]] && [[ ! -d "${VPATH}" ]]; then
	echo "Error : directory '${VPATH}' does not exists" && exit 3
    elif [[ ! -z "$VPORT" ]] && [[ "$VPORT" != ?(-)+([0-9]) ]]; then
	echo "Error : '${VPORT}' is not a valid port" && exit 3
    elif nginx -t; then
	echo "Creating a virtual host named '${VNAME}'"
    else
	echo "Nginx configuration is incorrect, aborting." && exit 10;
    fi

    if [[ $CONFIRM == 0 ]]; then
	echo -n "Is this ok?? [y/N]: "
	read continue
	if [[ ${continue} != "y" ]]; then
	    echo "Opertion aborted"
	    exit 3;
	fi
    fi

    echo "Creating certificate...."
    # Creating cert
    if ! letsencrypt certonly ${LE_ARGS} --rsa-key-size 4096 --non-interactive \
	 --agree-tos --keep --text --email "${EMAIL}" -a webroot \
	 --webroot-path="${WEBROOT_PATH}" -d "${VNAME}"; then
	echo "Error when creating cert, aborting..." && exit 4
    fi

    config
    # Adding virtual host
    if [ ! -z "${VPATH}" ]; then
	echo "Adding vhost file (static)"
	CONFIG=${STATIC}
    else
	echo "Adding vhost file (dynamic)"
	CONFIG=${DYNAMIC}
    fi

    render_template base.template > "${NGINX_DIR}/sites-available/${VNAME}"
    ln -s "${NGINX_DIR}/sites-available/${VNAME}" "${NGINX_DIR}/sites-enabled/${VNAME}"

    # Reload nginx
    if nginx -t; then
	systemctl reload nginx
	echo "${VNAME} is now active and working"
    else
	echo "nginx config verification failed, rollbacking.."
	unlink "${NGINX_DIR}/sites-enabled/${VNAME}"
	rm -v "${NGINX_DIR}/sites-available/${VNAME}"
    fi
}

key="$1"

case $key in
    list)
	echo "$domains"
	;;
    create|add)
	shift
	create "$@"
	;;
    -h|--help|help)
	usage
	;;
    *)
	# unknown option, redirect to "create" by default
	create "$@"
	;;
esac
