USE master;
GO
IF DB_ID(N'$(WarehouseDatabase)') IS NULL
    CREATE DATABASE [$(WarehouseDatabase)];
GO
USE [$(WarehouseDatabase)];
GO
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO
IF SCHEMA_ID('ctl') IS NULL EXEC('CREATE SCHEMA ctl');
IF SCHEMA_ID('stg') IS NULL EXEC('CREATE SCHEMA stg');
IF SCHEMA_ID('dw') IS NULL EXEC('CREATE SCHEMA dw');
IF SCHEMA_ID('mart') IS NULL EXEC('CREATE SCHEMA mart');
GO
IF OBJECT_ID('ctl.Batch') IS NULL
CREATE TABLE ctl.Batch (
    BatchID bigint IDENTITY PRIMARY KEY,
    StartedAt datetime2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
    FinishedAt datetime2(3) NULL,
    Status varchar(16) NOT NULL DEFAULT 'RUNNING',
    IsFullReconcile bit NOT NULL,
    SourceUpperBound datetime NOT NULL,
    RowsRead int NOT NULL DEFAULT 0,
    RowsInserted int NOT NULL DEFAULT 0,
    RowsUpdated int NOT NULL DEFAULT 0,
    RowsDeleted int NOT NULL DEFAULT 0,
    RowsRejected int NOT NULL DEFAULT 0,
    DimensionVersions int NOT NULL DEFAULT 0,
    ErrorMessage nvarchar(2048) NULL
);
IF OBJECT_ID('ctl.Watermark') IS NULL
CREATE TABLE ctl.Watermark (
    EntityName sysname PRIMARY KEY,
    LastSuccessfulValue datetime NOT NULL,
    BatchID bigint NOT NULL REFERENCES ctl.Batch(BatchID)
);
IF OBJECT_ID('ctl.DataQualityIssue') IS NULL
CREATE TABLE ctl.DataQualityIssue (
    IssueID bigint IDENTITY PRIMARY KEY,
    BatchID bigint NOT NULL REFERENCES ctl.Batch(BatchID),
    RecordedAt datetime2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
    Message nvarchar(2048) NOT NULL
);
IF OBJECT_ID('dw.DimDate') IS NULL
CREATE TABLE dw.DimDate (
    DateKey int PRIMARY KEY, [Date] date NOT NULL UNIQUE,
    [Year] int NOT NULL, [Quarter] int NOT NULL, [Month] int NOT NULL,
    MonthName varchar(12) NOT NULL, YearMonth char(7) NOT NULL,
    WeekStart date NOT NULL, ISOWeek int NOT NULL, ISOYear int NOT NULL,
    DayOfWeek int NOT NULL
);
IF OBJECT_ID('dw.DimProduct') IS NULL
CREATE TABLE dw.DimProduct (
    ProductKey int IDENTITY PRIMARY KEY, ProductID int NOT NULL,
    ProductName nvarchar(100) NOT NULL, ProductNumber nvarchar(50) NOT NULL,
    Category nvarchar(100) NOT NULL, Subcategory nvarchar(100) NOT NULL,
    Color nvarchar(30) NULL, Size nvarchar(30) NULL,
    ValidFrom datetime2(3) NOT NULL, ValidTo datetime2(3) NOT NULL,
    IsCurrent bit NOT NULL, HashDiff binary(32) NOT NULL,
    HistoryBasis varchar(24) NOT NULL, LoadBatchID bigint NOT NULL,
    CONSTRAINT CK_Product_Validity CHECK (ValidTo > ValidFrom)
);
IF OBJECT_ID('dw.DimCustomer') IS NULL
CREATE TABLE dw.DimCustomer (
    CustomerKey int IDENTITY PRIMARY KEY, CustomerID int NOT NULL,
    CustomerType varchar(20) NOT NULL, TerritoryID int NULL,
    ValidFrom datetime2(3) NOT NULL, ValidTo datetime2(3) NOT NULL,
    IsCurrent bit NOT NULL, HashDiff binary(32) NOT NULL,
    HistoryBasis varchar(24) NOT NULL, LoadBatchID bigint NOT NULL,
    CONSTRAINT CK_Customer_Validity CHECK (ValidTo > ValidFrom)
);
IF OBJECT_ID('dw.DimSalesPerson') IS NULL
CREATE TABLE dw.DimSalesPerson (
    SalesPersonKey int IDENTITY PRIMARY KEY, SalesPersonID int NOT NULL,
    SalesPersonName nvarchar(200) NOT NULL, TerritoryID int NULL,
    ValidFrom datetime2(3) NOT NULL, ValidTo datetime2(3) NOT NULL,
    IsCurrent bit NOT NULL, HashDiff binary(32) NOT NULL,
    HistoryBasis varchar(24) NOT NULL, LoadBatchID bigint NOT NULL,
    CONSTRAINT CK_SalesPerson_Validity CHECK (ValidTo > ValidFrom)
);
IF OBJECT_ID('dw.DimTerritory') IS NULL
CREATE TABLE dw.DimTerritory (
    TerritoryKey int IDENTITY PRIMARY KEY, TerritoryID int NOT NULL,
    TerritoryName nvarchar(100) NOT NULL, CountryRegionCode nvarchar(10) NOT NULL,
    TerritoryGroup nvarchar(100) NOT NULL,
    ValidFrom datetime2(3) NOT NULL, ValidTo datetime2(3) NOT NULL,
    IsCurrent bit NOT NULL, HashDiff binary(32) NOT NULL,
    HistoryBasis varchar(24) NOT NULL, LoadBatchID bigint NOT NULL,
    CONSTRAINT CK_Territory_Validity CHECK (ValidTo > ValidFrom)
);
IF OBJECT_ID('dw.DimPromotion') IS NULL
CREATE TABLE dw.DimPromotion (
    PromotionKey int IDENTITY PRIMARY KEY, SpecialOfferID int NOT NULL UNIQUE,
    Description nvarchar(255) NOT NULL, DiscountPct decimal(9,4) NOT NULL,
    StartDate date NOT NULL, EndDate date NOT NULL, LoadBatchID bigint NOT NULL
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='UX_Product_Current' AND object_id=OBJECT_ID('dw.DimProduct'))
BEGIN
 CREATE UNIQUE INDEX UX_Product_Current ON dw.DimProduct(ProductID) WHERE IsCurrent=1;
 CREATE UNIQUE INDEX UX_Customer_Current ON dw.DimCustomer(CustomerID) WHERE IsCurrent=1;
 CREATE UNIQUE INDEX UX_SalesPerson_Current ON dw.DimSalesPerson(SalesPersonID) WHERE IsCurrent=1;
 CREATE UNIQUE INDEX UX_Territory_Current ON dw.DimTerritory(TerritoryID) WHERE IsCurrent=1;
 CREATE INDEX IX_Product_History ON dw.DimProduct(ProductID,ValidFrom,ValidTo);
 CREATE INDEX IX_Customer_History ON dw.DimCustomer(CustomerID,ValidFrom,ValidTo);
 CREATE INDEX IX_SalesPerson_History ON dw.DimSalesPerson(SalesPersonID,ValidFrom,ValidTo);
 CREATE INDEX IX_Territory_History ON dw.DimTerritory(TerritoryID,ValidFrom,ValidTo);
