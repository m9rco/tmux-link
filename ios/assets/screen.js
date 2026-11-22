const term = new Terminal({
  allowProposedApi: true, // Required by the pinned Unicode provider.
  cursorBlink: true,
  cursorStyle: 'bar',
  cursorWidth: 2,
  fontFamily: '"Terminal Symbols", ui-monospace, Menlo, monospace',
  fontSize: 14,
  lineHeight: 1,
  scrollback: 4000,
  // FitAddon also uses this width when calculating how many columns to request.
  overviewRuler: {width: 1},
  theme: {
    background: '#0a141a', foreground: '#dce8eb', cursor: '#79e8c9',
    selectionBackground: '#345057', black: '#16272e', green: '#7ddbb5',
    cyan: '#75d6e9', yellow: '#efbb78', red: '#fb8985'
  }
});
const fit = new FitAddon.FitAddon();
term.loadAddon(new UnicodeGraphemesAddon.UnicodeGraphemesAddon());
term.loadAddon(fit);

const bridge = window.webkit.messageHandlers.terminal;
term.onData(terminalData);
// Legacy mouse reports contain raw coordinate bytes, including values above 127.
term.onBinary(bytes => bridge.postMessage({binary: btoa(bytes)}));
let lastCols = term.cols;
term.onResize(({cols, rows}) => {
  if (cols !== lastCols) resetInput();
  lastCols = cols;
  bridge.postMessage({cols, rows});
});

