#!/bin/sh

# ============================================================
# OpenWrt Smart Restore Script
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

BACKUP_DIR="/root/backup"
PKG_MANAGER=""
BACKUP_PKG_MANAGER=""
BACKUP_VERSION=""
BACKUP_DATE=""

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

# ============================================================
# Чтение метаданных из бэкапа
# ============================================================
read_backup_metadata() {
    local backup_dir="$1"
    if [ -f "$backup_dir/backup_metadata.txt" ]; then
        BACKUP_PKG_MANAGER=$(grep "^PKG_MANAGER=" "$backup_dir/backup_metadata.txt" | cut -d'=' -f2)
        BACKUP_VERSION=$(grep "^OPENWRT_VERSION=" "$backup_dir/backup_metadata.txt" | cut -d'=' -f2)
        BACKUP_DATE=$(grep "^BACKUP_DATE=" "$backup_dir/backup_metadata.txt" | cut -d'=' -f2)
    fi
}

# ============================================================
# Выбор версии OpenWrt
# ============================================================
select_version() {
    local detected
    detected=$(detect_openwrt_version)

    header "ВЫБОР ВЕРСИИ OpenWrt"

    case "$detected" in
        opkg) info "  [Автоопределение] Обнаружен opkg → OpenWrt 24.x или ниже" ;;
        apk)  info "  [Автоопределение] Обнаружен apk → OpenWrt 25.x+" ;;
        *)    warn "Пакетный менеджер не обнаружен" ;;
    esac

    if [ -n "$BACKUP_PKG_MANAGER" ]; then
        info "  [Метаданные бэкапа] Бэкап создан на: $BACKUP_PKG_MANAGER (OpenWrt $BACKUP_VERSION, $BACKUP_DATE)"
    fi

    echo ""
    info "Выберите версию OpenWrt на ТЕКУЩЕМ роутере:"
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
# Проверка и настройка интернета
# ============================================================
check_and_fix_internet() {
    header "ПРОВЕРКА ИНТЕРНЕТ-СОЕДИНЕНИЯ"

    info "1. Проверка сетевого подключения..."
    if ! ping -c 1 -W 3 1.1.1.1 >/dev/null 2>&1; then
        err "Сетевое подключение: ОШИБКА"
        warn "Интернет-соединение отсутствует. Установка пакетов будет пропущена."
        return 1
    fi
    ok "Сетевое подключение: OK"

    info "2. Проверка DNS-разрешения..."
    if ! nslookup downloads.openwrt.org >/dev/null 2>&1; then
        err "DNS: ОШИБКА"
        warn "Пинг работает, но DNS нет — пытаемся исправить..."

        cp /etc/resolv.conf /etc/resolv.conf.bak 2>/dev/null

        cat > /etc/resolv.conf << EOF
nameserver 1.1.1.1
nameserver 8.8.8.8
nameserver 8.8.4.4
EOF

        info "   Ожидание применения DNS..."
        sleep 2

        info "3. Повторная проверка DNS..."
        if ! nslookup downloads.openwrt.org >/dev/null 2>&1; then
            err "DNS: Всё ещё не работает"
            warn "Установка пакетов будет пропущена."
            return 1
        fi
        ok "DNS: ИСПРАВЛЕН и работает"
    else
        ok "DNS: OK"
    fi

    ok "Интернет-соединение: ГОТОВО"
    return 0
}

