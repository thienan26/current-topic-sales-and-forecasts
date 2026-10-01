"""Integration checks against the dedicated restored source; restore changed rows in finally."""
import json
import sys
from decimal import Decimal
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'src'))
from companyx.config import ROOT, load_config
from companyx.database import connect, run_etl

config = load_config()
checks = []


def record(name, condition):
    if not condition:
        raise AssertionError(name)
    checks.append(name)
    print('PASS:', name, flush=True)


run_etl(config, full=True)
with connect(config, database=config['source_database'], autocommit=True) as src, connect(config, autocommit=True) as dw:
    line = src.execute('''SELECT TOP(1) d.SalesOrderDetailID,d.SalesOrderID,d.ProductID,d.OrderQty,d.UnitPrice,
        d.ModifiedDate,h.Status,h.ModifiedDate,h.SubTotal,p.Name,p.ModifiedDate
        FROM Sales.SalesOrderDetail d JOIN Sales.SalesOrderHeader h ON h.SalesOrderID=d.SalesOrderID
        JOIN Production.Product p ON p.ProductID=d.ProductID
        WHERE h.Status=5 AND d.OrderQty>0 AND d.UnitPrice>0 AND LEN(p.Name)<35
        ORDER BY d.SalesOrderDetailID DESC''').fetchone()
    detail, order, product, qty, price, modified, status, hmodified, subtotal, pname, pmodified = line
    inserted_id = None
    try:
        first = dw.execute('SELECT COUNT(*),SUM(NetSales) FROM dw.FactSales').fetchone()
        result = run_etl(config)
        second = dw.execute('SELECT COUNT(*),SUM(NetSales) FROM dw.FactSales').fetchone()
        record('Rerun is idempotent', tuple(first)==tuple(second) and result['RowsUpdated']==0 and result['RowsInserted']==0)
        valid = src.execute('''SELECT COUNT(*),SUM(d.LineTotal) FROM Sales.SalesOrderDetail d
            JOIN Sales.SalesOrderHeader h ON h.SalesOrderID=d.SalesOrderID
            WHERE h.Status=5 AND d.OrderQty>0 AND d.UnitPrice>=0 AND d.UnitPriceDiscount BETWEEN 0 AND 1''').fetchone()
        actual = dw.execute('SELECT COUNT(*),SUM(NetSales) FROM mart.Sales').fetchone()
        record('Valid shipped source exactly reconciles with KPI mart', tuple(valid)==tuple(actual))
        record('Quarantine + fact count reconciles with source', dw.execute('SELECT (SELECT COUNT(*) FROM dw.FactSales)+(SELECT COUNT(*) FROM ctl.RejectedSales)').fetchval()==src.execute('SELECT COUNT(*) FROM Sales.SalesOrderDetail').fetchval())

        before = dw.execute('SELECT NetSales FROM dw.FactSales WHERE SalesOrderDetailID=?',detail).fetchval()
        src.execute('UPDATE Sales.SalesOrderDetail SET UnitPrice=UnitPrice+1,ModifiedDate=GETDATE() WHERE SalesOrderDetailID=?',detail)
        watermark = tuple(dw.execute("SELECT LastSuccessfulValue,BatchID FROM ctl.Watermark WHERE EntityName='SalesOrderDetail'").fetchone())
        try:
            dw.execute('EXEC ctl.LoadSales @InjectFailure=1')
            raise AssertionError('Injected failure did not fail')
        except Exception as error:
            if 'Injected failure:' not in str(error):
                raise
        record('Failed batch leaves watermark unchanged', watermark==tuple(dw.execute("SELECT LastSuccessfulValue,BatchID FROM ctl.Watermark WHERE EntityName='SalesOrderDetail'").fetchone()))
        record('Failed batch rolls back facts', dw.execute('SELECT NetSales FROM dw.FactSales WHERE SalesOrderDetailID=?',detail).fetchval()==before)
        run_etl(config)
        expected=src.execute('SELECT LineTotal FROM Sales.SalesOrderDetail WHERE SalesOrderDetailID=?',detail).fetchval()
        record('Retry loads detail update', dw.execute('SELECT NetSales FROM dw.FactSales WHERE SalesOrderDetailID=?',detail).fetchval()==expected)

        src.execute('UPDATE Sales.SalesOrderHeader SET Status=6,ModifiedDate=GETDATE() WHERE SalesOrderID=?',order)
        run_etl(config)
        record('Header-only change updates all detail rows', dw.execute('SELECT COUNT(*) FROM dw.FactSales WHERE SalesOrderID=? AND OrderStatus<>6',order).fetchval()==0)
        record('Cancelled order excluded from KPI', dw.execute('SELECT COUNT(*) FROM mart.Sales WHERE SalesOrderID=?',order).fetchval()==0)

        old_key = dw.execute('SELECT ProductKey FROM dw.FactSales WHERE SalesOrderDetailID=?',detail).fetchval()
        src.execute('UPDATE Production.Product SET Name=?,ModifiedDate=GETDATE() WHERE ProductID=?',pname+' [BI TEST]',product)
        run_etl(config)
        record('Dimension change creates a new SCD2 version', dw.execute('SELECT COUNT(*) FROM dw.DimProduct WHERE ProductID=?',product).fetchval()>=2)
        record('Historical sale retains its historical surrogate key', dw.execute('SELECT ProductKey FROM dw.FactSales WHERE SalesOrderDetailID=?',detail).fetchval()==old_key)
        record('One current version per business key', dw.execute('SELECT COUNT(*) FROM dw.DimProduct WHERE ProductID=? AND IsCurrent=1',product).fetchval()==1)

        src.execute('UPDATE Sales.SalesOrderDetail SET UnitPrice=NULL,ModifiedDate=GETDATE() WHERE SalesOrderDetailID=?',detail)
        run_etl(config)
        record('Bad update is quarantined and removed from fact', dw.execute('SELECT COUNT(*) FROM ctl.RejectedSales WHERE SalesOrderDetailID=?',detail).fetchval()==1 and dw.execute('SELECT COUNT(*) FROM dw.FactSales WHERE SalesOrderDetailID=?',detail).fetchval()==0)
        src.execute('UPDATE Sales.SalesOrderDetail SET UnitPrice=?,ModifiedDate=GETDATE() WHERE SalesOrderDetailID=?',price,detail)
        run_etl(config)
        record('Repaired row leaves quarantine and returns to fact', dw.execute('SELECT COUNT(*) FROM ctl.RejectedSales WHERE SalesOrderDetailID=?',detail).fetchval()==0 and dw.execute('SELECT COUNT(*) FROM dw.FactSales WHERE SalesOrderDetailID=?',detail).fetchval()==1)

        inserted_id=src.execute('''SET NOCOUNT ON; DECLARE @ids TABLE(ID int);
            INSERT Sales.SalesOrderDetail(SalesOrderID,OrderQty,ProductID,SpecialOfferID,UnitPrice,UnitPriceDiscount,ModifiedDate)
            OUTPUT INSERTED.SalesOrderDetailID INTO @ids
            SELECT SalesOrderID,1,ProductID,SpecialOfferID,UnitPrice,UnitPriceDiscount,GETDATE()
            FROM Sales.SalesOrderDetail WHERE SalesOrderDetailID=?; SELECT ID FROM @ids;''',detail).fetchval()
        run_etl(config)
        record('New detail inserted incrementally', dw.execute('SELECT COUNT(*) FROM dw.FactSales WHERE SalesOrderDetailID=?',inserted_id).fetchval()==1)
        src.execute('DELETE Sales.SalesOrderDetail WHERE SalesOrderDetailID=?',inserted_id)
        run_etl(config)
        record('Hard delete detected by key reconciliation', dw.execute('SELECT COUNT(*) FROM dw.FactSales WHERE SalesOrderDetailID=?',inserted_id).fetchval()==0)
    finally:
        if inserted_id:
            src.execute('DELETE Sales.SalesOrderDetail WHERE SalesOrderDetailID=?',inserted_id)
        src.execute('UPDATE Sales.SalesOrderDetail SET UnitPrice=?,ModifiedDate=? WHERE SalesOrderDetailID=?',price,modified,detail)
        src.execute('UPDATE Sales.SalesOrderHeader SET Status=?,SubTotal=?,ModifiedDate=? WHERE SalesOrderID=?',status,subtotal,hmodified,order)
        src.execute('UPDATE Production.Product SET Name=?,ModifiedDate=? WHERE ProductID=?',pname,pmodified,product)
        run_etl(config, full=True)
        print('Restored test row values and reconciled warehouse.', flush=True)

(ROOT/'artifacts/sql_verification.json').write_text(json.dumps({'passed':len(checks),'checks':checks},indent=2),encoding='utf-8')
