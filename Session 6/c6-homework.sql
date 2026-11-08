-- Bài tập về nhà: đối soát sản phẩm đã bị xóa ở nguồn
--
-- Mục tiêu: tìm sản phẩm còn trong dimension nhưng đã bị xóa ở nguồn, đánh dấu xóa mềm, và kiểm tra đơn cũ vẫn nối được.
--
-- Đầu vào có sẵn:
-- - `dim_products_t1` (Bài tập 1).
-- - Bronze `products` (`stylehub_ab_bronze.products`), stream Full refresh | Append: mỗi lần sync ghi lại cả bảng nguồn. Id đã bị xóa ở nguồn thì không còn xuất hiện ở lần sync cuối.
-- - `fact_order_items` (Buổi 5).

-- Phần 1. Đếm và tìm id bị xóa
-- So số dòng của dimension với số id xuất hiện ở lần sync cuối. Rồi tạo bảng `deleted_product_ids` gồm id có trong Bronze nhưng không còn xuất hiện ở lần sync cuối (dùng CTE `last_seen`, không dùng subquery).
-- TODO: đếm dòng của dim_products_t1 và số id ở lần sync cuối của Bronze products
WITH last_sync AS (
  SELECT MAX(_airbyte_extracted_at) AS last_sync_at
  FROM `laurenprj123.stylehub_airbyte_bronze.products`
),
dim_count AS (
  SELECT COUNT(*) AS row_count
  FROM `laurenprj123.stylehub_silver.dim_products_t1`
),
source_count AS (
  SELECT COUNT(DISTINCT b.id) AS row_count
  FROM `laurenprj123.stylehub_airbyte_bronze.products` AS b
  CROSS JOIN last_sync AS s
  WHERE b._airbyte_extracted_at >= TIMESTAMP_SUB(s.last_sync_at, INTERVAL 10 MINUTE)
)
SELECT
  d.row_count AS dim_count,
  c.row_count AS source_count
FROM dim_count AS d
CROSS JOIN source_count AS c;

-- TODO: CREATE OR REPLACE TABLE deleted_product_ids AS ...
CREATE OR REPLACE TABLE `laurenprj123.stylehub_silver.deleted_product_ids` AS
WITH last_sync AS (
  SELECT MAX(_airbyte_extracted_at) AS last_sync_at
  FROM `laurenprj123.stylehub_airbyte_bronze.products`
),
last_seen AS (
  SELECT
    id,
    MAX(_airbyte_extracted_at) AS last_seen_at
  FROM `laurenprj123.stylehub_airbyte_bronze.products`
  GROUP BY 1
)
SELECT l.id AS product_id
FROM last_seen AS l
CROSS JOIN last_sync AS s
WHERE l.last_seen_at < TIMESTAMP_SUB(s.last_sync_at, INTERVAL 10 MINUTE);

-- Phần 2. Thêm cột xóa mềm và đánh dấu
-- Thêm hai cột `is_deleted` (BOOL) và `deleted_at` (TIMESTAMP) vào `dim_products_t1`. Đặt `is_deleted = FALSE` cho mọi dòng, rồi đặt `TRUE` và `deleted_at` cho id trong `deleted_product_ids`.
-- TODO: ALTER TABLE dim_products_t1 ADD COLUMN ...
ALTER TABLE `laurenprj123.stylehub_silver.dim_products_t1`
  ADD COLUMN IF NOT EXISTS is_deleted BOOL,
  ADD COLUMN IF NOT EXISTS deleted_at TIMESTAMP;

-- TODO: UPDATE đặt is_deleted = FALSE cho mọi dòng
UPDATE `laurenprj123.stylehub_silver.dim_products_t1`
SET is_deleted = FALSE
WHERE TRUE;

-- TODO: UPDATE đặt is_deleted = TRUE, deleted_at cho id đã bị xóa
UPDATE `laurenprj123.stylehub_silver.dim_products_t1` AS d
SET
  is_deleted = TRUE,
  deleted_at = CURRENT_TIMESTAMP()
FROM `laurenprj123.stylehub_silver.deleted_product_ids` AS x
WHERE d.product_id = x.product_id;


-- Phần 3. Kiểm tra đơn cũ vẫn nối được
-- Đếm số sản phẩm, số dòng đơn, doanh thu theo `is_deleted`. Đơn của sản phẩm đã xóa vẫn phải còn trong `fact_order_items`.
-- TODO: LEFT JOIN fact_order_items với dim_products_t1, GROUP BY is_deleted
SELECT
  d.is_deleted,
  COUNT(DISTINCT d.product_id) AS product_count,
  COUNT(f.order_item_id) AS order_item_count,
  SUM(f.amount) AS revenue
FROM `laurenprj123.stylehub_silver.dim_products_t1` AS d
LEFT JOIN `laurenprj123.stylehub_silver.fact_order_items` AS f
  ON f.product_id = d.product_id
GROUP BY d.is_deleted;

-- Phần 4. Trả lời ngắn (viết câu trả lời ngay dưới các câu hỏi)

-- 1. Vì sao đánh dấu xóa mềm thay vì xóa dòng khỏi `dim_products_t1`?
/*Các bảng fact (đơn hàng, giao dịch...) vẫn tham chiếu product_id của sản phẩm đã bị xóa ở nguồn. 
Nếu xóa cứng dòng trong dim, các fact này mất khóa join. 
Báo cáo lịch sử sẽ thiếu tên và danh mục sản phẩm, hoặc doanh thu cũ bị rơi mất khi dùng inner join. 
Xóa mềm (cờ is_deleted, kèm deleted_at) giữ nguyên lịch sử và khả năng truy vết, vẫn lọc được khỏi báo cáo hiện tại bằng WHERE NOT is_deleted. 
Việc phát hiện xóa cũng có thể sai khi một lần sync lỗi chỉ lấy được một phần dữ liệu. 
Xóa mềm thì khôi phục được, còn xóa cứng thì mất dữ liệu không lấy lại được. 
Ngoài ra, nó còn phục vụ kiểm toán: biết sản phẩm nào bị xóa và từ khi nào.*/

-- 2. Nếu một id từng bị đánh dấu xóa rồi xuất hiện lại ở nguồn, cần xử lý thế nào?
/*Không tạo dòng mới:
- Mỗi lần chạy, MERGE theo product_id. 
-> Id có mặt ở lần sync cuối (không còn trong deleted_product_ids) thì đặt is_deleted = FALSE và deleted_at = NULL, đồng thời cập nhật lại các thuộc tính từ nguồn.
- Nên ghi thêm restored_at (hoặc lưu lịch sử trạng thái) để biết id này từng bị xóa rồi quay lại, tránh mất dấu vết.
- Nếu dim_products_t1 đang theo SCD Type 2, thì đóng dòng hiện tại và mở dòng mới với is_deleted = FALSE, thay vì ghi đè.
- Bảng deleted_product_ids dạng CREATE OR REPLACE tính lại từ đầu mỗi lần nên id quay lại tự biến mất khỏi đó.
*/



