// Screenshots of the main gitweb pages in two widths and both color schemes, plus layout assertions.
// Usage: node tests/screenshots.mjs <output directory>, configured through the environment variables in CLAUDE.md.
import { mkdirSync } from 'node:fs';
import { join } from 'node:path';

const required = ['GW_TREE_PROJECT', 'GW_TREE_PATH', 'GW_BLOB_PROJECT', 'GW_BLOB_PATH', 'GW_LONG_BLOB_PATH',
    'GW_COMMIT_PROJECT', 'GW_COMMIT'];
const missing = required.filter((name) => !process.env[name]);
const outputDir = process.argv[2];
if (missing.length || !outputDir) {
    console.error(`usage: ${required.map((name) => `${name}=…`).join(' ')} node tests/screenshots.mjs <output directory>`);
    if (missing.length) console.error(`missing: ${missing.join(', ')}`);
    process.exit(2);
}
mkdirSync(outputDir, { recursive: true });

const { chromium } = await import(process.env.PLAYWRIGHT_MODULE ?? 'playwright');
const baseUrl = process.env.GITWEB_URL ?? 'http://127.0.0.1:28080';
const env = Object.fromEntries(required.map((name) => [name, encodeURIComponent(process.env[name])]));

const pages = {
    projects: '/',
    tree: `/?p=${env.GW_TREE_PROJECT};a=tree;f=${env.GW_TREE_PATH};hb=HEAD`,
    blob: `/?p=${env.GW_BLOB_PROJECT};a=blob;f=${env.GW_BLOB_PATH};hb=HEAD`,
    'blob-long': `/?p=${env.GW_BLOB_PROJECT};a=blob;f=${env.GW_LONG_BLOB_PATH};hb=HEAD`,
    history: `/?p=${env.GW_BLOB_PROJECT};a=history;f=${env.GW_BLOB_PATH};hb=HEAD`,
    summary: `/?p=${env.GW_COMMIT_PROJECT};a=summary`,
    heads: `/?p=${env.GW_COMMIT_PROJECT};a=heads`,
    log: `/?p=${env.GW_COMMIT_PROJECT};a=log;h=HEAD`,
    shortlog: `/?p=${env.GW_COMMIT_PROJECT};a=shortlog`,
    commit: `/?p=${env.GW_COMMIT_PROJECT};a=commit;h=${env.GW_COMMIT}`,
    commitdiff: `/?p=${env.GW_COMMIT_PROJECT};a=commitdiff;h=${env.GW_COMMIT}`,
};
const viewports = {
    phone: { width: 390, height: 844, minFontSize: 16 },
    desktop: { width: 1440, height: 900, minFontSize: 13 },
};
const schemes = ['light', 'dark'];
const darkSelectors = {
    blob: ['div.pre'],
    'blob-long': ['div.pre'],
    commitdiff: ['div.diff.add', 'div.diff.rem', 'div.diff.chunk_header'],
};
const syntaxSelector = '.hl.kwa, .hl.kwb, .hl.kwd, .hl.str, .hl.sng, .hl.num';
const lightSyntaxColors = {};

const failures = [];
const check = (condition, message) => condition || failures.push(message);

function inspect({ selectors, syntaxSelector }) {
    const luminance = (element) => {
        for (let node = element; node; node = node.parentElement) {
            const match = getComputedStyle(node).backgroundColor.match(/[\d.]+/g);
            if (match && (match.length < 4 || Number(match[3]) > 0)) {
                const [r, g, b] = match.slice(0, 3).map((value) => {
                    const channel = Number(value) / 255;
                    return channel <= 0.03928 ? channel / 12.92 : ((channel + 0.055) / 1.055) ** 2.4;
                });
                return 0.2126 * r + 0.7152 * g + 0.0722 * b;
            }
        }
        return 1;
    };
    const backgrounds = { body: luminance(document.body) };
    for (const selector of selectors) {
        const element = document.querySelector(selector);
        backgrounds[selector] = element ? luminance(element) : null;
    }
    const syntax = document.querySelector(syntaxSelector);
    return {
        syntaxColor: syntax ? getComputedStyle(syntax).color : null,
        scrollWidth: document.documentElement.scrollWidth,
        fontSize: parseFloat(getComputedStyle(document.body).fontSize),
        backgrounds,
    };
}

const browser = await chromium.launch();
try {
    for (const [viewportName, { minFontSize, ...viewport }] of Object.entries(viewports)) {
        for (const colorScheme of schemes) {
            const context = await browser.newContext({ viewport, colorScheme });
            const page = await context.newPage();
            for (const [pageName, path] of Object.entries(pages)) {
                const label = `${pageName} ${viewportName} ${colorScheme}`;
                const response = await page.goto(baseUrl + path);
                check(response?.ok(), `${label}: HTTP ${response?.status()}`);
                await page.screenshot({ path: join(outputDir, `${pageName}-${viewportName}-${colorScheme}.png`) });

                const selectors = colorScheme === 'dark' ? darkSelectors[pageName] ?? [] : [];
                const result = await page.evaluate(inspect, { selectors, syntaxSelector });
                check(result.scrollWidth <= viewport.width, `${label}: page scrolls sideways (${result.scrollWidth}px)`);
                check(result.fontSize >= minFontSize, `${label}: body font size ${result.fontSize}px`);
                if (pageName === 'blob') {
                    check(result.syntaxColor !== null, `${label}: no highlighted token`);
                    if (colorScheme === 'light') lightSyntaxColors[viewportName] = result.syntaxColor;
                    else check(result.syntaxColor !== lightSyntaxColors[viewportName], `${label}: syntax color same as light`);
                }
                const darkTargets = colorScheme === 'dark' ? Object.entries(result.backgrounds) : [];
                for (const [target, value] of darkTargets) {
                    check(value !== null, `${label}: ${target} not found`);
                    check(value === null || value < 0.05, `${label}: ${target} background not dark (L=${value?.toFixed(2)})`);
                }
            }
            await context.close();
        }
    }
} finally {
    await browser.close();
}

if (failures.length) {
    console.error(failures.map((failure) => `FAIL: ${failure}`).join('\n'));
    process.exit(1);
}
console.log(`PASS: screenshots in ${outputDir}`);
