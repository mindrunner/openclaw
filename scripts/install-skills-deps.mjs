#!/usr/bin/env node
/**
 * Reads all skills/SKILL.md metadata and installs their declared
 * dependencies (brew, go, node, uv).
 *
 * Brew formulas: warn on failure (some formulas lack Linux/x86 support).
 * Everything else: fail the build immediately on error.
 */
import { readdirSync, readFileSync } from "fs";
import { join, dirname } from "path";
import { execSync } from "child_process";
import { fileURLToPath } from "url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const skillsDir = join(__dirname, "..", "skills");
const platform = process.platform; // "linux" in Docker
const skipMLDeps = process.env.OPENCLAW_SKIP_ML_DEPS === "1";

// Heavy AI/ML packages that pull in massive dependencies (llvm@20: 2.3GB)
const mlPackages = new Set([
  "openai-whisper",
  "pytorch",
  "gemini-cli",
]);

if (skipMLDeps) {
  console.log("OPENCLAW_SKIP_ML_DEPS=1: Skipping AI/ML packages to reduce image size");
}

function parseSkillMetadata(dir) {
  const content = readFileSync(join(dir, "SKILL.md"), "utf-8");

  // Extract YAML frontmatter between --- markers
  const fmMatch = content.match(/^---\n([\s\S]*?)\n---/);
  if (!fmMatch) return null;
  const frontmatter = fmMatch[1];

  // Find the metadata block — everything after "metadata:" until the end
  // of the frontmatter. The JSON object may span multiple lines.
  const metaIdx = frontmatter.indexOf("\nmetadata:");
  if (metaIdx === -1) return null;
  const afterMeta = frontmatter.slice(metaIdx + "\nmetadata:".length).trim();

  // Parse JSON5-ish (trailing commas) by stripping them
  const cleaned = afterMeta.replace(/,(\s*[}\]])/g, "$1");
  const raw = JSON.parse(cleaned);
  return raw.openclaw || raw;
}

function run(cmd, env) {
  console.log(`  $ ${cmd}`);
  execSync(cmd, {
    stdio: "inherit",
    timeout: 600_000,
    env: { ...process.env, ...env },
  });
}

/** Returns true on success, false on failure (logs the error). */
function tryRun(cmd, env) {
  console.log(`  $ ${cmd}`);
  try {
    execSync(cmd, {
      stdio: "inherit",
      timeout: 600_000,
      env: { ...process.env, ...env },
    });
    return true;
  } catch (e) {
    console.error(`  WARN: ${cmd} failed (exit ${e.status ?? "?"}), skipping`);
    return false;
  }
}

// ── Collect install specs ───────────────────────────────────────────
const brewFormulas = [];
const goModules = [];
const nodePackages = [];
const uvPackages = [];

const skills = readdirSync(skillsDir, { withFileTypes: true })
  .filter((d) => d.isDirectory())
  .map((d) => d.name);

for (const skill of skills) {
  let meta;
  try {
    meta = parseSkillMetadata(join(skillsDir, skill));
  } catch (e) {
    // No SKILL.md or no parseable metadata — skip
    continue;
  }
  if (!meta?.install) continue;

  // Skip skills restricted to other platforms
  if (meta.os && !meta.os.includes(platform)) continue;

  for (const spec of meta.install) {
    // Skip installers restricted to other platforms
    if (spec.os && !spec.os.includes(platform)) continue;
    // Skip cask installers (macOS-only GUI apps)
    if (spec.kind === "brew" && spec.cask) continue;

    switch (spec.kind) {
      case "brew":
        if (spec.formula) {
          // Skip heavy ML packages if OPENCLAW_SKIP_ML_DEPS=1
          const formulaName = spec.formula.split("/").pop();
          if (skipMLDeps && mlPackages.has(formulaName)) {
            console.log(`  Skipping ${spec.formula} (ML dependency)`);
          } else {
            brewFormulas.push(spec.formula);
          }
        }
        break;
      case "go":
        if (spec.module) goModules.push(spec.module);
        break;
      case "node":
        if (spec.package) nodePackages.push(spec.package);
        break;
      case "uv":
        if (spec.package) uvPackages.push(spec.package);
        break;
      // Skip "download" — large binaries not suited for default image
    }
  }
}

const uniqueBrew = [...new Set(brewFormulas)];
const uniqueGo = [...new Set(goModules)];
const uniqueNode = [...new Set(nodePackages)];
const uniqueUv = [...new Set(uvPackages)];

console.log(
  `Skills scan: ${uniqueBrew.length} brew, ${uniqueGo.length} go, ` +
    `${uniqueNode.length} node, ${uniqueUv.length} uv`,
);

// ── 1. Brew (warn on failure — some lack Linux/x86 bottles) ─────────
const brewFailed = [];
if (uniqueBrew.length > 0) {
  console.log(`\n==> Tapping & installing ${uniqueBrew.length} brew formulas`);

  const taps = new Set();
  for (const f of uniqueBrew) {
    const parts = f.split("/");
    if (parts.length === 3) taps.add(`${parts[0]}/${parts[1]}`);
  }
  for (const tap of taps) run(`brew tap ${tap}`);
  for (const formula of uniqueBrew) {
    if (!tryRun(`brew install ${formula}`)) {
      brewFailed.push(formula);
    }
  }
}

// ── 2. Go (use brew's Go which is modern, not Debian's ancient 1.19) ─
if (uniqueGo.length > 0) {
  console.log(`\n==> Installing Go via brew (Debian's is too old)`);
  run("brew install go");
  const brewPrefix =
    process.env.HOMEBREW_PREFIX || "/home/linuxbrew/.linuxbrew";
  const goRoot = `${brewPrefix}/opt/go/libexec`;
  const gopath = join(process.env.HOME ?? "/home/node", "go");
  console.log(`==> Installing ${uniqueGo.length} go modules`);
  for (const mod of uniqueGo) {
    run(`${brewPrefix}/opt/go/bin/go install ${mod}`, {
      GOPATH: gopath,
      GOROOT: goRoot,
    });
  }
}

// ── 3. Node ─────────────────────────────────────────────────────────
if (uniqueNode.length > 0) {
  console.log(`\n==> Installing ${uniqueNode.length} node packages`);
  for (const pkg of uniqueNode) run(`sudo npm install -g ${pkg}`);
}

// ── 4. UV ───────────────────────────────────────────────────────────
if (uniqueUv.length > 0) {
  console.log(`\n==> Installing uv + ${uniqueUv.length} uv packages`);
  run("brew install uv");
  for (const pkg of uniqueUv) run(`uv tool install ${pkg}`);
}

// ── Summary ─────────────────────────────────────────────────────────
console.log("\n==> Skill dependency installation complete");
if (brewFailed.length > 0) {
  console.log(
    `  WARN: ${brewFailed.length} brew formula(s) failed (platform incompatible):`,
  );
  for (const f of brewFailed) console.log(`    - ${f}`);
}
