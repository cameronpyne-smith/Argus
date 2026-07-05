#!/usr/bin/env bash
# argus-test — autonomous QA run driven by a per-site coverage ledger.
#
# The ledger (qa-notes/<site>/) holds STATE, not history:
#   index.md     one line per area+persona: area | start-url | persona | last-tested
#                — maintained by THIS script, never by the agent
#   <area>.md    current facts/coverage for one area (~50 lines, model-maintained)
# History lives in /opt/data/reports/. The agent only ever sees the index's
# chosen slice: its one area file, copied into /opt/data/run/.
#
# Model + provider: both default to the local qwen variant
# (--provider local -m qwen3.6-argus128k) and are independently overridable:
#   --model  <name>       inference model      (default qwen3.6-argus128k)
#   --provider <name>     inference provider   (default local; built-in or a
#                         name from providers: in config.yaml — 'auto' picks the
#                         config default, e.g. cloud gpt-4.1)
#   --local               back-compat alias — re-asserts the local defaults (no-op)
# On a cloud/OpenAI box with no Ollama: --provider auto -m gpt-4.1 (see below).
#
# Usage:
#   argus-test                      # pick the area most in need (never > oldest)
#   argus-test expenses             # focus a specific area (local qwen by default)
#   argus-test --focus expenses --persona default --issues
#   argus-test --discover           # map the site: fill the index, no testing
#   argus-test expenses --watch     # headed: watch it live in a browser window
#                                          (Option 1: shares host X; run `xhost +local:` first)
#   argus-test expenses --provider auto --model gpt-4.1  # run against a cloud model
#   argus-test expenses --prompt "test price fields for invalid chars + limits"
#                                          # broad testing, but prioritise this instruction
#   argus-test expenses --only   "test price fields for invalid chars + limits"
#                                          # test ONLY this (ledger-neutral; no area.md/stamp update)
#   (--prompt and --only are mutually exclusive and stay loaded in context all run.)
#   argus-test dashboard --viewport mobile
#                                          # responsive pass at a mobile-size viewport
#                                          # (mobile=390x844, tablet=820x1180, or custom WxH;
#                                          #  ledger-neutral — desktop notes/stamp untouched)
#   argus-test expenses --no-verify         # skip the independent verification pass
#   argus-test expenses --verify-model gpt-4.1 --verify-provider auto
#                                          # re-check recorded bugs with a stronger judge model
#
# Prerequisite for local runs (host-side, one-time): Ollama's /v1 endpoint ignores
# per-request num_ctx, so the local default uses a model variant with the context window
# baked into its Modelfile. Create them once (they share blobs with the base):
#   printf 'FROM qwen3.6:35b\nPARAMETER num_ctx 131072\n' | tee /tmp/mf >/dev/null && ollama create qwen3.6-argus128k -f /tmp/mf
#   printf 'FROM qwen3.6:35b\nPARAMETER num_ctx 65536\n'  | tee /tmp/mf >/dev/null && ollama create qwen3.6-argus64k  -f /tmp/mf
# If host Ollama models are reset, recreate these or runs fall back to 32K.
# Keep the variant's num_ctx coherent with ARGUS_NUM_CTX (entrypoint sets
# context_length to match the variant, else Hermes over-fills and Ollama truncates).
#
# Vision aux is configured independently via three settings (put them in the
# settings file ~/.argus/.env, which the entrypoint loads on every start):
#   ARGUS_VISION_MODEL / ARGUS_VISION_BASE_URL / ARGUS_VISION_API_KEY
# (ARGUS_NUM_CTX and ARGUS_LOCAL_MODEL live there too.)
# Default = the local model on local Ollama (shares the resident model, no swap).
# On a cloud/OpenAI box with no Ollama: run with --provider auto -m gpt-4.1 (main
# -> gpt-4.1 via the config default) and set the three vision env vars, e.g.
#   ARGUS_VISION_MODEL=gpt-4.1  ARGUS_VISION_BASE_URL=https://api.openai.com/v1  ARGUS_VISION_API_KEY=sk-...
# (gpt-4.1/4o are multimodal, so vision is real). Also ensure the OpenAI key is in
# config.yaml's OpenAI provider, since that's not committed.
#
set -euo pipefail

SITE="remundo"
SITE_HOST="dev.xml.remundo.com"
SITE_DIR="/opt/data/qa-notes/${SITE}"
INDEX="$SITE_DIR/index.md"
RUN_DIR="/opt/data/run"

FOCUS=""
# Per-run guidance (--prompt / --only). GUIDE_TEXT is the user instruction;
# GUIDE_MODE is "" (none), "prompt" (broad testing + prioritise it), or "only"
# (test ONLY the instruction, ledger-neutral). The two are mutually exclusive.
GUIDE_TEXT=""
GUIDE_MODE=""
# Non-default viewport (--viewport). Empty = desktop default (1280x1080 set by
# browser_tool). When set, the run is a responsive-layout pass and is
# ledger-neutral: area.md is written from the desktop perspective, and letting a
# 390px run rewrite it ("nav is hidden behind a hamburger") would poison the
# facts every desktop run relies on.
VIEWPORT=""
VIEWPORT_W=""
VIEWPORT_H=""
PERSONA="candidate"
# Session length (150 turns). Sessions used to be kept short because the context
# compressor could no-op on long agentic sessions and pin them at the old 32K
# ceiling; every babysitter continuation restarts with freshly compressed context
# (~10-20K). With the 128K local variant that ceiling is far higher, so a longer
# session has real headroom — and the stateful bug classes (create→edit→delete,
# interrupted wizards, double-submit) need several uninterrupted turns to set up,
# which a too-short session cuts off mid-sequence. Override with --max-turns.
MAX_TURNS=150
# Model + provider both default to the local qwen variant and are independently
# overridable (--model / --provider). qwen3.6-argus128k = qwen3.6:35b with
# PARAMETER num_ctx 131072 baked in — Ollama's /v1 (OpenAI-compat) endpoint
# IGNORES per-request num_ctx, so a baked variant is the ONLY way to run >32768.
# Keep the model in sync with context_length (entrypoint ARGUS_NUM_CTX) and the
# vision model (entrypoint ARGUS_LOCAL_MODEL). PROVIDER_FLAGS is assembled from
# these after arg parsing. For a cloud box: --provider auto -m gpt-4.1.
PROVIDER="local"
MODEL="qwen3.6-argus128k"
# Hard wall-clock cap per agent session — the backstop for a hung model call
# (a qwen stream once stalled mid-response and never returned). timeout sends
# SIGTERM (not SIGINT: SIGINT triggers Hermes' graceful shutdown which itself
# blocked on the stuck request; SIGTERM's default action terminates), then
# SIGKILL after --kill-after as the hard guarantee. The post-run salvage still
# assembles/files whatever bugs were recorded. Override with SESSION_TIMEOUT.
SESSION_TIMEOUT="${SESSION_TIMEOUT:-2400}"
DISCOVER=false
RECORD=false
# Issue filing default comes from ARGUS_FILE_ISSUES in /opt/data/.env;
# --issues / --no-issues override per run. Report is always written.
FILE_ISSUES="$(grep -E '^ARGUS_FILE_ISSUES=' /opt/data/.env 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '[:space:]' || true)"
FILE_ISSUES="${FILE_ISSUES:-false}"

