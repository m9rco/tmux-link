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

// Load the local symbol face before xterm caches its first glyph measurements.
const ready = document.fonts.load('14px "Terminal Symbols"', '\ue0b0')
  .catch(() => [])
  .then(() => {
    const area = document.querySelector('#term');
    term.open(area);
    installSelectionTouches(area);
    // OSC 133 B marks the editable input after a shell prompt when forwarded by tmux.
    term.parser.registerOscHandler(133, value => {
      if (value === 'B' || value.startsWith('B;')) markInputStart(true);
      else if (/^[ACD](;|$)/.test(value)) resetInput();
      return false;
    });
    const grid = area.querySelector('.xterm-screen');
    fit.fit();
    const layout = new ResizeObserver(() => {
      fit.fit();
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
