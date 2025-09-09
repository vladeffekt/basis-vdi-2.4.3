# Базовый образ ALT Linux P10
FROM alt:p10

WORKDIR /tmp/vdi

# Копируем новые RPM-файлы в контейнер
COPY vdi-client-2.4.3-r278.n496a10.common.x86_64.rpm ./
COPY vms-vdi-env-python3-3.9.19-alt10basis1.x86_64.rpm ./

# Устанавливаем все необходимые системные зависимости
RUN apt-get update -y && \
    apt-get install -y \
        xorg-server \
        xorg-apps \
        xdotool \
        xinit \
        xauth \
        libqt5-widgets \
        libqt5-gui \
        libqt5-core \
        libqt5-x11extras \
        libqt5-svg \
        fontconfig \
        libxcb \
        libxkbcommon-x11 \
        libGL \
        pcsc-lite \
        libdbus \
        libdbus-glib \
        libffi7 \
        libssl1.1 \
        libgtk+3 \
        libX11 \
        libXtst \
        libXrandr \
        libalsa \
        libpam0 \
        python3-base \
        cpio \
        rpm-build \
        libyaml2 \
        samba-common-tools \
        openssl \
        openssl-gost-engine \
        systemd \
	      xfreerdp \
	      pulseaudio \
	      pulseaudio-utils \
	      freerdp-plugins-standard
	
RUN rpm -i vms-vdi-env-python3-3.9.19-alt10basis1.x86_64.rpm && \
    rpm -i vdi-client-2.4.3-r278.n496a10.common.x86_64.rpm

# Убеждаемся, что исполняемые файлы имеют правильные права
RUN chmod +x /opt/vdi-client/bin/desktop-client && \
    chmod +x /opt/vdi-client/bin/desktop-agent-linux

# Проверка установки: выводим список файлов и версию Python
RUN ls -la /opt/vdi-client/bin/ && \
    /opt/vms-vdi-env/python/bin/python3 --version

# Запуск клиента как основного процесса контейнера
CMD ["/opt/vdi-client/bin/desktop-client"]
