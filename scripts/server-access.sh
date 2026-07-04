#!/bin/bash
# server-access.sh - 阿里云服务器访问工具
# 用法: ./scripts/server-access.sh <command>
# 示例: ./scripts/server-access.sh status

SERVER_IP="47.98.144.243"
SERVER_USER="root"

# SSH 连接函数（使用 sshpass）
ssh_cmd() {
    sshpass -p "${SERVER_PASSWORD}" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=30 ${SERVER_USER}@${SERVER_IP} "$@"
}

# 检查服务器连接
check_connection() {
    echo "=== 检查服务器连接 ==="
    ssh_cmd "echo '✅ 连接成功' && uname -a"
}

# 查看 Runner 状态
runner_status() {
    echo "=== Runner 状态 ==="
    ssh_cmd "
echo '--- github-runner (c_cpp_to_rust_verify) ---'
systemctl status github-runner | head -5
echo ''
echo '--- github-runner-c2rust (c_cpp_to_rust) ---'
systemctl status github-runner-c2rust | head -5
echo ''
echo '--- Runner 版本 ---'
/home/runner/actions-runner/bin/Runner.Listener --version 2>&1
/home/runner/actions-runner-c2rust/bin/Runner.Listener --version 2>&1
"
}

# 重启 Runner
runner_restart() {
    local runner=${1:-all}
    echo "=== 重启 Runner: $runner ==="
    if [ "$runner" = "all" ] || [ "$runner" = "verify" ]; then
        ssh_cmd "systemctl restart github-runner"
        echo "✅ github-runner 已重启"
    fi
    if [ "$runner" = "all" ] || [ "$runner" = "c2rust" ]; then
        ssh_cmd "systemctl restart github-runner-c2rust"
        echo "✅ github-runner-c2rust 已重启"
    fi
}

# 查看 Docker 状态
docker_status() {
    echo "=== Docker 状态 ==="
    ssh_cmd "
docker ps --format 'table {{.ID}}\t{{.Status}}\t{{.Names}}' | head -10
echo ''
echo '--- Docker 镜像 ---'
docker images | grep -E 'c2rust|ubuntu' | head -10
"
}

# 查看服务器资源
server_resources() {
    echo "=== 服务器资源 ==="
    ssh_cmd "
echo '--- CPU ---'
top -bn1 | head -5
echo ''
echo '--- 内存 ---'
free -h
echo ''
echo '--- 磁盘 ---'
df -h / | tail -1
"
}

# 查看 Runner 日志
runner_logs() {
    local runner=${1:-verify}
    echo "=== Runner 日志 ($runner) ==="
    if [ "$runner" = "verify" ]; then
        ssh_cmd "tail -50 /home/runner/actions-runner/_diag/Runner_*.log 2>/dev/null | tail -30"
    else
        ssh_cmd "tail -50 /home/runner/actions-runner-c2rust/_diag/Runner_*.log 2>/dev/null | tail -30"
    fi
}

# 主函数
main() {
    # 检查环境变量
    if [ -z "$SERVER_PASSWORD" ]; then
        echo "❌ 请设置环境变量 SERVER_PASSWORD"
        echo "   export SERVER_PASSWORD='your_password'"
        exit 1
    fi

    # 检查 sshpass
    if ! command -v sshpass &> /dev/null; then
        echo "❌ sshpass 未安装，请先安装:"
        echo "   brew install hudochenkov/sshpass/sshpass"
        exit 1
    fi

    local command=${1:-help}
    case $command in
        connection|conn)
            check_connection
            ;;
        status|st)
            runner_status
            ;;
        restart|rs)
            runner_restart ${2:-all}
            ;;
        docker|dk)
            docker_status
            ;;
        resources|res)
            server_resources
            ;;
        logs|log)
            runner_logs ${2:-verify}
            ;;
        help|--help|-h)
            echo "用法: ./scripts/server-access.sh <command>"
            echo ""
            echo "命令:"
            echo "  connection, conn   检查服务器连接"
            echo "  status, st         查看 Runner 状态"
            echo "  restart, rs        重启 Runner (all|verify|c2rust)"
            echo "  docker, dk         查看 Docker 状态"
            echo "  resources, res     查看服务器资源"
            echo "  logs, log          查看 Runner 日志 (verify|c2rust)"
            echo "  help               显示帮助"
            ;;
        *)
            echo "❌ 未知命令: $command"
            echo "   运行 ./scripts/server-access.sh help 查看帮助"
            exit 1
            ;;
    esac
}

main "$@"
