generate_key() (
    set -euo pipefail
    key=$1
    algorithm=$2
    bits=$3
    public="$key.pub"

    if [ -L "$key" ] || [ -L "$public" ]; then
        echo "Refusing symlink SSH key: $key" >&2
        exit 1
    fi
    mkdir -p -m 0700 "$(dirname "$key")"
    tmp=$(mktemp -d "$(dirname "$key")/.alloy-ssh-key.XXXXXXXX")
    trap 'rm -rf "$tmp"' EXIT

    if [ ! -e "$key" ]; then
        if [ -e "$public" ]; then
            echo "Private SSH key missing but public key exists: $key" >&2
            exit 1
        fi
        args=(-q -t "$algorithm" -N "" -C "" -f "$tmp/key")
        if [ -n "$bits" ]; then args+=(-b "$bits"); fi
        ssh-keygen "${args[@]}"
        mv -T "$tmp/key" "$key"
    fi

    test -f "$key"
    ssh-keygen -y -P "" -f "$key" > "$tmp/public"
    read -r actual_algorithm data _ < "$tmp/public"
    if [ "$actual_algorithm" != "ssh-$algorithm" ]; then
        echo "SSH key algorithm differs from declaration: $key" >&2
        exit 1
    fi
    if [ -n "$bits" ]; then
        fingerprint=$(ssh-keygen -lf "$tmp/public")
        read -r actual_bits _ <<< "$fingerprint"
        if [ "$actual_bits" != "$bits" ]; then
            echo "SSH key size differs from declaration: $key" >&2
            exit 1
        fi
    fi
    if [ -e "$public" ]; then
        test -f "$public"
        read -r public_algorithm public_data _ < "$public"
        if [ "$public_algorithm $public_data" != "$actual_algorithm $data" ]; then
            echo "SSH public key does not match private key: $key" >&2
            exit 1
        fi
    else
        mv -T "$tmp/public" "$public"
    fi
    chown root:root "$key" "$public"
    chmod 0600 "$key"
    chmod 0644 "$public"
)
