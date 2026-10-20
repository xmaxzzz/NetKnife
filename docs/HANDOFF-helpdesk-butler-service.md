# MikroTik: общие служебные пользователи Butler (контракт v2, 2026-10-20)

Решение Максима: на каждом роутере объекта два **общих** пользователя для NetKnife, Helpdesk и Claude.
Реализация в NetKnife: `lib/MikroTik.ps1` — `Get-MtKeyRegistry`, `Get-MtProvisionScript`, `Show-MtConnectDialog`,
`Invoke-MtChange`.

| Пользователь | Группа | Для чего |
|---|---|---|
| `butler-service` | `butler-service-ro` | чтение и диагностика |
| `butler-rw` | `butler-service-rw` | запись — только подтверждённые изменения |

Политики:
- `butler-service-ro`: `read,test,ssh,api,rest-api,!local,!telnet,!ftp,!reboot,!write,!policy,!password,!web,!sniff,!sensitive,!romon,!winbox`
- `butler-service-rw`: `read,write,test,ssh,api,rest-api,!local,!telnet,!ftp,!reboot,!policy,!password,!web,!sniff,!sensitive,!romon,!winbox`

## Ключи — общий реестр

Сейчас в реестре два ключа, оба RSA 4096: `netknife-mikrotik` (NetKnife, `~/.ssh/netknife_mt`) и `butler-helpdesk`.
Каждый ключ импортируется в **оба** пользователя. Новые ключи под системы не заводим.

- Комментарий ключа на роутере хранится в поле **`info`** (RouterOS 7.24; в старых версиях `key-owner`). Проверено
  на «Алые паруса»: `/user ssh-keys print detail` → `info="netknife-mikrotik"`.
- Перед импортом удаляется только ключ с тем же комментарием, чужие не трогаем:
  `:do { /user ssh-keys remove [find user="U" info="O"] } on-error={ :do { /user ssh-keys remove [find user="U" key-owner="O"] } on-error={} }`
- В NetKnife публичные ключи других систем вводятся в поле «Настройки → Роутеры MikroTik → Ключи других систем»
  и попадают в команды подключения.

## Правила

- Пользователей создаём, только если их нет. У существующих не меняем ни группу, ни пароль.
- Пароль генерирует сам роутер (`:rndnum` + `:pick`; `:rndstr` на 7.24 не работает), он никуда не выходит.
  Вход только по ключу.
- Диагностика — только под `butler-service`.
- Изменения — только под `butler-rw` и только после явного подтверждения пользователя. Перед изменением
  сохраняется `/export` (NetKnife кладёт его в `%APPDATA%\NetKnife\mikrotik\<объект>\export-before-<время>.rsc`).
- Если пускает только `butler-service`, а `butler-rw` нет — не лезть под admin, а дать команды подключения.

## Порядок при добавлении объекта (NetKnife и Helpdesk делают одинаково)

1. Попробовать вход своим ключом как `butler-service`, затем как `butler-rw` (`:put "OK"`).
2. Оба пускают — готово, ничего не создавать.
3. Иначе выполнить идемпотентный скрипт (ниже) — с админ-доступом сам, без него показать оператору для
   терминала роутера (Winbox → New Terminal).
4. Повторить проверку из шага 1. Маркер успеха скрипта — `BUTLER-USERS-OK`.

## Идемпотентный скрипт (RouterOS 7, вставка в терминал)

На каждый ключ `<KEYn>` с комментарием `<OWNERn>` — по файлу на пользователя. Пример для двух ключей:

