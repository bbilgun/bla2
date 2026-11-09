// Structured JSON logs, one object per line, so CloudWatch Logs Insights can filter on any field.
// The tests set LOG_LEVEL=silent to turn them off.

type Level = 'debug' | 'info' | 'warn' | 'error';

/** Writes one JSON line per call. `child` returns a logger that adds `fields` to every line. */
export interface Logger {
  debug(msg: string, fields?: Record<string, unknown>): void;
  info(msg: string, fields?: Record<string, unknown>): void;
  warn(msg: string, fields?: Record<string, unknown>): void;
  error(msg: string, fields?: Record<string, unknown>): void;
  child(fields: Record<string, unknown>): Logger;
}

const silent = process.env.LOG_LEVEL === 'silent';

// JSON.stringify turns an Error into {}, so pull out the parts worth keeping.
function serializeError(value: unknown): unknown {
  if (value instanceof Error) return { name: value.name, message: value.message, stack: value.stack };
  return value;
}

function createLogger(base: Record<string, unknown>): Logger {
  const write = (level: Level, msg: string, fields: Record<string, unknown> = {}) => {
    if (silent) return;
    const entry: Record<string, unknown> = { level, msg, ...base };
    for (const [key, value] of Object.entries(fields)) {
      entry[key] = serializeError(value);
    }
    const line = JSON.stringify(entry);
    if (level === 'error') {
      console.error(line);
    } else {
      console.log(line);
    }
  };

  return {
    debug: (msg, fields) => write('debug', msg, fields),
    info: (msg, fields) => write('info', msg, fields),
    warn: (msg, fields) => write('warn', msg, fields),
    error: (msg, fields) => write('error', msg, fields),
    child: (fields) => createLogger({ ...base, ...fields }),
  };
}

/** The root logger. lib/http.ts makes a child per request. */
export const logger = createLogger({ service: 'netzero' });
