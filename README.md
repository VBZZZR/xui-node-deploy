# Установка нового узла

Шаблон новых узлов: VLESS/TCP/443 + REALITY, Google, fingerprint `firefox`, sniffing `http`, `tls`, `fakedns`. Имя inbound — флаг и имя нового узла; тег синхронизации — `in-443-tcp`. Ключи, UUID, shortId и spiderX создаются заново. Поля `minClientVer/maxClientVer` отсутствуют. Дополнительные `testseed` и ML-DSA выключены: экспорт LV1 скрыл их исходные значения. Обновление шаблона применяется при создании inbound на новом VPS.

## 1. Подготовьте VPS

- Чистая Ubuntu 24.04 x86_64.
- A-запись нового домена указывает на IPv4 VPS; ошибочной AAAA-записи нет.
- Имя узла и домен свободны в основной панели.
- В firewall провайдера разрешены действующий SSH-порт, `80/tcp` и `443/tcp`. Порт панели откройте, когда установщик его покажет.

### 1.1. Проверьте ключ сервера

Откройте **консоль VPS на сайте провайдера**, войдите под `root` и выполните:

```bash
ssh-keygen -E sha256 -lf /etc/ssh/ssh_host_ed25519_key.pub
```

Сохраните показанный отпечаток `SHA256:...`. При первом подключении Windows спросит о доверии ключу сервера: вводите `yes` только при совпадении отпечатка. Если появится `REMOTE HOST IDENTIFICATION HAS CHANGED`, остановитесь и сверьте ключ через консоль провайдера; блок сам не удаляет записи `known_hosts`.

#### Если появилась ошибка `REMOTE HOST IDENTIFICATION HAS CHANGED`

Она означает, что ключ сервера отличается от сохранённого на Windows. Это может произойти после переустановки или отката VPS; SSH останавливает подключение до запроса пароля.

Сначала выполните команду проверки отпечатка выше **в консоли провайдера** и сравните результат с отпечатком в сообщении SSH. **Только при совпадении** выполните следующий блок: он сохранит резервную копию `known_hosts` и удалит старую запись указанного сервера.

**PowerShell на Windows — весь блок:**

```powershell
& {
    $ErrorActionPreference = "Stop"
    $KnownHosts = Join-Path $env:USERPROFILE ".ssh\known_hosts"
    $Backup = "$KnownHosts.bak.$(Get-Date -Format 'yyyyMMdd-HHmmssfff')"

    Copy-Item -LiteralPath $KnownHosts -Destination $Backup
    Write-Host "Резервная копия: $Backup"

    ssh-keygen.exe -R "138.124.68.176" -f "$KnownHosts"
    if ($LASTEXITCODE -ne 0) { throw "Удаление старой записи не завершено." }
}
```

В блоке указан IPv4 US1 и предполагается SSH-порт `22`. Для другого VPS замените `138.124.68.176` на его IPv4. При другом SSH-порте вместо IP укажите запись вида `[138.124.68.176]:2222`, подставив свой IP и порт.

После исправления повторите подключение из шага 1.2. SSH снова спросит о доверии ключу: сверьте подтверждённый отпечаток, введите `yes`, затем пароль `root`. Если отпечатки не совпадают, сохранённую запись не удаляйте и уточните причину у провайдера.

### 1.2. Войдите по паролю и установите свой публичный ключ

Нужны пароль `root` от провайдера и уже созданная пара SSH-ключей на Windows: приватный файл, например `id_ed25519`, и публичный `id_ed25519.pub`.

**PowerShell на Windows — копируйте весь блок:**