# Independent verification pass (default ON for QA runs). The exploration
# session files a bug the moment it sees odd behaviour, and a small model
# readily talks itself into false criticals — a disabled Vaadin button it reads
# as "frozen", a light-DOM querySelectorAll it reads as a "DOM crash", escaped
# HTML it reads as stored XSS. Its own "verify a bug is real" step is
# self-verification inside the same reasoning that produced the bug, so it does
# not catch these. After exploration, a FRESH skeptical session re-reproduces
# each recorded bug from scratch (default verdict = reject) and returns keep /
# downgrade / reject. Disable with --no-verify or ARGUS_VERIFY=false.
VERIFY="$(grep -E '^ARGUS_VERIFY=' /opt/data/.env 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '[:space:]' || true)"
VERIFY="${VERIFY:-true}"
# The verify pass can run on a different (stronger) model than exploration —
# candidates are few, so a better judge here is cheap. Defaults to the run's
# model/provider; override with --verify-model / --verify-provider.
VERIFY_MODEL=""
VERIFY_PROVIDER=""
VERIFY_SESSION_TIMEOUT="${VERIFY_SESSION_TIMEOUT:-1200}"
VERIFY_MAX_TURNS="${VERIFY_MAX_TURNS:-60}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --local)
      # Back-compat alias: the local qwen variant is now the default, so this
      # just re-asserts it. Prefer --provider/--model directly.
      PROVIDER="local"; MODEL="qwen3.6-argus128k"; shift ;;
    --model|-m)
      # Inference model, e.g. --model qwen3.6:35b or (with --provider auto) gpt-4.1
      MODEL="$2"; shift 2 ;;
    --provider)
      # Inference provider: built-in or a name from providers: in config.yaml.
      # 'auto' resolves to the config default (cloud gpt-4.1 on a no-Ollama box).
      PROVIDER="$2"; shift 2 ;;
    --max-turns)
      MAX_TURNS="$2"; shift 2 ;;
    --focus)
      FOCUS="$2"; shift 2 ;;
    --persona)
      PERSONA="$2"; shift 2 ;;
    --discover)
      DISCOVER=true; shift ;;
    --record)
      RECORD=true; shift ;;
    --watch)
      # Headed/watch mode: render the browser to the shared host X display so
      # you can watch it click and type live. Per-run; needs `xhost +local:` on
      # the host. (ARGUS_HEADED=1 in ~/.argus/.env makes it always-on instead.)
      export ARGUS_HEADED=true; shift ;;
    --prompt)
      # Extra guidance for this run: broad testing PLUS prioritise this.
      if [[ -n "$GUIDE_MODE" ]]; then echo "✗ --prompt and --only are mutually exclusive — pass only one."; exit 1; fi
      GUIDE_TEXT="$2"; GUIDE_MODE="prompt"; shift 2 ;;
    --only)
      # Focus this run EXCLUSIVELY on this instruction (skip the broad sweep).
      if [[ -n "$GUIDE_MODE" ]]; then echo "✗ --prompt and --only are mutually exclusive — pass only one."; exit 1; fi
      GUIDE_TEXT="$2"; GUIDE_MODE="only"; shift 2 ;;
    --viewport)
      # Responsive-layout pass at a non-desktop viewport. Exports
      # ARGUS_BROWSER_VIEWPORT_W/H, which browser_tool re-applies on every
      # navigate (same mechanism as the desktop 1280x1080 default). CSS size
      # only — no touch events or mobile user-agent — but CSS width is what
      # responsive breakpoints key off, so it surfaces the layout bug class.
      case "$2" in
        mobile) VIEWPORT_W=390; VIEWPORT_H=844 ;;
        tablet) VIEWPORT_W=820; VIEWPORT_H=1180 ;;
        *)
          if [[ "$2" =~ ^[0-9]+x[0-9]+$ ]]; then
            VIEWPORT_W="${2%x*}"; VIEWPORT_H="${2#*x}"
          else
            echo "✗ --viewport takes 'mobile' (390x844), 'tablet' (820x1180) or a custom WxH (e.g. 414x896)."
            exit 1
          fi ;;
      esac
      VIEWPORT="$2"
      export ARGUS_BROWSER_VIEWPORT_W="$VIEWPORT_W" ARGUS_BROWSER_VIEWPORT_H="$VIEWPORT_H"
      shift 2 ;;
    --issues)
      FILE_ISSUES=true; shift ;;
    --no-issues)
      FILE_ISSUES=false; shift ;;
    --verify)
      VERIFY=true; shift ;;
    --no-verify)
      VERIFY=false; shift ;;
    --verify-model)
      VERIFY_MODEL="$2"; shift 2 ;;
    --verify-provider)
      VERIFY_PROVIDER="$2"; shift 2 ;;
    -*)
      echo "Unknown flag: $1"; exit 1 ;;
    *)
      FOCUS="$1"; shift ;;
  esac
done

# Assemble the provider flags forwarded to every `argus chat` (and the filer).
PROVIDER_FLAGS="--provider $PROVIDER -m $MODEL"

# The verification pass defaults to the run's model/provider unless overridden
# (--verify-model / --verify-provider), so a stronger judge can re-check bugs
# while exploration stays on the fast local model.
VERIFY_MODEL="${VERIFY_MODEL:-$MODEL}"
VERIFY_PROVIDER="${VERIFY_PROVIDER:-$PROVIDER}"
VERIFY_FLAGS="--provider $VERIFY_PROVIDER -m $VERIFY_MODEL"

# Guidance (--prompt/--only) steers a QA run; it has no meaning for discovery.
if [[ -n "$GUIDE_MODE" && "${DISCOVER:-false}" == "true" ]]; then
  echo "✗ --prompt/--only steer a QA run and can't be combined with --discover."
  exit 1
fi
# Discovery maps the site's navigation; at a mobile viewport most of that nav
# is collapsed/hidden, so a mobile discovery would under-fill the index.
if [[ -n "$VIEWPORT" && "${DISCOVER:-false}" == "true" ]]; then
  echo "✗ --viewport is a QA-run responsive pass and can't be combined with --discover."
  exit 1
fi

# Build the guidance text once. It is injected into BOTH the goal (lands in the
# protected first messages) and every continuation nudge (protected tail), so it
# stays in the model's context across compression and babysitter continuations.
GUIDE_BLOCK=""        # inserted into the goal prompt
GUIDE_NUDGE_LINE=""   # appended to each continuation nudge
if [[ "$GUIDE_MODE" == "prompt" ]]; then
  GUIDE_BLOCK="
PRIORITY FOR THIS RUN — the user specifically asked you to focus on the following. Do it FIRST and most thoroughly, then continue with normal testing of the area. Keep it in mind the whole run:
>>> ${GUIDE_TEXT} <<<
"
  GUIDE_NUDGE_LINE=" Also keep prioritising the user's focus for this run: ${GUIDE_TEXT}"
elif [[ "$GUIDE_MODE" == "only" ]]; then
  GUIDE_BLOCK="
THIS RUN IS NARROWLY SCOPED. Test ONLY the following on this area, exhaustively — do NOT do a broad sweep of unrelated functionality, and ignore any instruction below to 'prioritise what area.md says is not covered':
>>> ${GUIDE_TEXT} <<<
If you trip over a genuine bug outside this scope (e.g. the page errors or crashes), still record it — but do not go looking for anything beyond the instruction above.
"
  GUIDE_NUDGE_LINE=" Remember: this run tests ONLY '${GUIDE_TEXT}' — keep exhausting that, do not broaden out."
fi

# Viewport awareness: like GUIDE_BLOCK, injected into BOTH the goal (protected
# first messages) and every nudge (protected tail) — a model that forgets it is
# on a 390px screen files "the navigation is missing" as a bug.
VIEWPORT_BLOCK=""
VIEWPORT_NUDGE_LINE=""
VIEWPORT_LABEL=""
if [[ -n "$VIEWPORT" ]]; then
  if [[ "$VIEWPORT" == "${VIEWPORT_W}x${VIEWPORT_H}" ]]; then
    VIEWPORT_LABEL="$VIEWPORT"
  else
    VIEWPORT_LABEL="${VIEWPORT} ${VIEWPORT_W}x${VIEWPORT_H}"
  fi
  VIEWPORT_BLOCK="
THIS RUN USES A SMALL ${VIEWPORT_LABEL} VIEWPORT — it is a responsive-layout pass. Judge every page as a real user on a screen this size would:
- Responsive bugs ARE in scope: content clipped or overflowing horizontally, elements overlapping, controls that cannot be reached or clicked at this size, text or buttons rendered off-screen, layouts that visibly break.
- Normal small-screen behaviour is NOT a bug: navigation collapsed behind a hamburger/menu button (open it to navigate), columns stacking vertically, needing to scroll. Never file 'the navigation/sidebar is missing' — open the menu button instead.
- Functionality must still WORK at this size: test forms, edits and submissions as usual, and file it if something only fails at this viewport.
- In every bug you record, note that it occurred at the ${VIEWPORT_LABEL} viewport if the bug looks layout- or size-related.
"
  VIEWPORT_NUDGE_LINE=" Remember: this run is at a small ${VIEWPORT_LABEL} viewport — responsive/layout issues are in scope; hamburger navigation and vertical scrolling are normal, not bugs."
fi

source /opt/hermes/.venv/bin/activate

if [[ "$PROVIDER" == "local" ]]; then
  echo "▶ Checking Ollama connectivity ($MODEL)..."
  if ! curl -sf --max-time 3 http://localhost:11434/api/tags > /dev/null 2>&1; then
    echo "✗ Ollama is not reachable. Start it with: OLLAMA_HOST=0.0.0.0 ollama serve &"
    exit 1
  fi
  echo "  ✓ Ollama is up"
