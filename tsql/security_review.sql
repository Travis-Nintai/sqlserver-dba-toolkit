/* ============================================================================
   security_review.sql -- SQL Server login, user, and role security review

   Purpose:
     Report the security surface of a SQL Server instance the way a DBA
     reviews it when taking over an instance or preparing for an audit:
     which logins exist and whether they are disabled, who holds the
     powerful server roles and server-scope permissions, whether SQL
     logins enforce password policy and expiration, which database
     users are orphaned after a login was dropped, who sits in the
     privileged database roles, which users hold dangerous
     database-level grants or grants with grant option, and where the
     guest user or the public role can connect.

     The script reports facts and flags the rows that need a judgment
     call. A finding is not automatically a problem: a monitoring
     login is expected to hold VIEW SERVER STATE, and dbo is expected
     to be a member of db_owner in every database. Each section says
     what to check before acting.

   Usage (sqlcmd):
     sqlcmd -S <server> -E -i security_review.sql

   Thresholds (DECLARE variables below):
     @PasswordExpiryWarnDays  Flag a SQL login whose password expires
                               within this many days. Default 30.

   Compatibility:
     SQL Server 2016 or later. Reviewed against the documented catalog
     views (sys.server_principals, sys.sql_logins,
     sys.server_role_members, sys.server_permissions,
     sys.database_principals, sys.database_role_members,
     sys.database_permissions, sys.databases) and LOGINPROPERTY.
     Microsoft Entra principals (type E and X, authentication type 4)
     appear on instances with Entra authentication configured and are
     included in the same checks; the script does not assume Entra.
     Not executed against a live SQL Server instance during
     development; see the README testing status.

   Requires:
     sysadmin, or VIEW ANY DEFINITION and VIEW SERVER STATE, for full
     coverage. Catalog views only show a login the securables it owns
     or has been granted some permission on, so a login with less
     access sees a partial picture; the script still runs and reports
     what is visible. Per-database sections loop over ONLINE databases
     and skip any database the login cannot read, with a note.

   Notes:
     - An orphaned user is a database user mapped to a server login
       (instance, Windows, or Entra authentication) whose SID no
       longer exists in sys.server_principals. Contained database
       users have no server login by design and are not flagged.
       The usual fix is ALTER USER <user> WITH LOGIN = <login>;
       sp_change_users_login is deprecated and is not used here.
     - The script never reads password hashes. sys.sql_logins has a
       password_hash column; this script does not select it.
     - Server role membership is reported for the fixed roles and for
       any custom server roles. Membership changes use ALTER SERVER
       ROLE ... ADD MEMBER / DROP MEMBER; the sp_addsrvrolemember
       and sp_dropsrvrolemember procedures are deprecated.
     - Database role membership changes use ALTER ROLE ... ADD MEMBER
       / DROP MEMBER; sp_addrolemember and sp_droprolemember are
       deprecated.
     - On RDS SQL Server there is no sysadmin, the master user holds
       a subset of server roles, and some principals are RDS managed
       (rdsadmin). Expect the server role and CONTROL SERVER sections
       to look different there; see docs/aws-hosted-sql-server.md.

   Safety:
     Read-only.
   ============================================================================ */

SET NOCOUNT ON;

DECLARE @PasswordExpiryWarnDays int = 30;

PRINT '================================================================';
PRINT ' SQL Server security review';
PRINT ' Server        : ' + @@SERVERNAME;
PRINT ' Password expiry warning: ' + CAST(@PasswordExpiryWarnDays AS nvarchar(10))
      + ' days';
PRINT '================================================================';
PRINT '';

/* ----------------------------------------------------------------------
   1. Server login inventory
   ---------------------------------------------------------------------- */
PRINT '-- Server login inventory ----------------------------------------';

SELECT  sp.name AS login_name,
        sp.type_desc,
        sp.is_disabled,
        sp.create_date,
        sp.modify_date,
        sp.default_database_name,
        sl.is_policy_checked AS password_policy_enforced,
        sl.is_expiration_checked AS password_expiration_checked,
        sl.is_locked
