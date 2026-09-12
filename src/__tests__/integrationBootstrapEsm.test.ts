/**
 * The integration suite's Extension Host half may not depend on an ESM-only
 * package, by any import style.
 *
 * `src/test/suite/**` compiles to CommonJS (tsconfig.integration.json) and is
 * loaded INSIDE the Extension Host, which runs the Node that VS Code ships.
 * `require()` of an ESM graph needs Node 20.19; the `engines.vscode` floor ships
 * Node 20.18, one release below it. Nothing on a PR launches that runtime, so a
 * dependency that cannot load there is green on every contributor's Node, green
 * on stable VS Code, green in every CI job, and red only in the nightly Release
 * run, where it blocks publishing until someone reads the log. mocha 12 did
 * exactly that from 2026-09-10, and mocha is pinned to 11 because of it.
 *
 * THE IMPORT STYLE IS NOT THE FIX, and this is the part that cost a wrong
 * first attempt. Rewriting the static import as `await import("mocha")` moved
 * the error without removing it: mocha 12's own CommonJS shim (`lib/mocha.cjs`)
 * `require()`s an ESM file inside the package, so the failure reappeared one
 * frame deeper, inside the dependency. A package whose graph is ESM cannot be
 * loaded at the floor at all. So this guard judges the DEPENDENCY, and counts a
 * dynamic import as reaching it just as a static one does.
 *
 * `src/test/runTest.ts` is deliberately out of scope. It runs on the runner's
 * own Node rather than in the Extension Host, so the floor's limit does not
 * reach it and refusing an ESM-only import there would refuse something safe.
 *
 * A type-only import IS spared: it is erased before emit and reaches no runtime.
 */
import { describe, it, expect } from "vitest";
import * as fs from "fs";
import * as path from "path";
import { createRequire } from "module";
import ts from "typescript";

const repoRoot = path.resolve(__dirname, "..", "..");
const suiteDir = path.join(repoRoot, "src", "test", "suite");

/** Every `.ts` under the Extension Host half of the integration suite. */
function suiteSources(): string[] {
    return fs
        .readdirSync(suiteDir)
        .filter((f) => f.endsWith(".ts"))
        .map((f) => path.join(suiteDir, f));
}

interface PackageReference {
    file: string;
    specifier: string;
    /** How the source reaches it, reported so a failure says where to look. */
    via: "static" | "dynamic";
}

/**
 * Every bare package this source reaches at runtime, by either import form.
 *
 * A relative specifier is our own compiled CommonJS and never an ESM graph. A
 * type-only import is erased before emit. Everything else is a real load.
 */
function packageReferencesIn(text: string, file: string): PackageReference[] {
    const sf = ts.createSourceFile(file, text, ts.ScriptTarget.ES2020, true);
    const found: PackageReference[] = [];
    const rel = path.relative(repoRoot, file);

    const isBare = (s: string) => !s.startsWith(".") && !s.startsWith("/");

    const visit = (node: ts.Node): void => {
        if (ts.isImportDeclaration(node)) {
            if (
                !node.importClause?.isTypeOnly &&
                ts.isStringLiteral(node.moduleSpecifier) &&
                isBare(node.moduleSpecifier.text)
            ) {
                found.push({
                    file: rel,
                    specifier: node.moduleSpecifier.text,
                    via: "static",
                });
            }
        }
        if (
            ts.isCallExpression(node) &&
            node.expression.kind === ts.SyntaxKind.ImportKeyword
        ) {
            const arg = node.arguments[0];
            if (arg && ts.isStringLiteral(arg) && isBare(arg.text)) {
                found.push({ file: rel, specifier: arg.text, via: "dynamic" });
            }
        }
        ts.forEachChild(node, visit);
    };

    visit(sf);
    return found;
}

/** The same, read off disk. */
function packageReferences(file: string): PackageReference[] {
    return packageReferencesIn(fs.readFileSync(file, "utf8"), file);
}

type Verdict = "builtin" | "esm" | "cjs" | "unresolved";

/**
 * What kind of thing a bare specifier names.
 *
 * `builtin` covers Node's own modules and `vscode`: the first live inside the
 * runtime, the second is injected by the Extension Host, and neither can be an
 * ESM graph.
 *
 * `unresolved` is deliberately NOT a pass. An earlier cut of this read the
 * manifest through `require.resolve(specifier + "/package.json")`, which an
 * `exports` map is free to refuse, and a package that refuses it came back
 * indistinguishable from a builtin. That is an instrument reporting success
 * because it could not look, so the caller treats this verdict as a failure and
 * names the package rather than skipping it.
 *
 * Reading the manifest off disk is what avoids that: every package the suite can
 * import is a direct dependency, so it has a `node_modules/<name>` entry, and a
 * plain file read is not subject to an exports map at all.
 */
