'use strict';

// Compare complete segmentations using word frequencies. A locally longer
// match can consume the first letter of the next syllable, as in qing + bang.
function candidates(raw) {
  // A selection consumes only its displayed prefix. The rest of a long draft
  // stays editable, including letters beyond the current decoding window.
  const input = raw.slice(0, 96);
  const paths = Array.from({length: input.length + 1}, () => []);
  paths[0].push({text: '', cost: 0});
  const prefixes = [], cache = new Map();
  const keep = 4;
  function offer(list, text, cost) {
    const duplicate = list.findIndex(item => item.text === text);
    if (duplicate >= 0) {
      if (list[duplicate].cost <= cost) return;
      list.splice(duplicate, 1);
    }
    if (list.length === keep && cost >= list[keep - 1].cost) return;
    let position = list.findIndex(item => item.cost > cost);
    if (position === -1) position = list.length;
    list.splice(position, 0, {text, cost});
    if (list.length > keep) list.pop();
  }
  for (let start = 0; start < input.length; start++) {
    if (!paths[start].length) continue;
    if (input[start] === "'") {
      for (const path of paths[start]) offer(paths[start + 1], path.text, path.cost);
      continue;
    }
    let spelling = '', required = 0;
    for (let i = start; i < input.length && spelling.length < maxPinyinWordLength; i++) {
      if (input[i] === "'") { required |= 1 << spelling.length; continue; }
      spelling += input[i];
      if (!Object.hasOwn(pinyinLexicon, spelling)) continue;
      if (!cache.has(spelling)) {
        cache.set(spelling, pinyinLexicon[spelling].split(' ').map(token => {
          const [text, cost, mask] = token.split(':');
          return {text, cost: Number(cost), mask: Number(mask || 0)};
        }));
      }
      const words = cache.get(spelling);
      const matching = required ? words.filter(word => (word.mask & required) === required) : words;
      if (start === 0 && matching.length) prefixes.push({words: matching, end: i + 1});
      for (const word of matching.slice(0, keep)) {
        for (const path of paths[start])
          offer(paths[i + 1], path.text + word.text, path.cost + word.cost);
      }
    }
  }
  const result = [], seen = new Set();
  function add(text, end) {
    const key = end + '/' + text;
    if (text && !seen.has(key)) { seen.add(key); result.push({text, end}); }
  }
  let end = input.length;
  while (end && !paths[end].length) end--;
  for (const path of paths[end]) add(path.text, end);
  for (const match of prefixes.reverse())
    for (const {text} of match.words) add(text, match.end);
  return result;
}