FROM sys.server_principals AS sp
LEFT JOIN sys.sql_logins AS sl
  ON sl.principal_id = sp.principal_id
WHERE sp.type IN ('S', 'U', 'G', 'E', 'X', 'C', 'K')
ORDER BY sp.type_desc, sp.name;

PRINT '';
PRINT 'A disabled login cannot connect, but it still owns objects, jobs,';
PRINT 'and databases. Check disabled logins against section 2 before';
PRINT 'removing one. Password policy columns are NULL for Windows,';
PRINT 'Entra, certificate, and key-mapped logins; they apply to SQL';
PRINT 'logins only.';

/* ----------------------------------------------------------------------
   2. Server role membership, and databases owned by a missing or
      disabled login
   ---------------------------------------------------------------------- */
PRINT '';
PRINT '-- Server role membership ----------------------------------------';

SELECT  r.name AS role_name,
        CASE WHEN r.is_fixed_role = 1 THEN 'FIXED' ELSE 'CUSTOM' END
                                                   AS role_kind,
        m.name AS member_name,
        m.type_desc AS member_type,
        m.is_disabled AS member_disabled
FROM sys.server_role_members AS srm
JOIN sys.server_principals AS r
  ON r.principal_id = srm.role_principal_id
JOIN sys.server_principals AS m
  ON m.principal_id = srm.member_principal_id
ORDER BY r.name, m.name;

PRINT '';
PRINT 'sysadmin is full control of the instance. securityadmin can';
PRINT 'manage logins and change passwords; serveradmin can change';
PRINT 'server settings and shut the instance down; dbcreator can create';
PRINT 'and alter databases. A member listed as disabled keeps the';
PRINT 'membership while it cannot connect; remove the membership if';
PRINT 'the login is gone for good.';

PRINT '';
PRINT '-- Databases owned by a missing or disabled login --------------';

SELECT  d.name AS database_name,
        SUSER_SNAME(d.owner_sid) AS owner_login,
        CASE WHEN SUSER_SNAME(d.owner_sid) IS NULL
             THEN 'OWNER LOGIN MISSING'
             WHEN sp.is_disabled = 1
             THEN 'OWNER LOGIN DISABLED'
             ELSE 'OK' END AS status
FROM sys.databases AS d
LEFT JOIN sys.server_principals AS sp
  ON sp.sid = d.owner_sid
WHERE SUSER_SNAME(d.owner_sid) IS NULL
   OR sp.is_disabled = 1
ORDER BY d.name;

PRINT '';
PRINT 'A database whose owner login is missing or disabled still runs,';
PRINT 'but ownership-dependent operations (such as TRUSTWORTHY behavior';
PRINT 'and some cross-database access) no longer resolve the way they';
PRINT 'were intended. Point the database at a current login with';
PRINT 'ALTER AUTHORIZATION ON DATABASE::<database> TO <login>.';
PRINT 'An empty result means every database owner resolves and is';
PRINT 'enabled.';

/* ----------------------------------------------------------------------
   3. Server-scope permissions
   ---------------------------------------------------------------------- */
PRINT '';
PRINT '-- Powerful server-scope permissions ---------------------------';

SELECT  p.permission_name,
        p.state_desc,
        sp.name AS grantee,
        sp.type_desc AS grantee_type,
        g.name AS granted_by
FROM sys.server_permissions AS p
JOIN sys.server_principals AS sp
  ON sp.principal_id = p.grantee_principal_id
LEFT JOIN sys.server_principals AS g
  ON g.principal_id = p.grantor_principal_id
