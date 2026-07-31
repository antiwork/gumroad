import { chromium } from 'playwright';
import fs from 'fs';

const ROOT = 'https://docs-terms-subsection-renumber.apps.staging.gumroad.org';
const OUT = '/Users/gumclaw/qa/pr6717/shots';
fs.mkdirSync(OUT, { recursive: true });

const RENUMBERED = {
  '4.1': 'Registering Your Account', '4.2': 'Additional Identity Verification',
  '12.1': 'Types of Content', '13.1': 'Ownership of the Services',
  '17.1': 'User Responsibility', '21.1': 'Disclaimer of Certain Damages',
  '23.1': 'Term', '25.1': 'Applicability of Arbitration Agreement',
  '26.1': 'Third-Party Websites, Applications and Ads', '27.1': 'Electronic Communications',
};

// Each frame: [file, anchorLabel(number), description]
const FRAMES = [
  ['pr-6717-terms-s4-registration',            '4.1',  '§4 Registration'],
  ['pr-6717-terms-s12-types-of-content',       '12.1', '§12.1 Types of Content'],
  ['pr-6717-terms-s25-arbitration-start',      '25.1', '§25.1 start of arbitration run'],
  ['pr-6717-terms-s25-class-waiver',           '25.4', '§25.4 class-action waiver'],
  ['pr-6717-terms-s25-batch-arbitration',      '25.9', '§25.9 Batch Arbitration'],
  ['pr-6717-terms-s27-electronic-communications','27.1','§27.1 Electronic Communications'],
  ['pr-6717-terms-s1-control-untouched',       '1.1',  '§1 control (untouched)'],
];
const MOBILE_FRAMES = ['pr-6717-terms-s4-registration', 'pr-6717-terms-s25-class-waiver'];

function labelScraper() {
  const out = [];
  for (const s of document.querySelectorAll('strong')) {
    const t = (s.textContent || '').replace(/\s+/g, ' ').trim();
    const m = t.match(/^([0-9]+\.[0-9]+)\s*\.?\s*(.*)$/);
    if (m) out.push({ num: m[1], title: m[2].replace(/\.$/, '').trim() });
  }
  return out;
}

async function assertPage(page, tag) {
  const labels = await page.evaluate(labelScraper);
  console.log(`${tag} LIVE_LABELS ${labels.length}`);
  if (labels.length !== 84) throw new Error(`${tag} expected 84 subsection labels, got ${labels.length}`);

  const onex = labels.filter(l => l.num.startsWith('1.')).map(l => `${l.num} ${l.title}`);
  console.log(`${tag} ONE_X_LABELS ${JSON.stringify(onex)}`);
  if (onex.length !== 2) throw new Error(`${tag} expected exactly 2 1.x labels (both §1), got ${onex.length}`);

  // every section must number 1..n with no gap or repeat
  const bySec = {};
  for (const l of labels) { const s = l.num.split('.')[0]; (bySec[s] ||= []).push(Number(l.num.split('.')[1])); }
  let sections = 0;
  for (const [s, ns] of Object.entries(bySec)) {
    sections++;
    const sorted = [...ns].sort((a, b) => a - b);
    for (let i = 0; i < sorted.length; i++) {
      if (sorted[i] !== i + 1) throw new Error(`${tag} §${s} not contiguous: ${JSON.stringify(ns)}`);
    }
    if (JSON.stringify(ns) !== JSON.stringify(sorted)) throw new Error(`${tag} §${s} out of order`);
  }
  console.log(`${tag} RUNS_CONTIGUOUS_OK sections=${sections}`);

  for (const [num, title] of Object.entries(RENUMBERED)) {
    const hit = labels.find(l => l.num === num);
    if (!hit) throw new Error(`${tag} missing renumbered label ${num}`);
    if (!hit.title.toLowerCase().startsWith(title.toLowerCase().slice(0, 20)))
      throw new Error(`${tag} ${num} carries "${hit.title}", expected "${title}"`);
  }
  console.log(`${tag} ALL_RENUMBERED_ANCHOR_LABELS_LIVE_OK n=${Object.keys(RENUMBERED).length}`);

  // cross-reference resolution: Section N.M (Title) -> header carrying N.M
  const cites = await page.evaluate(() => {
    const txt = document.body.innerText.replace(/\s+/g, ' ');
    const re = /Section\s+([0-9]+\.[0-9]+)\s*\(([^)]{4,90})\)/g;
    const out = []; let m;
    while ((m = re.exec(txt))) out.push({ num: m[1], title: m[2].trim() });
    return out;
  });
  // Conjunction-insensitive: the "and Other" / "or Other" variance in three cites of the
  // class-action waiver is a pre-existing wording typo, explicitly out of scope for this PR.
  const norm = s => s.toLowerCase().replace(/\b(and|or)\b/g, '').replace(/[^a-z0-9]/g, '');
  let resolving = 0; const dead = []; const conjVariance = [];
  for (const c of cites) {
    const h = labels.find(l => l.num === c.num);
    const a = norm(c.title), b = h ? norm(h.title) : '';
    if (h && (b.includes(a) || a.includes(b))) {
      resolving++;
      if (c.title.replace(/\s+/g, ' ') !== h.title.replace(/\s+/g, ' '))
        conjVariance.push(`${c.num}: cite "${c.title}" vs header "${h.title}"`);
    } else dead.push(`${c.num} (${c.title}) -> ${h ? h.title : 'NO HEADER'}`);
  }
  console.log(`${tag} CITES total=${cites.length} resolving=${resolving} dead=${dead.length}`);
  console.log(`${tag} PREEXISTING_CONJUNCTION_VARIANCE ${conjVariance.length} ${JSON.stringify(conjVariance)}`);
  if (dead.length) throw new Error(`${tag} dead cites: ${JSON.stringify(dead)}`);
  return { labels: labels.length, cites: cites.length, resolving, onex };
}

