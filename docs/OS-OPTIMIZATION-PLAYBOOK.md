# Плейбук: оптимизация и гигиена Windows 11 на рабочей станции 1С-разработчика

Версия 1.0. Эталонный прогон: Windows 11 LTSC 26200, 4 ядра / 8 потоков, 16 ГБ RAM, NVMe 512 ГБ.

Документ описывает воспроизводимый порядок действий на машине, где уже поработал «оптимизатор» (Reg Organizer и подобные) либо антивирус, подкачка и автозагрузка настроены неоптимально. Все шаги идемпотентны, каждый пишет резервную копию в `C:\ProgramData\OSPlaybook\backup-<timestamp>`.

---

## 1. Область применения

**Что даёт:**
- возвращает Microsoft Defender и настраивает исключения для каталогов разработки;
- приводит файл подкачки в соответствие объёму RAM (устраняет падения «недостаточно памяти»);
- убирает автозагрузку и фоновые задачи, которые возвращаются сами;
- снимает конфликт имён в локальной сети;
- ставит накопившиеся обновления Windows.

**Чего не даёт:** не ускоряет процессор, не добавляет память, не заменяет чистку системы охлаждения. На слабом CPU (4 ядра / 15 Вт) потолок производительности остаётся прежним.

**Кому не подходит:** серверам 1С:Предприятия (там другой профиль настроек), машинам под доменной политикой (настройки может перезаписать GPO), ПК с аппаратными ключами защиты, требующими конкретных настроек Secure Boot.

---

## 2. Требования

- Windows 10/11 Pro/Enterprise/IoT LTSC, PowerShell 5.1, локальный администратор.
- 30–60 минут и 1–2 перезагрузки.
- Точка восстановления или образ диска.
- Для 1С: заранее выяснить, привязана ли лицензия к имени компьютера (см. фазу 5).
- Свободное место для логов и бэкапов: 100 МБ.

---

## 3. Состав комплекта

```
docs/OS-OPTIMIZATION-PLAYBOOK.md   этот документ
scripts/01-Diagnose.ps1            только чтение: инвентаризация и метрики
scripts/02-Set-Pagefile.ps1        файл подкачки
scripts/03-Enable-Defender.ps1     возврат Defender (через SYSTEM-задачу)
scripts/04-Clean-Autostart.ps1     автозагрузка и задачи
scripts/05-Test-Configuration.ps1  приёмка: PASS/WARN/FAIL
scripts/06-Install-Updates.ps1     поиск, загрузка и установка патчей
```

