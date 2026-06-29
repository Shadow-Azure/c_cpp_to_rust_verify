/**
 * compile-tracker — OpenCode plugin
 *
 * OBSERVABILITY ONLY. This plugin never alters tool output, never changes
 * pass/fail semantics, and never short-circuits a command. It only appends a
 * JSONL trajectory record each time the agent runs `cargo check` / `cargo build`
 * (and `cargo build --release`) during the C→Rust conversion.
 *
 * The trajectory lets us see, run over run:
 *   - the codegen baseline error count
 *   - each Phase 6 AI fix round (errors dropping over time)
 *   - the final error count at conversion end
 *
 * Output file: $COMPILE_TRAJECTORY_FILE (default /tmp/compile-trajectory.jsonl).
 * Set the env var to relocate it (e.g. inside a workspace-relative path).
 *
 * Plugin API follows @opencode-ai/plugin@1.17.11 (installed in
 * .opencode/node_modules). The module must export `server` (PluginModule shape),
 * which returns a Hooks object whose `tool.execute.after` receives:
 *   input : { tool, sessionID, callID, args }
 *   output: { title, output, metadata }   <- `output.output` is the tool's stdout/stderr text
 * For the built-in bash tool, input.args is `{ command: string }`.
 */
import { appendFileSync, mkdirSync, existsSync } from "node:fs";
import { dirname } from "node:path";
import type { Plugin, Hooks } from "@opencode-ai/plugin";

const DEFAULT_TRAJECTORY_FILE = "/tmp/compile-trajectory.jsonl";

function trajectoryFile(): string {
  return process.env.COMPILE_TRAJECTORY_FILE || DEFAULT_TRAJECTORY_FILE;
}

/** Pull the command string out of tool args across known tool shapes. */
function extractCommand(tool: string, args: any): string {
  if (!args || typeof args !== "object") return "";
  // Built-in bash tool (most common path).
  if (typeof args.command === "string") return args.command;
  // Some MCP/shell wrappers nest under `input` or `params`.
  if (args.input && typeof args.input.command === "string") return args.input.command;
  if (args.params && typeof args.params.command === "string") return args.params.command;
  // Fallback: stringified args (still useful for grep on unknown shapes).
  try {
    return JSON.stringify(args);
  } catch {
    return "";
  }
}

/** Pull the captured tool output text out of the output object. */
function extractOutputText(output: any): string {
  if (!output) return "";
  // Authoritative shape for tool.execute.after: { title, output, metadata }.
  if (typeof output.output === "string") return output.output;
  if (output.output && typeof output.output === "object") {
    if (typeof output.output.stdout === "string") return output.output.stdout;
    if (typeof output.output.text === "string") return output.output.text;
  }
  if (typeof output.result === "string") return output.result;
  if (output.result && typeof output.result.stdout === "string") return output.result.stdout;
  if (typeof output.content === "string") return output.content;
  if (typeof output.stdout === "string") return output.stdout;
  try {
    return JSON.stringify(output);
  } catch {
    return "";
  }
}

interface TrajectoryEntry {
  ts: string;
  sessionID: string;
  callID: string;
  tool: string;
  phase: "cargo-check" | "cargo-build";
  cmd: string;
  exit_ok: boolean | null;
  errors: number;
  warnings: number;
  error_codes: string[];
}

function appendEntry(entry: TrajectoryEntry): void {
  const file = trajectoryFile();
  try {
    const dir = dirname(file);
    if (dir && !existsSync(dir)) mkdirSync(dir, { recursive: true });
    appendFileSync(file, JSON.stringify(entry) + "\n", { flag: "a" });
  } catch {
    // Never let logging break the actual conversion. Swallow fs errors.
  }
}

export const server: Plugin = async (_input, _options) => {
  const hooks: Hooks = {
    "tool.execute.after": async (input, output) => {
      const tool: string = input?.tool ?? "";
      // The conversion runs `cargo ...` through the bash tool. Being liberal
      // here (accepting "bash"/"shell"/"task") keeps the plugin robust if the
      // agent ever switches tool wrappers.
      if (!/bash|shell|task|terminal/i.test(tool)) return;

      const cmd = extractCommand(tool, input?.args);
      // Only capture compile-invoking commands. Explicitly exclude `cargo test`
      // (test failures are a separate signal tracked by the eval harness).
      const m = cmd.match(/cargo\s+(check|build)\b/);
      if (!m) return;
      const phase: TrajectoryEntry["phase"] =
        m[1] === "check" ? "cargo-check" : "cargo-build";

      const text = extractOutputText(output);

      // Count errors/warnings. Anchored to line starts so we don't double-count
      // a diagnostic whose path contains the word "error".
      const errorLines = text.match(/^error(\[|:|\s|$)/gm) || [];
      const warningLines = text.match(/^warning:/gm) || [];
      const errorCodes = Array.from(
        new Set(text.match(/error\[E\d+\]/g) || []),
      ).sort();

      // Exit success heuristic: cargo writes "Finished" on success. `output.metadata`
      // may carry an exit code; prefer that when present.
      let exitOk: boolean | null = null;
      const metaExit = output?.metadata?.exitCode ?? output?.metadata?.exit_code;
      if (typeof metaExit === "number") {
        exitOk = metaExit === 0;
      } else if (/^Finished\b/m.test(text)) {
        exitOk = true;
      } else if (errorLines.length > 0) {
        exitOk = false;
      }

      const entry: TrajectoryEntry = {
        ts: new Date().toISOString(),
        sessionID: input?.sessionID ?? "",
        callID: input?.callID ?? "",
        tool,
        phase,
        // Truncate very long commands so one record stays readable.
        cmd: cmd.length > 400 ? cmd.slice(0, 397) + "..." : cmd,
        exit_ok: exitOk,
        errors: errorLines.length,
        warnings: warningLines.length,
        error_codes: errorCodes,
      };
      appendEntry(entry);
    },
  };
  return hooks;
};

export default server;
