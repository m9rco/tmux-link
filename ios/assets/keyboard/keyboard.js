'use strict';
const bridge = window.webkit.messageHandlers.typingKeyboard;
const choices = document.getElementById('candidates');
const spelling = document.getElementById('spelling');
const letters = ['q w e r t y u i o p', 'a s d f g h j k l', '{shift} z x c v b n m {bksp}'];
const bottom = '{lang} {symbols} , {space} . {enter}';
const symbols = ['1 2 3 4 5 6 7 8 9 0', '- / : ; ( ) $ & @ "', "{more} . , ? ! ' _ = {bksp}"];
const more = ['[ ] {braceL} {braceR} # % ^ * + =', '~ ` | \\ < > € £ ¥ •', '{more} - / : ; ! ? @ {bksp}'];
const shortcuts = {en: ['/','-','_','|','~','`','=','[',']'], zh: ['，','。','？','！','、','：','“','”',"'"]};
let language = window.initialLanguage === 'zh' ? 'zh' : 'en', page = 'letters', shifted = false, pending = '';
let options = [], shown = 0;

function send(text) {
  if (text) bridge.postMessage({text});
}

function matches(input) {
  const result = [];
  for (let end = input.length; end > 0; end--) {
    const part = input.slice(0, end);
    if (part.endsWith("'")) continue;
    const key = Object.hasOwn(pinyinLexicon, part) ? part : part.replaceAll("'", '');
    if (Object.hasOwn(pinyinLexicon, key)) result.push({words: pinyinLexicon[key], end});
  }
  return result;
}

function candidates(input) {
  const found = matches(input);
  const result = found.flatMap(({words, end}) => words.split(' ').map(text => ({text, end})));
  // A prompt can span several dictionary entries. Offer their longest-prefix
  // conversion, and keep the individual entries available for manual choices.
  let rest = input, converted = '', parts = 0;
  let first = found[0];
  while (first) {
    converted += first.words.split(' ', 1)[0];
    parts++;
    rest = rest.slice(first.end).replace(/^'+/, '');
    first = matches(rest)[0];
  }
  if (parts > 1 && !rest) result.unshift({text: converted, end: input.length});
  return result;
}

function choose(index) {
  const item = options[index];
  if (!item) return;
  send(item.text);
  pending = pending.slice(item.end).replace(/^'+/, '');
  refreshChoices();
}

function appendChoices() {
  for (const limit = Math.min(shown + 24, options.length); shown < limit; shown++) {
    const button = document.createElement('button');
    button.type = 'button';
    button.tabIndex = -1;
    button.textContent = options[shown].text;
    button.dataset.index = shown;
    choices.appendChild(button);
  }
}

function refreshChoices() {
  spelling.textContent = pending;
  options = pending ? candidates(pending) : shortcuts[language].map(text => ({text, end: 0}));
  if (pending && !options.length) options.push({text: pending, end: pending.length});
  choices.replaceChildren();
  choices.scrollLeft = 0;
  shown = 0;
  appendChoices();
}
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
  pending = '';
  shifted = false;
  page = 'letters';
  updateLayout();
  refreshChoices();
}

function handleKey(key) {
  switch (key) {
  case '{lang}':
    language = language === 'en' ? 'zh' : 'en';
    resetComposition();
    bridge.postMessage({language});
    return;
  case '{shift}': shifted = !shifted; updateLayout(); return;
  case '{symbols}': page = page === 'letters' ? 'symbols' : 'letters'; updateLayout(); return;
  case '{more}': page = page === 'more' ? 'symbols' : 'more'; updateLayout(); return;
  case '{bksp}':
    if (pending) { pending = pending.slice(0, -1); refreshChoices(); } else send('\x7f');
    return;
  case '{enter}':
  case '{space}':
    if (pending) choose(0); else send(key === '{space}' ? ' ' : '\r');
    return;
  case '{braceL}': key = '{'; break;
  case '{braceR}': key = '}'; break;
  }
  if (language === 'zh' && (/^[a-z]$/.test(key) || (key === "'" && pending))) {
    if (pending.length < 64) pending += key;
    refreshChoices();
    return;
  }
  // Punctuation follows the composition. Preserve any unrecognized tail.
  while (pending) choose(0);
  send(key);
  if (shifted) { shifted = false; updateLayout(); }
}

function handleShortcut(key) {
  if (pending) {
    resetComposition();
    if (key === '\x1b') return;
  }
  send(key);
}

// The terminal owns the edit buffer. The library supplies key hit testing,
// repeat and layout only. Keep its optional text buffer empty.
const keyboard = new window.SimpleKeyboard.default('.simple-keyboard', {
  layout: {letters: [...letters, bottom], upper: [...letters.map(row => row.replace(/\b[a-z]\b/g, x => x.toUpperCase())), bottom],
    symbols: [...symbols, bottom], more: [...more, bottom]},
  layoutName: 'letters', display: names(), inputPattern: /^$/, useButtonTag: true,
  preventMouseDownDefault: true, preventMouseUpDefault: true, onKeyPress: handleKey
});
// VoiceOver can activate a button with a click and no pointer event.
document.querySelector('.simple-keyboard').addEventListener('click', event => {
  const key = event.target.closest('[data-skbtn]')?.dataset.skbtn;
  if (event.detail === 0 && key) keyboard.handleButtonClicked(key);
});
refreshChoices();
