#!/bin/bash

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

DATA_DIR="$HOME/local_port_redirect"
mkdir -p "$DATA_DIR"

check_netcat() {
    if ! command -v nc &> /dev/null; then
        echo -e "${RED}netcat is not installed${NC}"
        exit 1
    fi
}

check_port() {
    local port=$1
    if lsof -Pi :$port -sTCP:LISTEN -t >/dev/null 2>&1; then
        local pid=$(lsof -ti:$port)
        local process=$(ps -p $pid -o comm= 2>/dev/null || echo "unknown")
        echo -e "${YELLOW} Port $port is taken by $process (PID: $pid)${NC}"
        return 1
    fi
    return 0
}

method_proxy() {
    local src_port=$1
    local dst_port=$2
    local pid_file="$DATA_DIR/proxy_${src_port}.pid"
        
    if [ ! -f "./proxy" ]; then
        echo -e "${YELLOW}Proxy is not found${NC}"
        if command -v make &> /dev/null; then
            make 2>/dev/null  make darwin 2>/dev/null 
            {
                echo -e "${RED}Unable to make binary${NC}"
                return 1
            }
        else
            echo -e "${RED}make is not installed${NC}"
            return 1
        fi
    fi
    
    ./proxy -l $src_port -h 127.0.0.1 -p $dst_port -i "tee -a input.log" -o "tee -a output.log" > "$DATA_DIR/proxy_${src_port}.log" 2>&1 &
    local pid=$(pgrep proxy)
    echo $pid > "$pid_file"
    
    sleep 1
    if ps -p $pid > /dev/null; then
        echo -e "${GREEN}Proxy is running (PID: $pid)${NC}"
        echo -e "   Port ${src_port} → ${dst_port}"
        echo -e "   Logs: ${DATA_DIR}/proxy_${src_port}.log"
    else
        echo -e "${RED}Unable to start proxy${NC}"
        return 1
    fi
}

start_redirect() {
    local src_port=$1
    local dst_port=$2
    local method=${3:-1}
    echo -e "\n${GREEN}Starting redirect${NC}"
    echo "Source: $src_port"
    echo "Destination: $dst_port"
    check_port $src_port || {
        read -p "Continue and kill process? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            fuser -k $src_port/tcp 2>/dev/null || true
            sleep 1
        else
            return 1
        fi
    }
    method_proxy $src_port $dst_port
}

