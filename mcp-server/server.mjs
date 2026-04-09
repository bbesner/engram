#!/usr/bin/env node
/**
 * OpenClaw Memory MCP Server (v2.0)
 *
 * Exposes an OpenClaw agent's memory system as MCP tools for remote
 * Claude Code instances. Runs as a stdio MCP server.
 *
 * Read Tools:
 *   memory_search      — Semantic search via openclaw memory search
 *   memory_read        — Read a specific memory or skill file
 *   skill_list         — List all available skills
 *   skill_read         — Read a skill's SKILL.md
 *   memory_grep        — Exact keyword search across memory and skills
 *
 * Write Tools:
 *   memory_candidate   — Submit tagged facts to the daily log
 *   session_submit     — Submit a session transcript for bridge processing
 *   session_chunk_start/chunk/chunk_finish — Chunked upload for large sessions
 *   session_flag       — Flag a session for priority skill capture
 *
 * System Tools:
 *   health             — Check server and integration health
 *
 * Features:
 *   - Search result caching (5-minute TTL) for repeated queries
 *   - Chunked transcript upload for large sessions (no size limits)
 *   - Health check tool for monitoring
 *   - Security-scoped to memory/ and skills/ directories
 *
 * Configuration via environment variables:
 *   OPENCLAW_WORKSPACE    — Agent workspace path (required)
 *   OPENCLAW_CONFIG_PATH  — Path to openclaw.json
 */

import { Server } from '@modelcontextprotocol/sdk/server/index.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from '@modelcontextprotocol/sdk/types.js';
import { execFile, exec as execCb } from 'node:child_process';
import { promisify } from 'node:util';
import { readdir, readFile, stat, writeFile, appendFile, unlink, mkdir } from 'node:fs/promises';
import { join, relative } from 'node:path';
import { existsSync } from 'node:fs';

const execFileP = promisify(execFile);
const execP = promisify(execCb);

// ─── Configuration ──────────────────────────────────────────

const WORKSPACE = process.env.OPENCLAW_WORKSPACE || '{{WORKSPACE}}';
const CONFIG_PATH = process.env.OPENCLAW_CONFIG_PATH || join(WORKSPACE, 'openclaw.json');
const ALLOWED_PATHS = [
  join(WORKSPACE, 'memory'),
  join(WORKSPACE, 'skills'),
  join(WORKSPACE, 'MEMORY.md'),
];

const CACHE_TTL_MS = 5 * 60 * 1000; // 5-minute search cache
const CHUNK_DIR = join(WORKSPACE, 'logs', '.mcp-chunks');

// ─── Utilities ──────────────────────────────────────────────

function isAllowedPath(filePath) {
  const resolved = join(WORKSPACE, filePath);
  return ALLOWED_PATHS.some(allowed =>
    resolved === allowed || resolved.startsWith(allowed + '/')
  );
}

// Simple in-memory cache for search results
const searchCache = new Map();

function getCachedSearch(query, maxResults) {
  const key = `${query}::${maxResults}`;
  const entry = searchCache.get(key);
  if (entry && Date.now() - entry.ts < CACHE_TTL_MS) {
    return entry.result;
  }
  searchCache.delete(key);
  return null;
}

function setCachedSearch(query, maxResults, result) {
  const key = `${query}::${maxResults}`;
  searchCache.set(key, { result, ts: Date.now() });
  // Prune old entries (keep max 50)
  if (searchCache.size > 50) {
    const oldest = [...searchCache.entries()]
      .sort((a, b) => a[1].ts - b[1].ts)
      .slice(0, searchCache.size - 50);
    oldest.forEach(([k]) => searchCache.delete(k));
  }
}

// In-memory chunk assembly store
const chunkStore = new Map();

function textResponse(text) {
  return { content: [{ type: 'text', text }] };
}

function errorResponse(text) {
  return { content: [{ type: 'text', text }], isError: true };
}

// ─── Server Setup ───────────────────────────────────────────

const server = new Server(
  { name: 'openclaw-memory', version: '2.0.0' },
  { capabilities: { tools: {} } }
);

// ─── Tool Definitions ───────────────────────────────────────

