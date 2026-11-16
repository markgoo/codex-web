// Consistent copy of one SQLite database into another path, via VACUUM INTO.
//
// A plain file copy of a WAL database that another process is writing can be
// torn; VACUUM INTO takes a read snapshot and writes a clean, self-contained
// database. Used by deploy/import-history.ps1 for the Codex thread index.
//
//   node deploy/vacuum-copy.mjs <source.db> <destination.db>
import { copyFileSync, existsSync, mkdirSync, rmSync } from "node:fs";
import path from "node:path";
import Database from "better-sqlite3";

const [source, destination] = process.argv.slice(2);
if (!source || !destination) {
  console.error("usage: node deploy/vacuum-copy.mjs <source.db> <destination.db>");
  process.exit(1);
}
if (!existsSync(source)) {
  console.log(`skip: ${source} does not exist`);
  process.exit(0);
}

mkdirSync(path.dirname(destination), { recursive: true });
for (const suffix of ["", "-wal", "-shm"]) {
  const file = destination + suffix;
  if (existsSync(file)) {
    // Keep the previous index before replacing it: re-importing a snapshot must
    // not silently drop conversations that were started in this home since the
    // last import (their rollouts would still exist, but nothing would list them).
    if (suffix === "") {
      const stamp = new Date().toISOString().replace(/[:.]/g, "-").slice(0, 19);
      const backup = `${file}.bak-${stamp}`;
      try {
        copyFileSync(file, backup);
        console.log(`previous index kept at ${backup}`);
      } catch (error) {
        console.error(`cannot back up ${file}: ${error.message}`);
        process.exit(1);
      }
    }
    try {
      rmSync(file, { force: true });
    } catch (error) {
      console.error(`cannot replace ${file}: ${error.message}`);
      console.error("stop codex-web (and any codex.exe using this home) and run again");
      process.exit(1);
    }
  }
}

const db = new Database(source, { readonly: true, fileMustExist: true });
try {
  db.exec(`VACUUM INTO '${destination.replaceAll("'", "''")}'`);
  console.log(`copied ${source} -> ${destination}`);
} finally {
  db.close();
}
