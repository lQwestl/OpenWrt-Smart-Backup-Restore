#!/bin/sh

# ============================================================
# OpenWrt Smart Backup Script
# Поддержка OpenWrt 24.x (opkg) и OpenWrt 25.x+ (apk)
# ============================================================

# --- Цвета ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
WHITE='\033[1;37m'
CYAN='\033[0;36m'
RESET='\033[0m'

# --- Функции вывода ---
info()   { printf "${WHITE}%s${RESET}\n" "$*"; }
ok()     { printf "${GREEN}✓ %s${RESET}\n" "$*"; }
warn()   { printf "${YELLOW}[!] %s${RESET}\n" "$*"; }
err()    { printf "${RED}✗ %s${RESET}\n" "$*"; }
header() { printf "\n${CYAN}=== %s ===${RESET}\n" "$*"; }
line()   { printf "${CYAN}============================================================${RESET}\n"; }

# Директория для бэкапа
BACKUP_DIR="/root/backup"
mkdir -p $BACKUP_DIR

# Переменная для выбранного пакетного менеджера
PKG_MANAGER=""

# ============================================================
# Определение версии OpenWrt
# ============================================================
detect_openwrt_version() {
    if command -v apk >/dev/null 2>&1; then
        echo "apk"
    elif command -v opkg >/dev/null 2>&1; then
        echo "opkg"
    else
        echo "unknown"
    fi
}

select_version() {
    local detected
    detected=$(detect_openwrt_version)

    header "ВЫБОР ВЕРСИИ OpenWrt"

    case "$detected" in
        opkg) info "  [Автоопределение] Обнаружен opkg → OpenWrt 24.x или ниже" ;;
        apk)  info "  [Автоопределение] Обнаружен apk → OpenWrt 25.x+" ;;
        *)    warn "Пакетный менеджер не обнаружен" ;;
    esac

    echo ""
    info "Выберите версию OpenWrt:"
    info "  1) OpenWrt 24.x и ниже (opkg)"
    info "  2) OpenWrt 25.x и выше (apk)"
    echo ""

    case "$detected" in
        opkg) printf "${WHITE}Ваш выбор [1]: ${RESET}" ;;
        apk)  printf "${WHITE}Ваш выбор [2]: ${RESET}" ;;
        *)    printf "${WHITE}Ваш выбор: ${RESET}" ;;
    esac

    read choice

    if [ -z "$choice" ]; then
        case "$detected" in
            opkg) choice="1" ;;
            apk)  choice="2" ;;
            *)
                err "Не удалось автоопределить версию. Укажите явно (1 или 2)."
                exit 1
                ;;
        esac
    fi

    case "$choice" in
        1)
            PKG_MANAGER="opkg"
            echo ""
            ok "Выбран режим: OpenWrt 24.x (opkg)"
            ;;
        2)
            PKG_MANAGER="apk"
            echo ""
            ok "Выбран режим: OpenWrt 25.x+ (apk)"
            ;;
        *)
            err "Неверный выбор. Укажите 1 или 2."
            exit 1
            ;;
    esac
    echo ""
}

# ============================================================
# Функция для добавления файлов в список бэкапа
# ============================================================
add_files() {
    local description="$1"
    local files="$2"
    local count=0

    if [ -n "$files" ]; then
        header "$description"
        for file in $files; do
            if [ -f "$file" ]; then
                FILES_TO_BACKUP="$FILES_TO_BACKUP $file"
                ok "$file"
                count=$((count + 1))
            fi
        done
        [ $count -eq 0 ] && warn "не найдено"
        echo ""
    fi
}

# ============================================================
# Сохранение списка установленных пакетов
# ============================================================
save_package_list() {
    header "СОХРАНЕНИЕ СПИСКА ПАКЕТОВ"

    if [ "$PKG_MANAGER" = "opkg" ]; then
        if opkg list-installed > "$BACKUP_DIR/installed_packages.txt" 2>/dev/null; then
            ok "Список пакетов сохранён (opkg): $BACKUP_DIR/installed_packages.txt"
            info "  Всего пакетов: $(wc -l < "$BACKUP_DIR/installed_packages.txt")"
        else
            err "Не удалось сохранить список пакетов"
        fi
    elif [ "$PKG_MANAGER" = "apk" ]; then
        if apk info > "$BACKUP_DIR/installed_packages.txt" 2>/dev/null; then
            ok "Список пакетов сохранён (apk): $BACKUP_DIR/installed_packages.txt"
            info "  Всего пакетов: $(wc -l < "$BACKUP_DIR/installed_packages.txt")"
        else
            err "Не удалось сохранить список пакетов"
        fi
    fi
}

