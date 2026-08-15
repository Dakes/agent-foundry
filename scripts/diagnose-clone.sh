#!/usr/bin/env bash
# Run on the SERVER, in the foundry checkout. Read-only: changes nothing.
BOX=foundry-parliament
HOST=git.dakes.de

echo "=== 1. what the host resolves $HOST to"
getent hosts "$HOST" || echo "  host cannot resolve it either"

echo
echo "=== 2. does ANY dns work inside the sandbox?"
sbx exec "$BOX" sh -c 'getent hosts github.com >/dev/null 2>&1 && echo "  github.com: OK" || echo "  github.com: FAILS  <-- all DNS is broken, not just this host"'

echo
echo "=== 3. this host, inside the sandbox"
sbx exec "$BOX" sh -c "getent hosts $HOST || echo '  FAILS'"

echo
echo "=== 4. rules that exist for it"
sbx policy ls "$BOX" --json 2>/dev/null \
  | jq -r '.rules[] | select(.resources[]? | test("dakes")) | "  \(.decision) \(.resources|join(",")) scope=\(.scope)"' \
  || echo "  none"

echo
echo "=== 5. what policy says"
sbx policy check network --sandbox "$BOX" "$HOST"       2>&1 | head -2
sbx policy check network --sandbox "$BOX" "$HOST:2222"  2>&1 | head -2

echo
echo "=== 6. is the forge on a private address? (the deny that would bite)"
ip=$(getent hosts "$HOST" | awk '{print $1}' | head -1)
echo "  $HOST -> ${ip:-<unresolved>}"
case "$ip" in
  10.*|192.168.*|127.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*)
      echo "  PRIVATE -> Foundry's baseline denies this range on purpose." ;;
  "") echo "  unresolved on the host itself" ;;
  *)  echo "  public" ;;
esac
