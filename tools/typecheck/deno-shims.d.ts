/**
 * The slice of the Deno runtime surface Massanger's edge functions touch.
 *
 * Supabase Edge Functions run on Deno, where these globals exist natively. We
 * declare them here so `tsc` can typecheck the functions in environments that
 * have no Deno binary (CI sandboxes, offline dev). Delete this file if you
 * switch the check to `deno check`.
 */

declare namespace Deno {
  interface Env {
    get(key: string): string | undefined;
    get(key: string, options: { required: true }): string;
    set(key: string, value: string): void;
  }

  interface ServeOptions {
    port?: number;
    hostname?: string;
    reusePort?: boolean;
    onError?: (error: unknown) => string;
  }

  interface HttpServer {
    finished: Promise<void>;
    shutdown(): Promise<void>;
  }

  const env: Env;

  function serve(
    handler: (request: Request) => Response | Promise<Response>,
    options?: ServeOptions
  ): HttpServer;

  function addEventListener(
    type: 'load' | 'beforeunload' | 'error' | 'unhandledrejection',
    listener: (event: Event) => void | Promise<void>
  ): void;

  const ppid: number;
  const pid: number;
  function exit(code?: number): never;
}

declare interface ImportMeta {
  url: string;
  main?: boolean;
  /** Supabase edge-runtime exposes no `Deno.mainModule`; keep both usable. */
  resolve?(specifiers: string | string[]): string;
}
