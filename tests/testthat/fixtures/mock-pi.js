// Deterministic Pi RPC test double. No model credentials or Pi installation needed.
"use strict";
const readline = require("node:readline");
let messages = [];
let count = 0;

function send(value) {
  process.stdout.write(JSON.stringify(value) + "\n");
}

function reply(id, command, data = {}, success = true, error = null) {
  send({ id, type: "response", command, success, data, error });
}

const lines = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
lines.on("line", (line) => {
  if (!line.trim()) return;
  try {
    const cmd = JSON.parse(line);
    const type = cmd.type;
    const id = cmd.id;
    if (type === "prompt") {
      reply(id, type, { disposition: "started" });
      count += 1;
      const structured = cmd.message.includes("Return only valid JSON");
      const large = cmd.message.includes("LARGE_OUTPUT");
      const answer = structured ? '[{"date":"2021-09-01","suspicious":true}]'
        : large ? "汉".repeat(30000) : `Reply ${count} ✓`;
      const pieces = (structured || large) ? [answer] : [`Reply ${count} `, "✓"];
      for (const delta of pieces) {
        send({ type: "message_update", assistantMessageEvent: { type: "text_delta", delta } });
      }
      messages.push({ role: "user", content: cmd.message });
      const response = {
        role: "assistant",
        content: [{ type: "text", text: answer }],
        stopReason: "stop",
        usage: {
          input: 20, output: 10, cacheRead: 5, cacheWrite: 0,
          cost: { total: 0.001 }
        }
      };
      messages.push(response);
      send({ type: "message_end", message: response });
      send({ type: "agent_end", messages: [response] });
      send({ type: "agent_settled", aborted: false });
    } else if (type === "get_state") {
      reply(id, type, { model: { provider: "test", id: "mock" }, messageCount: messages.length });
    } else if (type === "get_session_stats") {
      reply(id, type, {
        tokens: { input: count * 20, output: count * 10, cacheRead: count * 5, total: count * 35 },
        cost: count * 0.001
      });
    } else if (type === "get_messages") {
      reply(id, type, { messages });
    } else if (type === "new_session") {
      messages = [];
      count = 0;
      reply(id, type, { cancelled: false });
    } else if (type === "set_model" || type === "set_thinking_level") {
      reply(id, type);
    } else if (type === "get_commands") {
      reply(id, type, { commands: [{ name: "test" }] });
    } else if (type === "get_available_models") {
      reply(id, type, { models: [{ provider: "test", id: "mock" }] });
    } else if (type === "bash") {
      reply(id, type, { output: "mock shell output", exitCode: 0 });
    } else {
      reply(id, type, {}, false, "unknown command");
    }
  } catch (error) {
    process.stderr.write(String(error.stack || error) + "\n");
    process.exitCode = 1;
    lines.close();
  }
});
