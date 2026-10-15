# WE Telecom BI Project

End-to-end BI solution for a telecom dataset: SQL Server data preparation and optimization, a Power BI star-schema model with DAX measures, a four-page executive dashboard, business insights, and a rule-based customer segmentation.

## Tech Stack

| Layer | Tool |
|---|---|
| Database | SQL Server (database `We_BI`) |
| Data loading | SQL Server Import Wizard (CSV files) |
| Modeling and visualization | Power BI Desktop (DAX) |

## Repository Structure

```
├── README.md
├── sql/
│   ├── Task1_Task2.sql          # Customer aggregation + performance optimization
│   └── CustomerSegments.sql     # vw_CustomerSegments view (Task 7)
```

## Tasks Overview

| # | Task | Tool | Deliverable |
|---|---|---|---|
| 1 | Customer-level aggregation | SQL | Consumption, payments, and calls per customer |
| 2 | Query optimization | SQL | Baseline vs. optimized query with validation |
| 3 | Data model | Power BI | Star schema |
| 4 | DAX measures | Power BI | Reusable `DAXMeasures` table |
| 5 | Dashboard | Power BI | 4-page interactive report |
| 6 | Business insights | Analysis | 3 insights with evidence and actions |
| 7 | Customer segmentation | SQL + Power BI | `vw_CustomerSegments` view and segments page |
| 8 | AI / ML use case | Design | Churn (dormancy) prediction proposal |

---

## 1. Customer-Level Aggregation (SQL)

**Goal:** return one row per `CUSTOMER_ID` with total consumption (MB), total payments, and total calls.

**Setup:** the CSV files were loaded into the `We_BI` database with the Import Wizard, then verified with row counts per table and a column/data-type check against `INFORMATION_SCHEMA`.

**Approach:**

1. `customer_map` builds a distinct `CUSTOMER_ID` / `SUBSCRIBER_ID` / `SERVICE_NUMBER` mapping from `dbo.Customer`.
2. Each fact table is **pre-aggregated at its own grain** before joining:
   - `Consumption` by `SUBSCRIBER_ID` (sum of `DAILY_CONSUMPTION_MB`)
   - `Payments` by `SUBSCRIBER_ID` (sum of rent, out-of-bundle, in-bundle, add-on, creation fees, devices, and tax)
   - `Calls` by `SERVICE_NUMBER` (row count)
3. The aggregates are `LEFT JOIN`ed to the mapping and rolled up to `CUSTOMER_ID`.

**Why pre-aggregate?** Joining the raw fact tables directly would multiply rows (fan-out) and inflate every total. Pre-aggregating guarantees one row per key before each join.

**Validation:** the result returns **9,993 rows = 9,993 distinct customers**, so there are no duplicates.

---

## 2. Query Optimization (SQL)

**Baseline:** one correlated subquery per metric (consumption, payments, calls), each joining `Customer` again to reach its fact table.

**Three concrete changes:**

1. **Removed the correlated subqueries and aggregated each fact table once.** Each fact table is summed in its own CTE (`GROUP BY SUBSCRIBER_ID` or `SERVICE_NUMBER`) and the small results are joined. In the baseline plan `Customer` is scanned **four times** (once per subquery plus the outer query); in the optimized plan it is read **once**.
2. **Added covering indexes.** Not every index turned out to be useful, which the execution plan shows:

| Index | Table | Key | Used by the optimized plan? |
|---|---|---|---|
| `IX_Customer_CUSTOMER_SUBSCRIBER_SERVICE` | Customer | `CUSTOMER_ID, SUBSCRIBER_ID, SERVICE_NUMBER` | **Yes**, Index Seek; logical reads drop from 2,860 to 115 |
| `IX_Payments_SUBSCRIBER_ID` | Payments | `SUBSCRIBER_ID` (+ all revenue columns) | **Yes**, the ordered index feeds a Stream Aggregate instead of a Hash Aggregate; page reads stay about the same (4,122 vs 4,066) because the index covers all columns |
| `IX_Calls_SERVICE_NUMBER` | Calls | `SERVICE_NUMBER` | **Yes**, narrow Index Scan; logical reads drop from 239 to 142 |
| `IX_Consumption_SUBSCRIBER_ID` | Consumption | `SUBSCRIBER_ID` (+ `DAILY_CONSUMPTION_MB`) | **No.** `Consumption` already has a clustered columnstore index (`CCI_Consumption`) and the optimizer prefers its batch-mode scan. Building this index took about 25 seconds, so it adds cost without benefit and can be dropped |

