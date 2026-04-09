# Legacy Memory Curation Task

This prompt is retained for manual backfill or historical reference only.
Built-in memory-core Dreaming is now the active consolidation and promotion path.

You are performing a manual memory curation pass. Your job is to review recent daily notes and distill important insights into long-term memory.

## Steps

1. **Read current long-term memory:**
   Read `{{WORKSPACE}}/MEMORY.md` to understand what's already stored.

2. **Identify recent daily logs:**
   List files in `{{WORKSPACE}}/memory/` matching `YYYY-MM-DD.md`.
   Select the 3 most recent files (by date in filename).

3. **Read each recent daily log file.**

4. **Extract NEW insights not already in MEMORY.md:**
   - New people, contacts, phone numbers, email addresses
   - New business decisions or preferences the user expressed
   - New tools, services, or integrations set up
   - Important technical changes, configurations, or architecture decisions
   - Security policies or access rules
   - New projects, recurring tasks, or workflow changes
   - Lessons learned, bugs fixed, or mistakes to avoid
   - Key financial figures, metrics, or thresholds

5. **Append a new dated section to MEMORY.md:**
   Use this format at the end of the file:
   ```
   ## Memory Curation — YYYY-MM-DD

   - Bullet point for each new insight
   - Keep entries concise — one line each
   - Include enough context to be useful months later
   ```

6. **Store the 2-3 most important new facts in vector memory:**
   Use `memory_store` for each, with these guidelines:
   - Prefix text with a domain tag: `[financial]`, `[technical]`, `[business]`, `[personal]`, or `[general]`
   - Set `category` to the most appropriate value: `preference`, `fact`, `decision`, `entity`, or `other`
   - Set `importance` based on how critical the info is (0.5 = routine, 0.7 = useful, 0.9 = critical)

   Domain tag detection:
   - `[financial]` — dollar amounts, invoices, revenue, A/R, A/P, payments, budgets, costs
   - `[technical]` — servers, APIs, configs, deployments, code, scripts, plugins, ports, SSH
   - `[business]` — CRM, deals, pipeline, customers, clients, accounts, helpdesk
   - `[personal]` — the owner, family, birthdays, personal preferences, health
   - `[general]` — anything that doesn't fit the above

7. **Skip routine operational noise:**
   - "No new emails", "HEARTBEAT_OK", "briefing sent successfully"
   - Repeated information already captured
   - Temporary debugging notes

## Output

Log a brief summary of what was added to MEMORY.md and how many facts were stored to vector memory. If no new insights were found, say so. Do NOT send a Telegram message unless something critically important was discovered.
