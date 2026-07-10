/**
 * ci-logger — OpenCode plugin for structured CI output
 *
 * Prints concise, structured summaries of tool calls during CI runs.
 * Replaces the noisy --print-logs output with focused information:
 *   - Bash/shell tool calls: command + output preview
 *   - Task (sub-agent) calls: agent name + description
 *
 * Other tool calls (read, write, edit, grep, etc.) are silently skipped
 * to keep CI logs clean and focused on what matters.
 *
 * Plugin API follows @opencode-ai/plugin@1.17.11 (installed in
 * .opencode/node_modules). The module must export `server` (PluginModule shape),
 * which returns a Hooks object whose `tool.execute.after` receives:
 *   input : { tool, sessionID, callID, args }
 *   output: { title, output, metadata }
 * For the built-in bash tool, input.args is `{ command: string }`.
 */
import type { Plugin, Hooks } from "@opencode-ai/plugin";

const MAX_CMD_LEN = 300;
const MAX_OUTPUT_LINES = 50;

function truncate(str: string, max: number): string {
  if (str.length <= max) return str;
  return str.slice(0, max - 3) + "...";
}

function previewOutput(text: string, maxLines: number): string {
  if (!text) return "";
  const lines = text.split("\n");
  if (lines.length <= maxLines) return text;
  return lines.slice(0, maxLines).join("\n") + `\n... (${lines.length - maxLines} more lines)`;
}

export const server: Plugin = async (_input, _options) => {
  const hooks: Hooks = {
    "tool.execute.after": async (input, output) => {
      const tool: string = input?.tool ?? "";

      // --- Bash / Shell tools: show command + output ---
      if (/bash|shell|terminal/i.test(tool)) {
        const cmd = input?.args?.command ?? "";
        const outText =
          typeof output?.output === "string"
            ? output.output
            : output?.output && typeof output.output === "object"
              ? (output.output.stdout ?? output.output.text ?? "")
              : "";

        console.log(`\n🔧 [bash] $ ${truncate(cmd, MAX_CMD_LEN)}`);
        if (outText) {
          console.log(previewOutput(outText, MAX_OUTPUT_LINES));
        }
        return;
      }

      // --- Task tools (sub-agents): show agent info ---
      if (/^task$/i.test(tool)) {
        const args = input?.args ?? {};
        const agentName = args.agent ?? args.name ?? args.agentName ?? "?";
        const description = args.description ?? args.prompt ?? "";
        console.log(
          `\n🤖 [subagent] ${agentName}: ${truncate(description, 200)}`,
        );
        return;
      }

      // All other tools (read, write, edit, grep, glob, etc.) — skip silently
    },
  };
  return hooks;
};

export default server;
