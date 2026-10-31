# Hướng dẫn dựng Power BI (Module 5)

Giao diện Power BI Desktop tiếng Anh; tên nút để nguyên tiếng Anh. Làm đúng thứ tự. Lưu file ngay sau mỗi bước lớn: `powerbi/FinanceDW.pbix`.

## 0. Cài đặt
- Microsoft Store → "Power BI Desktop" → Install → mở → đóng màn hình chào.

## 1. Tham số kết nối (để đổi máy không phải sửa query – TC-DSH-04)
1. Tab **Home** → **Transform data** (mở cửa sổ Power Query).
2. Tab **Home** → **Manage Parameters** → **New Parameter**.
3. Parameter 1: Name `ServerName` · Type `Text` · Current Value `localhost` hoặc `localhost\TEN_INSTANCE` (đúng tên SQL Server của bạn) → bấm **New** (góc dưới trái) để tạo parameter tiếp theo.
4. Parameter 2: Name `DatabaseName` · Type `Text` · Current Value `FinanceDW` → OK.

## 2. Nạp 9 bảng
Trong cửa sổ Power Query, lặp **9 lần** (mở `powerbi/queries.m`, mỗi lần dán 1 khối `let … in …`):
1. **Home** → **New Source** → **Blank Query**.
2. **Home** → **Advanced Editor** → xóa hết → dán 1 khối → **Done**.
3. Khi hỏi credentials: **Edit Credentials** → chọn **Windows** → **Connect** (nếu hỏi encryption: **OK**).
4. Panel **Queries** bên trái: chuột phải query → **Rename** → đặt đúng tên bảng (`dim_date`, `dim_product`, `dim_customer`, `dim_territory`, `dim_salesperson`, `dim_vendor`, `fact_sales`, `fact_purchasing`, `fact_quota`).
5. Xong 9 query → **Home** → **Close & Apply**. Chờ nạp (~121k dòng, vài giây).

## 3. Mô hình (Model view – biểu tượng thứ 3 bên trái)
Xóa mọi quan hệ Power BI tự tạo sai; cần đúng **10 quan hệ**, mỗi quan hệ **Many-to-one (*:1)**, **Single** direction, kéo từ cột bảng fact sang cột cùng tên bảng dim:

| Fact | Cột | → Dim |
|---|---|---|
| fact_sales | date_key | dim_date |
| fact_sales | product_key | dim_product |
| fact_sales | customer_key | dim_customer |
| fact_sales | territory_key | dim_territory |
| fact_sales | salesperson_key | dim_salesperson |
| fact_purchasing | date_key | dim_date |
| fact_purchasing | product_key | dim_product |
| fact_purchasing | vendor_key | dim_vendor |
| fact_quota | salesperson_key | dim_salesperson |
| fact_quota | date_key | dim_date |

Bố cục: dim ở trên, fact ở dưới (hình sao). Không được có quan hệ **Both** hay **Many-to-many**.

Đánh dấu bảng ngày: Table view → bấm bảng `dim_date` → tab **Table tools** → **Mark as date table** → Date column = `full_date` → OK.

Ẩn cột kỹ thuật (Data view/Model view → chuột phải cột → **Hide in report view**): tất cả `*_key`, `*_id` trong fact; `date_key` trong dim_date.

## 4. Measure DAX
1. **Home** → **Enter data** → Name `_Measures` → **Load** (bảng rỗng chứa measure).
2. Bấm bảng `_Measures` trong panel Data → **Home** → **New measure** → dán 1 khối từ `powerbi/measures.dax` → Enter. Lặp cho cả **21 measure**.
3. Định dạng (tab **Measure tools**): `Revenue`, `COGS`, `Gross Profit`, `Discount Amount`, `Avg Order Value`, `Purchase Amount`, `Quota Amount`, `Actual Revenue (Sales Reps)` → Currency `$` 0 thập phân; các `%` → Percentage 1 thập phân.

