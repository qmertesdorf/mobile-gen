import { test, expect, describe } from "vitest";
import { readFileSync, existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const REPO_ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const REQUIRED_SKILLS = ["concept", "builder", "validator", "asset", "packager"];

// Minimal frontmatter parse: grab the first --- ... --- block and read name/description.
function frontmatter(md) {
  const m = md.match(/^---\r?\n([\s\S]*?)\r?\n---/);
  if (!m) return null;
  const out = {};
  for (const line of m[1].split(/\r?\n/)) {
    const kv = line.match(/^(\w+):\s*(.*)$/);
    if (kv) out[kv[1]] = kv[2].trim();
  }
  return out;
}

describe.each(REQUIRED_SKILLS)("skill: %s", (skill) => {
  const path = join(REPO_ROOT, ".claude", "skills", skill, "SKILL.md");

  test("SKILL.md exists", () => {
    expect(existsSync(path)).toBe(true);
  });

  test("has frontmatter with matching name and a description", () => {
    const fm = frontmatter(readFileSync(path, "utf8"));
    expect(fm).not.toBeNull();
    expect(fm.name).toBe(skill);
    expect(fm.description && fm.description.length).toBeGreaterThan(10);
  });
});
