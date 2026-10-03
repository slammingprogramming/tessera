# tsr.inet.http.html

Package: `web`

A small HTML reader for text screens: parses the usual tags into a tree and lays it out as wrapped lines of coloured pieces, with the links collected.
Understood: title, h1-h6, p, br, hr, a, b/strong, i/em/u, ul/ol/li, pre/code, blockquote, table (rows shown with " | "), img (its alt text), div and the
like as blocks; scripts, styles and comments are dropped; the entities &amp; &lt; &gt; &quot; &apos; &nbsp; and numeric ones are decoded.

## `M.parse(html)`

Parse into a tree: { tag, attrs, children } with text nodes as plain strings.

## `M.layout(tree, width)`

Lay out a tree. Returns { title, lines = { { { text, kind, link } ... } ... }, links = { { href, text, line } ... } }.
kind: "text" | "bold" | "italic" | "head" | "code" | "link". width: characters per line.

## `M.render(html, width, isText)`

Parse and lay out in one call. Plain text (not HTML) is shown as it is.

## `M.plain(page)`

The plain text of a rendered page (for tests and for piping to a file).