WHERE p.class = 100
  AND p.permission_name IN (
        'CONTROL SERVER',
        'ALTER ANY LOGIN',
        'ALTER ANY DATABASE',
        'ALTER ANY ENDPOINT',
        'ALTER ANY LINKED SERVER',
        'ALTER ANY CREDENTIAL',
        'ALTER ANY AVAILABILITY GROUP',
        'ALTER ANY SERVER AUDIT',
        'ALTER ANY EVENT SESSION',
        'ALTER ANY CONNECTION',
        'ALTER SERVER STATE',
        'ALTER TRACE',
        'ALTER RESOURCES',
        'ALTER SETTINGS',
        'ALTER ANY SERVER ROLE',
        'SHUTDOWN',
        'AUTHENTICATE SERVER',
        'IMPERSONATE ANY LOGIN',
        'CREATE ANY DATABASE',
        'UNSAFE ASSEMBLY',
        'EXTERNAL ACCESS ASSEMBLY',
        'VIEW SERVER STATE',
        'VIEW ANY DATABASE',
        'VIEW ANY DEFINITION')
  AND NOT (sp.name = 'public' AND p.permission_name = 'VIEW ANY DATABASE')
ORDER BY p.permission_name, sp.name;

PRINT '';
PRINT 'CONTROL SERVER is effectively sysadmin without the role';
PRINT 'membership. ALTER ANY LOGIN can reset the sa password and';
PRINT 'log in as sa. VIEW SERVER STATE, VIEW ANY DATABASE, and VIEW';
PRINT 'ANY DEFINITION are the visibility grants a monitoring login';
PRINT 'is expected to hold; the rest of this list on a non-DBA login';
PRINT 'is worth questioning.';

PRINT '';
PRINT '-- Server-scope permissions granted to public -------------------';

SELECT  p.permission_name,
        p.state_desc,
        g.name AS granted_by
FROM sys.server_permissions AS p
JOIN sys.server_principals AS sp
  ON sp.principal_id = p.grantee_principal_id
LEFT JOIN sys.server_principals AS g
  ON g.principal_id = p.grantor_principal_id
WHERE p.class = 100
  AND sp.name = 'public'
ORDER BY p.permission_name;

PRINT '';
PRINT 'A grant to public reaches every login on the instance. VIEW ANY';
PRINT 'DATABASE to public is the default and is expected; anything';
PRINT 'else here deserves a reason.';

PRINT '';
PRINT '-- Impersonation on logins, and server grants with grant option -';

SELECT  p.permission_name,
        p.state_desc,
        CASE p.class
            WHEN 101 THEN 'LOGIN: ' + tgt.name
            ELSE p.class_desc
        END AS securable,
        sp.name AS grantee,
        sp.type_desc AS grantee_type,
        g.name AS granted_by
FROM sys.server_permissions AS p
JOIN sys.server_principals AS sp
  ON sp.principal_id = p.grantee_principal_id
LEFT JOIN sys.server_principals AS tgt
  ON tgt.principal_id = p.major_id
 AND p.class = 101
LEFT JOIN sys.server_principals AS g
  ON g.principal_id = p.grantor_principal_id
WHERE (p.class = 101
       AND p.permission_name IN ('IMPERSONATE', 'CONTROL',
                                 'TAKE OWNERSHIP', 'ALTER'))
   OR (p.class = 100 AND p.state = 'W')
ORDER BY p.permission_name, sp.name;

PRINT '';
PRINT 'IMPERSONATE on a privileged login lets the grantee act as that';
PRINT 'login. A grant WITH GRANT OPTION lets the grantee pass the';
PRINT 'permission on, which is how a single grant quietly spreads.';

/* ----------------------------------------------------------------------
   4. SQL login password policy
   ---------------------------------------------------------------------- */
PRINT '';
PRINT '-- SQL logins with password policy gaps -------------------------';

SELECT  l.name AS login_name,
        l.is_policy_checked AS password_policy_enforced,
        l.is_expiration_checked AS password_expiration_checked,
        l.is_locked,
        LOGINPROPERTY(l.name, 'DaysUntilExpiration')
                                                   AS days_until_expiration,
        CASE WHEN l.is_policy_checked = 0
             THEN 'PASSWORD POLICY NOT ENFORCED; ' ELSE '' END
      + CASE WHEN l.is_expiration_checked = 0
             THEN 'PASSWORD EXPIRATION NOT CHECKED; ' ELSE '' END
      + CASE WHEN l.is_locked = 1
             THEN 'LOGIN LOCKED; ' ELSE '' END
      + CASE WHEN LOGINPROPERTY(l.name, 'DaysUntilExpiration') IS NOT NULL
                  AND LOGINPROPERTY(l.name, 'DaysUntilExpiration')
                      <= @PasswordExpiryWarnDays
             THEN 'PASSWORD EXPIRES SOON; ' ELSE '' END
                                                   AS findings
