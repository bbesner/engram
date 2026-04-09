# Daily Log Indexing Task

You are indexing daily log files into long-term vector memory so their content becomes semantically searchable.

## Steps

1. **Read the index state file:**
   Read `{{WORKSPACE}}/memory/.indexed-files.json`.
   If it doesn't exist, create it with content: `{"indexed":{}}`

2. **List daily log files:**
   List all files in `{{WORKSPACE}}/memory/` that match the pattern `YYYY-MM-DD.md` (e.g., `2026-02-03.md`).

3. **Determine which files need indexing:**
   For each file, check if it appears in `.indexed-files.json`:
   - If the file is NOT in the indexed list → index it
   - If the file IS in the indexed list but the file's modification time is newer than the stored timestamp → re-index it
   - Otherwise → skip it

   To check modification time, use `ls -l --time-style=+%s` on the file.

4. **For each file that needs indexing:**

   a. Read the file contents.

   b. Split into sections by `##` headings. Each section includes the heading and all text until the next `##` heading or end of file. Skip sections with fewer than 50 characters of content.

   c. For each section, detect the domain tag by scanning the section text for keywords:
      - `[financial]` — contains: $, dollar, invoice, revenue, A/R, A/P, payment, budget, cost, sales order, quote, estimate, overdue
      - `[technical]` — contains: server, API, config, deploy, code, script, plugin, port, SSH, bug, error, debug, database, webhook
      - `[business]` — contains: CRM, deal, pipeline, customer, client, helpdesk, ticket, account
      - `[personal]` — contains: family, birthday, personal, owner, preferences
      - `[general]` — default if no keywords match

   d. Call `memory_store` with:
      - `text`: `[domain] YYYY-MM-DD: <section heading> — <section content summarized to ~200 characters>`
      - `category`: `"fact"`
      - `importance`: `0.6`

      The date should come from the filename. Summarize the section content concisely — capture the key facts, not every detail.

   e. After processing all sections in a file, update `.indexed-files.json` to record:
      ```json
      {
        "indexed": {
          "2026-02-03.md": { "timestamp": 1738627200, "sections": 5 }
        }
      }
      ```
      Use the current Unix timestamp.

5. **Write the updated `.indexed-files.json` back to disk.**

6. **Report results:**
   Log how many files were processed and how many total sections were stored to memory.
   Example: "Indexed 3 files, stored 12 sections to vector memory."

## Important Notes

- Do NOT write directly to LanceDB. Always use the `memory_store` tool.
- If `memory_store` reports a duplicate ("Similar memory already exists"), skip that section and continue.
- Keep summaries informative but concise. Include dates, names, and numbers when present.
- Process files in chronological order (oldest first).
