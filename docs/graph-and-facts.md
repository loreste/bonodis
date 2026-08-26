# Graph, facts, and leases

Bonodis has built-in commands for directed edges, subject-predicate-object triples, confidence scores, and single-holder leases. All of these are same-shard only -- keys must share a hash tag.

## Edges

Create a directed edge between two keys:

```
RELATE {bot}user {bot}prefs "settings"
RELATE {bot}user {bot}history "viewed"
```

Query:

```
NEIGHBORS {bot}user
# {bot}prefs, {bot}history

PATH {bot}user {bot}prefs
# {bot}user -> {bot}prefs
```

Remove:

```
UNRELATE {bot}user {bot}prefs
```

`PATH` does BFS, capped at 6 hops.

## Facts (triples)

Store subject-predicate-object triples:

```
FACT ADD {bot}alice likes "dark mode"
FACT ADD {bot}alice uses "vim"
FACT ADD {bot}alice speaks "python"
```

Query:

```
FACT OF {bot}alice
# likes -> dark mode, uses -> vim, speaks -> python

FACT WHO {bot}alice likes
# dark mode
```

Remove:

```
FACT DEL {bot}alice uses "vim"
```

## Beliefs and tensions

`BELIEVE` is `FACT ADD` with a confidence score (0-100):

```
BELIEVE {bot}alice prefers "tabs" 80
BELIEVE {bot}alice prefers "spaces" 60
```

`TENSIONS` finds predicates where a key has multiple objects -- potential contradictions:

```
TENSIONS {bot}alice
# prefers -> tabs (80), spaces (60)
```

## ASK

Query interface that combines facts and edges:

```
ASK {bot}alice OF          # same as FACT OF
ASK {bot}alice WHO likes   # objects for a predicate, with scores
ASK {bot}alice QUERY "vim" # token overlap search on facts and edges
ASK {bot}alice HOPS 2      # BFS on outgoing edges, 2 hops deep
```

## WHY

Shows edges, facts, and confidence scores for a key in one call:

```
WHY {bot}alice
```

## Focus list

Per-session attention tracking. `ATTEND` prepends a key to a 24-item list:

```
ATTEND {bot}sess {bot}alice
ATTEND {bot}sess {bot}prefs
FOCUS {bot}sess
# {bot}prefs, {bot}alice
```

The list is capped at 24. Oldest entries fall off. `TURN` includes the focus list in its output.

## Budget / Spend

Integer counter that refuses to go below zero:

```
BUDGET {bot}sess 1000
SPEND {bot}sess 200
# :800
SPEND {bot}sess 900
# -ERR budget exhausted
```

`TURN` includes the remaining budget.

## Leases

Single-holder locks with a TTL:

```
LEASE {bot}lock 30     # acquire for 30 seconds
# :1 (acquired)

LEASE {bot}lock 30     # someone else tries
# :0 (already held)

LEASED {bot}lock       # check
# :1

UNLEASE {bot}lock      # release early
```

The lease expires automatically after the TTL.

## Hash tag requirement

All these commands require same-slot keys. Use `{tag}` to ensure keys hash together:

```
# These all share the hash tag "bot"
{bot}alice
{bot}prefs
{bot}sess
{bot}lock
```

Without hash tags, keys may land on different shards and the commands will return `CROSSSLOT`.