stop_redirect() {
    local src_port=$1
    echo -e "\n${YELLOW}Stopping redirect $src_port${NC}"
    local stopped=0
    for pid_file in $DATA_DIR/*_${src_port}.pid; do
        if [ -f "$pid_file" ]; then
            local pid=$(cat "$pid_file")
            local method=$(basename "$pid_file" | cut -d_ -f1)
            if kill -0 $pid 2>/dev/null; then
                kill $pid
                echo -e "Stopped $method (PID: $pid)"
                stopped=1
            fi
            rm -f "$pid_file"
        fi
    done
    local port_pids=$(lsof -ti:$src_port 2>/dev/null || true)
    if [ -n "$port_pids" ]; then
        for pid in $port_pids; do
            if [ $pid -ne $$ ]; then
                kill $pid 2>/dev/null || true
                echo -e "Stoppped (PID: $pid)"
                stopped=1
            fi
        done
    fi
    if [ $stopped -eq 0 ]; then
        echo -e "ACtive redirect are not found: $src_port"
    fi
}

show_status() {
    echo -e "\n${BLUE}Status${NC}"
    echo "────────────────────────────────"
    local found=0
    for pid_file in $DATA_DIR/*.pid; do
        if [ -f "$pid_file" ]; then
            local port=$(basename "$pid_file" | grep -o '[0-9]\+\.pid$' | cut -d. -f1)
            local method=$(basename "$pid_file" | cut -d_ -f1)
            local pid=$(cat "$pid_file")
            if kill -0 $pid 2>/dev/null; then
                echo -e "${GREEN} $method: port $port (PID: $pid) - working${NC}"
                found=1
            else
                echo -e "${RED} $method: port $port (PID: $pid) - is not working${NC}"
                rm -f "$pid_file"
            fi
        fi
    done
    if [ $found -eq 0 ]; then
        echo -e "Do not have active redirect"
    fi
    echo -e "\n${BLUE}Listeningg ports:${NC}"
    netstat -tlnp 2>/dev/null | grep LISTEN | grep -E ":(6[0-9]{2,3}|7[0-9]{3}|8[0-9]{3}|9[0-9]{3})" || true
}
test_connection() {
    local src_port=$1
    local dst_port=$2
    
    echo -e "\n${CYAN}Testing proxy (kklis/proxy)${NC}"
    echo "Source: port $src_port"
    echo "Destination: port $dst_port"
    echo ""
    
    echo "PROXY_TEST_$(date +%s)_${RANDOM}" >> test_case.txt
    local log_file="/tmp/proxy_test"
    
    echo "1. Starting listener $dst_port..."
    nc -l -p "$dst_port" > "$log_file" &
    local nc_pid=$!
    
    sleep 0.5
    
    echo "2. Sending test data $src_port..."
    echo "Data: $(cat test_case.txt)"
    echo ""
    
    if echo "$(cat test_case.txt)" | nc -w 2 localhost "$src_port" 2>/dev/null; then
        echo "Sending"
    fi
    
    sleep 1
    
    echo "3. Checking"
    if [[ -s "$log_file" ]]; then
        local received=$(cat "$log_file")
        echo "Received: $received"
        local test_data=$(cat test_case.txt)
        if [[ "$received" == "$test_data" ]]; then
            echo -e "${GREEN} SUCCESS ${NC}"
            echo "   $src_port → $dst_port"
        else
            echo -e "${YELLOW}  Got corrupted data${NC}"
            echo "   Send: $test_data"
            echo "   Got:   $received"
        fi
    else
        echo -e "${RED} FAIL${NC}"
    fi
    
    kill "$nc_pid" 2>/dev/null
    rm -f "$log_file"
    rm -f test_case.txt
    echo ""
}

show_menu() {
    clear
    echo "1) Start"
    echo "2) Stop redirect"
    echo "3) Show status"
    echo "4) Test connection"
    echo "5) Show logs"
    echo "6) Exit"
    echo ""
    echo -n "Choose [1-6]: "
}

main() {
    check_netcat
    if [ $# -ge 2 ]; then
        start_redirect $1 $2
        exit 0
    elif [ $# -eq 1 ]; then
        case $1 in
            stop)
                if [ $# -ge 2 ]; then
                    stop_redirect $2
                else
                    echo -n "Choose port to stop: "
                    read port
                    stop_redirect $port
                fi
                ;;
            status) show_status ;;
            test)
                if [ $# -ge 3 ]; then
                    test_connection $2 $3
                else
                    echo -n "Source: "
                    read src
                    echo -n "Destination: "
                    read dst
                    test_connection $src $dst
                fi
                ;;
            *) echo "Usage: $0 <source> <destination>" ;;
        esac
        exit 0
    fi
    while true; do
        show_menu
        read choice
        case $choice in
            1)
                echo -n "source: "
                read src
                echo -n "destination: "
                read dst
                start_redirect $src $dst
                ;;

            2)
                echo -n "Port to stop: "
                read port
                stop_redirect $port
                ;;
            3)
                show_status
                ;;
            4)
                echo -n "source: "
                read src
                echo -n "destination: "
                read dst
                test_connection $src $dst
                ;;
            5)
                echo "Logs:"
                ls -la $DATA_DIR/*.log 2>/dev/null || echo "Логов нет"
                echo ""
                echo -n "Log name: "
                read logfile
                if [ -f "$DATA_DIR/$logfile" ]; then
                    tail -20 "$DATA_DIR/$logfile"
                fi
                ;;
            6)
                echo "Exit..."
                exit 0
                ;;
            *)
                echo "Unknown"
                ;;
esac
        echo ""
        echo -n "Type enter..."
        read
    done
}

main "$@"