FROM sys.sql_logins AS l
WHERE l.is_policy_checked = 0
   OR l.is_expiration_checked = 0
   OR l.is_locked = 1
   OR (LOGINPROPERTY(l.name, 'DaysUntilExpiration') IS NOT NULL
       AND LOGINPROPERTY(l.name, 'DaysUntilExpiration')
           <= @PasswordExpiryWarnDays)
ORDER BY l.name;

PRINT '';
PRINT 'A SQL login with password policy off can hold a weak password';
PRINT 'that never expires. Policy enforcement only applies when the';
PRINT 'Windows password policy is in effect on the host; on a host';
PRINT 'without one, is_policy_checked reports 1 but enforces nothing,';
PRINT 'so check the host policy too. A locked login is usually the';
PRINT 'result of failed logon attempts; unlock it only after finding';
PRINT 'out why it locked.';

PRINT '';
PRINT '-- sa login status ------------------------------------------------';

SELECT  name AS login_name,
        is_disabled,
        is_policy_checked AS password_policy_enforced,
        is_expiration_checked AS password_expiration_checked,
        is_locked,
        CASE WHEN is_disabled = 0 THEN 'ENABLED' ELSE 'DISABLED' END
                                                   AS status
FROM sys.sql_logins
WHERE name = 'sa';

PRINT '';
PRINT 'sa is the best-known login name on any instance. If it is';
PRINT 'enabled, it needs a strong password and a reason to be enabled.';
PRINT 'Renaming sa does not remove the risk by itself; disabling it';
PRINT 'does, as long as another sysadmin login exists first.';

/* ----------------------------------------------------------------------
   Per-database sections: collect into temp tables first, because
   database-scoped catalog views need database context. Only ONLINE
   databases are read; a database the login cannot read is reported
   and skipped, not fatal.
   ---------------------------------------------------------------------- */

CREATE TABLE #OrphanedUsers (
    database_name       sysname       NOT NULL,
    user_name           sysname       NOT NULL,
    user_type           nvarchar(60)  NULL,
    authentication_type nvarchar(60)  NULL
);

CREATE TABLE #DbRoleMembers (
    database_name sysname      NOT NULL,
    role_name     sysname      NOT NULL,
    member_name   sysname      NOT NULL,
    member_type   nvarchar(60) NULL
);

CREATE TABLE #DbPerms (
    database_name  sysname        NOT NULL,
    finding        nvarchar(60)   NOT NULL,
    grantee_name   sysname        NOT NULL,
    grantee_type   nvarchar(60)   NULL,
    permission_name nvarchar(128) NULL,
    state_desc     nvarchar(60)   NULL,
    class_desc     nvarchar(60)   NULL,
    securable_name nvarchar(4000) NULL
);

CREATE TABLE #GuestAccess (
    database_name   sysname        NOT NULL,
    principal_name  sysname        NOT NULL,
    permission_name nvarchar(128) NULL,
    state_desc      nvarchar(60)   NULL,
    class_desc      nvarchar(60)   NULL
);

DECLARE @DbName sysname;
DECLARE @Sql    nvarchar(max);

DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT name
    FROM sys.databases
    WHERE state_desc = 'ONLINE';

OPEN db_cursor;
FETCH NEXT FROM db_cursor INTO @DbName;

