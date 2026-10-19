# HANDOFF → helpdesk: общий служебный пользователь MikroTik `butler-service`

Источник: NetKnife (D:\SCRIPTS\NetKnife, `lib/MikroTik.ps1`, функции `Get-MtProvisionScript`, `Show-MtConnectDialog`).
Решение владельца (2026-10-19): на всех объектах **один** служебный пользователь RouterOS — `butler-service`.
Им пользуются NetKnife (ноутбук инженера) и helpdesk. Никаких отдельных `netknife`/`helpdesk` пользователей.

## Задача для helpdesk

При добавлении объекта (или первом подключении к его MikroTik) helpdesk должен:

1. **Сначала проверить**, работает ли вход как `butler-service` со своим ключом (SSH) — если да, ничего не создавать.
2. **Если нет** — создать пользователя / добавить свой ключ **идемпотентным** скриптом ниже
   (создаёт только то, чего нет; чужое не трогает).
3. Проверить вход ещё раз и сохранить результат.

Если у helpdesk есть админ-доступ к роутеру — шаг 2 выполняется им автоматически.
Если нет — показать оператору готовые команды для терминала роутера (Winbox → New Terminal), как делает NetKnife,
и кнопку «Готово — проверить».

## Контракт (менять только по договорённости обеих систем)

| Что | Значение |
|---|---|
| Пользователь | `butler-service` |
| Группа пользователя | `butler-service-ro` |
| Политика `butler-service-ro` | `read,test,ssh,api,rest-api,!local,!telnet,!ftp,!reboot,!write,!policy,!password,!web,!sniff,!sensitive,!romon,!winbox` |
| Резервная группа | `butler-service-rw` (без пользователей): `read,write,test,ssh,api,rest-api,!local,!telnet,!ftp,!reboot,!policy,!password,!web,!sniff,!sensitive,!romon,!winbox` |
| Комментарий пользователя | `Butler service account (NetKnife, helpdesk)` |
| Ключи | у каждой системы **свой** SSH-ключ; комментарий ключа = `key-owner` на роутере |
| key-owner NetKnife | `netknife-mikrotik` (RSA 4096) |
| key-owner helpdesk | предлагается `butler-helpdesk` (любой, но не `netknife-mikrotik`) |
| SSH-порт | на объектах Butler обычно `10322`, иначе `22` |

### Правила общей учётки

- **Существующего пользователя не менять**: ни группу, ни пароль. Только добавить/заменить **свой** ключ.
- Удалять ключи **только своего** key-owner:
  `/user ssh-keys remove [find user="butler-service" key-owner="butler-helpdesk"]` — ключ NetKnife остаётся.
- **Пароль принадлежит helpdesk.** NetKnife входит только по ключу и пароль не хранит. Пароль он задаёт
  (случайный) лишь когда сам создаёт пользователя — чтобы не оставить пустой. Если helpdesk нужен пароль
  (API 8728/8729 — там вход только по паролю) и пользователя создал NetKnife — helpdesk при админ-доступе делает
  `/user set [find name="butler-service"] password="…"`; NetKnife это не ломает.
- **Права на запись — открытый вопрос.** Пользователь в `-ro`. Если helpdesk нужна запись, перевод общего
  пользователя в `butler-service-rw` даст запись и NetKnife. Варианты обсудить с владельцем до реализации.

## Проверка «пользователь уже есть»

- Без админа (основной путь): попытка входа `ssh -i <ключ helpdesk> -p <порт> -o BatchMode=yes butler-service@<ip> ':put OK'`.
  Успех = пользователь есть **и** ключ helpdesk на нём. `Permission denied` = пользователя нет **или** нет ключа
  helpdesk — различить без админа нельзя; в обоих случаях подходит один и тот же идемпотентный скрипт.
- С админом: `:put [:len [/user find name="butler-service"]]` → `0` / `1`;
  ключ helpdesk: `:put [:len [/user ssh-keys find user="butler-service" key-owner="butler-helpdesk"]]`.

## Идемпотентный скрипт (RouterOS 7)

`<PUBKEY>` — публичный ключ helpdesk одной строкой (`ssh-rsa AAAA… butler-helpdesk`), `<RANDOM>` — случайный
пароль (используется только при создании). Строки независимы, можно вставлять в терминал целиком или выполнять
по SSH под админом.

```
:if ([:len [/user group find name="butler-service-ro"]] = 0) do={ /user group add name=butler-service-ro policy=read,test,ssh,api,rest-api,!local,!telnet,!ftp,!reboot,!write,!policy,!password,!web,!sniff,!sensitive,!romon,!winbox comment="Butler service: diagnostics, read-only" }
:if ([:len [/user group find name="butler-service-rw"]] = 0) do={ /user group add name=butler-service-rw policy=read,write,test,ssh,api,rest-api,!local,!telnet,!ftp,!reboot,!policy,!password,!web,!sniff,!sensitive,!romon,!winbox comment="Butler service: reserved for write integrations" }
:if ([:len [/user find name="butler-service"]] = 0) do={ /user add name=butler-service group=butler-service-ro password="<RANDOM>" comment="Butler service account (NetKnife, helpdesk)" }
/file add name=butler-helpdesk.pub contents="<PUBKEY>"
:delay 1s
:do { /user ssh-keys remove [find user="butler-service" key-owner="butler-helpdesk"] } on-error={}
/user ssh-keys import public-key-file=butler-helpdesk.pub user=butler-service
:do { /file remove [find name="butler-helpdesk.pub"] } on-error={}
:put "BUTLER-SERVICE-OK"
```

Тот же скрипт у NetKnife, только файл `netknife.pub`, key-owner `netknife-mikrotik` и маркер `NETKNIFE-OK`.
Если SSH на роутере выключен, NetKnife добавляет первой строкой `/ip service set ssh disabled=no port=<порт>`.

## Проверено вживую / грабли

- 2026-10-19: объект «Алые паруса» (192.168.115.1:10322) подключён этим скриптом, вход `butler-service` по ключу
  работает, `:serialize to=json` и чтение DHCP-аренд под `butler-service-ro` — ок.
- `/file add contents=` + `/user ssh-keys import` — работают. Ветка `remove … key-owner=` выполнялась под
  `on-error` и отдельно не проверялась — при первой реализации проверить, что поле называется именно `key-owner`
  (`/user ssh-keys print detail`).
- Вывод RouterOS по SSH — сырой UTF-8 (кириллица в DHCP host-name). Читать stdout как UTF-8, иначе кракозябры.
- `:serialize to=json` — RouterOS 7.13+.
- Ключ RSA 4096 — самый совместимый вариант; ed25519 на старых RouterOS не принимается.
- Точки Omada регистрируют DHCP host-name как `AA-BB-CC-DD-EE-FF Имя` (без имени — `MAC (N)`); NetKnife берёт
  отсюда имена точек.