fi

# ── Browser recording (opt-in --record) ───────────────────────────────────
# browser_tool reads browser.record_sessions from config.yaml, so enable it
# there for the duration of this run. NB: each browser session (the main run
# AND every babysitter --continue) records to its OWN .webm — a run yields a
# folder of per-session clips, not one continuous video. Reset on EXIT (even
# on kill) so normal runs stay un-recorded.
RECORDINGS_DIR="/opt/data/browser_recordings"
CONFIG_YAML="/opt/data/config.yaml"
if [[ "$RECORD" == "true" ]]; then
  if grep -qE '^\s*record_sessions:' "$CONFIG_YAML"; then
    sed -i 's/^\(\s*record_sessions:\s*\).*/\1true/' "$CONFIG_YAML"
  else
    sed -i 's/^\(browser:\s*\)$/\1\n  record_sessions: true/' "$CONFIG_YAML"
  fi
  trap 'sed -i "s/^\(\s*record_sessions:\s*\).*/\1false/" "$CONFIG_YAML" 2>/dev/null || true' EXIT
  echo "▶ Recording ENABLED — per-session .webm clips will land in ${RECORDINGS_DIR}"
fi

mkdir -p "$SITE_DIR" /opt/data/reports/screenshots /opt/data/reports/parts
if [[ ! -f "$INDEX" ]]; then
  {
    echo "# ${SITE} coverage index — maintained by argus-test. Agents must not edit this file."
    echo "# Format: area | start-url | persona | last-tested   (last-tested: YYYY-MM-DD or 'never')"
    echo "dashboard | https://${SITE_HOST}/dashboard | default | never"
  } > "$INDEX"
fi

# ── Area selection ─────────────────────────────────────────────────────────
# Deterministic, harness-side: never-tested areas first, then the stalest.
# The model is never asked to choose.
index_lookup_url() {  # $1 area
  awk -F'|' -v a="$1" -v p="$PERSONA" '
    /^#/ {next}
    { gsub(/^[ \t]+|[ \t]+$/, "", $1); gsub(/^[ \t]+|[ \t]+$/, "", $2); gsub(/^[ \t]+|[ \t]+$/, "", $3) }
    $1==a && $3==p { print $2; exit }' "$INDEX"
}

if [[ "$DISCOVER" == "true" ]]; then
  AREA="discovery"
elif [[ -n "$FOCUS" ]]; then
  AREA="$FOCUS"
else
  AREA="$(awk -F'|' -v p="$PERSONA" '
    /^#/ {next}
    NF>=4 {
      for (i=1;i<=4;i++) gsub(/^[ \t]+|[ \t]+$/, "", $i)
      if ($3!=p) next
      if ($4=="never" && first=="") first=$1
      if ($4!="never" && (bestd=="" || $4<bestd)) { best=$1; bestd=$4 }
    }
    END { if (first!="") print first; else print best }' "$INDEX")"
  if [[ -z "$AREA" ]]; then
    echo "✗ No areas in the index for persona '$PERSONA' — add one or use --focus."
    exit 1
  fi
fi

AREA_URL=""
NAV_LINE=""
if [[ "$DISCOVER" != "true" ]]; then
  AREA_URL="$(index_lookup_url "$AREA")"
  if [[ -n "$AREA_URL" ]]; then
    NAV_LINE="Navigate to ${AREA_URL}"
  else
    NAV_LINE="Find the '${AREA}' area starting from https://${SITE_HOST}/dashboard"
  fi
fi

STAMP="$(date +%Y%m%d-%H%M)"
REPORT_FILE="/opt/data/reports/${AREA}-${STAMP}.md"
ARCHIVE_DIR="/opt/data/reports/parts/${AREA}-${STAMP}"

# Login is a GENERIC form-login procedure (in the web-qa-workflow skill), not a
# site-specific script: drive whatever sign-in page the site has with the normal
# browser_type/browser_click tools. Only the DATA is site-specific — the login
# URL and the persona's credentials — and that lives in site-config. We parse the
# persona's credentials out of site-config and inline them as data into the
# protected first message so context compression can never strip them; the
# procedure itself the model follows from the skill. (We used to inline a raw-JS
# dispatchEvent snippet here — models under context pressure regenerated it from
# memory and broke it, which is what wedged runs on /login. Native tools log in
# reliably as long as the model snapshots before acting and verifies the value.)
SITE_CONFIG="/opt/data/skills/site-config/SKILL.md"
LOGIN_EMAIL="$(awk -v p="$PERSONA" '
  tolower($0) ~ ("^### persona: " tolower(p) "$") {f=1; next}
  /^### / {f=0}
  f && /^- *Email:/ {sub(/^- *Email:[ \t]*/,""); gsub(/[ \t]+$/,""); print; exit}' "$SITE_CONFIG" 2>/dev/null || true)"
LOGIN_PW="$(awk -v p="$PERSONA" '
  tolower($0) ~ ("^### persona: " tolower(p) "$") {f=1; next}
  /^### / {f=0}
  f && /^- *Password:/ {sub(/^- *Password:[ \t]*/,""); gsub(/[ \t]+$/,""); print; exit}' "$SITE_CONFIG" 2>/dev/null || true)"
if [[ -n "$LOGIN_EMAIL" && -n "$LOGIN_PW" ]]; then
  CRED_LINE="Use ONLY these credentials (never invent or substitute any): email '${LOGIN_EMAIL}', password '${LOGIN_PW}'."
else
  CRED_LINE="Use ONLY the persona '${PERSONA}' credentials from the site-config skill — never invent or substitute any."
fi
LOGIN_STEP="Log in to https://${SITE_HOST} as persona '${PERSONA}' before testing, following the 'Logging in' procedure in the web-qa-workflow skill. ${CRED_LINE} In short: open the site's login page, browser_snapshot it, browser_type the email and password into their fields, read each value back to confirm it stuck (if a field is empty your ref went stale — re-snapshot and type again), browser_click the submit button, then confirm the URL has left the login page. If you land on a setup/MFA/consent interstitial that is not the app itself, click its skip / later / dismiss control. These credentials are valid, so a 'sign-in failed' message means the value did not register (stale ref) — re-snapshot and retype; never try other credentials or other login methods, and never file the login flow as a bug."

# ── Run dir: ALL agent file IO happens in /opt/data/run — one short path the
# model can reliably retain under context compression.
rm -rf "$RUN_DIR"
mkdir -p "$RUN_DIR"
if [[ "$DISCOVER" == "true" ]]; then
  # Discovery gets the index (read-only copy) so its job is "find what is
  # missing from this list" — the one mode where the model sees the index.
  grep -v '^#' "$INDEX" | awk -F'|' -v p="$PERSONA" '
    { gsub(/^[ \t]+|[ \t]+$/, "", $1); gsub(/^[ \t]+|[ \t]+$/, "", $2); gsub(/^[ \t]+|[ \t]+$/, "", $3) }
    $3==p { print $1 " | " $2 }' > "$RUN_DIR/known-areas.md"
elif [[ -f "$SITE_DIR/$AREA.md" ]]; then
  cp "$SITE_DIR/$AREA.md" "$RUN_DIR/area.md"
else
  printf '# %s\n\nNo notes on this area yet — first visit. Explore and record what you find.\n' "$AREA" > "$RUN_DIR/area.md"
fi

# ── Known-issues frontier feed ─────────────────────────────────────────────
# Per-area, harness-owned list of bugs ALREADY found+verified+filed (populated
# after each run's verification pass, below). Injected into the goal + nudges so
# the run recognises what is already tracked and spends its effort on NEW ground
# instead of re-finding and re-filing the same defects every run — the exact
# convergence + duplicate-filing trap. Populated ONLY from confirmed/kept bugs
# (never the model's free-text area notes, which can carry rejected false
# positives), so it stays high-precision. Not injected for --only runs: they are
# narrowly scoped and must not be steered toward broad new-ground exploration.
KNOWN_BLOCK=""
KNOWN_NUDGE_LINE=""
if [[ "$DISCOVER" != "true" && "$GUIDE_MODE" != "only" && -s "$SITE_DIR/$AREA.known.md" ]]; then
  cp "$SITE_DIR/$AREA.known.md" "$RUN_DIR/known-issues.md"
  KNOWN_BLOCK="
