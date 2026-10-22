# Обмен NetKnife ↔ Omada через файл (формат `netknife-omada/1`)

NetKnife к контроллеру Omada не подключается. С контроллером работает агент инженера через его MCP-коннектор
Omada; NetKnife только читает и пишет JSON-файлы этого формата.

Два вида файла:

| `kind`  | Кто пишет | Что внутри |
|---------|-----------|------------|
| `state` | агент (из Omada) | текущие настройки радио всех точек сайта — NetKnife загружает кнопкой «Загрузить из Omada» |
| `plan`  | NetKnife (кнопка «План для Omada») | какие канал, ширину и мощность выставить каждой точке — агент применяет |

Кодировка UTF-8, один JSON-объект.

## Общая схема

```json
{
  "format": "netknife-omada/1",
  "kind": "state",
  "site": "Алые паруса",
  "omadaSite": "Alie Parusa",
  "generated": "2026-10-22T15:50:00+03:00",
  "country": "RU",
  "aps": [
    {
      "name": "Кухня",
      "mac": "3C-64-CF-69-9A-64",
      "ip": "192.168.115.208",
      "model": "EAP613",
      "radios": {
        "2g": { "enabled": true, "channel": 6,  "width": 20, "txPowerMode": "custom", "txPower": 14,
                "channels": [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13], "widths": [20, 40] },
        "5g": { "enabled": true, "channel": 36, "width": 40, "txPowerMode": "custom", "txPower": 20,
                "channels": [36, 40, 44, 48, 52, 56, 60, 64, 100, 104, 108, 112, 116, 120, 124, 128, 132, 136, 140],
                "widths": [20, 40, 80] }
      }
    }
  ]
}
```

Поля:

- `mac` — MAC устройства, как в Omada (`AA-BB-CC-DD-EE-FF`; двоеточия тоже принимаются). По нему NetKnife сопоставляет
  точки, имя — запасной вариант.
- `radios.2g` / `radios.5g` (`6g` — если есть).
  - `channel` — номер канала или `"auto"`.
  - `width` — 20 / 40 / 80 / 160 или `"auto"` (в Omada «20/40 MHz» и т. п. — записывать как `"auto"`).
  - `txPowerMode` — `low` / `medium` / `high` / `custom` / `auto`.
  - `txPower` — мощность в dBm (EIRP, как в поле Custom). Для `low/medium/high/auto` — фактическое значение, если
    Omada его показывает, иначе `null`.
  - `enabled` — радио включено.
  - `channels` — **каналы, которые Omada разрешает выбрать для этого радио** (выпадающий список «Channel» точки
    при текущей стране сайта), числами. По ним NetKnife строит план — каналов вне списка в плане не будет.
  - `widths` — доступные ширины канала (20/40/80/160).
- `country` — страна сайта (Site Settings → Country/Region), код ISO (`RU`, `DE`…).

## `kind: "plan"` — что выставить

Те же поля, плюс у каждой точки `current` — что NetKnife считает текущим (для сверки):

```json
{
  "format": "netknife-omada/1", "kind": "plan", "site": "Алые паруса", "generated": "…",
  "aps": [
    { "name": "Кухня", "mac": "3C-64-CF-69-9A-64",
      "radios":  { "2g": { "channel": 6, "width": 20, "txPowerMode": "custom", "txPower": 14 },
                   "5g": { "channel": 36, "width": 40, "txPowerMode": "custom", "txPower": 20 } },
      "current": { "2g": { "channel": 6, "width": 20, "txPower": 20 },
                   "5g": { "channel": 36, "width": 40, "txPower": 27 } } }
  ]
}
```

Поле в `radios`, которого нет или которое равно `null`, **не менять**. Менять только радио точек — не SSID, не
сайт, не другие устройства.