WHILE @@FETCH_STATUS = 0
BEGIN
    SET @Sql = N'USE ' + QUOTENAME(@DbName) + N';
        INSERT INTO #OrphanedUsers (database_name, user_name, user_type,
                                    authentication_type)
        SELECT DB_NAME(), dp.name, dp.type_desc,
               dp.authentication_type_desc
        FROM sys.database_principals AS dp
        WHERE dp.authentication_type IN (1, 3, 4)
          AND dp.type IN (''S'', ''U'', ''G'', ''E'', ''X'')
          AND dp.sid IS NOT NULL
          AND dp.name NOT IN (''dbo'', ''guest'', ''sys'',
                              ''INFORMATION_SCHEMA'')
          AND NOT EXISTS (SELECT 1 FROM sys.server_principals AS sp
                          WHERE sp.sid = dp.sid);

        INSERT INTO #DbRoleMembers (database_name, role_name,
                                    member_name, member_type)
        SELECT DB_NAME(), r.name, m.name, m.type_desc
        FROM sys.database_role_members AS drm
        JOIN sys.database_principals AS r
          ON r.principal_id = drm.role_principal_id
        JOIN sys.database_principals AS m
          ON m.principal_id = drm.member_principal_id
        WHERE r.name IN (''db_owner'', ''db_securityadmin'',
                         ''db_accessadmin'', ''db_ddladmin'',
                         ''db_backupoperator'');

        INSERT INTO #DbPerms (database_name, finding, grantee_name,
                              grantee_type, permission_name, state_desc,
                              class_desc, securable_name)
        SELECT DB_NAME(), ''DANGEROUS GRANT'', dp.name, dp.type_desc,
               p.permission_name, p.state_desc, p.class_desc, DB_NAME()
        FROM sys.database_permissions AS p
        JOIN sys.database_principals AS dp
          ON dp.principal_id = p.grantee_principal_id
        WHERE p.class = 0
          AND p.permission_name IN (''CONTROL'', ''ALTER'',
               ''ALTER ANY USER'', ''ALTER ANY ROLE'',
               ''ALTER ANY SCHEMA'', ''TAKE OWNERSHIP'',
               ''BACKUP DATABASE'', ''BACKUP LOG'')
          AND (dp.type IN (''S'', ''U'', ''G'', ''A'', ''C'', ''K'',
                           ''E'', ''X'')
               OR dp.name = ''public'');

        INSERT INTO #DbPerms (database_name, finding, grantee_name,
                              grantee_type, permission_name, state_desc,
                              class_desc, securable_name)
        SELECT DB_NAME(), ''GRANT WITH GRANT OPTION'', dp.name,
               dp.type_desc, p.permission_name, p.state_desc,
               p.class_desc, DB_NAME()
        FROM sys.database_permissions AS p
        JOIN sys.database_principals AS dp
          ON dp.principal_id = p.grantee_principal_id
        WHERE p.class = 0
          AND p.state = ''W''
          AND p.permission_name NOT IN (''CONTROL'', ''ALTER'',
               ''ALTER ANY USER'', ''ALTER ANY ROLE'',
               ''ALTER ANY SCHEMA'', ''TAKE OWNERSHIP'',
               ''BACKUP DATABASE'', ''BACKUP LOG'')
          AND (dp.type IN (''S'', ''U'', ''G'', ''A'', ''C'', ''K'',
                           ''E'', ''X'')
               OR dp.name = ''public'');

        INSERT INTO #DbPerms (database_name, finding, grantee_name,
                              grantee_type, permission_name, state_desc,
                              class_desc, securable_name)
        SELECT DB_NAME(), ''PRINCIPAL GRANT'', dp.name, dp.type_desc,
               p.permission_name, p.state_desc, p.class_desc, tgt.name
        FROM sys.database_permissions AS p
        JOIN sys.database_principals AS dp
          ON dp.principal_id = p.grantee_principal_id
        JOIN sys.database_principals AS tgt
          ON tgt.principal_id = p.major_id
        WHERE p.class = 4
          AND p.permission_name IN (''IMPERSONATE'', ''CONTROL'',
                                    ''TAKE OWNERSHIP'', ''ALTER'')
          AND (dp.type IN (''S'', ''U'', ''G'', ''A'', ''C'', ''K'',
                           ''E'', ''X'')
               OR dp.name = ''public'');

        INSERT INTO #GuestAccess (database_name, principal_name,
                                  permission_name, state_desc, class_desc)
        SELECT DB_NAME(), dp.name, p.permission_name, p.state_desc,
               p.class_desc
        FROM sys.database_permissions AS p
        JOIN sys.database_principals AS dp
          ON dp.principal_id = p.grantee_principal_id
        WHERE p.class = 0
          AND dp.name IN (''guest'', ''public'')
          AND p.state IN (''G'', ''W'');';

    BEGIN TRY
        EXEC sp_executesql @Sql;
    END TRY
    BEGIN CATCH
        PRINT 'Could not read security information for ' + @DbName + ': '
              + ERROR_MESSAGE();
    END CATCH;

    FETCH NEXT FROM db_cursor INTO @DbName;
