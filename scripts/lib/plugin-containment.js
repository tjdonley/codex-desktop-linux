#!/usr/bin/env node
"use strict";

const fs = require("node:fs");
const path = require("node:path");

const DEFAULT_MAX_ENTRIES = 100000;
const MANIFEST_RELATIVE_PATH = path.join(".codex-plugin", "plugin.json");
const SAFE_PLUGIN_BASENAME = /^[A-Za-z0-9._-]+$/;

function isStrictlyInside(root, candidate) {
  const relative = path.relative(root, candidate);
  return (
    relative.length > 0 &&
    relative !== ".." &&
    !relative.startsWith(`..${path.sep}`) &&
    !path.isAbsolute(relative)
  );
}

function readRoot(root) {
  const metadata = fs.lstatSync(root, { throwIfNoEntry: false });
  if (metadata == null || metadata.isSymbolicLink() || !metadata.isDirectory()) {
    return null;
  }

  const realPath = fs.realpathSync(root);
  const realMetadata = fs.lstatSync(realPath, { throwIfNoEntry: false });
  if (
    realMetadata == null ||
    realMetadata.isSymbolicLink() ||
    !realMetadata.isDirectory()
  ) {
    return null;
  }
  return { path: root, realPath };
}

function inspectCandidateComponents(root, candidate) {
  const relative = path.relative(root, candidate);
  const components = relative.split(path.sep);
  let current = root;

  for (let index = 0; index < components.length; index += 1) {
    current = path.join(current, components[index]);
    const metadata = fs.lstatSync(current, { throwIfNoEntry: false });
    if (metadata == null || metadata.isSymbolicLink()) {
      return false;
    }
    if (!metadata.isDirectory()) {
      return false;
    }
  }

  return true;
}

function isRegularTree(root, maxEntries) {
  const pending = [root];
  let entries = 0;

  while (pending.length > 0) {
    const directoryPath = pending.pop();
    const directory = fs.opendirSync(directoryPath);
    try {
      let entry;
      while ((entry = directory.readSync()) !== null) {
        entries += 1;
        if (entries > maxEntries) {
          return false;
        }

        const entryPath = path.join(directoryPath, entry.name);
        const metadata = fs.lstatSync(entryPath, { throwIfNoEntry: false });
        if (metadata == null || metadata.isSymbolicLink()) {
          return false;
        }
        if (metadata.isDirectory()) {
          pending.push(entryPath);
        } else if (!metadata.isFile()) {
          return false;
        }
      }
    } finally {
      directory.closeSync();
    }
  }

  return true;
}

function inspectRequiredFile(candidate, realCandidate, relativePath) {
  if (
    typeof relativePath !== "string" ||
    relativePath.length === 0 ||
    path.isAbsolute(relativePath)
  ) {
    return null;
  }

  const requiredPath = path.resolve(candidate, relativePath);
  if (!isStrictlyInside(candidate, requiredPath)) {
    return null;
  }

  const metadata = fs.lstatSync(requiredPath, { throwIfNoEntry: false });
  if (metadata == null || metadata.isSymbolicLink() || !metadata.isFile()) {
    return null;
  }

  const realRequiredPath = fs.realpathSync(requiredPath);
  if (!isStrictlyInside(realCandidate, realRequiredPath)) {
    return null;
  }

  return requiredPath;
}

function normalizeOptions(options) {
  if (options == null || typeof options !== "object" || Array.isArray(options)) {
    throw new TypeError("plugin containment options must be an object");
  }

  const {
    requiredFiles = [],
    expectedManifestName = null,
    maxEntries = DEFAULT_MAX_ENTRIES,
  } = options;

  if (!Array.isArray(requiredFiles)) {
    throw new TypeError("requiredFiles must be an array");
  }
  for (const requiredFile of requiredFiles) {
    if (typeof requiredFile !== "string" || requiredFile.length === 0) {
      throw new TypeError("requiredFiles entries must be non-empty strings");
    }
  }
  if (
    expectedManifestName !== null &&
    (typeof expectedManifestName !== "string" || expectedManifestName.length === 0)
  ) {
    throw new TypeError("expectedManifestName must be a non-empty string or null");
  }
  if (!Number.isSafeInteger(maxEntries) || maxEntries < 1) {
    throw new TypeError("maxEntries must be a positive safe integer");
  }

  return {
    expectedManifestName,
    maxEntries,
    requiredFiles: [...new Set([MANIFEST_RELATIVE_PATH, ...requiredFiles])],
  };
}

/**
 * Create a filesystem-snapshot-scoped plugin resolver.
 *
 * Equivalent relative paths are memoized by their absolute lexical candidate.
 * Create a new resolver after copying or otherwise mutating the tree.
 */
function createPluginContainmentResolver(root, options = {}) {
  if (typeof root !== "string" || root.length === 0) {
    throw new TypeError("plugin containment root must be a non-empty string");
  }

  const { expectedManifestName, maxEntries, requiredFiles } = normalizeOptions(options);
  const rootPath = path.resolve(root);
  const memo = new Map();
  let rootState;

  try {
    rootState = readRoot(rootPath);
  } catch (_error) {
    rootState = null;
  }

  return {
    resolve(relativePath) {
      if (
        rootState == null ||
        typeof relativePath !== "string" ||
        relativePath.length === 0 ||
        path.isAbsolute(relativePath)
      ) {
        return null;
      }

      const candidate = path.resolve(rootPath, relativePath);
      if (!isStrictlyInside(rootPath, candidate)) {
        return null;
      }
      if (memo.has(candidate)) {
        return memo.get(candidate);
      }

      let result = null;
      try {
        if (
          SAFE_PLUGIN_BASENAME.test(path.basename(candidate)) &&
          inspectCandidateComponents(rootPath, candidate)
        ) {
          const realCandidate = fs.realpathSync(candidate);
          if (
            isStrictlyInside(rootState.realPath, realCandidate) &&
            isRegularTree(candidate, maxEntries)
          ) {
            const inspectedFiles = new Map();
            let filesAreSafe = true;
            for (const requiredFile of requiredFiles) {
              const requiredPath = inspectRequiredFile(
                candidate,
                realCandidate,
                requiredFile,
              );
              if (requiredPath == null) {
                filesAreSafe = false;
                break;
              }
              inspectedFiles.set(requiredFile, requiredPath);
            }

            if (filesAreSafe) {
              const manifest = JSON.parse(
                fs.readFileSync(inspectedFiles.get(MANIFEST_RELATIVE_PATH), "utf8"),
              );
              if (
                manifest != null &&
                typeof manifest === "object" &&
                !Array.isArray(manifest) &&
                (expectedManifestName == null || manifest.name === expectedManifestName)
              ) {
                result = { path: candidate, manifest };
              }
            }
          }
        }
      } catch (_error) {
        result = null;
      }

      memo.set(candidate, result);
      return result;
    },
  };
}

module.exports = {
  createPluginContainmentResolver,
};