3. **Aggregate before joining (join order).** The facts are reduced to one row per subscriber or service number before they meet the customer mapping, so the hash joins work on small pre-aggregated sets instead of row-level data (for example `Payments`, about 363K rows, is aggregated before the join).

### Execution plan: before vs. after

| | Baseline | Optimized |
|---|---|---|
| `Customer` | Clustered Index Scan, **4 times** | Index Seek on the new index, **once** |
| `Payments` | Table Scan, joined row by row to customers, then Hash Match aggregation | Index Scan in `SUBSCRIBER_ID` order, then **Stream Aggregate** before joining |
| `Calls` | Table Scan (heap) | Scan of the narrow `IX_Calls_SERVICE_NUMBER` index |
| `Consumption` | Clustered columnstore scan (batch mode) | Same; the new index was not used |
| Parallelism | DOP 2 | DOP 2 |
| Estimated plan cost | 6.36 | 5.29 |
| Warnings / missing-index hints | None | None |

SQL Server already converts the baseline subqueries into hash joins, so the baseline is not as slow as a literal per-customer loop. The gain comes mainly from reading `Customer` once, aggregating before joining, and the indexes on `Customer`, `Payments` and `Calls`.

### Results (`SET STATISTICS IO / TIME ON`, 9,993 rows returned by both)

| Metric | Baseline | Optimized |
|---|---:|---:|
| CPU time | 1,608 ms | 953 ms |
| Elapsed time | 1,588 ms | 768 ms |
| Logical reads: `Customer` | 2,860 | 115 |
| Logical reads: `Payments` | 4,122 | 4,066 |
| Logical reads: `Calls` | 239 | 142 |
| Logical reads: `Consumption` (LOB) | 12,061 | 5,893 |

Elapsed time improved by about **52%** and CPU time by about **41%**. The `Customer` reads show the clearest effect (about 96% fewer).

**Caveat:** the baseline run still had read-ahead (physical) reads, meaning part of the data was loaded from disk, while the optimized run read everything from memory. The `Consumption` reads in particular are not directly comparable, because the new index on that table was not used. An earlier first run of the baseline took 8,432 ms, which was most likely a cold-cache effect, so it is not used for the comparison.

**Correctness check:** both results were loaded into temp tables (`#baseline`, `#optimized`) and compared with `EXCEPT` in both directions. **Both returned 0 rows**, so the optimized query produces identical output.

---

## 3. Data Model (Power BI)

A star schema with four fact tables around a shared customer dimension.

| Type | Tables |
|---|---|
| Facts | `FactCalls`, `FactPayments`, `FactConsumption`, `FactMobileApp` |
| Dimensions | `DimCustomer`, `DimPlan`, `DimDate`, `DimRatingGroup` |
| Segmentation | `vw_CustomerSegments` (SQL view, related to `DimCustomer`) |
| Measures | `DAXMeasures` (measure-only table) |

### Grain of the activity tables

| Table | Grain (one row per...) | Key |
|---|---|---|
| `FactCalls` | call | `CALL_ID` |
| `FactPayments` | payment record | `Payment_ID` |
| `FactConsumption` | consumption record (daily consumption per subscriber, by consumption type and rating group) | `Consumption_ID` |
| `FactMobileApp` | app log event | `LOG_ID` |

Every fact table connects only to the dimensions (`DimCustomer`, `DimDate`, and for consumption `DimRatingGroup`), never to another fact table. This avoids fact-to-fact joins, so one customer is not counted multiple times.

- `DimCustomer` is the hub: it filters all four fact tables.
- `DimDate` provides the shared time axis (`Year`, `Quarter`, `MonthName`, `YearMonth`) across the fact tables.
- `DimPlan` filters customers by subscription plan; `DimRatingGroup` filters consumption.
- The segmentation view is imported so the segment can be used as a slicer and a dimension in visuals.

