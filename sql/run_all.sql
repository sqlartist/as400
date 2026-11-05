/*===========================================================================
  AS/400 in SQL Server 2025 — run the lot.

  Create a database first, then run this from the sql directory with:

      sqlcmd -S <server> -d AS400 -i run_all.sql

  Or just open 01..05 in order in SSMS.
===========================================================================*/
:r 01_catalog.sql
GO
:r 02_dds.sql
GO
:r 03_render.sql
GO
:r 04_cl.sql
GO
:r 05_demo.sql
GO
:r 06_rla.sql
GO
:r 07_demo_rla.sql
GO
:r 08_input.sql
GO
:r 09_inqpgm.sql
GO

PRINT '';
PRINT '=== INVENQ  (set-based) ===';
GO
EXEC WARELIB.INVENQ;
GO

PRINT '=== INVENQR (SETLL + READ) ===';
GO
EXEC WARELIB.INVENQR;
GO

PRINT '=== PARTMOV (CHAIN + READE) ===';
GO
EXEC WARELIB.PARTMOV 'SIMM16';
GO
