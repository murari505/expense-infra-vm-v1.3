# Expense app load test

`expense-load.mjs` puts realistic load on the expense app. Each simulated
user signs up, then keeps doing a random mix of real actions until the time
runs out: creating, listing, searching, updating and deleting expenses,
loading the dashboard summary, categories, budgets and insights, and signing
out and back in. Requests go through the ALB, just like a real browser.

## Requirements

- Node.js 18 or newer (`node --version`). Nothing else: no `npm install`.
- Run all commands from the `expense-infra-vm-v1.3` folder.

## Settings

All settings are environment variables. All are optional.

| Variable   | Default                        | Meaning                                                        |
|------------|--------------------------------|----------------------------------------------------------------|
| `BASE_URL` | **required**                   | App URL: `terraform output -raw app_url`                       |
| `VUS`      | `5`                            | Virtual users running at the same time                         |
| `DURATION` | `300`                          | Seconds to run                                                 |
| `THINK_MS` | `500`                          | Average pause between one user's actions (`0` = no pause)      |
| `RAMP`     | `10`                           | Seconds over which all users start                             |
| `ERRORS`   | off                            | `1` = also send some bad requests (400 / 401 / 404)            |

### Replace the domain

The app URL is `https://expense.<domain_name>`, where `domain_name` comes
from `terraform.tfvars`. Set `BASE_URL` to your own domain in every command
below, for example `https://expense.example.com`, or copy it from
`terraform output -raw app_url`. Without `BASE_URL` the script stops with a
message.

---

## Windows: PowerShell

```powershell
cd C:\learning\aiops-02\expense-infra-vm-v1.3

# basic run: 5 users, 5 minutes
$env:BASE_URL="https://expense.<your-domain>"
node loadtest\expense-load.mjs

# heavier: 20 users, 10 minutes, plus some error requests
$env:BASE_URL="https://expense.<your-domain>"; $env:VUS=20; $env:DURATION=600; $env:ERRORS="1"
node loadtest\expense-load.mjs

# no pauses between actions (stress test)
$env:VUS=50; $env:THINK_MS=0; $env:DURATION=300
node loadtest\expense-load.mjs
```

`$env:` variables stay set until you close that PowerShell window. To go
back to the defaults:

```powershell
Remove-Item Env:BASE_URL, Env:VUS, Env:DURATION, Env:THINK_MS, Env:RAMP, Env:ERRORS -ErrorAction SilentlyContinue
```

## Windows: Git Bash

```bash
cd /c/learning/aiops-02/expense-infra-vm-v1.3

# basic run
BASE_URL=https://expense.<your-domain> node loadtest/expense-load.mjs

# heavier: 20 users, 10 minutes, plus some error requests
BASE_URL=https://expense.<your-domain> VUS=20 DURATION=600 ERRORS=1 node loadtest/expense-load.mjs

# stress test
BASE_URL=https://expense.<your-domain> VUS=50 THINK_MS=0 DURATION=300 node loadtest/expense-load.mjs
```

`NAME=value` in front of the command applies to that one command only.

## macOS / Linux (Terminal)

Install Node if you don't have it: `brew install node`.

```bash
cd ~/path/to/expense-infra-vm-v1.3

# basic run
BASE_URL=https://expense.<your-domain> node loadtest/expense-load.mjs

# heavier: 20 users, 10 minutes, plus some error requests
BASE_URL=https://expense.<your-domain> VUS=20 DURATION=600 ERRORS=1 node loadtest/expense-load.mjs

# stress test
BASE_URL=https://expense.<your-domain> VUS=50 THINK_MS=0 DURATION=300 node loadtest/expense-load.mjs
```

To keep a setting for the whole terminal session, export it once:

```bash
export BASE_URL=https://expense.<your-domain>
node loadtest/expense-load.mjs
```

---

## Output

Every 30 seconds, and once at the end, the script prints a table like this:

```
=== final (15s) ===
action                  count  5xx/err   p50ms   p95ms  status codes
expense.create             10        0     244     297  201:10
categories.list             5        0     253     855  200:5
expense.list                3        0     295     378  200:3
signup                      1        0    2508    2508  201:1
```

- **5xx/err**: server errors, plus network errors or timeouts (code `0`).
  This should be `0`.
- **p50 / p95**: median and 95th-percentile latency in milliseconds.
- Press **Ctrl+C** to stop early. You still get the final table.

## What the load looks like

| Share | Action                                          |
|-------|-------------------------------------------------|
| 30%   | Create an expense                               |
| 15%   | List expenses (random sort and order)           |
| 5%    | Search expenses                                 |
| 12%   | Dashboard summary (this month or the last two)  |
| 12%   | Update an expense                               |
| 5%    | Delete an expense                               |
| 6%    | List categories                                 |
| 7%    | Set or list budgets                             |
| 6%    | Insights (trend and month)                      |
| 2%    | `/auth/me`, sign out and sign back in           |

As a rough guide, 20 users with the default 500 ms pause send about 30–40
requests per second. Signup and signin use bcrypt, which is CPU-heavy, so
starting many users at once raises backend CPU.

## Watch it in Prometheus

```promql
# requests per second, by route
sum by (route, method) (rate(http_request_duration_seconds_count{job="backend"}[1m]))

# p95 latency, by route
histogram_quantile(0.95, sum by (le, route) (rate(http_request_duration_seconds_bucket{job="backend"}[1m])))

# responses by status code
sum by (status_code) (rate(http_request_duration_seconds_count{job="backend"}[1m]))

# MySQL queries per second
rate(mysql_global_status_questions[1m])

# backend CPU
100 - avg by (instance) (rate(node_cpu_seconds_total{mode="idle", job="node"}[1m])) * 100
```

## Notes

- **Laptop limits.** Running from a laptop is fine up to about 50 users.
  Beyond that, your network or CPU can run out before the app does. For
  bigger tests, run the script from an EC2 instance.
- **Access.** Your public IP must be allowed by the ALB security group. It
  is open to `0.0.0.0/0` by default.
- **Test data.** Every run creates new users named
  `loadtest+<run>-<n>@example.com`. To clean them up, run this on the mysql
  VM (expenses and budgets are deleted along with their user):

  ```sql
  DELETE FROM users WHERE email LIKE 'loadtest+%@example.com';
  ```
