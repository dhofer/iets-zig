# The syntax tree as JSON

`iets parse --json` prints the syntax tree of a Nix file as JSON. This page
lists the node kinds, their keys and their spans.

```
$ printf 'a: a.b or 1' > t.nix
$ iets parse --json t.nix
{"file":"t.nix","root":{"kind":"lambda","start":0,"end":11,"arg":"a","formals":null,"ellipsis":false,"body":{"kind":"select","start":3,"end":11,"subject":{"kind":"var","start":3,"end":4,"name":"a"},"path":["b"],"default":{"kind":"int","start":10,"end":11,"value":1}}}}
```

Each file that parses gives one line, a JSON object with these keys:

| Key | Value |
|---|---|
| `file` | the file name, as you gave it on the command line |
| `root` | the node of the top expression |

A file that does not parse gives no line. Its error goes to stderr, and the
exit code is 1 (`docs/reference/commands.md`).

## Nodes

A node is a JSON object with a `kind`. Every node starts with these keys,
followed by the keys of its kind:

| Key | Value |
|---|---|
| `kind` | the name of the kind, from the next table |
| `start` | the byte offset of the first byte of the node in the file |
| `end` | the byte offset after the last byte of the node |

Offsets count bytes from 0. The source text of a node is the bytes from
`start` to `end - 1`. A value that is not an object with a `kind` is a
plain value of its parent, and has no span.

| `kind` | Keys | Source |
|---|---|---|
| `int` | `value`: an integer | `1`, `-1` |
| `float` | `value`: a number | `1.5` |
| `string` | `parts`: a list of text and nodes | `"a${b}"`, `''a''`, `http://a.b` |
| `path` | `form`: `relative`, `absolute`, `home` or `search`; `parts`: a list of text and nodes | `./a`, `/a`, `~/a`, `<a>` |
| `var` | `name` | `a` |
| `select` | `subject`: a node; `path`: an attribute path; `default`: a node or `null` | `a.b.c or d` |
| `has-attr` | `subject`: a node; `path`: an attribute path | `a ? b.c` |
| `attrs` | `rec`: a Boolean; `binds`: a list of `bind` and `inherit` nodes | `{ }`, `rec { }` |
| `bind` | `path`: an attribute path; `value`: a node | `a.b = c;` |
| `inherit` | `from`: a node or `null`; `names`: a list of `name` nodes | `inherit a;`, `inherit (e) a b;` |
| `name` | `name` | the `a` of `inherit a;` |
| `list` | `items`: a list of nodes | `[ a b ]` |
| `lambda` | `arg`: a name or `null`; `formals`: a list of `formal` nodes, or `null`; `ellipsis`: a Boolean; `body`: a node | `a: b`, `{ a, ... }@s: b` |
| `formal` | `name`; `default`: a node or `null` | the `a ? 1` of `{ a ? 1 }: b` |
| `apply` | `func`: a node; `args`: a list of nodes | `f a b` |
| `let` | `binds`: a list of `bind` and `inherit` nodes; `body`: a node | `let a = 1; in a` |
| `with` | `scope`: a node; `body`: a node | `with a; b` |
| `if` | `cond`, `then`, `else`: nodes | `if a then b else c` |
| `assert` | `cond`, `body`: nodes | `assert a; b` |
| `unary` | `op`: `!` or `-`; `expr`: a node | `!a`, `-a` |
| `binary` | `op`; `lhs`, `rhs`: nodes | `a + b` |

The `op` of a `binary` node is one of `==`, `!=`, `<`, `>`, `<=`, `>=`,
`&&`, `||`, `->`, `//`, `++`, `+`, `-`, `*`, `/`.

Text in `parts` is a JSON string. It holds the text after the parser has
decoded the escapes and removed the indentation of a `''` string. An
interpolation in `parts` is the node of its expression.

An attribute path is a list. A name written out in the source (`a`, `"a"`)
is a JSON string. A name the evaluator must compute (`${e}`, `"a${e}"`) is
the node of its expression.

A `lambda` of the form `a: b` has `formals` `null`, and `arg` is the
argument. A `lambda` with a pattern has the list in `formals`, and `arg` is
the name after `@`, or `null`.

## Stability

The names of the kinds and the keys do not change. A new version can add a
key to a kind, or a kind for new syntax, so your program must ignore a key
or kind it does not know.

## Limits

- Comments are not in the tree. If you need them, read the file between
  the spans of two nodes.
- Parentheses make no node. The span of `(a)` is the span of `a`.
- The text in `parts`, a name in an attribute path and the `arg` of a
  `lambda` have no span of their own. Their node has one.
- Some forms of the source give the kind of another form. `let { body =
  a; }` is a `select` of `body` on an `attrs` node with `rec` `true`, and a
  URL without quotation marks is a `string`. The first bytes of the span
  show which form the source has.
- `-1` is an `int` with the value -1, because the parser makes one number
  from a minus sign and a number.
- The span of a `binary`, `select`, `has-attr` or `apply` node starts where
  its first operand starts, so some nodes share a `start`.
- Text that is not UTF-8 has the replacement character U+FFFD for each bad
  sequence. The text form of `iets parse` shows the bytes.
