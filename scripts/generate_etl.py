"""Generate explicit, reviewable T-SQL for the small conformed dimensions."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DIMS = {
    'Product': ('ProductID', ['ProductName', 'ProductNumber', 'Category', 'Subcategory', 'Color', 'Size'], """
        SELECT p.ProductID, p.Name ProductName, p.ProductNumber,
               COALESCE(c.Name,N'Unclassified') Category,
               COALESCE(s.Name,N'Unclassified') Subcategory, p.Color, p.Size
        FROM [$(SourceDatabase)].Production.Product p
        LEFT JOIN [$(SourceDatabase)].Production.ProductSubcategory s ON s.ProductSubcategoryID=p.ProductSubcategoryID
        LEFT JOIN [$(SourceDatabase)].Production.ProductCategory c ON c.ProductCategoryID=s.ProductCategoryID"""),
    'Customer': ('CustomerID', ['CustomerType', 'TerritoryID'], """
        SELECT CustomerID, CAST(CASE WHEN StoreID IS NULL THEN 'Individual' ELSE 'Store' END AS varchar(20)) CustomerType, TerritoryID
        FROM [$(SourceDatabase)].Sales.Customer"""),
    'SalesPerson': ('SalesPersonID', ['SalesPersonName', 'TerritoryID'], """
        SELECT sp.BusinessEntityID SalesPersonID,
               CAST(CONCAT(p.FirstName,N' ',p.LastName) AS nvarchar(200)) SalesPersonName, sp.TerritoryID
        FROM [$(SourceDatabase)].Sales.SalesPerson sp
        JOIN [$(SourceDatabase)].Person.Person p ON p.BusinessEntityID=sp.BusinessEntityID
        UNION ALL SELECT -1,N'Online / unassigned',NULL"""),
    'Territory': ('TerritoryID', ['TerritoryName', 'CountryRegionCode', 'TerritoryGroup'], """
        SELECT TerritoryID, Name TerritoryName, CountryRegionCode, [Group] TerritoryGroup
        FROM [$(SourceDatabase)].Sales.SalesTerritory
        UNION ALL SELECT -1,N'Unassigned',N'NA',N'Unassigned'"""),
}

parts = []
for name, (bk, attrs, query) in DIMS.items():
    cols = ','.join(attrs)
    values = ','.join('s.' + a for a in attrs)
    parts.append(f"""
        SELECT s.*, HASHBYTES('SHA2_256', j.Payload) HashDiff, j.Payload
        INTO #{name}
        FROM ({query}) s
        CROSS APPLY (SELECT {values} FOR JSON PATH, WITHOUT_ARRAY_WRAPPER, INCLUDE_NULL_VALUES) j(Payload);
        INSERT stg.DimensionSnapshot(EntityName,BusinessKey,Payload,HashDiff,BatchID)
        SELECT '{name}', {bk}, Payload, HashDiff, @batch FROM #{name};
        UPDATE d SET ValidTo=@now, IsCurrent=0
        FROM dw.Dim{name} d JOIN #{name} s ON s.{bk}=d.{bk}
        WHERE d.IsCurrent=1 AND d.HashDiff<>s.HashDiff;
        INSERT dw.Dim{name}({bk},{cols},ValidFrom,ValidTo,IsCurrent,HashDiff,HistoryBasis,LoadBatchID)
        SELECT s.{bk},{values},
            CASE WHEN EXISTS(SELECT 1 FROM dw.Dim{name} old WHERE old.{bk}=s.{bk}) THEN @now ELSE '19000101' END,
            '99991231',1,s.HashDiff,
            CASE WHEN EXISTS(SELECT 1 FROM dw.Dim{name} old WHERE old.{bk}=s.{bk}) THEN 'OBSERVED_CHANGE' ELSE 'INITIAL_SNAPSHOT' END,@batch
        FROM #{name} s WHERE NOT EXISTS(SELECT 1 FROM dw.Dim{name} d WHERE d.{bk}=s.{bk} AND d.IsCurrent=1);
        SET @versions += @@ROWCOUNT;
""")

template = (ROOT / 'sql/templates/etl.sql.in').read_text(encoding='utf-8')
(ROOT / 'sql/02_etl.sql').write_text(template.replace('-- GENERATED_DIMENSIONS', '\n'.join(parts)), encoding='utf-8')
print('Generated sql/02_etl.sql')
