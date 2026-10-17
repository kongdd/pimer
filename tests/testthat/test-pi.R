make_mock_chat <- function() {
  # R CMD check --as-cran deliberately shadows Rscript on PATH to catch
  # non-portable subprocess launches. Use the interpreter being checked.
  rscript <- file.path(R.home("bin"),
                       if (.Platform$OS.type == "windows") "Rscript.exe" else "Rscript")
  skip_if(!file.exists(rscript), "Rscript is needed for the offline mock")
  mock <- normalizePath(test_path("fixtures", "mock-pi.R"),
                        winslash = "/", mustWork = TRUE)
  # R CMD check sets R_TESTS to a startup script relative to the tests/
  # directory. In a nested Rscript it can execute the wrong file or exit.
  old_r_tests <- Sys.getenv("R_TESTS", unset = NA_character_)
  Sys.setenv(R_TESTS = "")
  on.exit({
    if (is.na(old_r_tests)) Sys.unsetenv("R_TESTS")
    else Sys.setenv(R_TESTS = old_r_tests)
  }, add = TRUE)
  # The testthat working directory can differ from the processx child's wd.
  chat <- pimer:::PiChat$new(executable = unname(rscript),
                            args = c("--vanilla", mock),
                            wd = dirname(mock), echo = FALSE,
                            timeout = 15, prompt_file = NULL)
  # A round-trip ensures the mock has started before the tests use it.
  tryCatch(chat$get_state(), error = function(e) {
    chat$close()
    stop(conditionMessage(e), call. = FALSE)
  })
  chat
}

test_that("Pi RPC chat is stateful, streams deltas, and accounts tokens", {
  chat <- make_mock_chat()
  on.exit(chat$close(), add = TRUE)
  expect_true(chat$is_alive())
  stream <- chat$stream("Hello")
  expect_true(is.function(stream))
  expect_equal(nrow(chat$get_tokens()), 0L) # lazy: no request yet
  first <- stream()
  expect_identical(first, "Reply 1 ")
  expect_error(chat$chat("Concurrent"), "already active")
  expect_error(chat$clear(), "active stream")
  response <- paste0(c(first, unlist(coro::collect(stream))), collapse = "")
  expect_identical(response, "Reply 1 ✓")
  expect_identical(chat$chat("Next"), "Reply 2 ✓")
  expect_equal(nrow(chat$get_tokens()), 2L)
  expect_equal(chat$get_cost(), 0.002)
  expect_equal(chat$get_stats()$cost, 0.002)
  expect_length(chat$get_messages(), 4L)
  chat$clear()
  expect_equal(nrow(chat$get_tokens()), 0L)
  expect_identical(chat$chat("Restart"), "Reply 1 ✓")
  chat$close()
  expect_false(chat$is_alive())
})

test_that("Pi structured response validates schema and converts JSON", {
  chat <- make_mock_chat()
  on.exit(chat$close(), add = TRUE)
  schema <- pi_type_array(pi_type_object(date = pi_type_string(), suspicious = pi_type_boolean()))
  got <- chat$chat_structured("Check stations", data.frame(id = 1:2), type = schema)
  expect_true(is.data.frame(got))
  expect_identical(got$date, "2021-09-01")
  expect_true(got$suspicious[[1]])
})

test_that("schema errors and serialization are handled", {
  type <- pi_type_object(name = pi_type_string(), score = pi_type_number())
  expect_match(pimer:::check_schema(list(name = "A"), type), "missing required")
  expect_null(pimer:::check_schema(list(name = "A", score = 1), type))
  expect_match(pimer:::check_schema(list(name = "A", score = "high"), type), "number")
  expect_match(pimer:::format_pi_input(data.frame(x = 1:2)), '"x"')
  expect_identical(pimer:::strip_json_fence("```json\n{\"a\":1}\n```"), '{"a":1}')
})

test_that("raw RPC can access Pi models and commands", {
  chat <- make_mock_chat()
  on.exit(chat$close(), add = TRUE)
  expect_equal(chat$get_model()$provider, "test")
  expect_equal(chat$get_commands()[[1]]$name, "test")
  expect_equal(chat$bash("pwd")$exitCode, 0)
  expect_error(chat$rpc("unknown"), "unknown command")
})

test_that("JSONL framing handles records larger than the pipe buffer", {
  chat <- make_mock_chat()
  on.exit(chat$close(), add = TRUE)
  result <- chat$chat("LARGE_OUTPUT")
  expect_equal(nchar(result), 30000L)
  expect_identical(substr(result, 1L, 1L), "汉")
})
