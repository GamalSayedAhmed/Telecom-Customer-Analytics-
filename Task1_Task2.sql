CREATE DATABASE We_BI;
GO
USE We_BI

-- Loading data from CSV files into the dataset using wizzard -- 
USE We_BI;
GO

SELECT
    TABLE_SCHEMA,
    TABLE_NAME
FROM INFORMATION_SCHEMA.TABLES
WHERE TABLE_TYPE = 'BASE TABLE'
ORDER BY TABLE_NAME;

-- Check the number of rows in each table --

SELECT
    t.name AS TableName,
    SUM(ps.row_count) AS TotalRows
FROM sys.tables AS t
INNER JOIN sys.dm_db_partition_stats AS ps
    ON t.object_id = ps.object_id
WHERE
    ps.index_id IN (0, 1)
GROUP BY
    t.name
ORDER BY
    t.name;

USE We_BI;
GO

SELECT
    TABLE_NAME,
    COLUMN_NAME,
    DATA_TYPE,
    IS_NULLABLE
FROM INFORMATION_SCHEMA.COLUMNS
ORDER BY
    TABLE_NAME,
    ORDINAL_POSITION;

-----------------------------------------------

----TASK ONE----
USE We_BI;
GO

WITH customer_map AS (
    SELECT DISTINCT
        CUSTOMER_ID,
        SUBSCRIBER_ID,
        SERVICE_NUMBER
    FROM dbo.Customer
    WHERE CUSTOMER_ID IS NOT NULL
),
consumption_by_subscriber AS (
    SELECT
        SUBSCRIBER_ID,
        SUM(ISNULL(DAILY_CONSUMPTION_MB, 0)) AS Total_Consumption_MB
    FROM dbo.Consumption
    GROUP BY SUBSCRIBER_ID
),
payments_by_subscriber AS (
    SELECT
        SUBSCRIBER_ID,
        SUM(
            ISNULL(RENT_REVENUE, 0) +
            ISNULL(OUT_BUNDLE_REVENUE, 0) +
            ISNULL(CREATION_FEES_REVENUE, 0) +
            ISNULL(DEVICES_REVENUE, 0) +
            ISNULL(IN_BUNDLE_REVENUE, 0) +
            ISNULL(ADDON_REVENUE, 0) +
            ISNULL(TAX_AMOUNT, 0)
        ) AS Total_Payments
    FROM dbo.Payments
    GROUP BY SUBSCRIBER_ID
),
calls_by_service AS (
    SELECT
        SERVICE_NUMBER,
        COUNT(*) AS Total_Calls
    FROM dbo.Calls
    GROUP BY SERVICE_NUMBER
)
SELECT
    cm.CUSTOMER_ID,
    SUM(ISNULL(cbs.Total_Consumption_MB, 0)) AS Total_Consumption_MB,
    SUM(ISNULL(pbs.Total_Payments, 0)) AS Total_Payments,
    SUM(ISNULL(calls.Total_Calls, 0)) AS Total_Calls
FROM customer_map cm
LEFT JOIN consumption_by_subscriber cbs
    ON cm.SUBSCRIBER_ID = cbs.SUBSCRIBER_ID
LEFT JOIN payments_by_subscriber pbs
    ON cm.SUBSCRIBER_ID = pbs.SUBSCRIBER_ID
LEFT JOIN calls_by_service calls
    ON cm.SERVICE_NUMBER = calls.SERVICE_NUMBER
GROUP BY cm.CUSTOMER_ID
ORDER BY cm.CUSTOMER_ID;
GO

-------------------------------------------------------
USE We_BI;
GO