ALREADY-FILED BUGS FOR THIS AREA — read /opt/data/run/known-issues.md early with read_file. Every line is a bug that was already found, independently verified, and filed on a previous run. Do NOT re-report, re-record, or re-verify any of them — they are already tracked. If you stumble back onto one, that is expected: note it in one line and move on. Your value THIS run is NEW ground — steer your testing and your own hypotheses toward angles these known bugs did NOT cover (untested features, different state, different sequences). Re-confirming an already-filed bug adds nothing; finding a genuinely new one is the whole point.
"
  KNOWN_NUDGE_LINE=" Remember: /opt/data/run/known-issues.md lists bugs ALREADY filed for this area — do not re-record those; put your remaining effort into NEW, untested surface."
fi

if [[ "$DISCOVER" == "true" ]]; then
  echo "▶ Discovery run: site=${SITE} persona=${PERSONA} (max turns: ${MAX_TURNS})"
else
  echo "▶ QA run: site=${SITE} area=${AREA} persona=${PERSONA} (max turns: ${MAX_TURNS})"
fi
if [[ "$GUIDE_MODE" == "prompt" ]]; then
  echo "▶ Guided (prioritise): ${GUIDE_TEXT}"
elif [[ "$GUIDE_MODE" == "only" ]]; then
  echo "▶ Guided (ONLY, ledger-neutral): ${GUIDE_TEXT}"
fi
if [[ -n "$VIEWPORT" ]]; then
  echo "▶ Viewport: ${VIEWPORT_LABEL} (responsive pass, ledger-neutral)"
fi
echo ""

# Toolsets are restricted to what a QA run needs: every extra toolset adds
# tool schemas to the fixed prompt prefix, which costs context and slows
# every single model call.
if [[ "$DISCOVER" == "true" ]]; then
  NUDGE_PROMPT="You stopped before finishing. Do not ask the user anything — you are autonomous. Continue mapping the site per your original instructions: walk every navigation surface, append one '<area-name> | <exact URL>' line per newly found area to /opt/data/run/new-areas.md, and when you have covered all navigation write /opt/data/run/summary.md listing what you mapped."
  # shellcheck disable=SC2086
  timeout --signal=TERM --kill-after=30 "$SESSION_TIMEOUT" \
    argus chat --max-turns "$MAX_TURNS" \
    -t browser,skills_ro,file,terminal \
    -q "You are mapping the ${SITE} web app so it can be QA-tested area by area later. You are logged in as persona '${PERSONA}'. Your job this run is DISCOVERY ONLY — find pages, do not test them.

Before you start:
- Load these skills with skill_view: 'site-config', 'web-qa-workflow'
- Read /opt/data/run/known-areas.md with read_file — the areas already known. You are looking for what is MISSING from that list.

Rules:
- READ-ONLY exploration: navigate and look, but never submit forms, never enter data, never change settings. Clicking navigation links, menus and tabs is fine.
- The ONLY valid site domain is https://${SITE_HOST} — if you remember any other domain, it is wrong.
- Do not ask for direction. Never end your turn by announcing what you will do next — your final message comes only after /opt/data/run/summary.md is written.
- Areas are KINDS of pages, not individual records: a list page that opens detail pages is two areas — the list, and the detail page recorded once with one example URL. Never record one entry per record/row/uuid.

Process:
1. ${LOGIN_STEP}
2. Start at https://${SITE_HOST}/dashboard and systematically work through EVERY navigation surface: side nav entries, top bar menus, user/profile menus, settings, tabs inside pages, footer links
3. For every kind of page you reach that is not in known-areas.md, append one line to /opt/data/run/new-areas.md by running this in the terminal (append with >>, NEVER write_file — rewriting loses earlier entries):
   echo '<short-kebab-area-name> | <exact URL from the browser>' >> /opt/data/run/new-areas.md
4. If a page is visibly broken when you open it (error screen, blank page, crash), record it as a bug to /opt/data/run/bug-<short-slug>.md (distinct kebab-case slug per bug) (title, exact URL, steps, expected, actual, severity, plus a screenshot via browser_vision and cp to /opt/data/reports/screenshots/<name>.png) — but do not go looking for bugs

When you have walked all navigation — or are running low on turns:
- Write /opt/data/run/summary.md with write_file: which navigation surfaces you covered and which you could not reach
- Print the list of newly discovered areas as your final message." \
    $PROVIDER_FLAGS || echo "⚠ agent session exited abnormally — continuing with post-run"
else
  NUDGE_PROMPT="You stopped before finishing. Do not ask the user anything — you are autonomous. Continue testing the '${AREA}' area per your original instructions. Record every confirmed bug with write_file to /opt/data/run/bug-<short-slug>.md — a distinct kebab-case slug from each bug title (e.g. bug-save-button-disabled.md) so you never overwrite an earlier bug file; reuse the exact name only if re-recording the same bug (title, exact URL, steps, expected, actual, severity, Screenshot line). Do NOT write /opt/data/run/summary.md until every applicable deep-coverage item from your original instructions has been attempted OR recorded as blocked and you have THEN tested your own 3 hypotheses (see below). Work them in this order: (1) authorization — mutate any id in the URL and navigate to the cross-persona URLs from site-config; (2) persistence across reload; (3) browser back/forward/refresh; (4) double-submit; (5) full create→edit→delete lifecycle. Treat each item as independent: if a feature is broken and blocks its item, record that bug ONCE, mark the item blocked, and MOVE ON — do not get stuck re-testing it across continuations. A button that does nothing or stays disabled is usually a stale ref or an uncommitted required field, not a bug — re-snapshot and confirm committed values before filing, and never force it with JavaScript. Once every item is attempted or blocked, do NOT stop: form your OWN 3 specific hypotheses about where THIS app is likely broken in ways the checklist misses (pick angles previous runs did not try) and test each in the browser, recording any bug. Only THEN rewrite /opt/data/run/area.md (current facts, what remains untested, and the 3 hypotheses you tested so they are not repeated; max 50 lines) and write /opt/data/run/summary.md (each item's outcome plus each hypothesis and its result).${GUIDE_NUDGE_LINE}${VIEWPORT_NUDGE_LINE}${KNOWN_NUDGE_LINE}"
  # shellcheck disable=SC2086
  timeout --signal=TERM --kill-after=30 "$SESSION_TIMEOUT" \
    argus chat --max-turns "$MAX_TURNS" \
  -t browser,skills_ro,file,terminal \
  -q "You are an autonomous QA engineer testing the '${AREA}' area of the ${SITE} web app, logged in as persona '${PERSONA}'.${GUIDE_BLOCK}${VIEWPORT_BLOCK}${KNOWN_BLOCK}

Before you start:
- Load these skills with skill_view: 'site-config', 'web-qa-workflow'
- Read /opt/data/run/area.md with read_file — your notes on this area from previous runs: what it is, its quirks, what is covered and what is not

Rules:
- Test through the browser UI only, like a real user. Never call the backend API directly, and only use the persona '${PERSONA}' credentials from site-config.
- You are testing the '${AREA}' area, NOT the login flow. Do not test, re-submit, or 'verify' the login form, and never log out. If you get redirected to /login mid-run, just repeat the login procedure (snapshot, type the same credentials, submit) to get back in — that is routine, not a bug, and never file it as one.
- NEVER type credentials you made up. The only valid login is the exact email+password in site-config. A login that rejects any other credentials is working correctly — not a bug.
- The ONLY valid site domain is https://${SITE_HOST} — if you remember any other domain, it is wrong.
- Do not ask for direction. If something does not work, try a different approach on your own.
- Never end your turn by announcing what you will do next — keep calling tools until the work is done. Your final message comes only after /opt/data/run/summary.md is written.
- The browser console is only for confirming a UI bug you already observed. Do not spend turns analysing console logs, network requests or backend endpoints on their own.
- Use browser_snapshot to read pages. Call browser_vision only to capture a bug screenshot or when the snapshot genuinely cannot show something visual — its output is huge and crowds out your context.
- Start with the 'What remains untested' items in area.md and exhaust those first; then keep going deeper. Use different test inputs than previous runs.
- Do NOT stop at basic input validation — that is the shallow layer. Deliberately exercise the deeper bug classes and access-control probes described in the web-qa-workflow skill: persistence across reload/re-login, the full create→edit→delete lifecycle, interrupted/resumed wizards, browser back/forward and double-submit, dependent-field transitions, error recovery, cross-view consistency (after any create/edit/delete, read at least two views of the same data — counts, lists, detail pages, dropdowns — and confirm they still agree; two views that disagree is itself the bug, no visible error needed), round-trip fidelity (after saving an awkward value — long, unicode, high-precision, an edge date — reload the record and confirm what comes back equals EXACTLY what you typed; silent truncation, rounding, dropped special characters or timezone shifts are the bug even with no error shown), and mutating an id in the URL (or navigating to a cross-persona URL from site-config) to test authorization. These are where the bugs shallow testing misses actually live — spend real effort here.

