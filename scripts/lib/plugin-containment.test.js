#!/usr/bin/env node
"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const test = require("node:test");

const {
  createPluginContainmentResolver,
} = require("./plugin-containment.js");

const requiredFiles = [path.join("scripts", "browser-client.mjs")];

function makeWorkspace() {
  const workspace = fs.mkdtempSync(path.join(os.tmpdir(), "codex-plugin-containment-"));
  const root = path.join(workspace, "openai-bundled");
  fs.mkdirSync(root);
  return { root, workspace };
}

function makePlugin(root, relativePath = path.join("plugins", "browser")) {
  const plugin = path.join(root, relativePath);
  fs.mkdirSync(path.join(plugin, ".codex-plugin"), { recursive: true });
  fs.mkdirSync(path.join(plugin, "scripts"), { recursive: true });
  fs.writeFileSync(
    path.join(plugin, ".codex-plugin", "plugin.json"),
    JSON.stringify({ name: "browser", version: "1.0.0" }),
  );
  fs.writeFileSync(path.join(plugin, "scripts", "browser-client.mjs"), "export {};\n");
  return plugin;
}

function resolverFor(root, overrides = {}) {
  return createPluginContainmentResolver(root, {
    requiredFiles,
    expectedManifestName: "browser",
    maxEntries: 100,
    ...overrides,
  });
}

test("resolves a contained plugin and returns its manifest", () => {
  const { root, workspace } = makeWorkspace();
  const plugin = makePlugin(root, path.join("plugins", "vendor", "browser-renamed"));
  try {
    const result = resolverFor(root).resolve("./plugins/vendor/browser-renamed");
    assert.deepEqual(result, {
      path: plugin,
      manifest: { name: "browser", version: "1.0.0" },
    });
  } finally {
    fs.rmSync(workspace, { recursive: true, force: true });
  }
});

test("rejects invalid roots and paths outside the lexical root", () => {
  const { root, workspace } = makeWorkspace();
  const outside = makePlugin(workspace, "outside-browser");
  makePlugin(root);
  const rootAlias = path.join(workspace, "root-alias");
  fs.symlinkSync(root, rootAlias);
  try {
    assert.equal(resolverFor(root).resolve("../outside-browser"), null);
    assert.equal(resolverFor(root).resolve(outside), null);
    assert.equal(resolverFor(root).resolve("."), null);
    assert.equal(resolverFor(rootAlias).resolve("plugins/browser"), null);
    assert.equal(resolverFor(path.join(workspace, "missing")).resolve("plugins/browser"), null);
  } finally {
    fs.rmSync(workspace, { recursive: true, force: true });
  }
});

test("rejects symlinks in intermediate paths and anywhere in the plugin tree", () => {
  const { root, workspace } = makeWorkspace();
  const safePlugin = makePlugin(root, path.join("plugins", "vendor", "browser"));
  const intermediateAlias = path.join(root, "plugins", "vendor-alias");
  fs.symlinkSync(path.dirname(safePlugin), intermediateAlias);

  const linkedPlugin = makePlugin(root, path.join("plugins", "browser-linked-content"));
  fs.symlinkSync(
    path.join(linkedPlugin, "scripts", "browser-client.mjs"),
    path.join(linkedPlugin, "linked-client.mjs"),
  );
  try {
    assert.equal(
      resolverFor(root).resolve("plugins/vendor-alias/browser"),
      null,
    );
    assert.equal(
      resolverFor(root).resolve("plugins/browser-linked-content"),
      null,
    );
  } finally {
    fs.rmSync(workspace, { recursive: true, force: true });
  }
});

test("rejects special entries and trees over the configured entry limit", () => {
  const { root, workspace } = makeWorkspace();
  const specialPlugin = makePlugin(root, path.join("plugins", "browser-special"));
  const fifo = path.join(specialPlugin, "unsafe.fifo");
  const limitedPlugin = makePlugin(root, path.join("plugins", "browser-limited"));
  fs.writeFileSync(path.join(limitedPlugin, "extra.txt"), "extra\n");
  try {
    if (process.platform !== "win32") {
      const { spawnSync } = require("node:child_process");
      const result = spawnSync("mkfifo", [fifo], { encoding: "utf8" });
      assert.equal(result.status, 0, result.stderr);
      assert.equal(resolverFor(root).resolve("plugins/browser-special"), null);
    }
    assert.equal(
      resolverFor(root, { maxEntries: 4 }).resolve("plugins/browser-limited"),
      null,
    );
  } finally {
    fs.rmSync(workspace, { recursive: true, force: true });
  }
});

test("requires regular files and the expected manifest name", () => {
  const { root, workspace } = makeWorkspace();
  const missingRequired = makePlugin(root, path.join("plugins", "browser-missing"));
  fs.rmSync(path.join(missingRequired, "scripts", "browser-client.mjs"));
  const wrongManifest = makePlugin(root, path.join("plugins", "browser-wrong-name"));
  fs.writeFileSync(
    path.join(wrongManifest, ".codex-plugin", "plugin.json"),
    JSON.stringify({ name: "chrome" }),
  );
  try {
    assert.equal(resolverFor(root).resolve("plugins/browser-missing"), null);
    assert.equal(resolverFor(root).resolve("plugins/browser-wrong-name"), null);
  } finally {
    fs.rmSync(workspace, { recursive: true, force: true });
  }
});

test("memoizes equivalent lexical candidates within one resolver", () => {
  const { root, workspace } = makeWorkspace();
  makePlugin(root);
  const resolver = resolverFor(root);
  const originalOpendirSync = fs.opendirSync;
  let openCount = 0;
  fs.opendirSync = (...args) => {
    openCount += 1;
    return originalOpendirSync(...args);
  };
  try {
    const first = resolver.resolve("plugins/browser");
    const firstOpenCount = openCount;
    assert.ok(first);
    assert.ok(firstOpenCount > 0);
    assert.strictEqual(resolver.resolve("./plugins/./browser"), first);
    assert.equal(openCount, firstOpenCount);
  } finally {
    fs.opendirSync = originalOpendirSync;
    fs.rmSync(workspace, { recursive: true, force: true });
  }
});

test("validates option types", () => {
  const { root, workspace } = makeWorkspace();
  try {
    assert.throws(
      () => createPluginContainmentResolver(root, { requiredFiles: "client.mjs" }),
      /requiredFiles must be an array/,
    );
    assert.throws(
      () => createPluginContainmentResolver(root, { maxEntries: 0 }),
      /maxEntries must be a positive safe integer/,
    );
    assert.throws(
      () => createPluginContainmentResolver("", {}),
      /root must be a non-empty string/,
    );
  } finally {
    fs.rmSync(workspace, { recursive: true, force: true });
  }
});
