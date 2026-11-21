# SQL Server security review

`tsql/security_review.sql` is the login, user, and role review to run when
you take over an instance, before an audit, or after a restore from
another instance. It reads the server and database catalog views and
reports the security surface in eight sections: which logins exist, who
holds the powerful server roles and permissions, whether SQL logins
enforce password policy, which database users are orphaned, who sits in
the privileged database roles, which users hold dangerous database-level
grants, and where the guest user or the public role can connect.

Run it by hand when you take over an instance, and schedule it as its
own Agent job with output to a file or to the job history so the review
itself is covered by the same monitoring it performs. The script is
read-only; it changes nothing, and it never reads password hashes.

## What each section means

### 1. Server login inventory

Every server principal that can authenticate: SQL logins, Windows
logins and groups, Microsoft Entra logins and groups where Entra
authentication is configured, and certificate and key-mapped logins.
Server roles are not listed here; they are section 2.

For SQL logins the inventory also shows whether password policy and
password expiration are enforced and whether the login is locked.
Those columns are NULL for the other login types because they do not
apply there.

A disabled login cannot connect, but it still owns objects, jobs, and
databases, so do not remove a disabled login until section 2 says
nothing still depends on it. A login created months ago and never
modified is not automatically a problem, but it is worth asking who
uses it.

### 2. Server role membership, and databases owned by a missing or disabled login

The first query lists every member of every server role, fixed and
custom. sysadmin is full control of the instance. securityadmin can
manage logins and change passwords, which is enough to reset the sa
password and log in as sa. serveradmin can change server settings and shut the
instance down. dbcreator can create and alter databases. A member
listed as disabled keeps the membership while it cannot connect;
remove the membership if the login is gone for good.

The second query lists databases whose owner login no longer exists
or is disabled. The database still runs, but ownership-dependent
behavior no longer resolves the way it was intended. Point the
database at a current login with
`ALTER AUTHORIZATION ON DATABASE::<database> TO <login>`. This
commonly follows a restore: the database arrives with its old owner,
and the owner login was never created on the new instance. An empty
result means every database owner resolves and is enabled.

### 3. Server-scope permissions

Three queries, each covering a different way server access spreads.

The first lists powerful server-scope permissions granted to any
login or role: CONTROL SERVER, ALTER ANY LOGIN, ALTER ANY DATABASE,
and the rest of the list in the script. CONTROL SERVER is effectively
sysadmin without the role membership, and ALTER ANY LOGIN can reset
the sa password and log in as sa, so either one on a non-DBA login is worth questioning.
VIEW SERVER STATE, VIEW ANY DATABASE, and VIEW ANY DEFINITION are
the visibility grants a monitoring login is expected to hold; the
rest of the list on a non-DBA login is the thing to look at. The
default VIEW ANY DATABASE grant to public is excluded here and
reported in the next query instead.

The second query lists every server-scope permission granted to
public. A grant to public reaches every login on the instance. VIEW
ANY DATABASE to public is the default and is expected; anything else
here deserves a reason.

The third query covers impersonation on logins and any server grant
made WITH GRANT OPTION. IMPERSONATE on a privileged login lets the
grantee act as that login, which is how a junior login can quietly
gain a senior login's reach. A grant WITH GRANT OPTION lets the
grantee pass the permission on, which is how a single grant spreads
beyond the person it was given to.

### 4. SQL login password policy

The first query lists SQL logins with a password policy gap: policy
not enforced, expiration not checked, the login locked, or the
password expiring within the threshold (default 30 days, set at the
top of the script). A SQL login with password policy off can hold a
weak password that never expires.

Password policy enforcement only applies when the Windows password
policy is in effect on the host. On a host without one,
is_policy_checked reports 1 but enforces nothing, so check the host
policy too before concluding a login is protected. A locked login is
usually the result of failed logon attempts; find out why it locked
before unlocking it.

The second query reports the sa login specifically. sa is the
best-known login name on any instance. If it is enabled, it needs a
strong password and a reason to be enabled. Renaming sa does not
remove the risk by itself; disabling it does, as long as another
sysadmin login exists first.

### 5. Orphaned users

A database user is orphaned when it is mapped to a server login
(instance, Windows, or Entra authentication) whose SID no longer
exists in sys.server_principals. The section lists orphaned users in
every ONLINE database.

The usual fix is to remap the user to a current login:

```sql
ALTER USER <user> WITH LOGIN = <login>;
```

Or drop the user if nothing needs it. The most common cause is a
database restored from another instance: the users come with the
backup, the logins do not. Contained database users have no server
login by design and are not flagged here. An empty result means no
orphaned users were found.

### 6. Privileged database role membership

Members of db_owner, db_securityadmin, db_accessadmin, db_ddladmin,
and db_backupoperator in every ONLINE database. db_owner is full
control of that database. db_securityadmin can manage users and
roles in the database. db_accessadmin can add and remove users.
db_ddladmin can create and alter objects. db_backupoperator can back
the database up.

dbo appears in db_owner for every database; that is normal, not a
finding. Anyone else in db_owner or db_securityadmin is worth a
second look, especially an application login or a login that belongs
to a person who no longer works on that database.

### 7. Dangerous database-level grants

