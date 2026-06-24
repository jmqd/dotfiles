#!/usr/bin/env node

import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const cliPath = path.join(
  here,
  "..",
  "node_modules",
  "@steipete",
  "oracle",
  "dist",
  "bin",
  "oracle-cli.js"
);

await import(pathToFileURL(cliPath).href);
