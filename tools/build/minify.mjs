// SPDX-License-Identifier: AGPL-3.0-or-later
// Conservative Lua minifier: strips comments and indentation, collapses whitespace, keeps every newline so line
// numbers in error messages still match the source. Strings and long strings are never touched.
//
// Because Tessera is AGPL-3.0, minified payloads are only acceptable because the original source is published and
// every manifest links to it (see docs/PACKAGE-FORMAT.md).

/** Returns the minified source. Throws on unterminated strings/comments. */
export function minifyLua(src) {
  const out = [];
  const n = src.length;
  let i = 0;
  let line = 1;

  const longBracket = (pos) => {
    // returns the level if src[pos..] starts a long bracket "[=*[", else -1
    if (src[pos] !== '[') return -1;
    let j = pos + 1;
    let level = 0;
    while (src[j] === '=') { level++; j++; }
    return src[j] === '[' ? level : -1;
  };
  const skipLong = (pos, level) => {
    const close = ']' + '='.repeat(level) + ']';
    const end = src.indexOf(close, pos);
    if (end < 0) throw new Error(`unterminated long bracket at line ${line}`);
    return end + close.length;
  };

  // shebang
  if (src.startsWith('#!')) {
    while (i < n && src[i] !== '\n') i++;
  }

  while (i < n) {
    const c = src[i];
    if (c === '\n') { out.push('\n'); i++; line++; continue; }
    if (c === '\r') { i++; continue; }
    if (c === ' ' || c === '\t') {
      let j = i;
      while (j < n && (src[j] === ' ' || src[j] === '\t')) j++;
      out.push(' ');
      i = j;
      continue;
    }
    if (c === '-' && src[i + 1] === '-') {
      // comment
      const level = longBracket(i + 2);
      if (level >= 0) {
        const end = skipLong(i + 2 + level + 2, level);
        const body = src.slice(i, end);
        const nl = (body.match(/\n/g) || []).length;
        out.push('\n'.repeat(nl));
        line += nl;
        i = end;
      } else {
        while (i < n && src[i] !== '\n') i++;
      }
      continue;
    }
    if (c === '"' || c === "'") {
      let j = i + 1;
      while (j < n && src[j] !== c) {
        if (src[j] === '\\') j++; // skip escaped char (also \<newline>)
        if (src[j] === '\n') line++;
        else if (src[j] === undefined) break;
        j++;
      }
      if (j >= n) throw new Error(`unterminated string at line ${line}`);
      out.push(src.slice(i, j + 1));
      i = j + 1;
      continue;
    }
    if (c === '[') {
      const level = longBracket(i);
      if (level >= 0) {
        const end = skipLong(i + level + 2, level);
        const body = src.slice(i, end);
        line += (body.match(/\n/g) || []).length;
        out.push(body);
        i = end;
        continue;
      }
    }
    out.push(c);
    i++;
  }

  // second pass on a per-line basis is unsafe once strings are embedded, so do a token-aware trim instead:
  // rebuild using a light re-scan that only removes spaces adjacent to safe punctuation and at line ends.
  return trimSpaces(out.join(''));
}

/** Remove leading/trailing spaces per line and spaces next to , ( ) { } ; — outside of strings. */
function trimSpaces(s) {
  const res = [];
  let i = 0;
  const n = s.length;
  const isSafe = (ch) => ch === ',' || ch === '(' || ch === ')' || ch === '{' || ch === '}' || ch === ';';
  while (i < n) {
    const c = s[i];
    if (c === '"' || c === "'") {
      let j = i + 1;
      while (j < n && s[j] !== c) { if (s[j] === '\\') j++; j++; }
      res.push(s.slice(i, j + 1));
      i = j + 1;
      continue;
    }
    if (c === '[') {
      let j = i + 1;
      let level = 0;
      while (s[j] === '=') { level++; j++; }
      if (s[j] === '[') {
        const close = ']' + '='.repeat(level) + ']';
        const end = s.indexOf(close, j) + close.length;
        res.push(s.slice(i, end));
        i = end;
        continue;
      }
    }
    if (c === ' ') {
      const prev = res.length ? res[res.length - 1] : '';
      const last = prev[prev.length - 1];
      const next = s[i + 1];
      if (last === undefined || last === '\n' || last === ' ' || next === '\n' || next === undefined || next === ' ') { i++; continue; }
      if (isSafe(last) && last !== ')' && last !== '}') { i++; continue; }
      if (isSafe(next) && next !== '(' && next !== '{') { i++; continue; }
      res.push(' ');
      i++;
      continue;
    }
    res.push(c);
    i++;
  }
  return res.join('').replace(/\n+$/, '\n');
}
