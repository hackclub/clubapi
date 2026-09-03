FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    curl \
    wget

RUN curl -fsSL -o /usr/bin/astra https://github.com/ArkForgeLabs/Astra/releases/latest/download/astra-luajit-linux-amd64 \
    && chmod +x /usr/bin/astra

WORKDIR /app

COPY . .

EXPOSE 3000 3000

CMD ["astra", "run", "server.lua"]