# ============================================================
# Подготовка системы (обновление списков пакетов)
# ============================================================
prepare_system() {
    header "ПОДГОТОВКА СИСТЕМЫ"

    if [ "$PKG_MANAGER" = "opkg" ]; then
        info "1. Очистка кэша пакетов (opkg)..."
        rm -rf /var/opkg-lists/*
        info "2. Обновление списков пакетов..."
        opkg update
    elif [ "$PKG_MANAGER" = "apk" ]; then
        info "1. Обновление индексов пакетов (apk)..."
        apk update
    fi

    info "3. Создание необходимых директорий..."
    mkdir -p /etc/uci-defaults
    echo ""
}

# ============================================================
# Установка одного пакета с проверкой
# ============================================================
install_package() {
    local package="$1"
    local flags="$2"

    printf "${WHITE}  Установка: %-40s${RESET}" "$package ..."

    if [ "$PKG_MANAGER" = "opkg" ]; then
        if opkg list-installed | grep -q "^$package "; then
            printf "${GREEN}✓ (уже установлен)${RESET}\n"
            return 0
        fi
        if opkg install $flags $package >/dev/null 2>&1; then
            printf "${GREEN}✓${RESET}\n"
            return 0
        else
            printf "${RED}✗${RESET}\n"
            return 1
        fi
    elif [ "$PKG_MANAGER" = "apk" ]; then
        if apk info 2>/dev/null | grep -q "^${package}$"; then
            printf "${GREEN}✓ (уже установлен)${RESET}\n"
            return 0
        fi
        if apk add $flags $package >/dev/null 2>&1; then
            printf "${GREEN}✓${RESET}\n"
            return 0
        else
            printf "${RED}✗${RESET}\n"
            return 1
        fi
    fi
}

# ============================================================
# Установка пакетов из файла списка
# ============================================================
install_packages_from_list() {
    local packages_file="$1"
    local success=0
    local failed=0
    local failed_list=""

    header "УСТАНОВКА ПАКЕТОВ"

    if [ ! -f "$packages_file" ]; then
        err "Список пакетов не найден: $packages_file"
        return 1
    fi

    info "Файл списка: $packages_file"
    info "Всего записей: $(wc -l < "$packages_file")"
    echo ""

    while read line; do
        local package=$(echo "$line" | awk '{print $1}')
        if [ -n "$package" ] && [ "$package" != "#" ]; then
            if install_package "$package"; then
                success=$((success + 1))
            else
                failed=$((failed + 1))
                failed_list="$failed_list\n  - $package"
            fi
        fi
    done < "$packages_file"

    echo ""
    ok "Успешно установлено: $success пакетов"
    if [ $failed -gt 0 ]; then
        err "Не удалось установить: $failed пакетов"
        echo ""
        warn "Список неустановленных пакетов:"
        printf "${YELLOW}$failed_list${RESET}\n"
    fi
}

# ============================================================
# Восстановление конфигурации
# Параметр $3: "same" — включая конфиги репо, "migrate" — без них и без firewall/network
# ============================================================
restore_configuration() {
    local backup_file="$1"
    local temp_dir="$2"
    local mode="$3"

    header "ВОССТАНОВЛЕНИЕ КОНФИГУРАЦИОННЫХ ФАЙЛОВ"

    info "Распаковка файлов бэкапа..."
    tar -xzf "$backup_file" -C "$temp_dir"

    local paths="
        */etc/config/*
        */etc/dropbear/*
        */etc/uhttpd.*
        */etc/crontabs/*
        */etc/sing-box/*
        */etc/group
        */etc/passwd
        */etc/shadow
        */etc/hosts
        */etc/shells
        */etc/profile
        */etc/rc.local
        */etc/sysctl.conf
        */etc/inittab
        */etc/shinit
        */etc/nftables.d/*
    "

    if [ "$mode" = "same" ]; then
        if [ "$PKG_MANAGER" = "opkg" ]; then
            paths="$paths
                */etc/opkg/keys/*
                */etc/opkg/*.conf
            "
        elif [ "$PKG_MANAGER" = "apk" ]; then
            paths="$paths
                */etc/apk/keys/*
                */etc/apk/repositories.d/*
                */etc/apk/repositories
            "
        fi
    else
        warn "Конфигурация репозиториев исключена (миграция между версиями)"
        warn "/etc/config/firewall исключён (может блокировать сеть на 25.x)"
        warn "/etc/config/network исключён (форматы интерфейсов несовместимы)"
        echo ""
    fi

    info "Восстановление файлов..."
    for pattern in $paths; do
        find "$temp_dir" -path "$pattern" -type f 2>/dev/null | while read file; do
            local target_file="${file#$temp_dir}"

            # При миграции 24→25 пропускаем firewall — его правила несовместимы с 25.x
            # и блокируют исходящие соединения роутера (wget exit 4, EPERM)
            if [ "$mode" = "migrate" ] && [ "$target_file" = "/etc/config/firewall" ]; then
                warn "Пропущен: $target_file (настройте вручную после восстановления)"
                continue
            fi

            # При миграции 24→25 пропускаем network — форматы интерфейсов несовместимы
            # (swconfig vs DSA, netmask vs CIDR). IP задаётся вручную через ask_and_set_lan_ip
            if [ "$mode" = "migrate" ] && [ "$target_file" = "/etc/config/network" ]; then
                warn "Пропущен: $target_file (IP будет задан отдельно)"
                continue
            fi

            mkdir -p "$(dirname "$target_file")"

            if [ -f "$file" ]; then
                ok "$target_file"
                cp "$file" "$target_file"

                case "$target_file" in
                    *dropbear*_host_key|*uhttpd.key|*/shadow)
                        chmod 600 "$target_file"
                        ;;
                    *crontabs*)
                        chmod 644 "$target_file"
                        ;;
                esac
            fi
        done
    done

    echo ""
    ok "Восстановление конфигурационных файлов завершено"
    echo ""
}

