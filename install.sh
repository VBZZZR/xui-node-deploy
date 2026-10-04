#!/usr/bin/env bash
# Download the reviewed installer from your public GitHub repository.
set -Eeuo pipefail
umask 077

repo="${1:-}"
mode="${2:-run}"
[[ "$repo" =~ ^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || {
    printf 'Использование: bash install.sh USER/REPOSITORY [--download-only]\n' >&2
    exit 2
}
[[ "$mode" == run || "$mode" == --download-only ]] || exit 2
command -v curl >/dev/null || { printf 'Установите curl: sudo apt-get update && sudo apt-get install -y curl ca-certificates\n' >&2; exit 2; }
readonly EXPECTED_SCRIPT_SHA256='ed8c7f96c8080a8b99f685d279c3493b23c705e264deac521f2fc18564744658'
readonly base="https://raw.githubusercontent.com/${repo}/main"
readonly target_dir="${XUI_INSTALL_DIR:-$HOME/xui-node-deploy}"
[[ ! -L "$target_dir" ]] || { printf 'Каталог установки не должен быть символической ссылкой.\n' >&2; exit 2; }
mkdir -p -- "$target_dir"
tmp=$(mktemp -d "$target_dir/.download.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT
curl_args=(--disable --silent --show-error --location --proto '=https' --proto-redir '=https' --connect-timeout 15 --max-time 120 --retry 2)

curl "${curl_args[@]}" --fail "$base/xui-node-docker.sh" --output "$tmp/xui-node-docker.sh"
printf '%s  %s\n' "$EXPECTED_SCRIPT_SHA256" "$tmp/xui-node-docker.sh" | sha256sum --check --status || {
    printf 'SHA-256 установщика не совпал; запуск отменён. Возьмите актуальную команду из проверенного README.\n' >&2
    exit 1
}
bash -n "$tmp/xui-node-docker.sh"

# The exported image lock contains only a digest and version/checksum fields.
# 404 means a first installation without a shared lock; other errors stop.
http_code=$(curl "${curl_args[@]}" "$base/xui-docker-image.lock.json" --output "$tmp/xui-docker-image.lock.json" --write-out '%{http_code}')
case "$http_code" in
    200) ;;
    404) rm -- "$tmp/xui-docker-image.lock.json"
         printf 'Общий image-lock в репозитории отсутствует: первый запуск закрепит доступный официальный образ.\n' ;;
    *) printf 'Не удалось получить image-lock: HTTP %s. Запуск отменён.\n' "$http_code" >&2; exit 1 ;;
esac

for name in xui-node-docker.sh xui-docker-image.lock.json; do
    [[ -f "$tmp/$name" ]] || continue
    [[ ! -L "$target_dir/$name" ]] || { printf 'Недопустимая символическая ссылка: %s\n' "$target_dir/$name" >&2; exit 2; }
    if [[ -e "$target_dir/$name" ]] && ! cmp -s -- "$tmp/$name" "$target_dir/$name"; then
        cp -p -- "$target_dir/$name" "$target_dir/$name.bak.$(date -u +%Y%m%dT%H%M%S%N)"
    fi
    chmod 0600 "$tmp/$name"
    [[ "$name" != xui-node-docker.sh ]] || chmod 0700 "$tmp/$name"
    mv -f -- "$tmp/$name" "$target_dir/$name"
done
printf 'Установщик проверен и сохранён: %s/xui-node-docker.sh\n' "$target_dir"
printf 'После перезагрузки продолжайте: sudo bash %q\n' "$target_dir/xui-node-docker.sh"
rm -rf -- "$tmp"
trap - EXIT
[[ "$mode" != --download-only ]] || exit 0
if (( EUID == 0 )); then
    exec bash "$target_dir/xui-node-docker.sh"
else
    exec sudo bash "$target_dir/xui-node-docker.sh"
fi