function pressTerminalKey(key) {
  // Fullscreen applications can request SS3 cursor keys (DECCKM).
  if (term.modes.applicationCursorKeysMode && /^\x1b\[[A-D]$/.test(key)) key = '\x1bO' + key[2];
  term.input(key, true);
}

// Use the same wheel encoder as a desktop xterm so tmux and a full-screen
// application receive the mouse protocol they actually negotiated.
function scrollRemote(x, y, fingerSteps, first) {
  // Dragging content down reveals earlier rows (wheel up or Page Up).
  resetInput();
  const steps = -fingerSteps;
  if (!['vt200', 'drag', 'any'].includes(term.modes.mouseTrackingMode)) {
    if (first) term.input(steps < 0 ? '\x1b[5~' : '\x1b[6~', true);
    return;
  }
  const screen = term.element.querySelector('.xterm-screen');
  const rect = screen.getBoundingClientRect();
  const event = {
    bubbles: true, cancelable: true, deltaMode: 1, deltaY: Math.sign(steps),
    clientX: Math.max(rect.left, Math.min(rect.right - 1, rect.left + x * rect.width)),
    clientY: Math.max(rect.top, Math.min(rect.bottom - 1, rect.top + y * rect.height))
  };
  for (let i = 0; i < Math.min(8, Math.abs(steps)); i++) {
    screen.dispatchEvent(new WheelEvent('wheel', event));
  }
}

// Use xterm's cells for hit testing. UTF-16 offsets are for UIKit text ranges.
function terminalPoint(x, y) {
  const rect = term.element.querySelector('.xterm-screen').getBoundingClientRect();
  const buffer = term.buffer.active;
  const row = Math.max(0, Math.min(term.rows - 1, Math.floor((y - rect.top) * term.rows / rect.height)));
  const col = Math.max(0, Math.min(term.cols - 1, Math.floor((x - rect.left) * term.cols / rect.width)));
  return {row, col, atCursor: buffer.viewportY + row === buffer.baseY + buffer.cursorY};
}

function selectionSnapshot(x, y) {
  const buffer = term.buffer.active;
  const point = terminalPoint(x, y);
  let text = '', offset = 0;
  for (let row = 0; row < term.rows; row++) {
    const line = buffer.getLine(buffer.viewportY + row);
    const softWrap = row + 1 < term.rows && buffer.getLine(buffer.viewportY + row + 1)?.isWrapped;
    let value = '', columnOffset = 0;
    for (let col = 0; line && col < term.cols;) {
      const cell = line.getCell(col);
      const width = Math.max(1, cell.getWidth());
      if (col <= point.col) columnOffset = value.length;
      value += cell.isInvisible() ? ' '.repeat(width) : (cell.getChars() || ' ');
      col += width;
    }
    if (!softWrap) value = value.trimEnd();
    if (row === point.row) offset = text.length + Math.min(columnOffset, value.length);
    text += value;
    if (!softWrap && row + 1 < term.rows) text += '\n';
  }
  const span = inputSelection || inputSpan();
  const row = buffer.viewportY + point.row;
  const inInput = span && row >= Math.floor(span.from / span.cols) && row <= Math.floor((span.to - 1) / span.cols);
  return {text, offset, atCursor: point.atCursor || !!inInput, selected: inputSelection ? term.getSelection() : ''};
}

function setTerminalHeight(height) {
  document.getElementById('term').style.height = height + 'px';
}

// tmux can erase a pane with SU (scroll up the entire scrolling region),
// then send its replacement in a later SSH packet. Keep the painted rows
// visible across that gap. xterm still processes input and output normally.
function guardPaneRedraw(screen) {
  const rows = screen.querySelector('.xterm-rows');
  let top = 0, bottom = term.rows;
  let cover, timer, heldTop, heldBottom, minimumRows;
  const populated = () => Array.from(rows.children).slice(heldTop, heldBottom)
    .reduce((count, row) => count + (row.textContent.trim() ? 1 : 0), 0);
  function uncover() {
    cover?.remove();
    cover = null;
    clearTimeout(timer);
  }
  function resetMargins() { top = 0; bottom = term.rows; }
  term.onResize(resetMargins);
  term.parser.registerEscHandler({final: 'c'}, () => { resetMargins(); return false; });
  term.parser.registerCsiHandler({final: 'r'}, ([first, last]) => {
    const start = first || 1, end = Math.min(last || term.rows, term.rows);
    if (start < end) { top = start - 1; bottom = end; }
    return false;
  });
  term.parser.registerCsiHandler({final: 'S'}, ([amount]) => {
    const height = bottom - top;
    if (cover || height < 4 || amount < height - 1) return false;
    heldTop = top;
    heldBottom = bottom;
    const prior = populated();
    if (prior < 3) return false;
    minimumRows = Math.ceil(prior / 2);
    cover = rows.cloneNode(true);
    cover.classList.add('terminal-redraw');
    cover.inert = true;
    screen.appendChild(cover);
    // A pane that genuinely becomes empty or sparse must still be shown.
    timer = setTimeout(uncover, 200);
    return false;
  });
  term.onRender(() => {
    if (cover && populated() >= minimumRows) uncover();
  });
  document.addEventListener('visibilitychange', uncover);
  window.addEventListener('pagehide', uncover);
}

// Load the local symbol face before xterm caches its first glyph measurements.
const ready = document.fonts.load('14px "Terminal Symbols"', '\ue0b0')
  .catch(() => [])
  .then(() => {
    const area = document.querySelector('#term');
    term.open(area);
    term.textarea.inputMode = 'none';
    term.textarea.addEventListener('click', event => {
      if (event.detail === 0) bridge.postMessage({showKeyboard: true});
    });
    installSelectionTouches(area);
    // OSC 133 B marks the editable input after a shell prompt when forwarded by tmux.
    term.parser.registerOscHandler(133, value => {
      if (value === 'B' || value.startsWith('B;')) markInputStart(true);
      else if (/^[ACD](;|$)/.test(value)) resetInput();
      return false;
    });
    const grid = area.querySelector('.xterm-screen');
    guardPaneRedraw(grid);
    function fitGrid() {
      // FitAddon's fit() explicitly clears every painted row before resize.
      // The DOM renderer can reuse existing row elements when resized directly.
      const size = fit.proposeDimensions();
      if (size && Number.isFinite(size.cols) && Number.isFinite(size.rows)
          && (term.cols !== size.cols || term.rows !== size.rows)) term.resize(size.cols, size.rows);
    }
    fitGrid();
    const layout = new ResizeObserver(() => {
      fitGrid();
      const {width, height} = area.getBoundingClientRect();
      const cells = grid.getBoundingClientRect();
      bridge.postMessage({layout: {width, height, gridWidth: cells.width, gridHeight: cells.height}});
    });
    layout.observe(area);
    layout.observe(grid);
  });

// Transport frames may split a UTF-8 scalar. Only give xterm complete scalars
// so its grapheme state survives the boundary between an emoji and its ZWJ.
const decoder = new TextDecoder('utf-8', {ignoreBOM: true});
window.display = async encoded => {
  await ready;
  const bytes = Uint8Array.from(atob(encoded), char => char.charCodeAt(0));
  const text = decoder.decode(bytes, {stream: true});
  if (text.length) await new Promise(done => term.write(text, done));
};
