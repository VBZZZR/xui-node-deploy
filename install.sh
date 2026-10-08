#!/usr/bin/env bash
# Download pinned deployment files from a private GitHub repository.
set +x
set +a
set -Eeuo pipefail
umask 077

repo="${1:-}"
mode="${2:-run}"
[[ "$repo" =~ ^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || {
    printf 'Использование: bash install.sh USER/REPOSITORY [--download-only]\n' >&2
    exit 2
}
[[ "$mode" == run || "$mode" == --download-only ]] || exit 2
command -v curl >/dev/null || {
    printf 'Установите curl: sudo apt-get update && sudo apt-get install -y curl ca-certificates\n' >&2
    exit 2
}

readonly EXPECTED_SCRIPT_SHA256='03f068ccc260573ec0532b4dfaaf1dc89408448d1bcf52b4519d515b5aef1e28'
readonly EXPECTED_IMAGE_LOCK_SHA256='04c7471a08525fdd1c4679f89150a802c6160285794819b3e7798bd6de1587b0'
readonly base="https://api.github.com/repos/${repo}/contents"
readonly target_dir="${XUI_INSTALL_DIR:-$HOME/xui-node-deploy}"
unset github_read_token
github_read_token=''
tmp=''

cleanup() {
    unset github_read_token
    exec 3<&-
    [[ -z "$tmp" ]] || rm -rf -- "$tmp"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if { true <&3; } 2>/dev/null; then
    IFS= read -r github_read_token <&3 || {
        printf 'Не удалось прочитать GitHub-токен.\n' >&2
        exit 2
    }
    exec 3<&-
elif [[ -t 0 ]]; then
    IFS= read -r -s -p 'GitHub-токен для чтения репозитория: ' github_read_token
    printf '\n'
else
    printf 'Нужен интерактивный ввод GitHub-токена или передача через дескриптор 3.\n' >&2
    exit 2
fi
[[ "$github_read_token" =~ ^[A-Za-z0-9_]+$ ]] || {
    printf 'GitHub-токен пуст или содержит недопустимые символы.\n' >&2
    exit 2
}

[[ ! -L "$target_dir" ]] || {
    printf 'Каталог установки не должен быть символической ссылкой.\n' >&2
    exit 2
}
mkdir -p -- "$target_dir"
tmp=$(mktemp -d "$target_dir/.download.XXXXXX")
curl_args=(--disable --fail --silent --show-error --location
    --proto '=https' --proto-redir '=https'
    --connect-timeout 15 --max-time 120 --retry 2
    --header 'Accept: application/vnd.github.raw+json'
    --header 'X-GitHub-Api-Version: 2026-03-10')

download() {
    local name="$1"
    curl "${curl_args[@]}" --header @/dev/fd/3 \
        "$base/$name?ref=main" --output "$tmp/$name" \
        3< <(printf 'Authorization: Bearer %s\n' "$github_read_token") || {
        printf 'Не удалось скачать %s. Проверьте срок GitHub-токена, выбранный репозиторий и разрешение Contents: Read-only.\n' "$name" >&2
        return 1
    }
}

download xui-node-docker.sh
printf '%s  %s\n' "$EXPECTED_SCRIPT_SHA256" "$tmp/xui-node-docker.sh" | sha256sum --check --status || {
    printf 'SHA-256 установщика не совпал. Запуск отменён.\n' >&2
    exit 1
}
bash -n "$tmp/xui-node-docker.sh"

download xui-docker-image.lock.json
printf '%s  %s\n' "$EXPECTED_IMAGE_LOCK_SHA256" "$tmp/xui-docker-image.lock.json" | sha256sum --check --status || {
    printf 'SHA-256 image-lock не совпал. Запуск отменён.\n' >&2
    exit 1
}
unset github_read_token

for name in xui-node-docker.sh xui-docker-image.lock.json; do
    [[ ! -L "$target_dir/$name" ]] || {
        printf 'Недопустимая символическая ссылка: %s\n' "$target_dir/$name" >&2
        exit 2
    }
    [[ ! -e "$target_dir/$name" || -f "$target_dir/$name" ]] || {
        printf 'Вместо файла обнаружен другой объект: %s\n' "$target_dir/$name" >&2
        exit 2
    }
done
for name in xui-node-docker.sh xui-docker-image.lock.json; do
    if [[ -e "$target_dir/$name" ]] && ! cmp -s -- "$tmp/$name" "$target_dir/$name"; then
        cp -p -- "$target_dir/$name" "$target_dir/$name.bak.$(date -u +%Y%m%dT%H%M%S%N)"
    fi
    chmod 0600 "$tmp/$name"
    [[ "$name" != xui-node-docker.sh ]] || chmod 0700 "$tmp/$name"
    mv -f -- "$tmp/$name" "$target_dir/$name"
done
printf 'Файлы проверены и сохранены.\n'
printf 'Продолжение после перезагрузки: sudo bash %q\n' "$target_dir/xui-node-docker.sh"
cleanup
trap - EXIT INT TERM
[[ "$mode" != --download-only ]] || exit 0
if (( EUID == 0 )); then
    exec bash "$target_dir/xui-node-docker.sh"
else
    exec sudo bash "$target_dir/xui-node-docker.sh"
fi