# ============================================================
# Запуск сервисов
# ============================================================
start_services() {
    header "ЗАПУСК СЕРВИСОВ"

    /etc/init.d/network restart
    /etc/init.d/dropbear restart

    if [ -f "/etc/init.d/podkop" ]; then
        /etc/init.d/podkop enable
        /etc/init.d/podkop start
    fi

    local singbox_installed=0
    if [ "$PKG_MANAGER" = "opkg" ]; then
        opkg list-installed 2>/dev/null | grep -q "sing-box" && singbox_installed=1
    elif [ "$PKG_MANAGER" = "apk" ]; then
        apk info 2>/dev/null | grep -q "^sing-box$" && singbox_installed=1
    fi

    if [ $singbox_installed -eq 1 ]; then
        /etc/init.d/sing-box enable
        /etc/init.d/sing-box start
    fi

    /etc/init.d/uhttpd restart
}

# ============================================================
# Проверка наличия пакета (для финального отчёта)
# ============================================================
is_package_installed() {
    local package="$1"
    if [ "$PKG_MANAGER" = "opkg" ]; then
        opkg list-installed 2>/dev/null | grep -q "^$package "
    elif [ "$PKG_MANAGER" = "apk" ]; then
        apk info 2>/dev/null | grep -q "^${package}$"
    fi
}

# ============================================================
# Финальный отчёт
# ============================================================
print_status() {
    local mode_label="$1"

    echo ""
    line
    printf "${GREEN}  ВОССТАНОВЛЕНИЕ ЗАВЕРШЕНО  [%s]${RESET}\n" "$mode_label"
    line
    info "Пакетный менеджер: $PKG_MANAGER"

    if [ -f "/etc/init.d/podkop" ]; then
        ok "Podkop"
    else
        err "Podkop — не установлен"
    fi

    if is_package_installed "luci-theme-argon"; then
        ok "Argon Theme"
    else
        info "Argon Theme — не установлен"
    fi

    if is_package_installed "luci-app-argon-config"; then
        ok "Argon Config"
    else
        info "Argon Config — не установлен"
    fi

    if is_package_installed "sing-box"; then
        ok "sing-box"
    else
        info "sing-box — не установлен"
    fi

    echo ""
    warn "Следующим шагом будет перезапуск сервисов."
    warn "SSH-соединение может прерваться при перезапуске сети."
    warn "Переподключитесь после завершения."
}

