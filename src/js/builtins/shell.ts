type ShellInterpreter = any;
type Resolve = (value: ShellOutput) => void;

export function createBunShellTemplateFunction(ShellInterpreter) {
  class ShellError extends Error {
    #output: ShellOutput;
    constructor(output: ShellOutput) {
      super(`Failed with exit code: ${output}`)
      this.#output = output;
    }

    get exitCode() {
      return this.#output.exitCode;
    }

    get stdout() {
      return this.#output.stdout;
    }

    get stderr() {
      return this.#output.stderr;
    }

    text(encoding) {
      return this.#output.text(encoding);
    }

    json() {
      return this.#output.json();
    }

    arrayBuffer() {
      return this.#output.arrayBuffer();
    }

    blob() {
      return this.#output.blob();
    }
  }

  class ShellOutput {
    stdout: Buffer;
    stderr: Buffer;
    exitCode: number;
    constructor(stdout: Buffer, stderr: Buffer, exitCode: number) {
      this.stdout = stdout;
      this.stderr = stderr;
      this.exitCode = exitCode;
    }

    text(encoding) {
      return this.stdout.toString(encoding);
    }

    json() {
      return JSON.parse(this.stdout.toString());
    }

    arrayBuffer() {
      return this.stdout.buffer;
    }

    blob() {
      return new Blob([this.stdout]);
    }
  }

  function autoStartShell(shell) {
    return shell.run();
  }

  class ShellPromise extends Promise<ShellOutput> {
    #core: ShellInterpreter;
    #hasRun: boolean = false;
    #throws: boolean = true;
    // #immediate;
    constructor(core: ShellInterpreter, throws: boolean) {
      var resolve, reject;

      super((res, rej) => {
        resolve = code => {
          const out = new ShellOutput(core.getBufferedStdout(), core.getBufferedStderr(), code);
          if (this.#throws && code !== 0) {
            rej(out);
          } else {
            res(out);
          }
        }
        reject = code => rej(new ShellError(new ShellOutput(core.getBufferedStdout(), core.getBufferedStderr(), code)));
      });

      this.#throws = throws;
      this.#core = core;
      this.#hasRun = false;

      core.setResolve(resolve);
      core.setReject(reject);

      // this.#immediate = setImmediate(autoStartShell, this).unref();
    }

    get interpreter() {
      if (IS_BUN_DEVELOPMENT) {
        return this.#core;
      }
    }

    get stdin(): WritableStream {
      this.#run();
      return this.#core.stdin;
    }

    // For TransformStream
    get writable() {
      this.#run();
      return this.#core.stdin;
    }

    cwd(newCwd?: string): this {
      this.#throwIfRunning();
      if (typeof newCwd === "undefined" || newCwd === "." || newCwd === "" || newCwd === "./") {
        newCwd = defaultCwd;
      }
      this.#core.setCwd(newCwd);
      return this;
    }

    env(newEnv: Record<string, string>): this {
      this.#throwIfRunning();
      if (typeof newEnv === "undefined") {
        newEnv = defaultEnv;
      }

      this.#core.setEnv(newEnv);
      return this;
    }

    #run() {
      if (!this.#hasRun) {
        this.#hasRun = true;

        if (this.#core.isRunning()) return;
        this.#core.run();
      }
    }

    #quiet(): this {
      this.#throwIfRunning();
      this.#core.setQuiet();
      return this;
    }

    quiet(): this {
      return this.#quiet();
    }

    nothrow(): this {
      this.#throws = false;
      return this;
    }

    throws(doThrow: boolean | undefined): this {
      this.#throws = typeof doThrow === 'boolean' ? doThrow : false;
      return this;
    }

    async text(encoding) {
      const { stdout } = (await this.#quiet()) as ShellOutput;
      return stdout.toString(encoding);
    }

    async json() {
      const { stdout } = (await this.#quiet()) as ShellOutput;
      return JSON.parse(stdout.toString());
    }

    async *lines() {
      const { stdout } = (await this.#quiet()) as ShellOutput;

      if (process.platform === "win32") {
        yield* stdout.toString().split(/\r?\n/);
      } else {
        yield* stdout.toString().split("\n");
      }
    }

    async arrayBuffer() {
      const { stdout } = (await this.#quiet()) as ShellOutput;
      return stdout.buffer;
    }

    async blob() {
      const { stdout } = (await this.#quiet()) as ShellOutput;
      return new Blob([stdout]);
    }

    #throwIfRunning() {
      if (this.#hasRun) throw new Error("Shell is already running");
    }

    run(): this {
      this.#run();
      return this;
    }

    then(onfulfilled, onrejected) {
      this.#run();

      return super.then(onfulfilled, onrejected);
    }

    static get [Symbol.species]() {
      return Promise;
    }
  }

  var defaultEnv = process.env || {};
  const originalDefaultEnv = defaultEnv;
  var defaultCwd: string | undefined = undefined;

  const cwdSymbol = Symbol("cwd");
  const envSymbol = Symbol("env");
  const throwsSymbol = Symbol("throws");

  class ShellPrototype {
    [cwdSymbol]: string | undefined;
    [envSymbol]: Record<string, string | undefined> | undefined;
    [throwsSymbol]: boolean = true;

    env(newEnv: Record<string, string | undefined>) {
      if (typeof newEnv === "undefined" || newEnv === originalDefaultEnv) {
        this[envSymbol] = originalDefaultEnv;
      } else if (newEnv) {
        this[envSymbol] = Object.assign({}, newEnv);
      } else {
        throw new TypeError("env must be an object or undefined");
      }

      return this;
    }
    cwd(newCwd: string | undefined) {
      if (typeof newCwd === "undefined" || typeof newCwd === "string") {
        if (newCwd === "." || newCwd === "" || newCwd === "./") {
          newCwd = defaultCwd;
        }

        this[cwdSymbol] = newCwd;
      } else {
        throw new TypeError("cwd must be a string or undefined");
      }

      return this;
    }
    nothrow() {
      this[throwsSymbol] = false;
      return this;
    }
    throws(doThrow: boolean | undefined) {
      this[throwsSymbol] =  typeof doThrow === 'boolean' ? doThrow : false;
      return this;
    }
  }

  var BunShell = function BunShell() {
    const core = new ShellInterpreter(...arguments);

    const cwd = BunShell[cwdSymbol];
    const env = BunShell[envSymbol];
    const throws = BunShell[throwsSymbol];

    // cwd must be set before env or else it will be injected into env as "PWD=/"
    if (cwd) core.setCwd(cwd);
    if (env) core.setEnv(env);

    return new ShellPromise(core, throws);
  };

  function Shell() {
    if (!new.target) {
      throw new TypeError("Class constructor Shell cannot be invoked without 'new'");
    }

    var Shell = function Shell() {
      const core = new ShellInterpreter(...arguments);

      const cwd = Shell[cwdSymbol];
      const env = Shell[envSymbol];
      const throws = Shell[throwsSymbol];

      // cwd must be set before env or else it will be injected into env as "PWD=/"
      if (cwd) core.setCwd(cwd);
      if (env) core.setEnv(env);

      return new ShellPromise(core, throws);
    };

    Object.setPrototypeOf(Shell, ShellPrototype.prototype);
    Object.defineProperty(Shell, "name", { value: "Shell", configurable: true, enumerable: true });

    return Shell;
  }

  Shell.prototype = ShellPrototype.prototype;
  Object.setPrototypeOf(Shell, ShellPrototype);
  Object.setPrototypeOf(BunShell, ShellPrototype.prototype);

  BunShell[cwdSymbol] = defaultCwd;
  BunShell[envSymbol] = defaultEnv;
  BunShell[throwsSymbol] = true;

  Object.defineProperties(BunShell, {
    Shell: {
      value: Shell,
      configurable: false,
      enumerable: true,
      writable: false,
    },
    ShellPromise: {
      value: ShellPromise,
      configurable: false,
      enumerable: true,
      writable: false,
    },
  });

  return BunShell;
}
