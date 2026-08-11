#!/usr/bin/env bash

# ==============================================================================
# СИСТЕМНЫЕ НАСТРОЙКИ
# ==============================================================================
BASE_PROFILE_DIR="$HOME/ChromeProfiles"

# Определение исполняемого файла Chrome в зависимости от ОС
if command -v google-chrome &> /dev/null; then
    CHROME_CMD="google-chrome"
elif command -v google-chrome-stable &> /dev/null; then
    CHROME_CMD="google-chrome-stable"
elif command -v chromium &> /dev/null; then
    CHROME_CMD="chromium"
elif [[ "$OSTYPE" == "darwin"* ]]; then
    CHROME_CMD="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
else
    CHROME_CMD="google-chrome"
fi

# ==============================================================================
# ЦВЕТА ДЛЯ ВЫВОДА
# ==============================================================================
CYAN='\033[0;36m'
DARKGRAY='\033[1;30m'
WHITE='\033[1;37m'
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# ==============================================================================
# ДАННЫЕ САЙТОВ
# ==============================================================================
SITE_NAMES=("Claude AI" "Пустая страница")
SITE_URLS=("https://claude.ai" "about:blank")

# Создаем базовую директорию, если её нет
mkdir -p "$BASE_PROFILE_DIR"

while true; do
    clear
    echo -e "${CYAN}=== Мульти-профильный запуск Chrome ===${NC}"
    echo -e "${DARKGRAY}Папка профилей: $BASE_PROFILE_DIR${NC}\n"

    # --- 1. ВЫБОР САЙТА ---
    echo -e "${WHITE}Выберите сайт для запуска:${NC}"
    for i in "${!SITE_NAMES[@]}"; do
        echo "[$((i+1))] ${SITE_NAMES[$i]}"
    done
    echo -e "${RED}[0] Выход из скрипта${NC}"

    SELECTED_URL=""
    while true; do
        read -p "Введите номер сайта (Enter = 1): " site_input
        [[ -z "$site_input" ]] && site_input=1

        if [[ "$site_input" == "0" ]]; then
            echo -e "${DARKGRAY}Завершение работы...${NC}"
            exit 0
        fi

        if [[ "$site_input" =~ ^[0-9]+$ ]] && [ "$site_input" -ge 1 ] && [ "$site_input" -le "${#SITE_NAMES[@]}" ]; then
            SELECTED_URL="${SITE_URLS[$((site_input-1))]}"
            break
        else
            echo -e "${RED}Неверный ввод.${NC}"
        fi
    done

    echo ""

    # --- 2. ЧТЕНИЕ И ВЫБОР ПРОФИЛЯ ---
    # Считываем существующие профили
    PROFILES=()
    if [ -d "$BASE_PROFILE_DIR" ]; then
        while IFS= read -r -d '' dir; do
            PROFILES+=("$(basename "$dir")")
        done < <(find "$BASE_PROFILE_DIR" -mindepth 1 -maxdepth 1 -type d -print0)
    fi

    MAX_NAME_LEN=20
    for prof in "${PROFILES[@]}"; do
        [[ ${#prof} -gt $MAX_NAME_LEN ]] && MAX_NAME_LEN=${#prof}
    done

    echo -e "${WHITE}Выберите профиль:${NC}"
    INDEX=1
    
    # Массивы для хранения данных профилей
    PROF_MODES=()
    PROF_LAUNCHES=()

    for prof in "${PROFILES[@]}"; do
        mode_file="$BASE_PROFILE_DIR/$prof/launch_mode.txt"
        mode="normal"
        last_launch="Никогда"

        if [[ -f "$mode_file" ]]; then
            mapfile -t lines < "$mode_file"
            [[ -n "${lines[0]}" ]] && mode="${lines[0]}"
            [[ -n "${lines[1]}" ]] && last_launch="${lines[1]}"
        fi
        
        PROF_MODES+=("$mode")
        PROF_LAUNCHES+=("$last_launch")

        if [[ "$mode" == "app" ]]; then
            COLOR=$GREEN
        else
            COLOR=$YELLOW
        fi

        printf "${COLOR}[%-3d] %-${MAX_NAME_LEN}s | %s${NC}\n" "$INDEX" "$prof" "$last_launch"
        ((INDEX++))
    done

    NEW_PROFILE_INDEX=$INDEX
    printf "${CYAN}[%-3d] + СОЗДАТЬ НОВЫЙ ПРОФИЛЬ${NC}\n" "$NEW_PROFILE_INDEX"
    printf "${RED}[%-3d] Назад к выбору сайта${NC}\n" "0"

    SELECTED_PROFILE=""
    SELECTED_MODE=""
    SELECTED_LAST_LAUNCH=""
    GO_BACK=false

    while true; do
        read -p "Введите номер профиля (Enter = 1): " prof_input
        [[ -z "$prof_input" ]] && prof_input=1

        if [[ "$prof_input" == "0" ]]; then
            GO_BACK=true
            break
        fi

        if [[ "$prof_input" =~ ^[0-9]+$ ]] && [ "$prof_input" -ge 1 ] && [ "$prof_input" -le "$NEW_PROFILE_INDEX" ]; then
            if [ "$prof_input" -eq "$NEW_PROFILE_INDEX" ]; then
                # Создание нового профиля
                read -p "Введите имя нового профиля: " new_name
                if [[ -n "$new_name" ]] && [[ "$new_name" != *"/"* ]]; then
                    SELECTED_PROFILE="$new_name"
                    SELECTED_MODE="normal"
                    SELECTED_LAST_LAUNCH="Никогда"
                    break
                else
                    echo -e "${RED}Недопустимое имя. Попробуйте снова.${NC}"
                fi
            else
                # Выбор существующего
                idx=$((prof_input-1))
                SELECTED_PROFILE="${PROFILES[$idx]}"
                SELECTED_MODE="${PROF_MODES[$idx]}"
                SELECTED_LAST_LAUNCH="${PROF_LAUNCHES[$idx]}"
                break
            fi
        else
            echo -e "${RED}Неверный ввод.${NC}"
        fi
    done

    [[ "$GO_BACK" == true ]] && continue

    # --- 3. ПОДМЕНЮ ДЛЯ ПРОФИЛЯ ---
    PROFILE_PATH="$BASE_PROFILE_DIR/$SELECTED_PROFILE"
    MODE_FILE="$PROFILE_PATH/launch_mode.txt"

    if [[ ! -d "$PROFILE_PATH" ]]; then
        mkdir -p "$PROFILE_PATH"
        printf "%s\n%s\n" "$SELECTED_MODE" "$SELECTED_LAST_LAUNCH" > "$MODE_FILE"
    fi

    READY_TO_LAUNCH=false
    while [[ "$READY_TO_LAUNCH" == false ]]; do
        echo -e "\n${CYAN}--- Настройка запуска ---${NC}"
        echo "Профиль: $SELECTED_PROFILE"

        if [[ "$SELECTED_MODE" == "app" ]]; then
            echo -e "Текущий режим: ${GREEN}Как приложение (Без вкладок)${NC}"
        else
            echo -e "Текущий режим: ${YELLOW}Обычный (С вкладками)${NC}"
        fi

        echo -e "${WHITE}[1] ЗАПУСТИТЬ${NC}"
        echo -e "${DARKGRAY}[2] Изменить режим запуска${NC}"
        echo -e "${RED}[0] Назад в главное меню${NC}"

        read -p "Выберите действие (Enter = 1): " action_input
        [[ -z "$action_input" ]] && action_input=1

        if [[ "$action_input" == "1" ]]; then
            READY_TO_LAUNCH=true
            SELECTED_LAST_LAUNCH=$(date "+%d.%m.%Y %H:%M:%S")
            printf "%s\n%s\n" "$SELECTED_MODE" "$SELECTED_LAST_LAUNCH" > "$MODE_FILE"
        elif [[ "$action_input" == "2" ]]; then
            if [[ "$SELECTED_MODE" == "app" ]]; then
                SELECTED_MODE="normal"
            else
                SELECTED_MODE="app"
            fi
            printf "%s\n%s\n" "$SELECTED_MODE" "$SELECTED_LAST_LAUNCH" > "$MODE_FILE"
            echo -e "${GREEN}Режим изменен и сохранен!${NC}"
        elif [[ "$action_input" == "0" ]]; then
            GO_BACK=true
            break
        fi
    done

    [[ "$GO_BACK" == true ]] && continue

    # --- 4. ЗАПУСК CHROME ---
    echo -e "\n${CYAN}Запускаем Chrome...${NC}"

    CHROME_ARGS=(
        "--user-data-dir=$PROFILE_PATH"
        "--no-first-run"
        "--no-default-browser-check"
    )

    if [[ "$SELECTED_MODE" == "app" ]]; then
        CHROME_ARGS+=("--app=$SELECTED_URL")
    else
        CHROME_ARGS+=("$SELECTED_URL")
    fi

    # Запуск в фоновом режиме, чтобы скрипт не блокировался
    nohup "$CHROME_CMD" "${CHROME_ARGS[@]}" >/dev/null 2>&1 &
    
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}Готово! Возврат в меню через 2 секунды...${NC}"
    else
        echo -e "${RED}Ошибка при запуске Chrome.${NC}"
    fi

    sleep 2
done
