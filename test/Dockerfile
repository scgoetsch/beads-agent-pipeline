# Clean boxes for ./selftest.sh. Two targets:
#   bare  git + python3 + bash and nothing else the pipeline lists: no cairn, jq, rg.
#         Exercises the installer's "required command absent" exit and every optional fallback.
#   full  bare + cairn (github.com/scgoetsch/cairn at CAIRN_REF) + jq + ripgrep.
#         Exercises cairn init, the hooks, the store stanza and the whole suite.
# Built and run by test/selftest-in-container.sh; nothing here is installed anywhere.
FROM ubuntu:24.04 AS bare
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
 && apt-get install -y --no-install-recommends git python3 ca-certificates curl \
 && rm -rf /var/lib/apt/lists/*
# The suites write under $HOME; a non-root user is the real case.
RUN useradd -m -s /bin/bash tester
USER tester
WORKDIR /home/tester
ENV HOME=/home/tester PATH=/home/tester/.local/bin:/usr/local/bin:/usr/bin:/bin
RUN git config --global user.email tester@example.invalid \
 && git config --global user.name tester \
 && git config --global init.defaultBranch main

FROM bare AS full
USER root
RUN apt-get update \
 && apt-get install -y --no-install-recommends jq ripgrep \
 && rm -rf /var/lib/apt/lists/*
USER tester
# cairn: a clone at a pinned commit (the commit of cairn's tag v0.7.0) and a symlink of bin/cairn,
# as its README installs it. Keep CAIRN_REF in step with .github/workflows/selftest.yml.
ARG CAIRN_REF=07550872866f9edb949360f564601a4b463a5199
RUN git init -q /home/tester/cairn \
 && git -C /home/tester/cairn fetch -q --depth 1 https://github.com/scgoetsch/cairn "$CAIRN_REF" \
 && git -C /home/tester/cairn checkout -q FETCH_HEAD \
 && mkdir -p /home/tester/.local/bin \
 && ln -s /home/tester/cairn/bin/cairn /home/tester/.local/bin/cairn \
 && cairn --version
