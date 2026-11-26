// The PTY owns the edit buffer. Remember only its visible boundary, never raw keystrokes.
let inputStart = null;
let inputSelection = null;
let typedEcho = null;
let confirmedRange = null;
let pasting = false;
// UIKit orders clipboard loads and subsequent keys before committing their encoded bytes to the PTY.
let capturedInput = null;
const echoSeed = crypto.getRandomValues(new Uint32Array(1))[0];

function echoHash(text, hash = echoSeed) {
  for (let i = 0; i < text.length; i++) hash = Math.imul(hash ^ text.charCodeAt(i), 16777619) >>> 0;
  return hash;
}

// A tmux redraw may move the prompt between a keypress and its echo. Match the
// visible suffix without retaining typed characters (especially non-echoed input).
function echoedStart(cells, cursor) {
  if (!typedEcho) return -1;
  let end = cells.findIndex(cell => cell.pos >= cursor);
  if (end < 0) end = cells.length;
  let i = end, length = 0;
  while (i > 0 && length < typedEcho.length) length += cells[--i].chars.length;
  if (length !== typedEcho.length) return -1;
  const echo = cells.slice(i, end);
  return !echo.some(cell => cell.hidden) && echoHash(echo.map(cell => cell.chars).join('')) === typedEcho.hash ? i : -1;
}

function resetInput() {
  confirmedRange = null;
  inputStart = null;
  typedEcho = null;
  if (inputSelection) term.clearSelection();
  inputSelection = null;
}

function markInputStart(shell = false) {
  const b = term.buffer.active;
  const y = b.baseY + b.cursorY;
  const right = b.getLine(y)?.translateToString(true, b.cursorX) || '';
  inputStart = {type: b.type, y, x: b.cursorX, cols: term.cols, shell,
    rightDecoration: right.match(/^ {2,}(\S.*)$/u)?.[1],
    prefix: b.getLine(y)?.translateToString(false, 0, b.cursorX)};
}

