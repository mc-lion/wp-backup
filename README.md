# wp-backup — бэкап WordPress (этап 1)

Скрипт локального бэкапа одной установки WordPress с опциональной выгрузкой на **Proxmox Backup Server** и/или **S3**.

Подробные требования: [TZ_backup_WP.md](TZ_backup_WP.md).

## Зависимости

Обязательно:

- `bash`, `tar`, `gzip`, `find`, `mysqldump` (mysql/mariadb client)
- `perl` или корректный `sed` (для парсинга `wp-config.php`)

Опционально:

- `proxmox-backup-client` — для `--destination pbs|both`
- `aws` **или** `rclone` — для `--destination s3|both`
- `php` — только с `--allow-php-parse`

## Быстрый старт (только local)

```bash
chmod +x wp-backup.sh

sudo ./wp-backup.sh \
  --wp-root /var/www/example.com \
  --mode full \
  --destination local \
  --backup-root /var/backups/wordpress
```

Артефакты:

```text
/var/backups/wordpress/<site-id>/<YYYY-MM-DD_HHMMSS>/
  db.sql.gz
  site.tar.gz
  uploads-hot.tar.gz
  uploads-cold.tar.gz
  manifest.json
  backup.log
  debug.log          # только с --debug
```

`wp-config.php` ищется в `--wp-root` и подкаталогах **глубиной до 3**. При нескольких файлах укажите `--wp-config /path/to/wp-config.php`.

## Отладка (`--debug`)

Если бэкап падает — перезапустите с `--debug` (или `DEBUG=1`):

```bash
./wp-backup.sh --wp-root /var/www/example.com --mode full --destination local --debug
```

В режиме debug скрипт:

- пишет шаги `STEP: ...` и подробности `DEBUG: ...` в `backup.log`;
- включает bash xtrace в `debug.log` внутри каталога run;
- при ошибке печатает **DEBUG CONTEXT** (пути, mode, last_step/last_cmd, listing run, наличие утилит);
- сохраняет stderr внешних команд (`mysqldump.err`, `site-tar.err`, `pbs-upload.err`, `s3-upload.err`);
- **не** пишет пароли БД/PBS/S3 в контекст (маскирует).

## Режимы `--mode`

| Mode | Содержимое |
|------|------------|
| `full` | БД + site (без каталогов `uploads/ГОД/МЕСЯЦ` и без cache) + uploads-hot + uploads-cold |
| `full-hot` | то же, что `full`, без `uploads-cold.tar.gz` |
| `db` | только БД |
| `site` | файлы сайта; прочие файлы и папки внутри `uploads` входят, каталоги `ГОД/МЕСЯЦ` нет |
| `uploads-hot` | каталоги `uploads/ГОД/МЕСЯЦ` за последние `--hot-months` (default 2), включая переход через Новый год |
| `uploads-cold` | остальные каталоги `ГОД/МЕСЯЦ` |
| `uploads-changed` | файлы всего `--wp-root` с `mtime` не старше `--changed-hours` (default 24) или `--changed-days` (`N*24` часа); cache/tmp/`.git` не входят |
| `uploads-all` | hot + cold |

Год — папка из 4 цифр, месяц — `01`–`12`. Дополнительные имена: `--month-names FILE` со строками `Имя 11`. Те же год и месяц ищутся ещё в `uploads/sites/<id>/`, где `<id>` — каталог из цифр; таких каталогов может быть несколько. Во всех tar первым каталогом идёт имя `--wp-root`, дальше путь внутри него. Для `--wp-root /var/www/edu.kp.ru` файл hot выглядит как `edu.kp.ru/edu/wp-content/uploads/2026/11/photo.jpg` или `edu.kp.ru/edu/wp-content/uploads/sites/2/2026/11/photo.jpg`.

## Выгрузка `--destination`

| Значение | Поведение |
|----------|-----------|
| `local` | только диск сервера |
| `pbs` | после сборки → PBS |
| `s3` | после сборки → S3 |
| `both` | PBS и S3; успех только если оба OK |

Пример конфига: [examples/upload.env.example](examples/upload.env.example).

```bash
sudo ./wp-backup.sh \
  --wp-root /var/www/example.com \
  --mode full \
  --destination both \
  --upload-config /etc/wp-backup/upload.env \
  --keep-local yes
```

Повторная выгрузка без пересборки:

```bash
sudo ./wp-backup.sh \
  --upload-only \
  --run-dir /var/backups/wordpress/example.com/2026-11-05_020015 \
  --destination s3 \
  --upload-config /etc/wp-backup/upload.env
```

### PBS

Клиент: `proxmox-backup-client`. Секрет через `PBS_PASSWORD_FILE` или env `PBS_PASSWORD` / `PBS_API_TOKEN` (не в argv).

### S3

Предпочтительно AWS CLI (`aws s3 sync`). Если `aws` нет — `rclone sync` на remote `RCLONE_REMOTE` (default `s3`).

## Cron

```cron
15 2 * * * /opt/wp-backup/wp-backup.sh --wp-root /var/www/example.com --mode full --destination both --upload-config /etc/wp-backup/upload.env
20 */6 * * * /opt/wp-backup/wp-backup.sh --wp-root /var/www/example.com --mode uploads-changed --destination pbs --upload-config /etc/wp-backup/upload.env
```

## Коды выхода

| Код | Значение |
|-----|----------|
| 0 | успех |
| 1 | аргументы / wp-config / upload-config |
| 2 | константы БД |
| 3 | mysqldump |
| 4 | site archive |
| 5 | uploads archive |
| 6 | мало места |
| 7 | ошибка PBS/S3 (локальный run обычно сохранён) |
| 10 | прочее |

## Checklist приёмки

См. [docs/acceptance-checklist.md](docs/acceptance-checklist.md).