Запуск из PowerShell **от администратора**:

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
cd <папка проекта>
```

---

## 4. Порядок работ

| № | Фаза | Перезагрузка | Скрипт |
|---|------|--------------|--------|
| 0 | Диагностика | — | `01-Diagnose.ps1` |
| 1 | Файл подкачки | да | `02-Set-Pagefile.ps1` |
| 2 | Антивирус | да, если драйверы были отключены | `03-Enable-Defender.ps1` |
| 3 | Автозагрузка | нет | `04-Clean-Autostart.ps1` |
| 4 | Bloatware | нет | вручную |
| 5 | Сеть и имя | да, если переименование | вручную |
| 6 | Обновления | да | `06-Install-Updates.ps1` |
| 7 | Приёмка | — | `05-Test-Configuration.ps1` |

Перезагрузки фаз 1, 2 и 6 можно объединить в одну, но **только после** завершения установки обновлений.

---

## 5. Фаза 0. Диагностика

```powershell
.\scripts\01-Diagnose.ps1 -OutFile C:\Temp\win-report.txt
```

### Что смотреть

| Метрика | Норма | Тревога | Действие |
|---|---|---|---|
| Свободно RAM | > 20% | < 15% | фаза 3 (автозагрузка), поиск утечек |
| Лимит памяти (commit) | RAM + 4…12 ГБ | RAM + 1…2 ГБ | фаза 1 |
| Файл подкачки | 4 ГБ и больше | 1–2 ГБ фиксированно | фаза 1 |
| Свободно на C: | > 15% | < 10% | чистка Temp/кэшей |
| SMART | Healthy, Wear < 80 | Wear > 80, ошибки | замена диска |
| Автозагрузка (Run) | ≤ 5 записей | > 8 | фаза 3 |
| Задачи вне Microsoft | ≤ 5 включённых | > 8 | фаза 3 |
| Службы Auto | 60–80 | > 100 | ревизия |
| События 4321 (NetBT) | 0 | > 0 | фаза 5 |
| События 7026 (драйвер не загрузился) | 0 | > 0 | проверить, какой драйвер |
| События 1796 (TPM-WMI) | 0 | > 0 | обычно Secure Boot выключен |
| Defender | AMService / RealTime = True | False | фаза 2 |

### Важно про события 129 и 153

`Microsoft-Windows-Kernel-Power`/storage-события с кодами 129 и 153 в журнале System — это **не ошибки диска**, а сообщения гипервизора: «Hypervisor initialized I/O remapping» и «Virtualization-based security is enabled». Не начинайте с замены SSD, пока не прочитали текст события.

---

## 6. Фаза 1. Файл подкачки

### Зачем

При 16 ГБ RAM и фиксированных 1–2 ГБ подкачки предел выделения памяти равен ~16.7 ГБ. Один сеанс «1С + браузер + Node» упирается в него, приложение падает, дамп не создаётся.

### Размеры

| RAM | Initial | Maximum |
|---|---|---|
| 8 ГБ | 2048 | 8192 |
| 16 ГБ | 4096 | 12288 |
| 32 ГБ | 4096 | 16384 |
| 64 ГБ | 8192 | 16384 |

Правило: initial ≈ 25–50% RAM, maximum ≈ 1–1.5× RAM, но не больше 16 ГБ без нужды.

### Выполнение

```powershell
.\scripts\02-Set-Pagefile.ps1 -InitialMB 4096 -MaximumMB 12288
```

Скрипт выставляет `AutomaticManagedPagefile = False`, пишет `PagingFiles = C:\pagefile.sys 4096 12288` и дублирует значения через WMI.

### Проверка после перезагрузки

```powershell
Get-CimInstance Win32_PageFileUsage | Select Name, AllocatedBaseSize
$os = Get-CimInstance Win32_OperatingSystem
($os.TotalVirtualMemorySize / 1MB) - ($os.TotalPhysicalMemory / 1MB)   # должно быть ~4 ГБ
```

### Откат

```powershell
.\scripts\02-Set-Pagefile.ps1 -Revert
```

---

## 7. Фаза 2. Антивирус

### 7.1 Диагностика

```powershell
Get-MpComputerStatus | Select AMServiceEnabled, RealTimeProtectionEnabled, AMRunningMode
Get-Service WinDefend, WdNisSvc, SecurityHealthService | Select Name, Status, StartType

# политики
Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender' | Select DisableAntiSpyware, DisableAntiVirus

# ключ продукта (может быть защищён ACL)
Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows Defender' | Select DisableAntiSpyware, DisableAntiVirus

