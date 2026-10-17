\name{chat_pi}
\alias{chat_pi}
\title{Create an ellmer-style Pi coding-agent chat from R}
\usage{
chat_pi(model = NULL, provider = NULL, system_prompt = NULL,
        tools = NULL, cwd = getwd(), persist = FALSE,
        session = NULL, echo = FALSE, timeout = 180, pi = "pi")
}
\arguments{
\item{model}{Optional Pi model ID or pattern.}
\item{provider}{Provider name when setting model.}
\item{system_prompt}{Extra system instructions, appended at startup.}
\item{tools}{Optional Pi tool allowlist, or \code{character()} to disable tools.}
\item{cwd}{Pi working directory.}
\item{persist}{Whether to persist Pi session history on disk.}
\item{session}{Optional existing Pi session file to resume.}
\item{echo}{Print assistant text as it streams.}
\item{timeout}{RPC deadline in seconds.}
\item{pi}{Executable path or command for Pi.}
}
\description{
Starts a Pi subprocess in JSONL RPC mode and returns an R6 chat object.
}
\value{A PiChat R6 object.}
\details{
The chat object provides \code{$chat(...)}, \code{$stream(...)} (lazy coro iterator),
\code{$chat_structured(...,type=...)}, \code{$clear()},
\code{$get_tokens()}, \code{$get_last_tokens()}, \code{$get_stats()},
\code{$get_cost()}, \code{$get_messages()}, \code{$get_turns()},
\code{$get_model()}, \code{$set_model(provider,model)}, \code{$get_commands()},
\code{$rpc(type,...)}, \code{$interrupt()} and \code{$close()}.
}