WITH customer_map AS (
    SELECT DISTINCT
        CUSTOMER_ID,
        SUBSCRIBER_ID,
        SERVICE_NUMBER
    FROM dbo.Customer
    WHERE CUSTOMER_ID IS NOT NULL
),
consumption_by_subscriber AS (
    SELECT SUBSCRIBER_ID, SUM(ISNULL(DAILY_CONSUMPTION_MB, 0)) AS Total_Consumption_MB
    FROM dbo.Consumption
    GROUP BY SUBSCRIBER_ID
),
payments_by_subscriber AS (
    SELECT
        SUBSCRIBER_ID,
        SUM(
            ISNULL(RENT_REVENUE, 0) +
            ISNULL(OUT_BUNDLE_REVENUE, 0) +
            ISNULL(CREATION_FEES_REVENUE, 0) +
            ISNULL(DEVICES_REVENUE, 0) +
            ISNULL(IN_BUNDLE_REVENUE, 0) +
            ISNULL(ADDON_REVENUE, 0) +
            ISNULL(TAX_AMOUNT, 0)
        ) AS Total_Payments
    FROM dbo.Payments
    GROUP BY SUBSCRIBER_ID
),
calls_by_service AS (
    SELECT SERVICE_NUMBER, COUNT(*) AS Total_Calls
    FROM dbo.Calls
    GROUP BY SERVICE_NUMBER
),
final_result AS (
    SELECT
        cm.CUSTOMER_ID,
        SUM(ISNULL(cbs.Total_Consumption_MB, 0)) AS Total_Consumption_MB,
        SUM(ISNULL(pbs.Total_Payments, 0)) AS Total_Payments,
        SUM(ISNULL(calls.Total_Calls, 0)) AS Total_Calls
    FROM customer_map cm
    LEFT JOIN consumption_by_subscriber cbs
        ON cm.SUBSCRIBER_ID = cbs.SUBSCRIBER_ID
    LEFT JOIN payments_by_subscriber pbs
        ON cm.SUBSCRIBER_ID = pbs.SUBSCRIBER_ID
    LEFT JOIN calls_by_service calls
        ON cm.SERVICE_NUMBER = calls.SERVICE_NUMBER
    GROUP BY cm.CUSTOMER_ID
)
SELECT
    COUNT(*) AS Rownum,
    COUNT(DISTINCT CUSTOMER_ID) AS DistinctCustomers
FROM final_result;
GO
------------TASK2-----------
SET STATISTICS IO ON;
SET STATISTICS TIME ON;
GO

WITH customers AS (
    SELECT DISTINCT CUSTOMER_ID
    FROM dbo.Customer
    WHERE CUSTOMER_ID IS NOT NULL
)
SELECT
    c.CUSTOMER_ID,

    ISNULL((
        SELECT SUM(ISNULL(con.DAILY_CONSUMPTION_MB, 0))
        FROM dbo.Customer c2
        INNER JOIN dbo.Consumption con
            ON c2.SUBSCRIBER_ID = con.SUBSCRIBER_ID
        WHERE c2.CUSTOMER_ID = c.CUSTOMER_ID
    ), 0) AS Total_Consumption_MB,

    ISNULL((
        SELECT SUM(
            ISNULL(p.RENT_REVENUE, 0) +
            ISNULL(p.OUT_BUNDLE_REVENUE, 0) +
            ISNULL(p.CREATION_FEES_REVENUE, 0) +
            ISNULL(p.DEVICES_REVENUE, 0) +
            ISNULL(p.IN_BUNDLE_REVENUE, 0) +
            ISNULL(p.ADDON_REVENUE, 0) +
            ISNULL(p.TAX_AMOUNT, 0)
        )
        FROM dbo.Customer c3
        INNER JOIN dbo.Payments p
            ON c3.SUBSCRIBER_ID = p.SUBSCRIBER_ID
        WHERE c3.CUSTOMER_ID = c.CUSTOMER_ID
    ), 0) AS Total_Payments,

    ISNULL((
        SELECT COUNT(*)
        FROM dbo.Customer c4
        INNER JOIN dbo.Calls cl
            ON c4.SERVICE_NUMBER = cl.SERVICE_NUMBER
        WHERE c4.CUSTOMER_ID = c.CUSTOMER_ID
    ), 0) AS Total_Calls

FROM customers c
ORDER BY c.CUSTOMER_ID;
GO

-----Optimized version-----
IF NOT EXISTS (
    SELECT 1
    FROM sys.indexes
    WHERE name = 'IX_Consumption_SUBSCRIBER_ID'
      AND object_id = OBJECT_ID('dbo.Consumption')
)
BEGIN
    CREATE INDEX IX_Consumption_SUBSCRIBER_ID
    ON dbo.Consumption (SUBSCRIBER_ID)
    INCLUDE (DAILY_CONSUMPTION_MB);
END
GO

