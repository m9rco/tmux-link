'use strict';
const bridge = window.webkit.messageHandlers.typingKeyboard;
const choices = document.getElementById('candidates');
const spelling = document.getElementById('spelling');
const letters = ['q w e r t y u i o p', 'a s d f g h j k l', '{shift} z x c v b n m {bksp}'];
const bottom = '{lang} {symbols} , {space} . {enter}';
const symbols = ['1 2 3 4 5 6 7 8 9 0', '- / : ; ( ) $ & @ "', "{more} . , ? ! ' _ = {bksp}"];
const more = ['[ ] {braceL} {braceR} # % ^ * + =', '~ ` | \\ < > € £ ¥ •', '{more} - / : ; ! ? @ {bksp}'];
const shortcuts = {en: ['/','-','_','|','~','`','=','[',']'], zh: ['，','。','？','！','、','：','“','”',"'"]};
let language = 'en', page = 'letters', shifted = false, pending = '';
let options = [], shown = 0;

// A partial choice stays editable until the rest of the spelling is confirmed.
const selected = [];
let undoChoice = false, localBackspaceHold = false;

function hasDraft() {
  return Boolean(pending || selected.length);
}

function selectedText() {
  return selected.map(segment => segment.text).join('');
}

function send(text) {
  // The native bridge accepts at most 512 UTF-8 bytes per message.
  let chunk = '';
  for (const scalar of text) {
    if (chunk.length + scalar.length > 128) {
      bridge.postMessage({text: chunk});
      chunk = '';
    }
    chunk += scalar;
  }
  if (chunk) bridge.postMessage({text: chunk});
}

function finish(text) {
  send(selectedText() + text);
  selected.length = 0;
  pending = '';
  undoChoice = false;
  refreshChoices();
}

function choose(index) {
  const item = options[index];
  if (!item) return;
  if (!hasDraft()) { send(item.text); return; }
  const rest = pending.slice(item.end).replace(/^'+/, '');
  if (!rest) { finish(item.text); return; }
  selected.push({text: item.text, source: pending.slice(0, pending.length - rest.length)});
  pending = rest;
  undoChoice = true;
  refreshChoices();
}

function backspace(event) {
  // simple-keyboard supplies an event only for the initial press of a hold.
  if (event) localBackspaceHold = hasDraft();
  if (!hasDraft()) {
    if (!localBackspaceHold) send('\x7f');
    return;
  }
  if (selected.length && (undoChoice || !pending)) {
    pending = selected.pop().source + pending;
    undoChoice = selected.length > 0;
  } else {
    pending = pending.slice(0, -1);
  }
  refreshChoices();
}

function appendChoices() {
  for (const limit = Math.min(shown + 24, options.length); shown < limit; shown++) {
    const button = document.createElement('button');
    button.type = 'button';
    button.tabIndex = -1;
    button.textContent = options[shown].text || '确认';
    button.dataset.index = shown;
    choices.appendChild(button);
  }
}

function refreshChoices() {
  spelling.textContent = selectedText() + pending;
  spelling.scrollLeft = spelling.scrollWidth;
  if (pending) options = candidates(pending);
  else if (selected.length) options = [{text: '', end: 0}];
  else options = shortcuts[language].map(text => ({text, end: 0}));
  if (pending && !options.length) options.push({text: pending, end: pending.length});
  choices.replaceChildren();
  choices.scrollLeft = 0;
  shown = 0;
  appendChoices();
}
spelling.addEventListener('click', () => { if (hasDraft()) finish(pending); });
choices.addEventListener('click', event => {
  const button = event.target.closest('button');
  if (button) choose(Number(button.dataset.index));
});
choices.addEventListener('scroll', () => {
  if (choices.scrollLeft + choices.clientWidth >= choices.scrollWidth - 40) appendChoices();
});

function names() {
  return {'{lang}': language === 'en' ? '中文' : 'ABC', '{symbols}': page === 'letters' ? '123' : 'ABC',
    '{more}': page === 'more' ? '123' : '#+=', '{shift}': shifted ? '⬆' : '⇧', '{bksp}': '⌫',
    '{space}': language === 'zh' ? '空格' : 'space', '{enter}': '↵', '{braceL}': '{', '{braceR}': '}', '<': '&lt;', '>': '&gt;'};
}

function updateLayout() {
  keyboard.setOptions({layoutName: page === 'letters' && shifted ? 'upper' : page, display: names()});
}

function resetComposition() {
  selected.length = 0;
  undoChoice = localBackspaceHold = false;
  pending = '';
  shifted = false;
  page = 'letters';
  updateLayout();
  refreshChoices();
}

function handleKey(key, event) {
  switch (key) {
  case '{lang}':
    language = language === 'en' ? 'zh' : 'en';
    page = 'letters'; shifted = false;
    updateLayout(); refreshChoices();
    return;
  case '{shift}': shifted = !shifted; updateLayout(); return;
  case '{symbols}': page = page === 'letters' ? 'symbols' : 'letters'; updateLayout(); return;
  case '{more}': page = page === 'more' ? 'symbols' : 'more'; updateLayout(); return;
  case '{bksp}': backspace(event); return;
  case '{enter}':
  case '{space}':
    if (!hasDraft()) send(key === '{space}' ? ' ' : '\r');
    else if (language === 'zh') choose(0);
    else finish(pending + (key === '{space}' ? ' ' : ''));
    return;
  case '{braceL}': key = '{'; break;
  case '{braceR}': key = '}'; break;
  }
  if (language === 'zh' && (/^[a-z]$/.test(key) || (key === "'" && pending))) {
    pending += key;
    undoChoice = false;
    refreshChoices();
    return;
  }
  if (!hasDraft()) send(key);
  else if (language === 'en') finish(pending + key);
  else {
    // Commit punctuation after the converted prefix, preserving an unrecognized tail.
    let rest = pending, converted = '', best = options[0];
    while (best && best.end) {
      converted += best.text;
      rest = rest.slice(best.end);
      best = rest ? candidates(rest)[0] : null;
    }
    finish(converted + rest + key);
  }
  if (shifted) { shifted = false; updateLayout(); }
}

function handleShortcut(key) {
  if (hasDraft() && key === '\x1b') { resetComposition(); return; }
  if (hasDraft() && key === '\r') { handleKey('{enter}'); return; }
  send(key);
}

// The terminal owns the edit buffer. The library supplies key hit testing,
// repeat and layout only. Keep its optional text buffer empty.
const keyboard = new window.SimpleKeyboard.default('.simple-keyboard', {
  layout: {letters: [...letters, bottom], upper: [...letters.map(row => row.replace(/\b[a-z]\b/g, x => x.toUpperCase())), bottom],
    symbols: [...symbols, bottom], more: [...more, bottom]},
  layoutName: 'letters', display: names(), inputPattern: /^$/, useButtonTag: true,
  preventMouseDownDefault: true, preventMouseUpDefault: true, onKeyPress: handleKey,
  onKeyReleased: () => { localBackspaceHold = false; }
});
// VoiceOver can activate a button with a click and no pointer event.
document.querySelector('.simple-keyboard').addEventListener('click', event => {
  const key = event.target.closest('[data-skbtn]')?.dataset.skbtn;
  if (event.detail === 0 && key) keyboard.handleButtonClicked(key);
});
refreshChoices();