## 5. Kiểm tra DAX (Gate 4 – TC-DAX)
1. Tạo **Matrix**: Rows = `dim_date[year]`; Values = Revenue, COGS, Gross Profit, Gross Margin %, Discount Amount, Orders, Units Sold, Avg Order Value, Purchase Amount, Quota Amount.
2. Chạy `tests/dax_reference.sql` trong SSMS; so từng cột theo từng năm (lệch ≤ 0.01 là khớp).
3. Thêm cột Revenue YoY %, Period Status, Quota Attainment % → đối chiếu kết quả 3–4 của SQL.
4. Báo lại: **bảng nào lệch** (năm, cột, hai giá trị). Nếu khớp hết: "DAX khớp".

| Test | Cách kiểm | Mong đợi |
|---|---|---|
| TC-DAX-01 | Năm đầu tiên trong data (2011) | Revenue YoY % = trống, không lỗi |
| TC-DAX-02 | Chọn 1 tháng/nhân viên không có doanh thu | Gross Margin %, Quota Attainment % trống, không lỗi |
| TC-DAX-03 | Năm 2014 | Period Status = "Chưa đủ dữ liệu…", YoY trống |
| TC-DAX-04 | Bước 1–3 ở trên | Khớp 100% |

## 6. Dashboard 3 trang
Khổ trang: tab **View** → **Page view** → **Fit to page**; **Format page → Canvas settings** = 16:9. Đổi tên trang bằng chuột phải tab.

**Trang 1 – Tổng quan**
- Slicer: `dim_date[year]` (kiểu Dropdown), `dim_territory[name]`, `dim_product[category]`.
- 5 **Card**: Revenue, Gross Profit, Gross Margin %, Orders, Revenue YoY %.
- **Line chart**: Axis = `dim_date[year_month]`; Values = Revenue, Revenue PY.
- **Clustered bar**: Axis = `dim_product[category]`; Values = Revenue.
- **Card** văn bản: Period Status; **Card**: No Data Message (đặt giữa trang, chữ đỏ → hiện khi lọc ra rỗng).

**Trang 2 – Đội bán hàng & Quota**
- Slicer: year. **Matrix**: Rows = `dim_salesperson[full_name]`, Columns = `dim_date[year]`; Values = Quota Amount, Actual Revenue (Sales Reps), Quota Attainment %. Conditional formatting: Attainment % < 100% đỏ, ≥ 100% xanh.
- **Clustered column**: Axis = `dim_territory[name]`; Values = Revenue.
- Chú thích văn bản: "Quota chỉ có theo quý; cấp tháng không so sánh."

**Trang 3 – Mua hàng & Sản phẩm**
- **Bar**: Axis = `dim_vendor[name]` (Top 10 theo Purchase Amount: Filters → Top N); Values = Purchase Amount.
- **Table**: `dim_product[name]` Top 10 theo Gross Profit; cột Revenue, Gross Profit, Gross Margin %.
- **Line**: `dim_date[year_month]`, Purchase Amount.

## 7. Kiểm tra dashboard (Gate 4 – TC-DSH)
| Test | Cách kiểm | Mong đợi |
|---|---|---|
| TC-DSH-01 | Trang 1: chọn tổ hợp year + territory cho kết quả rỗng | Thấy "Không có dữ liệu…" |
| TC-DSH-02 | Đổi slicer, bấm đồng hồ | Mọi visual cập nhật ≤ 3 giây (tab **View** → **Performance analyzer** → Start recording → đổi slicer → xem Duration) |
| TC-DSH-03 | **View → Page view → Actual size**, thu cửa sổ ~1366×768 và 1920×1080 | Không tràn, không che nhau |
| TC-DSH-04 | **Transform data → Edit parameters** → đổi `DatabaseName` sai → Refresh (phải báo lỗi rõ), đổi lại đúng → Refresh | Refresh thành công |

## 8. Xuất ảnh & chuẩn bị đưa lên GitHub (TC-REP-01)
- **File → Export → Export to PDF**; chụp từng trang lưu `docs/dashboard_p1.png`, `p2`, `p3`.
- Parameter lưu trong .pbix: trước khi commit, **Save As** bản `powerbi/FinanceDW_public.pbix` với `ServerName` = `localhost` (bản đang làm giữ nguyên tên máy thật; `.gitignore` đã loại `config.json`, không loại .pbix nên **chỉ commit bản _public**).