# ============================================================
# Сохранение метаданных
# ============================================================
save_metadata() {
    METADATA_FILE="$BACKUP_DIR/backup_metadata.txt"
    cat > "$METADATA_FILE" << EOF
# OpenWrt Smart Backup Metadata
PKG_MANAGER=$PKG_MANAGER
BACKUP_DATE=$(date +%Y-%m-%d_%H:%M:%S)
OPENWRT_VERSION=$(cat /etc/openwrt_release 2>/dev/null | grep DISTRIB_RELEASE | cut -d"'" -f2)
DEVICE_MODEL=$(cat /tmp/sysinfo/model 2>/dev/null || echo "unknown")
EOF
    ok "Метаданные сохранены: $METADATA_FILE"
    info "  Пакетный менеджер: $PKG_MANAGER"
    echo ""
}

# ============================================================
# ПУНКТ 1: Полный бэкап
# ============================================================
do_full_backup() {
    local BACKUP_FILE="openwrt_backup_$(date +%Y%m%d_%H%M%S).tar.gz"

    header "СОЗДАНИЕ ПОЛНОГО БЭКАПА"

    FILES_TO_BACKUP=""

    # 1. Измененные конфиг-файлы через пакетный менеджер
    if [ "$PKG_MANAGER" = "opkg" ]; then
        MODIFIED_CONFIGS=$(opkg list-changed-conffiles 2>/dev/null)
        add_files "Измененные конфиг-файлы (opkg)" "$MODIFIED_CONFIGS"
    elif [ "$PKG_MANAGER" = "apk" ]; then
        MODIFIED_CONFIGS=$(apk audit 2>/dev/null | awk '{print $2}' | grep "^/etc/" | sort -u)
        if [ -n "$MODIFIED_CONFIGS" ]; then
            add_files "Измененные файлы (apk audit)" "$MODIFIED_CONFIGS"
        else
            header "Измененные файлы (apk audit)"
            warn "apk audit не вернул результатов или недоступен"
            echo ""
        fi
    fi

    # 2. Все файлы в /etc/config/
    ALL_CONFIGS=$(find /etc/config/ -type f 2>/dev/null)
    add_files "Все конфигурационные файлы (/etc/config/)" "$ALL_CONFIGS"

    # 3. SSH ключи
    SSH_KEYS=$(find /etc/dropbear/ -name "dropbear_*_host_key" -type f 2>/dev/null)
    add_files "SSH ключи хоста" "$SSH_KEYS"

    # 4. SSL сертификаты uhttpd
    UHTTPD_CERTS=$(find /etc/ -maxdepth 1 -name "uhttpd.*" -type f 2>/dev/null)
    add_files "Сертификаты uHTTPd" "$UHTTPD_CERTS"

    # 5. Ключи и конфигурация пакетного менеджера
    if [ "$PKG_MANAGER" = "opkg" ]; then
        OPKG_KEYS=$(find /etc/opkg/keys/ -type f 2>/dev/null)
        add_files "Ключи OPKG" "$OPKG_KEYS"

        OPKG_CONF=$(find /etc/opkg/ -name "*.conf" -type f 2>/dev/null)
        add_files "Конфигурация OPKG (репозитории)" "$OPKG_CONF"
    elif [ "$PKG_MANAGER" = "apk" ]; then
        APK_KEYS=$(find /etc/apk/keys/ -type f 2>/dev/null)
        add_files "Ключи APK" "$APK_KEYS"

        APK_REPOS=$(find /etc/apk/repositories.d/ -type f 2>/dev/null)
        add_files "Репозитории APK" "$APK_REPOS"

        if [ -f "/etc/apk/repositories" ]; then
            add_files "Основной файл репозиториев APK" "/etc/apk/repositories"
        fi
    fi

    # 6. Пользовательские crontabs
    CRONTABS=$(find /etc/crontabs/ -type f 2>/dev/null)
    add_files "Crontabs" "$CRONTABS"

    # 7. Конфиги sing-box
    SING_BOX_CONFIGS=$(find /etc/sing-box/ -name "*.json" -type f 2>/dev/null)
    add_files "Конфиги Sing-box" "$SING_BOX_CONFIGS"

    # 8. Важные системные файлы
    SYSTEM_FILES="
/etc/group
/etc/passwd
/etc/shadow
/etc/hosts
/etc/shells
/etc/profile
/etc/rc.local
/etc/sysctl.conf
/etc/inittab
/etc/shinit
"
    add_files "Системные файлы" "$SYSTEM_FILES"

    # 9. Пользовательские nftables правила
    NFTABLES_RULES=$(find /etc/nftables.d/ -name "*.nft" -type f 2>/dev/null)
    add_files "Правила NFTables" "$NFTABLES_RULES"

    # Метаданные
    header "СОХРАНЕНИЕ МЕТАДАННЫХ"
    save_metadata
    FILES_TO_BACKUP="$FILES_TO_BACKUP $METADATA_FILE"

    # Создаём архив
    header "СОЗДАНИЕ АРХИВА"
    info "Файл: $BACKUP_DIR/$BACKUP_FILE"

    if tar -czf "$BACKUP_DIR/$BACKUP_FILE" $FILES_TO_BACKUP 2>/dev/null; then
        ok "Архив создан успешно"
    else
        err "Ошибка создания архива"
        exit 1
    fi

    echo ""
    save_package_list

    echo ""
    line
    printf "${GREEN}  БЭКАП ЗАВЕРШЁН УСПЕШНО${RESET}\n"
    line
    info "Пакетный менеджер: $PKG_MANAGER"
    info "Файл бэкапа:      $BACKUP_DIR/$BACKUP_FILE"
    info "Файлов в архиве:  $(echo $FILES_TO_BACKUP | wc -w)"
    info "Размер архива:    $(du -h "$BACKUP_DIR/$BACKUP_FILE" | cut -f1)"
    info "Список пакетов:   $BACKUP_DIR/installed_packages.txt"
    info "Метаданные:       $BACKUP_DIR/backup_metadata.txt"
    echo ""
    info "Для восстановления используйте:"
    info "  ./smart_restore.sh"
}

