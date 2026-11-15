import { existsSync } from "node:fs";
import Module from "node:module";
import path from "node:path";

// The shim has to come from the same build as the server that requires it.
// Resolving it against the repo root instead (as this used to do) silently ran
// a stale src/server/electron build whenever the server itself was built to
// scratch/server by deploy/setup-windows.ps1.
function resolveElectronShim(): string {
  const candidates = [
    path.resolve(__dirname, "electron/index.js"),
    path.resolve(__dirname, "../..", "src/server/electron/index.js"),
  ];
  return (
    candidates.find((candidate) => existsSync(candidate)) ??
    path.resolve(__dirname, "electron/index.js")
  );
}

export function installModuleAliasHook(): void {
  const moduleWithLoad = Module as typeof Module & {
    _load: (
      request: string,
      parent: NodeModule | undefined,
      isMain: boolean,
    ) => unknown;
  };
  const originalLoad = moduleWithLoad._load;
  const electronShimPath = resolveElectronShim();

  moduleWithLoad._load = function moduleAliasLoad(
    request: string,
    parent: NodeModule | undefined,
    isMain: boolean,
  ): unknown {
    if (request === "electron") {
      return originalLoad.call(this, electronShimPath, parent, isMain);
    }

    return originalLoad.call(this, request, parent, isMain);
  };
}
