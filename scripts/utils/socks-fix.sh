#!/system/bin/sh
#############################################################################
# SOCKS base64 credential fix
#
# proxylink does not decode the v2rayN style link
#   socks://base64(user:pass)@host:port#name
# and writes the base64 string as the username with an empty password.
#
# Usage:
#   socks-fix.sh link <node-link>   print the link with plain user:pass
#   socks-fix.sh json <file>...     fix already generated outbound files
#############################################################################

# Decode base64 / base64url (with or without padding). Prints nothing on failure.
b64_decode() {
  local s pad
  s=$(printf '%s' "$1" | sed 's/%3[dD]/=/g' | tr '_-' '/+' | tr -d '=')
  case $((${#s} % 4)) in
    2) pad="==" ;;
    3) pad="=" ;;
    1) return 1 ;;
    *) pad="" ;;
  esac
  printf '%s%s' "$s" "$pad" | base64 -d 2> /dev/null
}

url_encode() {
  printf '%s' "$1" | sed 's/%/%25/g; s/@/%40/g; s/\//%2F/g; s/#/%23/g; s/?/%3F/g; s/:/%3A/g'
}

# Rewrite socks://base64@host to socks://user:pass@host (other links unchanged)
fix_link() {
  local link="$1" rest userinfo after dec user pass
  # socks5:// and socks5h:// are the same as socks:// (Xray only speaks SOCKS5)
  case "$link" in
    socks5h://*) link="socks://${link#socks5h://}" ;;
    socks5://*) link="socks://${link#socks5://}" ;;
  esac
  case "$link" in
    socks://*) ;;
    *)
      printf '%s' "$link"
      return 0
      ;;
  esac
  rest="${link#socks://}"
  case "$rest" in
    *@*) ;;
    *)
      # Provider style: socks://host:port:user:pass[#name]
      local frag="" body="$rest" host r port cred
      case "$rest" in
        *'#'*)
          frag="#${rest#*#}"
          body="${rest%%#*}"
          ;;
      esac
      host="${body%%:*}"
      r="${body#*:}"
      port="${r%%:*}"
      case "$r" in
        *:*) cred="${r#*:}" ;;
        *) cred="" ;;
      esac
      user="${cred%%:*}"
      case "$cred" in
        *:*) pass="${cred#*:}" ;;
        *) pass="" ;;
      esac
      case "$port" in '' | *[!0-9]*) port="" ;; esac
      case "$host" in '' | '['*) host="" ;; esac
      if [ -n "$host" ] && [ -n "$port" ] && [ -n "$user" ] && [ -n "$pass" ]; then
        printf 'socks://%s:%s@%s:%s%s' "$(url_encode "$user")" "$(url_encode "$pass")" "$host" "$port" "$frag"
      else
        printf '%s' "$link"
      fi
      return 0
      ;;
  esac
  userinfo="${rest%%@*}"
  after="${rest#*@}"
  # Already plain (user:pass or contains percent-encoding of a colon)
  case "$userinfo" in
    *:* | *%3[aA]*)
      printf '%s' "$link"
      return 0
      ;;
  esac
  dec=$(b64_decode "$userinfo") || dec=""
  case "$dec" in
    *:*)
      user="${dec%%:*}"
      pass="${dec#*:}"
      printf 'socks://%s:%s@%s' "$(url_encode "$user")" "$(url_encode "$pass")" "$after"
      ;;
    *) printf '%s' "$link" ;;
  esac
}

# Fix one generated outbound file in place
fix_json_file() {
  local file="$1" tmp="$1.fixtmp" held="" line user_b64 dec user pass indent changed=0
  [ -f "$file" ] || return 0
  : > "$tmp"
  while IFS= read -r line || [ -n "$line" ]; do
    if [ -n "$held" ]; then
      # $held is a "user" line; $line should be the "pass" line
      case "$line" in
        *'"pass"'*'""'*)
          user_b64=$(printf '%s' "$held" | sed -n 's/.*"user"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
          dec=$(b64_decode "$user_b64") || dec=""
          case "$dec" in
            *:*)
              user="${dec%%:*}"
              pass="${dec#*:}"
              # JSON-escape backslash and double quote
              user=$(printf '%s' "$user" | sed 's/\\/\\\\/g; s/"/\\"/g')
              pass=$(printf '%s' "$pass" | sed 's/\\/\\\\/g; s/"/\\"/g')
              printf '%s\n' "$held" | sed "s|\"user\"\([[:space:]]*\):\([[:space:]]*\)\"[^\"]*\"|\"user\"\1:\2\"$(printf '%s' "$user" | sed 's/[|&\\]/\\&/g')\"|" >> "$tmp"
              printf '%s\n' "$line" | sed "s|\"pass\"\([[:space:]]*\):\([[:space:]]*\)\"\"|\"pass\"\1:\2\"$(printf '%s' "$pass" | sed 's/[|&\\]/\\&/g')\"|" >> "$tmp"
              changed=1
              held=""
              continue
              ;;
          esac
          ;;
      esac
      printf '%s\n' "$held" >> "$tmp"
      held=""
    fi
    case "$line" in
      *'"user"'*:*'"'*) held="$line" ;;
      *) printf '%s\n' "$line" >> "$tmp" ;;
    esac
  done < "$file"
  [ -n "$held" ] && printf '%s\n' "$held" >> "$tmp"

  if [ "$changed" = 1 ]; then
    mv "$tmp" "$file"
    echo "Fixed SOCKS credentials: $(basename "$file")"
  else
    rm -f "$tmp"
  fi
}

case "${1:-}" in
  link)
    fix_link "${2:-}"
    ;;
  json)
    shift
    for f in "$@"; do fix_json_file "$f"; done
    ;;
  *)
    echo "Usage: $0 link <node-link> | json <file>..."
    exit 1
    ;;
esac
