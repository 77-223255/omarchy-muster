// @ts-nocheck
//
// Pi → Muster bridge.
//
// Writes one JSON session record per pi process into
//   $XDG_STATE_HOME/omarchy/muster/sessions/  (default ~/.local/state/...)
// which the `shienze.muster` Omarchy shell plugin watches. The plugin is
// a pure display: it never talks to pi, it only reads records.
//
// The record is the integration contract. Anything that can write this shape
// is a first-class agent to the widget — see bin/muster-report for a
// shell-friendly writer aimed at the other agents omarchy ships.
//
// State mapping:
//   working  → a run is in flight
//   blocked  → pi is waiting on a user-facing prompt
//   idle     → settled; waiting for the next prompt
//
// `completedRuns` is the alert trigger: it increments once per settled run, so
// the watcher does not have to catch a working→idle transition mid-scan.

import { execFileSync } from "node:child_process";
import { mkdirSync, readFileSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { basename, join } from "node:path";

const AGENT = "pi";
const SCHEMA_VERSION = 1;
const HEARTBEAT_MS = 30000;

function stateDir() {
	const base =
		process.env.XDG_STATE_HOME && process.env.XDG_STATE_HOME.length > 0
			? process.env.XDG_STATE_HOME
			: join(homedir(), ".local", "state");
	return join(base, "omarchy", "muster", "sessions");
}

function sanitize(value) {
	return String(value || "")
		.replace(/[^a-zA-Z0-9._-]/g, "_")
		.slice(0, 80);
}

function truncate(text, limit) {
	const value = String(text || "").replace(/\s+/g, " ").trim();
	if (value.length <= limit) return value;
	return value.slice(0, limit - 1).trimEnd() + "…";
}

// --------------------------------------------------------------- window id
//
// The panel focuses the terminal a session lives in. hyprctl reports the PID
// of the process that owns each window — normally the terminal emulator — so
// walking our own parent chain finds it even when pi runs under a shell,
// omarchy-launch-tui, or a multiplexer.

function parentChain(pid) {
	const chain = [];
	let current = Number(pid) || 0;
	for (let i = 0; i < 16 && current > 1; i++) {
		chain.push(current);
		try {
			const stat = readFileSync(`/proc/${current}/stat`, "utf8");
			const close = stat.lastIndexOf(")");
			const fields = stat.slice(close + 2).split(" ");
			current = Number(fields[1]); // state then ppid
		} catch {
			break;
		}
	}
	return chain;
}

function activeWindowAddress() {
	try {
		const raw = execFileSync("hyprctl", ["-j", "activewindow"], {
			timeout: 1500,
			encoding: "utf8",
			stdio: ["ignore", "pipe", "ignore"],
		});
		const win = JSON.parse(raw);
		return String(win?.address || "");
	} catch {
		return "";
	}
}

function resolveWindow() {
	try {
		const raw = execFileSync("hyprctl", ["-j", "clients"], {
			timeout: 1500,
			encoding: "utf8",
			stdio: ["ignore", "pipe", "ignore"],
		});
		const clients = JSON.parse(raw);
		let matches = [];
		for (const pid of parentChain(process.pid)) {
			const found = clients.filter((client) => Number(client.pid) === pid);
			if (found.length > 0) {
				matches = found;
				break;
			}
		}
		if (matches.length === 0) return "";
		if (matches.length === 1) return String(matches[0].address || "");
		// A single-instance terminal (ghostty, kitty) reports one pid for every
		// window, so the parent chain cannot tell them apart. The window the user
		// just typed in is this session's, so prefer the focused one, then the
		// most recently focused.
		const focused = activeWindowAddress();
		const hit = matches.find((client) => String(client.address) === focused);
		if (hit) return String(hit.address || "");
		matches.sort((a, b) => (Number(a.focusHistoryID) || 1e9) - (Number(b.focusHistoryID) || 1e9));
		return String(matches[0].address || "");
	} catch {
		// Not Hyprland, or hyprctl is unavailable. The record still works; the
		// panel just cannot focus a window for it.
	}
	return "";
}

// ------------------------------------------------------------------ writer

let recordFile = "";
let record = null;
let heartbeat = null;

function writeRecord() {
	if (!recordFile || !record) return;
	try {
		const tmp = `${recordFile}.tmp`;
		writeFileSync(tmp, JSON.stringify(record));
		renameSync(tmp, recordFile);
	} catch {
		// A failed status write must never break the agent loop.
	}
}

function touch(extra) {
	if (!record) return;
	record.updatedAt = Date.now();
	record.seq = (record.seq || 0) + 1;
	if (extra) Object.assign(record, extra);
	writeRecord();
}

function startSession(pi, ctx) {
	try {
		mkdirSync(stateDir(), { recursive: true });
	} catch {
		return;
	}

	let sessionId = "";
	try {
		sessionId = String(ctx?.sessionManager?.getSessionId?.() || "");
	} catch {
		// Session manager not ready; fall back to the process id below.
	}

	let name = "";
	try {
		name = String(pi?.getSessionName?.() || "");
	} catch {
		name = "";
	}

	const cwd = String(ctx?.cwd || process.cwd() || "");
	recordFile = join(stateDir(), `${AGENT}-${sanitize(sessionId || process.pid)}.json`);
	record = {
		schemaVersion: SCHEMA_VERSION,
		agent: AGENT,
		sessionId: sessionId || String(process.pid),
		name,
		cwd,
		project: basename(cwd),
		state: ctx?.isIdle?.() === false ? "working" : "idle",
		message: "",
		pid: process.pid,
		windowAddress: resolveWindow(),
		updatedAt: Date.now(),
		completedRuns: 0,
		lastPrompt: "",
		seq: 1,
	};
	writeRecord();

	if (!heartbeat) {
		heartbeat = setInterval(() => touch(), HEARTBEAT_MS);
		heartbeat.unref?.();
	}
}

function stopSession() {
	if (heartbeat) {
		clearInterval(heartbeat);
		heartbeat = null;
	}
	if (recordFile) {
		try {
			rmSync(recordFile, { force: true });
		} catch {
			// Nothing to clean up.
		}
	}
	recordFile = "";
	record = null;
}

// ------------------------------------------------------------------- hooks

export default function (pi) {
	let rootSession = false;
	let runActive = false;
	let uiPrompts = 0;

	function enabled(ctx) {
		return rootSession && ctx?.mode === "tui";
	}

	function setState(state, extra) {
		if (!record) return;
		touch({ state, message: "", ...extra });
	}

	pi.on("session_start", async (_event, ctx) => {
		// TUI only: print/JSON runs have no terminal for the panel to focus,
		// and RPC reports a UI while still being headless.
		if (ctx?.mode !== "tui") return;
		rootSession = true;
		runActive = false;
		uiPrompts = 0;
		startSession(pi, ctx);
	});

	pi.on("session_shutdown", async () => {
		if (!rootSession) return;
		stopSession();
		rootSession = false;
	});

	pi.on("session_info_changed", async (event) => {
		if (!rootSession || !record) return;
		touch({ name: String(event?.name || "") });
	});

	pi.on("before_agent_start", async (event, ctx) => {
		if (!enabled(ctx)) return;
		runActive = true;
		// The user just submitted this prompt, so the focused window is this
		// session's terminal. Re-resolving here pins a single-instance
		// terminal's per-window address that the chain alone cannot pick.
		setState("working", {
			lastPrompt: truncate(event?.prompt, 240),
			windowAddress: resolveWindow(),
		});
	});

	pi.on("agent_start", async (_event, ctx) => {
		if (!enabled(ctx)) return;
		if (runActive) return;
		runActive = true;
		setState("working");
	});

	// Blocking UI prompts are the "needs you" state. Coalesced the same way
	// the shell treats nested prompts.
	pi.on("ui_prompt_start", async (event, ctx) => {
		if (!enabled(ctx)) return;
		uiPrompts += 1;
		touch({
			state: "blocked",
			message: truncate(event?.title || event?.kind || "waiting for input", 120),
		});
	});

	pi.on("ui_prompt_end", async (_event, ctx) => {
		if (!enabled(ctx)) return;
		uiPrompts = Math.max(0, uiPrompts - 1);
		if (uiPrompts > 0) return;
		try {
			setState(ctx?.isIdle?.() === true ? "idle" : "working");
		} catch {
			setState("working");
		}
	});

	// agent_settled is the only "pi will not continue on its own" signal:
	// agent_end can still be followed by a retry, compaction, or a queued
	// follow-up. completedRuns is what makes the watcher alert exactly once.
	pi.on("agent_settled", async (_event, ctx) => {
		if (!enabled(ctx)) return;
		if (ctx?.isIdle?.() !== true) return;
		runActive = false;
		uiPrompts = 0;
		touch({
			state: "idle",
			message: "",
			completedRuns: (record?.completedRuns || 0) + 1,
		});
	});
}
