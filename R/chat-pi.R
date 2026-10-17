#' Start a Pi chat session from R
#'
#' Creates a long-lived Pi RPC subprocess. Chats retain context until `$clear()`
#' is called, and reuse the Pi models, skills, tools and extensions configured
#' for the working directory. The subprocess is stopped with `$close()`.
#'
#' @param model Optional Pi model ID or pattern (e.g. "openai/gpt-5").
#' @param provider Provider name when a model is explicitly supplied.
#' @param system_prompt Optional extra system instructions, appended to Pi's
#'   default system prompt instead of replacing tool instructions.
#' @param tools Optional vector of Pi tool names. `character()` disables tools;
#'   `NULL` keeps Pi's configured defaults. Pi tools may execute shell commands
#'   or modify files: restrict them for untrusted input.
#' @param cwd Project directory where Pi runs; controls AGENTS.md, resources, etc.
#' @param persist Whether to save conversations to Pi's session storage.
#'   Defaults to FALSE, so no session file is saved.
#' @param session Optional Pi session file to resume; implies persistence.
#' @param echo Print streamed assistant text to the R console by default.
#' @param timeout Timeout in seconds for each request or chat.
#' @param pi Path to the Pi executable (can be overridden for testing).
#' @return An R6 chat object with `$chat()`, `$chat_structured()`,
#'   `$stream()`, `$clear()`, `$get_tokens()`, `$get_cost()`, `$get_stats()`,
#'   `$get_messages()`, `$set_model()`, `$get_model()`, `$get_commands()`,
#'   `$rpc()`, and `$close()` methods.
#' @importFrom processx process
#' @export
chat_pi <- function(model = NULL, provider = NULL, system_prompt = NULL,
                    tools = NULL, cwd = getwd(), persist = FALSE,
                    session = NULL, echo = FALSE, timeout = 180, pi = "pi") {
  if (!is.character(pi) || length(pi) != 1L || !nzchar(pi)) stop("Invalid Pi executable.")
  pi_exe <- Sys.which(pi)
  if (!nzchar(pi_exe) && file.exists(pi)) pi_exe <- normalizePath(pi)
  if (!nzchar(pi_exe)) stop("Pi executable not found; install Pi and check PATH.", call. = FALSE)
  if (!dir.exists(cwd)) stop("Working directory does not exist.", call. = FALSE)
  if (!is.numeric(timeout) || length(timeout) != 1L || is.na(timeout) || timeout <= 0) {
    stop("'timeout' must be a positive number.", call. = FALSE)
  }
  if (!is.null(provider) && is.null(model)) stop("'provider' requires 'model'.", call. = FALSE)
  if (!is.null(session) && !is.character(session)) stop("'session' must be a path.", call. = FALSE)
  args <- c("--mode", "rpc")
  if (!is.null(model)) args <- c(args, "--model", model)
  if (!is.null(provider)) args <- c(args, "--provider", provider)
  if (!is.null(tools)) {
    if (!is.character(tools)) stop("'tools' must be a character vector.", call. = FALSE)
    if (!length(tools)) args <- c(args, "--no-tools")
    else args <- c(args, "--tools", paste(tools, collapse = ","))
  }
  if (!persist && is.null(session)) args <- c(args, "--no-session")
  if (!is.null(session)) args <- c(args, "--session", session)
  prompt_file <- NULL
  if (!is.null(system_prompt)) {
    stopifnot(is.character(system_prompt), length(system_prompt) == 1L)
    prompt_file <- tempfile("pimer-system-", fileext = ".md")
    writeLines(system_prompt, prompt_file, useBytes = TRUE)
    args <- c(args, "--append-system-prompt", prompt_file)
  }
  tryCatch(
    PiChat$new(executable = unname(pi_exe), args = args, wd = cwd,
               echo = echo, timeout = timeout, prompt_file = prompt_file),
    error = function(e) {
      if (!is.null(prompt_file)) unlink(prompt_file)
      stop(conditionMessage(e), call. = FALSE)
    }
  )
}

format_pi_input <- function(...) {
  x <- list(...)
  if (!length(x)) stop("Supply at least one prompt or data object.", call. = FALSE)
  convert <- function(z) {
    if (is.character(z)) return(paste(z, collapse = "\n"))
    if (is.data.frame(z) || is.list(z) || is.atomic(z)) {
      return(as.character(jsonlite::toJSON(z, auto_unbox = TRUE,
        dataframe = "rows", na = "null", null = "null", POSIXt = "ISO8601")))
    }
    stop("Cannot serialize object of class: ", paste(class(z), collapse = "/"), call. = FALSE)
  }
  paste(vapply(x, convert, character(1)), collapse = "\n\n")
}

