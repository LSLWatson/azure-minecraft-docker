set -euo pipefail

public_ip=""
for attempt in $(seq 1 60); do
  public_ip=$(getent ahostsv4 "$SERVER_PUBLIC_HOSTNAME" | awk 'NR == 1 {print $1}') || public_ip=""
  if [[ -n "$public_ip" ]]; then
    break
  fi
  echo "Waiting for ACI public DNS: $SERVER_PUBLIC_HOSTNAME (attempt $attempt)" >&2
  sleep 2
done

if [[ -z "$public_ip" ]]; then
  echo "ERROR: cannot resolve ACI public address for NetherNet gameplay" >&2
  exit 1
fi

export SERVER_UDP_PORTS="$public_ip:$SERVER_UDP_PORT_START-$SERVER_UDP_PORT_END:$SERVER_UDP_PORT_START-$SERVER_UDP_PORT_END"
echo "NetherNet gameplay address: $SERVER_UDP_PORTS"
exec /opt/demoter-entry.sh
