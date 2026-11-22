The bundled simple-keyboard modern browser build is version 3.8.206, distributed under the MIT license. [Upstream](https://github.com/simple-keyboard/simple-keyboard) · [Package](https://www.npmjs.com/package/simple-keyboard/v/3.8.206)

The simplified Chinese dictionary is derived from Android PinyinIME through rime-pinyin-simp, distributed under Apache 2.0. The bundled index groups entries by spelling and orders candidates by the upstream weights. The accompanying AUTHORS and LICENSE files are from the same revision. [Pinned dictionary](https://github.com/rime/rime-pinyin-simp/blob/0c6861ef7420ee780270ca6d993d18d4101049d0/pinyin_simp.dict.yaml)

To regenerate the index, run `python3 scripts/build-pinyin-lexicon.py pinyin_simp.dict.yaml ios/assets/keyboard/pinyin.js` from the repository root.
