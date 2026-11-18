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

The admin panel lives at `/admin`. Sign-in uses [Hack Club Auth](https://auth.hackclub.com), and only people the superadmin has added can get in. Everyone has one of three roles:

| | superadmin | admin | keyholder |
| --- | --- | --- | --- |
| Sees keys and their request activity | all | all | their own |
| Creates keys | any perms, any owner | `read` or `write`, owned by them | no |
| Rotates, renames, deletes, changes perms | any key | their own keys | no |
| Sees a full key | at create/rotate, and can reveal any key later (audit-logged) | once, at create/rotate | never |
| Reassigns keys, manages people, reads the audit log, "view as" | yes | no | no |

- Admins and keyholders only ever see the first few characters of an existing key. A keyholder's keys are created and assigned to them by the superadmin.
- The superadmin can "view as" anyone to see the panel with that person's role. Viewing as themselves shows the admin view.
- **Emails:** each person can have several emails, and signing in with any of them is the same account.
- The roles and what each may do live in one table, `CAPABILITIES` in [utils/admin.lua](utils/admin.lua). Routes check it with `admin.can()` and the dashboard renders from the same table.

`admin` keys can only be created from the panel; `POST /key/create` only creates `read` and `write` keys.

Upgrading from the single `is_superadmin` flag happens automatically on startup: the superadmin stays the superadmin and everyone else becomes a keyholder, so nobody sees more than before. Promote the ones who should be admins from the People tab.

### Setup

1. Create an app at https://auth.hackclub.com/developer/apps with the redirect URI `<PUBLIC_URL>/admin/callback` (for production, `https://clubapi.hackclub.com/admin/callback`) and the `openid` and `email` scopes.
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

### Testing locally

The `/admin` routes only use Postgres, so the panel can be tried without Airtable or Hack Club Auth:

```bash
# .env: DATABASE_URL pointing at a local database, PUBLIC_URL=http://localhost:3000, ADMIN_DEV_LOGIN=1
astra run scripts/seed.lua   # a superadmin, two admins, two keyholders, 12 keys, fake requests and audit rows
astra run server.lua         # then open http://localhost:3000/admin/dev-login
```

`/admin/dev-login` signs in as any existing person with no password. It only exists when `ADMIN_DEV_LOGIN=1` **and** `PUBLIC_URL` is `localhost`, `127.0.0.1` or `[::1]`; anywhere else the route isn't registered. Never set the flag on a deployed instance. The seed script refuses to run unless `DATABASE_URL` and `PUBLIC_URL` are both local, and won't touch a database that already has people in it unless you pass `SEED_RESET=1`, which wipes the admin tables first.
