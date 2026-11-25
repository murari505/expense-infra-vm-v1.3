#!/usr/bin/env node
// Expense app load generator (no dependencies, Node 18+).
//
// Each virtual user (VU) signs up, then loops through a weighted mix of real
// user actions until the duration ends: create / list / update / delete
// expenses, dashboard summary, categories, budgets, insights, sign out + in.
//
//   BASE_URL=https://expense.<your-domain> node loadtest/expense-load.mjs                # 5 VUs, 5 minutes
//   BASE_URL=https://expense.<your-domain> VUS=20 DURATION=600 node loadtest/expense-load.mjs
//
// Env:
//   BASE_URL   app URL through the ALB      (required: terraform output -raw app_url)
//   VUS        concurrent virtual users      (default 5)
//   DURATION   seconds to run                (default 300)
//   THINK_MS   avg pause between actions     (default 500; 0 = flat out)
//   RAMP       seconds to start all VUs      (default 10)
//   ERRORS=1   also send some bad requests (400/401/404) so error panels move

if (!process.env.BASE_URL) {
  console.error('Set BASE_URL to the app URL, e.g. https://expense.<your-domain> (terraform output -raw app_url).');
  process.exit(1);
}
const BASE_URL = process.env.BASE_URL.replace(/\/$/, '');
const VUS = Number(process.env.VUS || 5);
const DURATION = Number(process.env.DURATION || 300) * 1000;
const THINK_MS = Number(process.env.THINK_MS ?? 500);
const RAMP = Number(process.env.RAMP || 10) * 1000;
const ERRORS = process.env.ERRORS === '1';
const PASSWORD = 'LoadTest#12345';
const RUN_ID = Date.now().toString(36);

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const pick = (arr) => arr[Math.floor(Math.random() * arr.length)];
const rand = (min, max) => Math.round((min + Math.random() * (max - min)) * 100) / 100;
const think = () => (THINK_MS > 0 ? sleep(THINK_MS * (0.5 + Math.random())) : null);

function isoDate(daysAgo) {
  const d = new Date(Date.now() - daysAgo * 86400000);
  return d.toISOString().slice(0, 10);
}
function month(offset = 0) {
  const d = new Date();
  d.setUTCDate(1);
  d.setUTCMonth(d.getUTCMonth() + offset);
  return d.toISOString().slice(0, 7);
}

const DESCRIPTIONS = ['Groceries', 'Coffee', 'Lunch', 'Uber ride', 'Electricity bill', 'Movie tickets',
  'Petrol', 'Books', 'Gym', 'Dinner out', 'Pharmacy', 'Internet', 'Snacks', 'Train pass', 'Gift'];

// ---------- stats ----------
const stats = new Map(); // action -> { n, fail, codes:{}, ms:[] }
let done = false;
function record(action, status, ms) {
  let s = stats.get(action);
  if (!s) stats.set(action, (s = { n: 0, fail: 0, codes: {}, ms: [] }));
  s.n++;
  s.codes[status] = (s.codes[status] || 0) + 1;
  if (status === 0 || status >= 500) s.fail++;
  s.ms.push(ms);
}
const pct = (arr, p) => {
  if (!arr.length) return 0;
  const a = [...arr].sort((x, y) => x - y);
  return a[Math.min(a.length - 1, Math.floor((p / 100) * a.length))];
};
function report(title) {
  const rows = [...stats.entries()].sort((a, b) => b[1].n - a[1].n);
  let total = 0;
  console.log(`\n=== ${title} ===`);
  console.log('action'.padEnd(22) + 'count'.padStart(7) + '5xx/err'.padStart(9) + 'p50ms'.padStart(8) + 'p95ms'.padStart(8) + '  status codes');
  for (const [name, s] of rows) {
    total += s.n;
    const codes = Object.entries(s.codes).map(([c, n]) => `${c}:${n}`).join(' ');
    console.log(name.padEnd(22) + String(s.n).padStart(7) + String(s.fail).padStart(9) +
      String(pct(s.ms, 50)).padStart(8) + String(pct(s.ms, 95)).padStart(8) + '  ' + codes);
  }
  console.log(`total requests: ${total}`);
}

// ---------- HTTP client with a cookie jar per VU ----------
class Client {
  constructor() { this.cookie = ''; }
  async req(action, method, path, body) {
    const t0 = Date.now();
    let status = 0;
    let data = null;
    try {
      const res = await fetch(BASE_URL + path, {
        method,
        headers: {
          ...(body !== undefined ? { 'content-type': 'application/json' } : {}),
          ...(this.cookie ? { cookie: this.cookie } : {}),
          'user-agent': 'expense-loadtest/1.0',
        },
        body: body !== undefined ? JSON.stringify(body) : undefined,
        signal: AbortSignal.timeout(15000),
      });
      status = res.status;
      const setCookies = res.headers.getSetCookie?.() ?? [res.headers.get('set-cookie')].filter(Boolean);
      for (const c of setCookies) {
        const [pair] = c.split(';');
        if (pair.startsWith('expense_token=')) this.cookie = pair.endsWith('=') ? '' : pair;
      }
      const text = await res.text();
      data = text ? JSON.parse(text) : null;
    } catch {
      // network error / timeout / non-JSON body -> status stays as-is (0 = network)
    }
    record(action, status, Date.now() - t0);
    return { status, data };
  }
}

