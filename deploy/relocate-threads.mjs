// Rewrites the rollout paths inside an imported thread index so they point at
// codex-web's isolated Codex home.
//
// Why this is needed: the thread list comes from state_5.sqlite, and every row
// stores an absolute path to its rollout transcript. Importing the index without
// rewriting those paths makes the app resume a chat by opening the *original*
// %USERPROFILE%\.codex file for append - the exact write that fails on this host
// with "failed to resume local thread recorder: 拒绝访问 (os error 5)".
//
// Paths appear in three shapes and all of them are handled:
//   C:\Users\me\.codex\sessions\...
//   \\?\C:\Users\me\.codex\sessions\...
//   C:\\Users\\me\\.codex\\memories  (escaped, inside the sandbox_policy JSON)
//
//   node deploy/relocate-threads.mjs <state_5.sqlite> <sourceHome> <targetHome>
//
// Stop codex-web first: it holds the database open.
import { closeSync, existsSync, openSync } from "node:fs";
import Database from "better-sqlite3";

const [file, sourceHome, targetHome] = process.argv.slice(2);
if (!file || !sourceHome || !targetHome) {
  console.error("usage: node deploy/relocate-threads.mjs <state_5.sqlite> <sourceHome> <targetHome>");
  process.exit(1);
}

const db = new Database(file, { fileMustExist: true });

const outside = () => db.prepare("select count(*) as n from threads where rollout_path not like ?").get(`${targetHome}%`).n;
const before = outside();
console.log(`threads outside the target home : ${before}`);

// Everything from "...<sourceHome>\<rest>" becomes "<targetHome>\<rest>".
const sourceMarker = `${sourceHome.toLowerCase()}\\`;
const rewritten = db
  .prepare(
    `update threads
        set rollout_path = ? || '\\' || substr(rollout_path, instr(lower(rollout_path), ?) + ?)
      where lower(rollout_path) like ?`,
  )
  .run(targetHome, sourceMarker, sourceMarker.length + 1, `%${sourceMarker}%`).changes;

// sandbox_policy keeps JSON-escaped paths; the extended-length prefix is not
// used there, so a plain (escaped) prefix replacement is enough.
const escapedSource = sourceHome.replaceAll("\\", "\\\\");
const escapedTarget = targetHome.replaceAll("\\", "\\\\");
const policies = db
  .prepare("update threads set sandbox_policy = replace(sandbox_policy, ?, ?) where sandbox_policy like ?")
  .run(escapedSource, escapedTarget, `%${escapedSource.replaceAll("\\", "\\\\")}%`).changes;

console.log(`rollout_path rewritten          : ${rewritten}`);
console.log(`sandbox_policy rewritten        : ${policies}`);
console.log(`threads outside the target home : ${outside()}`);

// A rollout that cannot be opened for append is a chat that cannot be resumed.
let unwritable = 0;
for (const row of db.prepare("select rollout_path from threads where archived = 0").all()) {
  if (!existsSync(row.rollout_path)) continue;
  try {
    closeSync(openSync(row.rollout_path, "a"));
  } catch {
    unwritable++;
  }
}
console.log(`rollouts not writable           : ${unwritable} (must be 0 to resume chats)`);
db.close();
