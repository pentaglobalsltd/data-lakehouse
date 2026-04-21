WITH ranked AS (
  SELECT
    id, name, category, price, stock, created_at, updated_at, __op,
    ROW_NUMBER() OVER (PARTITION BY id ORDER BY updated_at DESC) AS rn
  FROM {{ source('bronze', 'products') }}
  WHERE __op != 'd'
)
SELECT id, name, category, price, stock, created_at, updated_at, __op
FROM ranked
WHERE rn = 1