```powershell
& {
    $ErrorActionPreference = "Stop"
    Get-Command ssh.exe, ssh-keygen.exe -ErrorAction Stop | Out-Null

    $ServerIp = (Read-Host "IPv4 нового VPS").Trim()
    $PortInput = (Read-Host "Действующий порт SSH; Enter для 22").Trim()
    if (-not $PortInput) { $PortInput = "22" }
    $SshPort = 0
    $ParsedIp = $null
    if (-not [System.Net.IPAddress]::TryParse($ServerIp, [ref]$ParsedIp) -or
        $ParsedIp.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork -or
        $ParsedIp.ToString() -ne $ServerIp) {
        throw "Укажите IPv4 VPS, например 192.0.2.10."
    }
    if (-not [int]::TryParse($PortInput, [ref]$SshPort) -or
        $SshPort -lt 1 -or $SshPort -gt 65535) {
        throw "SSH-порт должен быть от 1 до 65535."
    }

    $SshUser = (Read-Host "Пользователь SSH; Enter для root").Trim()
    if (-not $SshUser) { $SshUser = "root" }
    if ($SshUser -ne "root") { throw "Этот блок рассчитан на вход под root." }
    $PrivateKeyPath = (Read-Host "Полный путь к ПРИВАТНОМУ ключу, без .pub").Trim().Trim('"')
    $PublicKeyPath = (Read-Host "Полный путь к ПУБЛИЧНОМУ ключу, с .pub").Trim().Trim('"')
    foreach ($KeyFile in @($PrivateKeyPath, $PublicKeyPath)) {
        if (-not (Test-Path -LiteralPath $KeyFile -PathType Leaf)) {
            throw "Файл ключа не найден: $KeyFile"
        }
    }
    $PrivateKeyPath = (Resolve-Path -LiteralPath $PrivateKeyPath).Path
    $PublicKeyPath = (Resolve-Path -LiteralPath $PublicKeyPath).Path

    $PublicText = [System.IO.File]::ReadAllText($PublicKeyPath).Trim()
    if ($PublicText -match '[\r\n]') { throw "В .pub должна быть одна строка ключа." }
    $PublicParts = @($PublicText -split '\s+')
    if ($PublicParts.Count -lt 2 -or $PublicParts[1] -notmatch '^[A-Za-z0-9+/]+={0,2}$') {
        throw "Некорректный формат публичного ключа."
    }

    Write-Host "Проверяю пару ключей. Возможен запрос passphrase — парольной фразы локального ключа."
    $DerivedText = (& ssh-keygen.exe -y -f "$PrivateKeyPath") -join "`n"
    if ($LASTEXITCODE -ne 0) { throw "Не удалось прочитать приватный ключ." }
    $DerivedParts = @($DerivedText.Trim() -split '\s+')
    $PublicKey = "$($PublicParts[0]) $($PublicParts[1])"
    if ($DerivedParts.Count -lt 2 -or
        "$($DerivedParts[0]) $($DerivedParts[1])" -cne $PublicKey) {
        throw "Публичный и приватный ключи не составляют пару."
    }
    $PublicKeyB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($PublicKey))

    $RemoteScript = @'
set -euo pipefail
umask 077
[[ $(id -u) -eq 0 ]] || { printf 'Root login required.\n' >&2; exit 1; }
sshdir=/root/.ssh
auth="$sshdir/authorized_keys"
[[ ! -L "$sshdir" && ! -L "$auth" ]] || { printf 'Symlink detected; stopped.\n' >&2; exit 1; }
[[ ! -e "$auth" || -f "$auth" ]] || { printf 'authorized_keys is not a file.\n' >&2; exit 1; }
install -d -m 700 "$sshdir"
key=$(printf '%s' '__PUBLIC_KEY_B64__' | base64 --decode)
keyfile=$(mktemp "$sshdir/.deploy-key.XXXXXX")
trap 'rm -f -- "$keyfile"' EXIT
printf '%s\n' "$key" > "$keyfile"
ssh-keygen -lf "$keyfile" >/dev/null
if [[ -e "$auth" ]]; then
    backup="${auth}.bak.$(date -u +%Y%m%dT%H%M%S%N)"
    cp --preserve=all -- "$auth" "$backup"
    printf 'AUTHORIZED_KEYS_BACKUP=%s\n' "$backup"
else
    install -m 600 /dev/null "$auth"
fi
chown root:root "$sshdir" "$auth"
chmod 700 "$sshdir"
chmod 600 "$auth"
if ! awk -v wanted="$key" '$1 " " $2 == wanted { found=1 } END { exit !found }' "$auth"; then
    printf '\n%s\n' "$key" >> "$auth"