Process:
1. ${LOGIN_STEP}
2. ${NAV_LINE}
3. Explore it as a real user would — understand what is there and what it does
4. Test it thoroughly: edit fields, submit forms, navigate between sections
5. Try edge cases: empty values, very long strings, invalid data types, boundary numbers, special characters
6. Reproduce any suspected bug once before recording it
7. RECORD each confirmed bug immediately, while it is still on screen — all three steps before testing anything else:
   a. Call browser_vision — its result contains a screenshot_path
   b. Run in terminal: cp <that screenshot_path> /opt/data/reports/screenshots/<short-bug-name>.png
   c. Save the bug with write_file to /opt/data/run/bug-<short-slug>.md, where <short-slug> is a few kebab-case words from the bug title (e.g. bug-save-button-disabled.md). Use a DISTINCT slug for each different bug so you never overwrite an earlier one; if you are re-recording the SAME bug, reuse its exact filename. The file contains exactly:
      ## <short factual bug title>
      URL: <copied exactly from the browser, never from memory>
      Steps to reproduce: <numbered, from login>
      Expected behaviour: ...
      Actual behaviour: <what you observed>
      Severity: Critical / High / Medium / Low
      Screenshot: /opt/data/reports/screenshots/<short-bug-name>.png
   The Screenshot line must repeat EXACTLY the same filename you used in the cp command in step b — never invent a different name for it.
   A bug that is not saved to a file does not exist. Never describe bugs only in chat.
8. If you notice pages or sections OUTSIDE '${AREA}' that your notes do not mention (new nav links, new features), record each by running in the terminal: echo '<area-name> | <exact URL from the browser>' >> /opt/data/run/new-areas.md — do not test them this run.

