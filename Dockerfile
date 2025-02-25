# 基础镜像
FROM docker.io/tiger7/alpine:dev AS Builder

# 指定Nginx版本
ARG NGINX_VERSION=1.21.4

# 指定nginx的位置
ARG NGINX_PATH=/usr/local/nginx
ARG NGINX_CONF=/usr/local/nginx/conf

# 编译安装nginx
RUN CONFIG="\
        --prefix=$NGINX_PATH \
        --conf-path=$NGINX_CONF/nginx.conf \
        --error-log-path=/var/log/nginx/error.log \
        --http-log-path=/var/log/nginx/access.log \
        --pid-path=/var/run/nginx.pid \
        --lock-path=/var/run/nginx.lock \
        --http-client-body-temp-path=/var/cache/nginx/client_temp \
        --http-proxy-temp-path=/var/cache/nginx/proxy_temp \
        --http-fastcgi-temp-path=/var/cache/nginx/fastcgi_temp \
        --http-uwsgi-temp-path=/var/cache/nginx/uwsgi_temp \
        --http-scgi-temp-path=/var/cache/nginx/scgi_temp \
        --user=nginx \
        --group=nginx \
        --with-http_ssl_module \
        --with-http_stub_status_module \
        --add-dynamic-module=/usr/src/nginx-http-flv-module \
    " \
    # 下载nginx和最新的http-flv-module
    && curl -fSL http://nginx.org/download/nginx-$NGINX_VERSION.tar.gz -o nginx.tar.gz \
    && git clone https://github.com/winshining/nginx-http-flv-module.git --depth 1 \
    && mkdir -p /usr/src \
    && tar -zxC /usr/src -f nginx.tar.gz \
    && mv nginx-http-flv-module /usr/src/nginx-http-flv-module \
    && rm nginx.tar.gz \
    && cd /usr/src/nginx-$NGINX_VERSION \
    && ./configure $CONFIG --with-debug \
    && make -j$(getconf _NPROCESSORS_ONLN) \
    && make install \
    # 缩小文件大小
    && strip $NGINX_PATH/sbin/nginx* \
    && strip $NGINX_PATH/modules/*.so \
    # 拷贝rtmp的xsl文件
    && mkdir $NGINX_PATH/html/rtmp \
    && cp /usr/src/nginx-http-flv-module/stat.xsl $NGINX_PATH/html/rtmp/stat.xsl \
    && rm -rf /usr/src/nginx-$NGINX_VERSION \
    && rm -rf /usr/src/nginx-http-flv-module \ 
    # 获取nginx运行需要的库（下面的打包阶段无法获取，除非写死）
    && runDeps="$( \
        scanelf --needed --nobanner $NGINX_PATH/sbin/nginx $NGINX_PATH/modules/*.so /tmp/envsubst \
            | awk '{ gsub(/,/, "\nso:", $2); print "so:" $2 }' \
            | sort -u \
            | xargs -r apk info --installed \
            | sort -u \
    )" \
    # 保存到文件，给打包阶段使用
    && echo $runDeps >> $NGINX_PATH/nginx.depends


# 打包阶段
# 基础镜像
FROM alpine:latest AS nginx-flv

# 指定nginx的位置
ARG NGINX_PATH=/usr/local/nginx

# 定义一个环境变量，方便后面运行时可以进行替换
ENV NGINX_CONF /usr/local/nginx/conf/nginx.conf

# 从build中拷贝编译好的文件
COPY --from=Builder $NGINX_PATH $NGINX_PATH
# 下面链接stderr和stdout需要的文件
COPY --from=Builder /var/log/nginx /var/log/nginx

# 将目录下的文件copy到镜像中(默认的配置文件)
COPY nginx.conf $NGINX_CONF
# 拷贝启动命令
COPY start.sh /etc/start.sh

# 修改源及添加用户
RUN echo "http://mirrors.aliyun.com/alpine/latest-stable/main/" > /etc/apk/repositories \
    && echo "http://mirrors.aliyun.com/alpine/latest-stable/community/" >> /etc/apk/repositories \
    # 添加nginx运行时的用户  
    && addgroup -S nginx \
    && adduser -D -S -h /var/cache/nginx -s /sbin/nologin -G nginx nginx 
    
# 安装启动依赖项
RUN apk update \
    # 从编译阶段读取需要的库
    && runDeps="$( cat $NGINX_PATH/nginx.depends )" \
    #&& echo $runDeps \
    # 通过上面查找nginx运行需要的库
    && apk add --no-cache --virtual .nginx-rundeps $runDeps \
    # 移动html文件到/var/www,这是和nginx.conf保持一直
    && mv $NGINX_PATH/html /var/www \ 
    # forward request and error logs to docker log collector
    #&& ln -sf /dev/stdout /var/log/nginx/access.log \
    #&& ln -sf /dev/stderr /var/log/nginx/error.log \
    && chmod +x /etc/start.sh

# 开放80和1935端口
EXPOSE 80

# 使用这个指令允许用户自定义应用在收到 docker stop 所发送的信号，是通过重写 signal 库内的 stopsignal 来支持自定义信号的传递，在上层调用时则将用户自定义的信号传入底层函数
STOPSIGNAL SIGTERM

# 启动nginx命令
CMD ["/bin/sh", "/etc/start.sh"]
