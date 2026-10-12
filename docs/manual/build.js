// Builds RXPIP-Guide.docx in two passes: the contents list is typed text
// with page numbers (as in the VM/370plus Guide), so pass 1 finds the page
// of every heading in a rendered PDF and pass 2 writes them in.
const fs = require('fs');
const { execFileSync } = require('child_process');
const { d, Doc, tocParagraphs, frontMatter, mainHeaderFooter } = require('./lib');
const content = require('./content');

const cfg = {
  product: 'RXPIP',
  tagline: 'The REXX Package Manager',
  title1: 'Introduction, Installation and User’s Guide',
  release: 'Release 1  •  updated 12 October 2026',
  basedOn: 'for Regina, ooRexx, NetRexx and cREXX and the repository www.rexxpository.org',
  pub: 'RXP-0001-0',
  fileNo: 'File No. REXX-01',
  edition: 'Second Edition (October 2026)',
  notice: [
    'This edition applies to RXPIP Release 1 (clients for Regina, ooRexx, NetRexx and cREXX, and the server, as of 12 October 2026) and to all subsequent releases until otherwise indicated in new editions.',
    'RXPIP is a hobbyist project. It is not a product of, and this manual is not a publication of, any company named in it. REXX is the Restructured Extended Executor language. Regina REXX, Apache HTTP Server, AlmaLinux, Hetzner, Let’s Encrypt, curl and the other programs and services named here are the property of their respective owners and are named only to identify what RXPIP runs on and works with.',
    'The project repository holds the source of the client and server, the examples and the automated test suite from which every statement in this manual about behaviour can be checked. Comments on this publication may be addressed to the project.',
  ],
};

function build(pages, out) {
  const D = new Doc();
  content(D);
  const front = [...frontMatter(cfg),
    new d.Paragraph({ children: [new d.PageBreak()] }),
    ...tocParagraphs(D.toc, pages)];
  const doc = new d.Document({
    creator: 'RXPIP project', title: 'RXPIP Introduction, Installation and User’s Guide',
    styles: { default: { document: { run: { font: 'Times New Roman', size: 21 } } } },
    numbering: { config: [
      { reference: 'bul', levels: [{ level: 0, format: d.LevelFormat.BULLET, text: '•', alignment: d.AlignmentType.LEFT,
        style: { paragraph: { indent: { left: 540, hanging: 270 } }, run: { font: 'Times New Roman' } } }] },
      ...D.lists,
    ] },
    sections: [
      { properties: { page: { size: { width: 11906, height: 16838 }, margin: { top: 1134, right: 1134, bottom: 1134, left: 1134, header: 708, footer: 708 } } },
        children: front },
      { properties: { page: { size: { width: 11906, height: 16838 }, margin: { top: 1300, right: 1134, bottom: 1134, left: 1134, header: 708, footer: 708 },
          pageNumbers: { start: 1 } } },
        ...mainHeaderFooter('RXPIP Introduction, Installation and User’s Guide', cfg.pub),
        children: D.main },
    ],
  });
  return d.Packer.toBuffer(doc).then(b => { fs.writeFileSync(out, b); return D; });
}

function pageMap(pdf, D) {
  const n = parseInt(execFileSync('pdfinfo', [pdf]).toString().match(/Pages:\s+(\d+)/)[1], 10);
  const text = [];
  for (let i = 1; i <= n; i++) {
    text.push(execFileSync('pdftotext', ['-f', String(i), '-l', String(i), '-layout', pdf, '-']).toString());
  }
  const hdr = 'RXPIP Introduction, Installation and User';
  const first = text.findIndex(t => t.includes(hdr));          // first numbered page
  const pages = [];
  let from = first;
  D.toc.forEach((e, k) => {
    const norm = s => s.replace(/\s+/g, ' ').trim();
    for (let i = from; i < n; i++) {
      const lines = text[i].split('\n').map(norm);
      if (lines.some(l => l === norm(e.text))) { pages[k] = i - first + 1; from = i; return; }
    }
    console.error('heading not found:', e.text);
  });
  return pages;
}

(async () => {
  const out = process.argv[2] || 'RXPIP-Guide.docx';
  const tmp = out.replace(/\.docx$/, '.pass1.docx');
  let D = await build([], tmp);
  const sk = process.env.SOFFICE || '/root/.claude/skills/synced/004a80ff-5a8f-4597-8d6b-9c2731b8994a_5fb75d53-748b-40b7-b60d-47cbebea1b46/docx/scripts/office/soffice.py';
  const run = f => execFileSync('python', [sk, '--headless', '--convert-to', 'pdf', f], { stdio: 'ignore' });
  run(tmp);
  let pages = pageMap(tmp.replace(/\.docx$/, '.pdf'), D);
  D = await build(pages, tmp);           // pass 2 (page numbers in), re-check stability
  run(tmp);
  const pages2 = pageMap(tmp.replace(/\.docx$/, '.pdf'), D);
  if (JSON.stringify(pages) !== JSON.stringify(pages2)) { pages = pages2; await build(pages, tmp); }
  fs.renameSync(tmp, out);
  fs.unlinkSync(tmp.replace(/\.docx$/, '.pdf'));
  console.log('wrote', out, pages.length, 'headings');
})();