# драйверы (Start: 0 = boot, 2 = auto, 3 = demand, 4 = disabled)
foreach ($n in 'WdBoot','WdFilter','WdNisDrv','WinDefend') {
  '{0,-10} Start={1}' -f $n, (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\$n").Start
}

# сторонние антивирусы
Get-CimInstance -Namespace root\SecurityCenter2 -ClassName AntiVirusProduct | Select displayName
```

### 7.2 Почему «просто включить» не работает

1. Политика `HKLM\SOFTWARE\Policies\Microsoft\Windows Defender` снимается администратором обычным `Remove-Item`.
2. Ключ продукта `HKLM\SOFTWARE\Microsoft\Windows Defender` имеет ACL, где `BUILTIN\Administrators` получает только чтение/выполнение. Запись разрешена `SYSTEM`, `TrustedInstaller` и `WinDefend`. Поэтому `Remove-ItemProperty`/`Set-ItemProperty` от администратора возвращают «Доступ к реестру запрещён».
3. `DisableAntiSpyware=1` и `DisableAntiVirus=1` в этом ключе заставляют `MsMpEng.exe` завершаться сразу после старта.
4. Драйверы `WdFilter` и `WdBoot` могут быть в состоянии `Start=4` (disabled). Без `WdFilter` real-time protection не поднимется, а `WdBoot` — загрузочный, его изменение применяется только после полной перезагрузки.

Поэтому правка выполняется одноразовой задачей от `SYSTEM`: у неё есть полный доступ к ключу.

### 7.3 Выполнение

```powershell
.\scripts\03-Enable-Defender.ps1 -ExclusionPath 'C:\project','C:\Users\<user>\AppData\Local\npm-cache'
```

Скрипт:
1. снимает политику;
2. создаёт временную задачу `OSPlaybook-EnableDefender` от SYSTEM;
3. внутри SYSTEM-сессии удаляет `DisableAntiSpyware`/`DisableAntiVirus`, выставляет старт драйверов, запускает `WinDefend`, ждёт и прописывает исключения;
4. удаляет задачу и печатает лог.

### 7.4 Исключения

Минимум для машины разработчика:

```
C:\project
%LOCALAPPDATA%\npm-cache
%USERPROFILE%\.cache
%LOCALAPPDATA%\ms-playwright
%LOCALAPPDATA%\Temp
```

Не добавляйте в исключения целые диски и `%USERPROFILE%` целиком — это сводит защиту к нулю.

### 7.5 Проверка

```powershell
Get-MpComputerStatus | Select AMServiceEnabled, RealTimeProtectionEnabled, AMRunningMode
Get-MpPreference | Select -ExpandProperty ExclusionPath
```

Ожидается: `True / True / Normal`, сигнатуры обновляются автоматически.

### 7.6 Нюансы

- `WinDefend` в состоянии `StartType = Manual` — это **норма** для Windows 11 (trigger-start). Не пытайтесь вернуть `Automatic`: Defender сам переписывает значение обратно.
- `WdBoot` может не загрузиться при выключенном Secure Boot (событие 7026, ошибка 31). На защиту это не влияет: `WdFilter` работает, режим `Normal`.
- Если после включения служба сразу останавливается — проверьте, не остался ли `DisableAntiSpyware` в ключе продукта (пункт 7.2) и не включён ли `TamperProtection`.
- Не удаляйте `HKLM\SOFTWARE\Policies\Microsoft\Windows Defender\Policy Manager`, если им управляет Intune.

---

## 8. Фаза 3. Автозагрузка

### 8.1 Где искать

| Место | Команда |
|---|---|
| Run (пользователь) | `Get-ItemProperty 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'` |
| Run (машина) | `Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'` |
| Все источники | `Get-CimInstance Win32_StartupCommand` |
| Отключено пользователем | `...\Explorer\StartupApproved\Run` |
| Задачи | `Get-ScheduledTask \| ? TaskPath -notlike '\Microsoft\*'` |
| Службы | `Get-CimInstance Win32_Service \| ? StartMode -eq 'Auto'` |

### 8.2 Почему удаления значения Run недостаточно

Приложение при следующем запуске прописывает себя заново. Диспетчер задач хранит состояние в `StartupApproved\Run`: 12-байтное значение, первый байт `02` — включено, `03` — отключено. Если удалить Run-значение, но не поставить метку `03`, приложение вернётся. Комбинация «удалить значение + поставить `03`» устойчива: запись можно добавлять сколько угодно, автозапуск останется выключенным.

### 8.3 Почему нельзя отключать задачи по имени

Реальный пример: задача с «безобидным» именем запускала пользовательский скрипт из личного каталога. Всегда смотрите действие:

```powershell
Get-ScheduledTask -TaskName '<имя>' | ForEach-Object { $_.Actions | Format-List Execute, Arguments }
```

### 8.4 Почему задачи возвращаются

У некоторых приложений (Яндекс.Браузер) есть задача-«восстановитель», которая при загрузке включает остальные задачи. Порядок: сначала отключить восстановитель, затем остальные, затем остановить и перевести в `Manual` службу обновления. Иначе цикл повторится после каждой перезагрузки.

### 8.5 Выполнение

```powershell
.\scripts\04-Clean-Autostart.ps1 `
  -RunValue '<ЗначениеRun1>','<ЗначениеRun2>' `
  -TaskName '<ИмяЗадачи1>','<ИмяЗадачи2>'
```

Скрипт делает бэкап Run/StartupApproved и XML задач, затем отключает выбранное. Проверка — повторный запуск `01-Diagnose.ps1`.

### 8.6 Что оставлять

- аудио (`RtkAudUService`), SecurityHealth, синхронизацию (Google Drive, OneDrive), если она нужна;
- задачи обновления браузера/Edge/Google — по желанию;
- пользовательские скрипты (проверив их действие).

### 8.7 Откат

```powershell
.\scripts\04-Clean-Autostart.ps1 -Revert -RunValue ... -TaskName ...
```

Значения Run восстанавливаются импортом `.reg` из папки бэкапа.

---

## 9. Фаза 4. Удаление bloatware

### 9.1 Найти деинсталлятор

```powershell
$paths = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
         'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
         'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
Get-ItemProperty $paths | Where-Object DisplayName |
  Select DisplayName, DisplayVersion, UninstallString, QuietUninstallString
```

### 9.2 Тихий запуск

| Тип установщика | Ключи |
|---|---|
| Inno Setup (`unins000.exe`, `_is1`) | `/VERYSILENT /SUPPRESSMSGBOXES /NORESTART` |
| MSI | `msiexec /x {GUID} /qn /norestart` |

```powershell
Start-Process -FilePath 'C:\Program Files\Vendor\unins000.exe' `
  -ArgumentList '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART' -Wait
```

### 9.3 После удаления

1. Проверить, что записи в Uninstall и службы исчезли.
2. Удалить осиротевшие задачи (`Get-ScheduledTask`).
3. Проверить остатки каталогов **перед** удалением: в папке может лежать пользовательские данные. Реальный случай: `...\Programs\Zoom` содержала ярлыки игр, а не файлы Zoom.
4. Перепроверить Defender — некоторые деинсталляторы «оптимизаторов» пытаются вернуть свои настройки.

### 9.4 Компромисс

Вендорная утилита (например, диспетчер производителя ноутбука) может быть единственным каналом обновления драйверов/BIOS. После её удаления обновления — только с сайта производителя.

---

## 10. Фаза 5. Сеть и имя компьютера

### 10.1 Диагностика конфликта

```powershell
Get-WinEvent -FilterHashtable @{LogName='System'; Id=4321; StartTime=(Get-Date).AddDays(-7)}
nbtstat -A <IP-конкурента>
arp -a <IP-конкурента>
```

Событие 4321 означает: «имя не удалось зарегистрировать, его удерживает другой узел».

### 10.2 Три стратегии

| Стратегия | Плюсы | Минусы |
|---|---|---|
| Переименовать этот ПК | устраняет причину, имя снова резолвится | ломает пути `\\ИМЯ`, риск для лицензий 1С, нужна перезагрузка |
| Переименовать чужой ПК | этот ПК сохраняет имя | нужен доступ к тому ПК |
| Отключить NetBIOS на адаптере | быстро, без перезагрузки ПК | имя перестаёт резолвиться по NetBIOS, ошибка в журнале исчезает, но конфликт остаётся |

Отключение NetBIOS:

```powershell
$ad = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' -and $_.InterfaceDescription -match 'Wireless' }
$g  = $ad.InterfaceGuid.Trim('{','}')
Set-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\NetBT\Parameters\Interfaces\Tcpip_$g" -Name NetbiosOptions -Value 2 -Type DWord
```

`NetbiosOptions`: `0` — из DHCP, `1` — включён, `2` — выключен.

### 10.3 Переименование и 1С

Перед переименованием проверьте, не привязана ли программная лицензия 1С к имени компьютера. Аппаратные ключи (HASP) не затрагиваются. Откат — до перезагрузки:

```powershell
Rename-Computer -NewName <старое_имя> -Force
```

Подчёркивание в имени (`My_PC`) Windows принимает, но DNS-хостнеймы по RFC его не допускают: динамическая регистрация в DNS может не пройти, локально NetBIOS/LLMNR работают. Надёжнее дефис (`My-PC`).

После переименования замените пути `\\СТАРОЕ_ИМЯ\...` в ярлыках, 1С и скриптах.

---

## 11. Фаза 6. Обновления Windows

### 11.1 Почему «обновления не приходят»

Проверьте политику и службу:

```powershell
Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
Get-Service wuauserv, UsoSvc, BITS
```

Твикеры выставляют `DisableWUfBSafeguards=1`, `TargetReleaseVersion`, отложенные периоды. На LTSC обновления выходят реже, но ежемесячные патчи безопасности должны приходить.

### 11.2 Поиск без установки

```powershell
$s  = New-Object -ComObject Microsoft.Update.Session
$sr = $s.CreateUpdateSearcher()
$r  = $sr.Search("IsInstalled=0 and Type='Software' and IsHidden=0")
$r.Updates | Select Title
```

### 11.3 Установка

Скачивание и установка занимают 10–40 минут на 4-ядерном CPU. Готовый скрипт:

```powershell
.\scripts\06-Install-Updates.ps1
```

Внутри — поиск, скачивание и установка с логом в `C:\ProgramData\OSPlaybook\wu-install.log`. Ключ `-Reboot` перезагрузит машину, но только если установщик сообщил о необходимости и установка прошла успешно.

**Не перезагружайте машину, пока установка не завершилась** — прервётся на середине.

### 11.4 Проверка

```powershell
Get-CimInstance Win32_QuickFixEngineering | Sort InstalledOn -Descending | Select -First 5
[Environment]::OSVersion.Version
```

---

## 12. Фаза 7. Приёмка

```powershell
.\scripts\05-Test-Configuration.ps1 -MinPagefileMB 4096 -RequireDefender
```

Скрипт печатает таблицу PASS/WARN/FAIL. Код возврата 1 — есть FAIL.

Ручные проверки:

| Проверка | Ожидание |
|---|---|
| `Get-MpComputerStatus` | AMService=True, RealTime=True, Normal |
| `Get-MpPreference` | ваши исключения |
| `Get-CimInstance Win32_PageFileUsage` | AllocatedBaseSize ≥ 4096 |
| Лимит памяти | RAM + 4 ГБ и больше |
| `Get-ScheduledTask` (вне Microsoft) | лишние Disabled |
| Run | только нужное |
| События 4321 за сутки | 0 |
| `Get-Volume C` | свободно > 15% |
| SMART | Healthy, Wear < 80 |

---

## 13. Откат

Все изменения обратимы, бэкапы лежат в `C:\ProgramData\OSPlaybook\backup-<timestamp>` и в каталоге, куда вы складывали `.reg`-файлы.

| Что | Как откатить |
|---|---|
| Подкачка | `02-Set-Pagefile.ps1 -Revert` |
| Defender | импорт `defender-policy.reg`, вернуть `Start=4` драйверам, перезагрузка |
| Run | импорт `hkcu-run.reg` |
| StartupApproved | импорт `startup-approved.reg` |
| Задачи | `Register-ScheduledTask -Xml (Get-Content task_*.xml -Raw)` |
| Имя ПК | `Rename-Computer -NewName <старое> -Force` |
| NetBIOS | `NetbiosOptions` = `0` или `1` |

---

## 14. Грабли (проверено на практике)

1. **ACL ключа Defender.** Администратор не может писать в `HKLM\SOFTWARE\Microsoft\Windows Defender` — только SYSTEM/TrustedInstaller/WinDefend. Отсюда одноразовая задача от SYSTEM.
2. **`Remove-Item` без `-ErrorAction Stop`** молча не срабатывает. Всегда проверяйте результат чтением значения обратно.
3. **`Start-Service WinDefend` ничего не говорит о причине.** Смотрите `sc.exe start` и журнал System (7000/7023/7026).
4. **`WinDefend StartType=Manual` — норма.** Defender сам меняет Auto → Manual при старте.
5. **Boot-драйверы применяются только после полной перезагрузки.** «Быстрый запуск» может скрыть эффект — используйте «Перезагрузка», а не «Завершение работы».
6. **События 129/153 — не диск.** Это VBS/гипервизор.
7. **Удаление Run не отключает автозапуск.** Нужна метка в `StartupApproved`.
8. **Задачи возвращаются.** Ищите задачу-восстановитель и службу обновления приложения.
9. **Отключение задачи по имени опасно.** Задача с именем, похожим на компонент приложения, оказалась пользовательским скриптом.
10. **Остатки каталогов могут содержать данные пользователя.** Проверяйте содержимое перед `Remove-Item -Recurse`.
11. **Переименование ПК может сломать лицензию 1С.** Сначала выясните тип лицензии.
12. **Подчёркивание в имени ПК** ломает DNS-регистрацию, хотя Windows его принимает.
13. **Не перезагружайте во время установки обновлений.**
14. **Регулятор «оптимизатор» может стоять службой-сторожем.** Отключайте её до правок, иначе настройки вернутся.
15. **16 ГБ RAM не апгрейдятся, если память распаяна.** Проверьте `Win32_PhysicalMemory` до обещаний «добавим памяти».

---

## Приложение A. Эталонный прогон

### A.1 До / после

| Метрика | До | После |
|---|---|---|
| Defender | выключен (политика + службы + драйверы + ключ продукта) | AMService=True, RealTime=True, Normal |
| Подкачка | 1024 / 2048 МБ | 4096 / 12288 МБ |
| Лимит памяти | 16.7 ГБ | 19.7 ГБ |
| Свободно RAM | 7.0 ГБ | 7.8–9.3 ГБ |
| Процессов | 203 | 166–171 |
| Автозагрузка | клиент магазина, браузер, утилита диктовки, служба производителя | синхронизация, утилита диктовки, пользовательский скрипт |
| Задачи вне Microsoft | 13 включённых | 3 включённых (Edge ×2, Google Updater) |
| NetBIOS 4321 | 20 событий / 7 дней | 0 после переименования ПК |
| Обновления | последний патч 10.2025 | 4 патча установлены, сборка 26200.9974 |

### A.2 Что было отключено на эталоне

```
Задачи: обслуживание оптимизатора реестра (2),
        апдейтер утилиты скриншотов (2),
        апдейтер старой версии клиента видеосвязи (1),
        обновление/восстановление браузера (3)
Run:    клиент магазина игр, автозапуск браузера, утилита диктовки
Службы: служба-«сторож» оптимизатора, служба обновления браузера → Manual
Удалено: оптимизатор реестра, вендорная утилита, устаревшая версия клиента видеосвязи
```

Состояние эталонной машины: переименование применено, сборка 26200.9974, конфликтов NetBIOS нет, Defender в режиме Normal.

---

## Приложение B. Чек-лист на новую машину

| # | Шаг | Команда | Ожидание | ✓ |
|---|-----|---------|----------|---|
| 1 | Инвентаризация | `01-Diagnose.ps1` | отчёт сохранён | |
| 2 | Точка восстановления | `Checkpoint-Computer` | создана | |
| 3 | Подкачка | `02-Set-Pagefile.ps1` | 4096/12288 | |
| 4 | Defender | `03-Enable-Defender.ps1` | True/True/Normal | |
| 5 | Исключения | `Get-MpPreference` | 5 путей | |
| 6 | Автозагрузка | `04-Clean-Autostart.ps1` | только нужное | |
| 7 | Задачи | `Get-ScheduledTask` | лишние Disabled | |
| 8 | Bloatware | деинсталляция | записи исчезли | |
| 9 | Сеть | `nbtstat -A` | конфликта нет | |
| 10 | Лицензия 1С | запуск базы | работает | |
| 11 | Обновления | COM-поиск | 0 в очереди | |
| 12 | Перезагрузка | — | имя/подкачка применились | |
| 13 | Приёмка | `05-Test-Configuration.ps1` | нет FAIL | |

---

*Документ составлен по результатам реального прогона. Все команды проверены на Windows 11 IoT Enterprise LTSC 26200, PowerShell 5.1.*
