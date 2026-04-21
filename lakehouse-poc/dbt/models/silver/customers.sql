WITH ranked AS (
  SELECT
    id, name, email, city, created_at, updated_at, __op,
    ROW_NUMBER() OVER (PARTITION BY id ORDER BY updated_at DESC) AS rn
  FROM {{ source('bronze', 'customers') }}
  WHERE __op != 'd'
)
SELECT id, name, email, city, created_at, updated_at, __op
FROM ranked
WHERE rn = 1