fi
printf 'PUBLIC_KEY_INSTALLED\n'
'@
    $RemoteScript = $RemoteScript.Replace('__PUBLIC_KEY_B64__', $PublicKeyB64).Replace("`r", "")
    $RemoteScriptB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($RemoteScript))
    $RemoteCommand = "printf '%s' '$RemoteScriptB64' | base64 --decode | bash"
    $SshTarget = "$SshUser@$ServerIp"
    $CommonArgs = @(
        "-4", "-F", "NUL", "-o", "ProxyCommand=none", "-o", "ProxyJump=none",
        "-p", "$SshPort", "-o", "ConnectTimeout=15",
        "-o", "ServerAliveInterval=30", "-o", "ServerAliveCountMax=6",
        "-o", "ClearAllForwardings=yes", "-o", "HostKeyAlgorithms=ssh-ed25519"
    )
    $PasswordArgs = $CommonArgs + @(
        "-o", "StrictHostKeyChecking=ask", "-o", "PreferredAuthentications=password",
        "-o", "PasswordAuthentication=yes", "-o", "PubkeyAuthentication=no",
        "-o", "KbdInteractiveAuthentication=no", "-o", "NumberOfPasswordPrompts=3"
    )
    Write-Host "Сейчас SSH запросит пароль root от VPS. Публичный ключ будет добавлен после входа."
    & ssh.exe @PasswordArgs "$SshTarget" "$RemoteCommand"
    if ($LASTEXITCODE -ne 0) {
        throw "Вход по паролю или добавление ключа не завершены. Исправьте показанную ошибку; парольный вход пока не отключайте."
    }

    $KeyArgs = $CommonArgs + @(
        "-o", "StrictHostKeyChecking=yes", "-o", "PreferredAuthentications=publickey",
        "-o", "PubkeyAuthentication=yes", "-o", "PasswordAuthentication=no",
        "-o", "KbdInteractiveAuthentication=no", "-o", "IdentitiesOnly=yes",
        "-o", "IdentityAgent=none", "-i", "$PrivateKeyPath"
    )
    Write-Host "Проверяю новое подключение только по выбранному ключу."
    & ssh.exe @KeyArgs "$SshTarget" "printf 'SSH_KEY_LOGIN_OK\n'"
    if ($LASTEXITCODE -ne 0) {
        throw "Вход по ключу не подтверждён. Парольный вход отключать нельзя."
    }

    Write-Warning "Теперь отключите вход по паролю командой из шага 1.3."
    Write-Host "Открываю SSH-терминал VPS по ключу. Приватный ключ остаётся на Windows."
    & ssh.exe @KeyArgs "$SshTarget"
    if ($LASTEXITCODE -ne 0) { throw "SSH-сессия завершилась с ошибкой." }
}
```

Ожидаются `PUBLIC_KEY_INSTALLED`, затем `SSH_KEY_LOGIN_OK` и приглашение вида `root@имя-сервера:~#`. Пароль VPS вводится непосредственно в SSH и не отображается. Запрос `passphrase` относится к приватному ключу на Windows. На VPS передаётся только публичный ключ; уже записанные ключи сохраняются.

### 1.3. Отключите вход по паролю

Выполняйте после `SSH_KEY_LOGIN_OK`. **Оставьте это SSH-окно открытым**, пока не проверите новый вход в другом окне PowerShell.

**SSH-терминал VPS под root — весь блок целиком:**

```bash
(
    set -euo pipefail
    umask 077
    (( EUID == 0 )) || { printf 'Нужен root.\n' >&2; exit 1; }
    [[ -n ${SSH_CONNECTION:-} && -s /root/.ssh/authorized_keys ]] || {
        printf 'Нужна SSH-сессия с уже установленным ключом.\n' >&2; exit 1;
    }
    /usr/sbin/sshd -t

    conf=/etc/ssh/sshd_config.d/00-xui-key-only.conf
    [[ ! -L "$conf" && ( ! -e "$conf" || -f "$conf" ) ]] || {
        printf 'Необычный файл SSH-конфигурации; остановка.\n' >&2; exit 1;
    }
    mkdir -p /etc/ssh/sshd_config.d
    backup=$(mktemp -d /root/ssh-key-only-backup.XXXXXX)
    if [[ -e "$conf" ]]; then
        cp --preserve=all -- "$conf" "$backup/previous.conf"
    else
        touch "$backup/previously-absent"
    fi
    cat > "$backup/rollback.sh" <<'ROLLBACK'
#!/bin/bash
set -euo pipefail
backup=$(cd -- "$(dirname -- "$0")" && pwd)
conf=/etc/ssh/sshd_config.d/00-xui-key-only.conf
if [[ -f "$backup/previously-absent" ]]; then
    rm -f -- "$conf"
else
    cp --preserve=all -- "$backup/previous.conf" "$conf"
fi
/usr/sbin/sshd -t
systemctl reload ssh.service
printf 'SSH_ROLLBACK_OK\n'
ROLLBACK
    chmod 700 "$backup/rollback.sh"
    printf 'Резервная копия: %s\nКоманда отката: bash %s/rollback.sh\n' "$backup" "$backup"
    trap 'rc=$?; if (( rc != 0 )); then bash "$backup/rollback.sh" || printf "Откат не завершён; используйте консоль провайдера.\n" >&2; fi' EXIT

    cat > "$backup/new.conf" <<'SSH_CONFIG'
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
AuthenticationMethods publickey
SSH_CONFIG
    chmod 600 "$backup/new.conf"
    mv -- "$backup/new.conf" "$conf"
    /usr/sbin/sshd -t
    read -r client_ip client_port server_ip server_port <<< "$SSH_CONNECTION"
    for scope in global current; do
        if [[ "$scope" == global ]]; then
            effective=$(/usr/sbin/sshd -T)
        else
            effective=$(/usr/sbin/sshd -T -C "user=root,addr=$client_ip,host=$client_ip,laddr=$server_ip,lport=$server_port")
        fi
        for expected in 'pubkeyauthentication yes' 'passwordauthentication no' \
            'kbdinteractiveauthentication no' 'authenticationmethods publickey'; do
            grep -qxF "$expected" <<< "$effective" || {
                printf 'Другая настройка SSH перекрывает: %s (%s). Выполняется откат.\n' "$expected" "$scope" >&2;
                exit 1;
            }
        done
        grep -Eq '^permitrootlogin (prohibit-password|without-password)$' <<< "$effective" || {
            printf 'SSH не разрешает ожидаемый вход root по ключу (%s). Выполняется откат.\n' "$scope" >&2;
            exit 1;
        }
    done
    systemctl reload ssh.service
    systemctl is-active --quiet ssh.service
    trap - EXIT
    printf 'SSH_KEY_ONLY_APPLIED: вход по паролю отключён; root входит по ключу.\n'
)
```