Direct grants of CONTROL, ALTER, ALTER ANY USER, ALTER ANY ROLE,
ALTER ANY SCHEMA, TAKE OWNERSHIP, BACKUP DATABASE, and BACKUP LOG
to individual users, plus any grant made WITH GRANT OPTION, plus
IMPERSONATE, CONTROL, TAKE OWNERSHIP, and ALTER on database
principals. CONTROL on a database is effectively db_owner without
the role membership. ALTER ANY USER and ALTER ANY ROLE let the
grantee reshape who can use the database. IMPERSONATE on a user lets
the grantee act as that user.

Role membership is not listed here; section 6 covers it. A user can
hold a dangerous permission either directly or through a role, and
this section only shows the direct grants, so read the two sections
together. An empty result means no user holds a grant in these
categories.

### 8. Guest and public access

Database-scope permissions held by the guest user or the public role
in every ONLINE database. The guest user is disabled by default: it
has no CONNECT permission unless someone granted it. A guest CONNECT
row means any login can reach that database without a user of its
own. A public CONNECT row has the same effect.

Either one is usually a leftover from a restore or a demo, not an
intended design. The fix is to revoke the grant:

```sql
USE <database>;
REVOKE CONNECT FROM guest;
```

An empty result means guest and public hold no database-scope grants
anywhere.

## Fixing what it finds

| Finding | Fix |
|---|---|
| Orphaned user | `ALTER USER <user> WITH LOGIN = <login>`, or drop the user |
| Login in sysadmin that should not be there | `ALTER SERVER ROLE sysadmin DROP MEMBER <login>` |
| User in db_owner that should not be there | `ALTER ROLE db_owner DROP MEMBER <user>` in that database |
| Dangerous direct grant | `REVOKE <permission> FROM <user>` in that database, or `DENY` if the grant comes from a role and must be blocked |
| Grant WITH GRANT OPTION that should not spread | `REVOKE <permission> FROM <user> CASCADE` to pull back grants the user passed on |
| IMPERSONATE on a privileged login | `REVOKE IMPERSONATE ON LOGIN::<login> FROM <grantee>` |
| SQL login with password policy off | `ALTER LOGIN <login> WITH CHECK_POLICY = ON` (and CHECK_EXPIRATION = ON where it applies) |
| sa enabled without a reason | Disable it after confirming another sysadmin login exists |
| Database owned by a missing login | `ALTER AUTHORIZATION ON DATABASE::<database> TO <login>` |
| Guest or public can connect | `REVOKE CONNECT FROM guest` or `REVOKE CONNECT FROM public` in that database |

The older procedures sp_addsrvrolemember, sp_dropsrvrolemember,
sp_addrolemember, and sp_droprolemember are deprecated; the ALTER
ROLE and ALTER SERVER ROLE forms above are the current way. The
sp_change_users_login procedure for orphaned users is deprecated as
well; ALTER USER ... WITH LOGIN is the replacement.

Revoke with care on a database you do not know well: a grant that
looks excessive may be the reason an application works. Check what
breaks in a test environment first, or revoke during a maintenance
window and watch for failures.

## Scheduling this check

Schedule `security_review.sql` as its own Agent job, weekly or
monthly, with the output written to a file or captured in the job
history. Give the job a failure notification, and keep the captured
output: a review is most useful as a comparison, because a new login
or a new db_owner member stands out against last month's run in a
way it never does on its own.

The password expiry threshold at the top of the script defaults to 30
days. Shorten it if logins are expected to rotate on a tighter cycle,
or lengthen it if the review runs monthly and you want the warning
before the next run.

## Troubleshooting

| Symptom | Likely cause | First check |
|---|---|---|
| A section returns fewer rows than expected | The login running the script cannot see the catalog views it reads | Run as sysadmin, or grant VIEW ANY DEFINITION and VIEW SERVER STATE; the script header explains the visibility rule |
| A database is skipped with a note | The login cannot read that database, or it is not ONLINE | The database state and the login's access to it |
| Every database shows dbo in db_owner | Normal | dbo is a member of db_owner in every database by design |
| A user shows as orphaned right after a restore | The logins were not recreated on this instance | Section 5; remap or drop the users |
| A monitoring login appears in section 3 | Expected for VIEW SERVER STATE and VIEW ANY DEFINITION | Confirm the login is the monitoring login and nothing else is granted to it |
| A section is empty on RDS SQL Server | RDS has no sysadmin and the master user holds a subset of server roles | `docs/aws-hosted-sql-server.md`; some server-level findings do not apply on RDS |

## Relationship to the other scripts

Agent jobs are a common place for a stale owner to hide, and this
script pairs with `tsql/agent_job_health.sql`, which reports jobs
whose owner login no longer resolves. A login removed from the
instance leaves both: orphaned database users in this script, and
jobs with an unresolvable owner in that one. Run them together when
a person leaves or a service account is retired.

Backup verification (`tsql/backup_verification.sql`) and log shipping
(`tsql/log_shipping_status.sql`) depend on Agent jobs and on the
logins those jobs run as; a job that fails because its owner login
was disabled shows up in the Agent job health script first, and the
reason shows up here.

## What the script does not cover

Object-level grants (EXECUTE on a procedure, SELECT on a table) are
not listed; section 7 covers database-scope grants only. If an
application login holds SELECT on every table through a role, that
is section 6 territory, not this script. Server audit configuration
and SQL Server Audit are also out of scope: this script reports who
can do what, not whether the activity is being recorded. Endpoint
permissions (CONNECT on the TSQL endpoint, for example) are not
listed either; they rarely change and are covered by the server
permissions catalog view if you need them.
