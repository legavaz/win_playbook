# win_playbook

Воспроизводимый плейбук по оптимизации и гигиене Windows 11 на рабочей станции 1С-разработчика.

Комплект собран по результатам реального прогона на Windows 11 LTSC (4 ядра / 8 потоков, 16 ГБ RAM, NVMe). Все команды и скрипты проверены на PowerShell 5.1.

## Что решает

- возвращает Microsoft Defender, выключенный «оптимизатором» (политика, ключ продукта, драйверы);
- приводит файл подкачки в соответствие объёму RAM и снимает падения «недостаточно памяти»;
- убирает автозагрузку и фоновые задачи, которые возвращаются сами;
- снимает конфликт имён NetBIOS в локальной сети;
- ставит накопившиеся обновления Windows.

Чего не делает: не ускоряет процессор, не добавляет память, не заменяет чистку охлаждения.

## Состав

```
README.md
docs/OS-OPTIMIZATION-PLAYBOOK.md   полный плейбук: фазы, проверки, откат, грабли
scripts/01-Diagnose.ps1            инвентаризация, только чтение
scripts/02-Set-Pagefile.ps1        файл подкачки (+ -Revert)
scripts/03-Enable-Defender.ps1     возврат Defender через SYSTEM-задачу
scripts/04-Clean-Autostart.ps1     автозагрузка и задачи (+ -Revert)
scripts/05-Test-Configuration.ps1  приёмка PASS/WARN/FAIL
scripts/06-Install-Updates.ps1     поиск, загрузка и установка патчей
```

## Быстрый старт

PowerShell **от администратора**:

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force

.\scripts\01-Diagnose.ps1 -OutFile C:\Temp\win-report.txt
.\scripts\02-Set-Pagefile.ps1 -InitialMB 4096 -MaximumMB 12288
.\scripts\03-Enable-Defender.ps1 -ExclusionPath 'C:\project',"$env:LOCALAPPDATA\npm-cache"
.\scripts\04-Clean-Autostart.ps1 -RunValue '<ЗначениеRun>' -TaskName '<ИмяЗадачи>'
.\scripts\05-Test-Configuration.ps1 -MinPagefileMB 4096 -RequireDefender
```

Перезагрузка нужна после шагов 2, 3 и 6. Их можно объединить в одну, но только после завершения установки обновлений.

Подробности, пороги «норма/тревога», нюансы 1С и список типовых ошибок — в [плейбуке](docs/OS-OPTIMIZATION-PLAYBOOK.md).

## Требования

- Windows 10/11 Pro/Enterprise/IoT LTSC, PowerShell 5.1, локальный администратор.
- 30–60 минут и 1–2 перезагрузки.
- Точка восстановления или образ диска.
- Понимание, привязана ли лицензия 1С к имени компьютера (см. фазу 5 плейбука).

## Безопасность

- Скрипты меняют системные настройки. Перед запуском прочитайте соответствующий раздел плейбука.
- Каждый шаг пишет резервную копию в `C:\ProgramData\OSPlaybook\backup-<timestamp>`.
- Не запускайте на серверах 1С:Предприятия и на машинах под доменной политикой без адаптации.
- Репозиторий не содержит данных конкретных машин: путей пользователей, логов и бэкапов.

## Лицензия

MIT, см. [LICENSE](LICENSE).
