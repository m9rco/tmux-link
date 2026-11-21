const term = new Terminal({cursorBlink:true, fontSize:13, scrollback:3000, theme:{background:'#101218'}});
const fit = new FitAddon.FitAddon();
term.loadAddon(fit);
term.open(document.querySelector('#term'));
const bridge = window.webkit.messageHandlers.terminal;
term.onData(data => bridge.postMessage({data}));
term.onResize(({cols,rows}) => bridge.postMessage({cols,rows}));
new ResizeObserver(() => fit.fit()).observe(document.body);
window.display = bytes => new Promise(done => term.write(Uint8Array.from(atob(bytes), c=>c.charCodeAt(0)),done));