server.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: [
    // ── Read Tools ──
    {
      name: 'memory_search',
      description: 'Semantic search across the agent\'s memory, daily logs, session transcripts, and skills. Uses hybrid search (70% semantic + 30% keyword). Results are cached for 5 minutes.',
      inputSchema: {
        type: 'object',
        properties: {
          query: { type: 'string', description: 'Search query — can be a question, topic, or concept' },
          max_results: { type: 'number', description: 'Maximum results (default: 5)', default: 5 },
        },
        required: ['query'],
      },
    },
    {
      name: 'memory_read',
      description: 'Read a specific memory file. Use relative paths from the workspace root.',
      inputSchema: {
        type: 'object',
        properties: {
          path: { type: 'string', description: 'Relative path (e.g., "memory/infrastructure.md", "MEMORY.md")' },
        },
        required: ['path'],
      },
    },
    {
      name: 'skill_list',
      description: 'List all available skills with titles and types (hand-crafted or auto-captured).',
      inputSchema: { type: 'object', properties: {} },
    },
    {
      name: 'skill_read',
      description: 'Read a specific skill document by its slug (directory name).',
      inputSchema: {
        type: 'object',
        properties: {
          slug: { type: 'string', description: 'Skill slug (directory name under skills/)' },
        },
        required: ['slug'],
      },
    },
    {
      name: 'memory_grep',
      description: 'Exact keyword search across memory files and skills. Returns matching file paths.',
      inputSchema: {
        type: 'object',
        properties: {
          keyword: { type: 'string', description: 'Keyword (case-insensitive)' },
          scope: { type: 'string', enum: ['all', 'memory', 'skills'], default: 'all' },
        },
        required: ['keyword'],
      },
    },

    // ── Write Tools ──
    {
      name: 'memory_candidate',
      description: 'Submit candidate memory facts to the daily log. Use tagged bullets: [DECISION], [TECHNICAL], [BUSINESS], [PREFERENCE], [RULE], [PROJECT].',
      inputSchema: {
        type: 'object',
        properties: {
          facts: {
            type: 'array',
            items: { type: 'string' },
            description: 'Array of tagged fact strings',
          },
          source: { type: 'string', description: 'Source identifier', default: 'claude-code-remote' },
        },
        required: ['facts'],
      },
    },
    {
      name: 'session_submit',
      description: 'Submit a complete session transcript (for small sessions < 200KB). For larger sessions, use the chunked upload tools instead.',
      inputSchema: {
        type: 'object',
        properties: {
          session_id: { type: 'string', description: 'Session ID' },
          transcript: { type: 'string', description: 'Full session transcript as JSONL text' },
        },
        required: ['session_id', 'transcript'],
      },
    },
    {
      name: 'session_chunk_start',
      description: 'Start a chunked session upload. Use this for large transcripts that exceed MCP message limits. Follow with session_chunk calls, then session_chunk_finish.',
      inputSchema: {
        type: 'object',
        properties: {
          session_id: { type: 'string', description: 'Session ID' },
          total_chunks: { type: 'number', description: 'Expected number of chunks' },
        },
        required: ['session_id', 'total_chunks'],
      },
    },
    {
      name: 'session_chunk',
      description: 'Send one chunk of a session transcript. Chunks are reassembled in order on the server.',
      inputSchema: {
        type: 'object',
        properties: {
          session_id: { type: 'string', description: 'Session ID (must match session_chunk_start)' },
          chunk_index: { type: 'number', description: 'Chunk index (0-based)' },
          content: { type: 'string', description: 'Chunk content (JSONL fragment)' },
        },
        required: ['session_id', 'chunk_index', 'content'],
      },
    },
    {
      name: 'session_chunk_finish',
      description: 'Finalize a chunked upload and submit the reassembled transcript to the bridge.',
      inputSchema: {
        type: 'object',
        properties: {
          session_id: { type: 'string', description: 'Session ID (must match session_chunk_start)' },
        },
        required: ['session_id'],
      },
    },
    {
      name: 'session_flag',
      description: 'Flag a session for priority skill capture (bypasses heuristic gates).',
      inputSchema: {
        type: 'object',
        properties: {
          session_id: { type: 'string', description: 'Session ID to flag' },
        },
        required: ['session_id'],
      },
    },

    // ── System Tools ──
    {
      name: 'health',
      description: 'Check the health of the memory integration: workspace accessibility, bridge script, gateway status, and recent activity.',
      inputSchema: { type: 'object', properties: {} },
    },
  ],
}));