IF NOT EXISTS (
    SELECT 1
    FROM sys.indexes
    WHERE name = 'IX_Payments_SUBSCRIBER_ID'
      AND object_id = OBJECT_ID('dbo.Payments')
)
BEGIN
    CREATE INDEX IX_Payments_SUBSCRIBER_ID
    ON dbo.Payments (SUBSCRIBER_ID)
    INCLUDE (
        RENT_REVENUE,
        OUT_BUNDLE_REVENUE,
        CREATION_FEES_REVENUE,
        DEVICES_REVENUE,
        IN_BUNDLE_REVENUE,
        ADDON_REVENUE,
        TAX_AMOUNT
    );
END
GO

IF NOT EXISTS (
    SELECT 1
    FROM sys.indexes
    WHERE name = 'IX_Calls_SERVICE_NUMBER'
      AND object_id = OBJECT_ID('dbo.Calls')
)
BEGIN
    CREATE INDEX IX_Calls_SERVICE_NUMBER
    ON dbo.Calls (SERVICE_NUMBER);
END
GO

IF NOT EXISTS (
    SELECT 1
    FROM sys.indexes
    WHERE name = 'IX_Customer_CUSTOMER_SUBSCRIBER_SERVICE'
      AND object_id = OBJECT_ID('dbo.Customer')
)
BEGIN
    CREATE INDEX IX_Customer_CUSTOMER_SUBSCRIBER_SERVICE
    ON dbo.Customer (CUSTOMER_ID, SUBSCRIBER_ID, SERVICE_NUMBER);
END
GO

WITH customer_map AS (
    SELECT DISTINCT
        CUSTOMER_ID,
        SUBSCRIBER_ID,
        SERVICE_NUMBER
    FROM dbo.Customer
    WHERE CUSTOMER_ID IS NOT NULL
),
consumption_by_subscriber AS (
    SELECT
        SUBSCRIBER_ID,
        SUM(DAILY_CONSUMPTION_MB) AS Total_Consumption_MB
    FROM dbo.Consumption
    GROUP BY SUBSCRIBER_ID
),
payments_by_subscriber AS (
    SELECT
        SUBSCRIBER_ID,
        SUM(
            COALESCE(RENT_REVENUE, 0) +
            COALESCE(OUT_BUNDLE_REVENUE, 0) +
            COALESCE(CREATION_FEES_REVENUE, 0) +
            COALESCE(DEVICES_REVENUE, 0) +
            COALESCE(IN_BUNDLE_REVENUE, 0) +
            COALESCE(ADDON_REVENUE, 0) +
            COALESCE(TAX_AMOUNT, 0)
        ) AS Total_Payments
    FROM dbo.Payments
    GROUP BY SUBSCRIBER_ID
),
calls_by_service AS (
    SELECT
        SERVICE_NUMBER,
        COUNT_BIG(*) AS Total_Calls
    FROM dbo.Calls
    GROUP BY SERVICE_NUMBER
)
SELECT
    cm.CUSTOMER_ID,
    SUM(COALESCE(cbs.Total_Consumption_MB, 0)) AS Total_Consumption_MB,
    SUM(COALESCE(pbs.Total_Payments, 0)) AS Total_Payments,
    SUM(COALESCE(calls.Total_Calls, 0)) AS Total_Calls
FROM customer_map cm
LEFT JOIN consumption_by_subscriber cbs
    ON cm.SUBSCRIBER_ID = cbs.SUBSCRIBER_ID
LEFT JOIN payments_by_subscriber pbs
    ON cm.SUBSCRIBER_ID = pbs.SUBSCRIBER_ID
LEFT JOIN calls_by_service calls
    ON cm.SERVICE_NUMBER = calls.SERVICE_NUMBER
GROUP BY cm.CUSTOMER_ID
ORDER BY cm.CUSTOMER_ID;
GO

SET STATISTICS IO OFF;
SET STATISTICS TIME OFF;
GO


-- Baseline performance:
-- Rows returned: 9993
-- CPU time: 1687 ms
-- Elapsed time: 8432 ms

-- Optimized performance:
-- Rows returned: 9993
-- CPU time: 1703 ms
-- Elapsed time: 1117 ms
-- Elapsed time improvement: about 86.8%
-----------------------------------------------
-- Validation: baseline result = optimized result
-----------------------------------------------
IF OBJECT_ID('tempdb..#baseline') IS NOT NULL DROP TABLE #baseline;
IF OBJECT_ID('tempdb..#optimized') IS NOT NULL DROP TABLE #optimized;
GO