END;
GO
IF OBJECT_ID('dw.FactSales') IS NULL
CREATE TABLE dw.FactSales (
    SalesOrderDetailID int PRIMARY KEY, SalesOrderID int NOT NULL,
    SalesDateKey int NOT NULL REFERENCES dw.DimDate(DateKey),
    ProductKey int NOT NULL REFERENCES dw.DimProduct(ProductKey),
    CustomerKey int NOT NULL REFERENCES dw.DimCustomer(CustomerKey),
    SalesPersonKey int NOT NULL REFERENCES dw.DimSalesPerson(SalesPersonKey),
    TerritoryKey int NOT NULL REFERENCES dw.DimTerritory(TerritoryKey),
    PromotionKey int NOT NULL REFERENCES dw.DimPromotion(PromotionKey),
    OrderStatus tinyint NOT NULL, OnlineOrderFlag bit NOT NULL,
    OrderQty int NOT NULL, UnitPrice decimal(19,4) NOT NULL,
    DiscountPct decimal(9,4) NOT NULL, GrossSales decimal(19,6) NOT NULL,
    DiscountAmount decimal(19,6) NOT NULL, NetSales decimal(19,6) NOT NULL,
    EstimatedCost decimal(19,6) NULL,
    CostBasis varchar(30) NOT NULL,
    SourceModifiedDate datetime NOT NULL,
    HashDiff binary(32) NOT NULL,
    LoadBatchID bigint NOT NULL REFERENCES ctl.Batch(BatchID),
    CONSTRAINT CK_Fact_Amounts CHECK (OrderQty > 0 AND UnitPrice >= 0 AND DiscountPct BETWEEN 0 AND 1)
);
IF OBJECT_ID('stg.SalesLine') IS NULL
CREATE TABLE stg.SalesLine (
    SalesOrderDetailID int PRIMARY KEY, SalesOrderID int NOT NULL,
    OrderDate datetime2(3) NOT NULL, CustomerID int NOT NULL, SalesPersonID int NOT NULL,
    TerritoryID int NOT NULL, ProductID int NOT NULL, SpecialOfferID int NOT NULL,
    OrderStatus tinyint NOT NULL, OnlineOrderFlag bit NOT NULL,
    OrderQty int NULL, UnitPrice decimal(19,4) NULL,
    DiscountPct decimal(9,4) NOT NULL, NetSales decimal(19,6) NOT NULL,
    EstimatedUnitCost decimal(19,4) NULL, CostBasis varchar(30) NOT NULL,
    SourceModifiedDate datetime NOT NULL,
    HashDiff binary(32) NULL, BatchID bigint NOT NULL,
    ExtractedAt datetime2(3) NOT NULL DEFAULT SYSUTCDATETIME()
);
IF COL_LENGTH('ctl.Batch','RowsRejected') IS NULL
    ALTER TABLE ctl.Batch ADD RowsRejected int NOT NULL CONSTRAINT DF_Batch_Rejected DEFAULT 0;
