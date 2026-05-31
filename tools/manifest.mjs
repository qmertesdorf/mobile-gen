import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import Ajv from "ajv/dist/2020.js";
import addFormats from "ajv-formats";

const __dirname = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = join(__dirname, "..");
const SCHEMA_PATH = join(REPO_ROOT, "schema", "manifest.schema.json");

let _validator;
function getValidator() {
  if (!_validator) {
    const schema = JSON.parse(readFileSync(SCHEMA_PATH, "utf8"));
    const ajv = new Ajv({ allErrors: true });
    addFormats(ajv);
    _validator = ajv.compile(schema);
  }
  return _validator;
}

export function validate(manifest) {
  const v = getValidator();
  const valid = v(manifest);
  return {
    valid,
    errors: valid ? [] : v.errors.map((e) => `${e.instancePath || "/"} ${e.message}`)
  };
}