// ---------- one virtual user ----------
async function virtualUser(n) {
  const c = new Client();
  const email = `loadtest+${RUN_ID}-${n}@example.com`;
  const signup = await c.req('signup', 'POST', '/api/auth/signup', { email, password: PASSWORD, displayName: `Load User ${n}` });
  if (signup.status !== 201) {
    console.error(`VU${n}: signup failed (${signup.status}) ${JSON.stringify(signup.data)}`);
    return;
  }

  const cats = await c.req('categories.list', 'GET', `/api/categories?month=${month()}`);
  const categoryIds = (cats.data?.items ?? []).map((x) => x.id);
  if (!categoryIds.length) {
    console.error(`VU${n}: no categories returned`);
    return;
  }
  const myExpenses = [];

  const newExpense = () => ({
    amount: rand(20, 5000),
    categoryId: pick(categoryIds),
    expenseDate: isoDate(Math.floor(Math.random() * 90)),
    description: pick(DESCRIPTIONS),
  });

  // weight, action
  const actions = [
    [30, async () => {
      const r = await c.req('expense.create', 'POST', '/api/expenses', newExpense());
      if (r.status === 201 && r.data?.expense?.id) myExpenses.push(r.data.expense.id);
    }],
    [15, () => c.req('expense.list', 'GET', `/api/expenses?page=1&limit=25&sort=${pick(['date', 'amount'])}&order=${pick(['asc', 'desc'])}`)],
    [5, () => c.req('expense.search', 'GET', `/api/expenses?q=${encodeURIComponent(pick(DESCRIPTIONS).slice(0, 4))}&minAmount=100`)],
    [12, () => c.req('expense.summary', 'GET', `/api/expenses/summary?month=${month(-Math.floor(Math.random() * 3))}`)],
    [12, async () => {
      if (!myExpenses.length) return;
      await c.req('expense.update', 'PUT', `/api/expenses/${pick(myExpenses)}`, newExpense());
    }],
    [5, async () => {
      if (myExpenses.length < 5) return;
      const id = myExpenses.splice(Math.floor(Math.random() * myExpenses.length), 1)[0];
      await c.req('expense.delete', 'DELETE', `/api/expenses/${id}`);
    }],
    [6, () => c.req('categories.list', 'GET', `/api/categories?month=${month()}`)],
    [4, () => c.req('budget.set', 'PUT', `/api/budgets/${pick(categoryIds)}?month=${month()}`, { amount: rand(1000, 20000) })],
    [3, () => c.req('budget.list', 'GET', `/api/budgets?month=${month()}`)],
    [4, () => c.req('insights.trend', 'GET', `/api/insights/trend?months=6`)],
    [2, () => c.req('insights.month', 'GET', `/api/insights/month?month=${month()}`)],
    [1, () => c.req('auth.me', 'GET', '/api/auth/me')],
    [1, async () => {
      await c.req('signout', 'POST', '/api/auth/signout');
      await think();
      await c.req('signin', 'POST', '/api/auth/signin', { email, password: PASSWORD });
    }],
  ];
  if (ERRORS) {
    actions.push(
      [2, () => c.req('err.bad-expense', 'POST', '/api/expenses', { amount: -5, categoryId: 'x' })],      // 400
      [1, () => c.req('err.wrong-password', 'POST', '/api/auth/signin', { email, password: 'nope' })],   // 401
      [1, () => c.req('err.missing', 'DELETE', '/api/expenses/999999999')],                               // 404
    );
  }
  const totalWeight = actions.reduce((s, [w]) => s + w, 0);

  while (!done) {
    let r = Math.random() * totalWeight;
    const [, fn] = actions.find(([w]) => (r -= w) < 0) ?? actions[0];
    await fn();
    await think();
  }
}

// ---------- main ----------
console.log(`Load test ${RUN_ID}: ${VUS} VUs for ${DURATION / 1000}s against ${BASE_URL} (think ${THINK_MS}ms, ramp ${RAMP / 1000}s${ERRORS ? ', with errors' : ''})`);
const started = Date.now();
const ticker = setInterval(() => report(`after ${Math.round((Date.now() - started) / 1000)}s`), 30000);
const stop = () => { done = true; };
process.on('SIGINT', () => { console.log('\nstopping (Ctrl+C again to force)...'); stop(); process.once('SIGINT', () => process.exit(1)); });
setTimeout(stop, DURATION);

const vus = [];
for (let i = 1; i <= VUS; i++) {
  vus.push(virtualUser(i));
  if (VUS > 1) await sleep(RAMP / VUS);
  if (done) break;
}
await Promise.all(vus);
clearInterval(ticker);
report(`final (${Math.round((Date.now() - started) / 1000)}s)`);
