# pimer: Pi Coding Agent for R

A lightweight `ellmer`-style chat interface to [Pi Coding Agent](https://pi.dev/docs/latest/rpc) via its **official JSONL RPC protocol**. Pi runs once per R chat object, so its current model, configured tools, extensions, and project instructions remain available across turns.

**Status:** 0.1.1 prototype. Not affiliated with Pi or ellmer; not published on CRAN. Offline mock tests are included. Real Pi/model integration has not been tested in this build environment.

## Install

First install and configure Pi (a working `pi` executable and authenticated model are required):

```bash
npm install -g @mariozechner/pi-coding-agent
pi  # follow provider login/configuration, then exit
```

Then install from GitHub:

```r
install.packages("pak")
pak::pak("kongdd/pimer")
library(pimer)
```

For local/offline installation instead, first install `R6`, `processx`,
`jsonlite`, and `coro`, then install the bundled source tarball:

```r
install.packages("pimer_0.1.1.tar.gz", repos = NULL, type = "source")
```

Or if you extracted the source folder, use `pak::local_install("/path/to/pimer")` or `devtools::install("/path/to/pimer")`.

## Basic chat and persistent context

```r
library(pimer)
chat <- chat_pi(system_prompt = "Answer in concise Chinese.")
chat$chat("什么是 Richards 方程？")
chat$chat("它的边界条件有哪些？")    # Same Pi process + conversation context
chat$get_tokens()                 # Per-assistant-message input/output/cache/cost
chat$get_last_tokens()            # Aggregate tokens of the last chat() request
chat$get_cost()                   # Local accumulation of assistant costs, USD
chat$get_stats()                  # Pi-reported full-session totals and context use
chat$clear()                      # Start fresh context; retains Pi process and model
chat$chat("新问题：解释 EnKF")
chat$close()                      # Release subprocess
```

`system_prompt` **appends** instructions to Pi's native system prompt and is fixed at process creation. Default chats are kept **in memory** (`persist=FALSE`), so no Pi session file is written.

## Pass R objects directly

```r
x <- data.frame(station = c("A", "B"), distance_km = c(0, 3.2))
chat <- chat_pi(tools = character())  # No model tools for purely analytical extraction
chat$chat("找出疑似迁站，给出简短原因：", x)
chat$close()
```

R objects are serialized to JSON (data frames as arrays of rows). Since full objects are included in prompts, subset very large tables before sending.

## Structured extraction

```r
schema <- pi_type_array(pi_type_object(
  date = pi_type_string(),
  suspicious = pi_type_boolean(),
  reason = pi_type_string(),
  confidence = pi_type_enum(c("low", "medium", "high"))
))

chat <- chat_pi(tools = character())
result <- chat$chat_structured(
  "Assess these potential station relocations:",
  data.frame(date = c("2016-01-01", "2021-09-01"), dist_km = c(0, 1.24)),
  type = schema, retries = 1
)
chat$clear()    # One station/table per independent evaluation
chat$close()
```

The supported JSON schema subset is `string`, `integer`, `number`, `boolean`, `enum`, `array`, and `object` with `required` and `additionalProperties=FALSE`. **The schema is included in the prompt; Pi RPC does not provide an ellmer-style native structured decoding endpoint.** The response is parsed and checked locally; invalid responses can be retried. Model output is not guaranteed to be factually correct merely because it passes validation. You can pass an existing JSON Schema list instead of using these helpers.

## Stream output, models, commands, and tools

```r
chat <- chat_pi(echo = TRUE, tools = c("read", "grep", "find", "ls"))
chat$chat("Summarize the README of this project")

# coro iterator yields incremental chunks (consumed on demand)
library(coro)
chunks <- chat$stream("Summarize in one sentence")
loop(for (chunk in chunks) cat(chunk))

# Or collect streamed chunks as a list
chunks <- chat$stream("Explain EnKF")
text <- paste0(unlist(coro::collect(chunks)), collapse = "")
chat$get_model()
chat$get_models()
chat$get_commands()             # Pi prompt templates, skills, extension commands
chat$set_model("YOUR_PROVIDER", "YOUR_MODEL_ID")  # Use an installed model ID
chat$set_thinking("low")
chat$rpc("get_state")           # Raw RPC escape hatch
chat$close()
```

Pi extensions and built-in tools already configured in Pi are available. **R-defined function registration is not yet supported.** This is a subprocess RPC client, not a reimplementation of Pi's extension system.

## Independent records

For classifying many unrelated records, create **one** Pi process and call `$clear()` between records. This avoids restarting Pi but does **not** preserve prompt-cache/context tokens between fresh sessions. Every request still incurs its model's configured input/output cost. For dependent cases, keep the session instead of clearing it.

```r
chat <- chat_pi(tools = character())
on.exit(chat$close(), add = TRUE)  # Inside an R function
for (i in seq_len(nrow(stations))) {
  if (i > 1L) chat$clear()
  answer <- chat$chat_structured("Review station record:", stations[i, ], type = schema)
  # Save answer immediately in your chosen table/store.
}
```

## Security and limitations

- Pi normally has **file editing and shell-command tools**. Choose `tools = character()` or a read-only allowlist for untrusted input.
- `$bash()` executes a shell command in Pi's working directory; treat it as privileged.
- `$stream()` returns a **lazy, blocking `coro` generator** (matching `ellmer`'s synchronous stream). Calling `coro::collect()` or `coro::loop()` advances it. It is not a non-blocking `async_generator()`.
- `$get_cost()` summarizes ordinary assistant messages; `$get_stats()` is authoritative for Pi's full-session totals (including nested tools and compaction).
- Pi RPC extensions that request interactive UI responses are not implemented in this prototype.
- Finish consuming a stream before starting another chat or clearing a session. If abandoned mid-stream, call `$interrupt()` and resume draining or `$close()`.
- A timeout raises an R error; an in-progress model run may remain active, so call `$interrupt()` or `$close()` explicitly.
- Each R Chat object launches a dedicated subprocess; call `$close()` when finished.

## Development tests

```r
install.packages("testthat")
testthat::test_local("/path/to/pimer")
```

Tests launch an **offline mock Pi RPC subprocess**, with no model credentials or network access. Real provider integration requires your own Pi installation.

Official reference: <https://pi.dev/docs/latest/rpc>, <https://pi.dev/docs/latest/rpc-commands>, <https://pi.dev/docs/latest/json>.
