@echo off
setlocal enabledelayedexpansion

rem ============================================================================
rem  r2-postgres-backup (Windows)
rem  Periodically dump a PostgreSQL database (or the whole cluster) and upload
rem  the archive to a Cloudflare R2 bucket with rclone.
rem ============================================================================

rem --- Add the bundled PostgreSQL client to PATH ------------------------------
set "PATH=C:\pgsql\bin;%PATH%"

rem --- Required configuration -------------------------------------------------
for %%V in (PGHOST PGUSER PGPASSWORD R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY R2_ENDPOINT R2_BUCKET) do (
    if not defined %%V (
        echo ERROR: %%V is required 1>&2
        exit /b 1
    )
)

rem --- Optional configuration with defaults -----------------------------------
if not defined PGPORT set "PGPORT=5432"
if not defined BACKUP_DIR set "BACKUP_DIR=C:\backups"
if not defined BACKUP_INTERVAL_SECONDS set "BACKUP_INTERVAL_SECONDS=86400"
if not defined PG_DUMP_MODE set "PG_DUMP_MODE=database"

if /I "%PG_DUMP_MODE%"=="database" (
    if not defined PGDATABASE (
        echo ERROR: PGDATABASE is required when PG_DUMP_MODE=database 1>&2
        exit /b 1
    )
) else if /I "%PG_DUMP_MODE%"=="cluster" (
    rem whole-cluster mode: pg_dumpall, PGDATABASE not needed
) else (
    echo ERROR: PG_DUMP_MODE must be 'database' or 'cluster' 1>&2
    exit /b 1
)

if not exist "%BACKUP_DIR%" mkdir "%BACKUP_DIR%"

rem --- Verify the baked-in clients are runnable -------------------------------
pg_dump --version >nul 2>&1 || ( echo ERROR: pg_dump not runnable 1>&2 & exit /b 1 )
pg_dumpall --version >nul 2>&1 || ( echo ERROR: pg_dumpall not runnable 1>&2 & exit /b 1 )

rem --- Configure rclone entirely from the environment -------------------------
set "RCLONE_CONFIG_R2_TYPE=s3"
set "RCLONE_CONFIG_R2_PROVIDER=Cloudflare"
set "RCLONE_CONFIG_R2_ACCESS_KEY_ID=%R2_ACCESS_KEY_ID%"
set "RCLONE_CONFIG_R2_SECRET_ACCESS_KEY=%R2_SECRET_ACCESS_KEY%"
set "RCLONE_CONFIG_R2_ENDPOINT=%R2_ENDPOINT%"

set "REMOTE=r2:%R2_BUCKET%"
if defined R2_PATH_PREFIX set "REMOTE=%REMOTE%/%R2_PATH_PREFIX%"

echo [backup] Starting backup loop (mode=%PG_DUMP_MODE%, every %BACKUP_INTERVAL_SECONDS%s)

:loop
rem --- Timestamp (UTC not available in batch; wmic local time) ----------------
set "TS="
for /f "tokens=2 delims==" %%I in ('wmic os get localdatetime /value 2^>nul') do set "TS=%%I"
if defined TS (
    set "TS=!TS:~0,4!!TS:~4,2!!TS:~6,2!-!TS:~8,2!!TS:~10,2!!TS:~12,2!"
) else (
    set "TS=%DATE:/=%-%TIME::=%"
    set "TS=!TS: =0!"
)

if /I "%PG_DUMP_MODE%"=="cluster" goto dump_cluster

rem --- database mode ----------------------------------------------------------
set "FILE=%BACKUP_DIR%\%PGDATABASE%-%TS%.dump"
echo [backup] Dumping database '%PGDATABASE%' from %PGHOST%:%PGPORT% -^> "%FILE%"
pg_dump -Fc -f "%FILE%"
if errorlevel 1 (
    echo [backup] pg_dump FAILED 1>&2
    if exist "%FILE%" del /f /q "%FILE%"
    goto sleep
)
goto upload

:dump_cluster
set "FILE=%BACKUP_DIR%\cluster-%TS%.sql"
echo [backup] Dumping entire cluster (pg_dumpall --clean) from %PGHOST%:%PGPORT% -^> "%FILE%"
pg_dumpall --clean -f "%FILE%"
if errorlevel 1 (
    echo [backup] pg_dumpall FAILED 1>&2
    if exist "%FILE%" del /f /q "%FILE%"
    goto sleep
)

:upload
echo [backup] Uploading "%FILE%" -^> "%REMOTE%/"
rclone copy "%FILE%" "%REMOTE%/"
if errorlevel 1 (
    echo [backup] rclone upload FAILED 1>&2
    if exist "%FILE%" del /f /q "%FILE%"
    goto sleep
)
if exist "%FILE%" del /f /q "%FILE%"
echo [backup] Backup complete -^> %REMOTE%/

:sleep
echo [backup] Sleeping %BACKUP_INTERVAL_SECONDS%s
rem timeout needs a console; fall back to ping when running without a TTY.
timeout /t %BACKUP_INTERVAL_SECONDS% /nobreak >nul 2>&1 || ping -n %BACKUP_INTERVAL_SECONDS% 127.0.0.1 >nul 2>&1
goto loop
