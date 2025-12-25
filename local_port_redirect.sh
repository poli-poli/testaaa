#!/bin/bash
# local_port_redirect.sh - Перенаправление между локальными портами
# Использование: ./local_port_redirect.sh <порт_источник> <порт_назначение>

set -e

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Директория для PID файлов и логов
DATA_DIR="$HOME/local_port_redirect"
mkdir -p "$DATA_DIR"

# Проверка и установка netcat
check_netcat() {
    if ! command -v nc &> /dev/null; then
        echo -e "${RED}❌ netcat не установлен${NC}"
        echo "Установите:"
        echo "  Ubuntu/Debian: sudo apt install netcat"
        echo "  CentOS/RHEL: sudo yum install nc"
        echo "  macOS: brew install netcat"
        exit 1
    fi
}

# Проверка занятости порта
check_port() {
    local port=$1
    if lsof -Pi :$port -sTCP:LISTEN -t >/dev/null 2>&1; then
        local pid=$(lsof -ti:$port)
        local process=$(ps -p $pid -o comm= 2>/dev/null || echo "неизвестный")
        echo -e "${YELLOW}⚠️  Порт $port занят процессом $process (PID: $pid)${NC}"
        return 1
    fi
    return 0
}


# Метод 1: Через proxy бинарник
method_proxy() {
    local src_port=$1
    local dst_port=$2
    local pid_file="$DATA_DIR/proxy_${src_port}.pid"
    
    echo -e "${BLUE}🎯 Метод 1: Использую proxy бинарник${NC}"
    
    if [ ! -f "./proxy" ]; then
        echo -e "${YELLOW}⚠️  Бинарник proxy не найден, собираю...${NC}"
        if command -v make &> /dev/null; then
            make 2>/dev/null  make darwin 2>/dev/null 
            {
                echo -e "${RED}❌ Не удалось собрать proxy${NC}"
                return 1
            }
        else
            echo -e "${RED}❌ make не установлен${NC}"
            return 1
        fi
    fi
    
    # Запускаем proxy
    ./proxy -l $src_port -h 127.0.0.1 -p $dst_port -i "tee -a input.log" -o "tee -a output.log" > "$DATA_DIR/proxy_${src_port}.log" 2>&1 &
    local pid=$(pgrep proxy)
    echo $pid > "$pid_file"
    
    sleep 1
    if ps -p $pid > /dev/null; then
        echo -e "${GREEN}✅ Proxy запущен (PID: $pid)${NC}"
        echo -e "   Порт ${src_port} → ${dst_port}"
        echo -e "   Логи: ${DATA_DIR}/proxy_${src_port}.log"
    else
        echo -e "${RED}❌ Proxy не запустился${NC}"
        return 1
    fi
}

# Запуск выбранного метода
start_redirect() {
    local src_port=$1
    local dst_port=$2
    local method=${3:-1}
    echo -e "\n${GREEN}🚀 Начинаю перенаправление портов${NC}"
    echo "────────────────────────────────"
    echo "Источник: порт $src_port"
    echo "Назначение: порт $dst_port"
    echo "────────────────────────────────"
    # Проверяем порты
    check_port $src_port || {
        read -p "Продолжить и завершить процесс? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            fuser -k $src_port/tcp 2>/dev/null || true
            sleep 1
        else
            return 1
        fi
    }
    case $method in
        1) method_proxy $src_port $dst_port ;;
        2) method_socat $src_port $dst_port ;;
        3) method_nc $src_port $dst_port ;;
        4) method_rinetd $src_port $dst_port ;;
        5) method_ssh $src_port $dst_port ;;
        *) method_proxy $src_port $dst_port ;;
    esac
}

