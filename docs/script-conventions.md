# Script conventions

Conventions used by every script in this repository, so a check behaves the
same way from SQL Server Agent, from sqlcmd, or by hand in SSMS.

## T-SQL scripts

- Read-only. Administrative scripts in this repo query DMVs, catalog views,
  and msdb history. A script that changes state would say so in its name and
  its header, prominently.
- A header comment states the purpose, the exact invocation, thresholds,
  compatibility, and the permissions required.
- Thresholds are DECLARE variables at the top of the script, never constants
  buried inside queries. Tune the DECLARE; do not edit the logic.
- `SET NOCOUNT ON` at the top so row-count messages do not pollute output
  captured by Agent or a calling script.
- Output sections are separated with PRINT banners, and each section says
  what it reads, so captured output explains itself later.
- Findings are labeled as facts plus a judgment aid (`OK`, `STALE`,
  `OVERDUE`). The script reports; the DBA decides. A flagged database in
  SIMPLE recovery is information, not an alarm.
- Never embed credentials, server names, or environment-specific values.
  Connection details belong to the sqlcmd or Agent invocation.

## Testing honesty

- Scripts are labeled in their headers and in the README when they have not
  been executed against a live instance. Syntax and logic review is not
  execution, and this repo does not blur that line.
- When a script is first run against a real instance, note the version and
  edition in the commit message and adjust the header if behavior differs
  from the documentation.