REQUIRED deep-coverage checklist — attempt every item that applies to this area before you may finish, in THIS order (cheapest and highest-value first). Treat each item as INDEPENDENT: if one is blocked because the feature under it is broken, record that as a bug ONCE, note the item as 'blocked', and MOVE ON to the next — never spend more than one continuation stuck on a single item, and never let a blocked item stop you from reaching the others. Actually perform each sequence in the browser; a correct result still counts as 'attempted'.
   1. Authorization (do this FIRST — it needs no working form): if ANY URL here contains an id (a record id, an org UUID, ?id=), mutate that id to a different or foreign value AND navigate to the cross-persona URLs listed in site-config. A clean denial/redirect/404 is correct; leaking another party's data, letting you act on it, or a 500 / generic error page is a bug.
   2. Persistence: enter or save a value, then reload the page and also navigate away and back — confirm it survived and is not stale or reverted.
   3. Back / forward / refresh mid-flow: after a submit, press the browser Back button, and refresh a confirmation or detail page — watch for stale or resurrected form state.
   4. Double-submit: save or submit the same thing twice (click twice, or submit then press browser Back and re-submit) — watch for duplicate records.
   5. Full lifecycle: create a record, edit it, then delete it — check a deleted item does not linger in lists/counts/dropdowns and cannot still be opened. If create or submit seems unresponsive or a button stays disabled, that is usually a stale ref or an uncommitted required field, NOT a bug: re-snapshot for a fresh ref and confirm every required field (especially Vaadin comboboxes) shows a COMMITTED value before concluding it is broken (see the skill's false-positive guidance), and never force it with JavaScript. If it genuinely will not respond after that, record it once as blocked and move on.

The checklist is a FLOOR, not the whole job — clearing it is where a real QA session BEGINS the interesting work.

HYPOTHESIS PHASE (do this AFTER the checklist, BEFORE you finish): form your OWN 3 hypotheses and chase them. From what YOU saw this run — this app's stack and quirks (it is a Vaadin server-rendered app; watch its console for errors such as failed dynamic imports or 500s), any anomaly you noticed but did not follow up, and the 'what remains untested' notes in area.md — write down THREE specific, testable guesses about where THIS app is most likely broken in a way the fixed checklist would miss. Make each concrete (e.g. 'editing a record while its detail page is open elsewhere saves a stale version', NOT 'test editing'). Deliberately pick angles PREVIOUS runs did not try — novelty over re-coverage. Then actually perform each one in the browser and record any confirmed bug. A hypothesis that proves false still counts as done — note it so the next run does not repeat it.

When finished — and ONLY after every applicable checklist item above has been attempted OR recorded as blocked AND your 3 hypotheses have been tested:
- Rewrite /opt/data/run/area.md with write_file: the CURRENT facts about this area — what exists, its quirks, what is now covered, what remains untested. Include the 3 hypotheses you tested this run (so the next run does not repeat them) and any anomaly you saw but did not chase (a lead for next time). Replace stale lines instead of appending. No dates, no run history. Maximum 50 lines.
- Write /opt/data/run/summary.md with write_file: what you did this run, for EACH checklist item (1-5) whether you attempted it, skipped it as not-applicable, or hit a blocker and what happened, and your 3 hypotheses with the outcome of each.
- Print a short list of the bugs you recorded as your final message.

Do NOT write summary.md while an applicable checklist item is still unattempted-and-unblocked, or while you have not yet formed and tested your 3 hypotheses. Once the checklist is cleared AND your 3 hypotheses are tested, finish promptly — do not keep re-testing a blocked feature to burn turns." \
  $PROVIDER_FLAGS || echo "⚠ agent session exited abnormally — continuing with post-run"
fi

echo ""
# Babysitter + convergence: a small model rarely writes summary.md voluntarily,
# so without a convergence signal it rides the whole nudge ceiling even on a
# clean area (a 33-field form once burned ~2h / the full cycle). summary.md is
# the explicit completion signal; failing that, we converge when a full
# continuation produces NO NEW bug files. We require THREE consecutive barren
# continuations (≈ a clean area genuinely has nothing), so areas that find bugs
# in bursts across continuations are not cut short — the deeper stateful/authz
# probes often surface bugs late, after a couple of quiet continuations.
# find (not ls|wc) so an empty match is exit 0, never tripping set -e/pipefail.
count_bugs() { find "$RUN_DIR" -maxdepth 1 -name 'bug-*.md' 2>/dev/null | wc -l | tr -d ' '; }
NUDGES=0
NO_PROGRESS=0
PREV_BUGS=$(count_bugs)
while [[ ! -f "$RUN_DIR/summary.md" && $NUDGES -lt 8 ]]; do
  NUDGES=$((NUDGES + 1))
  echo "▶ Session ended without finishing (no summary.md) — continuing session (nudge $NUDGES/8)..."
  # shellcheck disable=SC2086
  timeout --signal=TERM --kill-after=30 "$SESSION_TIMEOUT" \
    argus chat --continue --max-turns 150 \
    -t browser,skills_ro,file,terminal \
    -q "$NUDGE_PROMPT" \
    $PROVIDER_FLAGS || echo "⚠ agent session exited abnormally — continuing with post-run"
  echo ""
  # NB: every conditional below uses if/fi, never '[[ ]] && cmd' — under set -e
  # a statement-level '&&' whose test is false returns 1 and EXITS the script.
  # This exact footgun silently killed two runs before the babysitter could act.
  if [[ -f "$RUN_DIR/summary.md" ]]; then
    break
  fi
  CUR_BUGS=$(count_bugs)
  if [[ "$CUR_BUGS" == "$PREV_BUGS" ]]; then
    NO_PROGRESS=$((NO_PROGRESS + 1))
    if [[ $NO_PROGRESS -ge 3 ]]; then
      echo "▶ Converged: three continuations recorded no new bugs — ending run."
      break
    fi
  else
    NO_PROGRESS=0
  fi
  PREV_BUGS="$CUR_BUGS"
done

# ── From here down is best-effort bookkeeping (hygiene, stamp, assemble,
# file). Disable errexit for it: a single non-zero return (a grep that
# matches nothing, an awk exit code, a gh hiccup) must NOT abort the run and
# leave bugs unassembled / the area unstamped. This set-e-kills-post-run class
# of bug has bitten three times; stop fighting it line-by-line.
set +e

# If the model never wrote summary.md (converged or hit the nudge cap),
# synthesise one so the report assembles and the completion state is explicit.
if [[ ! -f "$RUN_DIR/summary.md" ]]; then
  echo "Run ended without an agent-written summary (converged or nudge cap reached). Bugs recorded this run: $(count_bugs)." > "$RUN_DIR/summary.md"
fi

# ── Post-run hygiene (harness-owned, deterministic) ────────────────────────
# Any URL whose host looks like the site but is not EXACTLY the site host is a
# model hallucination (seen: dev.remundo.com, remundo.dev) — it once poisoned
# the notes and sent later runs to dead domains. Fix hosts, keep paths.
# NB: guard with if, not '[[ ]] &&' — under set -e a missing file would
# short-circuit to exit 1 and kill the whole post-run (happened once: bugs
# recorded but never assembled, index never stamped).
fix_hosts() {
  if [[ -f "$1" ]]; then
    sed -E -i "s#https?://[A-Za-z0-9.-]*${SITE}[A-Za-z0-9.-]*#https://${SITE_HOST}#g" "$1"
  fi
}
fix_hosts "$RUN_DIR/area.md"
fix_hosts "$RUN_DIR/new-areas.md"
for b in "$RUN_DIR"/bug-*.md; do
  [[ -f "$b" ]] || continue
  fix_hosts "$b"
done

# ── Within-run dedup ───────────────────────────────────────────────────────
# The exploration session files the SAME defect under several slugs — the last
# validation recorded one edit-URL-500 bug three times (bug-edit-500,
# bug-expense-edit-error, bug-edit-route-broken), and the verifier then confirmed
# each copy independently, inflating the count and the filing. Merge duplicates
# BEFORE verification so we don't spend a fresh verify session per copy. The rule
# is deliberately HIGH-PRECISION so it never merges two genuinely different bugs
# on the same page: two bugs collapse only when their URLs normalise to the same
# path AND they share the same HTTP error code (500/404/403/…); with no shared
# code they must share a near-identical normalised title. Extras are moved to
# run/duplicates/ (excluded from the report + filing) with a note folded into the
# survivor, and every merge is logged — never a silent drop.
norm_url() {  # strip scheme+host, query, and id-ish path segments
  printf '%s' "$1" | tr 'A-Z' 'a-z' | sed -E "s#^https?://[^/]+##; s/\?.*\$//; s#/[0-9a-f]{8}-[0-9a-f-]{4,}#/:id#g; s#/[0-9]+#/:id#g; s#/+\$##"
}
if ls "$RUN_DIR"/bug-*.md >/dev/null 2>&1; then
  mkdir -p "$RUN_DIR/duplicates"
  declare -A DEDUP_CANON
  MERGED=0
  for b in "$RUN_DIR"/bug-*.md; do
    [[ -f "$b" ]] || continue
    url="$(grep -iE '^URL:' "$b" | head -1 | sed 's/^[^:]*:[[:space:]]*//')"
    nurl="$(norm_url "$url")"
    # Only trust a numeric code as an HTTP-error symptom when the bug text is
    # actually about an error — otherwise a "£500" amount field would collide
    # with a genuine HTTP 500 on the same page and be wrongly merged.
    code=""
    if grep -qiE 'error|oops|internal server|dynamically imported|stack trace|http [0-9]|status code|crash|blank' "$b" 2>/dev/null; then
      code="$(grep -hoE '\b(403|404|500|502|503)\b' "$b" 2>/dev/null | head -1)"
    fi
    tkey="$(head -1 "$b" | tr 'A-Z' 'a-z' | tr -cd 'a-z0-9')"
    if [[ -n "$code" ]]; then
      key="${nurl}##${code}"
    else
      key="${nurl}##${tkey}"
    fi
    canon="${DEDUP_CANON[$key]:-}"
    if [[ -n "$canon" && -f "$canon" ]]; then
      dtitle="$(head -1 "$b" | sed 's/^#*[[:space:]]*//')"
      printf '\nAlso recorded this run as a duplicate (merged): %s — %s\n' "$dtitle" "${url:-?}" >> "$canon"
      mv "$b" "$RUN_DIR/duplicates/$(basename "$b")" 2>/dev/null || true
      MERGED=$((MERGED + 1))
      echo "  ⧉ merged duplicate: $(basename "$b") → $(basename "$canon")"
    else
      DEDUP_CANON[$key]="$b"
    fi
  done
  if [[ $MERGED -gt 0 ]]; then
    echo "▶ Dedup: merged ${MERGED} duplicate bug file(s) into their canonical bug (archived in duplicates/)."
  fi
fi

# ── Independent verification pass ──────────────────────────────────────────
# Re-check each recorded bug in a FRESH session (clean context, fresh browser,
# skeptical prompt, default = reject) that must INDEPENDENTLY reproduce the
# broken behaviour from scratch — this is what the exploration session's own
# self-verification cannot do, because it reasons from the same premises that
# produced the bug. Verdicts: confirmed (keep), downgrade (keep, lower
# severity), reject (moved to rejected/, excluded from report + filing). Each
# surviving bug gets a 'Verification:' provenance line. Disable with --no-verify.
if [[ "$VERIFY" == "true" && "$DISCOVER" != "true" ]] && ls "$RUN_DIR"/bug-*.md >/dev/null 2>&1; then
  echo ""
  echo "▶ Verification pass (${VERIFY_PROVIDER}/${VERIFY_MODEL}): independently re-checking each recorded bug in a fresh session..."
  mkdir -p "$RUN_DIR/rejected"
  for b in "$RUN_DIR"/bug-*.md; do
    [[ -f "$b" ]] || continue
    slug="$(basename "$b" .md)"
    verdict_file="$RUN_DIR/verdict-${slug}.txt"
    rm -f "$verdict_file"
    bug_title="$(head -1 "$b" | sed 's/^#*[[:space:]]*//')"
    echo "  • verifying: ${bug_title}"

    VERIFY_PROMPT="You are a SKEPTICAL senior QA reviewer doing an independent second look at ONE bug another tester filed. Decide whether it is REAL by reproducing it YOURSELF from scratch — do not trust the report. Your default verdict is REJECT: only confirm a bug you can independently reproduce, where the app genuinely misbehaves AND the filed 'expected behaviour' is actually correct.

Do NOT ask anything — you are autonomous.

Before you start:
- Load these skills with skill_view: 'site-config', 'web-qa-workflow'. Study the web-qa-workflow skill's 'How to Verify a Bug is Real' section and its false-positive guidance.
- Read the filed bug with read_file: ${b}

Then:
1. ${LOGIN_STEP}
2. Follow the bug's OWN 'Steps to reproduce' exactly, in a fresh browser, from the URL it gives. browser_snapshot before every action, and confirm each field holds a COMMITTED value before you judge anything.
3. Apply these known false-positive traps — if the 'bug' is one of them, the verdict is REJECT:
   - A button that is disabled or 'does nothing' is almost always a stale ref or an uncommitted REQUIRED field (especially a Vaadin combobox that needs a real selection), NOT a bug. Re-snapshot for a fresh ref and confirm every required field shows a committed value. NEVER force a control with JavaScript, and never conclude 'frozen/unresponsive' from a JS-dispatched click.
   - document.querySelectorAll('input') returning 0 or few elements is NOT a DOM crash: this is a Vaadin app whose inputs live inside shadow DOM, invisible to a light-DOM query. Judge the page by what browser_snapshot shows and whether you can actually type into the fields — never by a raw querySelector count.
   - Escaped HTML shown on screen (e.g. the literal text &lt;script&gt;) is CORRECT sanitization, not stored XSS. Only a payload that actually executes or renders as live markup is a real XSS.
   - Pre-existing odd records (titles containing script tags, extreme amounts, 'XSS Test', garbage strings) are leftover test data from earlier QA runs — their mere presence is NOT a bug.
   - A redirect to /login mid-flow, or a field that won't accept text on the first try, is routine (session/stale ref): log in again or re-snapshot. Never file it.
4. If the app genuinely misbehaves and the expected behaviour is right but the real impact is milder than filed, choose DOWNGRADE and give the correct severity.

Your FINAL action must be to write the verdict with write_file to ${verdict_file}, containing EXACTLY these lines and nothing else:
VERDICT: <confirmed|downgrade|reject>
SEVERITY: <Critical|High|Medium|Low>   (include ONLY when VERDICT is downgrade)
REASON: <one line: what you observed on re-test and why>

Write that file, then stop. Do not record new bugs and do not test anything beyond this one bug."

    vn=0
    while [[ ! -f "$verdict_file" && $vn -le 2 ]]; do
      if [[ $vn -eq 0 ]]; then
        # shellcheck disable=SC2086
        timeout --signal=TERM --kill-after=30 "$VERIFY_SESSION_TIMEOUT" \
          argus chat --max-turns "$VERIFY_MAX_TURNS" \
          -t browser,skills_ro,file \
          -q "$VERIFY_PROMPT" \
          $VERIFY_FLAGS || echo "    ⚠ verify session exited abnormally"
      else
        # shellcheck disable=SC2086
        timeout --signal=TERM --kill-after=30 "$VERIFY_SESSION_TIMEOUT" \
          argus chat --continue --max-turns "$VERIFY_MAX_TURNS" \
          -t browser,skills_ro,file \
          -q "You have not written the verdict yet. Finish now: reach a verdict on the one bug you were re-checking and write_file to ${verdict_file} EXACTLY the lines 'VERDICT: <confirmed|downgrade|reject>', then 'SEVERITY: <level>' ONLY if downgrade, then 'REASON: <one line>'. Write that file and stop." \
          $VERIFY_FLAGS || echo "    ⚠ verify continuation exited abnormally"
      fi
      vn=$((vn + 1))
    done

    if [[ ! -f "$verdict_file" ]]; then
      echo "    ? no verdict written — keeping bug, marked unverified"
      if ! grep -qi '^Verification:' "$b"; then
        printf '\nVerification: NOT verified — the verifier session produced no verdict; treat with caution.\n' >> "$b"
      fi
      continue
    fi

    v="$(grep -iE '^VERDICT:' "$verdict_file" | head -1 | sed 's/^[^:]*:[[:space:]]*//' | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z')"
    reason="$(grep -iE '^REASON:' "$verdict_file" | head -1 | sed 's/^[^:]*:[[:space:]]*//')"
    case "$v" in
      *reject*)
        echo "    ✗ REJECTED — ${reason:-no reason given}"
        printf '\nVerification: REJECTED on independent re-test — %s\n' "${reason:-no reason given}" >> "$b"
        mv "$b" "$RUN_DIR/rejected/$(basename "$b")" 2>/dev/null || true
        ;;
      *downgrade*)
        newsev="$(grep -iE '^SEVERITY:' "$verdict_file" | head -1 | sed 's/^[^:]*:[[:space:]]*//' | tr -cd 'A-Za-z')"
        if [[ -n "$newsev" ]]; then
          oldsev="$(grep -iE '^Severity:' "$b" | head -1 | sed 's/^[^:]*:[[:space:]]*//')"
          sed -i "s/^[Ss][Ee][Vv][Ee][Rr][Ii][Tt][Yy]:.*/Severity: ${newsev}/" "$b"
          echo "    ↓ DOWNGRADED ${oldsev:-?} → ${newsev} — ${reason:-no reason given}"
          printf '\nVerification: severity downgraded from %s to %s on independent re-test — %s\n' "${oldsev:-?}" "$newsev" "${reason:-no reason given}" >> "$b"
        else
          echo "    ↓ downgrade verdict but no severity given — keeping as-is, marked reviewed"
          printf '\nVerification: reviewed on re-test (downgrade requested without a level) — %s\n' "${reason:-no reason given}" >> "$b"
        fi
        ;;
      *confirm*)
        echo "    ✓ CONFIRMED — ${reason:-reproduced}"
        printf '\nVerification: confirmed on independent re-test — %s\n' "${reason:-reproduced}" >> "$b"
        ;;
      *)
        echo "    ? unrecognised verdict '${v}' — keeping bug, marked unverified"
        printf '\nVerification: verdict unclear on re-test — treat with caution.\n' >> "$b"
        ;;
    esac
  done

  KEPT=$(find "$RUN_DIR" -maxdepth 1 -name 'bug-*.md' 2>/dev/null | wc -l | tr -d ' ')
  REJECTED_N=$(find "$RUN_DIR/rejected" -maxdepth 1 -name 'bug-*.md' 2>/dev/null | wc -l | tr -d ' ')
  echo "▶ Verification complete: ${KEPT} kept, ${REJECTED_N} rejected (rejected bugs archived in rejected/, excluded from the report)."