async function shoot(page, num, file, suffix) {
  const loc = page.locator('strong').filter({ hasText: new RegExp(`^\\s*${num.replace('.', '\\.')}[\\s.]`) }).first();
  if (!(await loc.count())) throw new Error(`no header for ${num}`);
  await loc.scrollIntoViewIfNeeded();
  await page.waitForTimeout(400);
  const box = await loc.boundingBox();
  const vh = page.viewportSize().height;
  if (!box || box.y < 0 || box.y > vh) throw new Error(`${num} heading out of viewport (y=${box && box.y})`);
  // nudge the heading toward the top third so the run below it is visible
  await page.evaluate(y => window.scrollBy(0, y), box.y - Math.round(vh * 0.15));
  await page.waitForTimeout(300);
  const p = `${OUT}/${file}${suffix}.png`;
  await page.screenshot({ path: p });
  console.log(`SHOT ${file}${suffix} y=${Math.round((await loc.boundingBox()).y)}`);
}

const browser = await chromium.launch();
const summary = {};
try {
  // ---- DESKTOP ----
  let ctx = await browser.newContext({ viewport: { width: 1440, height: 900 }, deviceScaleFactor: 2 });
  let page = await ctx.newPage();
  const resp = await page.goto(`${ROOT}/terms`, { waitUntil: 'domcontentloaded', timeout: 120000 });
  const rev = resp.headers()['x-revision'];
  console.log(`DESKTOP status ${resp.status()} x-revision ${rev}`);
  if (resp.status() !== 200) throw new Error(`desktop status ${resp.status()}`);
  summary.revision = rev;
  summary.desktop = await assertPage(page, 'DESKTOP');
  for (const [file, num] of FRAMES.map(f => [f[0], f[1]])) await shoot(page, num, file, '-desktop');
  await ctx.close();

  // ---- MOBILE 375 ----
  ctx = await browser.newContext({ viewport: { width: 375, height: 812 }, deviceScaleFactor: 2, isMobile: true, hasTouch: true });
  page = await ctx.newPage();
  const r2 = await page.goto(`${ROOT}/terms`, { waitUntil: 'domcontentloaded', timeout: 120000 });
  console.log(`MOBILE status ${r2.status()} x-revision ${r2.headers()['x-revision']}`);
  if (r2.headers()['x-revision'] !== rev) throw new Error(`revision moved mid-run: ${rev} -> ${r2.headers()['x-revision']}`);
  summary.mobile = await assertPage(page, 'MOBILE');
  for (const file of MOBILE_FRAMES) {
    const num = FRAMES.find(f => f[0] === file)[1];
    await shoot(page, num, file, '-mobile-375');
  }
  await ctx.close();

  fs.writeFileSync(`${OUT}/summary.json`, JSON.stringify(summary, null, 2));
  console.log(`RUN_OK rev=${rev}`);
} finally {
  await browser.close();
}
