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
term.onData(data => bridge.postMessage({data}));
// Legacy mouse reports contain raw coordinate bytes, including values above 127.
term.onBinary(bytes => bridge.postMessage({binary: btoa(bytes)}));
term.onResize(({cols, rows}) => bridge.postMessage({cols, rows}));

// Use the same wheel encoder as a desktop xterm so tmux and a full-screen
// application receive the mouse protocol they actually negotiated.
function scrollRemote(x, y, fingerSteps, first) {
  // Dragging content down reveals earlier rows (wheel up or Page Up).
  const steps = -fingerSteps;
  if (!['vt200', 'drag', 'any'].includes(term.modes.mouseTrackingMode)) {
    if (first) term.input(steps < 0 ? '\x1b[5~' : '\x1b[6~', true);
    return;
  }
  const screen = term.element.querySelector('.xterm-screen');
  const rect = screen.getBoundingClientRect();
  const event = {
    bubbles: true, cancelable: true, deltaMode: 1, deltaY: Math.sign(steps),
    clientX: Math.max(rect.left, Math.min(rect.right - 1, x * innerWidth)),
    clientY: Math.max(rect.top, Math.min(rect.bottom - 1, y * innerHeight))
  };
  for (let i = 0; i < Math.min(8, Math.abs(steps)); i++) {
    screen.dispatchEvent(new WheelEvent('wheel', event));
  }
}

// Load the local symbol face before xterm caches its first glyph measurements.
const ready = document.fonts.load('14px "Terminal Symbols"', '\ue0b0')
  .catch(() => [])
  .then(() => {
    term.open(document.querySelector('#term'));
    fit.fit();
    new ResizeObserver(() => fit.fit()).observe(document.body);
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
