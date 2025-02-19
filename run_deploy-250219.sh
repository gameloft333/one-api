#!/bin/bash

# 设置颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 日志函数
log_info() {
    echo -e "${GREEN}[INFO] $1${NC}"
}

log_warn() {
    echo -e "${YELLOW}[WARN] $1${NC}"
}

log_error() {
    echo -e "${RED}[ERROR] $1${NC}"
}

# 安装依赖函数
install_dependency() {
    local cmd=$1
    log_info "正在安装 $cmd..."
    
    # 检测操作系统类型
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
    else
        OS=$(uname -s)
    fi
    
    case $OS in
        ubuntu|debian)
            # 更新包管理器
            apt-get update -y > /dev/null 2>&1
            
            case $cmd in
                docker)
                    # 安装 Docker
                    apt-get remove docker docker-engine docker.io containerd runc -y > /dev/null 2>&1 || true
                    apt-get install ca-certificates curl gnupg lsb-release -y > /dev/null 2>&1
                    mkdir -p /etc/apt/keyrings
                    curl -fsSL https://download.docker.com/linux/$OS/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
                    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$OS $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
                    apt-get update -y > /dev/null 2>&1
                    apt-get install docker-ce docker-ce-cli containerd.io -y > /dev/null 2>&1
                    systemctl enable docker > /dev/null 2>&1
                    systemctl start docker > /dev/null 2>&1
                    ;;
                docker-compose)
                    # 安装 Docker Compose
                    curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose > /dev/null 2>&1
                    chmod +x /usr/local/bin/docker-compose
                    ;;
            esac
            ;;
            
        centos|rhel|fedora)
            # 更新包管理器
            yum update -y > /dev/null 2>&1
            
            case $cmd in
                docker)
                    # 安装 Docker
                    yum remove docker docker-client docker-client-latest docker-common docker-latest docker-latest-logrotate docker-logrotate docker-engine -y > /dev/null 2>&1 || true
                    yum install -y yum-utils > /dev/null 2>&1
                    yum-config-manager --add-repo https://download.docker.com/linux/$OS/docker-ce.repo > /dev/null 2>&1
                    yum install docker-ce docker-ce-cli containerd.io -y > /dev/null 2>&1
                    systemctl enable docker > /dev/null 2>&1
                    systemctl start docker > /dev/null 2>&1
                    ;;
                docker-compose)
                    # 安装 Docker Compose
                    curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose > /dev/null 2>&1
                    chmod +x /usr/local/bin/docker-compose
                    ;;
            esac
            ;;
            
        *)
            log_error "不支持的操作系统: $OS"
            exit 1
            ;;
    esac
    
    # 验证安装
    if command -v $cmd &> /dev/null; then
        log_info "$cmd 安装成功 ✓"
        return 0
    else
        log_error "$cmd 安装失败"
        exit 1
    fi
}

# 检查并安装必要的依赖
check_requirements() {
    log_info "检查环境依赖..."
    
    # 检查是否为 root 用户
    if [ "$EUID" -ne 0 ]; then
        log_error "请使用 root 用户运行此脚本"
        exit 1
    fi
    
    commands=("docker" "docker-compose")
    for cmd in "${commands[@]}"; do
        if ! command -v $cmd &> /dev/null; then
            log_warn "$cmd 未安装，正在自动安装..."
            install_dependency $cmd
        else
            log_info "$cmd 已安装 ✓"
        fi
    done
    
    # 将当前用户添加到 docker 组
    if ! groups $USER | grep &>/dev/null '\bdocker\b'; then
        usermod -aG docker $USER > /dev/null 2>&1
        log_info "已将当前用户添加到 docker 组 ✓"
    fi
    
    log_info "环境依赖检查完成 ✓"
}

# 检查必要的目录
check_directories() {
    log_info "检查必要目录..."
    
    directories=("./data/oneapi" "./data/mysql" "./logs")
    for dir in "${directories[@]}"; do
        if [ ! -d "$dir" ]; then
            log_info "创建目录: $dir"
            mkdir -p "$dir"
        fi
    done
    
    # 设置目录权限
    chmod -R 755 ./data
    chmod -R 755 ./logs
    
    log_info "目录检查完成 ✓"
}

# 检查数据库连接
check_db_connection() {
    log_info "检查数据库连接..."
    
    # 等待数据库启动
    for i in {1..30}; do
        if docker-compose -f docker-compose-250219.yml exec db mysqladmin ping -h localhost -u gameloft -pFabsbumVdxFWIe6f --silent; then
            log_info "数据库连接成功 ✓"
            return 0
        fi
        log_warn "等待数据库启动... ($i/30)"
        sleep 2
    done
    
    log_error "数据库连接失败"
    return 1
}

# 备份数据库
backup_database() {
    log_info "开始备份数据库..."
    
    # 创建备份目录
    BACKUP_DIR="./backups"
    mkdir -p $BACKUP_DIR
    
    # 生成备份文件名
    BACKUP_FILE="$BACKUP_DIR/gameloft_$(date +%Y%m%d_%H%M%S).sql"
    
    # 执行备份
    if docker-compose -f docker-compose-250219.yml exec db mysqldump -u gameloft -pFabsbumVdxFWIe6f gameloft > "$BACKUP_FILE"; then
        log_info "数据库备份完成: $BACKUP_FILE ✓"
        # 只保留最近7天的备份
        find $BACKUP_DIR -name "gameloft_*.sql" -mtime +7 -delete
    else
        log_warn "数据库备份失败，继续部署..."
    fi
}

# 主部署函数
deploy() {
    log_info "开始部署 One API..."
    
    # 1. 检查环境
    check_requirements
    check_directories
    
    # 2. 停止现有服务
    log_info "停止现有服务..."
    docker-compose -f docker-compose-250219.yml down --remove-orphans
    
    # 3. 拉取最新镜像
    log_info "拉取最新镜像..."
    docker-compose -f docker-compose-250219.yml pull
    
    # 4. 启动服务
    log_info "启动服务..."
    docker-compose -f docker-compose-250219.yml up -d
    
    # 5. 检查数据库连接
    check_db_connection
    if [ $? -eq 0 ]; then
        # 6. 备份数据库
        backup_database
    fi
    
    # 7. 检查服务健康状态
    log_info "检查服务健康状态..."
    for i in {1..30}; do
        if curl -s http://localhost:12181/api/status | grep -q "success.*true"; then
            log_info "One API 服务启动成功 ✓"
            log_info "访问地址: http://localhost:12181"
            return 0
        fi
        log_warn "等待服务就绪... ($i/30)"
        sleep 2
    done
    
    log_error "服务启动可能存在问题，请检查日志"
    docker-compose -f docker-compose-250219.yml logs one-api
    return 1
}

# 执行部署
deploy