# ============================================================
# ПУНКТ 2: Только список пакетов
# ============================================================
do_packages_only_backup() {
    header "БЭКАП ТОЛЬКО СПИСКА ПАКЕТОВ"

    save_metadata
    save_package_list

    echo ""
    line
    printf "${GREEN}  БЭКАП СПИСКА ПАКЕТОВ ЗАВЕРШЁН${RESET}\n"
    line
    info "Пакетный менеджер: $PKG_MANAGER"
    info "Список пакетов:   $BACKUP_DIR/installed_packages.txt"
    info "Метаданные:       $BACKUP_DIR/backup_metadata.txt"
    echo ""
    info "Для установки пакетов на новом роутере используйте:"
    info "  ./smart_restore.sh  →  пункт 3 (Установить пакеты из списка)"
}

# ============================================================
# ОСНОВНОЙ СКРИПТ
# ============================================================

line
printf "${WHITE}       OpenWrt Smart Backup${RESET}\n"
printf "${WHITE}       Поддержка OpenWrt 24.x (opkg) и 25.x+ (apk)${RESET}\n"
line
echo ""

select_version

while true; do
    header "ГЛАВНОЕ МЕНЮ"
    echo ""
    info "  1) Полный бэкап (конфиги + список пакетов)"
    info "  2) Бэкап только списка установленных пакетов"
    info "  3) Выход"
    echo ""
    printf "${WHITE}Ваш выбор: ${RESET}"
    read menu_choice

    case "$menu_choice" in
        1)
            echo ""
            do_full_backup
            break
            ;;
        2)
            echo ""
            do_packages_only_backup
            break
            ;;
        3)
            info "Выход."
            exit 0
            ;;
        *)
            echo ""
            err "Неверный выбор. Укажите 1, 2 или 3."
            echo ""
            ;;
    esac
done
