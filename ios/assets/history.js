// Keep rendered rows, never input or raw control bytes. One instance per terminal.
function terminalHistory(term) {
  const rows = new Array(2000);
  const maxChars = 256 * 1024;
  let first = 0, count = 0, chars = 0;

  function remember(line) {
    while (count && (count === rows.length || chars + line.length > maxChars)) {
      chars -= rows[first].length;
      rows[first] = undefined;
      first = (first + 1) % rows.length;
      count--;
    }
    rows[(first + count) % rows.length] = line;
    count++;
    chars += line.length;
  }

  // xterm 6 has no public before-scroll event. Hook the pinned scroll service
  // before rows are recycled (LF, IND and automatic wraps). tmux usually sets
  // the bottom margin above its status bar, even when using the alternate screen.
  const service = term._core._bufferService;
  function capture(top, amount) {
    const buffer = term.buffer.active;
    for (let i = 0; i < amount; i++) {
      const row = buffer.getLine(buffer.baseY + top + i);
      if (row) remember(row.translateToString(true));
    }
  }
  const scroll = service.scroll;
  service.scroll = function(...args) {
    capture(this.buffer.scrollTop, 1);
    return scroll.apply(this, args);
  };

  // SU and DL move rows directly without calling the scroll service.
  for (const final of ['S', 'M']) {
    term.parser.registerCsiHandler({final}, ([amount]) => {
      const {scrollTop, scrollBottom, y} = service.buffer;
      const top = final === 'S' ? scrollTop : y;
      if (top >= scrollTop && top <= scrollBottom) {
        capture(top, Math.min(amount || 1, scrollBottom - top + 1));
      }
      return false; // xterm still renders the original command.
    });
  }
  return function snapshot() {
    const lines = Array.from({length: count}, (_, i) => rows[(first + i) % rows.length]);
    const buffer = term.buffer.active;
    const visible = [];
    for (let i = 0; i < term.rows; i++) {
      visible.push(buffer.getLine(buffer.baseY + i)?.translateToString(true) ?? '');
    }
    while (visible.length && !visible[visible.length - 1]) visible.pop();
    return lines.concat(visible).join('\n');
  };
}