END

CLOSE db_cursor;
DEALLOCATE db_cursor;

/* ----------------------------------------------------------------------
   5. Orphaned users
   ---------------------------------------------------------------------- */
PRINT '';
PRINT '-- Orphaned users -------------------------------------------------';

SELECT  database_name,
        user_name,
        user_type,
        authentication_type
FROM #OrphanedUsers
ORDER BY database_name, user_name;

PRINT '';
PRINT 'An orphaned user cannot connect because its login is gone. Fix';
PRINT 'it by remapping the user to a current login, or drop the user if';
PRINT 'nothing needs it. A common cause is a database restored from';
PRINT 'another instance: the users come with the backup, the logins do';
PRINT 'not. An empty result means no orphaned users were found.';

/* ----------------------------------------------------------------------
   6. Privileged database role membership
   ---------------------------------------------------------------------- */
PRINT '';
PRINT '-- Privileged database role membership ---------------------------';

SELECT  database_name,
        role_name,
        member_name,
        member_type
FROM #DbRoleMembers
ORDER BY database_name, role_name, member_name;

PRINT '';
PRINT 'db_owner is full control of that database. db_securityadmin can';
PRINT 'manage users and roles in the database; db_accessadmin can add';
PRINT 'and remove users; db_ddladmin can create and alter objects;';
PRINT 'db_backupoperator can back the database up. dbo appears in';
PRINT 'db_owner for every database; that is normal, not a finding.';
PRINT 'Anyone else in db_owner or db_securityadmin is worth a second';
PRINT 'look.';

/* ----------------------------------------------------------------------
   7. Dangerous database-level grants
   ---------------------------------------------------------------------- */
PRINT '';
PRINT '-- Dangerous database-level grants --------------------------------';

SELECT  database_name,
        finding,
        grantee_name,
        grantee_type,
        permission_name,
        state_desc,
        class_desc,
        securable_name
FROM #DbPerms
ORDER BY database_name, finding, grantee_name, permission_name;

PRINT '';
PRINT 'CONTROL on a database is effectively db_owner without the role';
PRINT 'membership. ALTER ANY USER and ALTER ANY ROLE let the grantee';
PRINT 'reshape who can use the database. IMPERSONATE on a user lets the';
PRINT 'grantee act as that user. A grant WITH GRANT OPTION lets the';
PRINT 'grantee pass the permission on. An empty result means no user';
PRINT 'holds a grant in these categories.';

/* ----------------------------------------------------------------------
   8. Guest and public access
   ---------------------------------------------------------------------- */
PRINT '';
PRINT '-- Guest and public access ---------------------------------------';

SELECT  database_name,
        principal_name,
        permission_name,
        state_desc,
        class_desc
FROM #GuestAccess
ORDER BY database_name, principal_name, permission_name;

PRINT '';
PRINT 'The guest user is disabled by default: it has no CONNECT';
PRINT 'permission unless someone granted it. A guest CONNECT row means';
PRINT 'any login can reach that database without a user of its own.';
PRINT 'A public CONNECT row has the same effect. Either one is usually';
PRINT 'a leftover from a restore or a demo, not an intended design.';
PRINT 'An empty result means guest and public hold no database-scope';
PRINT 'grants anywhere.';

DROP TABLE IF EXISTS #OrphanedUsers;
DROP TABLE IF EXISTS #DbRoleMembers;
DROP TABLE IF EXISTS #DbPerms;
DROP TABLE IF EXISTS #GuestAccess;
