const term = new Terminal({cursorBlink:true, cursorStyle:'bar', cursorWidth:2, fontFamily:'ui-monospace, Menlo, monospace', fontSize:14, lineHeight:1.12, scrollback:4000, theme:{background:'#0a141a',foreground:'#dce8eb',cursor:'#79e8c9',selectionBackground:'#345057',black:'#16272e',green:'#7ddbb5',cyan:'#75d6e9',yellow:'#efbb78',red:'#fb8985'}});
const fit = new FitAddon.FitAddon();
term.loadAddon(fit);
term.open(document.querySelector('#term'));
const bridge = window.webkit.messageHandlers.terminal;
term.onData(data => bridge.postMessage({data}));
term.onResize(({cols,rows}) => bridge.postMessage({cols,rows}));
new ResizeObserver(() => fit.fit()).observe(document.body);
window.display = bytes => new Promise(done => term.write(Uint8Array.from(atob(bytes), c=>c.charCodeAt(0)),done));
