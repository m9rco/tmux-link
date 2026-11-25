'use strict';

const bridge = window.webkit.messageHandlers.typingKeyboard;
const letters = ['q w e r t y u i o p', 'a s d f g h j k l', '{shift} z x c v b n m {bksp}'];
const bottom = '{symbols} , {space} . {enter}';
const symbols = ['1 2 3 4 5 6 7 8 9 0', '- / : ; ( ) $ & @ "', "{more} . , ? ! ' _ = {bksp}"];
const more = ['[ ] {braceL} {braceR} # % ^ * + =', '~ ` | \\ < > € £ ¥ •', '{more} - / : ; ! ? @ {bksp}'];
let page = 'letters';
let shifted = false;

function names() {
  return {
    '{symbols}': page === 'letters' ? '123' : 'ABC', '{more}': page === 'more' ? '123' : '#+=',
    '{shift}': shifted ? '⬆' : '⇧', '{bksp}': '⌫', '{space}': 'space', '{enter}': '↵',
    '{braceL}': '{', '{braceR}': '}', '<': '&lt;', '>': '&gt;'
  };
}

function updateLayout() {
  keyboard.setOptions({layoutName: page === 'letters' && shifted ? 'upper' : page, display: names()});
}

function resetLayout() {
  shifted = false;
  page = 'letters';
  updateLayout();
}

function send(text) {
  bridge.postMessage({text});
}

function handleKey(key) {
  switch (key) {
  case '{shift}': shifted = !shifted; updateLayout(); return;
  case '{symbols}': page = page === 'letters' ? 'symbols' : 'letters'; updateLayout(); return;
  case '{more}': page = page === 'more' ? 'symbols' : 'more'; updateLayout(); return;
  case '{bksp}': send('\x7f'); return;
  case '{enter}': send('\r'); return;
  case '{space}': send(' '); return;
  case '{braceL}': key = '{'; break;
  case '{braceR}': key = '}'; break;
  }
  send(key);
  if (shifted) { shifted = false; updateLayout(); }
}

document.getElementById('punctuation').addEventListener('click', event => {
  const button = event.target.closest('button');
  if (button) send(button.textContent);
});

// The terminal owns the edit buffer; simple-keyboard handles layout, touch and key repeat.
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