fi

# ── Populate the known-issues frontier feed ────────────────────────────────
# Append this run's surviving bugs (deduped above, then verified) to the
# per-area known-issues ledger so the NEXT run recognises them as already-filed
# and hunts new ground instead of re-finding them. Confirmed/kept bugs ONLY —
# the rejected/ and duplicates/ subdirs are excluded by the top-level glob, so a
# false positive the verifier threw out never poisons the feed. Deduped against
# what's already in the ledger (normalised title+path) and size-capped. Skipped
# for ledger-neutral runs (--only, --viewport), exactly like the area.md writeback.
if [[ "$DISCOVER" != "true" && "$GUIDE_MODE" != "only" && -z "$VIEWPORT" ]] && ls "$RUN_DIR"/bug-*.md >/dev/null 2>&1; then
  KNOWN_FILE="$SITE_DIR/$AREA.known.md"
  if [[ ! -f "$KNOWN_FILE" ]]; then
    printf '# %s — bugs already found, verified and filed (harness-owned). QA runs read this to avoid re-reporting them; do not hand-edit.\n' "$AREA" > "$KNOWN_FILE"
  fi
  ADDED=0
  for b in "$RUN_DIR"/bug-*.md; do
    [[ -f "$b" ]] || continue
    title="$(head -1 "$b" | sed 's/^#*[[:space:]]*//' | tr -d '|' | tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//')"
    url="$(grep -iE '^URL:' "$b" | head -1 | sed 's/^[^:]*:[[:space:]]*//')"
    sev="$(grep -iE '^Severity:' "$b" | head -1 | sed 's/^[^:]*:[[:space:]]*//' | tr -cd 'A-Za-z')"
    path="${url#https://${SITE_HOST}}"
    [[ -n "$path" ]] || path="$url"
    newkey="$(printf '%s' "$title" | tr 'A-Z' 'a-z' | tr -cd 'a-z0-9')##$(norm_url "$url")"
    dup=0
    while IFS= read -r line; do
      etitle="$(printf '%s' "$line" | sed 's/^- *//' | cut -d'|' -f1)"
      eurl="$(printf '%s' "$line" | cut -d'|' -f2)"
      ekey="$(printf '%s' "$etitle" | tr 'A-Z' 'a-z' | tr -cd 'a-z0-9')##$(norm_url "$eurl")"
      if [[ "$ekey" == "$newkey" ]]; then dup=1; break; fi
    done < <(grep '^- ' "$KNOWN_FILE" 2>/dev/null)
    if [[ $dup -eq 0 ]]; then
      printf -- '- %s | %s | %s\n' "$title" "$path" "${sev:-?}" >> "$KNOWN_FILE"
      ADDED=$((ADDED + 1))
    fi
  done
  if [[ "$(grep -c '^- ' "$KNOWN_FILE" 2>/dev/null)" -gt 60 ]]; then
    { grep -v '^- ' "$KNOWN_FILE" | head -1; grep '^- ' "$KNOWN_FILE" | tail -60; } > "$KNOWN_FILE.tmp" && mv "$KNOWN_FILE.tmp" "$KNOWN_FILE"
  fi
  if [[ $ADDED -gt 0 ]]; then
    echo "▶ Frontier feed: recorded ${ADDED} new confirmed bug(s) to ${AREA}.known.md so future runs skip them and hunt new ground."
  fi
fi

# De-poison the area notes before they are written back. Under context pressure
# the model repeatedly "learns" a false workaround — that browser_type fails and
# you must set values with raw JS el.value/dispatchEvent — and records it as a
# quirk. That advice is wrong (JS bypasses the framework, so values that "save"
# may not really save) and self-perpetuates: the next run reads the quirk and
# repeats it. Strip those lines from area.md so they cannot propagate. The truth
# (refs go stale → re-snapshot and retype) is already in the web-qa-workflow skill.
de_poison() {
  if [[ -f "$1" ]]; then
    sed -E -i '/dispatchEvent/d; /[bB]rowser_type[^\n]*(fail|does *n.?.?t *work|do *not *work|won.?t *work|not *work)/d' "$1"
  fi
}
de_poison "$RUN_DIR/area.md"

# Write back the area notes (size-capped — the ledger holds state, not history).
# --only runs are ledger-neutral: a narrow targeted run must NOT overwrite the
# area's broad coverage notes (it only exercised one slice).
if [[ "$GUIDE_MODE" == "only" ]]; then
  echo "▶ --only run: leaving the ledger untouched (area.md + last-tested not updated)."
elif [[ -n "$VIEWPORT" ]]; then
  echo "▶ --viewport run: leaving the ledger untouched (area notes describe the desktop layout; last-tested not updated)."
