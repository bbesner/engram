import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import type { OpenClawPluginApi } from 'openclaw/plugin-sdk';

const execFileAsync = promisify(execFile);

const WORKSPACE = '{{WORKSPACE}}';
const CAPTURE_SCRIPT = `${WORKSPACE}/scripts/incremental-memory-capture.py`;

// Post-turn capture: extracts facts from the most recent conversation window
// after each agent turn. Pre-turn recall is handled by memory-core plugin.
const plugin = {
  register(api: OpenClawPluginApi) {
    api.on('agent_end', async (_event, _ctx) => {
      try {
        await execFileAsync('python3', [CAPTURE_SCRIPT, '--include-active'], {
          cwd: WORKSPACE,
          env: process.env,
          maxBuffer: 1024 * 1024,
        });
        api.logger.info('memory-bridge: post-turn capture complete');
      } catch (err) {
        api.logger.warn(`memory-bridge: capture failed: ${String(err)}`);
      }
    });

    api.registerService({
      id: 'memory-bridge',
      start: () => api.logger.info('memory-bridge: started (post-turn capture active)'),
      stop: () => api.logger.info('memory-bridge: stopped'),
    });
  },
};

export default plugin;