function inputSpan() {
  const b = term.buffer.active;
  const y = b.baseY + b.cursorY, cols = term.cols;
  const cursor = y * cols + b.cursorX;
  let first = y, last = y;
  while (first > b.viewportY && b.getLine(first)?.isWrapped) first--;
  while (last + 1 < b.viewportY + term.rows && b.getLine(last + 1)?.isWrapped) last++;
  const anchor = inputStart;
  const anchored = anchor && anchor.type === b.type && anchor.cols === cols &&
    anchor.y >= first && anchor.y <= last && anchor.y * cols + anchor.x <= cursor &&
    anchor.prefix === b.getLine(anchor.y)?.translateToString(false, 0, anchor.x);
  const cells = [];
  for (let row = first; row <= last; row++) {
    const line = b.getLine(row);
    if (!line) return null;
    for (let x = 0; x < cols;) {
      const cell = line.getCell(x);
      const width = Math.max(1, cell.getWidth());
      cells.push({pos: row * cols + x, width, chars: cell.getChars() || ' ',
                  hidden: !!cell.isInvisible(), dim: !!cell.isDim()});
      x += width;
    }
  }
  const echo = echoedStart(cells, cursor);
  let start = 0;
  if (echo >= 0 && (!anchored || (typedEcho.fromStart && !anchor.shell))) {
    start = echo;
  } else if (anchored) {
    while (start < cells.length && cells[start].pos < anchor.y * cols + anchor.x) start++;
  } else {
    // Attached mid-command. Omit the visible prompt or the left gutter of a TUI input.
    const prefix = cells.filter(cell => cell.pos < cursor).map(cell => cell.chars).join('');
    const prompt = prefix.match(/^\s*(?:[│┃▏▎┆]\s*)*(?:(?:\([^)]*\)\s*)?(?:\[[^\]]+\]|[^\s#$%>❯›]*)[#$%>❯›]+\s+|[➜»λ]\s+)?/u)[0];
    let length = 0;
    while (start < cells.length && length < prompt.length) length += cells[start++].chars.length;
  }
  // Discard padding, a right-hand pane border and right-aligned shell decorations.
  let end = cells.length;
  while (end > start && /^[\s│┃▕┆]$/u.test(cells[end - 1].chars) && cells[end - 1].pos >= cursor) end--;
  if (anchored && anchor.rightDecoration) {
    const right = cells.slice(start, end).map(cell => cell.chars).join('');
    if (right.endsWith(anchor.rightDecoration)) {
      let n = anchor.rightDecoration.length;
      while (end > start && n > 0 && cells[end - 1].pos >= cursor) n -= cells[--end].chars.length;
      while (end > start && cells[end - 1].pos >= cursor && cells[end - 1].chars === ' ') end--;
    }
  }
  for (let i = start; i < end; i++) {
    if (cells[i].pos < cursor) continue;
    if (cells[i].dim && i > start && !cells[i - 1].dim) { end = i; break; }
    if (cells[i].chars === ' ' && cells[i + 1]?.chars === ' ' && !anchored) {
      end = i; break;
    }
  }
  if (echo >= 0 && typedEcho.fromStart) {
    // Shell autosuggestions can be rendered as ordinary colored cells after the cursor.
    // Only the bytes that actually echoed belong to a newly typed command.
    while (end > start && cells[end - 1].pos >= cursor) end--;
  }
  if (confirmedRange && confirmedRange.type === b.type && confirmedRange.cols === cols &&
      cursor >= confirmedRange.from && cursor <= confirmedRange.to) {
    const left = cells.findIndex(cell => cell.pos === confirmedRange.from);
    const right = cells.findIndex(cell => cell.pos + cell.width === confirmedRange.to);
    if (left >= 0 && right >= left && echoHash(cells.slice(left, right + 1).map(cell => cell.chars).join('')) === confirmedRange.hash) {
      start = left;
      end = right + 1;
    }
  }
  const content = cells.slice(start, end);
  if (!content.length || content.some(cell => cell.hidden)) return null;
  const from = content[0].pos, to = content.at(-1).pos + content.at(-1).width;
  if (cursor < from || cursor > to) return null;
  return {type: b.type, from, to, cursor, cols, text: content.map(cell => cell.chars).join(''),
          before: content.filter(cell => cell.pos < cursor).length,
          after: content.filter(cell => cell.pos >= cursor).length};
}

function selectTerminalInput(x, y, firstTap = null) {
  const span = inputSpan();
  if (!span) return false;
  const point = terminalPoint(x, y);
  const row = term.buffer.active.viewportY + point.row;
  const onLine = row >= Math.floor(span.from / span.cols) && row <= Math.floor((span.to - 1) / span.cols);
  // Showing the keyboard on the first tap can move the remote input before the second tap.
  if (!onLine && !(firstTap && firstTap.type === span.type && firstTap.text === span.text)) return false;
  term.focus();
  term.select(span.from % span.cols, Math.floor(span.from / span.cols), span.to - span.from);
  inputSelection = span;
  return true;
}

function pasteTerminal(text, confirmed = false, capture = false) {
  // tmux can enable bracketed paste on its client while the pane itself is in plain mode.
  text = text.replace(/[\r\n]+$/, '');
  if (!confirmed && /[\r\n]/.test(text)) return {confirm: true};
  if (!text) return {data: ''};
  pasting = true;
  try {
    if (capture) return {data: captureTerminalData(() => term.paste(text))};
    term.paste(text);
  } finally {
    pasting = false;
  }
}

function captureTerminalData(action) {
  capturedInput = '';
  try { action(); return capturedInput; }
  finally { capturedInput = null; }
}

function deliverTerminalData(data) {
  if (capturedInput === null) bridge.postMessage({data});
  else capturedInput += data;
}

function terminalData(data) {
  // Mouse/focus reports from the TUI do not move the shell's edit boundary.
  if (/^\x1b\[(?:<|M|[IO]$)/.test(data)) { deliverTerminalData(data); return; }
  const horizontalArrow = /^\x1b(?:\[|O)[CD]$/.test(data);
  const moving = horizontalArrow || data === '\x01' || data === '\x05';
  if (moving && !inputSelection) {
    const span = inputSpan();
    if (span) confirmedRange = {type: span.type, cols: span.cols, from: span.from, to: span.to, hash: echoHash(span.text)};
  } else if (!inputSelection) { confirmedRange = null; }
  const selected = inputSelection;
  const paste = pasting || data.startsWith('\x1b[200~');
  const text = data.length > 0 && data.codePointAt(0) >= 32 && data[0] !== '\x7f';
  const deletion = data === '\x7f' || data === '\b' || data === '\x1b[3~';
  if (!selected && text && !/[\x00-\x1f\x7f]/.test(data)) {
    const length = (typedEcho?.length ?? 0) + data.length;
    typedEcho = length <= 16384 ? {length, hash: echoHash(data, typedEcho?.hash),
      fromStart: typedEcho?.fromStart ?? !inputStart} : null;
  } else if (!selected) { typedEcho = null; }
  if (selected) {
    const current = inputSpan();
    confirmedRange = null;
    typedEcho = null;
    inputSelection = null;
    term.clearSelection();
    if (text || paste || deletion) {
      // A remote redraw (including editing on another connected client) invalidates the selection.
      if (!current || current.type !== selected.type || current.cols !== selected.cols ||
          current.cursor !== selected.cursor || current.from !== selected.from ||
          current.to !== selected.to || current.text !== selected.text) { inputStart = null; return; }
      data = '\x1b[3~'.repeat(current.after) + '\x7f'.repeat(current.before) + (deletion ? '' : data);
      inputStart = {type: current.type, cols: current.cols, y: Math.floor(current.from / current.cols),
        x: current.from % current.cols, prefix: term.buffer.active.getLine(Math.floor(current.from / current.cols))
          .translateToString(false, 0, current.from % current.cols)};
    }
  } else if ((text || paste) && !inputStart) {
    markInputStart();
  }
  if (!paste && (/[\r\n]/.test(data) || (!text && !deletion && !horizontalArrow))) inputStart = null;
  deliverTerminalData(data);
}

function installSelectionTouches(area) {
  area.addEventListener('paste', event => {
    if (!event.clipboardData) return;
    event.preventDefault();
    event.stopImmediatePropagation();
    bridge.postMessage({pasteText: event.clipboardData.getData('text/plain')});
  }, true);
  let start, lastTap, selectedOnSecondTap = false;
  area.addEventListener('touchstart', event => {
    const t = event.touches[0];
    start = event.touches.length === 1 ? {x: t.clientX, y: t.clientY, time: event.timeStamp} : null;
    if (start) {
      const hit = terminalPoint(start.x, start.y);
      const span = inputSpan();
      const row = term.buffer.active.viewportY + hit.row;
      if (span && row >= Math.floor(span.from / span.cols) && row <= Math.floor((span.to - 1) / span.cols)) {
        start.span = span;
      }
    }
    selectedOnSecondTap = !!(start && lastTap && start.time - lastTap.time < 380 &&
      Math.hypot(start.x - lastTap.x, start.y - lastTap.y) < 24 && selectTerminalInput(start.x, start.y, lastTap.span));
    if (selectedOnSecondTap) {
      event.preventDefault();
      event.stopImmediatePropagation();
      lastTap = null;
    }
  }, {capture: true, passive: false});
  area.addEventListener('touchend', event => {
    if (selectedOnSecondTap) {
      event.preventDefault();
      event.stopImmediatePropagation();
      selectedOnSecondTap = false;
    } else {
      const t = event.changedTouches[0];
      const tap = start && event.timeStamp - start.time < 320 &&
        Math.hypot(t.clientX - start.x, t.clientY - start.y) < 12;
      lastTap = tap ? {x: t.clientX, y: t.clientY, time: event.timeStamp, span: start.span} : null;
      if (tap) { term.focus(); requestTerminalKeyboard(); }
      if (tap && inputSelection) { term.clearSelection(); inputSelection = null; }
    }
    start = null;
  }, {capture: true, passive: false});
  area.addEventListener('touchcancel', () => { start = lastTap = null; selectedOnSecondTap = false; });
}