elif [[ -s "$RUN_DIR/area.md" ]]; then
  head -60 "$RUN_DIR/area.md" > "$SITE_DIR/$AREA.md"
fi

# Fold newly discovered areas into the index (validated, deduped).
if [[ -s "$RUN_DIR/new-areas.md" ]]; then
  while IFS='|' read -r raw_name raw_url _; do
    name="$(echo "$raw_name" | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | tr -cd 'a-z0-9-' | sed 's/^-*//; s/-*$//')"
    url="$(echo "$raw_url" | tr -d '[:space:]')"
    url="${url%%\?*}"   # query strings are views, not areas
    [[ -n "$name" && "$url" == https://${SITE_HOST}/* ]] || continue
    # Dedupe on BOTH name and URL: discovery agents record the same page
    # under several names (hire-worker / create-worker / hire-a-worker-wizard
    # were all /create-eorinstance in one run).
    if ! awk -F'|' -v a="$name" -v u="$url" -v p="$PERSONA" '
         /^#/ {next}
         { gsub(/^[ \t]+|[ \t]+$/, "", $1); gsub(/^[ \t]+|[ \t]+$/, "", $2); gsub(/^[ \t]+|[ \t]+$/, "", $3) }
         $3==p { sub(/\?.*$/, "", $2); if ($1==a || $2==u) found=1 } END { exit !found }' "$INDEX"; then
      echo "$name | $url | $PERSONA | never" >> "$INDEX"
      echo "▶ New area discovered: $name ($url)"
    fi
  done < "$RUN_DIR/new-areas.md"
fi

# Drift guard: the model has tested a different page than asked before (a
# 'dashboard' run once spent itself on /expenses/new). If bugs were recorded
# and they all sit under ANOTHER known area's URL while none sit under this
# area's, don't stamp — the area wasn't actually tested.
DRIFTED=false
if [[ "$DISCOVER" != "true" && -n "$AREA_URL" ]] && ls "$RUN_DIR"/bug-*.md >/dev/null 2>&1; then
  AREA_PATH="${AREA_URL#https://${SITE_HOST}}"
  BUG_URLS="$(grep -h "^URL:" "$RUN_DIR"/bug-*.md 2>/dev/null | sed 's/^URL:[[:space:]]*//')"
  if [[ -n "$BUG_URLS" && -n "$AREA_PATH" && "$AREA_PATH" != "/" ]]; then
    hits_here=0; hits_other=0
    while IFS= read -r u; do
      if [[ "$u" == "https://${SITE_HOST}${AREA_PATH}"* ]]; then
        hits_here=$((hits_here + 1))
      else
        # does it sit under a DIFFERENT known area of this persona?
        if awk -F'|' -v u="$u" -v p="$PERSONA" -v me="$AREA" -v host="https://${SITE_HOST}" '
             /^#/ {next}
             { for (i=1;i<=3;i++) gsub(/^[ \t]+|[ \t]+$/, "", $i) }
             $3==p && $1!=me && $2!=host"/dashboard" && index(u, $2)==1 { found=1 }
             END { exit !found }' "$INDEX"; then
          hits_other=$((hits_other + 1))
        fi
      fi
    done <<< "$BUG_URLS"
    if [[ $hits_here -eq 0 && $hits_other -gt 0 ]]; then
      DRIFTED=true
      echo "⚠ Drift detected: recorded bugs are under other areas' URLs, none under '${AREA}' — not stamping the index."
    fi
  fi
fi

# Stamp the tested area in the index. Discovery runs do NOT stamp anything —
# mapped is not tested; discovered areas stay 'never' so test runs pick them up.
TODAY="$(date +%F)"
if [[ "$DISCOVER" == "true" || "$DRIFTED" == "true" || "$GUIDE_MODE" == "only" || -n "$VIEWPORT" ]]; then
  :
elif awk -F'|' -v a="$AREA" -v p="$PERSONA" '
     /^#/ {next}
     { gsub(/^[ \t]+|[ \t]+$/, "", $1); gsub(/^[ \t]+|[ \t]+$/, "", $3) }
     $1==a && $3==p { found=1 } END { exit !found }' "$INDEX"; then
  awk -F'|' -v a="$AREA" -v p="$PERSONA" -v d="$TODAY" '
    /^#/ { print; next }
    {
      o1=$1; o3=$3
      gsub(/^[ \t]+|[ \t]+$/, "", o1); gsub(/^[ \t]+|[ \t]+$/, "", o3)
      if (o1==a && o3==p) {
        gsub(/^[ \t]+|[ \t]+$/, "", $2)
        print o1 " | " $2 " | " o3 " | " d
      } else print
    }' "$INDEX" > "$INDEX.tmp" && mv "$INDEX.tmp" "$INDEX"
else
  echo "$AREA | ${AREA_URL:-https://${SITE_HOST}/dashboard} | $PERSONA | $TODAY" >> "$INDEX"
fi

# ── Assemble the report from the per-bug files ─────────────────────────────
# If the model wandered or died late in the run, every bug recorded up to that
# point still makes it into the report.
BUG_COUNT=0
if ls "$RUN_DIR"/bug-*.md >/dev/null 2>&1; then
  {
    if [[ -n "$VIEWPORT" ]]; then
      echo "# ${SITE} ${AREA} QA report — $(date '+%Y-%m-%d %H:%M') (persona: ${PERSONA}, viewport: ${VIEWPORT_LABEL})"
    else
      echo "# ${SITE} ${AREA} QA report — $(date '+%Y-%m-%d %H:%M') (persona: ${PERSONA})"
    fi
    echo
    for p in "$RUN_DIR"/bug-*.md; do
      cat "$p"
      # Deterministic viewport stamp on every bug: layout issues filed from a
      # 390px run are meaningless to a dev reproducing at desktop size.
      if [[ -n "$VIEWPORT" ]]; then
        echo "Viewport: ${VIEWPORT_LABEL}"
      fi
      echo
      echo "---"
      echo
    done
    # NB: summary.md is deliberately NOT included. It is the model's end-of-run
    # recollection, which after heavy compression lists a DIFFERENT, sometimes
    # fabricated bug set — appending it polluted the filer's input (it once
    # numbered bugs 1-9 off a 6-bug report). The authoritative bugs are the
    # per-bug files only. summary.md is kept in the archived run dir for humans.
  } > "$REPORT_FILE"
  BUG_COUNT=$(ls "$RUN_DIR"/bug-*.md | wc -l)
  echo "▶ Report assembled from $BUG_COUNT recorded bug(s): $REPORT_FILE"
else
  echo "▶ No bugs were recorded this run"
fi

# Archive the run dir alongside the reports.
mkdir -p "$(dirname "$ARCHIVE_DIR")"
mv "$RUN_DIR" "$ARCHIVE_DIR" 2>/dev/null || true

# ── GitHub issue filing (separate filer session) ──────────────────────────
# Gated by ARGUS_FILE_ISSUES / --issues. The QA report above is the input;
# a fresh, small agent session reads it, dedupes against existing
# Argus-labeled issues, and files only reproduced bugs.
if [[ "$FILE_ISSUES" == "true" && -f "$REPORT_FILE" ]]; then
  ARGUS_GITHUB_TOKEN="$(grep -E '^ARGUS_GITHUB_TOKEN=' /opt/data/.env 2>/dev/null | tail -1 | cut -d= -f2- || true)"
  if [[ -z "$ARGUS_GITHUB_TOKEN" ]]; then
    echo "✗ Issue filing enabled but ARGUS_GITHUB_TOKEN is not set in /opt/data/.env — skipping."
  else
    echo "▶ Filing GitHub issues from $REPORT_FILE ..."
    argus-file-issues "$REPORT_FILE" $PROVIDER_FLAGS
  fi
elif [[ "$FILE_ISSUES" == "true" ]]; then
  echo "✗ Issue filing enabled but no report file exists — nothing to file."
else
  echo "▶ Issue filing is off (enable with --issues or ARGUS_FILE_ISSUES=true) — report only."
fi

# ── Recording summary (opt-in --record) ───────────────────────────────────
if [[ "$RECORD" == "true" ]]; then
  echo ""
  if ls "$RECORDINGS_DIR"/*.webm >/dev/null 2>&1; then
    echo "▶ Browser recordings for this run (one .webm per session) in ${RECORDINGS_DIR}:"
    ls -t "$RECORDINGS_DIR"/*.webm | head -10 | sed 's#^#    #'
  else
    echo "▶ Recording was enabled but no .webm files were produced in ${RECORDINGS_DIR}."
  fi
fi
