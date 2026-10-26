-- Part 2, Task 2: total revenue per RFM segment
-- Runs as-is in any Snowflake account (uses the free SNOWFLAKE_SAMPLE_DATA share).
-- The CTEs are identical in every file; only the final SELECT differs.

USE SCHEMA SNOWFLAKE_SAMPLE_DATA.TPCH_SF1;

-- =====================================================================
-- 1. Customer base with nation info (join customer -> nation to add country details)
-- =====================================================================
WITH customer_base AS (
    SELECT
        c.c_custkey    AS customer_id,
        c.c_name       AS customer_name,
        c.c_address    AS customer_address,
        c.c_phone      AS customer_phone,
        c.c_acctbal    AS account_balance,
        c.c_mktsegment AS market_segment,
        n.n_name       AS nation_name
    FROM
        customer c
        INNER JOIN nation n ON c.c_nationkey = n.n_nationkey -- match customer to their nation
),

-- =====================================================================
-- 2. Orders and line items
-- =====================================================================
orders_base AS (
    SELECT
        o.o_orderkey  AS order_id,
        o.o_custkey   AS customer_id,
        o.o_orderdate AS order_date
    FROM
        orders o
),

lineitem_base AS (
    SELECT
        l.l_orderkey      AS order_id,
        l.l_extendedprice AS extended_price,
        l.l_discount      AS discount
    FROM
        lineitem l
),

-- =====================================================================
-- 3. Snapshot date used for recency calculation (latest order in dataset)
-- =====================================================================
snapshot_cte AS (
    SELECT
        MAX(order_date) AS snapshot_date
    FROM
        orders_base
),

-- =====================================================================
-- 4. Aggregate customer-level RFM metrics
--    Calculate frequency, monetary value, average order value, and order dates
-- =====================================================================
customer_order_summary AS (
    SELECT
        c.customer_id,
        -- Frequency: total number of orders per customer
        COUNT(DISTINCT o.order_id) AS total_orders,
        -- Monetary: total revenue per customer
        ROUND(
            COALESCE(
                SUM(l.extended_price * (1 - l.discount)),
                0
            ),
            2
        ) AS total_revenue,
        -- Average Order Value: revenue / number of orders
        ROUND(
            COALESCE(
                NULLIF(SUM(l.extended_price * (1 - l.discount)), 0) / NULLIF(COUNT(DISTINCT o.order_id), 0),
                0
            ),
            2
        ) AS avg_order_value,
        -- First and last order dates for recency calculation
        MIN(o.order_date) AS first_order_date,
        MAX(o.order_date) AS last_order_date
    FROM
        customer_base c
        -- Join orders for each customer (may be no orders, hence LEFT JOIN)
        LEFT JOIN orders_base o ON c.customer_id = o.customer_id
        -- Join line items for each order to calculate revenue and AOV
        LEFT JOIN lineitem_base l ON o.order_id = l.order_id
    -- Group by customer to aggregate all metrics at customer level
    GROUP BY
        c.customer_id
),

-- =====================================================================
-- 5. Recency calculation
--    Calculate days since the last order for each customer
--    If the customer has no orders, use a default early date ('1900-01-01')
-- =====================================================================
recency_calc AS (
    SELECT
        s.customer_id,
        s.total_orders,
        s.total_revenue,
        s.avg_order_value,
        s.first_order_date,
        s.last_order_date,
        -- Recency in days: difference between snapshot date and last order date
        DATEDIFF(
            DAY,
            COALESCE(s.last_order_date, '1900-01-01'),
            snap.snapshot_date
        ) AS recency_days
    FROM
        customer_order_summary s
        CROSS JOIN snapshot_cte snap
),

-- =====================================================================
-- 6. RFM scoring using NTILE
--    Assign scores (1-5) for Recency, Frequency, and Monetary metrics
--    Higher score = better customer
-- =====================================================================
rfm_scores AS (
    SELECT
        r.customer_id,
        r.recency_days,
        r.total_orders,
        r.total_revenue,
        r.avg_order_value,
        r.first_order_date,
        r.last_order_date,
        -- Recency score: lower recency_days = more recent = better
        -- DESC used so most recent customers get highest score (5)
        NTILE(5) OVER (
            ORDER BY
                r.recency_days DESC
        ) AS r_score,
        -- Frequency score: higher total_orders = better
        -- ASC used so customers with the most orders get the highest score (5)
        NTILE(5) OVER (
            ORDER BY
                COALESCE(r.total_orders, 0) ASC
        ) AS f_score,
        -- Monetary score: higher total_revenue = better
        -- ASC used so customers with the highest revenue get the highest score (5)
        NTILE(5) OVER (
            ORDER BY
                COALESCE(r.total_revenue, 0) ASC
        ) AS m_score,
        -- Combined RFM score: sum of Recency, Frequency, and Monetary scores
        (r_score + f_score + m_score) AS rfm_score
    FROM
        recency_calc r
),

-- =====================================================================
-- 7. Final enriched RFM dataset
--    Combine RFM scores with customer details and assign RFM segments
-- =====================================================================
final_rfm AS (
    SELECT
        r.customer_id,
        cb.customer_name,
        cb.customer_address,
        cb.customer_phone,
        cb.account_balance,
        cb.market_segment,
        cb.nation_name,
        -- Last order date and aggregated metrics
        r.last_order_date,
        r.total_revenue,
        r.total_orders,
        r.avg_order_value,
        r.recency_days,
        -- RFM scores
        r.r_score,
        r.f_score,
        r.m_score,
        r.rfm_score,
        -- Segment assignment based on combined RFM score
        CASE
            WHEN r.rfm_score BETWEEN 12 AND 15 THEN 'Platinum (High Value)'
            WHEN r.rfm_score BETWEEN 8 AND 11 THEN 'Gold (Loyal)'
            WHEN r.rfm_score BETWEEN 4 AND 7 THEN 'Silver (At Risk)'
            ELSE 'Bronze (Inactive)'
        END AS rfm_segment
    FROM
        rfm_scores r
        LEFT JOIN customer_base cb ON r.customer_id = cb.customer_id -- Join to get customer details
)

-- Total revenue contribution by each RFM segment
SELECT
    rfm_segment,
    -- Total revenue generated by the segment
    SUM(total_revenue) AS segment_revenue,
    -- Percentage of total segment revenue
    ROUND(
        SUM(total_revenue) * 100.0 / SUM(SUM(total_revenue)) OVER (),
        2
    ) AS percentage_of_total_revenue
FROM
    final_rfm
GROUP BY
    rfm_segment
ORDER BY
    segment_revenue DESC;
