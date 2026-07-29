import fs from 'node:fs';
import path from 'node:path';

const root = path.dirname(new URL(import.meta.url).pathname).replace(/^\//, '').replace(/^([A-Za-z]):/, '$1:');
const specs = [
  ['mobile', 'mobile/src/shell.html', 'mobile/index.html'],
  ['desktop', 'desktop/src/shell.html', 'desktop/index.html'],
];

function read(rel) { return fs.readFileSync(path.join(root, rel), 'utf8'); }
function include(text, kind, stack = []) {
  const re = kind === 'html' ? /<!--\s*@include\s+([^\s]+)\s*-->/g : /\/\*\s*@include\s+([^\s]+)\s*\*\//g;
  return text.replace(re, (_, rel) => {
    const normalized = rel.replaceAll('\\', '/');
    if (stack.includes(normalized)) throw new Error(`Cyclic include: ${[...stack, normalized].join(' -> ')}`);
    return include(read(normalized), kind, [...stack, normalized]);
  });
}
function compile(entry, platform) {
  let html = include(read(entry), 'html', [entry]);
  html = html.replace(/<!--\s*@style\s+([^\s]+)\s*-->/g, (_, rel) => include(read(rel), 'css', [rel]));
  html = html.replace(/<!--\s*@script\s+([^\s]+)\s*-->/g, (_, rel) => include(read(rel), 'js', [rel]));
  html = `<!-- GENERATED FILE. Edit maquettes/${platform}/src and shared sources. -->\n${html}`;
  return html;
}
function validate(html, platform) {
  const forbidden = [/<!--\s*@(?:include|style|script)/, /<script[^>]+src=/i, /<link[^>]+href=/i, /\b(fetch|require)\s*\(/, /\bimport\s+/];
  for (const re of forbidden) if (re.test(html)) throw new Error(`${platform}: unresolved runtime dependency ${re}`);
  for (const re of [/radial-gradient/i, /backdrop-filter/i]) if (re.test(html)) throw new Error(`${platform}: forbidden visual effect ${re}`);
  if (!html.includes('id="app"')) throw new Error(`${platform}: missing app root`);
  for (const script of html.matchAll(/<script(?:>|[^>]*>)([\s\S]*?)<\/script>/gi)) new Function(script[1]);
  const templateIds = [...html.matchAll(/<template\s+id="([^"]+)"/gi)].map((match) => match[1]);
  const duplicateTemplateIds = templateIds.filter((id, index) => templateIds.indexOf(id) !== index);
  if (duplicateTemplateIds.length) throw new Error(`${platform}: duplicate template ids ${[...new Set(duplicateTemplateIds)].join(', ')}`);
  const templateHtml = [...html.matchAll(/<template[^>]*>[\s\S]*?<\/template>/gi)].map((match) => match[0]).join('\n');
  const actions = [...templateHtml.matchAll(/data-action="([^"{][^"]*)"/g)].map((match) => match[1]);
  const handledActions = new Set([...html.matchAll(/action === '([^']+)'/g)].map((match) => match[1]));
  const formActions = new Set([...html.matchAll(/form\.dataset\.action === '([^']+)'/g)].map((match) => match[1]));
  const unhandledActions = actions.filter((action) => !handledActions.has(action) && !formActions.has(action));
  if (unhandledActions.length) throw new Error(`${platform}: unhandled data actions ${[...new Set(unhandledActions)].join(', ')}`);
  const iconPlaceholders = [...html.matchAll(/\{\{(icon[A-Z]\w*)\}\}/g)].map((match) => match[1]);
  const providedIcons = new Set([...html.matchAll(/(icon[A-Z]\w*):/g)].map((match) => match[1]));
  const missingIcons = iconPlaceholders.filter((icon) => !providedIcons.has(icon));
  if (missingIcons.length) throw new Error(`${platform}: missing icon placeholders ${[...new Set(missingIcons)].join(', ')}`);
  for (const selector of ['.hero-mark svg', '.empty-mark svg', '.search-wrap svg', '.queue-note svg']) {
    if (!html.includes(selector)) throw new Error(`${platform}: missing SVG sizing rule ${selector}`);
  }
  for (const id of [
    'tpl-splash',
    'tpl-tor-onboarding',
    'tpl-nickname',
    'tpl-mobile-shell',
    'tpl-desktop-shell',
    'tpl-dock',
    'tpl-rail',
    'tpl-list-shell',
    'tpl-detail-shell',
    'tpl-chat-row',
    'tpl-contact-row',
    'tpl-inbox-row',
    'tpl-message-row',
    'tpl-empty',
    'tpl-contact-detail',
    'tpl-invite-detail',
    'tpl-new-contact',
    'tpl-account-detail',
    'tpl-tor-detail',
    'tpl-inspector',
    'tpl-modal-qr',
    'tpl-modal-new-contact',
    'tpl-modal-confirm',
    'tpl-modal-error',
    'tpl-modal-actions',
  ]) if (!html.includes(`id="${id}"`)) throw new Error(`${platform}: missing template ${id}`);
}
const check = process.argv.includes('--check');
for (const [platform, entry, output] of specs) {
  const result = compile(entry, platform);
  validate(result, platform);
  const target = path.join(root, output);
  if (!check) fs.writeFileSync(target, result, 'utf8');
  console.log(`[maquettes] ${check ? 'checked' : 'built'} ${output}`);
}
