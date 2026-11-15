#!/usr/bin/env node
// Generates / updates an nginx `auth_basic_user_file` for codex-web.
//
// nginx accepts apr1 (salted MD5, what Apache's `htpasswd -m` produces), so we
// emit that instead of {SHA} (unsalted SHA-1) or {PLAIN}.
//
//   node deploy/htpasswd.mjs add <user> [file]       password from stdin
//   node deploy/htpasswd.mjs generate <user> [file]  random password, printed once
//   node deploy/htpasswd.mjs list [file]
//   node deploy/htpasswd.mjs remove <user> [file]
//   node deploy/htpasswd.mjs selftest
//
// The hash is checked against the published vector before any file is written:
// apr1("hashcat", "71850310") === "$apr1$71850310$gh9m4xcAn3MGxogwX/ztb."
// (hashcat example hashes, hash-mode 1600).

import { createHash, randomBytes } from "node:crypto";
import { chmodSync, existsSync, readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const DEFAULT_FILE = path.join(
  path.dirname(fileURLToPath(import.meta.url)),
  "htpasswd",
);

const ITOA64 =
  "./0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";

function to64(value, count) {
  let out = "";
  for (let i = 0; i < count; i += 1) {
    out += ITOA64[value & 0x3f];
    value = Math.floor(value / 64);
  }
  return out;
}

function encodeDigest(final) {
  return (
    to64((final[0] << 16) | (final[6] << 8) | final[12], 4) +
    to64((final[1] << 16) | (final[7] << 8) | final[13], 4) +
    to64((final[2] << 16) | (final[8] << 8) | final[14], 4) +
    to64((final[3] << 16) | (final[9] << 8) | final[15], 4) +
    to64((final[4] << 16) | (final[10] << 8) | final[5], 4) +
    to64(final[11], 2)
  );
}

/** Apache apr1 / md5crypt with the "$apr1$" magic. */
export function apr1(password, salt) {
  const pw = Buffer.from(password, "utf8");
  const saltBytes = Buffer.from(salt, "utf8").subarray(0, 8);
  const magic = Buffer.from("$apr1$", "utf8");

  const ctx = createHash("md5").update(pw).update(magic).update(saltBytes);

  // Then just as many characters of md5(pw, salt, pw), cycling its 16 bytes.
  const mixed = createHash("md5")
    .update(pw)
    .update(saltBytes)
    .update(pw)
    .digest();
  const repeated = Buffer.alloc(pw.length);
  for (let i = 0; i < pw.length; i += 1) repeated[i] = mixed[i % 16];
  ctx.update(repeated);

  // Then something really weird: one byte per bit of the password length.
  for (let bits = pw.length; bits > 0; bits >>= 1) {
    ctx.update(bits & 1 ? Buffer.from([0]) : pw.subarray(0, 1));
  }
  let final = ctx.digest();

  for (let round = 0; round < 1000; round += 1) {
    const hash = createHash("md5");
    hash.update(round & 1 ? pw : final);
    if (round % 3) hash.update(saltBytes);
    if (round % 7) hash.update(pw);
    hash.update(round & 1 ? final : pw);
    final = hash.digest();
  }

  return `$apr1$${saltBytes.toString("utf8")}$${encodeDigest(final)}`;
}

const VECTOR = {
  password: "hashcat",
  salt: "71850310",
  hash: "$apr1$71850310$gh9m4xcAn3MGxogwX/ztb.",
};

export function selfTest() {
  return apr1(VECTOR.password, VECTOR.salt) === VECTOR.hash;
}

if (!selfTest()) {
  process.stderr.write(
    "apr1 does not reproduce the reference vector; refusing to write a password file that would lock you out.\n",
  );
  process.exit(2);
}

function newSalt() {
  return randomBytes(6).toString("hex").slice(0, 8);
}

function hashPassword(password) {
  return apr1(password, newSalt());
}

// --- file handling -------------------------------------------------------

function readEntries(file) {
  if (!existsSync(file)) return new Map();
  const entries = new Map();
  for (const line of readFileSync(file, "utf8").split(/\r?\n/)) {
    if (!line || line.startsWith("#")) continue;
    const at = line.indexOf(":");
    if (at <= 0) continue;
    entries.set(line.slice(0, at), line.slice(at + 1));
  }
  return entries;
}

function writeEntries(file, entries) {
  const body = [...entries].map(([user, hash]) => `${user}:${hash}\n`).join("");
  writeFileSync(file, body, { encoding: "utf8", mode: 0o600 });
  try {
    chmodSync(file, 0o600);
  } catch {
    // Windows: the mode is advisory.
  }
}

function readStdin() {
  return readFileSync(0, "utf8").replace(/\r?\n$/, "");
}

function randomPassword(length = 28) {
  const alphabet =
    "abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789!@#%^*-_=+";
  const bytes = randomBytes(length);
  let out = "";
  for (let i = 0; i < length; i += 1) out += alphabet[bytes[i] % alphabet.length];
  return out;
}

function usage() {
  process.stderr.write(
    [
      "Usage:",
      "  node deploy/htpasswd.mjs add <user> [file]       password from stdin",
      "  node deploy/htpasswd.mjs generate <user> [file]  random password, printed once",
      "  node deploy/htpasswd.mjs list [file]",
      "  node deploy/htpasswd.mjs remove <user> [file]",
      "  node deploy/htpasswd.mjs selftest",
      "",
      `Default file: ${DEFAULT_FILE}`,
      "",
    ].join("\n"),
  );
}

function main(argv) {
  const [command, ...rest] = argv;

  if (!command || command === "-h" || command === "--help") {
    usage();
    process.exit(1);
  }

  if (command === "selftest") {
    process.stdout.write("apr1 matches the reference vector\n");
    return;
  }

  // `list [file]` takes no user; every other command is `<command> <user> [file]`.
  const user = command === "list" ? undefined : rest[0];
  const fileArg = command === "list" ? rest[0] : rest[1];
  const file = fileArg ? path.resolve(fileArg) : DEFAULT_FILE;

  if (command === "list") {
    const entries = readEntries(file);
    if (!entries.size) {
      process.stdout.write(`no users in ${file}\n`);
      return;
    }
    for (const name of entries.keys()) process.stdout.write(`${name}\n`);
    return;
  }

  if (!user) {
    usage();
    process.exit(1);
  }

  if (command === "add") {
    const password = readStdin();
    if (!password) {
      process.stderr.write("refusing an empty password\n");
      process.exit(1);
    }
    const entries = readEntries(file);
    entries.set(user, hashPassword(password));
    writeEntries(file, entries);
    process.stdout.write(`updated ${user} in ${file}\n`);
    return;
  }

  if (command === "generate") {
    const password = randomPassword();
    const entries = readEntries(file);
    entries.set(user, hashPassword(password));
    writeEntries(file, entries);
    process.stdout.write(`created ${user} in ${file}\npassword: ${password}\n`);
    return;
  }

  if (command === "remove") {
    const entries = readEntries(file);
    if (!entries.delete(user)) {
      process.stderr.write(`no such user: ${user}\n`);
      process.exit(1);
    }
    writeEntries(file, entries);
    process.stdout.write(`removed ${user} from ${file}\n`);
    return;
  }

  usage();
  process.exit(1);
}

main(process.argv.slice(2));