---

## 4. DAX Measures (Power BI)

All measures live in a dedicated `DAXMeasures` table, which keeps the field list clean and the logic reusable.

| Category | Measures |
|---|---|
| Volume | Total Customers, Total Subscribers, Active Customers, Active Customers (Status), New Customers, Dormant Customers, Total Calls, Total Consumption MB |
| Revenue | Total Revenue, Total Payments, Total Tax, ARPU, Payments Share %, Revenue Share %, Customer Share %, Consumption Share %, Active Customer Share % |
| Engagement | App Users, App Engagement Rate, Mobile App Actions, Actions per App User, Calls per Active Customer, Avg Consumption per Active Customer, Active Rate % |
| Time intelligence | Revenue PM / Revenue MoM %, Calls PM / Calls MoM %, Consumption PM / Consumption MoM %, Active Customers PM / Active Customers MoM % |

### Business definitions

- **Total Customers:** distinct customers in `DimCustomer` (counted at customer level, so fact-to-fact joins cannot inflate it).
- **Active Customer:** a distinct customer whose `SUBSCRIBER_STATUS` is `"Active"` **and** who has at least some activity in the current filter context, meaning `Total Consumption MB + Total Calls + Mobile App Actions > 0`. A customer with an active status but no usage, calls, or app activity in the selected period is not counted. Because the measure respects the report filters, the result changes with the selected month, plan, or class.
- **Why this differs from the Task 7 "Dormant" count:** Active Customers uses a status flag plus *any* activity (usage, calls, or app) in the selected period, while Dormant / At-Risk is based only on consumption in the last 90 days of the data. The two definitions overlap but are not exact complements, so Active Customers (9,422) is not equal to total customers minus dormant (9,993 - 548).
- **ARPU:** Total Revenue divided by Total Customers.
- **App Engagement Rate:** App Users divided by Active Customers.
- **Percentage-of-total measures** (Customer Share %, Revenue Share %, Payments Share %, Consumption Share %): each plan's value divided by the total across all plans, so they stay correct when the user filters by Subscription Plan.

### Why these measures

| Measure group | Why management needs it |
|---|---|
| Total / Active Customers, Active Rate % | The base question: how big is the customer base and how much of it is engaged |
| Revenue, Payments, Tax, ARPU | Customer value: total income and the average value of each customer |
| Share-based measures | Show concentration and dependency on a plan or class (the basis of Insight 1) |
| Consumption and Calls per Active Customer | Usage intensity and cost to serve, normalized per customer so plans of different sizes can be compared |
| App Users, App Engagement Rate, Actions per App User | Digital adoption, which drives the Digital Self-Servers segment |
| Dormant Customers, New Customers | Churn risk and acquisition, the two sides of base movement |
| PM and MoM % measures | Trend and change over time, which feed the declining-usage finding (Insight 3) |

---

## 5. Dashboard (Power BI)

Four pages, each with slicers for `YearMonth`, `SUBSCRIPTION_PLAN_DESC`, and `CUSTOMER_CLASS`, plus page navigation buttons.

### 5.1 Executive Overview

Headline KPIs: **9,993** customers, **9,422** active, **107.82M** revenue, **ARPU 11,443.44**, **67.70%** app engagement. Charts answer: is revenue growing, is the engaged base growing, which plans drive revenue, who uses the network most, and are customers calling less over time.

### 5.2 Plans & Revenue

- `Plan_Family709908` brings **77.09M (71.5%)** of revenue, followed by `Plan_Family709909` (19.32M, 17.92%) and `Plan_Family709910` (7.99M, 7.41%).
- By class, `B+` generates the most revenue (48.7M), but `A+` has the highest ARPU (24.5K) and `D` the lowest (2.3K).
- `Plan_Family709915` has the highest ARPU among the main plans (15.7K).

### 5.3 Engagement & Usage

