#!/bin/bash

# exit script if return code != 0
set -e

# note do NOT download build scripts - inherited from int script with envvars common defined

# detect image arch
####

OS_ARCH=$(cat /etc/os-release | grep -P -o -m 1 "(?=^ID\=).*" | grep -P -o -m 1 "[a-z]+$")
if [[ ! -z "${OS_ARCH}" ]]; then
	if [[ "${OS_ARCH}" == "arch" ]]; then
		OS_ARCH="x86-64"
	else
		OS_ARCH="aarch64"
	fi
	echo "[info] OS_ARCH defined as '${OS_ARCH}'"
else
	echo "[warn] Unable to identify OS_ARCH, defaulting to 'x86-64'"
	OS_ARCH="x86-64"
fi

# pacman packages
####

# call pacman db and package updater script
source upd.sh

# define pacman packages
pacman_packages="libtorrent-rasterbar openssl python-chardet python-dbus python-distro python-geoip python-idna python-mako python-pillow python-pyopenssl python-rencode python-service-identity python-setproctitle python-six python-future python-requests python-twisted python-xdg python-zope-interface xdg-utils libappindicator-gtk3 patch deluge"

# install compiled packages using pacman
if [[ ! -z "${pacman_packages}" ]]; then
	pacman -S --needed $pacman_packages --noconfirm
fi

# aur packages
####

# define aur packages
aur_packages=""

# call aur install script (arch user repo)
source aur.sh

# tweaks
####

# create path to store deluge python eggs
mkdir -p /home/nobody/.cache/Python-Eggs

# remove permissions for group and other from the Python-Eggs folder
chmod -R 700 /home/nobody/.cache/Python-Eggs

# change peerid to appear to be 2.0.3 stable - note this does not work for all/any private trackers at present
sed -i -e "s~peer_id = substitute_chr(peer_id, 6, release_chr)~peer_id = \'--DE203s--\'\n        release_chr = \'s\'~g" /usr/lib/python3*/site-packages/deluge/core/core.py

# container perms
####

# define comma separated list of paths 
install_paths="/etc/privoxy,/home/nobody"

# split comma separated string into list for install paths
IFS=',' read -ra install_paths_list <<< "${install_paths}"

# process install paths in the list
for i in "${install_paths_list[@]}"; do

	# confirm path(s) exist, if not then exit
	if [[ ! -d "${i}" ]]; then
		echo "[crit] Path '${i}' does not exist, exiting build process..." ; exit 1
	fi

done

# convert comma separated string of install paths to space separated, required for chmod/chown processing
install_paths=$(echo "${install_paths}" | tr ',' ' ')

# set permissions for container during build - Do NOT double quote variable for install_paths otherwise this will wrap space separated paths as a single string
chmod -R 775 ${install_paths}

# set permissions for python eggs to be a more restrictive 755, this prevents the warning message thrown by deluge on startup
mkdir -p /home/nobody/.cache/Python-Eggs ; chmod -R 755 /home/nobody/.cache/Python-Eggs

# disable built-in Deluge Plugin 'stats', as its currently broken in Deluge 2.x and causes log spam
# see here for details https://dev.deluge-torrent.org/ticket/3310
chmod 000 /usr/lib/python3*/site-packages/deluge/plugins/Stats*.egg

# create file with contents of here doc, note EOF is NOT quoted to allow us to expand current variable 'install_paths'
# we use escaping to prevent variable expansion for PUID and PGID, as we want these expanded at runtime of init.sh
cat <<EOF > /tmp/permissions_heredoc

# get previous puid/pgid (if first run then will be empty string)
previous_puid=\$(cat "/root/puid" 2>/dev/null || true)
previous_pgid=\$(cat "/root/pgid" 2>/dev/null || true)

# if first run (no puid or pgid files in /tmp) or the PUID or PGID env vars are different 
# from the previous run then re-apply chown with current PUID and PGID values.
if [[ ! -f "/root/puid" || ! -f "/root/pgid" || "\${previous_puid}" != "\${PUID}" || "\${previous_pgid}" != "\${PGID}" ]]; then

	# set permissions inside container - Do NOT double quote variable for install_paths otherwise this will wrap space separated paths as a single string
	chown -R "\${PUID}":"\${PGID}" ${install_paths}

fi

# write out current PUID and PGID to files in /root (used to compare on next run)
echo "\${PUID}" > /root/puid
echo "\${PGID}" > /root/pgid

EOF

# replace permissions placeholder string with contents of file (here doc)
sed -i '/# PERMISSIONS_PLACEHOLDER/{
    s/# PERMISSIONS_PLACEHOLDER//g
    r /tmp/permissions_heredoc
}' /usr/local/bin/init.sh
rm /tmp/permissions_heredoc

# env vars
####

cat <<'EOF' > /tmp/envvars_heredoc

export DELUGE_DAEMON_LOG_LEVEL=$(echo "${DELUGE_DAEMON_LOG_LEVEL}" | sed -e 's~^[ \t]*~~;s~[ \t]*$~~')
if [[ ! -z "${DELUGE_DAEMON_LOG_LEVEL}" ]]; then
	echo "[info] DELUGE_DAEMON_LOG_LEVEL defined as '${DELUGE_DAEMON_LOG_LEVEL}'" | ts '%Y-%m-%d %H:%M:%.S'
