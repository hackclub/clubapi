# Clubs API
[![CI](https://hackatime-badge.hackclub.com/U07UV4R2G4T/clubapi)](https://hackatime.hackclub.com)

API For interacting with clubs data. Written in Lua using the [Astra](https://astra.arkforge.net/) web framework

API Documentation: https://clubapi.hackclub.com

If you need a API key for a Hack Club sponsored project, email wally@hackclub.com or dm [@wbs](https://hackclub.enterprise.slack.com/team/U09AYT4B1JB) on the [Hack Club Slack](https://hackclub.com/slack/)

## Setup

Requirements: [Astra](https://astra.arkforge.net/), Git 

```bash
git clone https://github.com/hackclub/clubapi
cp example.env .env # then fill out the .env
astra run server.lua