empty_tokens <- function() {
  data.frame(input = numeric(), output = numeric(), cached_input = numeric(),
             cache_write = numeric(), cost = numeric())
}

PiChat <- R6::R6Class("PiChat",
  public = list(
    initialize = function(executable, args, wd, echo, timeout, prompt_file) {
      private$default_echo <- isTRUE(echo)
      private$timeout <- timeout
      private$prompt_file <- prompt_file
      private$proc <- processx::process$new(executable, args = args, wd = wd,
        stdin = "|", stdout = "|", stderr = "|", cleanup = TRUE, cleanup_tree = TRUE)
      private$responses <- new.env(parent = emptyenv())
      private$events <- list()
      private$tokens <- empty_tokens()
      private$last_start <- 0L
      private$counter <- 0L
      private$settled <- 0L
      private$errors <- character()
      private$output_buffer <- raw()
    },
    chat = function(..., echo = NULL) {
      private$do_chat(format_pi_input(...), echo = echo)
    },
    # Like ellmer::Chat$stream(): return a lazy coro iterator of text deltas.
    # A session is busy from first iteration until the iterator is exhausted.
    stream = function(..., echo = FALSE) {
      message <- format_pi_input(...)
      new_stream <- coro::generator(function() {
        run <- private$begin_chat(message, echo = echo, streaming = TRUE)
        on.exit(private$finish_chat(), add = TRUE)
        if (!identical(run$disposition, "handled")) {
          repeat {
            if (length(private$chunks)) {
              chunk <- private$chunks[[1L]]
              private$chunks <- private$chunks[-1L]
              yield(chunk)
            } else if (private$settled > run$settled) {
              break
            } else {
              private$until(function() {
                length(private$chunks) > 0L || private$settled > run$settled
              })
            }
          }
        }
        if (isTRUE(private$streaming_echo)) cat("\n")
        if (!is.null(private$last_run_error)) {
          stop("Pi model error: ", private$last_run_error, call. = FALSE)
        }
      })
      new_stream()
    },
    chat_structured = function(..., type, echo = FALSE, convert = TRUE, retries = 1L) {
      if (!is.list(type) || is.null(type$type)) stop("'type' must be a JSON schema list.")
      if (length(retries) != 1L || is.na(retries) || retries < 0 || retries != as.integer(retries)) {
        stop("'retries' must be a non-negative integer.")
      }
      prompt <- format_pi_input(...)
      schema_json <- as.character(jsonlite::toJSON(type, auto_unbox = TRUE,
        pretty = TRUE, null = "null"))
      instruction <- paste0(
        "Return only valid JSON conforming exactly to the following JSON Schema. ",
        "No Markdown, no explanations, no code fences. Do not fabricate missing facts; ",
        "use schema-compatible values and mention uncertainty where schema permits.\n",
        schema_json, "\n\nINPUT:\n", prompt)
      for (attempt in seq_len(as.integer(retries) + 1L)) {
        result <- self$chat(instruction, echo = echo)
        result <- strip_json_fence(result)
        value <- tryCatch(jsonlite::fromJSON(result, simplifyVector = FALSE),
                          error = function(e) e)
        err <- if (inherits(value, "error")) conditionMessage(value) else check_schema(value, type)
        if (is.null(err)) {
          if (!isTRUE(convert)) return(value)
          return(jsonlite::fromJSON(result, simplifyVector = TRUE))
        }
        if (attempt > retries) stop("Invalid structured response: ", err, call. = FALSE)
        instruction <- paste0("Your previous JSON was invalid (", err,
          "). Correct it. Return ONLY JSON matching the original schema. ",
          "Do not change the underlying source facts.")
      }
    },
    clear = function() {
      if (isTRUE(private$busy)) {
        stop("Finish the active stream before clearing the session.", call. = FALSE)
      }
      data <- self$rpc("new_session")
      if (isTRUE(data$cancelled)) stop("Pi extension cancelled new_session.", call. = FALSE)
      private$tokens <- empty_tokens()
      private$last_start <- 0L
      private$last_text <- NULL
      private$events <- list()
      invisible(self)
    },
    get_tokens = function() private$tokens,
    get_last_tokens = function() {
      if (nrow(private$tokens) <= private$last_start) return(empty_tokens())
      x <- private$tokens[seq.int(private$last_start + 1L, nrow(private$tokens)), , drop = FALSE]
      as.data.frame(as.list(colSums(x)))
    },
    get_cost = function(include = c("all", "last")) {
      include <- match.arg(include)
      x <- private$tokens$cost
      if (!length(x)) return(0)
      if (include == "last") return(sum(self$get_last_tokens()$cost))
      sum(x)
    },
    get_stats = function() self$rpc("get_session_stats"),
    get_state = function() self$rpc("get_state"),
    get_model = function() self$get_state()$model,
    get_models = function() self$rpc("get_available_models")$models,
    set_model = function(provider, model) {
      self$rpc("set_model", provider = provider, modelId = model)
      invisible(self)
    },
    set_thinking = function(level) {
      self$rpc("set_thinking_level", level = level)
      invisible(self)
    },
    get_messages = function() self$rpc("get_messages")$messages,
    get_turns = function() self$get_messages(),
    get_commands = function() self$rpc("get_commands")$commands,
    last_response = function() private$last_text,
    get_events = function(clear = FALSE) {
      events <- private$events
      if (isTRUE(clear)) private$events <- list()
      events
    },
    bash = function(command, exclude_from_context = FALSE) {
      self$rpc("bash", command = command, excludeFromContext = exclude_from_context)
    },
    rpc = function(type, ...) private$request(type, list(...)),
    interrupt = function() {
      self$rpc("abort")
      invisible(self)
    },
    is_alive = function() !is.null(private$proc) && private$proc$is_alive(),
    close = function() {
      if (!is.null(private$proc)) {
        if (private$proc$is_alive()) {
          try(private$proc$write_input(NULL), silent = TRUE)
          try(private$proc$wait(timeout = 250), silent = TRUE)
          if (private$proc$is_alive()) try(private$proc$kill(), silent = TRUE)
        }
        private$proc <- NULL
      }
      if (!is.null(private$prompt_file)) {
        unlink(private$prompt_file)
        private$prompt_file <- NULL
      }
      invisible(NULL)
    },
    finalize = function() self$close()
  ),
  private = list(
    proc = NULL, prompt_file = NULL, timeout = NULL, default_echo = FALSE, last_start = 0L,
    counter = NULL, responses = NULL, events = NULL, tokens = NULL,
    settled = 0L, last_text = NULL, last_run_error = NULL,
    busy = FALSE, is_stream = FALSE, chunks = NULL,
    streaming_echo = FALSE, errors = NULL, output_buffer = NULL,
    record = function(event) {
      type <- event$type
      if (identical(type, "response") && !is.null(event$id)) {
        assign(event$id, event, envir = private$responses)
      } else {
        private$events[[length(private$events) + 1L]] <- event
        if (length(private$events) > 1000L) private$events <- tail(private$events, 1000L)
      }
      if (identical(type, "agent_settled")) private$settled <- private$settled + 1L
      if (identical(type, "message_update")) {
        update <- event$assistantMessageEvent
        if (identical(update$type, "text_delta") && !is.null(update$delta)) {
          if (isTRUE(private$streaming_echo)) cat(update$delta)
          if (isTRUE(private$is_stream)) {
            private$chunks <- c(private$chunks, update$delta)
          }
        }
      }
      if (identical(type, "message_end") && identical(event$message$role, "assistant")) {
        msg <- event$message
        blocks <- msg$content
        texts <- vapply(Filter(function(x) identical(x$type, "text"), blocks),
                        function(x) x$text %||% "", character(1))
        if (length(texts)) private$last_text <- paste(texts, collapse = "\n")
        if (isTRUE(msg$stopReason %in% c("error", "aborted"))) {
          private$last_run_error <- msg$errorMessage %||% msg$stopReason
        }
        usage <- msg$usage
        if (!is.null(usage)) {
          row <- data.frame(
            input = as.numeric(usage$input %||% 0),
            output = as.numeric(usage$output %||% 0),
            cached_input = as.numeric(usage$cacheRead %||% 0),
            cache_write = as.numeric(usage$cacheWrite %||% 0),
            cost = as.numeric(usage$cost$total %||% 0)
          )
          private$tokens <- rbind(private$tokens, row)
        }
      }
    },
    pump = function(wait_ms = 100L) {
      if (is.null(private$proc)) stop("Pi session already closed.", call. = FALSE)
      private$proc$poll_io(as.integer(wait_ms))
      # Read *bytes*, not read_output_lines(): a JSONL record can exceed the
      # ~64 KB pipe buffer. Convert to UTF-8 only after finding a full LF line.
      chunk <- private$proc$read_output_bytes()
      if (length(chunk)) {
        buf <- c(private$output_buffer, chunk)
        ends <- which(buf == as.raw(10L))
        start <- 1L
        if (length(ends)) for (end in ends) {
          line <- if (end > start) rawToChar(buf[seq.int(start, end - 1L)]) else ""
          line <- sub("\r$", "", line)
          if (nzchar(line)) {
            event <- tryCatch(jsonlite::fromJSON(line, simplifyVector = FALSE),
              error = function(e) stop("Malformed Pi RPC JSON: ", conditionMessage(e), call. = FALSE))
            private$record(event)
          }
          start <- end + 1L
        }
        private$output_buffer <- if (start <= length(buf)) buf[seq.int(start, length(buf))] else raw()
      }
      errs <- private$proc$read_error_lines()
      if (length(errs)) private$errors <- tail(c(private$errors, errs), 50L)
      invisible(NULL)
    },
    until = function(done) {
      deadline <- Sys.time() + private$timeout
      repeat {
        private$pump()
        if (isTRUE(done())) return(invisible(NULL))
        if (!private$proc$is_alive()) {
          stop("Pi RPC process exited unexpectedly. ", paste(tail(private$errors, 8L), collapse = "\n"),
            call. = FALSE)
        }
        if (Sys.time() >= deadline) {
          stop("Pi RPC timed out after ", private$timeout,
               " seconds; run may still be active. Use $interrupt() or $close().", call. = FALSE)
        }
      }
    },
    request = function(type, args = list()) {
      if (is.null(private$proc)) stop("Pi RPC process is closed.", call. = FALSE)
      if (!private$proc$is_alive()) {
        private$pump(0L)
        detail <- paste(tail(private$errors, 8L), collapse = "\n")
        stop("Pi RPC process is not running.",
             if (nzchar(detail)) paste0("\nChild stderr:\n", detail) else "",
             call. = FALSE)
      }
      private$counter <- private$counter + 1L
      id <- paste0("pimer-", private$counter)
      body <- c(list(id = id, type = type), args)
      json <- as.character(jsonlite::toJSON(body, auto_unbox = TRUE, null = "null"))
      pending <- private$proc$write_input(paste0(json, "\n"), sep = "")
      deadline <- Sys.time() + private$timeout
      while (length(pending)) {
        private$pump()
        if (!private$proc$is_alive()) stop("Pi exited while writing input.", call. = FALSE)
        if (Sys.time() >= deadline) stop("Timed out writing Pi RPC input.", call. = FALSE)
        pending <- private$proc$write_input(pending)
      }
      private$until(function() exists(id, envir = private$responses, inherits = FALSE))
      response <- get(id, envir = private$responses, inherits = FALSE)
      rm(list = id, envir = private$responses)
      if (!isTRUE(response$success)) {
        stop("Pi RPC ", type, ": ", response$error %||% "unknown error", call. = FALSE)
      }
      response$data
    },
    begin_chat = function(message, echo = NULL, streaming = FALSE) {
      if (isTRUE(private$busy)) {
        stop("Another Pi prompt or stream is already active.", call. = FALSE)
      }
      private$busy <- TRUE
      started <- FALSE
      on.exit(if (!started) private$finish_chat(), add = TRUE)
      private$chunks <- character()
      private$is_stream <- isTRUE(streaming)
      private$last_start <- nrow(private$tokens)
      private$last_text <- NULL
      private$last_run_error <- NULL
      private$streaming_echo <- if (is.null(echo)) private$default_echo else isTRUE(echo)
      previous <- private$settled
      ack <- private$request("prompt", list(message = message))
      started <- TRUE
      list(settled = previous, disposition = ack$disposition %||% "started")
    },
    finish_chat = function() {
      private$busy <- FALSE
      private$is_stream <- FALSE
      private$chunks <- character()
      private$streaming_echo <- FALSE
      invisible(NULL)
    },
    do_chat = function(message, echo = NULL) {
      run <- private$begin_chat(message, echo = echo)
      on.exit(private$finish_chat(), add = TRUE)
      if (!identical(run$disposition, "handled")) {
        private$until(function() private$settled > run$settled)
      }
      if (isTRUE(private$streaming_echo)) cat("\n")
      if (!is.null(private$last_run_error)) {
        stop("Pi model error: ", private$last_run_error, call. = FALSE)
      }
      private$last_text %||% ""
    }
  )
)

`%||%` <- function(x, y) if (is.null(x)) y else x
