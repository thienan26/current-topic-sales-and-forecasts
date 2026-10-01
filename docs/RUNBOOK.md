# Hướng dẫn chạy và demo

## 1. Cấu hình

Mặc định trong `config.example.json`: SQL Server `localhost`, Windows authentication, source `CompanyX_BI_Source`, warehouse `CompanyX_BI_DW`, ODBC Driver 18. Python 3.12; phiên bản thư viện đã chạy nằm trong `requirements.lock.txt`.

Nếu đổi server/database, sao chép thành `config.local.json` và chạy:

```powershell
.\.venv\Scripts\python.exe -X utf8 scripts\run.py --config config.local.json etl --full
```

Tên database phải có tiền tố `CompanyX_BI_` và source khác warehouse. `setup.ps1` nhận `-Server`, `-SourceDatabase`, `-WarehouseDatabase`, `-BackupPath`; không restore đè database có sẵn. Backup đã kiểm tra có logical files `AdventureWorks2022` và `AdventureWorks2022_log`; sửa script nếu dùng một backup khác. SQL files dùng SQLCMD variables; chạy qua setup hoặc bật SQLCMD mode trong SSMS.

`Encrypt=true`, `TrustServerCertificate=true` dành cho SQL Server local dùng certificate tự ký. Với server quản lý, dùng certificate hợp lệ và đặt trust thành false. Nếu dùng SQL authentication, đặt `trusted_connection=false`, credentials qua biến môi trường `COMPANYX_SQL_USER` / `COMPANYX_SQL_PASSWORD`; không ghi password vào config. SSIS/Agent scripts mặc định Windows authentication.

Các script được thiết kế chạy từ thư mục project. Không cần `pip install -e .`: đường dẫn tiếng Việt trên Windows có thể làm một số phiên bản setuptools lỗi encoding; `scripts/run.py` nạp source trực tiếp.

## 2. ETL và data quality

```powershell
.\.venv\Scripts\python.exe -X utf8 scripts\run.py etl --full  # initial/nightly reconciliation
.\.venv\Scripts\python.exe -X utf8 scripts\run.py etl         # incremental
dtexec /F ssis\CompanyX_IncrementalSales.dtsx /Reporting E
```

SSIS dùng Execute SQL Task gọi `ctl.LoadSales`; các bước extract, staging, DQ, SCD, fact và watermark nằm trong cùng SQL transaction. Cách này có file `.dtsx` thực thi được, đồng thời giữ logic ETL có thể review và kiểm thử bằng SQL. Không có SSIS Data Flow riêng cho từng bảng.

Theo dõi bằng SSMS:

```sql
USE CompanyX_BI_DW;
SELECT TOP (20) * FROM ctl.Batch ORDER BY BatchID DESC;
SELECT * FROM ctl.Watermark;
SELECT SalesOrderDetailID,Reason,FirstBatchID,LastBatchID FROM ctl.RejectedSales;
SELECT TOP (20) * FROM ctl.DataQualityIssue ORDER BY IssueID DESC;
SELECT IsComplete,COUNT(*) Weeks FROM mart.WeeklySales GROUP BY IsComplete;
```

`RowsRejected` là số dòng lỗi nhìn thấy trong batch, không phải tổng quarantine hiện tại. Các dòng lỗi được lưu bằng business key và raw JSON; khi nguồn sửa đúng, lần incremental/full sau sẽ đưa dòng về fact. Một dòng hợp lệ chuyển thành lỗi sẽ bị loại khỏi fact để KPI không giữ giá trị cũ. Foreign key không giải được, cost interval chồng nhau hoặc lỗi SQL làm fail toàn batch; watermark giữ nguyên và error được ghi ngoài transaction.

Watermark so sánh với clock local của source (`GETDATE`), có overlap 2 ngày và hash để chạy lại an toàn. Audit timestamps dùng UTC. SCD observation time dùng local source clock để cùng chuẩn với OrderDate; deployment nhiều múi giờ cần chuẩn hóa thời gian rõ ràng.

`ModifiedDate` **không tự đổi với mọi câu UPDATE**; writer phải cập nhật nó. Timestamp có thể bỏ sót sửa lịch sử/backdate quá cửa sổ overlap, vì vậy có full reconciliation hằng đêm. Hard delete được phát hiện qua scan key nguồn mỗi batch. Đây là giải pháp cho dataset nhỏ; không tương đương CDC có log thay đổi đầy đủ. Không dùng tài khoản production hay chạy procedure serializable này trên OLTP lớn mà chưa đánh giá thời gian khóa.

## 3. Forecast

```powershell
.\.venv\Scripts\python.exe -X utf8 scripts\run.py train
.\.venv\Scripts\python.exe -X utf8 scripts\run.py score
.\.venv\Scripts\python.exe -X utf8 scripts\run.py profile
```

Train: 4 folds validation không chồng nhau, mỗi fold 8 tuần; 8 tuần cuối là holdout. Champion được chọn bằng validation wMAPE (RMSE phá hòa); holdout chỉ dùng đánh giá. Sau đó refit champion trên toàn bộ 160 tuần, forecast 8 tuần và ghi `ForecastRun`, `FactSalesForecast`, `ModelEvaluation`, `BacktestPrediction`.

