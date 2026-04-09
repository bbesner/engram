import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import type { OpenClawPluginApi } from 'openclaw/plugin-sdk';

const execFileAsync = promisify(execFile);

const plugin = {
  register(api: OpenClawPluginApi) {
    const config = api.pluginConfig || {};
    const workspace = api.config?.agents?.defaults?.workspace || '{{WORKSPACE}}';
    const extractorScript = '{{WORKSPACE}}/extensions/auto-skill-capture/scripts/skill-extractor.py';

    if (config.captureEnabled !== false) {
      api.on('session_end', async (_event, _ctx) => {
        try {
          execFileAsync('python3', [extractorScript, '--workspace', workspace], {
            cwd: workspace,
            env: process.env,
            maxBuffer: 2 * 1024 * 1024,
            timeout: 120000,
          }).then(() => {
            api.logger.info('auto-skill-capture: extraction complete');
          }).catch((err) => {
            api.logger.warn(`auto-skill-capture: extraction failed: ${String(err)}`);
          });
        } catch (err) {
          api.logger.warn(`auto-skill-capture: failed to launch extractor: ${String(err)}`);
        }
      });
    }

    if (config.recallEnabled !== false) {
      api.on('before_prompt_build', async (_event, _ctx) => {
        return {};
      });
    }

    api.registerService({
      id: 'auto-skill-capture',
      start: () => api.logger.info('auto-skill-capture: started'),
      stop: () => api.logger.info('auto-skill-capture: stopped'),
    });
  },
};

export default plugin;