# Остановка перенаправления
stop_redirect() {
    local src_port=$1
    echo -e "\n${YELLOW}🛑 Останавливаю перенаправление порта $src_port${NC}"
    # Ищем все PID файлы для этого порта
    local stopped=0
    for pid_file in $DATA_DIR/*_${src_port}.pid; do
        if [ -f "$pid_file" ]; then
            local pid=$(cat "$pid_file")
            local method=$(basename "$pid_file" | cut -d_ -f1)
            if kill -0 $pid 2>/dev/null; then
                kill $pid
                echo -e "✅ Остановлен $method (PID: $pid)"
                stopped=1
            fi
            rm -f "$pid_file"
        fi
    done
    # Дополнительно убиваем по использованию порта
    local port_pids=$(lsof -ti:$src_port 2>/dev/null || true)
    if [ -n "$port_pids" ]; then
        for pid in $port_pids; do
            if [ $pid -ne $$ ]; then  # Не убиваем себя
                kill $pid 2>/dev/null || true
                echo -e "✅ Остановлен процесс (PID: $pid)"
                stopped=1
            fi
        done
    fi
    if [ $stopped -eq 0 ]; then
        echo -e "ℹ️  Не найдено активных перенаправлений для порта $src_port"
    fi
}

# Показать статус
show_status() {
    echo -e "\n${BLUE}📊 Статус перенаправлений${NC}"
    echo "────────────────────────────────"
    local found=0
    for pid_file in $DATA_DIR/*.pid; do
        if [ -f "$pid_file" ]; then
            local port=$(basename "$pid_file" | grep -o '[0-9]\+\.pid$' | cut -d. -f1)
            local method=$(basename "$pid_file" | cut -d_ -f1)
            local pid=$(cat "$pid_file")
            if kill -0 $pid 2>/dev/null; then
                echo -e "${GREEN}✅ $method: порт $port (PID: $pid) - работает${NC}"
                found=1
            else
                echo -e "${RED}❌ $method: порт $port (PID: $pid) - не работает${NC}"
                rm -f "$pid_file"
            fi
        fi
    done
    if [ $found -eq 0 ]; then
        echo -e "ℹ️  Нет активных перенаправлений"
    fi
    # Показываем слушающие порты
    echo -e "\n${BLUE}👂 Слушающие порты:${NC}"
    netstat -tlnp 2>/dev/null | grep LISTEN | grep -E ":(6[0-9]{2,3}|7[0-9]{3}|8[0-9]{3}|9[0-9]{3})" || true
}
test_connection() {
    local src_port=$1
    local dst_port=$2
    
    echo -e "\n${CYAN}🔌 Тестируем proxy (kklis/proxy)${NC}"
    echo "Источник: порт $src_port"
    echo "Назначение: порт $dst_port"
    echo ""
    
    # Генерируем тестовые данные
    local test_data="PROXY_TEST_$(date +%s)_${RANDOM}"
    local log_file="/tmp/proxy_test"
    
    # Шаг 1: Запускаем приемник
    echo "1. Запускаем приемник на порту $dst_port..."
    nc -l -p "$dst_port" > "$log_file" &
    local nc_pid=$!
    
    # Даем время на запуск
    sleep 0.5
    
    # Шаг 2: Отправляем через proxy
    echo "2. Отправляем тестовые данные через порт $src_port..."
    echo "Данные: $test_data"
    echo ""
    
    # Отправляем (игнорируем ошибки соединения)
    if echo "$test_data" | nc -w 2 localhost "$src_port" 2>/dev/null; then
        echo "✅ Отправка инициирована"
    fi
    
    # Ждем получения
    sleep 1
    
    # Шаг 3: Проверяем результат
    echo "3. Проверяем результат..."
    if [[ -s "$log_file" ]]; then
        local received=$(cat "$log_file")
        echo "✅ Получены данные: $received"
        
        if [[ "$received" == "$test_data" ]]; then
            echo -e "${GREEN}🎉 SUCCESS: Proxy корректно работает!${NC}"
            echo "   $src_port → $dst_port: ✓"
        else
            echo -e "${YELLOW}⚠️  Данные искажены при передаче${NC}"
            echo "   Отправлено: $test_data"
            echo "   Получено:   $received"
        fi
    else
        echo -e "${RED}❌ FAIL: Данные не получены${NC}"
        echo "   Проверьте:"
        echo "   1. Запущен ли proxy?"
        echo "   2. Правильно ли настроены порты?"
        echo "   3. Не блокирует ли firewall соединение?"
    fi
    
    # Очистка
    kill "$nc_pid" 2>/dev/null
    #rm -f "$log_file"
    echo ""
}

# test_connection() {
#     local src_port=$1
#     local dst_port=$2
#     local listener_pid
#     local response_file="/tmp/test_response"  # Уникальный файл для каждого теста
    
#     echo -e "\n${BLUE}🧪 Тестирую соединение${NC}"
    
#     # Проверяем, слушает ли порт-источник
#     if nc -z localhost "$src_port" 2>/dev/null; then
#         echo -e "✅ Порт $src_port слушает"
#     else
#         echo -e "❌ Порт $src_port не отвечает"
#         return 1
#     fi
    
#     # Пробуем отправить тестовые данные
#     test_msg="Test connection $(date)"
    
#     # Запускаем слушатель на dst_port в фоне
#     echo -e "Запуск слушателя на порту $dst_port..."
#     timeout 3 nc -l -p "$dst_port" > "$response_file" 2>/dev/null &
#     listener_pid=$!
    
#     # Даем время на запуск слушателя
#     sleep 0.5
    
#     # Отправляем сообщение на src_port
#     echo -e "Отправка тестового сообщения на порт $src_port..."
#     if echo "$test_msg" | timeout 2 nc localhost "$src_port" 2>/dev/null; then
#         echo -e "✅ Сообщение отправлено на $src_port"
#     else
#         echo -e "❌ Не удалось отправить сообщение на $src_port"
#         kill "$listener_pid" 2>/dev/null
#         # rm -f "$response_file"
#         # return 1
#     fi
    
#     # Ждем завершения слушателя
#     wait "$listener_pid" 2>/dev/null
    
#     # Проверяем полученный ответ
#     if [[ -s "$response_file" ]]; then
#         echo -e "✅ Получен ответ на порту $dst_port"
#         echo -e "Содержимое ответа:"
#         cat "$response_file"
        
#         # Проверяем, содержит ли ответ ключевые слова
#         if grep -qi "test\|success\|ok" "$response_file"; then
#             echo -e "${GREEN}✅ Тест соединения пройден успешно!${NC}"
#         else
#             echo -e "${YELLOW}⚠️  Ответ получен, но не содержит ожидаемых данных${NC}"
#         fi
#     else
#         echo -e "❌ Не получен ответ на порту $dst_port"
#     fi
    
#     # Очистка временного файла
#     # rm -f "$response_file"
# }
# # Тестирование соединения
# test_connection() {
#     local src_port=$1
#     local dst_port=$2
#     echo -e "\n${BLUE}🧪 Тестирую соединение${NC}"
#     # Проверяем, слушает ли порт-источник
#     if nc -z localhost $src_port 2>/dev/null; then
#         echo -e "✅ Порт $src_port слушает"
#     else
#         echo -e "❌ Порт $src_port не отвечает"
#         # return 1
#     fi
#     # Пробуем отправить тестовые данные
#     test_msg="Test connection $(date)"
#     # Запускаем слушатель на dst_port в фоне
#     echo -e "Инициализировали слушателя"
#     timeout 3 nc -l -p $dst_port > /tmp/test_response &
#     #listener_pid=$(pgrep nc)
#     # Даем время на запуск слушателя
#     #sleep 0.2
#     echo -e "Отправляем сообщение на src_port"
#     # Отправляем сообщение на src_port
#     echo "$test_msg" | timeout 2 nc localhost $src_portmeout 3 nc -l -p $dst_port > /tmp/test_response &
#     #listener_pid=$(pgrep nc)
#     # Даем время на запуск слушателя
#     #sleep 0.2
#     echo -e "Отправляем сообщение на src_port"
#     # Отправляем сообщение на src_port
#     echo "$test_msg" | timeout 2 nc localhost $src_port
    
#     # Ждем завершения слушателя
#     #sleep 5
#     # Проверяем полученный ответ
#     if grep "Test" /tmp/test_response ; then
#         echo -e "✅ Успешно: отправили на $src_port, получили ответ на $dst_port"
#     else
#         echo -e "❌ Не удалось получить ответ на $dst_port"
#     fi

#     # Очистка
#     rm -f /tmp/test_response

#     if echo "$test_msg" | timeout 2 nc localhost $src_port | grep -q "Test"; then
#         echo -e "✅ Соединение работает"
#     else
#         echo -e "⚠️  Соединение установлено, но эхо не работает"
#     fi
# }
    # test_msg="Test connection $(date)"
    # if echo "Test connection" | timeout 2 nc localhost 80 | grep -q "Test"; then echo -e "✅ Соединение работает" ; fi
    # else
    #     echo -e "⚠️  Соединение установлено, но эхо не работает"
    # fi
# Основное меню
show_menu() {
    clear
    echo -e "${GREEN}=======================================${NC}"
    echo -e "${GREEN}    ПЕРЕНАПРАВЛЕНИЕ ЛОКАЛЬНЫХ ПОРТОВ   ${NC}"
    echo -e "${GREEN}=======================================${NC}"
    echo ""
    echo "1) Быстрый старт (два порта)"
    echo "2) Выбрать метод перенаправления"
    echo "3) Остановить перенаправление"
    echo "4) Показать статус"
    echo "5) Тестировать соединение"
    echo "6) Показать логи"
    echo "7) Выход"
    echo ""
    echo -n "Выберите [1-7]: "
}

# Главная функция
main() {
    check_netcat
    if [ $# -ge 2 ]; then
        # Если переданы два аргумента - быстрый запуск
        start_redirect $1 $2
        exit 0
    elif [ $# -eq 1 ]; then
        case $1 in
            stop)
                if [ $# -ge 2 ]; then
                    stop_redirect $2
                else
                    echo -n "Введите порт для остановки: "
                    read port
                    stop_redirect $port
                fi
                ;;
            status) show_status ;;
            test)
                if [ $# -ge 3 ]; then
                    test_connection $2 $3
                else
                    echo -n "Введите порт-источник: "
                    read src
                    echo -n "Введите порт-назначение: "
                    read dst
                    test_connection $src $dst
                fi
                ;;
            *) echo "Использование: $0 <порт_источник> <порт_назначение>" ;;
        esac
        exit 0
    fi
    # Интерактивный режим
    while true; do
        show_menu
        read choice
        case $choice in
            1)
                echo -n "Введите порт-источник: "
                read src
                echo -n "Введите порт-назначение: "
                read dst
                start_redirect $src $dst
                ;;
            2)
                echo -n "Введите порт-источник: "
                read src
                echo -n "Введите порт-назначение: "
                read dst
                echo ""
                echo "Выберите метод:"
                echo "1) Proxy (рекомендуется)"
                echo "2) Socat"
                echo "3) Netcat (простой)"
                echo "4) Rinetd"
                echo "5) SSH туннель"
                echo -n "Метод [1]: "
                read method
                start_redirect $src $dst ${method:-1}
                ;;
            3)
                echo -n "Введите порт для остановки: "
                read port
                stop_redirect $port
                ;;
            4)
                show_status
                ;;
            5)
                echo -n "Введите порт-источник: "
                read src
                echo -n "Введите порт-назначение: "
                read dst
                test_connection $src $dst
                ;;
            6)
                echo "Логи:"
                ls -la $DATA_DIR/*.log 2>/dev/null || echo "Логов нет"
                echo ""
                echo -n "Введите имя файла лога: "
                read logfile
                if [ -f "$DATA_DIR/$logfile" ]; then
                    tail -20 "$DATA_DIR/$logfile"
                fi
                ;;
            7)
                echo "Выход..."
                exit 0
                ;;
            *)
                echo "Неверный выбор"
                ;;
esac
        echo ""
        echo -n "Нажмите Enter для продолжения..."
        read
    done
}

# Запуск
main "$@"