WITH customers AS (
    SELECT DISTINCT CUSTOMER_ID
    FROM dbo.Customer
    WHERE CUSTOMER_ID IS NOT NULL
)
SELECT
    c.CUSTOMER_ID,
    ISNULL((
        SELECT SUM(ISNULL(con.DAILY_CONSUMPTION_MB, 0))
        FROM dbo.Customer c2
        INNER JOIN dbo.Consumption con
            ON c2.SUBSCRIBER_ID = con.SUBSCRIBER_ID
        WHERE c2.CUSTOMER_ID = c.CUSTOMER_ID
    ), 0) AS Total_Consumption_MB,
    ISNULL((
        SELECT SUM(
            ISNULL(p.RENT_REVENUE, 0) +
            ISNULL(p.OUT_BUNDLE_REVENUE, 0) +
            ISNULL(p.CREATION_FEES_REVENUE, 0) +
            ISNULL(p.DEVICES_REVENUE, 0) +
            ISNULL(p.IN_BUNDLE_REVENUE, 0) +
            ISNULL(p.ADDON_REVENUE, 0) +
            ISNULL(p.TAX_AMOUNT, 0)
        )
        FROM dbo.Customer c3
        INNER JOIN dbo.Payments p
            ON c3.SUBSCRIBER_ID = p.SUBSCRIBER_ID
        WHERE c3.CUSTOMER_ID = c.CUSTOMER_ID
    ), 0) AS Total_Payments,
    ISNULL((
        SELECT COUNT(*)
        FROM dbo.Customer c4
        INNER JOIN dbo.Calls cl
            ON c4.SERVICE_NUMBER = cl.SERVICE_NUMBER
        WHERE c4.CUSTOMER_ID = c.CUSTOMER_ID
    ), 0) AS Total_Calls
INTO #baseline
FROM customers c;
GO

WITH customer_map AS (
    SELECT DISTINCT
        CUSTOMER_ID,
        SUBSCRIBER_ID,
        SERVICE_NUMBER
    FROM dbo.Customer
    WHERE CUSTOMER_ID IS NOT NULL
),
consumption_by_subscriber AS (
    SELECT
        SUBSCRIBER_ID,
        SUM(DAILY_CONSUMPTION_MB) AS Total_Consumption_MB
    FROM dbo.Consumption
    GROUP BY SUBSCRIBER_ID
),
payments_by_subscriber AS (
    SELECT
        SUBSCRIBER_ID,
        SUM(
            COALESCE(RENT_REVENUE, 0) +
            COALESCE(OUT_BUNDLE_REVENUE, 0) +
            COALESCE(CREATION_FEES_REVENUE, 0) +
            COALESCE(DEVICES_REVENUE, 0) +
            COALESCE(IN_BUNDLE_REVENUE, 0) +
            COALESCE(ADDON_REVENUE, 0) +
            COALESCE(TAX_AMOUNT, 0)
        ) AS Total_Payments
    FROM dbo.Payments
    GROUP BY SUBSCRIBER_ID
),
calls_by_service AS (
    SELECT
        SERVICE_NUMBER,
        COUNT_BIG(*) AS Total_Calls
    FROM dbo.Calls
    GROUP BY SERVICE_NUMBER
)
SELECT
    cm.CUSTOMER_ID,
    SUM(COALESCE(cbs.Total_Consumption_MB, 0)) AS Total_Consumption_MB,
    SUM(COALESCE(pbs.Total_Payments, 0)) AS Total_Payments,
    SUM(COALESCE(calls.Total_Calls, 0)) AS Total_Calls
INTO #optimized
FROM customer_map cm
LEFT JOIN consumption_by_subscriber cbs
    ON cm.SUBSCRIBER_ID = cbs.SUBSCRIBER_ID
LEFT JOIN payments_by_subscriber pbs
    ON cm.SUBSCRIBER_ID = pbs.SUBSCRIBER_ID
LEFT JOIN calls_by_service calls
    ON cm.SERVICE_NUMBER = calls.SERVICE_NUMBER
GROUP BY cm.CUSTOMER_ID;
GO

-- Rows in baseline not in optimized
SELECT *
FROM #baseline
EXCEPT
SELECT *
FROM #optimized;
GO

-- Rows in optimized not in baseline
SELECT *
FROM #optimized
EXCEPT
SELECT *
FROM #baseline;
GO

---(9993 rows affected)

---(9993 rows affected)

------(0 rows affected)

------(0 rows affected)


-------------------------------------------------------