function classify(specifier: string): Verdict {
    if (specifier === "vscode") return "builtin";
    const require_ = createRequire(path.join(repoRoot, "package.json"));
    if (require_("module").isBuiltin(specifier)) return "builtin";

    const manifestPath = path.join(
        repoRoot,
        "node_modules",
        specifier,
        "package.json",
    );
    if (!fs.existsSync(manifestPath)) return "unresolved";
    const manifest = JSON.parse(fs.readFileSync(manifestPath, "utf8")) as {
        type?: string;
    };
    return manifest.type === "module" ? "esm" : "cjs";
}

describe("the integration suite's Extension Host half", () => {
    it("a dependency on an ESM-only package should be absent, because the engines floor cannot load one", () => {
        const seen = suiteSources().flatMap(packageReferences);

        // The instrument has to have reached the source. Zero third-party
        // packages is a legitimate state here, so counting the judged subset
        // would assert nothing; what has to be true is that the walk parsed real
        // imports out of real files. Every integration test imports `vscode`, so
        // its absence means the AST walk found nothing and the check below is
        // vacuous rather than satisfied.
        expect(seen.length).toBeGreaterThan(0);
        expect(seen.map((s) => s.specifier)).toContain("vscode");

        // An unresolved package fails alongside an ESM one. It means the guard
        // could not answer, and a guard that cannot answer must say so rather
        // than report a clean sweep.
        const offenders = seen.filter((s) => {
            const v = classify(s.specifier);
            return v === "esm" || v === "unresolved";
        });
        expect(
            offenders.map(
                (o) =>
                    `${o.file} ${o.via}-imports "${o.specifier}" (${classify(o.specifier)})`,
            ),
        ).toEqual([]);
    });

    it("mocha should resolve to a CommonJS package, since the bootstrap loads it at the floor", () => {
        // The specific pin this guard was written for. The check above would
        // catch a regression here too, but only while the bootstrap still names
        // mocha; this one fails even if the import moves, and names the reason.
        expect(classify("mocha")).toBe("cjs");
    });

    it("the walk should reach every file in the suite directory, so a new test file cannot escape it", () => {
        const files = suiteSources();
        expect(files.length).toBeGreaterThanOrEqual(5);
        expect(files.map((f) => path.basename(f))).toContain("index.ts");
    });

    it("the classifier should discriminate all four verdicts, so the check above cannot pass by always answering the same thing", () => {
        // A classifier that cannot tell an ESM package from a CommonJS one makes
        // the assertion above decoration. `harper.js` is ESM-only and present in
        // this tree, and it is the case that broke the first cut of this
        // function: its `exports` map refuses `./package.json`, so resolving the
        // manifest through the module system answered "not judged" and read as a
        // pass. `typescript` is CommonJS and equally present.
        expect(classify("harper.js")).toBe("esm");
        expect(classify("typescript")).toBe("cjs");
        expect(classify("path")).toBe("builtin");
        expect(classify("vscode")).toBe("builtin");
        expect(classify("a-package-that-is-not-installed")).toBe("unresolved");
    });

    it("the import walk should catch both forms that load a package and spare the one that does not", () => {
        // Both directions matter. Missing a form lets the floor break through;
        // flagging a type-only import would refuse something that reaches no
        // runtime, which is how a guard gets deleted by the next person it trips.
        const caught = (src: string) =>
            packageReferencesIn(src, "probe.ts").map(
                (i) => `${i.via}:${i.specifier}`,
            );

        expect(caught(`import Mocha from "mocha";`)).toEqual(["static:mocha"]);
        expect(caught(`import { a } from "mocha";`)).toEqual(["static:mocha"]);
        expect(caught(`const m = await import("mocha");`)).toEqual([
            "dynamic:mocha",
        ]);
        expect(caught(`async function f() { await import("mocha"); }`)).toEqual(
            ["dynamic:mocha"],
        );
        expect(caught(`import type Mocha from "mocha";`)).toEqual([]);
        expect(caught(`import { x } from "./local";`)).toEqual([]);
        expect(caught(`const p = await import("./local");`)).toEqual([]);
    });
});
