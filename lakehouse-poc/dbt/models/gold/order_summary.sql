SELECT
  c.city,
  SUM(o.total_amount)  AS total_revenue,
  COUNT(o.id)          AS order_count,
  AVG(o.total_amount)  AS avg_order_value
FROM {{ ref('orders') }} o
JOIN {{ ref('customers') }} c ON o.customer_id = c.id
GROUP BY c.city
