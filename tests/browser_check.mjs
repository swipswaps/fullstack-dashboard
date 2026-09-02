// tests/browser_check.mjs
// Drives a real Chromium against the deployed page and asserts on what a
// user would actually see. Run:  node tests/browser_check.mjs <url>
//
// Two things no curl can establish and this can:
//   1. the page is not blank - React mounted and produced DOM
//   2. the loopback fetch outcome, with the browser's own diagnostic text
//
// The local-network-access permission is granted to the context. That is the
// scripted equivalent of a user clicking Allow on the prompt; without it the
// browser reports "Permission was denied ... `loopback` address space", which
// is a permission state, not a bug.
import { chromium } from 'playwright';

const URL = process.argv[2];
const SHOT = process.argv[3] || 'notes/browser_check.png';
if (!URL) {
  console.error('usage: node tests/browser_check.mjs <url> [screenshot]');
  process.exit(2);
}

let failures = 0;
const check = (name, ok, detail) => {
  console.log(`  ${ok ? 'PASS' : 'FAIL'}  ${name}${detail ? ' :: ' + detail : ''}`);
  if (!ok) failures += 1;
};

const browser = await chromium.launch();
let ctx;
try {
  ctx = await browser.newContext({
    permissions: ['local-network-access'],
    // Off by default. Only set PW_IGNORE_CERT=1 when running behind a
    // TLS-intercepting proxy; it must never be on for a real check.
    ignoreHTTPSErrors: process.env.PW_IGNORE_CERT === '1',
  });
} catch {
  // Older Playwright/Chromium do not know the permission name. Fall back and
  // report it, rather than silently testing something weaker.
  console.log('  INFO  local-network-access permission unavailable in this ' +
              'Playwright build; loopback fetch will report a permission denial');
  ctx = await browser.newContext({ ignoreHTTPSErrors: process.env.PW_IGNORE_CERT === '1' });
}
const page = await ctx.newPage();

const consoleMsgs = [];
const failed = [];
const responses = [];
page.on('console', (m) => consoleMsgs.push(`[${m.type()}] ${m.text()}`));
page.on('pageerror', (e) => consoleMsgs.push(`[pageerror] ${e.message}`));
page.on('requestfailed', (r) => failed.push(`${r.url()} :: ${r.failure()?.errorText}`));
page.on('response', (r) => responses.push({ status: r.status(), url: r.url() }));

// A navigation failure must be REPORTED as a failed check, not thrown as an
// uncaught exception - a stack trace tells the operator nothing actionable.
let resp = null;
let navError = null;
try {
  resp = await page.goto(URL, { waitUntil: 'networkidle', timeout: 45000 });
} catch (e) {
  navError = e.message.split('\n')[0];
}
check('page navigation succeeded', navError === null, navError || 'ok');
check('page responds 200', resp !== null && resp.status() === 200,
      resp ? `HTTP ${resp.status()}` : (navError || 'no response'));
if (navError !== null) {
  console.log(`\nbrowser_check: ${failures} failure(s) - navigation failed, ` +
              'later checks skipped');
  await browser.close();
  process.exit(1);
}

await page.waitForTimeout(3000);

const rootHtml = await page.locator('#root').innerHTML().catch(() => '');
check('page is not blank (React mounted)', rootHtml.trim().length > 0,
      `#root inner length ${rootHtml.length}`);

const assets = responses.filter((r) => /\.(js|css)$/.test(r.url));
check('every js/css asset returned 200',
      assets.length > 0 && assets.every((a) => a.status === 200),
      assets.map((a) => `${a.status} ${a.url.split('/').pop()}`).join(', ') || 'none');

const text = await page.locator('body').innerText().catch(() => '');
check('dashboard heading rendered', /Forensic Dashboard/i.test(text),
      text.split('\n')[0] || '(empty)');

// The loopback probe. Reported, not asserted as a hard failure: whether the
// backend is running is the operator's business, not the page's correctness.
const probe = await page.evaluate(async () => {
  try {
    const r = await fetch('http://localhost:3001/api/health',
                          { targetAddressSpace: 'loopback' });
    return `HTTP ${r.status} :: ${(await r.text()).slice(0, 60)}`;
  } catch (e) {
    return `${e.constructor.name}: ${e.message}`;
  }
});
console.log(`  INFO  loopback probe -> ${probe}`);

const spaceMismatch = consoleMsgs.filter((m) =>
  m.includes('yet the resource is in address space')).length;
check('no address-space MISMATCH (the wrong-value symptom)', spaceMismatch === 0,
      spaceMismatch ? `${spaceMismatch} mismatch message(s)` : 'none');

console.log('  --- failed requests ---');
failed.length ? failed.forEach((f) => console.log('    ' + f))
              : console.log('    (none)');
console.log('  --- console (first 15) ---');
consoleMsgs.length ? consoleMsgs.slice(0, 15).forEach((m) => console.log('    ' + m))
                   : console.log('    (none)');
console.log('  --- visible text (first 400 chars) ---');
console.log(text.slice(0, 400).split('\n').map((l) => '    ' + l).join('\n'));

await page.screenshot({ path: SHOT, fullPage: true });
console.log(`  screenshot: ${SHOT}`);

await browser.close();
console.log(`\nbrowser_check: ${failures} failure(s)`);
process.exit(failures > 0 ? 1 : 0);