- **6,379** app users out of 9,422 active customers (**67.70%** engagement).
- **1.83** calls per active customer and **3.74M MB** average consumption per active customer.
- App engagement rose sharply at the start of the series and then stayed roughly stable around 50-55%.

### 5.4 Customer Behavior & Segments

Presents the Task 7 segmentation: segment size, share, ARPU, consumption, and calls per active customer.

---

## 6. Business Insights & Opportunities

### Insight 1: Revenue Is Highly Concentrated in a Single Plan (Risk)

* **Finding:** A single subscription plan contributes a disproportionately large share of the company's total revenue, creating significant plan-dependency risk.
* **Evidence:**
  * Total Company Revenue = **$107.82M**
  * `Plan_Family709908` Revenue ≈ **$77M** (approximately **71%** of total revenue).
* **Likely Driver:** The plan maintains a massive customer base compared to other offerings, concentrating the majority of commercial value into one plan.
* **Recommended Action:** Mitigate concentration risk by marketing targeted upsell bundles and higher-value plan alternatives to customers outside the dominant plan, while implementing dedicated retention initiatives for existing high-value customers on `Plan_Family709908`.

### Insight 2: A Small, High-Usage, High-Value Plan Is Under-Scaled (Growth Opportunity)

* **Finding:** `Plan_Family709915` serves the heaviest data users and the most valuable customers among the five main plans, but its customer base is so small that it contributes almost nothing to total revenue. The opportunity is scale: growing this base and monetizing heavy usage.
* **Evidence:**
  * Average consumption ≈ **4.4M MB** per active customer, the highest among the five main plans.
  * ARPU ≈ **15.7K**, the highest among the five main plans and above the company ARPU of **11,443**.
  * Only ≈ **1.1%** of customers and ≈ **$1M** of the **$107.82M** total revenue (~0.93%).
