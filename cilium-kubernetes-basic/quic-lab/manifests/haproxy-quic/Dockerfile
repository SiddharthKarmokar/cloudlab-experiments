# The official haproxy image is built against stock OpenSSL and has no QUIC.
# HAProxy needs either quictls or AWS-LC for its QUIC stack; AWS-LC is the
# option HAProxy upstream now recommends and it links statically, so the
# runtime image stays small and has no patched-OpenSSL footgun.
#
# Build with quic-lab/manifests/haproxy-quic/build-and-push.sh -- it asserts
# that QUIC is actually compiled in before the image is allowed to exist.
FROM debian:bookworm AS build

RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential ca-certificates cmake git golang \
      libpcre2-dev liblua5.4-dev ninja-build zlib1g-dev curl \
 && rm -rf /var/lib/apt/lists/*

ARG AWSLC_VERSION=v1.39.0
RUN git clone --depth 1 -b "${AWSLC_VERSION}" https://github.com/aws/aws-lc.git /src/aws-lc \
 && cmake -B /src/aws-lc/build -S /src/aws-lc -GNinja \
      -DCMAKE_BUILD_TYPE=Release \
      -DBUILD_SHARED_LIBS=OFF \
      -DBUILD_TESTING=OFF \
      -DDISABLE_GO=ON \
      -DCMAKE_INSTALL_PREFIX=/opt/aws-lc \
 && ninja -C /src/aws-lc/build install

# Resolved from the branch index rather than pinned, so this keeps building as
# HAProxy ships patch releases.
ARG HAPROXY_BRANCH=3.2
RUN set -eux; \
    idx="https://www.haproxy.org/download/${HAPROXY_BRANCH}/src/"; \
    ver="$(curl -fsSL "$idx" \
           | grep -oE "haproxy-${HAPROXY_BRANCH}\.[0-9]+\.tar\.gz" \
           | sort -V | tail -1)"; \
    test -n "$ver"; \
    echo "building $ver"; \
    mkdir -p /src/haproxy; \
    curl -fsSL "${idx}${ver}" | tar xz --strip-components=1 -C /src/haproxy

RUN make -C /src/haproxy -j"$(nproc)" \
      TARGET=linux-glibc \
      USE_OPENSSL_AWSLC=1 \
      SSL_INC=/opt/aws-lc/include \
      SSL_LIB=/opt/aws-lc/lib \
      USE_QUIC=1 \
      USE_PCRE2=1 USE_PCRE2_JIT=1 \
      USE_LUA=1 LUA_INC=/usr/include/lua5.4 LUA_LIB_NAME=lua5.4 \
      USE_ZLIB=1 USE_PROMEX=1 USE_THREAD=1 \
 && make -C /src/haproxy install-bin

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
      libpcre2-8-0 liblua5.4-0 zlib1g ca-certificates curl \
 && rm -rf /var/lib/apt/lists/*
COPY --from=build /usr/local/sbin/haproxy /usr/local/sbin/haproxy

# Fail the build rather than discovering at 2am that the arm silently fell back
# to TCP-only. QUIC must be listed as supported AND not marked as disabled.
RUN haproxy -vv | tee /tmp/v \
 && grep -qiE 'quic' /tmp/v \
 && ! grep -qiE 'QUIC support.*(no|disabled)' /tmp/v \
 && rm /tmp/v

ENTRYPOINT ["/usr/local/sbin/haproxy"]
CMD ["-f", "/etc/haproxy/haproxy.cfg", "-db"]
