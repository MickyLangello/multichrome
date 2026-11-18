<#
.SYNOPSIS
Скрипт для мульти-профильного запуска Chrome с сохранением режима, времени запуска, созданием ярлыков и очисткой кэша.
#>

$BaseProfileDir = "C:\ChromeProfiles"

if (-not (Test-Path -Path $BaseProfileDir)) {
    New-Item -ItemType Directory -Path $BaseProfileDir | Out-Null
}

# Служебная папка для иконок: "<Имя сайта из $Sites>.ico"
$IconsDir = Join-Path -Path $BaseProfileDir -ChildPath ".icons"
if (-not (Test-Path -Path $IconsDir)) {
    New-Item -ItemType Directory -Path $IconsDir | Out-Null
}

# Папки кэша, которые Chrome безопасно пересоздаёт сам (логины, куки, история, закладки НЕ затрагиваются)
# Относительно корня профиля (--user-data-dir)
$RootCacheTargets = @(
    "GrShaderCache",
    "ShaderCache",
    "GraphiteDawnCache",
    "GPUPersistentCache",
    "component_crx_cache",
    "extensions_crx_cache",
    "Crashpad\reports",
    "Snapshots"
    # "optimization_guide_model_store"   # Раскомментируйте, чтобы чистить и ML-модели (.tflite), Chrome скачает их заново
)
# Относительно подпапки профиля Chrome (Default, Profile 1, ...)
$ProfileCacheTargets = @(
    "Cache",
    "Code Cache",
    "GPUCache",
    "DawnWebGPUCache",
    "DawnGraphiteCache",
    "Media Cache",
    "Service Worker\CacheStorage",
    "Service Worker\ScriptCache"
)

# Поиск chrome.exe (нужен полный путь для ярлыка)
function Get-ChromePath {
    $RegKeys = @(
        "HKCU:\Software\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe",
        "HKLM:\Software\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe"
    )
    foreach ($Key in $RegKeys) {
        $Path = (Get-ItemProperty -Path $Key -ErrorAction SilentlyContinue).'(default)'
        if ($Path -and (Test-Path -Path $Path)) { return $Path }
    }
    $Candidates = @(
        "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
        "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
        "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe"
    )
    foreach ($C in $Candidates) {
        if (Test-Path -Path $C) { return $C }
    }
    return $null
}

