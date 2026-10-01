# CompanyX — Sales Intelligence & Forecasting

Project triển khai từ `CompanyX.bak`: SQL Server → staging và kiểm tra dữ liệu → star schema/SCD2 → Python forecasting → Power BI.

**Bắt đầu với [`powerbi/CompanyX.pbip`](powerbi/CompanyX.pbip)** để mở report, hoặc xem [hướng dẫn chạy](docs/RUNBOOK.md). Source riêng `CompanyX_BI_Source` và warehouse `CompanyX_BI_DW` đã được tạo trên `localhost`. Database `CompanyX` ban đầu được giữ nguyên.

## Đã triển khai

| Thành phần | Tệp / đầu ra |
|---|---|
| Restore an toàn, DDL, SCD2, ETL, audit, quarantine | [`sql/`](sql/) |
| SSIS Execute SQL Task gọi ETL transaction | [`ssis/CompanyX_IncrementalSales.dtsx`](ssis/CompanyX_IncrementalSales.dtsx) |
| Baselines, SARIMA, XGBoost, walk-forward và holdout | [`src/companyx/forecasting.py`](src/companyx/forecasting.py) |
| Train/scoring và ghi kết quả về SQL | [`src/companyx/pipeline.py`](src/companyx/pipeline.py) |
| Power BI: 4 trang, model, quan hệ, DAX | [`powerbi/CompanyX.pbip`](powerbi/CompanyX.pbip) |
| Lịch ETL 5 phút, đối soát đêm, scoring ngày, train tuần | [`scripts/install_agent_jobs.ps1`](scripts/install_agent_jobs.ps1) |
| Bằng chứng dữ liệu, mô hình, kiểm thử | [`artifacts/`](artifacts/) |
| Thiết kế, case studies và đối chiếu rubric | [`docs/DESIGN.md`](docs/DESIGN.md) |

## Kết quả trên backup được cung cấp

- Thời gian đơn hàng: **2011-05-31 → 2014-06-30**; 31.465 đơn, 121.317 dòng nguồn.
- **63 dòng lỗi** được cách ly: 22 dòng lỗi giá, 41 dòng lỗi số lượng. Không tự điền giá hoặc số lượng.
- Fact chứa **121.254 dòng hợp lệ** thuộc mọi trạng thái. KPI chỉ dùng **120.084 dòng của các đơn đã giao**; 315 đơn bị hủy không đóng góp doanh thu.
- Net Sales hợp lệ đã giao: **108.748.471,688061 đơn vị tiền tệ nguồn**, sau chiết khấu, chưa gồm thuế và vận chuyển. Không tự quy đổi sang VND.
- Forecast dùng **160 tuần đầy đủ**, bỏ hai tuần biên chưa đủ ngày; horizon **8 tuần**.
- SARIMA được chọn từ validation. **wMAPE holdout khoảng 535%**, coverage của khoảng dự báo khoảng 75% trên 8 quan sát. Kết quả được gắn `REVIEW_REQUIRED`; chưa đủ tốt để tự động điều chỉnh kế hoạch. Xem [`artifacts/forecast_report.json`](artifacts/forecast_report.json).

Forecast bắt đầu ở tuần **2014-06-30** sau tuần huấn luyện cuối bắt đầu **2014-06-23**. Đây là thử nghiệm tiếp nối lịch sử, không phải dự báo hoạt động CompanyX năm 2026.

## Chạy nhanh

Mở PowerShell ở thư mục project, dùng Windows account có quyền SQL Server:

```powershell
# Môi trường .venv đã được chuẩn bị trên máy này.
.\.venv\Scripts\python.exe -X utf8 scripts\run.py etl
.\.venv\Scripts\python.exe -X utf8 scripts\run.py train
.\.venv\Scripts\python.exe -X utf8 scripts\run.py score
.\.venv\Scripts\python.exe -X utf8 scripts\run.py profile
```

`train` chọn mô hình và refit; `score` dùng tham số của champion đã train, cập nhật trạng thái với những tuần mới. Nếu lịch sử đã sửa hoặc code/config thay đổi, cần train lại. Forecast và backtest được lưu trong SQL; Power BI không cần import CSV thủ công.

Trên máy mới:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\bootstrap.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\setup.ps1 -BackupPath 'D:\An\dl newest\CompanyX.bak'
.\.venv\Scripts\python.exe -X utf8 scripts\run.py etl --full
.\.venv\Scripts\python.exe -X utf8 scripts\run.py train
```

## Kiểm chứng và trạng thái bàn giao

6 unit tests kiểm tra time split, leakage, forecast đệ quy, metric và interval; 15 kiểm tra tích hợp SQL kiểm tra đối soát, idempotency, SCD2, insert/update/delete, quarantine và rollback/retry. SSIS đã validate và execute thành công. Power BI đã qua kiểm tra 50 tài liệu JSON schema và deserialize semantic model bằng thư viện TOM của Power BI Desktop.

**Chưa kiểm chứng render/refresh bằng giao diện Power BI Desktop.** Mở `.pbip`, chọn Windows authentication cho `localhost / CompanyX_BI_DW`, rồi Refresh. Model dùng Import; dữ liệu trên report chỉ mới sau khi refresh. Các SQL Agent jobs được tạo **disabled**, và SQL Server Agent đang dừng; pipeline chưa tự chạy nền mỗi 5 phút. Xem [runbook](docs/RUNBOOK.md) để vận hành.

## Phạm vi

Forecast hiện tại ở mức **TOTAL**. Product/category/territory/salesperson có phân tích lịch sử, chưa có mô hình dự báo riêng. Khoảng dự báo hiển thị bằng hai đường lower/upper; chưa phải dải tô màu. Estimated profit dùng historical standard cost khi có, không phải COGS kế toán. Chưa có target, stock/lead time, SHAP, reconciliation phân cấp hoặc triển khai Power BI Service. Những phần này không được giả lập thành kết quả thật.

Mã và tài liệu được tạo với hỗ trợ của Codex. Nhóm cần đọc, kiểm chứng và tự giải thích thiết kế, các sai số cùng giới hạn trước khi dùng cho bài nộp; project này là system resources, không thay thế báo cáo/presentation của nhóm.
