WITH ranked AS (
  SELECT
    id, customer_id, product_id, quantity, total_amount, status,
    created_at, updated_at, __op,
    ROW_NUMBER() OVER (PARTITION BY id ORDER BY updated_at DESC) AS rn
  FROM {{ source('bronze', 'orders') }}
  WHERE __op != 'd'
)
SELECT id, customer_id, product_id, quantity, total_amount, status,
       created_at, updated_at, __op
FROM ranked
WHERE rn = 1
