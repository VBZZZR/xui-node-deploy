# Установка нового узла

## 1. Подготовьте VPS

- Чистая Ubuntu 24.04 x86_64.
- A-запись нового домена указывает на IPv4 VPS; ошибочной AAAA-записи нет.
- Имя узла и домен свободны в основной панели.
- В firewall провайдера разрешены действующий SSH-порт, `80/tcp` и `443/tcp`. Порт панели откройте, когда установщик его покажет.

## 2. Создайте GitHub-токен для загрузки

Откройте [создание fine-grained токена](https://github.com/settings/personal-access-tokens/new) и выберите:

- **Token name — имя:** `xui-deploy-read`.
- **Expiration — срок:** 30 дней.
- **Resource owner — владелец:** `VBZZZR`.
- **Repository access — доступ:** `Only select repositories` → `xui-node-deploy`.
- **Repository permissions — права:** `Contents` → `Read-only`.

Нажмите **Generate token — создать токен**. Сохраните его в менеджере паролей: он потребуется в шаге 4 и на следующих VPS до истечения срока.

## 3. Войдите на VPS

**PowerShell на Windows:**

```powershell
$ServerIp = (Read-Host "IPv4 VPS").Trim()
$SshPort = (Read-Host "Порт SSH; Enter для 22").Trim()
if (-not $SshPort) { $SshPort = "22" }
ssh.exe -p "$SshPort" "root@$ServerIp"
```

Для первого подключения сверьте отпечаток ключа сервера через консоль провайдера. В ней выполните:

```bash
ssh-keygen -E sha256 -lf /etc/ssh/ssh_host_ed25519_key.pub
```

## 4. Запустите установку

**SSH-терминал VPS под root — весь блок целиком:**

```bash
(
    set +x
    set +a
    set -euo pipefail
    umask 077
    (( EUID == 0 )) || { printf 'Сначала выполните sudo -i.\n' >&2; exit 1; }

    if ! command -v curl >/dev/null 2>&1; then
        apt-get update
        apt-get install -y curl ca-certificates
    fi

    bootstrap=$(mktemp /tmp/xui-bootstrap.XXXXXX)
    trap 'unset github_read_token; exec 3<&-; rm -f -- "$bootstrap"' EXIT
    unset github_read_token
    IFS= read -r -s -p 'GitHub-токен из шага 2: ' github_read_token
    printf '\n'
    [[ "$github_read_token" =~ ^[A-Za-z0-9_]+$ ]] || { printf 'Некорректный токен.\n' >&2; exit 1; }

    curl --disable --fail --silent --show-error --location \
        --proto '=https' --proto-redir '=https' \
        --connect-timeout 15 --max-time 120 --retry 2 \
        --header 'Accept: application/vnd.github.raw+json' \
        --header 'X-GitHub-Api-Version: 2026-03-10' \
        --header @/dev/fd/3 \
        'https://api.github.com/repos/VBZZZR/xui-node-deploy/contents/install.sh?ref=main' \
        --output "$bootstrap" \
        3< <(printf 'Authorization: Bearer %s\n' "$github_read_token")

    printf '%s  %s\n' \
        'a72fd171e338831204262947ade6fb829d5027bd028acf2ae3512a1c68117d14' \
        "$bootstrap" | sha256sum --check --status

    exec 3< <(printf '%s\n' "$github_read_token")
    unset github_read_token
    bash "$bootstrap" VBZZZR/xui-node-deploy
)
```

## 5. Ответьте на запросы установщика

| Запрос | Что сделать |
|---|---|
| Домен, страна, короткое имя узла | Введите параметры нового VPS, например код страны `US` и имя `US1` |
| Порт панели и внешний firewall | Разрешите показанный порт панели у провайдера; введите `ОТКРЫТО` |
| Второй вход по SSH | Откройте другое окно PowerShell, повторите блок шага 3; при успешном входе в установщике введите `SSH-OK` |
| Email для сертификата | Введите свой email |
| QR-код / VLESS-ссылка | Добавьте тестовый профиль в Happ на Windows, проверьте сайты и внешний IPv4 |
| Успешный тест Happ | Введите `1`, нажмите Enter, затем укажите внешний IPv4, показанный через VPN |
| Неуспешный тест Happ | Введите `2`; исправьте ошибку и продолжите командой ниже |
| Адрес основной панели | Введите полный HTTPS URL с портом и basePath |
| API-токен основной панели | Введите временный токен основной панели с областью `admin` |

Когда тестовый клиент будет отключён, отключите его профиль / VPN в Happ.

Если установщик требует перезагрузку, выполните на VPS:

```bash
sudo reboot
```

После перезагрузки повторите SSH-вход из шага 3. **На том же VPS** продолжите:

```bash
sudo bash /root/xui-node-deploy/xui-node-docker.sh
```

## 6. Проверьте результат

**SSH-терминал VPS:**

```bash
sudo bash /root/xui-node-deploy/xui-node-docker.sh --status
sudo bash /root/xui-node-deploy/xui-node-docker.sh --validate
sudo ufw status verbose
sudo ss -lntp
```

Ожидаются `registered: yes`, `client_test_verified: yes`, `bootstrap_cleanup_verified: yes`, `image_pin: OK`, работающий контейнер, TCP/443 и отключённый тестовый клиент (`enable=0`).

**В другом окне PowerShell — внешняя проверка портов:**

```powershell
$ServerIp = (Read-Host "IPv4 VPS").Trim()
$SshPort = [int](Read-Host "Действующий порт SSH")
$PanelPort = [int](Read-Host "Порт панели из установщика")
foreach ($Port in @($SshPort, 443, $PanelPort) | Select-Object -Unique) {
    Test-NetConnection -ComputerName $ServerIp -Port $Port |
        Select-Object ComputerName, RemotePort, TcpTestSucceeded
}
```

Для этих портов ожидается `TcpTestSucceeded: True`. TCP/80 проверяется во время получения сертификата; после завершения на нём может не быть слушателя.

В основной панели проверьте статус узла `online` и отзовите только временный токен установки, например `deploy-US1`.

Если установка остановилась, **на VPS** выполните:

```bash
sudo bash /root/xui-node-deploy/xui-node-docker.sh --diagnose
```

Для следующего VPS повторите шаги 1 и 3–6; действующий GitHub-токен из шага 2 можно использовать повторно.