else
	echo "[info] DELUGE_DAEMON_LOG_LEVEL not defined,(via -e DELUGE_DAEMON_LOG_LEVEL), defaulting to 'info'" | ts '%Y-%m-%d %H:%M:%.S'
	export DELUGE_DAEMON_LOG_LEVEL="info"
fi

export DELUGE_WEB_LOG_LEVEL=$(echo "${DELUGE_WEB_LOG_LEVEL}" | sed -e 's~^[ \t]*~~;s~[ \t]*$~~')
if [[ ! -z "${DELUGE_WEB_LOG_LEVEL}" ]]; then
	echo "[info] DELUGE_WEB_LOG_LEVEL defined as '${DELUGE_WEB_LOG_LEVEL}'" | ts '%Y-%m-%d %H:%M:%.S'
else
	echo "[info] DELUGE_WEB_LOG_LEVEL not defined,(via -e DELUGE_WEB_LOG_LEVEL), defaulting to 'info'" | ts '%Y-%m-%d %H:%M:%.S'
	export DELUGE_WEB_LOG_LEVEL="info"
fi

export DELUGE_WEB_AUTOLOGIN=$(echo "${DELUGE_WEB_AUTOLOGIN}" | sed -e 's~^[ \t]*~~;s~[ \t]*$~~')
if [[ ! -z "${DELUGE_WEB_AUTOLOGIN}" ]]; then
	echo "[info] DELUGE_WEB_AUTOLOGIN defined as '${DELUGE_WEB_AUTOLOGIN}'" | ts '%Y-%m-%d %H:%M:%.S'
else
	echo "[info] DELUGE_WEB_AUTOLOGIN not defined,(via -e DELUGE_WEB_AUTOLOGIN), defaulting to 'no'" | ts '%Y-%m-%d %H:%M:%.S'
	export DELUGE_WEB_AUTOLOGIN="no"
fi

export APPLICATION="deluge"

EOF

# replace env vars placeholder string with contents of file (here doc)
sed -i '/# ENVVARS_PLACEHOLDER/{
    s/# ENVVARS_PLACEHOLDER//g
    r /tmp/envvars_heredoc
}' /usr/local/bin/init.sh
rm /tmp/envvars_heredoc

# add hook for webui-autologin without affecting other other potential uses for the CONFIG_PLACEHOLDER
cat << 'EOF' > /tmp/webui-autologin_heredoc
# CONFIG_PLACEHOLDER

PATCH=$(cat <<'PATCH'
diff -Naur deluge-orig/ui/web/auth.py deluge/ui/web/auth.py
--- deluge-orig/ui/web/auth.py  2020-07-19 09:09:15.000000000 +0000
+++ deluge/ui/web/auth.py       2021-01-22 05:53:59.396212944 +0000
@@ -122,6 +122,7 @@
         return True

     def check_password(self, password):
+        return True
         config = self.config
         if 'pwd_sha1' not in config.config:
             log.debug('Failed to find config login details.')
diff -Naur deluge-orig/ui/web/js/deluge-all-debug.js deluge/ui/web/js/deluge-all-debug.js
--- deluge-orig/ui/web/js/deluge-all-debug.js   2020-07-19 09:09:15.000000000 +0000
+++ deluge/ui/web/js/deluge-all-debug.js        2021-01-22 05:50:44.149705748 +0000
@@ -7430,7 +7430,7 @@
     },

     onShow: function() {
-        this.passwordField.focus(true, 300);
+        this.onLogin();
     },
 });
 /**
PATCH
)

DELUGE_LIB_PATH=$(echo -e "import sys, os\nfor path in sys.path:\n  if os.path.exists(path + '/deluge') == True:\n    print(path)" | python)

# apply patch to bypass web ui login
if [[ ! -z "${DELUGE_WEB_AUTOLOGIN}" ]]; then
    if [[ ! -z "${DELUGE_LIB_PATH}" ]]; then
        if [ "${DELUGE_WEB_AUTOLOGIN}" != "no" ] && [ "${DELUGE_WEB_AUTOLOGIN}" != "No" ] && [ "${DELUGE_WEB_AUTOLOGIN}" != "NO" ]; then
            echo "[info] Patching deluge to disable login prompt" | ts '%Y-%m-%d %H:%M:%.S'
            echo "$PATCH" | patch -d$DELUGE_LIB_PATH/ -p0 -f -r - > /dev/null || true
        else
            echo "[info] Removing patch to disable login prompt" | ts '%Y-%m-%d %H:%M:%.S'
            echo "$PATCH" | patch -d$DELUGE_LIB_PATH/ -p0 -f -r - -R > /dev/null || true
        fi  
    else
        echo "[info] Unable to find deluge package, skipping DELUGE_WEB_AUTOLOGIN configuration." | ts '%Y-%m-%d %H:%M:%.S'
    fi
fi
EOF
sed -i '/# CONFIG_PLACEHOLDER/{
    s/# CONFIG_PLACEHOLDER//g
    r /tmp/webui-autologin_heredoc
}' /usr/local/bin/init.sh
rm /tmp/webui-autologin_heredoc

# cleanup
cleanup.sh
