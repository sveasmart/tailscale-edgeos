#!/bin/sh

set -e

if grep -q '^mozilla/DST_Root_CA_X3\.crt$' /etc/ca-certificates.conf; then
	sed -i 's|^mozilla\/DST_Root_CA_X3\.crt|!mozilla/DST_Root_CA_X3.crt|' /etc/ca-certificates.conf
	update-ca-certificates --fresh
fi

mkdir -p /config/tailscale/systemd/tailscaled.service.d
install -d -m 0700 /config/tailscale/state

# Older versions cached the package in /config, which can make EdgeOS backups
# too large for an ER-X. Remove only Tailscale packages managed by this script.
for cached_package in /config/data/firstboot/install-packages/tailscale_*.deb; do
	if [ -e "$cached_package" ]; then
		rm -f -- "$cached_package"
	fi
done

# Create a bind mount for the Tailscale state directory
cat > /config/tailscale/systemd/var-lib-tailscale.mount.new <<-EOF
[Mount]
What=/config/tailscale/state
Where=/var/lib/tailscale
Type=none
Options=bind

[Install]
WantedBy=multi-user.target
	EOF
mv /config/tailscale/systemd/var-lib-tailscale.mount.new /config/tailscale/systemd/var-lib-tailscale.mount

# Add an override to tailscaled.service to require the bind mount
cat > /config/tailscale/systemd/tailscaled.service.d/mount.conf.new <<-EOF
[Unit]
RequiresMountsFor=/var/lib/tailscale
	EOF
mv /config/tailscale/systemd/tailscaled.service.d/mount.conf.new /config/tailscale/systemd/tailscaled.service.d/mount.conf

# Add an override to tailscaled.service to wait until "UBNT Routing Daemons"
# has finished, otherwise tailscaled won't have proper networking
cat > /config/tailscale/systemd/tailscaled.service.d/wait-for-networking.conf.new <<-EOF
[Unit]
Wants=vyatta-router.service
After=vyatta-router.service
	EOF
mv /config/tailscale/systemd/tailscaled.service.d/wait-for-networking.conf.new /config/tailscale/systemd/tailscaled.service.d/wait-for-networking.conf

if [ ! -L /etc/systemd/system/tailscaled.service.d ]; then
	ln -s /config/tailscale/systemd/tailscaled.service.d /etc/systemd/system/tailscaled.service.d
fi
systemctl daemon-reload

# Install the managed post-config script. Always replace it so fixes in this
# firstboot script reach routers that already have an older generated copy.
mkdir -p /config/scripts/post-config.d
cat > /config/scripts/post-config.d/tailscale.sh.new <<"EOF"
#!/bin/sh

set -e

reload=""

# The mount unit needs to be copied rather than linked.
# systemd errors with "Link has been severed" if the unit is a symlink.
if ! cmp -s /config/tailscale/systemd/var-lib-tailscale.mount /etc/systemd/system/var-lib-tailscale.mount; then
	echo Installing /var/lib/tailscale mount unit
	install -m 0644 /config/tailscale/systemd/var-lib-tailscale.mount /etc/systemd/system/var-lib-tailscale.mount
	reload=y
fi

if [ ! -L /etc/systemd/system/tailscaled.service.d ]; then
	ln -s /config/tailscale/systemd/tailscaled.service.d /etc/systemd/system/tailscaled.service.d
	reload=y
fi

if [ -n "$reload" ]; then
	# Ensure systemd has loaded the unit overrides
	systemctl daemon-reload
fi

keyring=/usr/share/keyrings/tailscale-stretch-stable.gpg

if ! gpg --list-keys --with-colons --no-default-keyring --keyring "$keyring" 2>/dev/null | grep -qF info@tailscale.com; then
	echo Installing Tailscale repository signing key
	key_asc=$(mktemp)
	key_gpg=$(mktemp)
	trap 'rm -f "$key_asc" "$key_gpg"' 0 1 2 15
	curl -fsSL -o "$key_asc" https://pkgs.tailscale.com/stable/debian/stretch.asc
	gpg --dearmor < "$key_asc" > "$key_gpg"
	install -m 0644 "$key_gpg" "$keyring"
	rm -f "$key_asc" "$key_gpg"
	trap - 0 1 2 15
fi

pkg_status=$(dpkg-query -Wf '${Status}' tailscale 2>/dev/null || true)
if ! printf '%s\n' "$pkg_status" | grep -qF "install ok installed"; then
	# Sometimes after a firmware upgrade the package goes into half-configured state
	if printf '%s\n' "$pkg_status" | grep -qF "half-configured"; then
		# Use systemd-run to configure the package in a separate unit, otherwise it will block
		# due to tailscaled.service waiting on vyatta-router.service, which is running this script.
		systemd-run --no-block dpkg --configure -a
	else
		echo "Installing Tailscale"
		trap 'apt-get clean' 0
		apt-get update
		DEBIAN_FRONTEND=noninteractive apt-get install --yes --no-install-recommends tailscale
		apt-get clean
		trap - 0
	fi
fi

if [ -n "$reload" ]; then
	systemctl --no-block restart tailscaled
fi
EOF
chmod 755 /config/scripts/post-config.d/tailscale.sh.new
mv /config/scripts/post-config.d/tailscale.sh.new /config/scripts/post-config.d/tailscale.sh