# Создание ярлыка на рабочем столе с текущими параметрами запуска
function New-ChromeShortcut {
    param(
        [string]$SiteName,
        [string]$ProfileName,
        [string]$Arguments
    )

    $ChromePath = Get-ChromePath
    if (-not $ChromePath) {
        Write-Host "Не удалось найти chrome.exe. Ярлык не создан." -ForegroundColor Red
        return
    }

    # Иконка: "<Имя сайта>.ico" в .icons, иначе иконка Chrome
    $IconFile = Join-Path -Path $IconsDir -ChildPath "$SiteName.ico"
    if (Test-Path -Path $IconFile) {
        $IconLocation = "$IconFile,0"
        $IconInfo = "иконка: $SiteName.ico"
    } else {
        $IconLocation = "$ChromePath,0"
        $IconInfo = "иконка Chrome (файл '$SiteName.ico' не найден в $IconsDir)"
    }

    # Имя ярлыка без запрещённых символов
    $BadChars = [System.IO.Path]::GetInvalidFileNameChars()
    $LinkName = "$SiteName - $ProfileName"
    foreach ($Ch in $BadChars) { $LinkName = $LinkName.Replace([string]$Ch, "_") }

    try {
        $Desktop = [Environment]::GetFolderPath("Desktop")
        $LinkPath = Join-Path -Path $Desktop -ChildPath "$LinkName.lnk"

        $Shell = New-Object -ComObject WScript.Shell
        $Shortcut = $Shell.CreateShortcut($LinkPath)
        $Shortcut.TargetPath = $ChromePath
        $Shortcut.Arguments = $Arguments
        $Shortcut.WorkingDirectory = Split-Path -Path $ChromePath
        $Shortcut.IconLocation = $IconLocation
        $Shortcut.Description = "$SiteName ($ProfileName)"
        $Shortcut.Save()
        [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($Shell)

        Write-Host "Ярлык создан: $LinkPath" -ForegroundColor Green
        Write-Host "($IconInfo)" -ForegroundColor DarkGray
    } catch {
        Write-Host "Ошибка при создании ярлыка: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# Формирование аргументов Chrome
function Get-ChromeArgs {
    param([string]$ProfilePath, [string]$Url, [string]$Mode)

    $Result = @(
        "--user-data-dir=`"$ProfilePath`"",
        "--no-first-run",
        "--no-default-browser-check"
    )
    if ($Mode -eq 'app') {
        $Result += "--app=`"$Url`""
    } else {
        $Result += "`"$Url`""
    }
    return $Result
}

# Размер папки в байтах (0, если папки нет)
function Get-FolderSize {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return [long]0 }
    $Sum = (Get-ChildItem -LiteralPath $Path -Recurse -Force -File -ErrorAction SilentlyContinue |
        Measure-Object -Property Length -Sum).Sum
    if ($null -eq $Sum) { return [long]0 }
    return [long]$Sum
}

# Человекочитаемый размер
function Format-FileSize {
    param([long]$Bytes)

    if ($Bytes -ge 1GB) { return ("{0:N2} ГиБ" -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ("{0:N2} МиБ" -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ("{0:N2} КиБ" -f ($Bytes / 1KB)) }
    return "$Bytes байт"
}

# Запущен ли сейчас Chrome с этим профилем (иначе файлы кэша заблокированы)
function Test-ProfileInUse {
    param([string]$ProfilePath)

    $Pattern = '--user-data-dir="?' + [regex]::Escape($ProfilePath) + '"?(\s|$)'
    $Procs = Get-CimInstance -ClassName Win32_Process -Filter "Name = 'chrome.exe'" -ErrorAction SilentlyContinue
    foreach ($Proc in $Procs) {
        if ($Proc.CommandLine -and $Proc.CommandLine -match $Pattern) { return $true }
    }
    return $false
}

# Список существующих папок кэша для профиля
function Get-CacheTargets {
    param([string]$ProfilePath)

    $Found = @()
    foreach ($Rel in $RootCacheTargets) {
        $Full = Join-Path -Path $ProfilePath -ChildPath $Rel
        if (Test-Path -LiteralPath $Full) { $Found += $Full }
    }

    # Подпапки профилей Chrome (Default, Profile 1, ...) определяем по наличию файла Preferences
    $ChromeProfiles = Get-ChildItem -LiteralPath $ProfilePath -Directory -ErrorAction SilentlyContinue |
        Where-Object { Test-Path -LiteralPath (Join-Path -Path $_.FullName -ChildPath "Preferences") }
    foreach ($Sub in $ChromeProfiles) {
        foreach ($Rel in $ProfileCacheTargets) {
            $Full = Join-Path -Path $Sub.FullName -ChildPath $Rel
            if (Test-Path -LiteralPath $Full) { $Found += $Full }
        }
    }
    return $Found
}

# Очистка кэша во всех профилях
function Clear-AllChromeCache {
    Clear-Host
    Write-Host "=== Очистка кэша Chrome во всех профилях ===" -ForegroundColor Cyan
    Write-Host "Папка профилей: $BaseProfileDir" -ForegroundColor DarkGray
    Write-Host "Логины, куки, история и закладки не затрагиваются." -ForegroundColor DarkGray
    Write-Host ""

    $Profiles = @(Get-ChildItem -Path $BaseProfileDir -Directory |
        Where-Object { -not $_.Name.StartsWith('.') })
    if ($Profiles.Count -eq 0) {
        Write-Host "Профили не найдены." -ForegroundColor Yellow
        [void](Read-Host "Нажмите Enter для возврата")
        return
    }

    # Предварительный анализ: что можно очистить и сколько это займёт места
    Write-Host "Анализ профилей..." -ForegroundColor DarkGray
    $Plan = @()
    $MaxNameLen = 20
    foreach ($Prof in $Profiles) {
        $InUse = Test-ProfileInUse -ProfilePath $Prof.FullName
        $Targets = @(Get-CacheTargets -ProfilePath $Prof.FullName)
        $Size = [long]0
        if (-not $InUse) {
            foreach ($T in $Targets) { $Size += Get-FolderSize -Path $T }
        }
        if ($Prof.Name.Length -gt $MaxNameLen) { $MaxNameLen = $Prof.Name.Length }
        $Plan += [pscustomobject]@{ Name = $Prof.Name; Targets = $Targets; InUse = $InUse; Size = $Size }
    }

    Write-Host ""
    $TotalSize = [long]0
    foreach ($Item in $Plan) {
        $NameStr = $Item.Name.PadRight($MaxNameLen + 2)
        if ($Item.InUse) {
            Write-Host ("{0} | Chrome запущен, будет пропущен" -f $NameStr) -ForegroundColor Red
        } else {
            Write-Host ("{0} | {1}" -f $NameStr, (Format-FileSize -Bytes $Item.Size)) -ForegroundColor Yellow
            $TotalSize += $Item.Size
        }
    }
    Write-Host ""
    Write-Host ("Будет освобождено: {0}" -f (Format-FileSize -Bytes $TotalSize)) -ForegroundColor White

    if ($TotalSize -eq 0) {
        Write-Host "Очищать нечего." -ForegroundColor Green
        [void](Read-Host "Нажмите Enter для возврата")
        return
    }

    Write-Host "[1] ОЧИСТИТЬ" -ForegroundColor White
    Write-Host "[0] Отмена" -ForegroundColor Red
    $Confirm = Read-Host "Выберите действие (Enter = 1)"
    if ($Confirm -eq "") { $Confirm = "1" }
    if ($Confirm -ne '1') { return }

    # Удаление
    Write-Host ""
    $TotalFreed = [long]0
    foreach ($Item in $Plan) {
        if ($Item.InUse) {
            Write-Host "Пропущен (Chrome запущен): $($Item.Name)" -ForegroundColor Red
            continue
        }
        $Before = $Item.Size
        foreach ($T in $Item.Targets) {
            Remove-Item -LiteralPath $T -Recurse -Force -ErrorAction SilentlyContinue
        }
        $After = [long]0
        foreach ($T in $Item.Targets) { $After += Get-FolderSize -Path $T }
        $Freed = $Before - $After
        $TotalFreed += $Freed
        Write-Host ("Очищен: {0} ({1})" -f $Item.Name, (Format-FileSize -Bytes $Freed)) -ForegroundColor Green
    }

    Write-Host ""
    Write-Host ("Готово! Всего освобождено: {0}" -f (Format-FileSize -Bytes $TotalFreed)) -ForegroundColor Cyan
    [void](Read-Host "Нажмите Enter для возврата")
}

$Sites = @(
    [pscustomobject]@{ Name = "Claude AI"; Url = "https://claude.ai" }
    [pscustomobject]@{ Name = "Пустая страница"; Url = "chrome://newtab/" }
)

# Главный цикл скрипта
:MainLoop while ($true) {
    Clear-Host
    Write-Host "=== Мульти-профильный запуск Chrome ===" -ForegroundColor Cyan
    Write-Host "Папка профилей: $BaseProfileDir" -ForegroundColor DarkGray
    Write-Host ""

    # --- 1. ВЫБОР САЙТА ---
    Write-Host "Выберите сайт для запуска:" -ForegroundColor White
    for ($i = 0; $i -lt $Sites.Count; $i++) {
        Write-Host ("[{0}] {1}" -f ($i + 1), $Sites[$i].Name)
    }
    Write-Host "[-1] Очистить кэш во всех профилях" -ForegroundColor Magenta
    Write-Host "[0] Выход из скрипта" -ForegroundColor Red

    $SiteValid = $false
    $SelectedUrl = ""
    $SelectedSiteName = ""
    while (-not $SiteValid) {
        $SiteInput = Read-Host "Введите номер сайта (Enter = 1)"
        if ($SiteInput -eq "") { $SiteInput = "1" }

        if ($SiteInput -eq '0') {
            Write-Host "Завершение работы..." -ForegroundColor DarkGray
            exit
        }
        if ($SiteInput -eq '-1') {
            Clear-AllChromeCache
            continue MainLoop
        }
        $SiteNum = 0
        if ([int]::TryParse($SiteInput, [ref]$SiteNum) -and $SiteNum -ge 1 -and $SiteNum -le $Sites.Count) {
            $SelectedUrl = $Sites[$SiteNum - 1].Url
            $SelectedSiteName = $Sites[$SiteNum - 1].Name
            $SiteValid = $true
        } else {
            Write-Host "Неверный ввод." -ForegroundColor Red
        }
    }

    Write-Host ""

    # --- 2. ЧТЕНИЕ И ВЫБОР ПРОФИЛЯ ---
    $ExistingProfiles = Get-ChildItem -Path $BaseProfileDir -Directory |
        Where-Object { -not $_.Name.StartsWith('.') } |
        Select-Object -ExpandProperty Name
    $ProfileData = @()
    $MaxNameLen = 20 # Минимальная ширина столбца для имен

    # Считываем сохраненные настройки и время для каждого профиля
    foreach ($Prof in $ExistingProfiles) {
        $ModeFile = Join-Path -Path $BaseProfileDir -ChildPath "$Prof\launch_mode.txt"
        $Mode = "normal"
        $LastLaunch = "Никогда"
        
        if (Test-Path -Path $ModeFile) {
            # Читаем файл как массив строк
            $Lines = @(Get-Content -Path $ModeFile)
            if ($Lines.Count -ge 1 -and $Lines[0].Trim() -ne "") { $Mode = $Lines[0].Trim() }
            if ($Lines.Count -ge 2 -and $Lines[1].Trim() -ne "") { $LastLaunch = $Lines[1].Trim() }
        }
        
        if ($Prof.Length -gt $MaxNameLen) { $MaxNameLen = $Prof.Length }
        $ProfileData += [pscustomobject]@{ Name = $Prof; Mode = $Mode; LastLaunch = $LastLaunch }
    }

    Write-Host "Выберите профиль:" -ForegroundColor White
    $Index = 1
    foreach ($P in $ProfileData) {
        $Color = if ($P.Mode -eq 'app') { 'Green' } else { 'Yellow' }
        
        $IndexStr = "[$Index]".PadRight(5)
        $NameStr = $P.Name.PadRight($MaxNameLen + 2)
        
        Write-Host ("{0} {1} | {2}" -f $IndexStr, $NameStr, $P.LastLaunch) -ForegroundColor $Color
        $Index++
    }
    
    $NewProfileIndex = $Index
    $NewIndexStr = "[$NewProfileIndex]".PadRight(5)
    $ZeroIndexStr = "[0]".PadRight(5)
    
    Write-Host ("{0} + СОЗДАТЬ НОВЫЙ ПРОФИЛЬ" -f $NewIndexStr) -ForegroundColor Cyan
    Write-Host ("{0} Назад к выбору сайта" -f $ZeroIndexStr) -ForegroundColor Red

    $ProfileValid = $false
    $SelectedProfile = ""
    $SelectedMode = ""
    $SelectedLastLaunch = ""

    while (-not $ProfileValid) {
        $ProfileInput = Read-Host "Введите номер профиля (Enter = 1)"
        if ($ProfileInput -eq "") { $ProfileInput = "1" }
        
        if ($ProfileInput -eq '0') {
            continue MainLoop
        }

        $InputInt = 0
        if ([int]::TryParse($ProfileInput, [ref]$InputInt) -and $InputInt -ge 1 -and $InputInt -le $NewProfileIndex) {
            
            # --- СОЗДАНИЕ НОВОГО ПРОФИЛЯ ---
            if ($InputInt -eq $NewProfileIndex) {
                $NewName = Read-Host "Введите имя нового профиля"
                if (-not [string]::IsNullOrWhiteSpace($NewName) -and $NewName.IndexOfAny([System.IO.Path]::GetInvalidFileNameChars()) -lt 0) {
                    $SelectedProfile = $NewName
                    $SelectedMode = 'normal'
                    $SelectedLastLaunch = 'Никогда'
                    $ProfileValid = $true
                } else {
                    Write-Host "Недопустимое имя. Попробуйте снова." -ForegroundColor Red
                }
            } 
            # --- ВЫБОР СУЩЕСТВУЮЩЕГО ПРОФИЛЯ ---
            else {
                $SelectedProfile = $ProfileData[$InputInt - 1].Name
                $SelectedMode = $ProfileData[$InputInt - 1].Mode
                $SelectedLastLaunch = $ProfileData[$InputInt - 1].LastLaunch
                $ProfileValid = $true
            }
        } else {
            Write-Host "Неверный ввод." -ForegroundColor Red
        }
    }

    # --- 3. ПОДМЕНЮ ДЛЯ ПРОФИЛЯ (Запуск или Изменение) ---
    $ProfilePath = Join-Path -Path $BaseProfileDir -ChildPath $SelectedProfile
    $ModeFile = Join-Path -Path $ProfilePath -ChildPath "launch_mode.txt"

    # Если папки еще нет (новый профиль), создаем её и базовый файл
    if (-not (Test-Path -Path $ProfilePath)) {
        New-Item -ItemType Directory -Path $ProfilePath | Out-Null
        Set-Content -Path $ModeFile -Value @($SelectedMode, $SelectedLastLaunch)
    }

    $ReadyToLaunch = $false
    while (-not $ReadyToLaunch) {
        Write-Host "`n--- Настройка запуска ---" -ForegroundColor Cyan
        Write-Host "Сайт: $SelectedSiteName"
        Write-Host "Профиль: $SelectedProfile"
        
        $CurrentColor = if ($SelectedMode -eq 'app') { 'Green' } else { 'Yellow' }
        $CurrentModeText = if ($SelectedMode -eq 'app') { 'Как приложение (Без вкладок)' } else { 'Обычный (С вкладками)' }
        Write-Host "Текущий режим: $CurrentModeText" -ForegroundColor $CurrentColor

        Write-Host "[1] ЗАПУСТИТЬ" -ForegroundColor White
        Write-Host "[2] Изменить режим запуска" -ForegroundColor DarkGray
        Write-Host "[3] Создать ярлык на рабочем столе" -ForegroundColor DarkGray
        Write-Host "[0] Назад в главное меню" -ForegroundColor Red

        $Action = Read-Host "Выберите действие (Enter = 1)"
        if ($Action -eq "") { $Action = "1" }
        
        if ($Action -eq '1') {
            $ReadyToLaunch = $true
            
            $SelectedLastLaunch = Get-Date -Format "dd.MM.yyyy HH:mm:ss"
            Set-Content -Path $ModeFile -Value @($SelectedMode, $SelectedLastLaunch)
            
        } elseif ($Action -eq '2') {
            # Меняем режим на противоположный и сохраняем со старым временем
            $SelectedMode = if ($SelectedMode -eq 'app') { 'normal' } else { 'app' }
            Set-Content -Path $ModeFile -Value @($SelectedMode, $SelectedLastLaunch)
            Write-Host "Режим изменен и сохранен!" -ForegroundColor Green
        } elseif ($Action -eq '3') {
            $ShortcutArgs = (Get-ChromeArgs -ProfilePath $ProfilePath -Url $SelectedUrl -Mode $SelectedMode) -join ' '
            New-ChromeShortcut -SiteName $SelectedSiteName -ProfileName $SelectedProfile -Arguments $ShortcutArgs
        } elseif ($Action -eq '0') {
            continue MainLoop
        }
    }

    # --- 4. ЗАПУСК CHROME ---
    Write-Host "`nЗапускаем Chrome..." -ForegroundColor Cyan

    $ChromeArgs = Get-ChromeArgs -ProfilePath $ProfilePath -Url $SelectedUrl -Mode $SelectedMode

    try {
        Start-Process -FilePath "chrome.exe" -ArgumentList $ChromeArgs
        Write-Host "Готово! Возврат в меню через 2 секунды..." -ForegroundColor Green
    } catch {
        Write-Host "Ошибка при запуске Chrome." -ForegroundColor Red
    }

    Start-Sleep -Seconds 2
}