```
:if ([:len [/user group find name="butler-service-ro"]] = 0) do={ /user group add name=butler-service-ro policy=read,test,ssh,api,rest-api,!local,!telnet,!ftp,!reboot,!write,!policy,!password,!web,!sniff,!sensitive,!romon,!winbox comment="Butler service: diagnostics, read-only" }
:if ([:len [/user group find name="butler-service-rw"]] = 0) do={ /user group add name=butler-service-rw policy=read,write,test,ssh,api,rest-api,!local,!telnet,!ftp,!reboot,!policy,!password,!web,!sniff,!sensitive,!romon,!winbox comment="Butler service: write integrations" }
:if ([:len [/user find name="butler-service"]] = 0) do={ :local a "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789"; :local p ""; :for i from=1 to=32 do={ :set p ($p . [:pick $a [:rndnum from=0 to=56]]) }; /user add name=butler-service group=butler-service-ro password=$p comment="Butler service: read-only (NetKnife, helpdesk)" }
:if ([:len [/user find name="butler-rw"]] = 0) do={ :local a "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789"; :local p ""; :for i from=1 to=32 do={ :set p ($p . [:pick $a [:rndnum from=0 to=56]]) }; /user add name=butler-rw group=butler-service-rw password=$p comment="Butler service: write, key auth only" }
/file add name=bk1-butler-service.pub contents="<KEY1>"
/file add name=bk1-butler-rw.pub contents="<KEY1>"
/file add name=bk2-butler-service.pub contents="<KEY2>"
/file add name=bk2-butler-rw.pub contents="<KEY2>"
:delay 2s
:do { /user ssh-keys remove [find user="butler-service" info="<OWNER1>"] } on-error={ :do { /user ssh-keys remove [find user="butler-service" key-owner="<OWNER1>"] } on-error={} }
/user ssh-keys import public-key-file=bk1-butler-service.pub user=butler-service
:do { /user ssh-keys remove [find user="butler-rw" info="<OWNER1>"] } on-error={ :do { /user ssh-keys remove [find user="butler-rw" key-owner="<OWNER1>"] } on-error={} }
/user ssh-keys import public-key-file=bk1-butler-rw.pub user=butler-rw
:do { /user ssh-keys remove [find user="butler-service" info="<OWNER2>"] } on-error={ :do { /user ssh-keys remove [find user="butler-service" key-owner="<OWNER2>"] } on-error={} }
/user ssh-keys import public-key-file=bk2-butler-service.pub user=butler-service
:do { /user ssh-keys remove [find user="butler-rw" info="<OWNER2>"] } on-error={ :do { /user ssh-keys remove [find user="butler-rw" key-owner="<OWNER2>"] } on-error={} }
/user ssh-keys import public-key-file=bk2-butler-rw.pub user=butler-rw
:do { /file remove [find name~"^bk[0-9]+-"] } on-error={}
:put "BUTLER-USERS-OK"
```

Если SSH на роутере выключен, NetKnife добавляет первой строкой `/ip service set ssh disabled=no port=<порт>`.
Если скрипт передаётся через `ssh` аргументом (а не вставкой в терминал) — одной строкой через `;`: многострочный
аргумент RouterOS разбирает построчно и ломает блоки `do={…}`.

## Состояние «Алые паруса» (192.168.115.1:10322), 2026-10-20

- `butler-service`: ключи `netknife-mikrotik`, `butler-helpdesk`. Вход NetKnife — есть.
- `butler-rw`: ключ `netknife-mikrotik`. Вход NetKnife — есть. **Ключа `butler-helpdesk` нет** — добавить
  (скриптом выше с ключом helpdesk или через NetKnife после ввода ключа в настройках).

## Грабли

- Вывод RouterOS по SSH — сырой UTF-8, stdout читать как UTF-8. Кириллица в **аргументе** ssh теряется —
  кодировать `\D0\9A…`.
- `:serialize to=json` — RouterOS 7.13+.
- Имя точки Omada в DHCP host-name содержит MAC в любой форме: `MAC Имя`, `Имя (MAC)`, `Имя(MAC)`, `(Имя) MAC`;
  без имени — `MAC (N)`. Запасной источник имени — комментарий статической аренды (`AP Кабинет`).
