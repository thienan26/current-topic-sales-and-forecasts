USE [$(WarehouseDatabase)];
GO
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO
IF OBJECT_ID('stg.DimensionSnapshot') IS NULL
CREATE TABLE stg.DimensionSnapshot (
    EntityName varchar(30) NOT NULL, BusinessKey int NOT NULL,
    Payload nvarchar(max) NOT NULL, HashDiff binary(32) NOT NULL,
    BatchID bigint NOT NULL, ExtractedAt datetime2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
    PRIMARY KEY(EntityName,BusinessKey)
);
GO
CREATE OR ALTER PROCEDURE ctl.LoadSales
    @FullReconcile bit=0, @LookbackDays int=2, @InjectFailure bit=0
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF @@TRANCOUNT<>0 THROW 51000, 'Run LoadSales outside an existing transaction.',1;
    IF @LookbackDays<0 THROW 51000, 'LookbackDays must be nonnegative.',1;
    DECLARE @lock int, @batch bigint, @upper datetime, @now datetime2(3),
        @headerWatermark datetime, @detailWatermark datetime,
        @read int=0,@inserted int=0,@updated int=0,@deleted int=0,@versions int=0,@rejected int=0;
    EXEC @lock=sys.sp_getapplock @Resource='CompanyX_LoadSales',@LockMode='Exclusive',
         @LockOwner='Session',@LockTimeout=0;
    IF @lock<0 THROW 51001,'Another sales ETL is running.',1;
    BEGIN TRY
        SET @upper=GETDATE(); -- Source ModifiedDate follows the SQL Server local clock.
        SET @now=SYSDATETIME(); -- SCD observation time uses the same local clock as source OrderDate.
        IF NOT EXISTS(SELECT 1 FROM ctl.Watermark) SET @FullReconcile=1;
        INSERT ctl.Batch(IsFullReconcile,SourceUpperBound) VALUES(@FullReconcile,@upper);
        SET @batch=SCOPE_IDENTITY();
        SET TRANSACTION ISOLATION LEVEL SERIALIZABLE;
        BEGIN TRANSACTION;
        SELECT @headerWatermark=DATEADD(day,-@LookbackDays,LastSuccessfulValue)
          FROM ctl.Watermark WHERE EntityName='SalesOrderHeader';
        SELECT @detailWatermark=DATEADD(day,-@LookbackDays,LastSuccessfulValue)
          FROM ctl.Watermark WHERE EntityName='SalesOrderDetail';
        SET @headerWatermark=COALESCE(@headerWatermark,'19000101');
        SET @detailWatermark=COALESCE(@detailWatermark,'19000101');

        DELETE stg.SalesLine;
        DELETE stg.DimensionSnapshot;


        SELECT s.*, HASHBYTES('SHA2_256', j.Payload) HashDiff, j.Payload
        INTO #Product
        FROM (
        SELECT p.ProductID, p.Name ProductName, p.ProductNumber,
               COALESCE(c.Name,N'Unclassified') Category,
               COALESCE(s.Name,N'Unclassified') Subcategory, p.Color, p.Size
        FROM [$(SourceDatabase)].Production.Product p
        LEFT JOIN [$(SourceDatabase)].Production.ProductSubcategory s ON s.ProductSubcategoryID=p.ProductSubcategoryID
        LEFT JOIN [$(SourceDatabase)].Production.ProductCategory c ON c.ProductCategoryID=s.ProductCategoryID) s
        CROSS APPLY (SELECT s.ProductName,s.ProductNumber,s.Category,s.Subcategory,s.Color,s.Size FOR JSON PATH, WITHOUT_ARRAY_WRAPPER, INCLUDE_NULL_VALUES) j(Payload);
        INSERT stg.DimensionSnapshot(EntityName,BusinessKey,Payload,HashDiff,BatchID)
        SELECT 'Product', ProductID, Payload, HashDiff, @batch FROM #Product;
        UPDATE d SET ValidTo=@now, IsCurrent=0
        FROM dw.DimProduct d JOIN #Product s ON s.ProductID=d.ProductID
        WHERE d.IsCurrent=1 AND d.HashDiff<>s.HashDiff;
        INSERT dw.DimProduct(ProductID,ProductName,ProductNumber,Category,Subcategory,Color,Size,ValidFrom,ValidTo,IsCurrent,HashDiff,HistoryBasis,LoadBatchID)
        SELECT s.ProductID,s.ProductName,s.ProductNumber,s.Category,s.Subcategory,s.Color,s.Size,
            CASE WHEN EXISTS(SELECT 1 FROM dw.DimProduct old WHERE old.ProductID=s.ProductID) THEN @now ELSE '19000101' END,
            '99991231',1,s.HashDiff,
            CASE WHEN EXISTS(SELECT 1 FROM dw.DimProduct old WHERE old.ProductID=s.ProductID) THEN 'OBSERVED_CHANGE' ELSE 'INITIAL_SNAPSHOT' END,@batch
        FROM #Product s WHERE NOT EXISTS(SELECT 1 FROM dw.DimProduct d WHERE d.ProductID=s.ProductID AND d.IsCurrent=1);
        SET @versions += @@ROWCOUNT;


        SELECT s.*, HASHBYTES('SHA2_256', j.Payload) HashDiff, j.Payload
        INTO #Customer
        FROM (
        SELECT CustomerID, CAST(CASE WHEN StoreID IS NULL THEN 'Individual' ELSE 'Store' END AS varchar(20)) CustomerType, TerritoryID
        FROM [$(SourceDatabase)].Sales.Customer) s
        CROSS APPLY (SELECT s.CustomerType,s.TerritoryID FOR JSON PATH, WITHOUT_ARRAY_WRAPPER, INCLUDE_NULL_VALUES) j(Payload);
        INSERT stg.DimensionSnapshot(EntityName,BusinessKey,Payload,HashDiff,BatchID)
        SELECT 'Customer', CustomerID, Payload, HashDiff, @batch FROM #Customer;
        UPDATE d SET ValidTo=@now, IsCurrent=0
        FROM dw.DimCustomer d JOIN #Customer s ON s.CustomerID=d.CustomerID
        WHERE d.IsCurrent=1 AND d.HashDiff<>s.HashDiff;
        INSERT dw.DimCustomer(CustomerID,CustomerType,TerritoryID,ValidFrom,ValidTo,IsCurrent,HashDiff,HistoryBasis,LoadBatchID)
        SELECT s.CustomerID,s.CustomerType,s.TerritoryID,
            CASE WHEN EXISTS(SELECT 1 FROM dw.DimCustomer old WHERE old.CustomerID=s.CustomerID) THEN @now ELSE '19000101' END,
            '99991231',1,s.HashDiff,
            CASE WHEN EXISTS(SELECT 1 FROM dw.DimCustomer old WHERE old.CustomerID=s.CustomerID) THEN 'OBSERVED_CHANGE' ELSE 'INITIAL_SNAPSHOT' END,@batch
        FROM #Customer s WHERE NOT EXISTS(SELECT 1 FROM dw.DimCustomer d WHERE d.CustomerID=s.CustomerID AND d.IsCurrent=1);
        SET @versions += @@ROWCOUNT;


        SELECT s.*, HASHBYTES('SHA2_256', j.Payload) HashDiff, j.Payload
        INTO #SalesPerson
        FROM (
        SELECT sp.BusinessEntityID SalesPersonID,
               CAST(CONCAT(p.FirstName,N' ',p.LastName) AS nvarchar(200)) SalesPersonName, sp.TerritoryID
        FROM [$(SourceDatabase)].Sales.SalesPerson sp
        JOIN [$(SourceDatabase)].Person.Person p ON p.BusinessEntityID=sp.BusinessEntityID
        UNION ALL SELECT -1,N'Online / unassigned',NULL) s
        CROSS APPLY (SELECT s.SalesPersonName,s.TerritoryID FOR JSON PATH, WITHOUT_ARRAY_WRAPPER, INCLUDE_NULL_VALUES) j(Payload);
        INSERT stg.DimensionSnapshot(EntityName,BusinessKey,Payload,HashDiff,BatchID)
        SELECT 'SalesPerson', SalesPersonID, Payload, HashDiff, @batch FROM #SalesPerson;
        UPDATE d SET ValidTo=@now, IsCurrent=0
        FROM dw.DimSalesPerson d JOIN #SalesPerson s ON s.SalesPersonID=d.SalesPersonID
        WHERE d.IsCurrent=1 AND d.HashDiff<>s.HashDiff;
        INSERT dw.DimSalesPerson(SalesPersonID,SalesPersonName,TerritoryID,ValidFrom,ValidTo,IsCurrent,HashDiff,HistoryBasis,LoadBatchID)
        SELECT s.SalesPersonID,s.SalesPersonName,s.TerritoryID,
            CASE WHEN EXISTS(SELECT 1 FROM dw.DimSalesPerson old WHERE old.SalesPersonID=s.SalesPersonID) THEN @now ELSE '19000101' END,
            '99991231',1,s.HashDiff,
            CASE WHEN EXISTS(SELECT 1 FROM dw.DimSalesPerson old WHERE old.SalesPersonID=s.SalesPersonID) THEN 'OBSERVED_CHANGE' ELSE 'INITIAL_SNAPSHOT' END,@batch
        FROM #SalesPerson s WHERE NOT EXISTS(SELECT 1 FROM dw.DimSalesPerson d WHERE d.SalesPersonID=s.SalesPersonID AND d.IsCurrent=1);
        SET @versions += @@ROWCOUNT;


        SELECT s.*, HASHBYTES('SHA2_256', j.Payload) HashDiff, j.Payload
        INTO #Territory
        FROM (
        SELECT TerritoryID, Name TerritoryName, CountryRegionCode, [Group] TerritoryGroup
        FROM [$(SourceDatabase)].Sales.SalesTerritory
        UNION ALL SELECT -1,N'Unassigned',N'NA',N'Unassigned') s
        CROSS APPLY (SELECT s.TerritoryName,s.CountryRegionCode,s.TerritoryGroup FOR JSON PATH, WITHOUT_ARRAY_WRAPPER, INCLUDE_NULL_VALUES) j(Payload);
        INSERT stg.DimensionSnapshot(EntityName,BusinessKey,Payload,HashDiff,BatchID)
        SELECT 'Territory', TerritoryID, Payload, HashDiff, @batch FROM #Territory;
        UPDATE d SET ValidTo=@now, IsCurrent=0
        FROM dw.DimTerritory d JOIN #Territory s ON s.TerritoryID=d.TerritoryID
        WHERE d.IsCurrent=1 AND d.HashDiff<>s.HashDiff;
        INSERT dw.DimTerritory(TerritoryID,TerritoryName,CountryRegionCode,TerritoryGroup,ValidFrom,ValidTo,IsCurrent,HashDiff,HistoryBasis,LoadBatchID)
        SELECT s.TerritoryID,s.TerritoryName,s.CountryRegionCode,s.TerritoryGroup,
            CASE WHEN EXISTS(SELECT 1 FROM dw.DimTerritory old WHERE old.TerritoryID=s.TerritoryID) THEN @now ELSE '19000101' END,
            '99991231',1,s.HashDiff,
            CASE WHEN EXISTS(SELECT 1 FROM dw.DimTerritory old WHERE old.TerritoryID=s.TerritoryID) THEN 'OBSERVED_CHANGE' ELSE 'INITIAL_SNAPSHOT' END,@batch
        FROM #Territory s WHERE NOT EXISTS(SELECT 1 FROM dw.DimTerritory d WHERE d.TerritoryID=s.TerritoryID AND d.IsCurrent=1);
        SET @versions += @@ROWCOUNT;


        UPDATE d SET Description=s.Description,DiscountPct=s.DiscountPct,
            StartDate=s.StartDate,EndDate=s.EndDate,LoadBatchID=@batch
        FROM dw.DimPromotion d JOIN [$(SourceDatabase)].Sales.SpecialOffer s ON s.SpecialOfferID=d.SpecialOfferID
        WHERE d.Description<>s.Description COLLATE DATABASE_DEFAULT OR d.DiscountPct<>s.DiscountPct OR d.StartDate<>s.StartDate OR d.EndDate<>s.EndDate;
        INSERT dw.DimPromotion(SpecialOfferID,Description,DiscountPct,StartDate,EndDate,LoadBatchID)
        SELECT SpecialOfferID,Description,DiscountPct,StartDate,EndDate,@batch
        FROM [$(SourceDatabase)].Sales.SpecialOffer s
        WHERE NOT EXISTS(SELECT 1 FROM dw.DimPromotion d WHERE d.SpecialOfferID=s.SpecialOfferID);

        -- Header and detail deltas are captured independently. A header change fans out to every line.
        SELECT h.SalesOrderID INTO #ChangedOrders FROM [$(SourceDatabase)].Sales.SalesOrderHeader h
        WHERE @FullReconcile=1 OR (h.ModifiedDate>=@headerWatermark AND h.ModifiedDate<=@upper)
        UNION
        SELECT d.SalesOrderID FROM [$(SourceDatabase)].Sales.SalesOrderDetail d
        WHERE @FullReconcile=1 OR (d.ModifiedDate>=@detailWatermark AND d.ModifiedDate<=@upper)
        UNION
        SELECT d.SalesOrderID FROM [$(SourceDatabase)].Sales.SalesOrderDetail d
        JOIN [$(SourceDatabase)].Production.ProductCostHistory c ON c.ProductID=d.ProductID
        WHERE c.ModifiedDate>=@detailWatermark AND c.ModifiedDate<=@upper;
        CREATE UNIQUE CLUSTERED INDEX IX_Changed ON #ChangedOrders(SalesOrderID);

        IF EXISTS (
            SELECT d.SalesOrderDetailID
            FROM #ChangedOrders x JOIN [$(SourceDatabase)].Sales.SalesOrderHeader h ON h.SalesOrderID=x.SalesOrderID
            JOIN [$(SourceDatabase)].Sales.SalesOrderDetail d ON d.SalesOrderID=h.SalesOrderID
            JOIN [$(SourceDatabase)].Production.ProductCostHistory c ON c.ProductID=d.ProductID
                AND h.OrderDate>=c.StartDate AND (c.EndDate IS NULL OR CAST(h.OrderDate AS date)<=CAST(c.EndDate AS date))
            GROUP BY d.SalesOrderDetailID HAVING COUNT(*)>1
        ) THROW 51002,'DQ: overlapping historical cost intervals.',1;

        INSERT stg.SalesLine(SalesOrderDetailID,SalesOrderID,OrderDate,CustomerID,SalesPersonID,TerritoryID,
            ProductID,SpecialOfferID,OrderStatus,OnlineOrderFlag,OrderQty,UnitPrice,DiscountPct,NetSales,
            EstimatedUnitCost,CostBasis,SourceModifiedDate,BatchID)
        SELECT d.SalesOrderDetailID,h.SalesOrderID,h.OrderDate,h.CustomerID,
            COALESCE(h.SalesPersonID,-1),COALESCE(h.TerritoryID,-1),d.ProductID,d.SpecialOfferID,
            h.Status,h.OnlineOrderFlag,d.OrderQty,d.UnitPrice,d.UnitPriceDiscount,d.LineTotal,
            c.StandardCost,CASE WHEN c.StandardCost IS NULL THEN 'MISSING' ELSE 'HISTORICAL_STANDARD_COST' END,
            CASE WHEN h.ModifiedDate>d.ModifiedDate THEN h.ModifiedDate ELSE d.ModifiedDate END,@batch
        FROM #ChangedOrders x
        JOIN [$(SourceDatabase)].Sales.SalesOrderHeader h ON h.SalesOrderID=x.SalesOrderID
        JOIN [$(SourceDatabase)].Sales.SalesOrderDetail d ON d.SalesOrderID=h.SalesOrderID
        LEFT JOIN [$(SourceDatabase)].Production.ProductCostHistory c ON c.ProductID=d.ProductID
            AND h.OrderDate>=c.StartDate AND (c.EndDate IS NULL OR CAST(h.OrderDate AS date)<=CAST(c.EndDate AS date));
        SET @read=@@ROWCOUNT;
        SELECT s.SalesOrderDetailID,s.SalesOrderID,
            CAST(CONCAT(CASE WHEN OrderQty IS NULL OR OrderQty<=0 THEN 'INVALID_QUANTITY;' ELSE '' END,
                 CASE WHEN UnitPrice IS NULL OR UnitPrice<0 THEN 'INVALID_PRICE;' ELSE '' END,
                 CASE WHEN DiscountPct NOT BETWEEN 0 AND 1 THEN 'INVALID_DISCOUNT;' ELSE '' END,
                 CASE WHEN OrderDate<'19000101' THEN 'INVALID_DATE;' ELSE '' END,
                 CASE WHEN OrderStatus NOT BETWEEN 1 AND 6 THEN 'INVALID_STATUS;' ELSE '' END,
                 CASE WHEN ABS(NetSales-OrderQty*UnitPrice*(1-DiscountPct))>0.01 THEN 'AMOUNT_MISMATCH;' ELSE '' END) AS nvarchar(500)) Reason,
            j.Payload
        INTO #Invalid FROM stg.SalesLine s
        CROSS APPLY(SELECT s.* FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES) j(Payload)
        WHERE OrderQty IS NULL OR OrderQty<=0 OR UnitPrice IS NULL OR UnitPrice<0 OR DiscountPct NOT BETWEEN 0 AND 1
            OR OrderDate<'19000101' OR OrderStatus NOT BETWEEN 1 AND 6
            OR ABS(NetSales-OrderQty*UnitPrice*(1-DiscountPct))>0.01;
        SELECT @rejected=COUNT(*) FROM #Invalid;
        UPDATE r SET Reason=i.Reason,RawPayload=i.Payload,LastBatchID=@batch,RecordedAt=SYSUTCDATETIME()
        FROM ctl.RejectedSales r JOIN #Invalid i ON i.SalesOrderDetailID=r.SalesOrderDetailID;
        INSERT ctl.RejectedSales(SalesOrderDetailID,SalesOrderID,Reason,RawPayload,FirstBatchID,LastBatchID)
        SELECT i.SalesOrderDetailID,i.SalesOrderID,i.Reason,i.Payload,@batch,@batch FROM #Invalid i
        WHERE NOT EXISTS(SELECT 1 FROM ctl.RejectedSales r WHERE r.SalesOrderDetailID=i.SalesOrderDetailID);
        DELETE r FROM ctl.RejectedSales r WHERE
            (EXISTS(SELECT 1 FROM stg.SalesLine s WHERE s.SalesOrderDetailID=r.SalesOrderDetailID)
            AND NOT EXISTS(SELECT 1 FROM #Invalid i WHERE i.SalesOrderDetailID=r.SalesOrderDetailID))
            OR NOT EXISTS(SELECT 1 FROM [$(SourceDatabase)].Sales.SalesOrderDetail d WHERE d.SalesOrderDetailID=r.SalesOrderDetailID);

        -- JSON preserves null boundaries and avoids ambiguous string-concatenation hashes.
        UPDATE s SET HashDiff=HASHBYTES('SHA2_256',j.Payload)
        FROM stg.SalesLine s CROSS APPLY (
            SELECT s.SalesOrderID,s.OrderDate,s.CustomerID,s.SalesPersonID,s.TerritoryID,s.ProductID,
                   s.SpecialOfferID,s.OrderStatus,s.OnlineOrderFlag,s.OrderQty,s.UnitPrice,s.DiscountPct,
                   s.NetSales,s.EstimatedUnitCost,s.CostBasis
            FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES
        ) j(Payload);

        DECLARE @minDate date=(SELECT MIN(OrderDate) FROM stg.SalesLine),
                @maxDate date=(SELECT DATEADD(day,730,MAX(OrderDate)) FROM stg.SalesLine);
        ;WITH dates AS (
            SELECT @minDate d WHERE @minDate IS NOT NULL
            UNION ALL SELECT DATEADD(day,1,d) FROM dates WHERE d<@maxDate
        )
        INSERT dw.DimDate(DateKey,[Date],[Year],[Quarter],[Month],MonthName,YearMonth,WeekStart,ISOWeek,ISOYear,DayOfWeek)
        SELECT CONVERT(int,CONVERT(char(8),d,112)),d,YEAR(d),DATEPART(quarter,d),MONTH(d),DATENAME(month,d),
            CONVERT(char(7),d,126),DATEADD(day,-(DATEDIFF(day,'19000101',d)%7),d),DATEPART(iso_week,d),
            YEAR(DATEADD(day,3-(DATEDIFF(day,'19000101',d)%7),d)),1+DATEDIFF(day,'19000101',d)%7
        FROM dates WHERE NOT EXISTS(SELECT 1 FROM dw.DimDate dd WHERE dd.[Date]=dates.d)
        OPTION(MAXRECURSION 0);

        SELECT s.*,p.ProductKey,c.CustomerKey,sp.SalesPersonKey,t.TerritoryKey,pr.PromotionKey,
            CONVERT(int,CONVERT(char(8),s.OrderDate,112)) SalesDateKey
        INTO #Resolved
        FROM stg.SalesLine s
        LEFT JOIN dw.DimProduct p ON p.ProductID=s.ProductID AND s.OrderDate>=p.ValidFrom AND s.OrderDate<p.ValidTo
        LEFT JOIN dw.DimCustomer c ON c.CustomerID=s.CustomerID AND s.OrderDate>=c.ValidFrom AND s.OrderDate<c.ValidTo
        LEFT JOIN dw.DimSalesPerson sp ON sp.SalesPersonID=s.SalesPersonID AND s.OrderDate>=sp.ValidFrom AND s.OrderDate<sp.ValidTo
        LEFT JOIN dw.DimTerritory t ON t.TerritoryID=s.TerritoryID AND s.OrderDate>=t.ValidFrom AND s.OrderDate<t.ValidTo
        LEFT JOIN dw.DimPromotion pr ON pr.SpecialOfferID=s.SpecialOfferID
        WHERE NOT EXISTS(SELECT 1 FROM #Invalid i WHERE i.SalesOrderDetailID=s.SalesOrderDetailID);
        IF EXISTS(SELECT 1 FROM #Resolved WHERE ProductKey IS NULL OR CustomerKey IS NULL OR SalesPersonKey IS NULL
            OR TerritoryKey IS NULL OR PromotionKey IS NULL)
            THROW 51004,'DQ: missing dimension or effective version.',1;

        UPDATE f SET SalesOrderID=s.SalesOrderID,SalesDateKey=s.SalesDateKey,ProductKey=s.ProductKey,
            CustomerKey=s.CustomerKey,SalesPersonKey=s.SalesPersonKey,TerritoryKey=s.TerritoryKey,
            PromotionKey=s.PromotionKey,OrderStatus=s.OrderStatus,OnlineOrderFlag=s.OnlineOrderFlag,
            OrderQty=s.OrderQty,UnitPrice=s.UnitPrice,DiscountPct=s.DiscountPct,
            GrossSales=s.OrderQty*s.UnitPrice,DiscountAmount=s.OrderQty*s.UnitPrice*s.DiscountPct,
            NetSales=s.NetSales,EstimatedCost=s.OrderQty*s.EstimatedUnitCost,CostBasis=s.CostBasis,
            SourceModifiedDate=s.SourceModifiedDate,HashDiff=s.HashDiff,LoadBatchID=@batch
        FROM dw.FactSales f JOIN #Resolved s ON s.SalesOrderDetailID=f.SalesOrderDetailID
        WHERE f.HashDiff<>s.HashDiff;
        SET @updated=@@ROWCOUNT;
        UPDATE f SET SourceModifiedDate=s.SourceModifiedDate,LoadBatchID=@batch
        FROM dw.FactSales f JOIN #Resolved s ON s.SalesOrderDetailID=f.SalesOrderDetailID
        WHERE f.HashDiff=s.HashDiff AND f.SourceModifiedDate<>s.SourceModifiedDate;
        SET @updated+=@@ROWCOUNT;
        INSERT dw.FactSales(SalesOrderDetailID,SalesOrderID,SalesDateKey,ProductKey,CustomerKey,SalesPersonKey,TerritoryKey,
            PromotionKey,OrderStatus,OnlineOrderFlag,OrderQty,UnitPrice,DiscountPct,GrossSales,DiscountAmount,NetSales,
            EstimatedCost,CostBasis,SourceModifiedDate,HashDiff,LoadBatchID)
        SELECT SalesOrderDetailID,SalesOrderID,SalesDateKey,ProductKey,CustomerKey,SalesPersonKey,TerritoryKey,
            PromotionKey,OrderStatus,OnlineOrderFlag,OrderQty,UnitPrice,DiscountPct,OrderQty*UnitPrice,
            OrderQty*UnitPrice*DiscountPct,NetSales,OrderQty*EstimatedUnitCost,CostBasis,SourceModifiedDate,HashDiff,@batch
        FROM #Resolved s WHERE NOT EXISTS(SELECT 1 FROM dw.FactSales f WHERE f.SalesOrderDetailID=s.SalesOrderDetailID);
        SET @inserted=@@ROWCOUNT;
        -- Timestamp deltas cannot identify deletes. This small dataset uses a full key reconciliation.
        DELETE f FROM dw.FactSales f WHERE NOT EXISTS(
            SELECT 1 FROM [$(SourceDatabase)].Sales.SalesOrderDetail d WHERE d.SalesOrderDetailID=f.SalesOrderDetailID)
            OR EXISTS(SELECT 1 FROM ctl.RejectedSales r WHERE r.SalesOrderDetailID=f.SalesOrderDetailID);
        SET @deleted=@@ROWCOUNT;

        IF @InjectFailure=1 THROW 51005,'Injected failure: transaction and watermarks must roll back.',1;
        UPDATE ctl.Watermark SET LastSuccessfulValue=@upper,BatchID=@batch
        WHERE EntityName IN ('SalesOrderHeader','SalesOrderDetail');
        INSERT ctl.Watermark(EntityName,LastSuccessfulValue,BatchID)
        SELECT v.EntityName,@upper,@batch FROM (VALUES('SalesOrderHeader'),('SalesOrderDetail')) v(EntityName)
        WHERE NOT EXISTS(SELECT 1 FROM ctl.Watermark w WHERE w.EntityName=v.EntityName);
        UPDATE ctl.Batch SET FinishedAt=SYSUTCDATETIME(),Status='SUCCESS',RowsRead=@read,
            RowsInserted=@inserted,RowsUpdated=@updated,RowsDeleted=@deleted,DimensionVersions=@versions,RowsRejected=@rejected WHERE BatchID=@batch;
        COMMIT;
        SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
        EXEC sys.sp_releaseapplock @Resource='CompanyX_LoadSales',@LockOwner='Session';
        SELECT * FROM ctl.Batch WHERE BatchID=@batch;
    END TRY
    BEGIN CATCH
        IF XACT_STATE()<>0 ROLLBACK;
        SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
        DECLARE @error nvarchar(2048)=ERROR_MESSAGE();
        UPDATE ctl.Batch SET FinishedAt=SYSUTCDATETIME(),Status='FAILED',ErrorMessage=@error WHERE BatchID=@batch;
        IF @batch IS NOT NULL INSERT ctl.DataQualityIssue(BatchID,Message) VALUES(@batch,@error);
        EXEC sys.sp_releaseapplock @Resource='CompanyX_LoadSales',@LockOwner='Session';
        THROW;
    END CATCH;
END;
GO
