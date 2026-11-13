// Opens real pages in a real Brave, the way a person would, and says what
// came back. Run by Test-Brave.ps1, before and after turning the protection on.
// A visible window: Brave Search answers headless browsers with a captcha.
import { chromium } from 'playwright-core';

const [exe, phase] = process.argv.slice(2);
const browser = await chromium.launch({ executablePath: exe, headless: false });
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

// A search for an adult site: which result links point at adult domains.
async function search(q) {
  const r = await open('https://search.brave.com/search?q=' + encodeURIComponent(q) + '&source=web');
  if (!r.loaded) return r;
  await page.waitForTimeout(2500);
  const links = await page.$$eval('a[href]', (as) => as.map((a) => a.href));
  r.captcha = /captcha/i.test(r.title) || /captcha/i.test(r.url);
  r.links = links.length;
  r.adult = [...new Set(links.filter((h) => /pornhub|xvideos|xnxx|xhamster|redtube|youporn/i.test(new URL(h).hostname)).map((h) => new URL(h).hostname))];
  return r;
}

const out = {
  control: await open('https://example.com/'),
  xvideos: await open('https://www.xvideos.com/'),
  pornhub: await open('https://www.pornhub.com/'),
  braveSearch: await open('https://search.brave.com/search?q=hola'),
  braveAdult: await search('pornhub'),
};
if (phase === 'despues') {
  try {
    const p = await browser.newPage();
    await p.goto('chrome://policy', { timeout: 15000 });
    // Its text lives inside shadow roots, which innerText does not reach.
    const deepText = () => {
      const walk = (n) => {
        let t = '';
        if (n.nodeType === Node.TEXT_NODE) return n.textContent + ' ';
        if (n.shadowRoot) t += walk(n.shadowRoot);
        for (const c of n.childNodes) t += walk(c);
        return t;
      };
      return walk(document.documentElement).replace(/\s+/g, ' ');
    };
    await p.waitForFunction(`(${deepText})().includes('DnsOverHttpsMode')`, null, { timeout: 20000 }).catch(() => {});
    out.policy = await p.evaluate(deepText);
  } catch (e) {
    out.policy = 'ERROR ' + String(e.message).split('\n')[0];
  }
}
await browser.close();
console.log(JSON.stringify(out));