Блок запрещает парольный и keyboard-interactive вход по SSH, сохраняет вход `root` по ключу и выводит точную команду отката. Если проверка конфигурации не проходит, восстанавливает предыдущую настройку. Порт SSH остаётся прежним.

### 1.4. Проверьте применённые настройки и новый вход

**В том же SSH-терминале VPS — весь блок:**

```bash
(
    set -euo pipefail
    [[ -n ${SSH_CONNECTION:-} ]] || { printf 'Выполните в SSH-сессии.\n' >&2; exit 1; }
    /usr/sbin/sshd -t
    read -r client_ip client_port server_ip server_port <<< "$SSH_CONNECTION"
    /usr/sbin/sshd -T -C "user=root,addr=$client_ip,host=$client_ip,laddr=$server_ip,lport=$server_port" |
        grep -E '^(pubkeyauthentication|passwordauthentication|kbdinteractiveauthentication|permitrootlogin|authenticationmethods) '
    systemctl is-active ssh.service
)
```

Ожидаемые значения (порядок строк может отличаться):

```text
pubkeyauthentication yes
passwordauthentication no
kbdinteractiveauthentication no
permitrootlogin prohibit-password
authenticationmethods publickey
active
```

В строке `permitrootlogin` также допустимо `without-password`: это другое название той же настройки.

**Второе окно PowerShell на Windows — весь блок:**

```powershell
& {
    $ErrorActionPreference = "Stop"
    Get-Command ssh.exe -ErrorAction Stop | Out-Null
    $ServerIp = (Read-Host "IPv4 VPS").Trim()
    $PortInput = (Read-Host "Действующий порт SSH; Enter для 22").Trim()
    if (-not $PortInput) { $PortInput = "22" }
    $SshPort = 0
    $ParsedIp = $null
    if (-not [System.Net.IPAddress]::TryParse($ServerIp, [ref]$ParsedIp) -or
        $ParsedIp.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork -or
        $ParsedIp.ToString() -ne $ServerIp) {
        throw "Укажите IPv4 VPS."
    }
    if (-not [int]::TryParse($PortInput, [ref]$SshPort) -or
        $SshPort -lt 1 -or $SshPort -gt 65535) { throw "Некорректный SSH-порт." }
    $PrivateKeyPath = (Read-Host "Полный путь к ПРИВАТНОМУ SSH-ключу").Trim().Trim('"')
    if (-not (Test-Path -LiteralPath $PrivateKeyPath -PathType Leaf)) {
        throw "Приватный ключ не найден."
    }
    $PrivateKeyPath = (Resolve-Path -LiteralPath $PrivateKeyPath).Path
    $SshArgs = @(
        "-4", "-F", "NUL", "-o", "ProxyCommand=none", "-o", "ProxyJump=none",
        "-p", "$SshPort", "-i", "$PrivateKeyPath",
        "-o", "StrictHostKeyChecking=yes", "-o", "HostKeyAlgorithms=ssh-ed25519",
        "-o", "PreferredAuthentications=publickey", "-o", "PubkeyAuthentication=yes",
        "-o", "PasswordAuthentication=no", "-o", "KbdInteractiveAuthentication=no",
        "-o", "IdentitiesOnly=yes", "-o", "IdentityAgent=none",
        "-o", "ClearAllForwardings=yes", "-o", "ConnectTimeout=15",
        "-o", "ServerAliveInterval=30", "-o", "ServerAliveCountMax=6"
    )
    & ssh.exe @SshArgs "root@$ServerIp"
    if ($LASTEXITCODE -ne 0) { throw "SSH-вход не подтверждён. Сохраните первое SSH-окно и проверьте ошибку." }
}
```

