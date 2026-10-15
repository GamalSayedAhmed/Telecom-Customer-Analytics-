USE We_BI;
GO

CREATE OR ALTER VIEW dbo.vw_CustomerSegments
AS
WITH ref AS (
    SELECT MAX(CONSUMPTION_DATE) AS RefDate FROM dbo.Consumption
),
cons AS (
    SELECT SUBSCRIBER_ID,
           SUM(DAILY_CONSUMPTION_MB) AS ConsMB,
           MAX(CASE WHEN DAILY_CONSUMPTION_MB > 0 THEN CONSUMPTION_DATE END) AS LastUseDate
    FROM dbo.Consumption
    GROUP BY SUBSCRIBER_ID
),
pay AS (
    SELECT SUBSCRIBER_ID,
           SUM( ISNULL(RENT_REVENUE, 0)
              + ISNULL(OUT_BUNDLE_REVENUE, 0)
              + ISNULL(IN_BUNDLE_REVENUE, 0)
              + ISNULL(ADDON_REVENUE, 0)
              + ISNULL(CREATION_FEES_REVENUE, 0)
              + ISNULL(DEVICES_REVENUE, 0) ) AS Revenue
    FROM dbo.Payments
    GROUP BY SUBSCRIBER_ID
),
calls AS (
    SELECT SERVICE_NUMBER, COUNT(*) AS CallCount
    FROM dbo.Calls
    GROUP BY SERVICE_NUMBER
),
app AS (
    SELECT SERVICE_NUMBER, COUNT(*) AS AppEvents
    FROM dbo.Mobile_App
    GROUP BY SERVICE_NUMBER
),
base AS (
    SELECT c.SUBSCRIBER_ID,
           c.CUSTOMER_ID,
           ISNULL(cons.ConsMB, 0)      AS ConsMB,
           ISNULL(pay.Revenue, 0)      AS Revenue,
           ISNULL(calls.CallCount, 0)  AS CallCount,
           ISNULL(app.AppEvents, 0)    AS AppEvents,
           DATEDIFF(DAY, cons.LastUseDate, ref.RefDate) AS DaysSinceUse
    FROM dbo.Customer AS c
    CROSS JOIN ref
    LEFT JOIN cons  ON cons.SUBSCRIBER_ID   = c.SUBSCRIBER_ID
    LEFT JOIN pay   ON pay.SUBSCRIBER_ID    = c.SUBSCRIBER_ID
    LEFT JOIN calls ON calls.SERVICE_NUMBER = c.SERVICE_NUMBER
    LEFT JOIN app   ON app.SERVICE_NUMBER   = c.SERVICE_NUMBER
),
flagged AS (
    SELECT *,
           CASE WHEN DaysSinceUse IS NULL OR DaysSinceUse > 90 THEN 1 ELSE 0 END AS IsDormant
    FROM base
),
ranked AS (
    SELECT *,
           PERCENT_RANK() OVER (PARTITION BY IsDormant ORDER BY Revenue)   AS RevenueRank,
           PERCENT_RANK() OVER (PARTITION BY IsDormant ORDER BY CallCount) AS CallsRank
    FROM flagged
),
segmented AS (
    SELECT *,
           CASE
               WHEN IsDormant = 1                            THEN 'Dormant / At-Risk'
               WHEN RevenueRank >= 0.80                      THEN 'High-Value'
               WHEN CallCount >= 2 AND CallsRank >= 0.75     THEN 'Support-Dependent'
               WHEN AppEvents > 0                            THEN 'Digital Self-Servers'
               ELSE 'Core / Low-Engagement'
           END AS Segment
    FROM ranked
)
SELECT SUBSCRIBER_ID,
       CUSTOMER_ID,
       Segment,
       ConsMB,
       Revenue,
       CallCount,
       AppEvents,
       DaysSinceUse,
       CASE Segment
           WHEN 'High-Value'            THEN 'Top 20% of active subscribers by revenue; they carry a large part of the income.'
           WHEN 'Support-Dependent'     THEN 'Call the call center far more than others: high cost to serve and an early churn warning.'
           WHEN 'Digital Self-Servers'  THEN 'Use the mobile app and rarely call; the cheapest customers to serve.'
           WHEN 'Dormant / At-Risk'     THEN 'No consumption in the last 90 days of the data: revenue already lost or about to be.'
           ELSE                              'Stable customers of average value who barely use the app or call.'
       END AS Interpretation,
       CASE Segment
           WHEN 'High-Value'            THEN 'Protect: proactive retention, priority support and an offer for a higher tier.'
           WHEN 'Support-Dependent'     THEN 'Find the root cause of the calls (billing, network), move them to the app, and reach out before they leave.'
           WHEN 'Digital Self-Servers'  THEN 'Sell upgrades and add-ons through the app and keep the app reliable.'
           WHEN 'Dormant / At-Risk'     THEN 'Win-back campaign; check line status and service quality before offering discounts.'
           ELSE                              'Maintain the service, introduce app features and cross-sell add-ons.'
       END AS RecommendedAction
FROM segmented;
GO


/* ---------- CHECK 1: segment sizes and behavior ---------- */
SELECT Segment,
       COUNT(*)                                                         AS Subscribers,
       COUNT(DISTINCT CUSTOMER_ID)                                      AS Customers,
       CAST(100.0 * COUNT(*) / SUM(COUNT(*)) OVER () AS decimal(5,1))   AS PctOfBase,
       CAST(AVG(Revenue) AS decimal(18,2))                              AS AvgRevenue,
       CAST(AVG(ConsMB) AS decimal(18,0))                               AS AvgConsumptionMB,
       CAST(AVG(1.0 * CallCount) AS decimal(10,2))                      AS AvgCalls,
       CAST(100.0 * AVG(CASE WHEN AppEvents > 0 THEN 1.0 ELSE 0 END) AS decimal(5,1)) AS PctUsingApp
FROM dbo.vw_CustomerSegments
GROUP BY Segment
ORDER BY Subscribers DESC;

/* ---------- CHECK 2: no duplicates ---------- */ 
SELECT COUNT(*) AS RowsInView, COUNT(DISTINCT SUBSCRIBER_ID) AS DistinctSubscribers
FROM dbo.vw_CustomerSegments;