Scoring: dùng champion artifact local, giữ nguyên tham số mô hình; SARIMA append quan sát mới với `refit=False`, XGBoost lấy lag từ lịch sử mới và dự báo đệ quy. Nếu lịch sử đã sửa hoặc code/config thay đổi, scoring báo cần retrain. Không load pickle từ nguồn bên ngoài. Các lần publish trùng dữ liệu + code/config + loại run được tái sử dụng, tránh nhân đôi forecast. SQL transaction công bố cả bộ dự báo; view lấy latest committed run.

`ModelEvaluation` của scoring vẫn truy về lần train gốc qua `TrainingRunKey`. `TrainingEndDate` là ngày bắt đầu tuần cuối dùng fit; `ForecastOriginDate` là ngày bắt đầu tuần cuối đã quan sát, kể cả tuần được append trong scoring. `CreatedAt` là thời gian chạy thật.

Các khoảng dự báo là quantile sai số validation, scale theo căn bậc hai horizon. Chỉ có 32 residuals và 8 điểm holdout; mức danh nghĩa 80% không phải cam kết coverage thực tế. Gate `wMAPE > 30%` là quy tắc demo cần review, không phải policy CompanyX. Gate không chặn việc lưu dự báo để nhóm vẫn xem được mô hình thất bại ở đâu.

## 4. Power BI

1. Mở `powerbi/CompanyX.pbip` bằng Power BI Desktop có hỗ trợ PBIP/PBIR. Chọn Windows authentication cho SQL source.
2. Chọn **Refresh**. Dữ liệu được truy vấn từ SQL views qua Power Query M; không có credentials trong project.
3. Có thể import `powerbi/theme.json` qua View → Themes → Browse for themes.
4. Kiểm tra bốn trang: Executive, Trends, Product/Territory, Forecast/Decisions.
5. Page Forecast là tổng công ty, không nhận product/territory filters. Forecast tables cố ý không liên kết với DimProduct/DimTerritory; tránh hiểu nhầm forecast tổng đã được phân rã theo slicer.
6. Power BI Import không refresh chỉ vì SQL ETL đã chạy. Demo local: Refresh thủ công sau ETL. Muốn tự cập nhật cần cấu hình gateway và refresh/service hoặc thiết kế DirectQuery phù hợp; chưa deploy các phần này.

Column `Date` trong DimDate là khóa ngày duy nhất; model khai báo date table và quan hệ một chiều từ dimensions đến facts. Growth cần so sánh các khoảng ngày tương đương; chọn year/month đầy đủ, không so partial month với full month rồi kết luận tăng trưởng.

Tạo lại report/model sau khi sửa source generator:

```powershell
.\.venv\Scripts\python.exe -X utf8 scripts\build_powerbi.py
.\.venv\Scripts\python.exe -X utf8 scripts\validate_powerbi.py
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\validate_semantic_model.ps1
```

Generator đọc `config.example.json`; sửa file này trước khi generate cho server khác. Generate sẽ ghi đè các file report cùng tên; lưu thay đổi bằng Desktop trước khi quyết định regenerate. Kiểm tra JSON/TOM không thay thế kiểm tra render, credentials, M refresh hoặc DAX bằng Desktop.

## 5. Lịch chạy

Bốn jobs đã tạo trong SQL Agent và đều **disabled**:

| Job | Lịch theo giờ local của server |
|---|---|
| CompanyX BI - 5 minute ETL | Mỗi 5 phút |
| CompanyX BI - nightly reconciliation | 01:00 hằng ngày |
| CompanyX BI - weekly training | Thứ Hai 05:00 |
| CompanyX BI - daily forecast | 06:00 hằng ngày |

SQL Server Agent hiện đang stopped. Để vận hành tự động, cấu hình account/proxy được phép kết nối SQL và đọc/ghi thư mục project, start SQL Server Agent rồi enable jobs trong SSMS. Mỗi step retry 2 lần, cách nhau 1 phút. Có thể start job thủ công trước để kiểm tra quyền của service account. Script cài không ghi đè jobs đã tồn tại.

ETL 5 phút không tự gọi train. Scoring chỉ có thông tin mới khi có thêm tuần đầy đủ; chạy nhiều lần trên backup tĩnh không tạo thêm dữ liệu thực. Khi sửa quá khứ, scoring yêu cầu retrain sau full reconciliation. Service này chưa tự refresh Power BI Service.

## 6. Demo có thể tái lập

```powershell
.\.venv\Scripts\python.exe -X utf8 -m pytest -q
.\.venv\Scripts\python.exe -X utf8 scripts\verify_sql.py
```

Integration test chỉ thao tác database riêng theo config mặc định. Nó kiểm tra: đối soát nguồn/KPI, full → incremental idempotency, update detail, update header-only, fail và retry, SCD2, quarantine/repair, insert và hard delete. `finally` khôi phục giá trị nguồn đã thay và chạy full reconcile. Test vẫn để lại audit, các SCD versions quan sát được và identity gaps — đúng lịch sử của một lượt demo, không reset dữ liệu kho.

Demo near-real-time có thể sửa một line trong bản source riêng, set `ModifiedDate=GETDATE()`, ghi thời gian commit rồi chạy SSIS/job. Quan sát Batch.FinishedAt và dòng fact; Refresh Power BI để xem KPI. Nếu bật lịch 5 phút, độ trễ end-to-end còn phụ thuộc lịch job, runtime và refresh BI; không tuyên bố Power BI realtime chỉ từ cấu hình ETL.