Ожидается приглашение `root@имя-сервера:~#`; пароль VPS не запрашивается. Парольная фраза приватного ключа, если задана, может запрашиваться. Успешный новый вход подтверждает, что доступ сохранился после отключения пароля. После этого переходите к шагу 2; первое SSH-окно можно закрыть.

Если новый вход не работает, в ещё открытой SSH-сессии выполните команду отката, которую напечатал шаг 1.3, и исправьте проблему. Если SSH недоступен, эту же команду можно выполнить в консоли провайдера.

## 2. Создайте GitHub-токен для загрузки

Откройте [создание fine-grained токена](https://github.com/settings/personal-access-tokens/new) и выберите:

- **Token name — имя:** `xui-deploy-read`.
- **Expiration — срок:** 30 дней.
- **Resource owner — владелец:** `VBZZZR`.
- **Repository access — доступ:** `Only select repositories` → `xui-node-deploy`.
- **Repository permissions — права:** `Contents` → `Read-only`.

Нажмите **Generate token — создать токен**. Сохраните его в менеджере паролей: он потребуется в шаге 4 и на следующих VPS до истечения срока.

## 3. Откройте SSH-терминал VPS

Если окно подключения из шага 1.4 открыто, используйте его. Если закрыли окно, повторите PowerShell-блок шага 1.4: он подключается только по выбранному приватному ключу. Повторно загружать публичный ключ не требуется.

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
    if ! IFS= read -r -s -p 'GitHub-токен из шага 2: ' github_read_token; then
        printf '\n[ERROR] Ввод токена прерван.\n' >&2
        exit 1
    fi
    printf '\n'
    [[ "$github_read_token" =~ ^[A-Za-z0-9_]+$ ]] || {
        printf '[ERROR] Токен пуст или содержит недопустимые символы.\n' >&2
        exit 1
    }

    curl --disable --fail --silent --show-error --location \
        --proto '=https' --proto-redir '=https' \
        --connect-timeout 15 --max-time 120 --retry 2 \
        --header 'Accept: application/vnd.github.raw+json' \
        --header 'X-GitHub-Api-Version: 2026-03-10' \
        --header @/dev/fd/3 \
        'https://api.github.com/repos/VBZZZR/xui-node-deploy/contents/install.sh?ref=main' \
        --output "$bootstrap" \
        3< <(printf 'Authorization: Bearer %s\n' "$github_read_token") || {
        printf '[ERROR] Загрузка не удалась. Проверьте доступ GitHub-токена к репозиторию.\n' >&2
        exit 1
    }

    if ! printf '%s  %s\n' \
        'e2c2ac3e5600fa28da02bdbb0d965a505b429de5952a4ed7c1fe551805b09923' \
        "$bootstrap" | sha256sum --check; then
        printf '[ERROR] SHA-256 загрузчика не совпала. Установка остановлена.\n' >&2
        exit 1
    fi

    exec 3< <(printf '%s\n' "$github_read_token")
    unset github_read_token
    bash "$bootstrap" VBZZZR/xui-node-deploy
)
```

После запроса вставьте GitHub-токен и нажмите Enter; символы не отображаются. Ожидается сообщение `OK`, затем запуск установщика. Если проверка SHA-256 не прошла, возьмите весь блок из текущего README в ветке `main`: сохранённый ранее блок может содержать старую контрольную сумму. Ошибка на этом этапе относится к загрузчику, а не к API основной панели.

## 5. Ответьте на запросы установщика

| Запрос | Что сделать |
|---|---|
| Домен, страна, короткое имя узла | Введите параметры нового VPS, например код страны `US` и имя `US1` |
| Порт панели и внешний firewall | Разрешите показанный порт панели у провайдера; введите `ОТКРЫТО` |
| Второй вход по SSH | Откройте другое окно PowerShell, повторите PowerShell-блок шага 1.4; при успешном входе в установщике введите `SSH-OK` |
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

После перезагрузки повторите SSH-вход из шага 1.4. **На том же VPS** продолжите:

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
