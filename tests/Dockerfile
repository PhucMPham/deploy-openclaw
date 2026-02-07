FROM ubuntu:22.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update -qq && apt-get install -y -qq \
    git curl sudo bats shellcheck && \
    git clone --depth 1 https://github.com/bats-core/bats-support /usr/lib/bats/bats-support && \
    git clone --depth 1 https://github.com/bats-core/bats-assert /usr/lib/bats/bats-assert && \
    git clone --depth 1 https://github.com/bats-core/bats-file /usr/lib/bats/bats-file && \
    rm -rf /var/lib/apt/lists/*
WORKDIR /workspace
COPY . /workspace
CMD ["bats", "--recursive", "tests/"]