# ============================================================
# Установка внешнего пакета
# ============================================================
install_external_package() {
    local name="$1"
    local url="$2"
    local flags="$3"
    local file="/tmp/${name}.pkg"

    info "Скачивание $name..."
    if wget -q -O "$file" "$url"; then
        info "Установка $name..."
        if [ "$PKG_MANAGER" = "opkg" ]; then
            if opkg install $flags "$file"; then
                ok "$name установлен"
                rm -f "$file"
                return 0
            else
                err "Не удалось установить $name"
                rm -f "$file"
                return 1
            fi
        elif [ "$PKG_MANAGER" = "apk" ]; then
            if apk add --allow-untrusted $flags "$file"; then
                ok "$name установлен"
                rm -f "$file"
                return 0
            else
                err "Не удалось установить $name"
                rm -f "$file"
                return 1
            fi
        fi
    else
        err "Не удалось скачать $name"
        return 1
    fi
}

# ============================================================
# Выбор файла бэкапа
# ============================================================
select_backup_file() {
    local backup_file

    local archives
    archives=$(ls "$BACKUP_DIR"/*.tar.gz 2>/dev/null)

    if [ -z "$archives" ]; then
        err "Бэкапы не найдены в $BACKUP_DIR" >&2
        return 1
    fi

    info "Доступные бэкапы:" >&2
    local i=1
    for f in $archives; do
        printf "${WHITE}  %d) %-50s %s${RESET}\n" "$i" "$(basename $f)" "($(du -h "$f" | cut -f1))" >&2
        i=$((i + 1))
    done
    echo "" >&2
    printf "${WHITE}Выберите номер бэкапа [1]: ${RESET}" >&2
    read sel
    [ -z "$sel" ] && sel=1

    backup_file=$(echo "$archives" | awk "NR==$sel")
    if [ -z "$backup_file" ]; then
        err "Неверный выбор" >&2
        return 1
    fi

    if [ ! -f "$backup_file" ]; then
        local full_path="$BACKUP_DIR/$backup_file"
        if [ ! -f "$full_path" ]; then
            err "Файл бэкапа не найден: $backup_file" >&2
            return 1
        fi
        backup_file="$full_path"
    fi

    ok "Восстановление из: $backup_file" >&2
    echo "$backup_file"
}

# ============================================================
# Запрос LAN IP перед перезапуском сети (только при миграции)
# ============================================================
ask_and_set_lan_ip() {
    echo ""
    line
    printf "${WHITE}  НАСТРОЙКА IP-АДРЕСА ДЛЯ ПОДКЛЮЧЕНИЯ${RESET}\n"
    line
    echo ""
    info "  При миграции с OpenWrt 24.x на 25.x конфигурация сети"
    info "  не переносится, так как форматы интерфейсов несовместимы."
    info "  После перезапуска сети роутер будет доступен по IP-адресу,"
    info "  который вы укажете ниже."
    echo ""
    warn "  Если не задать IP — роутер может быть недоступен по SSH"
    warn "  и веб-интерфейсу после перезапуска сервисов."
    echo ""

    while true; do
        printf "${WHITE}  Введите IP-адрес для доступа к роутеру (например, 10.100.100.1): ${RESET}"
        read lan_ip

        if [ -z "$lan_ip" ]; then
            err "IP-адрес не может быть пустым. Попробуйте ещё раз."
            echo ""
            continue
        fi

        echo ""
        info "  Будет установлен LAN IP: $lan_ip"
        printf "${WHITE}  Подтвердить? [Y/n]: ${RESET}"
        read confirm_ip

        if [ "$confirm_ip" = "n" ] || [ "$confirm_ip" = "N" ]; then
            echo ""
            info "  Введите адрес заново."
            echo ""
            continue
        fi

        uci set network.lan.ipaddr="$lan_ip"
        uci commit network
        ok "IP-адрес $lan_ip применён в конфигурации сети."
        echo ""
        break
    done
}

# ============================================================
# ПУНКТ 1: Восстановление (та же версия → та же версия)
# ============================================================
do_same_version_restore() {
    header "ВОССТАНОВЛЕНИЕ БЭКАПА (та же версия)"

    local backup_file
    backup_file=$(select_backup_file) || return 1

    read_backup_metadata "$BACKUP_DIR"

    if [ -n "$BACKUP_PKG_MANAGER" ] && [ "$BACKUP_PKG_MANAGER" != "$PKG_MANAGER" ]; then
        warn "Бэкап создан на $BACKUP_PKG_MANAGER, а текущая система — $PKG_MANAGER"
        warn "Для миграции используйте пункт 2."
        echo ""
        printf "${WHITE}Всё равно продолжить? [y/N]: ${RESET}"
        read confirm
        [ "$confirm" != "y" ] && [ "$confirm" != "Y" ] && return 0
    fi

    warn "Существующие конфигурационные файлы будут перезаписаны!"
    printf "${WHITE}Нажмите Enter для продолжения или Ctrl+C для отмены...${RESET}"
    read

    local temp_dir="/tmp/restore_$$"
    mkdir -p "$temp_dir"

    if ! check_and_fix_internet; then
        echo ""
        warn "Нет интернет-соединения — пакеты не будут установлены."
        printf "${WHITE}Продолжить (только конфиги)? [y/N]: ${RESET}"
        read confirm
        if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
            restore_configuration "$backup_file" "$temp_dir" "same"
            print_status "та же версия, без пакетов"
            echo ""
            printf "${WHITE}Запустить сервисы? [Y/n]: ${RESET}"
            read svc
            [ "$svc" != "n" ] && [ "$svc" != "N" ] && start_services
        fi
        rm -rf "$temp_dir"
        return 0
    fi

    prepare_system
    install_packages_from_list "$BACKUP_DIR/installed_packages.txt"
    restore_configuration "$backup_file" "$temp_dir" "same"

    print_status "та же версия"
    echo ""
    printf "${WHITE}Запустить сервисы? [Y/n]: ${RESET}"
    read svc
    [ "$svc" != "n" ] && [ "$svc" != "N" ] && start_services

    rm -rf "$temp_dir"
}

# ============================================================
# ПУНКТ 2: Миграция (24.x → 25.x)
# ============================================================
do_migration_restore() {
    header "МИГРАЦИЯ БЭКАПА (24.x opkg → 25.x apk)"

    if [ "$PKG_MANAGER" != "apk" ]; then
        err "Миграция предназначена для переноса НА систему 25.x (apk)."
        info "  Текущая система: $PKG_MANAGER"
        info "  Для восстановления на той же версии используйте пункт 1."
        return 1
    fi

    local backup_file
    backup_file=$(select_backup_file) || return 1

    read_backup_metadata "$BACKUP_DIR"

    if [ -n "$BACKUP_PKG_MANAGER" ] && [ "$BACKUP_PKG_MANAGER" != "opkg" ]; then
        warn "Бэкап создан на $BACKUP_PKG_MANAGER (не opkg)."
        printf "${WHITE}Всё равно продолжить миграцию? [y/N]: ${RESET}"
        read confirm
        [ "$confirm" != "y" ] && [ "$confirm" != "Y" ] && return 0
    fi

    warn "Конфигурация репозиториев opkg НЕ будет перенесена (несовместима с apk)."
    warn "Конфигурация сети (/etc/config/network) НЕ переносится (несовместимые форматы)."
    warn "Существующие конфигурационные файлы будут перезаписаны!"
    printf "${WHITE}Нажмите Enter для продолжения или Ctrl+C для отмены...${RESET}"
    read

    local temp_dir="/tmp/restore_$$"
    mkdir -p "$temp_dir"

    if ! check_and_fix_internet; then
        echo ""
        warn "Нет интернет-соединения — пакеты не будут установлены."
        printf "${WHITE}Продолжить (только конфиги без репо и сети)? [y/N]: ${RESET}"
        read confirm
        if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
            restore_configuration "$backup_file" "$temp_dir" "migrate"
            print_status "миграция 24→25, без пакетов"
            echo ""
            ask_and_set_lan_ip
            printf "${WHITE}Запустить сервисы? [Y/n]: ${RESET}"
            read svc
            [ "$svc" != "n" ] && [ "$svc" != "N" ] && start_services
        fi
        rm -rf "$temp_dir"
        return 0
    fi

    prepare_system
    install_packages_from_list "$BACKUP_DIR/installed_packages.txt"
    restore_configuration "$backup_file" "$temp_dir" "migrate"

    print_status "миграция 24.x → 25.x"
    ask_and_set_lan_ip
    printf "${WHITE}Запустить сервисы? [Y/n]: ${RESET}"
    read svc
    [ "$svc" != "n" ] && [ "$svc" != "N" ] && start_services

    rm -rf "$temp_dir"
}

# ============================================================
# ПУНКТ 3: Установить пакеты из сохранённого списка
# ============================================================
do_install_packages_only() {
    header "УСТАНОВКА ПАКЕТОВ ИЗ СОХРАНЁННОГО СПИСКА"

    local packages_file="$BACKUP_DIR/installed_packages.txt"

    if [ ! -f "$packages_file" ]; then
        err "Файл списка пакетов не найден: $packages_file"
        info "  Сначала создайте бэкап через smart_backup.sh"
        return 1
    fi

    read_backup_metadata "$BACKUP_DIR"

    if [ -n "$BACKUP_PKG_MANAGER" ]; then
        info "  [Метаданные] Список создан на: $BACKUP_PKG_MANAGER (OpenWrt $BACKUP_VERSION)"
        if [ "$BACKUP_PKG_MANAGER" != "$PKG_MANAGER" ]; then
            warn "Список пакетов создан на другой версии ($BACKUP_PKG_MANAGER)."
            warn "Некоторые пакеты могут отсутствовать в репозиториях текущей системы ($PKG_MANAGER)."
        fi
        echo ""
    fi

    if ! check_and_fix_internet; then
        err "Нет интернет-соединения. Установка невозможна."
        return 1
    fi

    prepare_system
    install_packages_from_list "$packages_file"

    echo ""
    line
    printf "${GREEN}  УСТАНОВКА ПАКЕТОВ ЗАВЕРШЕНА${RESET}\n"
    line
}

# ============================================================
# ПУНКТ 4: Установка Argon Theme + Config (24.x и 25.x)
# ============================================================
do_install_argon() {
    header "УСТАНОВКА ARGON THEME + ARGON CONFIG"

    if ! check_and_fix_internet; then
        err "Нет интернет-соединения. Установка невозможна."
        return 1
    fi

    # Проверяем наличие curl (обязателен для установщика)
    if ! command -v curl >/dev/null 2>&1; then
        info "Установка curl (требуется для установщика)..."
        if [ "$PKG_MANAGER" = "opkg" ]; then
            opkg install curl >/dev/null 2>&1
        elif [ "$PKG_MANAGER" = "apk" ]; then
            apk add curl >/dev/null 2>&1
        fi
        if ! command -v curl >/dev/null 2>&1; then
            err "Не удалось установить curl. Установка Argon невозможна."
            return 1
        fi
        ok "curl установлен"
    fi

    info "Запуск установщика Argon Theme + Config..."
    if sh -c "$(curl -sL https://raw.githubusercontent.com/NerealNeSkill/luci-theme-argon-config-ru/master/install.sh)"; then
        echo ""
        ok "Argon Theme + Config установлены"
    else
        echo ""
        err "Ошибка установки Argon Theme + Config"
    fi

    echo ""
    line
    printf "${GREEN}  УСТАНОВКА ARGON ЗАВЕРШЕНА${RESET}\n"
    line
}

# ============================================================
# ПУНКТ 5: Установка Proton2025 (24.x и 25.x)
# ============================================================
do_install_proton2025() {
    header "УСТАНОВКА ТЕМЫ PROTON2025"

    if ! check_and_fix_internet; then
        err "Нет интернет-соединения. Установка невозможна."
        return 1
    fi

    info "Скачивание и запуск установщика Proton2025..."
    if wget -qO- https://raw.githubusercontent.com/ChesterGoodiny/luci-theme-proton2025/main/install.sh | sh; then
        echo ""
        ok "Proton2025 установлен"
    else
        echo ""
        err "Ошибка установки Proton2025"
    fi

    echo ""
    line
    printf "${GREEN}  УСТАНОВКА PROTON2025 ЗАВЕРШЕНА${RESET}\n"
    line
}

# ============================================================
# ПУНКТ 7: Установка Podkop
# ============================================================
do_install_podkop() {
    header "УСТАНОВКА PODKOP"

    if ! check_and_fix_internet; then
        err "Нет интернет-соединения. Установка невозможна."
        return 1
    fi

    info "Скачивание установщика Podkop..."
    if wget -q -O /tmp/install_podkop.sh "https://raw.githubusercontent.com/itdoginfo/podkop/main/install.sh"; then
        chmod +x /tmp/install_podkop.sh
        info "Запуск установки Podkop..."
        /tmp/install_podkop.sh
        rm -f /tmp/install_podkop.sh
    else
        err "Не удалось скачать установщик Podkop"
    fi

    echo ""
    line
    printf "${GREEN}  УСТАНОВКА PODKOP ЗАВЕРШЕНА${RESET}\n"
    line
    if [ -f "/etc/init.d/podkop" ]; then
        ok "Podkop"
    else
        err "Podkop — не установлен"
    fi
}

# ============================================================
# ОСНОВНОЙ СКРИПТ
# ============================================================

line
printf "${WHITE}       OpenWrt Smart Restore${RESET}\n"
printf "${WHITE}       Поддержка OpenWrt 24.x (opkg) и 25.x+ (apk)${RESET}\n"
line
echo ""

read_backup_metadata "$BACKUP_DIR"
select_version

while true; do
    header "ГЛАВНОЕ МЕНЮ"
    echo ""
    info "  1) Восстановить бэкап (та же версия → та же версия)"
    info "     Полное восстановление: конфиги + пакеты + репозитории"
    echo ""
    info "  2) Миграция бэкапа (24.x → 25.x)"
    info "     Конфиги + пакеты, без переноса конфигурации репозиториев и сети"
    echo ""
    info "  3) Установить пакеты из сохранённого списка"
    info "     Установка утилит на новый роутер по забэкапленному списку"
    echo ""
    info "  4) Установить тему Argon + Argon Config  (OpenWrt 24.x и 25.x)"
    echo ""
    info "  5) Установить тему Proton2025  (OpenWrt 24.x и 25.x)"
    echo ""
    info "  6) Установить Podkop"
    echo ""
    info "  7) Выход"
    echo ""
    printf "${WHITE}Ваш выбор: ${RESET}"
    read menu_choice

    echo ""
    case "$menu_choice" in
        1) do_same_version_restore ;;
        2) do_migration_restore ;;
        3) do_install_packages_only ;;
        4) do_install_argon ;;
        5) do_install_proton2025 ;;
        6) do_install_podkop ;;
        7)
            info "Выход."
            exit 0
            ;;
        *)
            err "Неверный выбор. Укажите число от 1 до 7."
            ;;
    esac

    echo ""
    printf "${WHITE}Вернуться в меню? [Y/n]: ${RESET}"
    read back
    [ "$back" = "n" ] || [ "$back" = "N" ] && break
    echo ""
done
