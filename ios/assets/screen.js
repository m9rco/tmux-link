const term = new Terminal({
  allowProposedApi: true, // Required by the pinned Unicode provider.
  cursorBlink: true,
  cursorStyle: 'bar',
  cursorWidth: 2,
  fontFamily: '"Terminal Symbols", ui-monospace, Menlo, monospace',
  fontSize: 14,
  lineHeight: 1.12,
  scrollback: 4000,
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
term.onResize(({cols, rows}) => bridge.postMessage({cols, rows}));

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