* **Likely Driver:** A niche plan with a small base, so strong per-customer value does not translate into total revenue. The data cannot show whether the small base comes from limited marketing, pricing, or eligibility, so this should be validated.
* **Recommended Action:** Identify heavy users on other plans (consumption above their plan's average) and run a targeted migration or upsell campaign toward this plan, and offer premium tiered data add-ons that match actual consumption.

### Insight 3: Declining Usage and Revenue Put Long-Term Customer Value at Risk (Risk)

* **Finding:** The executive dashboard indicates a simultaneous downward trend in customer calling engagement and monthly revenue across the analyzed period.
* **Evidence:**
  * **Calls per Active Customer** decreased from **3+ calls/customer** down to **below 2**.
  * **Monthly Revenue** dropped from approximately **$6M** to roughly **$2.5M**.
* **Likely Driver:** Reduced customer interaction with telecom services may indicate weakening engagement and diminishing activity levels, which can erode customer lifetime value over time (while correlated, direct causation requires further behavioral segmentation).
* **Recommended Action:** Launch proactive re-engagement campaigns aimed at accounts showing early signs of declining call volume or data usage, offering incentives matched to their historical usage patterns.

---

## 7. Customer Segmentation (SQL view + Power BI)

**Deliverable:** `dbo.vw_CustomerSegments` (`sql/CustomerSegments.sql`), one row per subscriber with the segment, supporting metrics, a business interpretation, and a recommended action.

### Metrics per subscriber

| Metric | Source | Definition |
|---|---|---|
| `ConsMB` | Consumption | Total `DAILY_CONSUMPTION_MB` |
| `Revenue` | Payments | Rent + out-of-bundle + in-bundle + add-on + creation fees + devices (tax excluded) |
| `CallCount` | Calls | Number of calls by `SERVICE_NUMBER` |
| `AppEvents` | Mobile_App | Number of app events by `SERVICE_NUMBER` |
| `DaysSinceUse` | Consumption | Days between the last day with consumption > 0 and the latest consumption date in the data |

### Segmentation rules

Rules are applied in priority order; the first match wins. Percentile ranks are calculated **within** the dormant / non-dormant groups, so dormant subscribers do not distort the thresholds for active ones.

| Priority | Segment | Rule |
|---|---|---|
| 1 | **Dormant / At-Risk** | No consumption in the last 90 days of the data (or never) |
| 2 | **High-Value** | Top 20% by revenue among active subscribers |
| 3 | **Support-Dependent** | At least 2 calls and top 25% by call count among active subscribers |
| 4 | **Digital Self-Servers** | Has mobile app activity |
| 5 | **Core / Low-Engagement** | Everyone else |

### Results

| Segment | Customers | Share | ARPU | Avg consumption (MB) | Calls per active customer |
|---|---:|---:|---:|---:|---:|
| Digital Self-Servers | 3,647 | 36.50% | 8,721.68 | 2,931,026 | 0.15 |
| Core / Low-Engagement | 2,193 | 21.95% | 7,398.09 | 2,238,266 | 0.19 |
| High-Value | 1,881 | 18.82% | 22,873.82 | 7,549,625 | 2.73 |
| Support-Dependent | 1,724 | 17.25% | 9,393.53 | 3,109,664 | 6.17 |
| Dormant / At-Risk | 548 | 5.48% | 12,876.53 | 3,808,342 | 4.22 |
| **Total** | **9,993** | **100%** | **11,443.44** | **3,744,521** | **1.83** |

### Interpretation and recommended actions

| Segment | Interpretation | Recommended action |
|---|---|---|
| High-Value | Roughly 19% of customers with about twice the ARPU of any other segment | Proactive retention, priority support, offer for a higher tier |
| Support-Dependent | Call far more than others (6.17 calls each): high cost to serve and an early churn warning | Find the root cause of the calls (billing, network), move them to the app, reach out before they leave |
| Digital Self-Servers | Largest segment; use the app and rarely call, so the cheapest to serve | Sell upgrades and add-ons through the app and keep the app reliable |
| Dormant / At-Risk | No usage in the last 90 days, yet historically high ARPU (12.9K): revenue already lost or about to be | Win-back campaign; check line status and service quality before offering discounts |
| Core / Low-Engagement | Stable customers of average value who barely use the app or call | Maintain the service, introduce app features, cross-sell add-ons |

### Why this segmentation is useful

- **Different actions, not just labels:** each segment maps to a different business lever (retention, cost-to-serve reduction, digital upsell, win-back), so teams can prioritize instead of treating the base as one block.
- **Value and cost together:** it separates who brings revenue (High-Value) from who costs money to serve (Support-Dependent) and who is already leaving (Dormant).
- **Measurable and repeatable:** the rules use only observed behavior (consumption, revenue, calls, app events) and live in a view, so segments refresh automatically with the data.

### Built-in checks

- **Check 1:** segment sizes, distinct customers, average revenue, consumption, calls, and % using the app.
- **Check 2:** `COUNT(*)` equals `COUNT(DISTINCT SUBSCRIBER_ID)`, confirming no duplicate rows in the view.

---

## 8. AI / ML Use Case: Churn (Dormancy) Prediction

**Business question:** which active subscribers are likely to stop using the service soon, so retention teams can act before the revenue is lost? Task 7 shows the cost of waiting: the Dormant / At-Risk segment is only identified *after* 90 days of silence.

### Prediction target

Binary label per subscriber and cut-off date: **1** if the subscriber has **no consumption in the 90 days after the cut-off date**, otherwise **0**. Only subscribers who were active at the cut-off are scored. This reuses the same dormancy definition as the segmentation, so the business already understands it.

### Candidate features (all computed from data before the cut-off)

| # | Feature | Source |
|---|---|---|
| 1 | Consumption trend: last 30 days vs. the previous 30 days (% change) | Consumption |
| 2 | Days since last consumption | Consumption |
| 3 | Revenue in the last 3 months and its change vs. the prior 3 months | Payments |
| 4 | Number of calls in the last 90 days | Calls |
| 5 | Mobile-app events in the last 90 days | Mobile_App |
| 6 | Subscription plan family and monthly plan price | DimPlan |
| 7 | Customer class | DimCustomer |
| 8 | Tenure (cut-off date minus `ACTIVATION_DATE`) | DimCustomer |

### Train / test split

Use a **time-based split**, not a random one. Build several monthly cut-off snapshots; train on the earlier cut-offs and test on the most recent cut-off(s) whose 90-day outcome window is fully observed. This mimics real use (predicting the future from the past). All snapshots of the same subscriber stay on the same side of the split.

### Evaluation metrics

Dormant subscribers are a small minority (about 5.5% in the segmentation), so accuracy would be misleading.

- **PR-AUC (average precision):** overall ranking quality under class imbalance.
- **Recall and precision at top-k (for example, the top 10% highest-risk subscribers):** reflects the real constraint that the retention team can only contact a limited number of customers.

### Preventing data leakage

Compute every feature strictly from data **dated before the cut-off**, and the label strictly from the 90 days after it. Exclude subscribers who are already dormant at the cut-off and do not use any field that is only populated after churn (for example, a deactivation status or flag). Fit any scaling or encoding on the training set only.

### Use in Power BI

1. Score subscribers on a schedule (Python or SQL Server ML) and write results to a table such as `CustomerChurnScore` (`SUBSCRIBER_ID`, `ScoreDate`, `ChurnProbability`, `RiskBand`, top contributing factors).
2. Relate it to `DimCustomer` (and `DimDate` through `ScoreDate`) in the existing model.
3. Add a report page with: subscribers per risk band, **revenue at risk** (probability × revenue), risk by plan and customer class, and a drill-through list of the highest-risk, highest-value subscribers for the retention team.

### Monitoring model and data drift

- **Data drift:** track the Population Stability Index (PSI) or distribution shifts for each feature, plus null rates, row counts, and data freshness per source table.
- **Score drift:** compare the monthly distribution of predicted probabilities against the training baseline.
- **Model performance:** once each 90-day outcome window closes, recompute PR-AUC and precision/recall at top-k on the real outcomes.
- **Triggers:** retrain when PSI or performance crosses an agreed threshold, or when plans, pricing, or the data pipeline change.

### Why predictions support, not replace, decisions

A prediction is a probability, not a fact, and it does not explain *why* a customer is leaving. Acting automatically could waste discounts on customers who would have stayed, or miss causes the data cannot see (network problems, competitor offers). A person should check the context, choose the right action (for example, service check before discount), and compare against a holdout group to measure whether the intervention actually works.

---

## Limitations

- The dataset has no churn or deactivation field, so "dormant" is an inferred proxy (no consumption for 90 days), not confirmed churn.
- The data cannot show *why* usage or revenue dropped. Causes such as network quality, pricing changes, competitor offers, or seasonality would need extra data (tickets, network KPIs, tariff history, competitor/market data).
- The end of the time series appears incomplete (see the notes below), which weakens conclusions about the most recent period.
- Insights are correlations observed in the dashboard; they do not prove causation.

## Explaining an inconclusive finding to a non-technical manager

"We can see that usage dropped, but the data we have only shows *what* changed, not *why*. Think of it like seeing fewer customers in a shop without knowing whether it's the weather, a competitor, or a closed road. Here is what we know, what we don't, and the next step: we'll check the likely causes with the extra data we need (such as network quality and complaints) before spending money on a fix."

---

## Notes and Assumptions

- **Revenue definition:** Task 1 and 2 `Total_Payments` includes `TAX_AMOUNT`; the Task 7 segmentation `Revenue` excludes it. Keep this in mind when comparing figures across tasks.
- **Dormancy reference date:** "last 90 days" is measured from the latest consumption date in the dataset, not from today's date.
- **Time-series tail:** the Active Customers chart drops close to zero at the very end of the series. This probably reflects incomplete data for the final period, so conclusions about recent trends (such as Insight 3) should be validated against data completeness.
- **Segment thresholds** (90 days, top 20% revenue, top 25% calls, minimum 2 calls) are business-rule choices and can be tuned in the view.

## How to Reproduce

1. Create the database and load the CSV files into `We_BI` (Import Wizard).
2. Run `sql/Task1_Task2.sql` for Tasks 1 and 2.
3. Run `sql/CustomerSegments.sql` to create `vw_CustomerSegments` (Task 7).
4. In Power BI, connect to `We_BI`, build the model and `DAXMeasures` table, and import `vw_CustomerSegments`.
