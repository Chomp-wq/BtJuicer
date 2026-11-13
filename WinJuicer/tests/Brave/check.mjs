// Opens real pages in a real Brave, the way a person would, and says what
// came back. Run by Test-Brave.ps1, before and after turning the protection on.
import { chromium } from 'playwright-core';

const [exe, phase] = process.argv.slice(2);
const browser = await chromium.launch({ executablePath: exe, headless: true });
const page = await browser.newPage();

async function open(url) {
  try {
    const r = await page.goto(url, { timeout: 25000, waitUntil: 'domcontentloaded' });
    let title = '';
    try { title = await page.title(); } catch { /* page gone */ }
    return { loaded: true, status: r ? r.status() : 0, url: page.url(), title };
  } catch (e) {
    return { loaded: false, error: String(e.message).split('\n')[0] };
  }
}

const out = {
  control: await open('https://example.com/'),
  xvideos: await open('https://www.xvideos.com/'),
  pornhub: await open('https://www.pornhub.com/'),
  braveSearch: await open('https://search.brave.com/search?q=hola'),
};
if (phase === 'despues') {
  try {
    await page.goto('brave://policy', { timeout: 15000 });
    await page.waitForTimeout(3000);
    out.policy = await page.innerText('body');
  } catch (e) {
    out.policy = 'ERROR ' + String(e.message).split('\n')[0];
  }
}
await browser.close();
console.log(JSON.stringify(out));
