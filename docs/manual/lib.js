// Small layout library that reproduces the look of the VM/370plus Guide:
// A4, Times New Roman body, Arial headings, thick rule under chapter titles,
// grey-headed tables, framed Courier code blocks, figure captions,
// static contents list with dot leaders, running header and footer.
const d = require('docx');
const {
  Paragraph, TextRun, Table, TableRow, TableCell, WidthType, BorderStyle, ShadingType,
  AlignmentType, TabStopType, LeaderType, Header, Footer, PageNumber, LevelFormat,
  PageBreak, HeadingLevel,
} = d;

const W = 9638;                     // content width in DXA (A4, 2 cm margins)
const TNR = 'Times New Roman', ARIAL = 'Arial', COURIER = 'Courier New';

function runs(text, o = {}) {
  // inline markup: `code`, **bold**, //italic//
  const out = [];
  const re = /(`[^`]+`|\*\*[^*]+\*\*|\/\/[^/]+\/\/)/g;
  let last = 0, m;
  const base = { font: o.font || TNR, size: o.size || 21, bold: o.bold, italics: o.italics };
  const push = (t, extra) => { if (t) out.push(new TextRun({ text: t, ...base, ...extra })); };
  while ((m = re.exec(text))) {
    push(text.slice(last, m.index));
    const tok = m[0];
    if (tok[0] === '`') push(tok.slice(1, -1), { font: COURIER, size: o.codeSize || 19, bold: false });
    else if (tok[0] === '*') push(tok.slice(2, -2), { bold: true });
    else push(tok.slice(2, -2), { italics: true });
    last = m.index + tok.length;
  }
  push(text.slice(last));
  return out;
}

class Doc {
  constructor() {
    this.main = [];       // body of the numbered section
    this.toc = [];        // {level, text, id}
    this.lists = [];      // numbering configs for numbered lists
    this.figN = 0;
    this.chapN = 0;
    this.id = 0;
  }
  _push(p) { this.main.push(p); }

  chapter(title, { label = true, appendix = null } = {}) {
    let text = title;
    if (appendix) text = `Appendix ${appendix}. ${title}`;
    else if (label) { this.chapN += 1; text = `Chapter ${this.chapN}. ${title}`; }
    this.toc.push({ level: 1, text });
    this._push(new Paragraph({
      heading: HeadingLevel.HEADING_1, pageBreakBefore: true, outlineLevel: 0,
      border: { bottom: { style: BorderStyle.SINGLE, size: 18, color: '000000', space: 6 } },
      spacing: { before: 0, after: 360 },
      children: [new TextRun({ text, font: ARIAL, bold: true, size: 36 })],
    }));
  }
  h2(text) {
    this.toc.push({ level: 2, text });
    this._push(new Paragraph({
      heading: HeadingLevel.HEADING_2, keepNext: true, spacing: { before: 320, after: 140 },
      children: [new TextRun({ text, font: ARIAL, bold: true, size: 26 })],
    }));
  }
  h3(text) {
    this._push(new Paragraph({
      heading: HeadingLevel.HEADING_3, keepNext: true, spacing: { before: 220, after: 100 },
      children: [new TextRun({ text, font: ARIAL, bold: true, size: 22 })],
    }));
  }
  p(text) { this._push(new Paragraph({ spacing: { after: 120 }, children: runs(text) })); }
  bullets(items) {
    items.forEach(t => this._push(new Paragraph({
      numbering: { reference: 'bul', level: 0 }, spacing: { after: 60 }, children: runs(t),
    })));
    this._push(new Paragraph({ spacing: { after: 60 }, children: [] }));
  }
  steps(items) {
    const ref = 'num' + this.lists.length;
    this.lists.push({
      reference: ref,
      levels: [{ level: 0, format: LevelFormat.DECIMAL, text: '%1.', alignment: AlignmentType.LEFT,
        style: { paragraph: { indent: { left: 540, hanging: 360 } }, run: { font: TNR, size: 21 } } }],
    });
    items.forEach(t => {
      if (typeof t === 'string') {
        this._push(new Paragraph({ numbering: { reference: ref, level: 0 }, spacing: { after: 60 }, children: runs(t) }));
      } else {   // {text, code:[...]}  a step followed by a framed block
        this._push(new Paragraph({ numbering: { reference: ref, level: 0 }, spacing: { after: 60 }, children: runs(t.text) }));
        this._code(t.code, true);
      }
    });
    this._push(new Paragraph({ spacing: { after: 60 }, children: [] }));
  }
  _code(lines, indented = false) {
    const cell = new TableCell({
      width: { size: W - (indented ? 540 : 0), type: WidthType.DXA },
      shading: { fill: 'F2F2F2', type: ShadingType.CLEAR, color: 'auto' },
      margins: { top: 100, bottom: 100, left: 140, right: 140 },
      children: lines.map(l => new Paragraph({
        spacing: { after: 0, line: 228 },
        children: [new TextRun({ text: l === '' ? ' ' : l, font: COURIER, size: 17 })],
      })),
    });
    const b = { style: BorderStyle.SINGLE, size: 4, color: 'auto' };
    this._push(new Table({
      width: { size: W - (indented ? 540 : 0), type: WidthType.DXA },
      columnWidths: [W - (indented ? 540 : 0)],
      indent: indented ? { size: 540, type: WidthType.DXA } : undefined,
      borders: { top: b, bottom: b, left: b, right: b, insideHorizontal: b, insideVertical: b },
      rows: [new TableRow({ cantSplit: true, children: [cell] })],
    }));
  }
  code(lines, caption) {
    this._code(lines);
    if (caption) this.caption(caption); else this._push(new Paragraph({ spacing: { after: 120 }, children: [] }));
  }
  caption(text) {
    this.figN += 1;
    this._push(new Paragraph({
      spacing: { before: 80, after: 200 }, keepLines: true,
      children: [new TextRun({ text: `Figure ${this.figN}. `, font: ARIAL, bold: true, size: 18 }),
                 ...runs(text, { font: ARIAL, size: 18, codeSize: 17 })],
    }));
  }
  table(headers, rows, widths, caption) {
    const tot = widths.reduce((a, b) => a + b, 0);
    const g = { style: BorderStyle.SINGLE, size: 4, color: '808080' };
    const mar = { top: 60, bottom: 60, left: 100, right: 100 };
    const mk = (t, w, head) => new TableCell({
      width: { size: w, type: WidthType.DXA }, margins: mar,
      shading: head ? { fill: 'D9D9D9', type: ShadingType.CLEAR, color: 'auto' } : undefined,
      children: [new Paragraph({ children: head
        ? [new TextRun({ text: t, font: ARIAL, bold: true, size: 18 })]
        : runs(t, { size: 18, codeSize: 17 }) })],
    });
    this._push(new Table({
      width: { size: tot, type: WidthType.DXA }, columnWidths: widths,
      borders: { top: g, bottom: g, left: g, right: g, insideHorizontal: g, insideVertical: g },
      rows: [
        new TableRow({ cantSplit: true, tableHeader: true, children: headers.map((h, i) => mk(h, widths[i], true)) }),
        ...rows.map(r => new TableRow({ cantSplit: true, children: r.map((c, i) => mk(c, widths[i], false)) })),
      ],
    }));
    if (caption) this.caption(caption); else this._push(new Paragraph({ spacing: { after: 120 }, children: [] }));
  }
  note(text) {
    this._push(new Paragraph({
      spacing: { before: 60, after: 160 }, indent: { left: 360 },
      border: { left: { style: BorderStyle.SINGLE, size: 18, color: '808080', space: 8 } },
      children: [new TextRun({ text: 'Note: ', font: ARIAL, bold: true, size: 19 }), ...runs(text, { size: 20 })],
    }));
  }
}

