FROM alpine:3.19 as builder

ENV TZ=Asia/Shanghai
ARG TAG=actions
ENV TAG=${TAG}

WORKDIR /app
COPY ./docker/entrypoint.sh /app/entrypoint.sh
COPY ./docker/http_server.js /app/http_server.js
COPY ./docker/mkworld_custom.cpp /app/patch/mkworld_custom.cpp

# init tool
RUN set -x\
    && apk update\
    && apk add --no-cache git python3 npm make g++ linux-headers curl pkgconfig openssl-dev jq build-base gcc cmake go \
    && echo "env prepare success!"

# make zerotier-one
RUN set -x\
    && curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y\
    && source "$HOME/.cargo/env"\
    && git clone https://github.com/zerotier/ZeroTierOne.git\
    && cd ZeroTierOne\
    && git checkout ${TAG}\
    && echo "切换到tag:${TAG}"\
    && make ZT_SYMLINK=1 \
    && make -j\
    && make install\
    && echo "make success!"\
    && (zerotier-one -d || true)\
    && sleep 5s\
    && (pkill -9 zerotier-one || true)\
    && echo "zerotier-one init success!"\
    && cd /app/ZeroTierOne/attic/world \
    && cp /app/patch/mkworld_custom.cpp .\
    && mv mkworld.cpp mkworld.cpp.bak \
    && mv mkworld_custom.cpp mkworld.cpp \
    \
    # 【关键修改】不再直接运行 build.sh，而是手动执行编译，并增加必要的库和检查
    && echo "🔍 检查源文件是否存在..." \
    && ls -la ../../node/C25519.cpp ../../node/Identity.cpp || (echo "❌ 源文件缺失！检查 TAG 版本是否正确" && exit 1) \
    \
    && echo "🔨 开始编译 mkworld (增加 -lpthread -lssl -lcrypto)..." \
    && c++ -std=c++11 \
       -I../.. \
       -I../../ext \
       -I.. \
       -g \
       -o mkworld \
       ../../node/C25519.cpp \
       ../../node/Salsa20.cpp \
       ../../node/SHA512.cpp \
       ../../node/Identity.cpp \
       ../../node/Utils.cpp \
       ../../node/InetAddress.cpp \
       ../../osdep/OSUtils.cpp \
       mkworld.cpp \
       -lm -lpthread -lssl -lcrypto \
>&1 | tee /tmp/compile_error.log \
    \
    # 如果编译失败，打印详细错误并退出
    || (echo "❌ 编译失败！详细错误如下：" && cat /tmp/compile_error.log && exit 1) \
    \
    && echo "✅ mkworld 编译成功!" \
    && mkdir -p /var/lib/zerotier-one \
    && mv mkworld /var/lib/zerotier-one\
    && echo "mkworld build success!"

# make ztncui 
RUN set -x \
    && mkdir /app -p \
    &&  cd /app \
    && git clone --progress https://github.com/TrueSaveWorldPig/ztncui.git\
    && cd /app/ztncui/src \
    && npm config set registry https://registry.npmmirror.com\
    && npm install -g node-gyp\
    && npm install 

FROM alpine:3.19

WORKDIR /app

ENV IP_ADDR4=''
ENV IP_ADDR6=''
ENV ZT_PORT=9994
ENV API_PORT=3443
ENV FILE_SERVER_PORT=3000
ENV GH_MIRROR="https://mirror.ghproxy.com/"
ENV FILE_KEY=''
ENV TZ=Asia/Shanghai

COPY --from=builder /app/ztncui /bak/ztncui
COPY --from=builder /var/lib/zerotier-one /bak/zerotier-one
COPY --from=builder /usr/sbin/zerotier-one /usr/sbin/zerotier-one
COPY --from=builder /app/entrypoint.sh /app/entrypoint.sh
COPY --from=builder /app/http_server.js /app/http_server.js

RUN set -x \
    && apk update \
    && apk add --no-cache npm curl jq openssl\
    && mkdir /app/config -p 

VOLUME [ "/app/dist","/app/ztncui","/var/lib/zerotier-one","/app/config"]

CMD ["/bin/sh","/app/entrypoint.sh"]
