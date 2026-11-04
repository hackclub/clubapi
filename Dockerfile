FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    curl \
    wget

ARG ASTRA_VERSION=v0.52.0

RUN curl -fsSL -o /usr/bin/astra https://github.com/ArkForgeLabs/Astra/releases/download/${ASTRA_VERSION}/astra-luajit-linux-amd64 \
    && chmod +x /usr/bin/astra

WORKDIR /app

COPY . .

EXPOSE 3000 3000

CMD ["astra", "run", "server.lua"]
