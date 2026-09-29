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
import { randomBytes } from "node:crypto";
import { chmodSync, lstatSync, mkdirSync, readFileSync, renameSync, rmSync, writeFileSync } from "node:fs";
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

// A record carries the last user prompt and the working directory, so the
// directory and every record must stay owner-only. mkdirSync's mode only
// applies at creation and is filtered through the process umask; the explicit
// chmods also repair a path an earlier version left at 0755/0644.
function privateStateDir() {
	const dir = stateDir();
	mkdirSync(dir, { recursive: true, mode: 0o700 });
	try {
		chmodSync(dir, 0o700);
	} catch {
		// Best effort: a failed repair must never break the agent loop.
	}
	// A record holds the last prompt, and the directory is written by same-user
	// integrations: it must be a real directory owned by this user, never a
	// symlink a writer could point at another location.
	const info = lstatSync(dir);
	if (!info.isDirectory() || info.isSymbolicLink() || info.uid !== process.getuid()) {
		throw new Error("muster state path is not a directory owned by this user");
	}
	return dir;
}

function sanitize(value) {
	return String(value || "")
		.replace(/[^a-zA-Z0-9._-]/g, "_")
		.slice(0, 80);
}

function truncate(text, limit) {
	const value = String(text || "").replace(/\s+/g, " ").trim();
	if (value.length <= limit) return value;
	let cut = value.slice(0, limit - 1).trimEnd();
	// Never keep half of a surrogate pair; a lone surrogate reaches Qt as a
	// replacement box when the record is parsed.
	if (cut.length > 0) {
		const last = cut.charCodeAt(cut.length - 1);
		if (last >= 0xd800 && last <= 0xdbff) cut = cut.slice(0, -1);
	}
	return cut + "…";
}

// --------------------------------------------------------------- window id
//
// The panel focuses the terminal a session lives in. hyprctl reports the PID
// of the process that owns each window — normally the terminal emulator — so
// walking our own parent chain finds it even when pi runs under a shell or
// omarchy-launch-tui.
//
// A daemon-based multiplexer is the exception: herdr runs every pane under
// `herdr server`, which is parented by systemd, so no ancestor owns a window.
// Those sessions get `herdrPane` instead, and fall back to the focused window
// (the herdr UI the prompt was typed in) for the window address itself.

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

// The pane a herdr-managed agent runs in, read from the environment herdr
// injects into the pane. Empty when pi is not inside herdr. Only a plain
// pane id is accepted, so the value can ride to the shell as data.
function herdrPane() {
	if (String(process.env.HERDR_ENV || "") !== "1") return "";
	const pane = String(process.env.HERDR_PANE_ID || "");
	return /^[A-Za-z0-9:_.-]+$/.test(pane) ? pane : "";
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
		if (matches.length === 0) {
			// Herdr panes have no terminal window in their ancestry. The prompt
			// was submitted from the herdr UI, so the focused window is it.
			return herdrPane() !== "" ? activeWindowAddress() : "";
		}
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

// The last thing the user typed, read back from a resumed session so the card
// is not blank until the next prompt. `getBranch()` returns SessionEntry[];
// user messages carry `message.content` as a string or text blocks.
function messageText(message) {
	const content = message?.content;
	if (typeof content === "string") return content;
	if (Array.isArray(content)) {
		return content
			.filter((part) => part?.type === "text" && typeof part.text === "string")
			.map((part) => part.text)
			.join(" ");
	}
	return "";
}

function lastUserPrompt(ctx) {
	try {
		const branch = ctx?.sessionManager?.getBranch?.() || [];
		for (let i = branch.length - 1; i >= 0; i--) {
			const entry = branch[i];
			if (entry?.type !== "message" || entry.message?.role !== "user") continue;
			const text = messageText(entry.message).trim();
			if (text) return text;
		}
	} catch {
		// No session manager, or no history yet.
	}
	return "";
}

let recordFile = "";
let record = null;
let heartbeat = null;

function writeRecord() {
	if (!recordFile || !record) return;
	// Stage in an exclusive, unpredictable temp file: the `wx` flag is
	// O_CREAT|O_EXCL and refuses an existing path, including a symlink, while
	// the random suffix cannot be predicted and pre-created. The previous
	// `${recordFile}.tmp` was a predictable name opened with the default `w`
	// flag, which follows a symlink and can truncate another file. The rename
	// publishes the record atomically.
	const tmp = `${recordFile}.${randomBytes(8).toString("hex")}.tmp`;
	try {
		writeFileSync(tmp, JSON.stringify(record), { mode: 0o600, flag: "wx" });
		try {
			chmodSync(tmp, 0o600);
		} catch {
			// Best effort; the rename below still publishes the record.
		}
		renameSync(tmp, recordFile);
	} catch {
		// A failed status write must never break the agent loop, and it must not
		// leave a staging file behind.
		try {
			rmSync(tmp, { force: true });
		} catch {
			// Nothing more to do.
		}
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
		privateStateDir();
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
		herdrPane: herdrPane(),
		updatedAt: Date.now(),
		completedRuns: 0,
		lastPrompt: truncate(lastUserPrompt(ctx), 240),
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
			herdrPane: herdrPane(),
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
		setState(ctx?.isIdle?.() === true ? "idle" : "working");
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
