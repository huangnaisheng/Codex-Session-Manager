# Why changing the model on a saved session breaks it

Measured on `codex-cli 0.160.0` against a third-party Responses-compatible
provider.

## Short version

Codex keeps each conversation in two places, and only one of them retains the
provider's encrypted reasoning payload. Resuming an existing session reads the
copy that has had that payload stripped. The model that produced the reasoning
can still resolve it by id, so nothing looks wrong until you switch models. At
that point the provider rejects the whole request with `invalid_request`.

Rewriting `threads.model` in `state_5.sqlite` cannot fix this, because the
problem is the stored history that gets replayed, not the model name.
`codex fork` does work, because it re-reads the transcript that still carries the
payload.

## The two stores

`~/.codex` holds the same conversation twice.

`thread_history_1.sqlite`, table `thread_items`, is the paginated projection the
CLI reads when it resumes a session. Each row is one item of type `userMessage`,
`agentMessage`, `reasoning`, `commandExecution` or `fileChange`.

`~/.codex/sessions/<year>/<month>/<day>/rollout-*.jsonl` is the original
transcript. One JSON record per line, each carrying an `ordinal`.

## The measurement

For a session that ran on one model and then had its stored model rewritten to
another:

| | rollout `.jsonl` | `thread_items` |
| --- | --- | --- |
| bytes | 6,104,776 | n/a |
| lines / rows | 207 | 41 |
| reasoning records | 15 | 15 |
| `rs_` ids | 30 | 15 |
| `encrypted_content` | 15 | 0 |
| `input_image` | 2 | paths only |

Both stores hold the same 15 reasoning items. The rollout keeps
`encrypted_content` on every one of them. The projection keeps none.

This is a reasoning row as the projection stores it:

```json
{"type":"reasoning","id":"rs_0de439395d90f0dd016abd369a141887d09abf44d10712a5e6","summary":[],"content":[]}
```

`content` and `summary` are empty. All that survives is an id.

## Why the same model still works

That id is resolvable by the service node that issued it. Resume the session on
the model that produced the reasoning and the provider looks the id up and
carries on. Nothing in the local data looks broken, and no warning is printed.

Switch the model and the request lands on a different node. That node did not
issue the id, cannot resolve it, and has no payload to fall back on. It answers
`invalid_request` and the turn fails. The error text comes from the relay and
mentions nothing about reasoning items, so the failure does not look like it has
anything to do with the model change.

## Why `codex fork` works

`codex fork` does not copy history. It writes a new rollout whose first record
names the source:

```json
{"type":"session_meta","payload":{
  "forked_from_id":"<source session id>",
  "forked_from_ordinal_exclusive":211
}}
```

Everything before that ordinal is read from the source rollout at run time, and
the source rollout is the copy that still has `encrypted_content`. The new
session therefore gets a complete history with the payload intact, and any model
can read it.

A fork's own rollout file holds only the records created after the fork point.
The two forks measured here were 81,010 and 65,499 bytes, against source files of
650,495 and 6,104,776 bytes. Their ordinal ranges began at 211 and 207, exactly
the line counts of their sources. Neither fork file contained a single
`encrypted_content` payload or a single embedded image.

## A fork depends on its source

Because history is referenced rather than copied, deleting the source session
destroys the fork's history. `codex fork` followed by `codex delete` on the old
session is not a migration, it is data loss.

Keep the source. If the old session has to leave the list, archive it, and check
first that archiving leaves the rollout file in place.

## What to do instead

Do not change the model of a session that already has turns recorded on a
different model.

Empty sessions are safe. With no history there is no reasoning to replay.

To carry a conversation across to another model, fork it:

```powershell
codex exec fork <session-id> -m <model> --skip-git-repo-check "<prompt>"
```

`codex exec fork` requires a prompt. Without one it tries to read stdin and exits
with an error when stdin is not a terminal. Every headless fork therefore spends
one turn on the target model and leaves that message behind in the new session.
`codex fork` from the TUI has the same cost and additionally needs a terminal.

A cleaner fork exists as the `thread/fork` method on the experimental
`codex app-server` JSON-RPC interface. It creates the fork without running a
turn, at the cost of driving that interface directly.

The other approach, not implemented in this repository, is to rebuild the
conversation as plain text. Read the user and agent messages in order, write them
into a fresh session, and drop the reasoning items entirely. The resulting
request carries no opaque provider state and works on any model. The cost is the
native tool-call structure and the reasoning chain.

## Practical notes

Changing `reasoning_effort` alone still replays the same history. Treat it as
equally unsafe on a session with turns on a different model.

`codex exec fork` has no `--effort` flag. Pass the effort through configuration
instead:

```powershell
codex exec fork <session-id> -m <model> -c model_reasoning_effort="high" --skip-git-repo-check "<prompt>"
```

A fork inherits reasoning effort from the source session, not from `config.toml`.

`codex delete` refuses to run without an interactive terminal unless `--force`
and a session UUID are both supplied. A session name is not accepted in that
mode.
