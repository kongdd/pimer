# Offline Pi JSONL test double. Launched as Rscript, not as a Pi CLI.
msgs <- list()
count <- 0L
send <- function(x) {
  cat(as.character(jsonlite::toJSON(x, auto_unbox = TRUE, null = "null")), "\n", sep = "")
  flush(stdout())
}
repeat {
  line <- readLines(stdin(), n = 1L, warn = FALSE)
  if (!length(line)) break
  cmd <- jsonlite::fromJSON(line, simplifyVector = FALSE)
  id <- cmd$id
  reply <- function(command, data = list(), success = TRUE, error = NULL) {
    send(list(id = id, type = "response", command = command, success = success,
              data = data, error = error))
  }
  if (identical(cmd$type, "prompt")) {
    reply("prompt", list(disposition = "started"))
    count <- count + 1L
    answer <- if (grepl("Return only valid JSON", cmd$message, fixed = TRUE)) {
      '[{"date":"2021-09-01","suspicious":true}]'
    } else if (grepl("LARGE_OUTPUT", cmd$message, fixed = TRUE)) {
      paste(rep("汉", 30000L), collapse = "")
    } else paste0("Reply ", count, " ✓")
    if (grepl("LARGE_OUTPUT", cmd$message, fixed = TRUE)) {
      parts <- answer
    } else if (grepl("Return only valid JSON", cmd$message, fixed = TRUE)) {
      parts <- answer
    } else {
      parts <- c(sub("✓$", "", answer), "✓")
    }
    for (part in parts) {
      send(list(type = "message_update", assistantMessageEvent = list(type = "text_delta", delta = part)))
    }
    msgs[[length(msgs) + 1L]] <- list(role = "user", content = cmd$message)
    response <- list(role = "assistant", content = list(list(type = "text", text = answer)),
      stopReason = "stop", usage = list(input = 20, output = 10, cacheRead = 5,
                                        cacheWrite = 0, cost = list(total = 0.001)))
    msgs[[length(msgs) + 1L]] <- response
    send(list(type = "message_end", message = response))
    send(list(type = "agent_end", messages = list(response)))
    send(list(type = "agent_settled", aborted = FALSE))
  } else if (identical(cmd$type, "get_state")) {
    reply(cmd$type, list(model = list(provider = "test", id = "mock"), messageCount = length(msgs)))
  } else if (identical(cmd$type, "get_session_stats")) {
    reply(cmd$type, list(tokens = list(input = count * 20, output = count * 10,
              cacheRead = count * 5, total = count * 35), cost = count * 0.001))
  } else if (identical(cmd$type, "get_messages")) {
    reply(cmd$type, list(messages = msgs))
  } else if (identical(cmd$type, "new_session")) {
    msgs <- list()
    count <- 0L
    reply(cmd$type, list(cancelled = FALSE))
  } else if (identical(cmd$type, "set_model") || identical(cmd$type, "set_thinking_level")) {
    reply(cmd$type)
  } else if (identical(cmd$type, "get_commands")) {
    reply(cmd$type, list(commands = list(list(name = "test"))))
  } else if (identical(cmd$type, "get_available_models")) {
    reply(cmd$type, list(models = list(list(provider = "test", id = "mock"))))
  } else if (identical(cmd$type, "bash")) {
    reply(cmd$type, list(output = "mock shell output", exitCode = 0))
  } else {
    reply(cmd$type, success = FALSE, error = "unknown command")
  }
}
