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
```

## Admin panel

The admin panel lives at `/admin`. Sign-in uses [Hack Club Auth](https://auth.hackclub.com), and only people added as admins can get in.

- **The superadmin** sees every key, its owner and its request history, and can reveal full keys (each reveal is audit-logged). They can create keys with any perms, including `admin`, and assign each key to an admin. They also invite admins, manage their emails, read the audit log, and can "view as" any admin, themselves included, to see the panel the way that admin does.
- **Admins** only see keys they own and the requests made with them, and only the first few characters of each key. They can create `read` or `write` keys, and rotate, rename or delete their own keys. Admin-perm keys can only be created by the superadmin.
- **Emails:** each admin can have several emails, and signing in with any of them is the same account.

`admin` keys can only be created from the panel; `POST /key/create` only creates `read` and `write` keys.

### Setup

1. Create an app at https://auth.hackclub.com/developer/apps with the redirect URI `<PUBLIC_URL>/admin/callback` (for production, `https://clubapi.hackclub.com/admin/callback`) and the `email` scope.
2. Set these environment variables:

| Variable | Description |
| --- | --- |
| `HCA_CLIENT_ID` | Client ID of the Hack Club Auth app |
| `HCA_CLIENT_SECRET` | Client secret of the Hack Club Auth app |
| `PUBLIC_URL` | Public base URL of the API, used to build the redirect URI |
| `REQUEST_LOG_RETENTION_DAYS` | How long request history is kept (default `90`) |

3. Create the superadmin once. The emails are only passed to this one command and aren't stored in config:

```bash
SUPERADMIN_NAME="Your Name" SUPERADMIN_EMAILS="you@hackclub.com,you@example.com" astra run scripts/superadmin.lua
```

On Orchard, run it inside the app's pod. Running it again adds the given emails to the existing superadmin, which is also how to recover access. Database tables are created automatically on startup.
