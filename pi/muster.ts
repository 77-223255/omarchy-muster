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

function stateBase() {
	const configured = String(process.env.XDG_STATE_HOME || "");
	// All slashes collapse to one: stripping them would leave "" or "//".
	if (/^\/+$/.test(configured)) return "/";
	if (configured.startsWith("/")) return configured.replace(/\/+$/, "");
	// XDG paths are absolute by definition. A relative one would put the state
	// directory wherever the agent's cwd happens to be, and one starting with
	// "-" would be read as an option by a tool that takes the path. The home
	// fallback is checked the same way, and join() must never see an empty
	// string: join("", ".local", "state") is ".local/state", a *relative* path,
	// which is how this ended up writing a prompt-bearing record under the
	// agent's cwd. With no absolute home the path names a directory that cannot
	// be created, and the write fails instead of landing somewhere unintended.
	const home = homedir();
	return home.startsWith("/") ? join(home, ".local", "state") : "/nonexistent-home/.local/state";
}

function stateDir() {
	return join(stateBase(), "omarchy", "muster", "sessions");
}

// Every component this plugin creates under the state home must be a real
// directory owned by this user. mkdirSync({recursive:true}) and every later
// open follow a symlinked component, so a same-user writer that drops a link at
// …/omarchy/muster would move the whole sessions directory — records included
// — out of the state home. One level is created at a time and re-checked, so an
// existing directory is never reached through a link. The state home itself is
// left alone: a user who symlinks XDG_STATE_HOME into a dotfiles repo did that
// on purpose.
// The leaf directory (dev:inode) captured when the state path was vetted. Every
// write re-checks it, because the vetting happens once at session start while
// the heartbeat keeps writing for as long as the session lives: a directory
// renamed or replaced in between would otherwise receive the prompt without a
// single check noticing.
let stateDirIdentity = "";

function identityOf(path) {
	try {
		const info = lstatSync(path, { bigint: true });
		return `${info.dev}:${info.ino}`;
	} catch {
		return "";
	}
}

function stateDirIsPinned() {
	return stateDirIdentity !== "" && identityOf(stateDir()) === stateDirIdentity;
}

function privateStateDir() {
	// The state home itself is only created when missing, never vetted: a user
	// who symlinks XDG_STATE_HOME into a dotfiles repo did that on purpose.
	const base = stateBase();
	if (!lstatSafe(base)) mkdirSync(base, { recursive: true, mode: 0o700 });
	let current = base;
	const parts = ["omarchy", "muster", "sessions"];
	for (const [index, part] of parts.entries()) {
		current = join(current, part);
		const leaf = index === parts.length - 1;
		let info = lstatSafe(current);
		if (!info) {
			// 0700 from the start: mkdirSync's mode is filtered through the
			// process umask, and the chmod below repairs whatever it took off.
			// The directory can appear between the lstat and the mkdir — another
			// integration starting at the same moment — and that is not an error;
			// only a mkdir failure that leaves nothing behind is.
			try {
				mkdirSync(current, { mode: 0o700 });
			} catch (error) {
				if (error?.code !== "EEXIST") throw error;
			}
			info = lstatSync(current);
		}
		if (info.isSymbolicLink() || !info.isDirectory() || info.uid !== process.getuid()) {
			throw new Error(`muster state path is not a directory owned by this user: ${current}`);
		}
		// Only the leaf holds records, so only the leaf is forced owner-only.
		// `omarchy` is shared with every other omarchy plugin's state: tightening
		// it would change a directory this plugin does not own, and demanding a
		// mode on it would silently stop the bridge wherever that mode cannot be
		// set. The intermediate directories only have to be real, owned and not
		// symlinks, which is what the check above establishes.
		if (!leaf) continue;
		try {
			chmodSync(current, 0o700);
		} catch {
			// Best effort; the check below decides whether the result is usable.
		}
		// A chmod that silently does nothing — a filesystem that does not enforce
		// POSIX modes, such as FAT or some FUSE and network mounts — would leave
		// the prompt readable by every local user. A wrong mode means the record
		// is not written at all, instead of being leaked quietly.
		if ((lstatSync(current).mode & 0o777) !== 0o700) {
			throw new Error(`muster state path is not owner-only: ${current}`);
		}
		stateDirIdentity = identityOf(current);
	}
	return current;
}

function lstatSafe(path) {
	try {
		return lstatSync(path);
	} catch {
		return null;
	}
}

function sanitize(value) {
	return String(value || "")
		.replace(/[^a-zA-Z0-9._-]/g, "_")
		.slice(0, 80);
}

// The 64 KiB the reader accepts, enforced on this side too: the record is a
// fixed small object, and one that the reader would refuse is never written.
const MAX_RECORD_BYTES = 65536;

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
	// Capped like every other field: an uncapped pane id would push the record
	// past the 64 KiB the reader accepts and make the session vanish silently.
	return /^[A-Za-z0-9:_.-]{1,64}$/.test(pane) ? pane : "";
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
	// The directory that was vetted at session start is not necessarily the
	// directory this write would land in; if it is no longer there, skip the
	// write rather than publish a prompt somewhere else.
	if (!stateDirIsPinned()) return;
	// Stage in an exclusive, unpredictable temp file: the `wx` flag is
	// O_CREAT|O_EXCL and refuses an existing path, including a symlink, while
	// the random suffix cannot be predicted and pre-created. The previous
	// `${recordFile}.tmp` was a predictable name opened with the default `w`
	// flag, which follows a symlink and can truncate another file. The rename
	// publishes the record atomically.
	const payload = JSON.stringify(record);
	// Every field is capped, so this is a backstop: a record the reader would
	// refuse is never written in the first place.
	if (new TextEncoder().encode(payload).length > MAX_RECORD_BYTES) return;
	const tmp = `${recordFile}.${randomBytes(8).toString("hex")}.tmp`;
	try {
		writeFileSync(tmp, payload, { mode: 0o600, flag: "wx" });
		try {
			chmodSync(tmp, 0o600);
		} catch {
			// Best effort; the check below decides whether it is publishable.
		}
		// The staged record is verified before it is published: a filesystem that
		// ignores the mode would otherwise put the prompt somewhere other local
		// users can read.
		if ((lstatSync(tmp).mode & 0o777) !== 0o600) {
			throw new Error("muster staging file is not owner-only");
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
		// Capped like every other writer: a record is a fixed small object, and
		// the shell re-reads and re-renders it on every scan.
		name = String(pi?.getSessionName?.() || "").slice(0, 80);
	} catch {
		name = "";
	}

	// Capped like bin/muster-report: the shell re-reads and re-renders this on
	// every scan, and a path longer than this is not a path worth showing.
	const cwd = String(ctx?.cwd || process.cwd() || "").slice(0, 1024);
	recordFile = join(stateDir(), `${AGENT}-${sanitize(sessionId || process.pid)}.json`);
	record = {
		schemaVersion: SCHEMA_VERSION,
		agent: AGENT,
		sessionId: (sessionId || String(process.pid)).slice(0, 120),
		name,
		cwd,
		project: basename(cwd).slice(0, 256),
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
		// Capped like the name in startSession: an uncapped rename would push the
		// record past the reader's 64 KiB limit and make the session vanish from
		// the widget with no diagnostic.
		touch({ name: String(event?.name || "").slice(0, 80) });
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
