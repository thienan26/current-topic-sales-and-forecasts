USE [$(WarehouseDatabase)];
GO
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO
CREATE OR ALTER VIEW mart.Sales AS
SELECT f.*, d.[Date] OrderDate,d.WeekStart,d.YearMonth,
    CASE WHEN EstimatedCost IS NOT NULL THEN NetSales-EstimatedCost END EstimatedGrossProfit
FROM dw.FactSales f JOIN dw.DimDate d ON d.DateKey=f.SalesDateKey
WHERE f.OrderStatus=5; -- Shipped orders; excludes cancelled/rejected/open orders.
GO
CREATE OR ALTER VIEW mart.WeeklySales AS
WITH coverage AS (
    SELECT MIN(d.[Date]) FirstDate,MAX(d.[Date]) LastDate
    FROM dw.FactSales f JOIN dw.DimDate d ON d.DateKey=f.SalesDateKey
), weeks AS (
    SELECT d.WeekStart FROM dw.DimDate d CROSS JOIN coverage c
    WHERE d.[Date] BETWEEN c.FirstDate AND c.LastDate GROUP BY d.WeekStart
)
SELECT w.WeekStart,DATEADD(day,6,w.WeekStart) WeekEnd,
    COALESCE(SUM(s.NetSales),0) NetSales,COALESCE(SUM(s.OrderQty),0) Quantity,
    COUNT(DISTINCT s.SalesOrderID) Orders,
    CAST(CASE WHEN w.WeekStart>=c.FirstDate AND DATEADD(day,6,w.WeekStart)<=c.LastDate THEN 1 ELSE 0 END AS bit) IsComplete
FROM weeks w CROSS JOIN coverage c LEFT JOIN mart.Sales s ON s.WeekStart=w.WeekStart
GROUP BY w.WeekStart,c.FirstDate,c.LastDate;
GO
CREATE OR ALTER VIEW mart.LatestForecast AS
SELECT f.ForecastRunKey,d.[Date] WeekStart,f.Horizon,f.PredictedSales,f.LowerBound,f.UpperBound,
    r.Champion,r.TrainingEndDate,r.CreatedAt,r.IntervalLevel,r.SourceBatchID,
    COALESCE(r.ForecastOriginDate,r.TrainingEndDate) ForecastOriginDate,
    CASE WHEN e.WMAPE IS NULL OR e.WMAPE>0.30 THEN 'REVIEW_REQUIRED' ELSE 'PLANNING_REVIEW' END ReleaseStatus
FROM dw.FactSalesForecast f JOIN dw.ForecastRun r ON r.ForecastRunKey=f.ForecastRunKey
JOIN dw.DimDate d ON d.DateKey=f.ForecastDateKey
LEFT JOIN dw.ModelEvaluation e ON e.ForecastRunKey=COALESCE(r.TrainingRunKey,r.ForecastRunKey) AND e.EvaluationSet='holdout'
WHERE r.ForecastRunKey=(SELECT MAX(ForecastRunKey) FROM dw.ForecastRun);
GO
CREATE OR ALTER VIEW mart.ForecastEvaluation AS
SELECT f.ForecastRunKey,d.[Date] WeekStart,f.Horizon,r.Champion,
    s.NetSales ActualSales,f.PredictedSales,f.LowerBound,f.UpperBound,
    s.NetSales-f.PredictedSales ForecastError,
    ABS(s.NetSales-f.PredictedSales)/NULLIF(s.NetSales,0) APE
FROM dw.FactSalesForecast f JOIN dw.ForecastRun r ON r.ForecastRunKey=f.ForecastRunKey
JOIN dw.DimDate d ON d.DateKey=f.ForecastDateKey
JOIN mart.WeeklySales s ON s.WeekStart=d.[Date] AND s.IsComplete=1;
GO
CREATE OR ALTER VIEW mart.ForecastChart AS
SELECT w.WeekStart,CAST(w.NetSales AS decimal(19,6)) ActualSales,
    CAST(NULL AS decimal(19,6)) PredictedSales,CAST(NULL AS decimal(19,6)) LowerBound,CAST(NULL AS decimal(19,6)) UpperBound
FROM mart.WeeklySales w WHERE w.IsComplete=1
UNION ALL
SELECT f.WeekStart,NULL,f.PredictedSales,f.LowerBound,f.UpperBound FROM mart.LatestForecast f
WHERE NOT EXISTS(SELECT 1 FROM mart.WeeklySales w WHERE w.WeekStart=f.WeekStart AND w.IsComplete=1);
GO
CREATE OR ALTER VIEW mart.LatestModelEvaluation AS
SELECT e.* FROM dw.ModelEvaluation e WHERE e.ForecastRunKey=(SELECT TOP(1) COALESCE(TrainingRunKey,ForecastRunKey) FROM dw.ForecastRun ORDER BY ForecastRunKey DESC);
GO
CREATE OR ALTER VIEW mart.LatestBacktest AS
SELECT b.* FROM dw.BacktestPrediction b WHERE b.ForecastRunKey=(SELECT TOP(1) COALESCE(TrainingRunKey,ForecastRunKey) FROM dw.ForecastRun ORDER BY ForecastRunKey DESC);
GO