// ─── Tool Handlers ──────────────────────────────────────────

server.setRequestHandler(CallToolRequestSchema, async (request) => {
  const { name, arguments: args } = request.params;

  try {
    switch (name) {

      // ── Read Tools ──

      case 'memory_search': {
        const maxResults = args.max_results || 5;
        const cached = getCachedSearch(args.query, maxResults);
        if (cached) {
          return textResponse(`[cached] ${cached}`);
        }
        const { stdout } = await execFileP(
          'openclaw',
          ['memory', 'search', args.query, '--max-results', String(maxResults)],
          { cwd: WORKSPACE, env: { ...process.env, OPENCLAW_CONFIG_PATH: CONFIG_PATH }, timeout: 30000 }
        );
        const result = stdout || 'No results found.';
        setCachedSearch(args.query, maxResults, result);
        return textResponse(result);
      }

      case 'memory_read': {
        if (!isAllowedPath(args.path)) {
          return errorResponse('Access denied. Path must be within memory/, skills/, or MEMORY.md');
        }
        try {
          const content = await readFile(join(WORKSPACE, args.path), 'utf-8');
          return textResponse(content);
        } catch {
          return errorResponse(`File not found: ${args.path}`);
        }
      }

      case 'skill_list': {
        const skillsDir = join(WORKSPACE, 'skills');
        const entries = await readdir(skillsDir, { withFileTypes: true });
        const skills = [];

        for (const entry of entries) {
          if (!entry.isDirectory() || entry.name.startsWith('.')) continue;
          const skillMd = join(skillsDir, entry.name, 'SKILL.md');
          try { await stat(skillMd); } catch { continue; }

          let title = entry.name;
          try {
            const content = await readFile(skillMd, 'utf-8');
            const match = content.match(/^#\s+(.+)$/m);
            if (match) title = match[1];
          } catch {}

          let isAuto = false;
          try {
            const meta = JSON.parse(await readFile(join(skillsDir, entry.name, '_meta.json'), 'utf-8'));
            isAuto = 'capturedFrom' in meta;
          } catch {}

          skills.push({ slug: entry.name, title, type: isAuto ? 'auto-captured' : 'hand-crafted' });
        }

        return textResponse(skills.length
          ? skills.map(s => `- **${s.title}** (\`${s.slug}\`) — ${s.type}`).join('\n')
          : 'No skills found.');
      }

      case 'skill_read': {
        if (!isAllowedPath(`skills/${args.slug}/SKILL.md`)) {
          return errorResponse('Invalid skill slug.');
        }
        try {
          return textResponse(await readFile(join(WORKSPACE, 'skills', args.slug, 'SKILL.md'), 'utf-8'));
        } catch {
          return errorResponse(`Skill not found: ${args.slug}`);
        }
      }

      case 'memory_grep': {
        const searchPaths = [];
        const scope = args.scope || 'all';
        if (scope === 'all' || scope === 'memory') searchPaths.push(join(WORKSPACE, 'memory'));
        if (scope === 'all' || scope === 'skills') searchPaths.push(join(WORKSPACE, 'skills'));

        const results = [];
        for (const p of searchPaths) {
          try {
            const { stdout } = await execFileP('grep', ['-rli', args.keyword, p], { timeout: 10000 });
            results.push(...stdout.trim().split('\n').filter(Boolean).map(f => relative(WORKSPACE, f)));
          } catch { /* grep returns 1 on no match */ }
        }

        return textResponse(results.length
          ? `Found ${results.length} file(s):\n${results.map(f => `- ${f}`).join('\n')}`
          : 'No matches found.');
      }

      // ── Write Tools ──

      case 'memory_candidate': {
        const facts = args.facts;
        const source = args.source || 'claude-code-remote';
        if (!Array.isArray(facts) || facts.length === 0) {
          return errorResponse('facts must be a non-empty array.');
        }
        const today = new Date().toISOString().slice(0, 10);
        const time = new Date().toISOString().slice(11, 16);
        const dailyLog = join(WORKSPACE, 'memory', `${today}.md`);
        const header = `\n## Memory Candidate — ${source} (${time} UTC)\n`;
        const entries = facts.map(f => `- ${f}`).join('\n');
        await appendFile(dailyLog, header + entries + '\n');
        return textResponse(`Appended ${facts.length} fact(s) to ${today}.md`);
      }

      case 'session_submit': {
        const { session_id, transcript } = args;
        if (!session_id || !transcript) return errorResponse('session_id and transcript required.');

        const tmpPath = join(WORKSPACE, 'logs', `.mcp-session-${session_id.substring(0, 8)}.jsonl`);
        await writeFile(tmpPath, transcript);

        try {
          const hookInput = JSON.stringify({ session_id, transcript_path: tmpPath });
          const escaped = hookInput.replace(/'/g, "'\\''");
          const { stdout } = await execP(
            `echo '${escaped}' | python3 "${join(WORKSPACE, 'scripts', 'claude-code-bridge.py')}"`,
            { cwd: WORKSPACE, timeout: 120000 }
          );
          await unlink(tmpPath).catch(() => {});
          return textResponse(stdout || 'Session submitted to bridge.');
        } catch (err) {
          await unlink(tmpPath).catch(() => {});
          return errorResponse(`Bridge error: ${err.message}`);
        }
      }

      case 'session_chunk_start': {
        const { session_id, total_chunks } = args;
        if (!session_id || !total_chunks) return errorResponse('session_id and total_chunks required.');

        await mkdir(CHUNK_DIR, { recursive: true });
        chunkStore.set(session_id, {
          total: total_chunks,
          received: new Set(),
          startedAt: Date.now(),
        });
        return textResponse(`Chunked upload started for ${session_id} (expecting ${total_chunks} chunks).`);
      }

      case 'session_chunk': {
        const { session_id, chunk_index, content } = args;
        if (!session_id || chunk_index === undefined || !content) {
          return errorResponse('session_id, chunk_index, and content required.');
        }

        const session = chunkStore.get(session_id);
        if (!session) return errorResponse(`No chunked upload in progress for ${session_id}. Call session_chunk_start first.`);

        // Write chunk to disk
        const chunkPath = join(CHUNK_DIR, `${session_id}-${String(chunk_index).padStart(4, '0')}.chunk`);
        await writeFile(chunkPath, content);
        session.received.add(chunk_index);

        return textResponse(`Chunk ${chunk_index + 1}/${session.total} received (${session.received.size}/${session.total} total).`);
      }

      case 'session_chunk_finish': {
        const { session_id } = args;
        const session = chunkStore.get(session_id);
        if (!session) return errorResponse(`No chunked upload for ${session_id}.`);

        // Verify all chunks received
        const missing = [];
        for (let i = 0; i < session.total; i++) {
          if (!session.received.has(i)) missing.push(i);
        }
        if (missing.length > 0) {
          return errorResponse(`Missing chunks: ${missing.join(', ')}. Send them before finishing.`);
        }

        // Reassemble transcript
        const tmpPath = join(WORKSPACE, 'logs', `.mcp-session-${session_id.substring(0, 8)}.jsonl`);
        let transcript = '';
        for (let i = 0; i < session.total; i++) {
          const chunkPath = join(CHUNK_DIR, `${session_id}-${String(i).padStart(4, '0')}.chunk`);
          transcript += await readFile(chunkPath, 'utf-8');
          await unlink(chunkPath).catch(() => {});
        }
        await writeFile(tmpPath, transcript);
        chunkStore.delete(session_id);

        // Feed through bridge
        try {
          const hookInput = JSON.stringify({ session_id, transcript_path: tmpPath });
          const escaped = hookInput.replace(/'/g, "'\\''");
          const { stdout } = await execP(
            `echo '${escaped}' | python3 "${join(WORKSPACE, 'scripts', 'claude-code-bridge.py')}"`,
            { cwd: WORKSPACE, timeout: 120000 }
          );
          await unlink(tmpPath).catch(() => {});
          return textResponse(`Reassembled ${session.total} chunks and submitted. ${stdout || ''}`);
        } catch (err) {
          await unlink(tmpPath).catch(() => {});
          return errorResponse(`Bridge error after reassembly: ${err.message}`);
        }
      }

      case 'session_flag': {
        const flagPath = `/tmp/agent-priority-${(args.session_id || 'manual').substring(0, 8)}`;
        await writeFile(flagPath, `flagged at ${new Date().toISOString()}\n`);
        return textResponse(`Priority flag created: ${flagPath}`);
      }

      // ── System Tools ──

      case 'health': {
        const checks = [];
        let pass = 0, fail = 0;

        // Workspace accessible
        if (existsSync(WORKSPACE)) { checks.push('[OK] Workspace accessible'); pass++; }
        else { checks.push('[!!] Workspace not accessible'); fail++; }

        // Bridge script
        if (existsSync(join(WORKSPACE, 'scripts', 'claude-code-bridge.py'))) { checks.push('[OK] Bridge script present'); pass++; }
        else { checks.push('[!!] Bridge script missing'); fail++; }

        // MEMORY.md
        if (existsSync(join(WORKSPACE, 'MEMORY.md'))) { checks.push('[OK] MEMORY.md present'); pass++; }
        else { checks.push('[!!] MEMORY.md missing'); fail++; }

        // Skills directory
        try {
          const skills = await readdir(join(WORKSPACE, 'skills'), { withFileTypes: true });
          const skillCount = skills.filter(e => e.isDirectory() && !e.name.startsWith('.')).length;
          checks.push(`[OK] ${skillCount} skill directories`); pass++;
        } catch { checks.push('[!!] Skills directory not accessible'); fail++; }

        // Skill extractor
        if (existsSync(join(WORKSPACE, 'extensions', 'auto-skill-capture', 'scripts', 'skill-extractor.py'))) {
          checks.push('[OK] Skill extractor present'); pass++;
        } else { checks.push('[!!] Skill extractor missing'); fail++; }

        // Gateway health
        try {
          const port = JSON.parse(await readFile(join(WORKSPACE, 'openclaw.json'), 'utf-8')).gateway?.port;
          if (port) {
            const { stdout } = await execP(`curl -s -m 5 http://localhost:${port}/health`, { timeout: 10000 });
            if (stdout && stdout.includes('ok')) { checks.push(`[OK] Gateway healthy (port ${port})`); pass++; }
            else { checks.push(`[WARN] Gateway responded but status unclear (port ${port})`); }
          }
        } catch { checks.push('[WARN] Could not check gateway health'); }

        // Bridge log recency
        const logPath = join(WORKSPACE, 'logs', 'claude-code-bridge.jsonl');
        if (existsSync(logPath)) {
          try {
            const logStat = await stat(logPath);
            const ageHours = (Date.now() - logStat.mtimeMs) / 3600000;
            checks.push(`[OK] Bridge log last updated ${ageHours.toFixed(1)}h ago`); pass++;
          } catch { checks.push('[WARN] Could not read bridge log'); }
        } else { checks.push('[INFO] No bridge log yet (no sessions captured)'); }

        // Toolkit version
        const versionPath = join(WORKSPACE, '.toolkit-version');
        if (existsSync(versionPath)) {
          const version = (await readFile(versionPath, 'utf-8')).trim();
          checks.push(`[OK] Toolkit version: ${version}`); pass++;
        }

        // OpenClaw version
        try {
          const { stdout } = await execP('openclaw --version 2>/dev/null || echo "unknown"', { timeout: 5000 });
          checks.push(`[INFO] OpenClaw version: ${stdout.trim()}`);
        } catch {}

        // Claude Code version
        try {
          const { stdout } = await execP('claude --version 2>/dev/null || echo "unknown"', { timeout: 5000 });
          checks.push(`[INFO] Claude Code version: ${stdout.trim()}`);
        } catch {}

        const summary = `Health check: ${pass} passed, ${fail} failed\n\n${checks.join('\n')}`;
        return fail > 0 ? errorResponse(summary) : textResponse(summary);
      }

      default:
        return errorResponse(`Unknown tool: ${name}`);
    }
  } catch (error) {
    return errorResponse(`Error: ${error.message}`);
  }
});

// ─── Start Server ───────────────────────────────────────────

const transport = new StdioServerTransport();
await server.connect(transport);
