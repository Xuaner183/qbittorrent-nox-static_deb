#!/bin/bash

set -e

# Get version from JSON
JSON_URL="https://github.com/userdocs/qbittorrent-nox-static/releases/latest/download/dependency-version.json"
VERSION=$(wget -q -O - "$JSON_URL" | grep '"qbittorrent"' | sed 's/.*"qbittorrent": "\([^"]*\)".*/\1/')

# Variables
ARCH="amd64"
PACKAGE_NAME="qBittorrent-nox_${VERSION}_ubuntu24-${ARCH}.deb"

# 可选代理前缀，用于在中国大陆替换/加速 GitHub 文件下载。
# 例如: https://ghfile.geekertao.top/
# 将其设置为空字符串以禁用代理。
PROXY_URL="https://ghfile.geekertao.top/"

# 原始下载地址（不要修改）
ORIGINAL_DOWNLOAD_URL="https://github.com/userdocs/qbittorrent-nox-static/releases/latest/download/x86_64-qbittorrent-nox"

# 如果设置了 PROXY_URL，则在原始下载地址前拼接代理前缀，否则使用原始地址
if [ -n "$PROXY_URL" ]; then
    DOWNLOAD_URL="${PROXY_URL}${ORIGINAL_DOWNLOAD_URL}"
else
    DOWNLOAD_URL="$ORIGINAL_DOWNLOAD_URL"
fi

# Create temp dir
TEMP_DIR=$(mktemp -d)
PACKAGE_DIR="$TEMP_DIR/qbittorrent-nox"

mkdir -p "$PACKAGE_DIR/DEBIAN"
mkdir -p "$PACKAGE_DIR/usr/bin"

# Download and rename
wget -O "$PACKAGE_DIR/usr/bin/qbittorrent-nox" "$DOWNLOAD_URL"
chmod +x "$PACKAGE_DIR/usr/bin/qbittorrent-nox"

# Calculate installed size
INSTALLED_SIZE=$(du -s "$PACKAGE_DIR/usr" | cut -f1)

# Create control file
cat > "$PACKAGE_DIR/DEBIAN/control" << EOF
Package: qbittorrent-nox
Version: $VERSION
Section: net
Priority: optional
Architecture: $ARCH
Installed-Size: $INSTALLED_SIZE
Maintainer: sledgehammer999 <sledgehammer999@qbittorrent.org>
Description: Enhanced qBittorrent command-line client
 This package provides the qBittorrent client with enhanced features
 without the GUI interface.
EOF

# Create preinst
cat > "$PACKAGE_DIR/DEBIAN/preinst" << 'EOF'
#!/bin/sh
set -e

# 在升级或重新安装前，若服务正在运行则先停止，避免替换二进制时出现并发问题
if command -v systemctl >/dev/null 2>&1; then
    if systemctl is-active --quiet qbittorrent-nox.service; then
        systemctl stop qbittorrent-nox.service || true
    fi
fi

exit 0
EOF

chmod +x "$PACKAGE_DIR/DEBIAN/preinst"

# Create postinst
cat > "$PACKAGE_DIR/DEBIAN/postinst" << 'EOF'
#!/bin/sh
set -e

# 创建数据目录
mkdir -p /var/lib/qbittorrent
chmod 755 /var/lib/qbittorrent

# 设置系统服务
cat > /etc/systemd/system/qbittorrent-nox.service << 'EOS'
[Unit]
Description=qBittorrent Enhanced Command Line Client
After=network.target

[Service]
ExecStart=/usr/bin/qbittorrent-nox --profile=/var/lib/qbittorrent
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOS

# 启用服务（重载 systemd 配置并启用服务）
systemctl daemon-reload
systemctl enable qbittorrent-nox.service

# 在配置阶段，首次安装应启动服务；升级时重启服务以加载新二进制
if [ "$1" = "configure" ]; then
    if [ -z "$2" ]; then
        # fresh install
        systemctl start qbittorrent-nox.service
    else
        # upgrade: try to restart, if restart fails try to start
        systemctl restart qbittorrent-nox.service || systemctl start qbittorrent-nox.service
    fi
fi

ldconfig
EOF

chmod +x "$PACKAGE_DIR/DEBIAN/postinst"

# Create postrm
cat > "$PACKAGE_DIR/DEBIAN/postrm" << 'EOF'
#!/bin/sh
set -e

# 这是 qbittorrent-nox 包的 postrm 脚本
# 在删除包后执行清理操作

case "$1" in
  purge|remove|upgrade|failed-upgrade|abort-install|abort-upgrade|disappear)
    ;;
  *)
    echo "postrm called with unknown argument \`$1'" >&2
    exit 1
    ;;
esac

# 只有在完全清除 (purge) 时才删除数据目录
if [ "$1" = "purge" ] || [ "$1" = "disappear" ]; then
    # 停止服务 (如果还在运行)
    if systemctl is-active --quiet qbittorrent-nox.service; then
        systemctl stop qbittorrent-nox.service
    fi

    # 禁用服务
    systemctl disable qbittorrent-nox.service >/dev/null 2>&1 || true

    # 删除数据目录
    if [ -d /var/lib/qbittorrent ]; then
        rm -rf /var/lib/qbittorrent
    fi

    # 删除服务配置文件
    if [ -f /etc/systemd/system/qbittorrent-nox.service ]; then
        rm -f /etc/systemd/system/qbittorrent-nox.service
    fi

    # 重新加载 systemd
    systemctl daemon-reload >/dev/null 2>&1 || true
fi

# 在 remove 时只执行基本清理
if [ "$1" = "remove" ] || [ "$1" = "upgrade" ] || [ "$1" = "abort-upgrade" ] || [ "$1" = "failed-upgrade" ]; then
    # 停止服务
    if systemctl is-active --quiet qbittorrent-nox.service; then
        systemctl stop qbittorrent-nox.service
    fi

    # 重新加载 systemd
    systemctl daemon-reload >/dev/null 2>&1 || true
fi

exit 0
EOF

chmod +x "$PACKAGE_DIR/DEBIAN/postrm"

# Build deb
dpkg-deb --build "$PACKAGE_DIR" "$PACKAGE_NAME"

echo "Deb package created: $PACKAGE_NAME"

# Clean up
rm -rf "$TEMP_DIR"