function tocParagraphs(entries, pages) {
  const out = [new Paragraph({ spacing: { after: 240 }, children: [new TextRun({ text: 'Contents', font: ARIAL, bold: true, size: 32 })] })];
  entries.forEach(e => {
    const pg = pages[e.text] != null ? String(pages[e.text]) : '0';
    const top = e.level === 1;
    out.push(new Paragraph({
      tabStops: [{ type: TabStopType.RIGHT, position: W, leader: LeaderType.DOT }],
      spacing: top ? { before: 160, after: 20 } : { before: 0, after: 20 },
      indent: { left: top ? 0 : 280 },
      children: [new TextRun({ text: e.text + '\t' + pg, font: top ? ARIAL : TNR, bold: top, size: top ? 21 : 18 })],
    }));
  });
  return out;
}

function frontMatter(cfg) {
  const A = (t, o = {}) => new TextRun({ text: t, font: ARIAL, ...o });
  const T = (t, o = {}) => new TextRun({ text: t, font: TNR, size: 19, ...o });
  const P = (c, o = {}) => new Paragraph({ spacing: { after: 140 }, children: c, ...o });
  const title = [
    new Paragraph({ spacing: { before: 1800 }, children: [] }),
    new Paragraph({ children: [A(cfg.product, { bold: true, size: 72 })] }),
    new Paragraph({ spacing: { after: 600 }, children: [A(cfg.tagline, { size: 30 })] }),
    new Paragraph({
      spacing: { after: 240 }, border: { bottom: { style: BorderStyle.SINGLE, size: 24, color: '000000', space: 8 } },
      children: [A(cfg.title1, { bold: true, size: 34 })],
    }),
    new Paragraph({ spacing: { after: 100 }, children: [T(cfg.release, { size: 21 })] }),
    new Paragraph({ spacing: { after: 2400 }, children: [T(cfg.basedOn, { size: 19 })] }),
    new Paragraph({ spacing: { after: 20 }, children: [T(`Publication ${cfg.pub}`, { size: 21 })] }),
    new Paragraph({ children: [T(cfg.fileNo, { size: 21 })] }),
  ];
  const notice = [new Paragraph({ children: [new TextRun({ break: 1 })], pageBreakBefore: true }),
    P([A(cfg.edition, { bold: true, size: 21 })]),
    ...cfg.notice.map(t => new Paragraph({ spacing: { after: 140 }, children: [T(t)] })),
  ];
  return [...title, ...notice];
}

function mainHeaderFooter(headText, pubNo) {
  return {
    headers: { default: new Header({ children: [new Paragraph({
      border: { bottom: { style: BorderStyle.SINGLE, size: 4, color: '000000', space: 4 } },
      children: [new TextRun({ text: headText, font: ARIAL, size: 16 })] })] }) },
    footers: { default: new Footer({ children: [new Paragraph({
      tabStops: [{ type: TabStopType.RIGHT, position: 9026 }],
      children: [new TextRun({ text: pubNo, font: ARIAL, size: 16 }),
                 new TextRun({ children: ['\t', PageNumber.CURRENT], font: ARIAL, size: 18 })] })] }) },
  };
}

module.exports = { d, Doc, tocParagraphs, frontMatter, mainHeaderFooter, W, TNR, ARIAL, COURIER, runs };
