#!/bin/sh
set -eu
test -f /.dockerenv || { echo "Disposable Docker fixture only" >&2; exit 1; }
mkdir -p /run/sshd /etc/tmux-link
chown root:root /etc/tmux-link/phone.keys
chmod 644 /etc/tmux-link/phone.keys
useradd -m -s /bin/sh alice
useradd -m -s /bin/sh tmuxrelay
# Unlock key-only test accounts with unusable password hashes.
usermod -p '*' alice
usermod -p '*' tmuxrelay
install -m700 -d -o tmuxrelay /home/tmuxrelay/link /home/tmuxrelay/.ssh
ssh-keygen -q -t ed25519 -N '' -f /etc/tmux-link/host_ed25519
link=$(agent import-link --center center.example.com --route linux --name 'Build + Linux' --user alice)
pin=$(ssh-keygen -E sha256 -lf /etc/tmux-link/host_ed25519.pub | awk '{print $2}' | sed 's/:/%3A/g; s|/|%2F|g; s/+/%2B/g')
test "$link" = "tmuxlink://client?host=center.example.com&port=443&route=linux&user=alice&pin=$pin&name=Build%20%2B%20Linux&requireMTLS=true"
ssh-keygen -q -t ed25519 -N '' -f /tmp/outer
cp /tmp/outer.pub /home/tmuxrelay/.ssh/authorized_keys
chown tmuxrelay:tmuxrelay /home/tmuxrelay/.ssh/authorized_keys
cat >/tmp/outer.conf <<CONF
Port 2202
ListenAddress 127.0.0.1
HostKey /etc/ssh/ssh_host_ed25519_key
PidFile /tmp/outer.pid
AllowUsers tmuxrelay
CONF
cat /tmp/center-match >> /tmp/outer.conf
/usr/sbin/sshd -f /tmp/outer.conf -E /tmp/outer.log
# Phones do not forward a locale. Exercise the agent in an ASCII SSH environment.
echo 'SetEnv LC_ALL=C' >> /etc/tmux-link/inner-sshd.conf
# Only the sizing test uses this target. Sample the SSH PTY before any tmux
# client can resize it, then let the test request a second sample after rotation.
cat > /tmp/fixture-attach <<'SH'
#!/bin/sh
if [ "${SSH_ORIGINAL_COMMAND:-}" = "tmux-link-attach 90027" ]; then
    printf 'initial-grid %s\n' "$(stty size)"
    while IFS= read -r _line; do printf 'current-grid %s\n' "$(stty size)"; done
    exit 0
fi
exec /usr/local/bin/tmux-link-agent attach
SH
chmod 755 /tmp/fixture-attach
sed -i 's|^ForceCommand .*|ForceCommand /tmp/fixture-attach|' /etc/tmux-link/inner-sshd.conf
/usr/sbin/sshd -f /etc/tmux-link/inner-sshd.conf -E /tmp/inner.log
install -d -m700 /root/.ssh
{ printf '[127.0.0.1]:2202 '; cat /etc/ssh/ssh_host_ed25519_key.pub; } >> /root/.ssh/known_hosts
cat >/root/.ssh/config <<CONF
Host test-relay
 HostName 127.0.0.1
 Port 2202
 User tmuxrelay
 IdentityFile /tmp/outer
 IdentitiesOnly yes
CONF
su alice -c 'tmux -f /dev/null new-session -d -s tl-live'
su alice -c 'tmux -u new-session -d -s "zz-中文🙂" "echo pane-左🙂右; exec sleep infinity"'
su alice -c 'tmux new-session -d -s tl-scroll'
su alice -c 'tmux set-option -t tl-scroll prefix C-a'
su alice -c 'tmux set-option -t tl-scroll mouse off'
agent tunnel test-relay /home/tmuxrelay/link/linux.sock 2201 >/tmp/tunnel.log 2>&1 &
su tmuxrelay -c 'exec /usr/local/bin/center 0.0.0.0:2222 /home/tmuxrelay/link/linux.sock' >/tmp/center.log 2>&1 &
su tmuxrelay -c 'exec /usr/local/bin/center 0.0.0.0:2223 /home/tmuxrelay/link/linux.sock --websocket' >/tmp/websocket.log 2>&1 &
