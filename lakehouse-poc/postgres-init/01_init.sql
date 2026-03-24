-- ─── Replication settings (also set via postgres command args in compose) ───
ALTER SYSTEM SET wal_level = 'logical';
ALTER SYSTEM SET max_replication_slots = 5;
ALTER SYSTEM SET max_wal_senders = 5;
SELECT pg_reload_conf();

-- ─── Tables ───────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS customers (
    id          BIGSERIAL PRIMARY KEY,
    name        VARCHAR(200)        NOT NULL,
    email       VARCHAR(200)        NOT NULL UNIQUE,
    city        VARCHAR(100)        NOT NULL,
    created_at  TIMESTAMPTZ         NOT NULL DEFAULT NOW(),
    updated_at  TIMESTAMPTZ         NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS products (
    id          BIGSERIAL PRIMARY KEY,
    name        VARCHAR(300)        NOT NULL,
    category    VARCHAR(100)        NOT NULL,
    price       NUMERIC(12, 2)      NOT NULL,
    stock       INTEGER             NOT NULL DEFAULT 0,
    created_at  TIMESTAMPTZ         NOT NULL DEFAULT NOW(),
    updated_at  TIMESTAMPTZ         NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS orders (
    id            BIGSERIAL PRIMARY KEY,
    customer_id   BIGINT             NOT NULL REFERENCES customers(id),
    product_id    BIGINT             NOT NULL REFERENCES products(id),
    quantity      INTEGER            NOT NULL DEFAULT 1,
    total_amount  NUMERIC(14, 2)     NOT NULL,
    status        VARCHAR(50)        NOT NULL DEFAULT 'pending',
    created_at    TIMESTAMPTZ        NOT NULL DEFAULT NOW(),
    updated_at    TIMESTAMPTZ        NOT NULL DEFAULT NOW()
);

-- ─── Seed: customers (25 rows — Bangladeshi e-commerce) ───────────────────
INSERT INTO customers (name, email, city) VALUES
('Rahim Uddin',         'rahim.uddin@example.com',       'Dhaka'),
('Sumaiya Begum',       'sumaiya.begum@example.com',     'Chittagong'),
('Karim Ahmed',         'karim.ahmed@example.com',       'Sylhet'),
('Nasrin Akter',        'nasrin.akter@example.com',      'Rajshahi'),
('Mizanur Rahman',      'mizanur.rahman@example.com',    'Khulna'),
('Fatema Khanam',       'fatema.khanam@example.com',     'Barisal'),
('Abdullah Al Mamun',   'mamun.al@example.com',          'Mymensingh'),
('Sharmin Sultana',     'sharmin.s@example.com',         'Comilla'),
('Jahangir Alam',       'jahangir.alam@example.com',     'Dhaka'),
('Roksana Parvin',      'roksana.p@example.com',         'Chittagong'),
('Md. Rafiqul Islam',   'rafiq.islam@example.com',       'Narayanganj'),
('Halima Begum',        'halima.b@example.com',          'Gazipur'),
('Shafiqul Haque',      'shafiq.haque@example.com',      'Tongi'),
('Moriom Khatun',       'moriom.k@example.com',          'Sylhet'),
('Anwar Hossain',       'anwar.h@example.com',           'Rajshahi'),
('Bilkis Akhtar',       'bilkis.a@example.com',          'Dhaka'),
('Sohel Rana',          'sohel.r@example.com',           'Khulna'),
('Runa Laila',          'runa.l@example.com',            'Barisal'),
('Nurul Islam',         'nurul.i@example.com',           'Bogura'),
('Sabina Yasmin',       'sabina.y@example.com',          'Jessore'),
('Mosharraf Hossain',   'moshraf.h@example.com',         'Dhaka'),
('Nargis Sultana',      'nargis.s@example.com',          'Chittagong'),
('Fazlur Rahman',       'fazlur.r@example.com',          'Comilla'),
('Suraia Begum',        'suraia.b@example.com',          'Mymensingh'),
('Imran Khan',          'imran.k@example.com',           'Sylhet');

-- ─── Seed: products (25 rows — Bangladeshi e-commerce categories) ─────────
INSERT INTO products (name, category, price, stock) VALUES
('Aarong Cotton Panjabi',          'Clothing',       1250.00,  80),
('Bata Leather Oxford Shoes',      'Footwear',       3500.00,  45),
('Walton LED TV 32"',              'Electronics',   22000.00,  20),
('Fair & White Face Cream 50ml',   'Beauty',          350.00, 200),
('Igloo Ice Cream Chocolate 2L',   'Food',            320.00, 150),
('ACI Pure Mustard Oil 1L',        'Groceries',       220.00, 300),
('Transcom Laptop Bag 15"',        'Accessories',    1800.00,  60),
('Pran Mango Juice 1L',            'Beverages',        80.00, 500),
('Symphony Z50 Smartphone',        'Electronics',   12500.00,  35),
('Otobi Study Table',              'Furniture',      8500.00,  15),
('Hatil Wooden Chair',             'Furniture',      4200.00,  25),
('BPL Smart Refrigerator 250L',    'Electronics',   38000.00,  12),
('Nasir Glass Tumbler Set 6pc',    'Kitchenware',     650.00, 100),
('Square Paracetamol 500mg x20',   'Healthcare',       45.00, 800),
('Partex MDF Bookshelf',           'Furniture',      6200.00,  18),
('Renata Vitamin C Tablets x30',   'Healthcare',      180.00, 400),
('Pran Chanachur 200g',            'Snacks',           55.00, 600),
('Bashundhara A4 Paper 500 Sheets','Stationery',      450.00, 200),
('Rangs Electronics Iron',         'Appliances',     1600.00,  50),
('Navana Ceiling Fan 56"',         'Appliances',     3800.00,  30),
('Star Ceramic Dinner Set 12pc',   'Kitchenware',    2200.00,  40),
('Organic BD Honey 500g',          'Food',            480.00, 120),
('ACI Mosquito Coil 10pc',         'Household',        60.00, 700),
('Meril Splash Body Lotion 200ml', 'Beauty',          195.00, 250),
('Grameenphone SIM Card',          'Telecom',          10.00, 1000);

-- ─── Seed: orders (25 rows) ───────────────────────────────────────────────
INSERT INTO orders (customer_id, product_id, quantity, total_amount, status) VALUES
(1,  3,  1,  22000.00, 'delivered'),
(2,  1,  2,   2500.00, 'delivered'),
(3,  9,  1,  12500.00, 'shipped'),
(4,  6,  5,   1100.00, 'delivered'),
(5, 10,  1,   8500.00, 'pending'),
(6,  4,  3,   1050.00, 'delivered'),
(7, 12,  1,  38000.00, 'processing'),
(8,  2,  1,   3500.00, 'delivered'),
(9,  7,  2,   3600.00, 'shipped'),
(10, 5,  4,   1280.00, 'delivered'),
(11, 20, 1,   3800.00, 'pending'),
(12, 18, 3,   1350.00, 'delivered'),
(13, 11, 2,   8400.00, 'shipped'),
(14, 8, 10,    800.00, 'delivered'),
(15, 16, 5,    900.00, 'delivered'),
(16, 21, 1,   2200.00, 'processing'),
(17, 19, 1,   1600.00, 'delivered'),
(18, 14, 4,    180.00, 'delivered'),
(19, 15, 1,   6200.00, 'pending'),
(20, 22, 2,    960.00, 'delivered'),
(21, 13, 1,    650.00, 'delivered'),
(22, 24, 3,    585.00, 'shipped'),
(23, 17, 6,    330.00, 'delivered'),
(24, 23, 10,   600.00, 'delivered'),
(25, 25, 1,     10.00, 'delivered');

-- ─── Debezium publication ─────────────────────────────────────────────────
-- lakeuser is the postgres superuser so publication works out of the box
CREATE PUBLICATION dbz_publication FOR ALL TABLES;