ALTER TABLE stg.SalesLine ALTER COLUMN OrderQty int NULL;
ALTER TABLE stg.SalesLine ALTER COLUMN UnitPrice decimal(19,4) NULL;
ALTER TABLE stg.SalesLine ALTER COLUMN OrderDate datetime2(3) NOT NULL;
IF OBJECT_ID('ctl.RejectedSales') IS NULL
CREATE TABLE ctl.RejectedSales (
    SalesOrderDetailID int PRIMARY KEY, SalesOrderID int NOT NULL,
    Reason nvarchar(500) NOT NULL, RawPayload nvarchar(max) NOT NULL,
    FirstBatchID bigint NOT NULL, LastBatchID bigint NOT NULL,
    RecordedAt datetime2(3) NOT NULL DEFAULT SYSUTCDATETIME()
);
IF OBJECT_ID('dw.ForecastRun') IS NULL
CREATE TABLE dw.ForecastRun (
    ForecastRunKey bigint IDENTITY PRIMARY KEY,
    CreatedAt datetime2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
    TrainingEndDate date NOT NULL, SourceBatchID bigint NOT NULL REFERENCES ctl.Batch(BatchID),
    DataHash char(64) NOT NULL, CodeVersion varchar(100) NOT NULL,
    Champion varchar(50) NOT NULL, ModelPath nvarchar(400) NOT NULL,
    RunType varchar(20) NOT NULL, ConfigJson nvarchar(max) NOT NULL,
    IntervalLevel decimal(5,4) NOT NULL,
    CONSTRAINT UQ_ForecastRun UNIQUE(DataHash, CodeVersion, RunType)
);
IF OBJECT_ID('dw.FactSalesForecast') IS NULL
CREATE TABLE dw.FactSalesForecast (
    ForecastRunKey bigint NOT NULL REFERENCES dw.ForecastRun(ForecastRunKey),
    ForecastDateKey int NOT NULL REFERENCES dw.DimDate(DateKey),
    Horizon int NOT NULL, PredictedSales decimal(19,6) NOT NULL,
    LowerBound decimal(19,6) NOT NULL, UpperBound decimal(19,6) NOT NULL,
    PRIMARY KEY(ForecastRunKey,ForecastDateKey),
    CONSTRAINT CK_Forecast_Bounds CHECK (LowerBound>=0 AND PredictedSales>=LowerBound AND UpperBound>=PredictedSales)
);
IF COL_LENGTH('dw.ForecastRun','TrainingRunKey') IS NULL
    ALTER TABLE dw.ForecastRun ADD TrainingRunKey bigint NULL REFERENCES dw.ForecastRun(ForecastRunKey);
IF COL_LENGTH('dw.ForecastRun','ForecastOriginDate') IS NULL
    ALTER TABLE dw.ForecastRun ADD ForecastOriginDate date NULL;
IF OBJECT_ID('dw.ModelEvaluation') IS NULL
CREATE TABLE dw.ModelEvaluation (
    ForecastRunKey bigint NOT NULL REFERENCES dw.ForecastRun(ForecastRunKey),
    ModelName varchar(50) NOT NULL, EvaluationSet varchar(20) NOT NULL,
    MAE float NOT NULL, RMSE float NOT NULL, WMAPE float NULL, Bias float NULL,
    IntervalCoverage float NULL, N int NOT NULL,
    PRIMARY KEY(ForecastRunKey,ModelName,EvaluationSet)
);
IF OBJECT_ID('dw.BacktestPrediction') IS NULL
CREATE TABLE dw.BacktestPrediction (
    ForecastRunKey bigint NOT NULL REFERENCES dw.ForecastRun(ForecastRunKey),
    ModelName varchar(50) NOT NULL, EvaluationSet varchar(20) NOT NULL,
    OriginDate date NOT NULL, TargetDate date NOT NULL, Horizon int NOT NULL,
    Actual float NOT NULL, Predicted float NOT NULL, LowerBound float NULL, UpperBound float NULL,
    PRIMARY KEY(ForecastRunKey,ModelName,EvaluationSet,OriginDate,Horizon)
);
GO
